# ASA hub-and-spoke IPsec scenario: design

Date: 2026-11-01
Status: approved for planning
Scenario: `scenarios/asa-hub-spoke-ipsec`

## Goal

The first real scenario in `network-labs`: three Cisco ASA 5506-X firewalls in
a hub-and-spoke IPsec design, with one Linux host behind each, built three ways
(route-based VTI over IKEv2, policy-based crypto maps over IKEv2, policy-based
crypto maps over IKEv1) as variants of a single scenario. `verify.sh` proves the
tunnels are up, carry encrypted traffic, and that spoke-to-spoke traffic hairpins
through the hub.

It is also the first vendor-only scenario and the first to need CLI access to a
network OS that `docker exec` cannot reach, so it adds a small, reusable SSH path
to `scripts/lib.sh`.

## Decisions already made

| Topic | Decision |
|---|---|
| Topology | Hub and spoke: `asa-hub` ↔ `asa-spoke1`, `asa-hub` ↔ `asa-spoke2`. No spoke-to-spoke tunnel. |
| Variants | Three variants of one scenario: `vti-ikev2` (default), `cryptomap-ikev2`, `cryptomap-ikev1`. Variants swap ASA configs only; images and hosts are identical. |
| Images | ASAv 9.8+ supplied by the user, built with vrnetlab as `vrnetlab/cisco_asav:<tag>`. No free-image fallback; the scenario is ASA-only and documented as such. |
| Hosts and checks | One Linux host per site. Verify: ASAs reachable, IKE SAs up on the hub for both spokes, non-zero IPsec encaps/decaps, spoke→hub pings, spoke→spoke ping via the hub, VTI interfaces up/up (VTI variant). |
| ASA access | `asa_exec` over SSH to the containerlab management address using `ssh` + `sshpass` (vrnetlab default `admin` / `Admin@123`, overridable). `expect_contains` / `wait_for` route nodes listed in `ASA_NODES` through it. |
| Default-variant layout | The default variant's ASA configs live in `configs/` so `topology.clab.yml` is self-contained; only the two crypto-map variants live under `variants/`. |

## Approaches considered

- **A. Config-only variants + SSH-based ASA checks.** Chosen. Fits the existing
  variant overlay mechanism unchanged; verification reads real SA state.
  Adds `sshpass` as an optional dependency, needed only by scenarios that set
  `ASA_NODES`.
- **B. Host-side verification only.** Rejected: a tunnel that is up but carrying
  traffic in cleartext (wrong crypto ACL, NAT path) would still pass pings.
- **C. Console-driven checks with `expect`.** Rejected: brittle prompt handling
  and a second scripting language.

## Topology and addressing

```
        h1 (10.1.0.10)                 h2 (10.2.0.10)                h3 (10.3.0.10)
          |  inside 10.1.0.0/24          |  inside 10.2.0.0/24         |  inside 10.3.0.0/24
      asa-hub (.1)                  asa-spoke1 (.1)               asa-spoke2 (.1)
          | outside 203.0.113.1          | outside 203.0.113.2         | outside 203.0.113.3
          +------------------------------+-----------------------------+
                               wan  203.0.113.0/24  (Linux container acting as a bridge)
```

| Node | Kind | Image | Role |
|---|---|---|---|
| `asa-hub` | `cisco_asav` | `vrnetlab/cisco_asav:<tag>` | hub, outside 203.0.113.1, inside 10.1.0.1 |
| `asa-spoke1` | `cisco_asav` | same | spoke, outside 203.0.113.2, inside 10.2.0.1 |
| `asa-spoke2` | `cisco_asav` | same | spoke, outside 203.0.113.3, inside 10.3.0.1 |
| `h1`, `h2`, `h3` | `linux` | `wbitt/network-multitool` | 10.x.0.10/24, route to 10.0.0.0/8 via their ASA, set via `exec:` |
| `wan` | `linux` | `wbitt/network-multitool` | Linux container bridging its three ports (br0); flat stand-in for the internet. A containerlab `bridge` kind would need a pre-created host bridge. |

