# ospf-ebgp-two-as

## Objective

Two autonomous systems, each a triangle of FRR routers in single-area OSPF,
joined by one eBGP session between their border routers. One Linux host per AS
proves end-to-end reachability, and the verification takes down an intra-AS
link to show OSPF reconverging around it while traffic keeps flowing. Free
images only: this is the scenario to run first on a new containerlab host.

## Topology

```
   AS 65001 (OSPF area 0)                      AS 65002 (OSPF area 0)
   h1 ─ r1 ──── r2                              r5 ──── r6 ─ h2
         \      /                               /      /
          \    /                               /      /
           r3 ════════ eBGP ════════ r4 ──────
```

| Node | Role | Loopback / router-id |
|---|---|---|
| `r1` | AS 65001 interior, gateway for `h1` (10.1.100.0/24) | 10.1.0.1 |
| `r2` | AS 65001 interior, detour path | 10.1.0.2 |
| `r3` | AS 65001 border, eBGP to r4 | 10.1.0.3 |
| `r4` | AS 65002 border, eBGP to r3 | 10.2.0.4 |
| `r5` | AS 65002 interior, detour path | 10.2.0.5 |
| `r6` | AS 65002 interior, gateway for `h2` (10.2.100.0/24) | 10.2.0.6 |

| Link | Subnet | Endpoints |
|---|---|---|
| h1–r1 | 10.1.100.0/24 | `h1:eth1` .10, `r1:eth1` .1 |
| r1–r3 (primary) | 10.1.13.0/30 | `r1:eth2` .1, `r3:eth1` .2 |
| r1–r2 | 10.1.12.0/30 | `r1:eth3` .1, `r2:eth1` .2 |
| r2–r3 | 10.1.23.0/30 | `r2:eth2` .1, `r3:eth2` .2 |
| r3–r4 (eBGP) | 192.0.2.0/30 | `r3:eth3` .1, `r4:eth1` .2 |
| r4–r6 (primary) | 10.2.46.0/30 | `r4:eth2` .1, `r6:eth2` .2 |
| r4–r5 | 10.2.45.0/30 | `r4:eth3` .1, `r5:eth1` .2 |
| r5–r6 | 10.2.56.0/30 | `r5:eth2` .1, `r6:eth3` .2 |
| r6–h2 | 10.2.100.0/24 | `r6:eth1` .1, `h2:eth1` .10 |

Interface names are fixed in `topology.clab.yml`, so `r1:eth2` is always the
r1–r3 primary link that the failover test takes down.

## Routing design

- **OSPF area 0 per AS.** All router links are point-to-point with cost 10, so
  the direct r1–r3 path (cost 10) beats the detour r1–r2–r3 (cost 20) until the
  direct link fails. Loopbacks are in area 0; the host LANs are passive.
- **eBGP between the borders only.** r3 and r4 each advertise their AS
  aggregate (`network 10.x.0.0/16`, backed by `ip route 10.x.0.0/16 Null0`).
  FRR requires `no bgp ebgp-requires-policy` to exchange eBGP routes without a
  route-map; this lab has no policy, so the line is set on both borders.
- **No redistribution.** Interiors are BGP-free: each border runs
  `default-information originate always`, so r1/r2 (and r5/r6) reach the other
  AS via a default route toward their border. Aggregate-plus-default keeps the
  configs short and mirrors a common enterprise edge design.

Normal path h1 → h2: `r1 → r3 → r4 → r6`. With r1–r3 down: `r1 → r2 → r3 → r4 → r6`.

## Tasks

1. `scripts/up.sh ospf-ebgp-two-as --force` (`--force` while the scenario is `draft`).
2. Wait a minute for OSPF and BGP to converge, then run the verification.
3. Inspect: `docker exec clab-ospf-ebgp-two-as-r3 vtysh -c 'show bgp summary'`,
   `docker exec clab-ospf-ebgp-two-as-r1 vtysh -c 'show ip ospf neighbor'`.

## Verification

`scripts/verify.sh ospf-ebgp-two-as` checks, in order:

1. FRR answers `show version` on all six routers.
2. Every router has exactly its two expected OSPF neighbours in `Full`, none stuck in Init/ExStart/Exchange/Loading.
3. The eBGP session r3↔r4 is `Established`; r3 has `10.2.0.0/16` via BGP and r4 has `10.1.0.0/16`.
4. r1, r2, r5, r6 have an OSPF default route.
5. h1 ↔ h2 pings succeed; h1's traceroute to h2 goes through `10.1.13.2` (r3 via the primary link) and not `10.1.12.2`.
6. **Failover:** `ip link set eth2 down` on r1. r1's route to r3's loopback (read with `show ip route ospf | grep 10.1.0.3/32`) moves to `via 10.1.12.2`, pings still succeed, and the traceroute now shows `10.1.12.2` and not `10.1.13.2`. The link is restored by an EXIT `trap` if any of these checks fails, so a failed run never leaves the lab degraded.
7. **Restore:** the link comes back up (the `trap` is cleared once the explicit restore has run), the route returns to `via 10.1.13.2`, and a final ping succeeds.

The host pings in steps 5–7 are retried for up to 30 s (`wait_for 30`), so a single lost packet right after reconvergence does not fail the run.

Timeouts: `BOOT_TIMEOUT` (60 s), `OSPF_TIMEOUT` (90 s), `BGP_TIMEOUT` (120 s), and `WAIT_INTERVAL` (2 s) can be overridden in the environment.

## Failover walkthrough

Before the failover, on r1:

```
r1# show ip route ospf | include 10.1.0.3/32
O>* 10.1.0.3/32 [110/10] via 10.1.13.2, eth2, weight 1, 00:10:00
```

After `ip link set eth2 down` on r1, OSPF reconverges and the same route
points through r2:

```
r1# show ip route ospf | include 10.1.0.3/32
O>* 10.1.0.3/32 [110/20] via 10.1.12.2, eth3, weight 1, 00:00:05
```

h1's traceroute to 10.2.100.10 correspondingly changes its second hop from
`10.1.13.2` to `10.1.12.2` (and gains a `10.1.23.2` hop). Bringing `eth2` back
restores the original route.

## Validation on a containerlab host

CI cannot run containerlab, so this scenario stays `status: draft` until the
following has passed once on a host with Docker and containerlab (no vendor
images needed):

```bash
scripts/up.sh ospf-ebgp-two-as --force
scripts/verify.sh ospf-ebgp-two-as || echo "FAIL"
scripts/down.sh ospf-ebgp-two-as
```

The commit that flips `status` to `ready` records the versions used:

- FRR image: not yet validated
- containerlab version: not yet validated

## Simulators

| Simulator | Status |
|---|---|
| Containerlab | native |
| GNS3 | none yet (FRR Docker template; see `docs/simulators/gns3.md`) |
| EVE-NG | none yet (`docker` node; see `docs/simulators/eve-ng.md`) |

## Teardown

`scripts/down.sh ospf-ebgp-two-as`
