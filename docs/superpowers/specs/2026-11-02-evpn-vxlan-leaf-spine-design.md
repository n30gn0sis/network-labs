# EVPN/VXLAN leaf-spine scenario: design

Date: 2026-11-02
Status: approved for planning
Scenario: `scenarios/evpn-vxlan-leaf-spine`

## Goal

The first datacenter-fabric scenario: two spines and two leaves running FRR,
eBGP unnumbered as the underlay, BGP EVPN as the overlay, and one Linux host
per leaf in a single VLAN stretched across both leaves over VXLAN (L2 VNI 10).
`verify.sh` proves the BGP sessions in both address families, ECMP between the
spines, VTEP discovery (EVPN type-3), MAC learning across the fabric (EVPN
type-2), host-to-host reachability, and that traffic survives the loss of one
spine uplink while the other spine carries it, restored under `trap`.

It stays on the repository's free path (FRR + multitool images, `docker exec`
verification) while exercising a protocol stack that neither earlier scenario
touches: unnumbered BGP over IPv6 link-local, the L2VPN EVPN address family,
and Linux kernel bridging and VXLAN as the dataplane.

## Decisions already made

| Topic | Decision |
|---|---|
| Shape | 2 spines, 2 leaves, 1 host per leaf. One VLAN (VNI 10) stretched across the leaves. No IRB, no L3 VNI, no anycast gateway. |
| Underlay | eBGP unnumbered: every fabric link is IPv4-unnumbered, BGP peers over IPv6 link-local learned from router advertisements. Spines share AS 65100; each leaf has its own AS. |
| Overlay | BGP EVPN on the same sessions. Leaves are VTEPs with `advertise-all-vni`; spines only relay EVPN routes. |
| Images | FRR only: `quay.io/frrouting/frr:10.1` for routers, `wbitt/network-multitool:latest` for hosts. Single variant `frr`, no vendor variants. |
| Dataplane plumbing | Linux bridge and VXLAN device per leaf created from the node's `exec:` list in `topology.clab.yml` (approach A). No setup scripts. |
| Verification depth | Protocol state in both address families, ECMP, VTEP and MAC state, host↔host ping, one spine-uplink failover with restore. |
| Failure injection | `ip link set eth1 down` on `leaf1` (its uplink to `spine1`), restored under `trap`, as in `ospf-ebgp-two-as`. |

## Topology

```
          spine1 (AS 65100)          spine2 (AS 65100)
          10.0.0.1                   10.0.0.2
           /      \                  /      \
      eth1/        \eth2        eth1/        \eth2
         /          \              /          \
   eth1 /       eth2 \        eth1/        eth2 \
   leaf1 ───────────────────────┘               leaf2
   AS 65001  (eth2 ─────────────────────────────┘)  AS 65002
   10.0.0.11                                      10.0.0.12
     │ eth3                                          │ eth3
     h1  10.10.0.1/24                                h2  10.10.0.2/24
                 VLAN 10 stretched over VXLAN VNI 10
```

Each leaf has two uplinks: `eth1` to `spine1` and `eth2` to `spine2`.

### Nodes

| Node | Kind / image | Role | Loopback (router-id, VTEP IP) | ASN |
|---|---|---|---|---|
| `spine1` | `linux` / FRR | spine, EVPN relay | 10.0.0.1/32 | 65100 |
| `spine2` | `linux` / FRR | spine, EVPN relay | 10.0.0.2/32 | 65100 |
| `leaf1` | `linux` / FRR | leaf, VTEP for `h1` | 10.0.0.11/32 | 65001 |
| `leaf2` | `linux` / FRR | leaf, VTEP for `h2` | 10.0.0.12/32 | 65002 |
| `h1` | `linux` / multitool | host in VLAN 10, 10.10.0.1/24, no default route | | |
| `h2` | `linux` / multitool | host in VLAN 10, 10.10.0.2/24, no default route | | |

Both spines share one AS so that a leaf never sees its own AS in a path and
so that both spines present the same AS path for a given leaf loopback, which
is what makes the two paths ECMP candidates. The hosts have no gateway: the
scenario proves pure L2 extension, and `h1 → h2` is a same-subnet ping.

### Links and interface mapping

Interface names are explicit in every `endpoints:` entry.

