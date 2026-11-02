# asa-hub-spoke-ipsec

## Objective

Three Cisco ASA firewalls (ASAv in the lab, standing in for ASA 5506-X units) in a
hub-and-spoke site-to-site IPsec design, built three ways so the configurations can
be compared and tested: route-based VTI over IKEv2, policy-based crypto maps over
IKEv2, and policy-based crypto maps over IKEv1. One Linux host per site proves
end-to-end traffic, including spoke-to-spoke traffic hairpinning through the hub.

## Topology

```
        h1 (10.1.0.10)                 h2 (10.2.0.10)                h3 (10.3.0.10)
          |  inside 10.1.0.0/24          |  inside 10.2.0.0/24         |  inside 10.3.0.0/24
      asa-hub (.1)                  asa-spoke1 (.1)               asa-spoke2 (.1)
          | outside 203.0.113.1          | outside 203.0.113.2         | outside 203.0.113.3
          +------------------------------+-----------------------------+
                        wan  203.0.113.0/24  (Linux container acting as a bridge)
```

A draw.io version of this topology lives at
[`docs/diagrams/asa-hub-spoke-ipsec.drawio`](../../docs/diagrams/asa-hub-spoke-ipsec.drawio)
(open with diagrams.net or import into Visio).

Tunnels: `asa-hub` ↔ `asa-spoke1` and `asa-hub` ↔ `asa-spoke2`. There is no
spoke-to-spoke tunnel; spoke1 ↔ spoke2 traffic goes through the hub.

Containerlab interface mapping for the ASAv nodes: `eth1` = `GigabitEthernet0/0`
(outside), `eth2` = `GigabitEthernet0/1` (inside). `Management0/0` sits on
containerlab's management network and is what `verify.sh` SSHes to.

### Interface names on real 5506-X hardware

| Role | ASAv (this lab) | ASA 5506-X |
|---|---|---|
| outside | `GigabitEthernet0/0` | `GigabitEthernet1/1` |
| inside | `GigabitEthernet0/1` | `GigabitEthernet1/2` |
| management | `Management0/0` | `Management1/1` |

The 5506-X factory configuration bridges `GigabitEthernet1/2`–`1/8` into `BVI1`;
remove that bridge-group configuration before applying these configs.

## Variants

| Variant | Tunnel style | Minimum ASA | Configs |
|---|---|---|---|
| `vti-ikev2` (default) | route-based VTI, IKEv2 | 9.8 | `configs/asa-*/startup.cfg` |
| `cryptomap-ikev2` | policy-based crypto map, IKEv2 | 9.x | `variants/cryptomap-ikev2/configs/` |
| `cryptomap-ikev1` | policy-based crypto map, IKEv1 | 9.x | `variants/cryptomap-ikev1/configs/` |

Crypto parameters: IKEv2 uses AES-256-GCM, PRF SHA-384, DH group 19; IPsec proposal
`GCM` (ESP AES-GCM-256). IKEv1 uses AES-256 / SHA-1 / DH group 14 with transform set
`AES256-SHA` (GCM is not available in IKEv1 on ASA).

Pre-shared keys are lab placeholders: `LAB-PSK-SPOKE1` and `LAB-PSK-SPOKE2`. Change
them before using these configs anywhere real.

In the VTI variant all tunnel interfaces use `security-level 100` and every ASA sets
`same-security-traffic permit inter-interface`: VTI traffic gets no
`sysopt connection permit-vpn` bypass, so without this it would be dropped toward
`inside`.

### The crypto-map hairpin gotcha

