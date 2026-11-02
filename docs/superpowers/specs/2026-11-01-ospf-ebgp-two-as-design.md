# OSPF + eBGP two-AS scenario: design

Date: 2026-11-01
Status: approved for planning
Scenario: `scenarios/ospf-ebgp-two-as`

## Goal

The first free-image scenario: two autonomous systems, each a triangle of FRR
routers running single-area OSPF, joined by one eBGP session between their
border routers, with one Linux host per AS. `verify.sh` proves OSPF
adjacencies, the eBGP session and routes, end-to-end reachability, and that
OSPF reconverges around a failed intra-AS link while traffic keeps flowing.

It exercises the repository's default path (free images, `docker exec`
verification, no licences) and is the scenario most likely to be run first
against a real containerlab host.

## Decisions already made

| Topic | Decision |
|---|---|
| Shape | Two ASes, eBGP between them, OSPF inside each. Triangle per AS (six routers) so the failover is a real SPF path change through a third router. |
| Images | FRR only: `quay.io/frrouting/frr:10.1` for routers, `wbitt/network-multitool:latest` for hosts. Single variant `frr`. |
| Verification depth | Protocol state, routes, host↔host reachability, one intra-AS link failover with restore. |
| Failure injection | `ip link set <if> down` inside the router container (kernel carrier loss), restored under a `trap`. |
| Routing design | No OSPF↔BGP redistribution. Borders advertise their AS aggregate (`10.x.0.0/16`) into BGP and originate a default route into OSPF. Interiors are BGP-free. |

## Topology

```
   AS 65001 (OSPF area 0)                      AS 65002 (OSPF area 0)
   h1 ─ r1 ──── r2                              r5 ──── r6 ─ h2
         \      /                               /      /
          \    /                               /      /
           r3 ════════ eBGP ════════ r4 ──────
```

### Nodes

| Node | Kind / image | Role | Loopback (router-id) |
|---|---|---|---|
| `r1` | `linux` / FRR | AS 65001 interior, gateway for `h1` | 10.1.0.1/32 |
| `r2` | `linux` / FRR | AS 65001 interior (detour path) | 10.1.0.2/32 |
| `r3` | `linux` / FRR | AS 65001 border (eBGP) | 10.1.0.3/32 |
| `r4` | `linux` / FRR | AS 65002 border (eBGP) | 10.2.0.4/32 |
| `r5` | `linux` / FRR | AS 65002 interior (detour path) | 10.2.0.5/32 |
| `r6` | `linux` / FRR | AS 65002 interior, gateway for `h2` | 10.2.0.6/32 |
| `h1` | `linux` / multitool | host, 10.1.100.10/24, default via 10.1.100.1 | |
| `h2` | `linux` / multitool | host, 10.2.100.10/24, default via 10.2.100.1 | |

### Links and interface mapping

Interface names are given explicitly in every `endpoints:` entry, so the
mapping below is part of the topology, not derived from order.

| Link | Subnet | A side | B side |
|---|---|---|---|
| h1–r1 | 10.1.100.0/24 | `h1:eth1` .10 | `r1:eth1` .1 |
| r1–r3 (primary) | 10.1.13.0/30 | `r1:eth2` .1 | `r3:eth1` .2 |
| r1–r2 | 10.1.12.0/30 | `r1:eth3` .1 | `r2:eth1` .2 |
| r2–r3 | 10.1.23.0/30 | `r2:eth2` .1 | `r3:eth2` .2 |
| r3–r4 (eBGP) | 192.0.2.0/30 | `r3:eth3` .1 | `r4:eth1` .2 |
| r4–r6 (primary) | 10.2.46.0/30 | `r4:eth2` .1 | `r6:eth2` .2 |
| r4–r5 | 10.2.45.0/30 | `r4:eth3` .1 | `r5:eth1` .2 |
| r5–r6 | 10.2.56.0/30 | `r5:eth2` .1 | `r6:eth3` .2 |
| r6–h2 | 10.2.100.0/24 | `r6:eth1` .1 | `h2:eth1` .10 |

The six routers carry `exec: ip route del default` (see Routing design).

Nine links, no bridge node. Hosts get their address and default route via
`exec:` lines in the topology, as in the ASA scenario.

## Routing design

### OSPF (per AS, area 0)

- Every router link and the loopback are in area 0; all router-to-router links
  are `ip ospf network point-to-point` (no DR election, deterministic
  adjacency output).