| Link | Addressing | A side | B side |
|---|---|---|---|
| leaf1–spine1 | unnumbered (IPv6 link-local) | `leaf1:eth1` | `spine1:eth1` |
| leaf1–spine2 | unnumbered | `leaf1:eth2` | `spine2:eth1` |
| leaf2–spine1 | unnumbered | `leaf2:eth1` | `spine1:eth2` |
| leaf2–spine2 | unnumbered | `leaf2:eth2` | `spine2:eth2` |
| leaf1–h1 | access port, VLAN 10 | `leaf1:eth3` (bridge member) | `h1:eth1` 10.10.0.1/24 |
| leaf2–h2 | access port, VLAN 10 | `leaf2:eth3` (bridge member) | `h2:eth1` 10.10.0.2/24 |

The failover test takes down `leaf1:eth1`, the link to `spine1`. It is marked
with a comment in `topology.clab.yml` like the OSPF scenario's primary link.

### Management default route

All four routers run `ip route del default` first in their `exec:` list
(established convention: the containerlab management default is a kernel
route that would otherwise shadow fabric routes and let traffic leak via the
management network). Hosts keep their management route; they need no fabric
default because their only fabric destination is on-link.

## Control plane (`frr.conf`)

Daemons: `zebra`, `bgpd`, `staticd` (template alignment; `staticd` is
harmless). `ospfd=no` everywhere. Configs are integrated `frr.conf` files
bind-mounted to `/etc/frr/frr.conf` with a `daemons` file per router.

### Common to all four routers

```
interface lo
 ip address <loopback>/32
!
interface eth1
 no ipv6 nd suppress-ra
 ipv6 nd ra-interval 10
!
interface eth2
 no ipv6 nd suppress-ra
 ipv6 nd ra-interval 10
!
router bgp <asn>
 bgp router-id <loopback>
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 bgp bestpath as-path multipath-relax
 neighbor fabric peer-group
 neighbor fabric remote-as external
 neighbor eth1 interface peer-group fabric
 neighbor eth2 interface peer-group fabric
 !
 address-family ipv4 unicast
  neighbor fabric activate
  redistribute connected
 exit-address-family
 !
 address-family l2vpn evpn
  neighbor fabric activate
 exit-address-family
```

`redistribute connected` is what carries each loopback into the underlay;
there are no other connected IPv4 networks on a router (fabric links are
unnumbered, the host-facing port is a bridge member with no address).
`multipath-relax` is not strictly required here, since both paths to a remote
loopback carry the identical AS path `65100 650xx`, but it is the conventional
line in an unnumbered fabric and keeps the design robust to later changes
(for example a third spine in a different AS).

### Leaves only

Inside `address-family l2vpn evpn`:

```
  advertise-all-vni
  vni 10
   rd auto
   route-target import 65000:10
   route-target export 65000:10
  exit-vni
```

`advertise-all-vni` makes FRR originate a type-3 (inclusive multicast) route
for every VXLAN device it finds in the kernel and a type-2 (MAC) route for
every local MAC in the bridge FDB. The explicit route-targets matter: FRR
auto-derives the RT as `<ASN>:<VNI>`, and because each leaf is in its own AS
the auto-derived RTs (`65001:10` and `65002:10`) would never match, so leaf2
would silently discard leaf1's routes. Pinning both leaves to `65000:10`
removes the trap and gives the README a concrete thing to explain.

Spines carry EVPN routes without a VXLAN device, so they have no
`advertise-all-vni` and no `vni` block.

### Route selection and ECMP

Each leaf learns the other leaf's loopback from both spines with the same AS
path length and the same AS path, so `show ip route 10.0.0.12/32` on `leaf1`
installs two next hops, one per uplink. When `leaf1:eth1` goes down, the
session to `spine1` drops, that path is withdrawn, and the kernel route keeps
the `eth2` next hop. The VXLAN tunnel endpoint does not change, so EVPN state
on both leaves is unaffected: only the underlay path moves.

## Dataplane plumbing (`exec:` lists)

Spines:

```yaml
exec:
  - ip route del default
  - sysctl -qw net.ipv6.conf.all.disable_ipv6=0
```

Leaves (`leaf1` shown; `leaf2` uses `local 10.0.0.12`):