With crypto maps, spoke-to-spoke traffic only works if the hub's crypto ACLs include
the cross entries: `L2L-SPOKE1` must permit `10.3.0.0/24 → 10.2.0.0/24` and
`L2L-SPOKE2` must permit `10.2.0.0/24 → 10.3.0.0/24`, with matching entries on each
spoke (exact /24 mirrors of the hub's two ACEs for that peer), and the hub needs
`same-security-traffic permit intra-interface`. Without them spoke1 ↔ spoke2 pings
fail while hub ↔ spoke traffic looks healthy. The VTI variant has no such ACLs: the
hub simply routes between the two tunnel interfaces.

The two crypto-map variants differ only in the IKE version lines; diff them to see
exactly what moving from IKEv1 to IKEv2 changes.

## Tasks

1. Build the ASAv image with vrnetlab (https://github.com/srl-labs/vrnetlab, `asav/`)
   from your ASAv qcow2 and tag it `vrnetlab/cisco_asav:9.18.4`, or edit the tag in
   `topology.clab.yml` and `scenario.yml` to match your build.
2. Bring up a variant: `scripts/up.sh asa-hub-spoke-ipsec --force [--variant cryptomap-ikev2|cryptomap-ikev1]`
   (`--force` while the scenario is `draft`).
3. Wait for the ASAs to boot (ASAv takes 5–7 minutes to boot), then run the verification.

## Verification

`scripts/verify.sh asa-hub-spoke-ipsec [--variant X]` checks, in order:

1. All three ASAs answer `show version` over SSH (management network).
2. Each host pings its own ASA's inside address.
3. After hosts send traffic toward the hub, `show crypto ikev2 sa` (or `ikev1`) on the
   hub lists both spoke peers.
4. Host pings succeed and the hub's `#pkts encaps:` for each peer is present and not
   `0,`, so the traffic really went through the tunnels.
5. h2 pings h3 through the hub.
6. VTI variant only: `Tunnel1` and `Tunnel2` on the hub are up/up.

SSH defaults are vrnetlab's `admin` / `CiscoAsa1!`; override with `ASA_USER` and
`ASA_PASS`. `sshpass`, `ssh` and coreutils `timeout` must be installed. Other knobs:
`ASA_BOOT_TIMEOUT` (default 600 seconds to wait for the ASAs to boot), `ASA_SA_TIMEOUT`
(120, wait for the tunnels' SAs) and `ASA_SSH_TIMEOUT` (30, per SSH call). `SSHPASS_BIN`
and `SSH` override the binaries.

If `asa_exec` returns an interactive banner instead of command output, your ASA's SSH
server does not support exec requests; run the validation with the commands fed on stdin
(see conventions) — confirm with `ssh admin@<mgmt-ip> "show version"` on a real ASAv
before flipping status to ready.

vrnetlab-built images use an ECDSA host key, so no SSH client changes are normally
needed. The `ssh-rsa` settings are only a fallback for hand-built images: if `asa_exec`
fails with a key-exchange or host-key error, add `HostKeyAlgorithms +ssh-rsa` and
`PubkeyAcceptedAlgorithms +ssh-rsa` for the management subnet in `~/.ssh/config`.

## Validation on a containerlab host

CI cannot run containerlab or ASAv, so this scenario stays `status: draft` until the
following has passed once per variant on a machine with containerlab, Docker and the
vrnetlab ASAv image:

```bash
for v in vti-ikev2 cryptomap-ikev2 cryptomap-ikev1; do
  scripts/up.sh asa-hub-spoke-ipsec --force --variant "$v"
  scripts/verify.sh asa-hub-spoke-ipsec --variant "$v" || { echo "FAIL $v"; break; }
  scripts/down.sh asa-hub-spoke-ipsec --variant "$v"
done
```

The commit that flips `status` to `ready` records the ASAv and containerlab versions
used here:

- ASAv version: not yet validated
- containerlab version: not yet validated

## Simulators

| Simulator | Status |
|---|---|
| Containerlab | native (vrnetlab `cisco_asav`) |
| GNS3 | none yet (ASAv QEMU appliance; see `docs/simulators/gns3.md`) |
| EVE-NG | none yet (`asav` template; see `docs/simulators/eve-ng.md`) |

## Teardown

`scripts/down.sh asa-hub-spoke-ipsec [--variant X]`