- Host LANs (`r1:eth1`, `r6:eth1`) are in area 0 but `passive-interface`.
- Costs: the primary links `r1–r3` and `r4–r6` cost 10; `r1–r2`, `r2–r3`,
  `r4–r5`, `r5–r6` also cost 10, so the detour costs 20 and is used only when
  the primary is down.
- Borders run `default-information originate always` so interiors learn
  0.0.0.0/0 toward the border (`r3` in AS 65001, `r4` in AS 65002).

- Containerlab installs a management default route in every node; zebra
  imports it as a kernel route (distance 0) that outranks the OSPF default
  (distance 110). The routers delete it at startup with `exec: ip route del
  default`; `docker exec` management access is unaffected.

### BGP

- `r3`: `router bgp 65001`, `neighbor 192.0.2.2 remote-as 65002`,
  `network 10.1.0.0/16`, with `ip route 10.1.0.0/16 Null0` so the aggregate is
  in the RIB. Address-family `ipv4 unicast` activates the neighbor.
- `r4`: mirror image with 65002, `neighbor 192.0.2.1 remote-as 65001`,
  `network 10.2.0.0/16`, `ip route 10.2.0.0/16 Null0`.
- No route-maps or filters in this scenario (route policy is a candidate
  follow-up).

### Traffic path

`h1 → r1 → r3 → r4 → r6 → h2` normally. With `r1:eth2` down:
`h1 → r1 → r2 → r3 → r4 → r6 → h2`. The eBGP session and the AS 65002 side are
unaffected by the failover.

### FRR daemons

Routers enable `zebra`, `ospfd`, `staticd`, and `bgpd` on `r3`/`r4` only.
Configs are integrated `frr.conf` files bind-mounted to `/etc/frr/frr.conf`
with a `daemons` file per router, following the template.

## Verification

Uses only the existing helpers over `docker exec`: `node_exec`,
`expect_contains`, `expect_not_contains`, `wait_for`. No `ASA_NODES`, no SSH.
Timeouts: `OSPF_TIMEOUT` (default 90), `BGP_TIMEOUT` (default 120),
`BOOT_TIMEOUT` (default 60).