```yaml
exec:
  - ip route del default
  - sysctl -qw net.ipv6.conf.all.disable_ipv6=0
  - ip link add br10 type bridge
  - ip link add vxlan10 type vxlan id 10 local 10.0.0.11 dstport 4789 nolearning
  - ip link set vxlan10 master br10
  - ip link set eth3 master br10
  - ip link set br10 up
  - ip link set vxlan10 up
  - ip link set eth3 up
```

Hosts:

```yaml
exec:
  - ip addr add 10.10.0.1/24 dev eth1     # h2: 10.10.0.2/24
```

Why each line is there:

- The `sysctl` is a deterministic guarantee rather than a fallback: BGP
  unnumbered needs an IPv6 link-local address on every fabric interface, and
  Docker can start a container with IPv6 disabled depending on the host's
  daemon settings. Setting `all.disable_ipv6=0` enables it on every interface
  the container already has, which is all of them by the time `exec` runs.
- `nolearning` disables kernel MAC learning on the VXLAN device, so remote
  MACs enter the bridge FDB only through EVPN type-2 routes installed by
  zebra. That is what makes `show evpn mac vni 10` a meaningful test rather
  than a mirror of flooded traffic.
- `local 10.0.0.11` pins the VTEP source address to the loopback. FRR reads
  it from the device to pick the VTEP IP it advertises in type-3 routes.
  Creating the device does not require the address to exist yet; it must
  exist before traffic flows, and `frr.conf` configures it at startup.
- `eth3` joins the bridge as an untagged access port, so hosts need no VLAN
  awareness.
- No `exec` on spines beyond the two housekeeping lines: spines have no
  dataplane role.

`verify.sh` must not assume any ordering between the `exec` list and FRR's
own startup; every check that depends on both (VNI present, VTEP learned) is
wrapped in `wait_for`.

## Verification

Uses only the existing helpers over `docker exec`: `node_exec`,
`expect_contains`, `expect_not_contains`, `wait_for`. No SSH. Timeouts:
`BOOT_TIMEOUT` (default 60), `BGP_TIMEOUT` (default 120), `EVPN_TIMEOUT`
(default 60), `WAIT_INTERVAL` (default 2). MAC addresses are read from the
hosts at run time, never hard-coded.

1. **Daemons up:** `wait_for $BOOT_TIMEOUT <r> "vtysh -c 'show version'" "FRRouting"` for all four routers.
2. **Underlay and overlay sessions:** for each router, `wait_for $BGP_TIMEOUT <r> "vtysh -c 'show bgp ipv4 unicast summary json' | grep -c '\"state\":\"Established\"'" "2"` and the same with `show bgp l2vpn evpn summary json`. Every router has exactly two fabric neighbours, so the count is the single line `2`. Then `expect_not_contains <r> "vtysh -c 'show bgp ipv4 unicast summary'" "Active"` and `"Connect"`.
3. **Loopback reachability and ECMP:** `wait_for $BGP_TIMEOUT leaf1 "vtysh -c 'show ip route 10.0.0.12/32' | grep -c ' eth[12]'" "2"`, then `expect_contains leaf1 "vtysh -c 'show ip route 10.0.0.12/32'" "Known via \"bgp\""`; mirrored on `leaf2` for `10.0.0.11/32`. Interface names are the only stable token in an unnumbered next hop, and the per-prefix view prints each next hop on its own line as `fe80::…, via eth1, weight 1` (the OSPF scenario already showed that the per-prefix format differs from the table view), so the count pattern is ` eth[12]`, which no other line of that output contains.
4. **VTEP discovery (type-3):** `wait_for $EVPN_TIMEOUT leaf1 "vtysh -c 'show evpn vni 10'" "10.0.0.12"` and `wait_for $EVPN_TIMEOUT leaf2 "vtysh -c 'show evpn vni 10'" "10.0.0.11"`.
5. **Reachability and MAC learning (type-2):** `H1_MAC=$(node_exec h1 "cat /sys/class/net/eth1/address")`, likewise `H2_MAC`. `wait_for 30 h1 "ping -c 3 -W 2 10.10.0.2" "3 received"` (the first ARP triggers learning, so this is retried). Then `wait_for $EVPN_TIMEOUT leaf2 "vtysh -c 'show evpn mac vni 10' | grep -i $H1_MAC" "10.0.0.11"` and `expect_contains leaf2 "vtysh -c 'show evpn mac vni 10' | grep -i $H1_MAC" "remote"`; mirrored on `leaf1` for `H2_MAC` and `10.0.0.12`. Also `expect_contains leaf1 "vtysh -c 'show evpn mac vni 10' | grep -i $H1_MAC" "local"` to show the local side of the same MAC.
6. **Spine failover:** install `trap 'node_exec leaf1 "ip link set eth1 up" >/dev/null 2>&1 || true' EXIT`; `node_exec leaf1 "ip link set eth1 down"`; `wait_for $BGP_TIMEOUT leaf1 "vtysh -c 'show ip route 10.0.0.12/32' | grep -c ' eth[12]'" "1"`; `expect_not_contains leaf1 "vtysh -c 'show ip route 10.0.0.12/32'" "eth1"`; `expect_contains leaf1 "vtysh -c 'show ip route 10.0.0.12/32'" "eth2"`; `expect_contains leaf1 "vtysh -c 'show evpn vni 10'" "10.0.0.12"`; `wait_for 30 h1 "ping -c 3 -W 2 10.10.0.2" "3 received"`. `spine1`'s session to `leaf1` is expected to go down and is not asserted on.
7. **Restore:** `node_exec leaf1 "ip link set eth1 up"`; `wait_for $BGP_TIMEOUT leaf1 "vtysh -c 'show ip route 10.0.0.12/32' | grep -c ' eth[12]'" "2"`; `wait_for 30 h1 "ping -c 3 -W 2 10.10.0.2" "3 received"`; `trap - EXIT`.
8. `log "all checks passed"`.

