# evpn-vxlan-leaf-spine

## Objective

A minimal datacenter fabric: two spines and two leaves running FRR with an
eBGP-unnumbered underlay and a BGP EVPN overlay. One Linux host hangs off each
leaf in the same VLAN, stretched between the leaves over VXLAN (VNI 10). The
verification proves the BGP sessions in both address families, ECMP across the
spines, VTEP discovery and MAC learning through EVPN, host reachability, and
that traffic survives the loss of a leaf's uplink to one spine. Free images
only.

## Topology

```
      spine1 (AS 65100, 10.0.0.1)        spine2 (AS 65100, 10.0.0.2)
        eth1          eth2                 eth1          eth2
         |              |                   |              |
         |              +-------------------|---------+    |
         |                                  |         |    |
         |     +----------------------------+         |    |
         |     |                                      |    |
        eth1  eth2                                   eth1  eth2
      leaf1 (AS 65001, VTEP 10.0.0.11)           leaf2 (AS 65002, VTEP 10.0.0.12)
        eth3                                           eth3
         |                                              |
        h1 10.10.0.1/24                                h2 10.10.0.2/24

      leaf1:eth1 -> spine1:eth1   leaf1:eth2 -> spine2:eth1
      leaf2:eth1 -> spine1:eth2   leaf2:eth2 -> spine2:eth2
      VLAN 10 stretched between the leaves over VXLAN VNI 10
```

A draw.io version of this topology lives at
[`docs/diagrams/evpn-vxlan-leaf-spine.drawio`](../../docs/diagrams/evpn-vxlan-leaf-spine.drawio)
(open with diagrams.net or import into Visio).

| Node | Role | Loopback (router-id, VTEP IP) | ASN |
|---|---|---|---|
| `spine1` | spine, relays EVPN routes | 10.0.0.1 | 65100 |
| `spine2` | spine, relays EVPN routes | 10.0.0.2 | 65100 |
| `leaf1` | leaf, VTEP for `h1` | 10.0.0.11 | 65001 |
| `leaf2` | leaf, VTEP for `h2` | 10.0.0.12 | 65002 |
| `h1` | host in VLAN 10, 10.10.0.1/24, no gateway | | |
| `h2` | host in VLAN 10, 10.10.0.2/24, no gateway | | |

| Link | Addressing | Endpoints |
|---|---|---|
| leaf1–spine1 | unnumbered (IPv6 link-local) | `leaf1:eth1`, `spine1:eth1` |
| leaf1–spine2 | unnumbered | `leaf1:eth2`, `spine2:eth1` |
| leaf2–spine1 | unnumbered | `leaf2:eth1`, `spine1:eth2` |
| leaf2–spine2 | unnumbered | `leaf2:eth2`, `spine2:eth2` |
| leaf1–h1 | VLAN 10 access port | `leaf1:eth3` (bridge member), `h1:eth1` |
| leaf2–h2 | VLAN 10 access port | `leaf2:eth3` (bridge member), `h2:eth1` |

Interface names are fixed in `topology.clab.yml`, so `leaf1:eth1` is always the
uplink to `spine1` that the failover test takes down.

## Design

