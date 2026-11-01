# OSPF + eBGP Two-AS Scenario Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `scenarios/ospf-ebgp-two-as`: six FRR routers in two OSPF triangles joined by one eBGP session, one host per AS, with a `verify.sh` that proves adjacencies, BGP, reachability and an intra-AS link failover, plus Docker-free tests and docs.

**Architecture:** Follows the repository scenario contract (`scenario.yml`, `topology.clab.yml`, `configs/<node>/`, `verify.sh`). Routers are `linux` kind FRR containers with bind-mounted `frr.conf`/`daemons`; hosts are `linux` multitool containers configured via `exec:`. Verification uses only the existing `docker exec` helpers (`node_exec`, `expect_contains`, `expect_not_contains`, `wait_for`); the failover is injected with `ip link set eth2 down` on `r1` and restored under an EXIT `trap`. Tests stub `docker` through `DOCKER` with a stateful stub that tracks the link state.

**Tech Stack:** bash 5, mikefarah `yq` v4, `shellcheck`, FRR 10.1 (`quay.io/frrouting/frr:10.1`), `wbitt/network-multitool:latest`, containerlab (runtime only).

Spec: `docs/superpowers/specs/2026-11-01-ospf-ebgp-two-as-design.md`

## Global Constraints

- Every script: `#!/usr/bin/env bash`, `set -euo pipefail`; `scripts/lib.sh` is sourced, not executed. Start every Bash call with `export PATH="$HOME/.local/bin:$PATH"` (yq v4.44.3, shellcheck 0.10.0 live there).
- Tests never need Docker or containerlab; inject stubs via `DOCKER`.
- Scenario name `ospf-ebgp-two-as`, topic `routing/ospf-bgp`, `status: draft`, single variant `frr` with `images.router: quay.io/frrouting/frr:10.1`, `images.host: wbitt/network-multitool:latest`; exports `none`.
- Nodes: `r1`–`r6` (`linux`, FRR image, binds `configs/<r>/frr.conf:/etc/frr/frr.conf` and `configs/<r>/daemons:/etc/frr/daemons`), `h1`, `h2` (`linux`, multitool).
- Loopbacks / router-ids: r1 10.1.0.1, r2 10.1.0.2, r3 10.1.0.3, r4 10.2.0.4, r5 10.2.0.5, r6 10.2.0.6 (all /32).
- Links and addresses (explicit interface names in `endpoints:`):
  - `h1:eth1` 10.1.100.10/24 ↔ `r1:eth1` 10.1.100.1/24
  - `r1:eth2` 10.1.13.1/30 ↔ `r3:eth1` 10.1.13.2/30 (primary, failover target)
  - `r1:eth3` 10.1.12.1/30 ↔ `r2:eth1` 10.1.12.2/30
  - `r2:eth2` 10.1.23.1/30 ↔ `r3:eth2` 10.1.23.2/30
  - `r3:eth3` 192.0.2.1/30 ↔ `r4:eth1` 192.0.2.2/30 (eBGP)
  - `r4:eth2` 10.2.46.1/30 ↔ `r6:eth2` 10.2.46.2/30 (primary)
  - `r4:eth3` 10.2.45.1/30 ↔ `r5:eth1` 10.2.45.2/30
  - `r5:eth2` 10.2.56.1/30 ↔ `r6:eth3` 10.2.56.2/30
  - `r6:eth1` 10.2.100.1/24 ↔ `h2:eth1` 10.2.100.10/24