Links: each ASA `GigabitEthernet0/0` → `wan`; each ASA `GigabitEthernet0/1` →
its host `eth1`. Six links. Management: containerlab's management network on
`Management0/0` of each ASA; hosts need no management access beyond `docker exec`.

Spoke-to-spoke traffic flows inside-spoke1 → hub → inside-spoke2; the hub
permits it with `same-security-traffic permit intra-interface` plus the
per-variant routes or crypto ACL entries.

### Interface mapping to hardware

Configs use ASAv interface names. The scenario README carries this table so the
configs can be lifted onto 5506-X units:

| Role | ASAv (this lab) | ASA 5506-X |
|---|---|---|
| outside | `GigabitEthernet0/0` | `GigabitEthernet1/1` |
| inside | `GigabitEthernet0/1` | `GigabitEthernet1/2` |
| management | `Management0/0` | `Management1/1` |

Note for hardware: the 5506-X default configuration bridges `Gi1/2`–`Gi1/8` into
BVI1; remove the bridge-group configuration before applying these configs.

## Shared ASA base configuration

Identical in all variants, per ASA: hostname; `outside` (security-level 0) and
`inside` (security-level 100) with the addresses above; `same-security-traffic
permit intra-interface` on the hub; no default route (the WAN is a flat,
directly connected segment with no gateway, so every peer is reachable without
one; routes to remote inside networks are per variant, below); ICMP
inspection (`policy-map global_policy` → `inspect icmp`); identity NAT exemption
`nat (inside,outside) source static <local> <local> destination static <remote>
<remote> no-proxy-arp route-lookup` for all site-to-site pairs; `ssh 0.0.0.0
0.0.0.0 management` and `aaa authentication ssh console LOCAL` so `asa_exec`
works (vrnetlab's bootstrap already creates the `admin` user; the startup config
must not remove it); `tunnel-group <peer-ip> type ipsec-l2l` with a pre-shared
key per peer.

Pre-shared keys are lab placeholders (`LAB-PSK-SPOKE1`, `LAB-PSK-SPOKE2`) and
the README says so.

## Variants

### `vti-ikev2` (default; configs in `configs/`)

- `crypto ikev2 policy 10`: AES-256-GCM, PRF SHA-384, DH group 19, lifetime
  86400. `crypto ikev2 enable outside`.
- `crypto ipsec ikev2 ipsec-proposal GCM` (AES-GCM-256) and `crypto ipsec
  profile VTI-PROFILE` (`set ikev2 ipsec-proposal GCM`).
- Hub: `interface Tunnel1` 169.254.1.1/30 → spoke1, `interface Tunnel2`
  169.254.2.1/30 → spoke2. Each: `nameif vti-spokeN`, `tunnel source interface
  outside`, `tunnel destination <spoke outside>`, `tunnel mode ipsec ipv4`,
  `tunnel protection ipsec profile VTI-PROFILE`.
- Spokes: `interface Tunnel1` 169.254.N.2/30 → hub.
- Routes: hub `10.2.0.0/24 → Tunnel1`, `10.3.0.0/24 → Tunnel2`; spokes
  `10.0.0.0/8 → Tunnel1` (covers hub and the other spoke).
- Spoke-to-spoke works because the hub routes between the two VTIs.
- All Tunnel interfaces use `security-level 100` and every ASA sets
  `same-security-traffic permit inter-interface`, because VTI traffic is subject
  to normal interface security rules (no `sysopt connection permit-vpn` bypass)
  and would otherwise be dropped toward `inside`.
- Requires ASA 9.8 or newer.

### `cryptomap-ikev2` (`variants/cryptomap-ikev2/`)

- Same IKEv2 policy and `crypto ipsec ikev2 ipsec-proposal GCM`.
- Hub crypto ACLs: `L2L-SPOKE1` permits 10.1.0.0/24 and 10.3.0.0/24 →
  10.2.0.0/24; `L2L-SPOKE2` permits 10.1.0.0/24 and 10.2.0.0/24 → 10.3.0.0/24.
  The cross entries (10.3.0.0 → 10.2.0.0 and 10.2.0.0 → 10.3.0.0) are what make
  spoke-to-spoke hairpinning work; the README names this as the classic
  crypto-map gotcha.