The ` eth[12]` next-hop count relies on FRR printing each next hop on its own
line in the per-prefix view (`fe80::…, via eth1, weight 1`); the stub answers
with that exact format so a format change on a live run shows up as a stub
update, not a guess.

## Tests (Docker-free, `tests/test_evpn_vxlan.sh`)

- `scenario.yml` validates; `status: draft`; one variant `frr`.
- Built topology: exactly 6 `linux` nodes, four FRR and two multitool; 6
  links; every `binds` source exists relative to the built file; the links
  table holds (`leaf1:eth1` ↔ `spine1:eth1`, `leaf1:eth2` ↔ `spine2:eth1`,
  `leaf2:eth1` ↔ `spine1:eth2`, `leaf2:eth2` ↔ `spine2:eth2`, `leaf1:eth3` ↔
  `h1:eth1`, `leaf2:eth3` ↔ `h2:eth1`).
- `exec` lists: all routers start with `ip route del default` and contain the
  `disable_ipv6=0` sysctl; leaves contain the `vxlan10` line with the right
  `local` address, `id 10`, `nolearning`, and bridge membership for both
  `vxlan10` and `eth3`; spines contain no `ip link` lines; hosts add the
  expected `/24` and set no default route.
- Config markers per router: `router bgp <asn>` with the expected
  `bgp router-id`; `neighbor fabric peer-group` and `remote-as external`;
  `neighbor eth1 interface peer-group fabric` and the same for `eth2`;
  `no bgp ebgp-requires-policy`; `no bgp default ipv4-unicast`;
  `address-family l2vpn evpn` on all four; `advertise-all-vni`, `vni 10`,
  and both `route-target … 65000:10` lines only on leaves; `ipv6 nd
  ra-interval` on `eth1` and `eth2` of every router; `daemons` has `bgpd=yes`
  and `ospfd=no` everywhere.