- **Unnumbered eBGP underlay.** Fabric links carry no IPv4 address. Each router
  sends IPv6 router advertisements on `eth1` and `eth2` (`no ipv6 nd
  suppress-ra`, `ipv6 nd ra-interval 10`) and peers with `neighbor ethN
  interface peer-group fabric`, so BGP runs over the link-local address it
  learns from the other end. `redistribute connected` is what puts each
  loopback into the underlay. It also carries the management subnet
  (containerlab's 172.20.20.0/24 on `eth0`) into the fabric, which is harmless
  because the connected route wins on every router; a production design would
  filter it with a prefix-list route-map. `no bgp ebgp-requires-policy` is needed because
  FRR refuses to exchange eBGP routes without it or a route-map.
- **One AS for both spines, one AS per leaf.** A leaf sees the same AS path
  (`65100 650xx`) to the other leaf's loopback through either spine, so both
  paths install as ECMP next hops. `bgp bestpath as-path multipath-relax` is
  not required for identical paths but is the conventional line in such a
  fabric.
- **EVPN on the same sessions.** The `l2vpn evpn` address family is activated
  for the `fabric` peer-group everywhere. Leaves add `advertise-all-vni`, which
  makes FRR originate a type-3 route for every VXLAN device it finds in the
  kernel and a type-2 route for every local MAC in the bridge. Spines only
  relay.
- **Explicit route-targets.** FRR auto-derives the route-target as
  `<ASN>:<VNI>`. With a different AS per leaf the auto-derived values
  (`65001:10` and `65002:10`) never match and leaf2 would silently discard
  leaf1's routes, so both leaves pin `route-target import 65000:10` and
  `route-target export 65000:10` under `vni 10`.
- **Linux dataplane from `exec:`.** Each leaf creates bridge `br10`, the VXLAN
  device `vxlan10` (`id 10`, `local <loopback>`, `dstport 4789`,
  `nolearning`), enslaves `vxlan10` and the host-facing `eth3` to the bridge,
  turns bridge-port learning off on `vxlan10` (`bridge link set dev vxlan10
  learning off`), and brings them up. `nolearning` turns off learning in the
  VXLAN FDB and the bridge-port setting turns off learning on the `vxlan10`
  port, so remote MACs come only from EVPN, which is what
  makes `show evpn mac vni 10` a meaningful test. `eth3` is an untagged
  access port, so the hosts need no VLAN awareness.
- **Hosts have no gateway.** This scenario proves L2 extension only: `h1` and
  `h2` share 10.10.0.0/24 and the ping is a same-subnet ping. Inter-VLAN
  routing (symmetric IRB) is a follow-up scenario.

Routers delete the containerlab management default route at startup (see
`docs/conventions.md`) and enable IPv6 on all interfaces with `sysctl`, which
BGP unnumbered depends on.

## Tasks

1. `scripts/up.sh evpn-vxlan-leaf-spine --force` (`--force` while the scenario is `draft`).
2. Wait a minute for BGP to converge, then run the verification.
3. Inspect: `docker exec clab-evpn-vxlan-leaf-spine-leaf1 vtysh -c 'show bgp summary'`,
   `docker exec clab-evpn-vxlan-leaf-spine-leaf1 vtysh -c 'show evpn vni 10'`,
   `docker exec clab-evpn-vxlan-leaf-spine-leaf1 vtysh -c 'show evpn mac vni 10'`,
   `docker exec clab-evpn-vxlan-leaf-spine-leaf1 bridge fdb show br br10`.

## Verification

`scripts/verify.sh evpn-vxlan-leaf-spine` checks, in order:

1. FRR answers `show version` on all four routers.
2. Every router has two `Established` fabric neighbours in both `ipv4 unicast` and `l2vpn evpn` (counted from the JSON summaries), and none in `Active` or `Connect`.
3. `leaf1` reaches `10.0.0.12/32` by BGP with two next hops (`eth1` and `eth2`); `leaf2` reaches `10.0.0.11/32` the same way. Next hops are counted as ` eth[12]` tokens in `show ip route <prefix>`, since the per-prefix view prints `fe80::…, via eth1, weight 1` per path.
4. **VTEP discovery:** `show evpn vni 10` on each leaf lists the other leaf's loopback as a remote VTEP (type-3 route).
5. **Reachability and MAC learning:** host MACs are read from `/sys/class/net/eth1/address`; `h1` pings `h2` (retried up to 30 s, since the first ARP triggers learning); `leaf2` then shows `h1`'s MAC as `remote` via `10.0.0.11`, `leaf1` shows it as `local`, and `leaf1` shows `h2`'s MAC as `remote` via `10.0.0.12` (type-2 routes).
6. **Failover:** `ip link set eth1 down` on `leaf1`. The route to `10.0.0.12/32` drops to one next hop (`eth2` only), the remote VTEP is still listed, and `h1` still pings `h2`. The link is restored by an EXIT `trap` if any check fails, so a failed run never leaves the lab degraded.
7. **Restore:** the link comes back up (the `trap` is cleared once the explicit restore has run), the route regains both next hops, and a final ping succeeds.

Timeouts: `BOOT_TIMEOUT` (60 s), `BGP_TIMEOUT` (120 s), `EVPN_TIMEOUT` (60 s), and `WAIT_INTERVAL` (2 s) can be overridden in the environment.

## Failover walkthrough

Before the failover, on `leaf1`:

```
leaf1# show ip route 10.0.0.12/32
Routing entry for 10.0.0.12/32
  Known via "bgp", distance 20, metric 0, best
  Last update 00:10:00 ago
  * fe80::a8c1:abff:fe00:1, via eth1, weight 1
  * fe80::a8c1:abff:fe00:2, via eth2, weight 1

leaf1# show evpn vni 10
VNI: 10
 Type: L2
 VxLAN interface: vxlan10
 Local VTEP IP: 10.0.0.11
 Remote VTEPs for this VNI:
  10.0.0.12 flood: HER

leaf1# show evpn mac vni 10
MAC               Type   Flags Intf/Remote ES/VTEP VLAN  Seq #'s
aa:c1:ab:00:00:01 local        eth3                      0/0
aa:c1:ab:00:00:02 remote       10.0.0.12                 0/0
```

After `ip link set eth1 down` on `leaf1`, the session to `spine1` drops and
the underlay route keeps only the `spine2` path:

```
leaf1# show ip route 10.0.0.12/32
Routing entry for 10.0.0.12/32
  Known via "bgp", distance 20, metric 0, best
  Last update 00:00:05 ago
  * fe80::a8c1:abff:fe00:2, via eth2, weight 1
```

The VXLAN tunnel endpoint does not change, so `show evpn vni 10` and
`show evpn mac vni 10` look exactly as before: only the underlay path moved.
Bringing `eth1` back restores the second next hop.

## Validation on a containerlab host

CI cannot run containerlab, so this scenario stays `status: draft` until the
following has passed once on a host with Docker and containerlab (no vendor
images needed):

```bash
scripts/up.sh evpn-vxlan-leaf-spine --force
scripts/verify.sh evpn-vxlan-leaf-spine || echo "FAIL"
scripts/down.sh evpn-vxlan-leaf-spine
```

The multitool `ping` must be the iputils one (it prints `N received`); BusyBox ping prints `N packets received` and would fail step 5.

Known risks to confirm on that run, each with its fallback:

| Risk | Symptom | Fallback |
|---|---|---|
| IPv6 disabled on fabric veths despite the sysctl | BGP neighbours stay `Active`; `ip -6 addr show eth1` has no `fe80::` | Add per-interface `net.ipv6.conf.eth1.disable_ipv6=0` lines to `exec:`. |
| Container lacks `NET_ADMIN` for `ip link add vxlan` | `exec` line fails in `containerlab deploy` output; no `vxlan10` | Add `privileged: true` (or the capability) to the leaf nodes in the topology. |
| Spines rewrite the EVPN next hop to themselves | `show bgp l2vpn evpn` on a leaf shows the spine loopback as next hop; no remote VTEP | Add `neighbor fabric attribute-unchanged next-hop` under `address-family l2vpn evpn` on the spines (not expected: FRR keeps the EVPN next hop on eBGP by default). |
| Next-hop line format differs from `fe80::…, via eth1, weight 1` | Step 3 or 6 count check fails although `ip route` shows two paths | Adjust the grep pattern in `verify.sh` and the stub in `tests/test_evpn_vxlan.sh` to the real format. |
| `exec:` runs before the veths exist, or `/proc/sys` is read-only on a non-privileged node | `Cannot find device eth3` or `sysctl: Read-only file system` in the deploy log | Confirm containerlab runs `linux` nodes privileged and runs `exec:` after link creation; otherwise add `privileged: true` to the nodes. |
| Host kernel lacks the `vxlan` or `bridge` module (containers cannot modprobe) | `ip link add vxlan10` fails with `Unknown device type` | `modprobe vxlan bridge` on the host before deploy. |
| MTU: `vxlan10` defaults to 1450 while the veths are larger | Small pings work; large frames are dropped at `br10` | Set `mtu 1450` on the hosts' `eth1`, or raise the VXLAN MTU. |
| Slow initial BGP convergence with `frr defaults traditional` (connect-retry 120 s) | Step 2 times out on a slow host | Raise `BGP_TIMEOUT`, or switch the configs to `frr defaults datacenter`. |

The commit that flips `status` to `ready` records the versions used:

- FRR image: not yet validated
- containerlab version: not yet validated

## Simulators

| Simulator | Status |
|---|---|
| Containerlab | native |
| GNS3 | none yet (FRR Docker template; see `docs/simulators/gns3.md`) |
| EVE-NG | none yet (`docker` node; see `docs/simulators/eve-ng.md`) |

Neither GNS3 nor EVE-NG has an equivalent of the `exec:` list. Anyone porting
this scenario by hand runs the leaf plumbing in each leaf's console:

```
ip route del default
sysctl -qw net.ipv6.conf.all.disable_ipv6=0
sysctl -qw net.ipv6.conf.default.disable_ipv6=0
ip link add br10 type bridge
ip link add vxlan10 type vxlan id 10 local 10.0.0.11 dstport 4789 nolearning   # 10.0.0.12 on leaf2
ip link set vxlan10 master br10
bridge link set dev vxlan10 learning off
ip link set eth3 master br10
ip link set br10 up
ip link set vxlan10 up
ip link set eth3 up
```

## Teardown

`scripts/down.sh evpn-vxlan-leaf-spine`