- OSPF area 0 in each AS; all router-router links `ip ospf network point-to-point` and `ip ospf cost 10`; loopbacks in area 0; host LAN interfaces passive (`passive-interface eth1` under `router ospf` on r1 and r6); `default-information originate always` only on r3 and r4. The eBGP link interface is NOT in OSPF.
- BGP: r3 `router bgp 65001`, `neighbor 192.0.2.2 remote-as 65002`, `network 10.1.0.0/16`, `ip route 10.1.0.0/16 Null0`; r4 mirror with 65002 / `neighbor 192.0.2.1 remote-as 65001` / `network 10.2.0.0/16` / `ip route 10.2.0.0/16 Null0`. Both borders set `no bgp ebgp-requires-policy` (FRR refuses to exchange eBGP routes without it or a policy). No route-maps.
- `daemons`: `zebra=yes`, `ospfd=yes`, `staticd=yes`, `bgpd=yes` only on r3 and r4 (`bgpd=no` elsewhere), rest `no`; include `vtysh_enable=yes` and the `*_options` lines from the template.
- Hosts: `exec:` `ip addr add 10.N.100.10/24 dev eth1` and `ip route replace default via 10.N.100.1`.
- Verification env knobs: `BOOT_TIMEOUT` (60), `OSPF_TIMEOUT` (90), `BGP_TIMEOUT` (120). `WAIT_INTERVAL` is lib.sh's existing knob.
- Container names are `clab-ospf-ebgp-two-as-<node>`.
- Commit after every task with a conventional prefix, ending with the attribution lines the harness provides. No model identifiers in committed content.
- Work on branch `ccr-00157a22-qiys9w` (restarted from `main`; draft PR #4 tracks it).

---

## File map

| Path | Responsibility |
|---|---|
| `scenarios/ospf-ebgp-two-as/scenario.yml` | metadata |
| `scenarios/ospf-ebgp-two-as/topology.clab.yml` | 8 nodes, 9 links, host exec |
| `scenarios/ospf-ebgp-two-as/configs/r{1..6}/{frr.conf,daemons}` | router configs |
| `scenarios/ospf-ebgp-two-as/verify.sh` | checks incl. failover |
| `scenarios/ospf-ebgp-two-as/README.md` | docs |
| `scenarios/ospf-ebgp-two-as/export/{gns3,eve-ng}/.gitkeep` | empty export dirs |
| `tests/test_ospf_ebgp.sh` | structure, config, end-to-end stub tests |
| `tests/test_docs.sh` | conventions assertion |
| `docs/conventions.md` | "Failure injection" paragraph |

---

### Task 1: Scenario skeleton and structure tests

**Files:**
- Create: `scenarios/ospf-ebgp-two-as/scenario.yml`, `topology.clab.yml`, `verify.sh` (placeholder), `README.md` (stub), `export/gns3/.gitkeep`, `export/eve-ng/.gitkeep`
- Create: `tests/test_ospf_ebgp.sh`

**Interfaces:**
- Consumes: `validate_scenario_yml DIR`, `meta DIR PATH`, `build_topology DIR VARIANT` from `scripts/lib.sh`; `tests/helpers.sh`.
- Produces: `SCN`, `built` (echoes the built topology path), `cleanup_built`, and the `LINKS` table used by later tasks' tests.

- [ ] **Step 1: Write failing tests**

`tests/test_ospf_ebgp.sh`:
```bash
#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

SCN="$REPO_ROOT/scenarios/ospf-ebgp-two-as"
ROUTERS="r1 r2 r3 r4 r5 r6"

built() { build_topology "$SCN" frr; }
cleanup_built() { rm -f "$SCN"/.*.build.clab.yml; }
# helpers.sh already installs an EXIT trap; extend it rather than replace it.
trap '_cleanup_tmpdirs; cleanup_built' EXIT

# Link table: "A_endpoint A_addr B_endpoint B_addr"
LINKS="
h1:eth1 10.1.100.10/24 r1:eth1 10.1.100.1/24
r1:eth2 10.1.13.1/30 r3:eth1 10.1.13.2/30
r1:eth3 10.1.12.1/30 r2:eth1 10.1.12.2/30
r2:eth2 10.1.23.1/30 r3:eth2 10.1.23.2/30
r3:eth3 192.0.2.1/30 r4:eth1 192.0.2.2/30
r4:eth2 10.2.46.1/30 r6:eth2 10.2.46.2/30
r4:eth3 10.2.45.1/30 r5:eth1 10.2.45.2/30
r5:eth2 10.2.56.1/30 r6:eth3 10.2.56.2/30
r6:eth1 10.2.100.1/24 h2:eth1 10.2.100.10/24
"

test_scenario_yml_is_valid() { assert_succeeds validate_scenario_yml "$SCN"; }
test_scenario_is_draft_with_frr_variant() {
  assert_eq draft "$(meta "$SCN" .status)"
  assert_eq frr "$(meta "$SCN" .default_variant)"
  assert_eq "quay.io/frrouting/frr:10.1" "$(meta "$SCN" .variants.frr.images.router)"
  assert_eq none "$(meta "$SCN" .simulators.gns3)"
  assert_file_exists "$SCN/export/gns3/.gitkeep"
  assert_file_exists "$SCN/export/eve-ng/.gitkeep"
}
test_topology_nodes() {
  local t; t="$SCN/topology.clab.yml"
  assert_eq ospf-ebgp-two-as "$(yq -r .name "$t")"
  assert_eq "h1 h2 r1 r2 r3 r4 r5 r6" "$(yq -r '.topology.nodes | keys | sort | join(" ")' "$t")"
  assert_eq 6 "$(yq -r '[.topology.nodes[] | select(.image == "quay.io/frrouting/frr:10.1")] | length' "$t")"
  assert_eq 2 "$(yq -r '[.topology.nodes[] | select(.image == "wbitt/network-multitool:latest")] | length' "$t")"
  assert_eq 8 "$(yq -r '[.topology.nodes[] | select(.kind == "linux")] | length' "$t")"
}
test_topology_links_match_table() {
  local t; t="$SCN/topology.clab.yml"
  assert_eq 9 "$(yq -r '.topology.links | length' "$t")"
  local a aaddr b baddr
  while read -r a aaddr b baddr; do
    [[ -z "$a" ]] && continue
    assert_eq 1 "$(A="$a" B="$b" yq -r '[.topology.links[] | select((.endpoints[0] == strenv(A) and .endpoints[1] == strenv(B)) or (.endpoints[0] == strenv(B) and .endpoints[1] == strenv(A)))] | length' "$t")" "link $a <-> $b"
  done <<<"$LINKS"
}
test_router_binds_point_at_configs() {
  local r
  for r in $ROUTERS; do
    assert_contains "$(R="$r" yq -r '.topology.nodes[strenv(R)].binds | join("\n")' "$SCN/topology.clab.yml")" "configs/$r/frr.conf:/etc/frr/frr.conf"
    assert_contains "$(R="$r" yq -r '.topology.nodes[strenv(R)].binds | join("\n")' "$SCN/topology.clab.yml")" "configs/$r/daemons:/etc/frr/daemons"
  done
}
test_hosts_get_address_and_default_route() {
  local t; t="$SCN/topology.clab.yml"
  assert_contains "$(yq -r '.topology.nodes.h1.exec | join("\n")' "$t")" "ip addr add 10.1.100.10/24 dev eth1"
  assert_contains "$(yq -r '.topology.nodes.h1.exec | join("\n")' "$t")" "ip route replace default via 10.1.100.1"
  assert_contains "$(yq -r '.topology.nodes.h2.exec | join("\n")' "$t")" "ip addr add 10.2.100.10/24 dev eth1"
  assert_contains "$(yq -r '.topology.nodes.h2.exec | join("\n")' "$t")" "ip route replace default via 10.2.100.1"
}
test_verify_placeholder_is_executable_and_sources_lib() {
  [[ -x "$SCN/verify.sh" ]]
  # shellcheck disable=SC2016
  assert_contains "$(cat "$SCN/verify.sh")" 'source "${LIB_SH:?'
}

run_tests
```

- [ ] **Step 2: Run to verify failure**

Run: `chmod +x tests/test_ospf_ebgp.sh && bash tests/test_ospf_ebgp.sh 2>&1 | tail -3`
Expected: all tests FAIL (scenario missing).

- [ ] **Step 3: Create `scenario.yml`**

```yaml
# Two ASes in OSPF, joined by eBGP. Topology in topology.clab.yml.
name: ospf-ebgp-two-as
title: Two autonomous systems, OSPF inside, eBGP between, with intra-AS failover
topic: routing/ospf-bgp
status: draft                     # flip to ready after a live containerlab run (see README)
default_variant: frr
variants:
  frr:
    images:
      router: quay.io/frrouting/frr:10.1
      host: wbitt/network-multitool:latest
    notes: free images only; FRR 10.x syntax
simulators:
  containerlab: native
  gns3: none
  eve-ng: none
```

- [ ] **Step 4: Create `topology.clab.yml`**

```yaml
# Single source of truth. Interface names are explicit in every link so the
# README's ethN table and verify.sh's `ip link set eth2 down` on r1 are unambiguous.
name: ospf-ebgp-two-as

topology:
  nodes:
    r1:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/r1/frr.conf:/etc/frr/frr.conf
        - configs/r1/daemons:/etc/frr/daemons
    r2:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/r2/frr.conf:/etc/frr/frr.conf
        - configs/r2/daemons:/etc/frr/daemons
    r3:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/r3/frr.conf:/etc/frr/frr.conf
        - configs/r3/daemons:/etc/frr/daemons
    r4:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/r4/frr.conf:/etc/frr/frr.conf
        - configs/r4/daemons:/etc/frr/daemons
    r5:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/r5/frr.conf:/etc/frr/frr.conf
        - configs/r5/daemons:/etc/frr/daemons
    r6:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/r6/frr.conf:/etc/frr/frr.conf
        - configs/r6/daemons:/etc/frr/daemons
    h1:
      kind: linux
      image: wbitt/network-multitool:latest
      exec:
        - ip addr add 10.1.100.10/24 dev eth1
        - ip route replace default via 10.1.100.1
    h2:
      kind: linux
      image: wbitt/network-multitool:latest
      exec:
        - ip addr add 10.2.100.10/24 dev eth1
        - ip route replace default via 10.2.100.1
  links:
    - endpoints: ["h1:eth1", "r1:eth1"]
    - endpoints: ["r1:eth2", "r3:eth1"]   # primary path, taken down in the failover test
    - endpoints: ["r1:eth3", "r2:eth1"]
    - endpoints: ["r2:eth2", "r3:eth2"]
    - endpoints: ["r3:eth3", "r4:eth1"]   # eBGP
    - endpoints: ["r4:eth2", "r6:eth2"]   # primary path
    - endpoints: ["r4:eth3", "r5:eth1"]
    - endpoints: ["r5:eth2", "r6:eth3"]
    - endpoints: ["r6:eth1", "h2:eth1"]
```

- [ ] **Step 5: Placeholder `verify.sh`, README stub, export dirs**

`scenarios/ospf-ebgp-two-as/verify.sh`:
```bash
#!/usr/bin/env bash
# Verification for ospf-ebgp-two-as. Run via: scripts/verify.sh ospf-ebgp-two-as
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib.sh
source "${LIB_SH:?run this via scripts/verify.sh}"

fail "verify.sh not implemented yet"
```

`README.md` stub with headings only: `# ospf-ebgp-two-as`, `## Objective`, `## Topology`, `## Routing design`, `## Tasks`, `## Verification`, `## Failover walkthrough`, `## Validation on a containerlab host`, `## Simulators`, `## Teardown`.

```bash
mkdir -p scenarios/ospf-ebgp-two-as/export/gns3 scenarios/ospf-ebgp-two-as/export/eve-ng
touch scenarios/ospf-ebgp-two-as/export/gns3/.gitkeep scenarios/ospf-ebgp-two-as/export/eve-ng/.gitkeep
chmod +x scenarios/ospf-ebgp-two-as/verify.sh
```

- [ ] **Step 6: Run tests**

Run: `bash tests/test_ospf_ebgp.sh && scripts/test.sh`
Expected: `test_ospf_ebgp.sh: 7 tests, 0 failed`; `ALL PASSED`; `git status` shows no `.build.clab.yml`.

- [ ] **Step 7: Commit**

```bash
git add scenarios/ospf-ebgp-two-as tests/test_ospf_ebgp.sh
git commit -m "feat: scaffold ospf-ebgp-two-as scenario (metadata, topology, hosts)"
```

---

### Task 2: AS 65001 router configs (r1, r2, r3)

**Files:**
- Create: `scenarios/ospf-ebgp-two-as/configs/r{1,2,3}/frr.conf` and `daemons`
- Modify: `tests/test_ospf_ebgp.sh`

**Interfaces:**
- Produces: test helpers `cfg R` (echoes `configs/R/frr.conf` content), `daemons_of R`, `assert_router_base R ROUTERID`, `assert_addresses_from_table R`, `assert_ospf_ptp R IFACES...`; the `DAEMONS_TEMPLATE` expectation (`vtysh_enable=yes` etc.).

- [ ] **Step 1: Write failing tests** (insert above `run_tests`)

```bash
cfg() { cat "$SCN/configs/$1/frr.conf"; }
daemons_of() { cat "$SCN/configs/$1/daemons"; }

# Every router: hostname, loopback in area 0, router-id, daemons sane.
assert_router_base() { # R ROUTERID
  local c; c="$(cfg "$1")"
  assert_contains "$c" "hostname $1"
  assert_contains "$c" "interface lo"
  assert_contains "$c" " ip address $2/32"
  assert_contains "$c" "router ospf"
  assert_contains "$c" " ospf router-id $2"
  local d; d="$(daemons_of "$1")"
  assert_contains "$d" "zebra=yes"
  assert_contains "$d" "ospfd=yes"
  assert_contains "$d" "staticd=yes"
  assert_contains "$d" "vtysh_enable=yes"
  assert_file_exists "$SCN/configs/$1/daemons"
}
# Every address the LINKS table assigns to R appears as an `ip address` line.
assert_addresses_from_table() { # R
  local c a aaddr b baddr; c="$(cfg "$1")"
  while read -r a aaddr b baddr; do
    [[ -z "$a" ]] && continue
    [[ "${a%%:*}" == "$1" ]] && assert_contains "$c" " ip address $aaddr" "$1 ${a#*:}"
    [[ "${b%%:*}" == "$1" ]] && assert_contains "$c" " ip address $baddr" "$1 ${b#*:}"
  done <<<"$LINKS"
}
# Each listed interface block has area 0, point-to-point and cost 10.
assert_ospf_ptp() { # R IFACE...
  local r="$1"; shift
  local i block
  for i in "$@"; do
    block="$(sed -n "/^interface $i\$/,/^!/p" "$SCN/configs/$r/frr.conf")"
    assert_contains "$block" " ip ospf area 0" "$r $i area"
    assert_contains "$block" " ip ospf network point-to-point" "$r $i ptp"
    assert_contains "$block" " ip ospf cost 10" "$r $i cost"
  done
}

test_as65001_configs_exist() {
  local r; for r in r1 r2 r3; do assert_file_exists "$SCN/configs/$r/frr.conf"; done
}
test_as65001_base_and_addresses() {
  assert_router_base r1 10.1.0.1; assert_addresses_from_table r1
  assert_router_base r2 10.1.0.2; assert_addresses_from_table r2
  assert_router_base r3 10.1.0.3; assert_addresses_from_table r3
}
test_as65001_ospf_interfaces() {
  assert_ospf_ptp r1 eth2 eth3
  assert_ospf_ptp r2 eth1 eth2
  assert_ospf_ptp r3 eth1 eth2
  assert_contains "$(cfg r1)" " passive-interface eth1"
  assert_not_contains "$(sed -n '/^interface eth3$/,/^!/p' "$SCN/configs/r3/frr.conf")" "ip ospf" "eBGP link not in OSPF"
}
test_as65001_border_only_on_r3() {
  local c3; c3="$(cfg r3)"
  assert_contains "$c3" "router bgp 65001"
  assert_contains "$c3" " no bgp ebgp-requires-policy"
  assert_contains "$c3" " neighbor 192.0.2.2 remote-as 65002"
  assert_contains "$c3" "  network 10.1.0.0/16"
  assert_contains "$c3" "ip route 10.1.0.0/16 Null0"
  assert_contains "$c3" " default-information originate always"
  assert_contains "$(daemons_of r3)" "bgpd=yes"
  local r
  for r in r1 r2; do
    assert_not_contains "$(cfg "$r")" "router bgp"
    assert_not_contains "$(cfg "$r")" "default-information"
    assert_contains "$(daemons_of "$r")" "bgpd=no"
  done
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_ospf_ebgp.sh 2>&1 | tail -5`
Expected: four new tests FAIL.

- [ ] **Step 3: Write `configs/r1/frr.conf`**

```
! r1: AS 65001 interior, gateway for h1
frr defaults traditional
hostname r1
log syslog informational
!
interface lo
 ip address 10.1.0.1/32
 ip ospf area 0
!
interface eth1
 description h1 LAN
 ip address 10.1.100.1/24
 ip ospf area 0
!
interface eth2
 description r1-r3 primary
 ip address 10.1.13.1/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
interface eth3
 description r1-r2
 ip address 10.1.12.1/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
router ospf
 ospf router-id 10.1.0.1
 passive-interface eth1
!
line vty
!
```

- [ ] **Step 4: Write `configs/r2/frr.conf`**

```
! r2: AS 65001 interior (detour path)
frr defaults traditional
hostname r2
log syslog informational
!
interface lo
 ip address 10.1.0.2/32
 ip ospf area 0
!
interface eth1
 description r2-r1
 ip address 10.1.12.2/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
interface eth2
 description r2-r3
 ip address 10.1.23.1/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
router ospf
 ospf router-id 10.1.0.2
!
line vty
!
```

- [ ] **Step 5: Write `configs/r3/frr.conf`**

```
! r3: AS 65001 border (eBGP to AS 65002)
frr defaults traditional
hostname r3
log syslog informational
!
interface lo
 ip address 10.1.0.3/32
 ip ospf area 0
!
interface eth1
 description r3-r1 primary
 ip address 10.1.13.2/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
interface eth2
 description r3-r2
 ip address 10.1.23.2/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
interface eth3
 description r3-r4 eBGP
 ip address 192.0.2.1/30
!
ip route 10.1.0.0/16 Null0
!
router ospf
 ospf router-id 10.1.0.3
 default-information originate always
!
router bgp 65001
 bgp router-id 10.1.0.3
 no bgp ebgp-requires-policy
 neighbor 192.0.2.2 remote-as 65002
 !
 address-family ipv4 unicast
  network 10.1.0.0/16
  neighbor 192.0.2.2 activate
 exit-address-family
!
line vty
!
```

- [ ] **Step 6: Write the three `daemons` files**

`configs/r1/daemons` and `configs/r2/daemons` (identical):
```
# FRR daemons for an interior router: OSPF only.
zebra=yes
bgpd=no
ospfd=yes
ospf6d=no
ripd=no
isisd=no
staticd=yes

vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
ospfd_options="  -A 127.0.0.1"
ospf6d_options=" -A ::1"
ripd_options="   -A 127.0.0.1"
isisd_options="  -A 127.0.0.1"
staticd_options="-A 127.0.0.1"
```
`configs/r3/daemons`: same file with the first comment `# FRR daemons for a border router: OSPF + BGP.` and `bgpd=yes`.

- [ ] **Step 7: Run tests**

Run: `bash tests/test_ospf_ebgp.sh && scripts/test.sh`
Expected: `test_ospf_ebgp.sh: 11 tests, 0 failed`; `ALL PASSED`.

- [ ] **Step 8: Commit**

```bash
git add scenarios/ospf-ebgp-two-as/configs tests/test_ospf_ebgp.sh
git commit -m "feat: add AS 65001 FRR configs (r1-r3) for ospf-ebgp-two-as"
```

---

### Task 3: AS 65002 router configs (r4, r5, r6)

**Files:**
- Create: `scenarios/ospf-ebgp-two-as/configs/r{4,5,6}/frr.conf` and `daemons`
- Modify: `tests/test_ospf_ebgp.sh`

**Interfaces:**
- Consumes: `cfg`, `daemons_of`, `assert_router_base`, `assert_addresses_from_table`, `assert_ospf_ptp`, `built` from Tasks 1–2.

- [ ] **Step 1: Write failing tests** (insert above `run_tests`)

```bash
test_as65002_configs_exist() {
  local r; for r in r4 r5 r6; do assert_file_exists "$SCN/configs/$r/frr.conf"; done
}
test_as65002_base_and_addresses() {
  assert_router_base r4 10.2.0.4; assert_addresses_from_table r4
  assert_router_base r5 10.2.0.5; assert_addresses_from_table r5
  assert_router_base r6 10.2.0.6; assert_addresses_from_table r6
}
test_as65002_ospf_interfaces() {
  assert_ospf_ptp r4 eth2 eth3
  assert_ospf_ptp r5 eth1 eth2
  assert_ospf_ptp r6 eth2 eth3
  assert_contains "$(cfg r6)" " passive-interface eth1"
  assert_not_contains "$(sed -n '/^interface eth1$/,/^!/p' "$SCN/configs/r4/frr.conf")" "ip ospf" "eBGP link not in OSPF"
}
test_as65002_border_only_on_r4() {
  local c4; c4="$(cfg r4)"
  assert_contains "$c4" "router bgp 65002"
  assert_contains "$c4" " no bgp ebgp-requires-policy"
  assert_contains "$c4" " neighbor 192.0.2.1 remote-as 65001"
  assert_contains "$c4" "  network 10.2.0.0/16"
  assert_contains "$c4" "ip route 10.2.0.0/16 Null0"
  assert_contains "$c4" " default-information originate always"
  assert_contains "$(daemons_of r4)" "bgpd=yes"
  local r
  for r in r5 r6; do
    assert_not_contains "$(cfg "$r")" "router bgp"
    assert_not_contains "$(cfg "$r")" "default-information"
    assert_contains "$(daemons_of "$r")" "bgpd=no"
  done
}
test_all_bind_sources_exist_in_built_topology() {
  local t src; t="$(built)"
  while IFS= read -r src; do
    assert_file_exists "$(dirname "$t")/$src"
  done < <(yq -r '.topology.nodes[].binds[]? | split(":") | .[0]' "$t")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_ospf_ebgp.sh 2>&1 | tail -6`
Expected: the five new tests FAIL.

- [ ] **Step 3: Write `configs/r4/frr.conf`**

```
! r4: AS 65002 border (eBGP to AS 65001)
frr defaults traditional
hostname r4
log syslog informational
!
interface lo
 ip address 10.2.0.4/32
 ip ospf area 0
!
interface eth1
 description r4-r3 eBGP
 ip address 192.0.2.2/30
!
interface eth2
 description r4-r6 primary
 ip address 10.2.46.1/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
interface eth3
 description r4-r5
 ip address 10.2.45.1/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
ip route 10.2.0.0/16 Null0
!
router ospf
 ospf router-id 10.2.0.4
 default-information originate always
!
router bgp 65002
 bgp router-id 10.2.0.4
 no bgp ebgp-requires-policy
 neighbor 192.0.2.1 remote-as 65001
 !
 address-family ipv4 unicast
  network 10.2.0.0/16
  neighbor 192.0.2.1 activate
 exit-address-family
!
line vty
!
```

- [ ] **Step 4: Write `configs/r5/frr.conf`**

```
! r5: AS 65002 interior (detour path)
frr defaults traditional
hostname r5
log syslog informational
!
interface lo
 ip address 10.2.0.5/32
 ip ospf area 0
!
interface eth1
 description r5-r4
 ip address 10.2.45.2/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
interface eth2
 description r5-r6
 ip address 10.2.56.1/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
router ospf
 ospf router-id 10.2.0.5
!
line vty
!
```

- [ ] **Step 5: Write `configs/r6/frr.conf`**

```
! r6: AS 65002 interior, gateway for h2
frr defaults traditional
hostname r6
log syslog informational
!
interface lo
 ip address 10.2.0.6/32
 ip ospf area 0
!
interface eth1
 description h2 LAN
 ip address 10.2.100.1/24
 ip ospf area 0
!
interface eth2
 description r6-r4 primary
 ip address 10.2.46.2/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
interface eth3
 description r6-r5
 ip address 10.2.56.2/30
 ip ospf area 0
 ip ospf network point-to-point
 ip ospf cost 10
!
router ospf
 ospf router-id 10.2.0.6
 passive-interface eth1
!
line vty
!
```

- [ ] **Step 6: Write the `daemons` files**

`configs/r5/daemons`, `configs/r6/daemons`: identical to `configs/r1/daemons` (interior, `bgpd=no`). `configs/r4/daemons`: identical to `configs/r3/daemons` (border, `bgpd=yes`).

- [ ] **Step 7: Run tests**

Run: `bash tests/test_ospf_ebgp.sh && scripts/test.sh`
Expected: `test_ospf_ebgp.sh: 16 tests, 0 failed`; `ALL PASSED`; no `.build.clab.yml` leftovers.

- [ ] **Step 8: Commit**

```bash
git add scenarios/ospf-ebgp-two-as/configs tests/test_ospf_ebgp.sh
git commit -m "feat: add AS 65002 FRR configs (r4-r6) for ospf-ebgp-two-as"
```

---

### Task 4: `verify.sh` with failover, and stateful stub tests

**Files:**
- Modify: `scenarios/ospf-ebgp-two-as/verify.sh` (replace body)
- Modify: `tests/test_ospf_ebgp.sh`

**Interfaces:**
- Consumes: `node_exec`, `expect_contains`, `expect_not_contains`, `wait_for`, `log`, `fail` from `lib.sh`; `scripts/verify.sh` exports `LAB_NAME=ospf-ebgp-two-as`, `VARIANT`, `LIB_SH`.
- Produces: test helpers `make_frr_stub ROOT MODE` (MODE ∈ `ok`, `ospf-stuck`, `bgp-active`, `no-reroute`) and `run_verify ROOT`.

- [ ] **Step 1: Write failing tests** (insert above `run_tests`)

```bash
# Stateful docker stub. The second argv word is the container name; the command is $4.
# It records "ip link set eth2 down/up" in a flag file so routes/traceroute change state.
make_frr_stub() { # ROOT MODE
  local root="$1" mode="$2"
  mkdir -p "$root/bin"
  cat >"$root/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/docker.log"
node="\${2#clab-ospf-ebgp-two-as-}"
cmd="\${4:-}"
mode="$mode"
flag="$root/eth2_down"
case "\$cmd" in
  *"ip link set eth2 down"*) touch "\$flag"; exit 0 ;;
  *"ip link set eth2 up"*)   rm -f "\$flag"; exit 0 ;;
  *"show version"*) echo "FRRouting 10.1 (\$node)" ;;
  *"grep -c Full"*)
    if [[ "\$mode" == ospf-stuck && "\$node" == r1 ]]; then echo 1; else echo 2; fi ;;
  *"show ip ospf neighbor"*)
    echo "Neighbor ID     Pri State           Up Time         Dead Time Address         Interface"
    case "\$node" in
      r1) n1=10.1.0.2; n2=10.1.0.3 ;; r2) n1=10.1.0.1; n2=10.1.0.3 ;; r3) n1=10.1.0.1; n2=10.1.0.2 ;;
      r4) n1=10.2.0.5; n2=10.2.0.6 ;; r5) n1=10.2.0.4; n2=10.2.0.6 ;; r6) n1=10.2.0.4; n2=10.2.0.5 ;;
    esac
    s2="Full/-"; [[ "\$mode" == ospf-stuck && "\$node" == r1 ]] && s2="ExStart/-"
    echo "\$n1              1 Full/-          1h00m00s          38.000s 10.0.0.1        eth9:10.0.0.2"
    echo "\$n2              1 \$s2          1h00m00s          38.000s 10.0.0.1        eth8:10.0.0.2" ;;
  *"show bgp neighbors"*)
    if [[ "\$mode" == bgp-active ]]; then echo '"bgpState":"Active"'; else echo '"bgpState":"Established"'; fi ;;
  *"show ip route bgp"*)
    if [[ "\$node" == r3 ]]; then echo "B>* 10.2.0.0/16 [20/0] via 192.0.2.2, eth3"; else echo "B>* 10.1.0.0/16 [20/0] via 192.0.2.1, eth1"; fi ;;
  *"show ip route ospf"*) echo "O>* 0.0.0.0/0 [110/1] via 10.1.13.2, eth2" ;;
  *"show ip route 10.1.0.3/32"*)
    if [[ -e "\$flag" && "\$mode" != no-reroute ]]; then echo "O>* 10.1.0.3/32 [110/20] via 10.1.12.2, eth3"; else echo "O>* 10.1.0.3/32 [110/10] via 10.1.13.2, eth2"; fi ;;
  *ping*) echo "5 packets transmitted, 5 received, 0% packet loss" ;;
  *traceroute*)
    echo " 1  10.1.100.1  0.1 ms"
    if [[ -e "\$flag" && "\$mode" != no-reroute ]]; then echo " 2  10.1.12.2  0.2 ms"; echo " 3  10.1.23.2  0.3 ms"; else echo " 2  10.1.13.2  0.2 ms"; fi
    echo " 4  192.0.2.2  0.4 ms"; echo " 5  10.2.46.2  0.5 ms"; echo " 6  10.2.100.10  0.6 ms" ;;
  *) echo "unknown" ;;
esac
STUB
  chmod +x "$root/bin/docker"
}
run_verify() { # ROOT
  LIB_REPO_ROOT="$REPO_ROOT" DOCKER="$1/bin/docker" WAIT_INTERVAL=1 BOOT_TIMEOUT=2 OSPF_TIMEOUT=2 BGP_TIMEOUT=2 \
    "$REPO_ROOT/scripts/verify.sh" ospf-ebgp-two-as
}

test_verify_passes_against_healthy_stub() {
  local root out; root="$(make_tmpdir)"; make_frr_stub "$root" ok
  out="$(run_verify "$root" 2>&1)"
  assert_contains "$out" "all checks passed"
  local dk; dk="$(cat "$root/docker.log")"
  assert_contains "$dk" "clab-ospf-ebgp-two-as-r1 sh -c ip link set eth2 down"
  assert_contains "$dk" "clab-ospf-ebgp-two-as-r1 sh -c ip link set eth2 up"
  assert_contains "$dk" "clab-ospf-ebgp-two-as-r3 sh -c vtysh -c 'show bgp neighbors 192.0.2.2 json'"
  assert_contains "$dk" "clab-ospf-ebgp-two-as-h1 sh -c traceroute"
  [[ ! -e "$root/eth2_down" ]] || return 1   # link restored at the end
}
test_verify_fails_when_ospf_stuck() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" ospf-stuck
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "error: r1:"
  assert_not_contains "$(cat "$root/docker.log")" "ip link set eth2 down" "failover never reached"
}
test_verify_fails_when_bgp_active() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" bgp-active
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "did not contain 'Established'"
}
test_verify_fails_when_no_reroute_and_still_restores_link() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" no-reroute
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "show ip route 10.1.0.3/32' did not contain 'via 10.1.12.2'"
  assert_eq "ip link set eth2 up" "$(grep -o 'ip link set eth2 [a-z]*' "$root/docker.log" | tail -1)" "trap restored the link"
  [[ ! -e "$root/eth2_down" ]] || return 1
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_ospf_ebgp.sh 2>&1 | tail -5`
Expected: the four new tests FAIL ("not implemented yet").

- [ ] **Step 3: Write `verify.sh`**

```bash
#!/usr/bin/env bash
# Verification for ospf-ebgp-two-as. Run via: scripts/verify.sh ospf-ebgp-two-as
# scripts/verify.sh exports LAB_NAME, VARIANT and LIB_SH before calling this.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib.sh
source "${LIB_SH:?run this via scripts/verify.sh}"

boot_timeout="${BOOT_TIMEOUT:-60}"
ospf_timeout="${OSPF_TIMEOUT:-90}"
bgp_timeout="${BGP_TIMEOUT:-120}"

routers="r1 r2 r3 r4 r5 r6"
# Expected OSPF neighbour router-ids per router.
neighbors_of() {
  case "$1" in
    r1) echo "10.1.0.2 10.1.0.3" ;; r2) echo "10.1.0.1 10.1.0.3" ;; r3) echo "10.1.0.1 10.1.0.2" ;;
    r4) echo "10.2.0.5 10.2.0.6" ;; r5) echo "10.2.0.4 10.2.0.6" ;; r6) echo "10.2.0.4 10.2.0.5" ;;
  esac
}

log "== 1. FRR up on all routers"
for r in $routers; do
  wait_for "$boot_timeout" "$r" "vtysh -c 'show version'" "FRRouting"
done

log "== 2. OSPF adjacencies Full (two neighbours per router)"
for r in $routers; do
  for n in $(neighbors_of "$r"); do
    wait_for "$ospf_timeout" "$r" "vtysh -c 'show ip ospf neighbor'" "$n"
  done
  wait_for "$ospf_timeout" "$r" "vtysh -c 'show ip ospf neighbor' | grep -c Full" "2"
  for state in Init ExStart Exchange Loading; do
    expect_not_contains "$r" "vtysh -c 'show ip ospf neighbor'" "$state"
  done
done

log "== 3. eBGP Established and aggregates exchanged"
wait_for "$bgp_timeout" r3 "vtysh -c 'show bgp neighbors 192.0.2.2 json' | grep -o '\"bgpState\":\"[A-Za-z]*\"'" "Established"
wait_for "$bgp_timeout" r4 "vtysh -c 'show bgp neighbors 192.0.2.1 json' | grep -o '\"bgpState\":\"[A-Za-z]*\"'" "Established"
wait_for "$bgp_timeout" r3 "vtysh -c 'show ip route bgp'" "10.2.0.0/16"
wait_for "$bgp_timeout" r4 "vtysh -c 'show ip route bgp'" "10.1.0.0/16"

log "== 4. Interiors learn a default route from their border"
for r in r1 r2 r5 r6; do
  wait_for "$ospf_timeout" "$r" "vtysh -c 'show ip route ospf'" "0.0.0.0/0"
done

log "== 5. End-to-end reachability and primary path"
expect_contains h1 "ping -c 5 -W 2 10.2.100.10" "5 received"
expect_contains h2 "ping -c 5 -W 2 10.1.100.10" "5 received"
expect_contains     h1 "traceroute -n -w 1 -q 1 -m 8 10.2.100.10" "10.1.13.2"
expect_not_contains h1 "traceroute -n -w 1 -q 1 -m 8 10.2.100.10" "10.1.12.2"

log "== 6. Failover: take down r1-r3 (r1 eth2); traffic must detour via r2"
restore_link() { node_exec r1 "ip link set eth2 up" >/dev/null 2>&1 || true; }
trap restore_link EXIT
node_exec r1 "ip link set eth2 down"
wait_for "$ospf_timeout" r1 "vtysh -c 'show ip route 10.1.0.3/32'" "via 10.1.12.2"
expect_contains     h1 "ping -c 5 -W 2 10.2.100.10" "5 received"
expect_contains     h1 "traceroute -n -w 1 -q 1 -m 8 10.2.100.10" "10.1.12.2"
expect_not_contains h1 "traceroute -n -w 1 -q 1 -m 8 10.2.100.10" "10.1.13.2"

log "== 7. Restore the link; primary path returns"
node_exec r1 "ip link set eth2 up"
trap - EXIT
wait_for "$ospf_timeout" r1 "vtysh -c 'show ip route 10.1.0.3/32'" "via 10.1.13.2"
expect_contains h1 "ping -c 5 -W 2 10.2.100.10" "5 received"

log "all checks passed"
```

- [ ] **Step 4: Run tests**

Run: `bash tests/test_ospf_ebgp.sh && scripts/test.sh`
Expected: `test_ospf_ebgp.sh: 20 tests, 0 failed` (the three failure tests take a few seconds each); `ALL PASSED`. If shellcheck flags the `$state`/`$n` loops or the `grep -o` quoting, fix quoting rather than disabling the check.

- [ ] **Step 5: Commit**

```bash
git add scenarios/ospf-ebgp-two-as/verify.sh tests/test_ospf_ebgp.sh
git commit -m "feat: add ospf-ebgp-two-as verification with failover and stub tests"
```

---

### Task 5: Documentation

**Files:**
- Modify: `scenarios/ospf-ebgp-two-as/README.md` (replace stub)
- Modify: `docs/conventions.md` (add "Failure injection" paragraph under "## Scripts")
- Modify: `tests/test_docs.sh`, `tests/test_ospf_ebgp.sh`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_docs.sh` above `run_tests`:
```bash
test_conventions_describe_failure_injection() {
  local c; c="$(cat "$REPO_ROOT/docs/conventions.md")"
  assert_contains "$c" "Failure injection"
  assert_contains "$c" "trap"
  assert_contains "$c" "ip link set"
}
```
Append to `tests/test_ospf_ebgp.sh` above `run_tests`:
```bash
test_readme_documents_scenario() {
  local r; r="$(cat "$SCN/README.md")"
  for s in "## Objective" "## Topology" "## Routing design" "## Verification" "## Failover walkthrough" "## Validation on a containerlab host"; do
    assert_contains "$r" "$s"
  done
  assert_contains "$r" "r1:eth2"
  assert_contains "$r" "default-information originate"
  assert_contains "$r" "no bgp ebgp-requires-policy"
  assert_contains "$r" "scripts/up.sh ospf-ebgp-two-as --force"
  assert_contains "$r" "OSPF_TIMEOUT"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_docs.sh 2>&1 | tail -2; bash tests/test_ospf_ebgp.sh 2>&1 | tail -2`
Expected: both new tests FAIL.

- [ ] **Step 3: Write the README**

`scenarios/ospf-ebgp-two-as/README.md`:
````markdown
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
6. **Failover:** `ip link set eth2 down` on r1. r1's route to r3's loopback moves to `via 10.1.12.2`, pings still succeed, and the traceroute now shows `10.1.12.2` and not `10.1.13.2`.
7. **Restore:** the link comes back up, the route returns to `via 10.1.13.2`, and a final ping succeeds. The restore also runs under an EXIT `trap`, so a failed check never leaves the lab degraded.

Timeouts: `BOOT_TIMEOUT` (60 s), `OSPF_TIMEOUT` (90 s), `BGP_TIMEOUT` (120 s), and `WAIT_INTERVAL` (2 s) can be overridden in the environment.

## Failover walkthrough

Before the failover, on r1:

```
r1# show ip route 10.1.0.3/32
O>* 10.1.0.3/32 [110/10] via 10.1.13.2, eth2
```

After `ip link set eth2 down` on r1, OSPF reconverges and the same route
points through r2:

```
O>* 10.1.0.3/32 [110/20] via 10.1.12.2, eth3
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
````

- [ ] **Step 4: Add the conventions paragraph**

In `docs/conventions.md`, at the end of the "## Scripts" section (after the `ASA_NODES` paragraph), add:

```markdown
### Failure injection

A scenario that breaks something to test convergence (for example
`node_exec r1 "ip link set eth2 down"`) must restore it even when a later
check fails. Define a restore function and register it with
`trap restore_link EXIT` before injecting the failure, perform the degraded
checks, then restore explicitly and clear the trap with `trap - EXIT` before
the final checks. Prefer kernel-level injection (`ip link set`) over
daemon-level `shutdown` commands: it models a real link loss and needs no
NOS-specific syntax.
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh`
Expected: `test_docs.sh: 9 tests, 0 failed`; `test_ospf_ebgp.sh: 21 tests, 0 failed`; `ALL PASSED`.

- [ ] **Step 6: Commit**

```bash
git add scenarios/ospf-ebgp-two-as/README.md docs/conventions.md tests/test_docs.sh tests/test_ospf_ebgp.sh
git commit -m "docs: document ospf-ebgp-two-as and the failure-injection convention"
```

---

### Task 6: Full suite, push, update PR #4

**Files:** none new.

- [ ] **Step 1: Full suite and built-topology sanity**

```bash
scripts/test.sh
bash -c 'source scripts/lib.sh; build_topology "$PWD/scenarios/ospf-ebgp-two-as" frr' >/dev/null
yq -r '.topology.nodes[].binds[]? | split(":") | .[0]' scenarios/ospf-ebgp-two-as/.frr.build.clab.yml \
  | while read -r f; do [[ -f "scenarios/ospf-ebgp-two-as/$f" ]] && echo "ok $f" || echo "MISSING $f"; done
rm -f scenarios/ospf-ebgp-two-as/.*.build.clab.yml
git status --short   # must be clean
```
Expected: `ALL PASSED`; twelve `ok` lines; clean status.

- [ ] **Step 2: Push**

```bash
git push -u origin ccr-00157a22-qiys9w
```

- [ ] **Step 3: Update PR #4**

Replace the "Status" section of the PR body with what landed (scenario files, six configs, `verify.sh` with failover, 21 scenario tests, docs); tick the test-plan boxes CI will confirm; keep the attribution footer. Do not open a new PR.

- [ ] **Step 4: Confirm CI**

Check `ci / test` on the new head. Expected: green.

---

## Self-review notes

- Spec coverage: topology/addressing/interface table (T1), OSPF+BGP design incl. aggregate/default/`no bgp ebgp-requires-policy` (T2, T3), daemons (T2, T3), verification steps 1–8 with trap restore (T4), tests: scenario.yml, built topology, link table, binds, config markers, addressing from table, stub modes incl. trap proof (T1–T4), README + conventions paragraph (T5), real-world validation commands and draft status (T1, T5), exports none (T1).
- Names used consistently: `SCN`, `ROUTERS`, `LINKS`, `built`, `cleanup_built`, `cfg`, `daemons_of`, `assert_router_base`, `assert_addresses_from_table`, `assert_ospf_ptp`, `make_frr_stub`, `run_verify`, env `BOOT_TIMEOUT`/`OSPF_TIMEOUT`/`BGP_TIMEOUT`, `neighbors_of`, `restore_link`, container prefix `clab-ospf-ebgp-two-as-`.
- Test counts in "Expected" lines are the number of `test_*` functions at that point; trust `0 failed` / `ALL PASSED` if a count is off by one.