- End-to-end against a docker stub (`make_frr_stub ROOT MODE`) that answers
  `show version`, both `summary json` greps, `show ip route 10.0.0.12/32`
  and `10.0.0.11/32` (next hops depend on whether the stub has seen
  `ip link set eth1 down`), `show evpn vni 10`, `show evpn mac vni 10`
  (contents depend on whether a `ping` has been seen), `cat
  /sys/class/net/eth1/address` with distinct fixed MACs for `h1` and `h2`,
  and `ping`. Happy path passes and the stub log shows `ip link set eth1
  down` then `up`. Failure modes, each failing with the expected message:
  `bgp-active` (one session stays `Active` in the ipv4 summary), `evpn-down`
  (ipv4 sessions Established but the EVPN summary shows one session not
  Established), `no-vtep` (`show evpn vni 10` lists no remote VTEP),
  `mac-local-only` (h1's MAC never appears as `remote` on leaf2),
  `single-path` (the route has one next hop before the failover), and
  `no-failover` (after `eth1` goes down the route still lists `eth1`). In
  the `no-failover` case the stub log still ends with `ip link set eth1 up`
  (the trap fired).
- Docs test: the scenario README links
  `docs/diagrams/evpn-vxlan-leaf-spine.drawio`; `docs/conventions.md`
  contains a "Dataplane plumbing" heading.

## Documentation

- Scenario `README.md`: objective, ASCII diagram plus a link to
  `docs/diagrams/evpn-vxlan-leaf-spine.drawio`, node and link tables, a
  "Design" section covering unnumbered BGP over link-local, the shared spine
  AS, `advertise-all-vni`, the explicit route-targets and why auto-derived
  RTs would not match, `nolearning`, and why the hosts have no gateway; the
  eight verification steps; a failover walkthrough with the expected
  `show ip route 10.0.0.12/32`, `show evpn vni 10`, and `show evpn mac vni 10`
  output before and after; the validation commands; the `draft`→`ready` rule.
- `docs/diagrams/evpn-vxlan-leaf-spine.drawio`: Cisco 19 stencils like the
  existing two diagrams; spines in one row, leaves below, hosts below the
  leaves, the `leaf1:eth1` uplink drawn thick amber as the failed link, the
  VXLAN tunnel between leaf loopbacks dashed.
- `docs/conventions.md`: a short "Dataplane plumbing" section: Linux-level
  objects a scenario needs (bridges, VXLAN devices, VLAN subinterfaces,
  sysctls) live in the node's `exec:` list, after `ip route del default`;
  `verify.sh` must not assume ordering between `exec` and FRR startup and
  wraps dependent checks in `wait_for`; GNS3 and EVE-NG have no equivalent
  hook, so a scenario README lists the commands for manual entry.
- `docs/simulators/gns3.md` and `eve-ng.md`: one sentence under the existing
  derived-export notes stating that `exec:` plumbing is not carried over and
  pointing to the scenario README.
- `images/README.md`: no change.
- Exports: `none` for GNS3 and EVE-NG in `scenario.yml`, matching the OSPF
  scenario; the README's manual-plumbing note covers anyone who hand-ports it.

## Real-world validation

The scenario stays `status: draft` until this has passed once on a host with
Docker and containerlab (no vendor images needed):

```bash
scripts/up.sh evpn-vxlan-leaf-spine --force
scripts/verify.sh evpn-vxlan-leaf-spine
scripts/down.sh evpn-vxlan-leaf-spine
```

Known risks to confirm on that run, each with its fallback, recorded in the
README's validation section:

| Risk | Symptom | Fallback |
|---|---|---|
| IPv6 disabled on fabric veths despite the sysctl | BGP neighbours stay `Active`; `ip -6 addr show eth1` has no `fe80::` | Add per-interface `net.ipv6.conf.eth1.disable_ipv6=0` lines to `exec`. |
| Container lacks `NET_ADMIN` for `ip link add vxlan` | `exec` line fails in `containerlab deploy` output; no `vxlan10` | Add `privileged: true` (or the capability) to the leaf nodes in the topology. |
| Spines rewrite the EVPN next hop to themselves | `show bgp l2vpn evpn` on a leaf shows the spine loopback as next hop; no remote VTEP | Add `neighbor fabric next-hop-unchanged` under `address-family l2vpn evpn` on the spines. |
| Next-hop line format differs from `fe80::…, via eth1, weight 1` | Step 3 or 6 count check fails although `ip route` shows two paths | Adjust the grep pattern; the stub output is updated to the real format so the tests keep matching reality. |

The commit that flips `status` to `ready` records the FRR image tag and
containerlab version in the README.

## Out of scope

- Inter-VLAN routing: symmetric IRB, L3 VNI, anycast gateway, second VLAN.
  Natural follow-up scenario on top of this fabric.
- ARP suppression, multihoming (ESI), MLAG, BUM via multicast.
- Vendor variants (cEOS, SR Linux) and GNS3 / EVE-NG exports.
- IPv4-numbered or OSPF underlays.