- Spoke crypto ACL `L2L-HUB`: two entries, local /24 → 10.1.0.0/24 and local /24 → the other spoke's /24, exact mirrors of the hub's ACEs (ASA requires mirrored crypto ACLs; no reliance on IKEv2 selector narrowing).
- `crypto map OUTSIDE_MAP 10` (spoke1) and `20` (spoke2) on the hub, `10` on
  each spoke: `match address`, `set peer`, `set ikev2 ipsec-proposal GCM`;
  `crypto map OUTSIDE_MAP interface outside`.
- Routes (crypto maps need a route out `outside` for interesting traffic): hub
  `route outside 10.2.0.0 255.255.255.0 203.0.113.2` and `route outside
  10.3.0.0 255.255.255.0 203.0.113.3`; spokes `route outside 10.0.0.0 255.0.0.0
  203.0.113.1`.
- NAT exemption entries mirror the crypto ACLs.

### `cryptomap-ikev1` (`variants/cryptomap-ikev1/`)

- `crypto ikev1 policy 10`: AES-256, SHA, DH group 14, pre-share, lifetime
  86400. `crypto ikev1 enable outside`.
- `crypto ipsec ikev1 transform-set AES256-SHA esp-aes-256 esp-sha-hmac`.
- Same ACLs, routes and crypto-map structure as `cryptomap-ikev2`, with `set
  ikev1 transform-set AES256-SHA`; `tunnel-group ... ipsec-attributes` → `ikev1
  pre-shared-key`.
- The diff between the two crypto-map variants is almost purely the IKE
  version, which the README points out.

### Variant wiring

Each variant's `topology.patch.yml` only repoints `startup-config:` for the
three ASAs at that variant's `configs/asa-*/startup.cfg`. `scenario.yml` lists
all three variants with identical `images:` maps and a `notes:` giving the
minimum ASA version (9.8 for `vti-ikev2`; any 9.x for the others).

## Verification

### Library additions (`scripts/lib.sh`)

- `node_mgmt_ip NODE`: `"$DOCKER" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' clab-<lab>-NODE`; fails if empty.
- `asa_exec NODE CMD`: `"$SSHPASS" -p "$ASA_PASS" "$SSH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR "$ASA_USER@$(node_mgmt_ip NODE)" "CMD"`. Defaults: `ASA_USER=admin`, `ASA_PASS=Admin@123`, `SSH=ssh`, `SSHPASS=sshpass`. Fails via `fail` with an install hint when `sshpass` or `ssh` is missing.
- `_run_on_node NODE CMD`: dispatches to `asa_exec` when NODE is a word in `$ASA_NODES`, else `node_exec`. `expect_contains` and `wait_for` call `_run_on_node` instead of `node_exec`; their interface does not change.
- `expect_not_contains NODE CMD UNEXPECTED`: fails if the output contains UNEXPECTED. Mirrors `expect_contains`.

`scripts/verify.sh` is unchanged; the scenario's `verify.sh` exports `ASA_NODES`.

### `scenarios/asa-hub-spoke-ipsec/verify.sh`

1. `export ASA_NODES="asa-hub asa-spoke1 asa-spoke2"`; pick `IKE=ikev1` when
   `$VARIANT` is `cryptomap-ikev1`, else `ikev2`.
2. ASAs booted: `wait_for 300 <asa> "show version | include Software" "Cisco Adaptive Security Appliance"` for all three (ASAv boots in 2–4 minutes).
3. Hosts reach their own ASA: `expect_contains h1 "ping -c 2 -W 2 10.1.0.1" "2 received"` (h2, h3 likewise).
4. Trigger and wait for tunnels: `node_exec h2 "ping -c 3 -W 2 10.1.0.10" || true`, same from h3; then `wait_for 120 asa-hub "show crypto $IKE sa" "203.0.113.2"` and `"203.0.113.3"`.
5. Encrypted traffic: `expect_contains h2 "ping -c 5 -W 2 10.1.0.10" "5 received"`; `expect_not_contains asa-hub "show crypto ipsec sa peer 203.0.113.2 | include pkts encaps" "#pkts encaps: 0"`; same for h3 / 203.0.113.3.
6. Spoke-to-spoke through the hub: `expect_contains h2 "ping -c 5 -W 2 10.3.0.10" "5 received"`.
7. VTI variant only: `expect_contains asa-hub "show interface Tunnel1 | include line protocol" "up"`, same for `Tunnel2`.
8. `log "all checks passed"`.