1. **Daemons up:** `wait_for $BOOT_TIMEOUT <r> "vtysh -c 'show version'" "FRRouting"` for r1–r6.
2. **OSPF adjacencies:** for each router, `wait_for $OSPF_TIMEOUT <r> "vtysh -c 'show ip ospf neighbor'" "<neighbour router-id>"` for each of its two expected neighbours (r1: 10.1.0.2 and 10.1.0.3; r2: 10.1.0.1, 10.1.0.3; r3: 10.1.0.1, 10.1.0.2; r4: 10.2.0.5, 10.2.0.6; r5: 10.2.0.4, 10.2.0.6; r6: 10.2.0.4, 10.2.0.5), then `wait_for $OSPF_TIMEOUT <r> "vtysh -c 'show ip ospf neighbor' | grep -c Full" "2"` and `expect_not_contains <r> "vtysh -c 'show ip ospf neighbor'" "ExStart"` / `"Exchange"` / `"Loading"` / `"Init"`. (Every router has exactly two OSPF neighbours, so `grep -c Full` prints the single line `2`.)
3. **eBGP:** `wait_for $BGP_TIMEOUT r3 "vtysh -c 'show bgp neighbors 192.0.2.2 json' | grep -o '\"bgpState\":\"[A-Za-z]*\"'" "Established"` and the same on r4 for 192.0.2.1. Then `expect_contains r3 "vtysh -c 'show ip route bgp'" "10.2.0.0/16"` and `expect_contains r4 "vtysh -c 'show ip route bgp'" "10.1.0.0/16"`.
4. **Default route on interiors:** `expect_contains <r> "vtysh -c 'show ip route ospf'" "O>* 0.0.0.0/0"` for r1, r2, r5, r6. The `>*` (selected, installed) is required: an unselected `O   0.0.0.0/0` appears when the kernel management default (`K>*`, distance 0) was not removed.
5. **End-to-end and path:** `expect_contains h1 "ping -c 5 -W 2 10.2.100.10" "5 received"`; `expect_contains h2 "ping -c 5 -W 2 10.1.100.10" "5 received"`; `expect_contains h1 "traceroute -n -w 1 -q 1 -m 8 10.2.100.10" "10.1.13.2"` (primary path via r3's `eth1`) and `expect_not_contains ... "10.1.12.2"`.
6. **Failover:** install `trap 'node_exec r1 "ip link set eth2 up" >/dev/null 2>&1 || true' EXIT`; `node_exec r1 "ip link set eth2 down"`; `wait_for $OSPF_TIMEOUT r1 "vtysh -c 'show ip route 10.1.0.3/32'" "via 10.1.12.2"`; `expect_contains h1 "ping -c 5 -W 2 10.2.100.10" "5 received"`; `expect_contains h1 "traceroute -n -w 1 -q 1 -m 8 10.2.100.10" "10.1.12.2"` and `expect_not_contains ... "10.1.13.2"`.
7. **Restore:** `node_exec r1 "ip link set eth2 up"`; `wait_for $OSPF_TIMEOUT r1 "vtysh -c 'show ip route 10.1.0.3/32'" "via 10.1.13.2"`; `expect_contains h1 "ping -c 5 -W 2 10.2.100.10" "5 received"`; `trap - EXIT`.
8. `log "all checks passed"`.

The `trap` in step 6 guarantees the link is restored even if a check in step 6
fails, so a failed verification does not leave the lab degraded.

## Tests (Docker-free, `tests/test_ospf_ebgp.sh`)

- `scenario.yml` validates; `status: draft`; one variant `frr`.
- Built topology: exactly 8 `linux` nodes, six with the FRR image and two with
  multitool; 9 links; every `binds` source exists relative to the built file;
  the endpoints table above holds (`r1:eth2` is linked to `r3:eth1`, etc.).
- Config markers per router: `router ospf` with the expected `ospf router-id`;
  each router link interface carries `ip ospf area 0` and
  `ip ospf network point-to-point`; `passive-interface eth1` on r1 and r6;
  `default-information originate always` only on r3 and r4; `router bgp 65001`
  with `neighbor 192.0.2.2 remote-as 65002` and `network 10.1.0.0/16` only on
  r3, the 65002 mirror only on r4; `ip route 10.x.0.0/16 Null0` on borders
  only; `daemons` has `bgpd=yes` on r3/r4 and `bgpd=no` elsewhere, `ospfd=yes`
  everywhere.
- Addressing: each router's `frr.conf` carries the interface addresses from the
  links table (a test derives the expected `ip address` lines from a small
  table in the test file and greps for each).
- End-to-end against a docker stub (`make_frr_stub ROOT MODE`) answering
  `show version`, `show ip ospf neighbor` (two `Full` lines naming the
  expected neighbour router-ids), the BGP json
  grep, `show ip route bgp/ospf`, `show ip route 10.1.0.3/32` (whose next hop
  depends on whether the stub has seen `ip link set eth2 down`), `ping`, and
  `traceroute` (path likewise depends on link state): happy path passes and
  logs `ip link set eth2 down` then `up`; modes `ospf-stuck` (one neighbour
  never Full), `bgp-active` (bgpState Active), `no-reroute` (route stays via
  10.1.13.2 after the link goes down) each fail with the expected message;
  and in the `no-reroute` case the stub log still ends with
  `ip link set eth2 up` (the trap fired).

## Documentation

- Scenario `README.md`: objective, diagram, node and link tables, the routing
  design and why (aggregate + default rather than redistribution), the
  failover walkthrough with the expected `show ip route` and traceroute output,
  the validation commands, and the `draft`→`ready` rule.
- `docs/conventions.md`: a short "Failure injection" paragraph describing the
  restore-under-`trap` pattern for scenarios that break links.
- `images/README.md`: no change (FRR and multitool are already listed).
- Exports: `none` for GNS3 and EVE-NG.

## Real-world validation

The scenario stays `status: draft` until this has passed once on a host with
Docker and containerlab (no vendor images needed):

```bash
scripts/up.sh ospf-ebgp-two-as --force
scripts/verify.sh ospf-ebgp-two-as
scripts/down.sh ospf-ebgp-two-as
```

The commit that flips `status` to `ready` records the FRR image tag and
containerlab version in the README.

## Out of scope

- BGP route policy (prefix-lists, route-maps, prepending): candidate next
  scenario on top of this one.
- Dual eBGP / BGP failover, IPv6, OSPF multi-area or stub areas, iBGP.
- Vendor variants.
- GNS3 / EVE-NG exports.