### Scenario tests (Docker-free, `tests/test_asa_hub_spoke.sh`)

- `scenario.yml` validates; `name` equals the directory; status is `draft`
  until a real run passes.
- For each variant, `build_topology` output has exactly three `cisco_asav`
  nodes and four `linux` nodes (h1–h3 and `wan`), six links, and every
  `startup-config` path exists relative to the built file.
- Each variant's hub config contains its marker: `interface Tunnel1` and
  `tunnel protection ipsec profile` for `vti-ikev2`; `crypto map OUTSIDE_MAP
  interface outside` plus `crypto ikev2 enable outside` or `crypto ikev1 enable
  outside` for the crypto-map variants.
- Crypto-map hub ACLs contain the spoke-to-spoke cross entries
  (`10.3.0.0 255.255.255.0 10.2.0.0 255.255.255.0` in `L2L-SPOKE1` and the
  reverse in `L2L-SPOKE2`).
- No startup config has an empty pre-shared key; every spoke config references
  the hub's outside address as its peer.
- Library tests in `tests/test_verify.sh`: `node_mgmt_ip` with a stubbed
  `docker inspect`; `asa_exec` builds the expected `sshpass`/`ssh` argument
  list (stubbed binaries recording argv); `expect_contains` routes an
  `ASA_NODES` member through `asa_exec` and others through `node_exec`;
  `expect_not_contains` passes and fails correctly; `asa_exec` fails with the
  install hint when `SSHPASS` points at a missing binary.

### Real-world validation (outside this repository's CI)

Containerlab and the ASAv image are not available in CI. The scenario stays
`status: draft` until the following has been run on a machine with containerlab,
Docker and the vrnetlab ASAv image, once per variant:

```bash
scripts/up.sh asa-hub-spoke-ipsec --force [--variant cryptomap-ikev2|cryptomap-ikev1]
scripts/verify.sh asa-hub-spoke-ipsec [--variant ...]
scripts/down.sh asa-hub-spoke-ipsec [--variant ...]
```

The commit that flips `status` to `ready` records the ASAv version and
containerlab version used in the scenario README.

## Documentation changes

- Scenario `README.md`: objective, topology diagram, variant table with minimum
  ASA versions, crypto parameters, the crypto-map hairpin gotcha, the 5506-X
  interface mapping and BVI note, how to build and tag the ASAv vrnetlab image,
  the validation commands above, and the lab-only PSK warning.
- `images/README.md`: ASAv row (vendor image, vrnetlab recipe, tag convention).
- `docs/conventions.md`: `ASA_NODES` / `asa_exec` convention; `sshpass` and
  `ssh` listed as optional runtime dependencies for scenarios that set
  `ASA_NODES`; `ASA_USER` / `ASA_PASS` / `SSH` / `SSHPASS` overrides.
- `docs/simulators/gns3.md` and `eve-ng.md`: `cisco_asav` row in the kind
  mapping tables (GNS3 ASAv QEMU appliance; EVE-NG `asav` template).
- Exports remain `none` for all three simulators in `scenario.yml`.

## Out of scope

- FirePOWER / FTD, NAT traversal through a real NAT device, dynamic routing
  (BGP/OSPF) over the VTIs, certificate authentication, ASA failover pairs.
- A spoke-to-spoke backup tunnel.
- Running containerlab in this cloud session; validation happens on the user's
  machine as described above.
- GNS3 / EVE-NG exports for this scenario (hand-written exports can follow once
  the ASA configs are validated).
