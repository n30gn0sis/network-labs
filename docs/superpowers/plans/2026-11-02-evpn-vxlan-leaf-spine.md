# EVPN/VXLAN Leaf-Spine Scenario Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `scenarios/evpn-vxlan-leaf-spine`: two FRR spines and two FRR leaves with an eBGP-unnumbered underlay and a BGP EVPN overlay, one Linux host per leaf in a VLAN stretched over VXLAN VNI 10, with a `verify.sh` that proves both BGP address families, ECMP, VTEP and MAC state, reachability, and a spine-uplink failover, plus Docker-free tests, a draw.io diagram and docs.

**Architecture:** Follows the repository scenario contract (`scenario.yml`, `topology.clab.yml`, `configs/<node>/`, `verify.sh`). Routers are `linux` kind FRR containers with bind-mounted `frr.conf`/`daemons`; the Linux dataplane (bridge `br10`, VXLAN device `vxlan10`, access port `eth3`) is created from each leaf's `exec:` list; hosts are `linux` multitool containers configured via `exec:`. Verification uses only the existing `docker exec` helpers (`node_exec`, `expect_contains`, `expect_not_contains`, `wait_for`); the failover is injected with `ip link set eth1 down` on `leaf1` and restored under an EXIT `trap`. Tests stub `docker` through `DOCKER` with a stateful stub that tracks the link state and whether a ping has happened.

**Tech Stack:** bash 5, mikefarah `yq` v4, `shellcheck`, FRR 10.1 (`quay.io/frrouting/frr:10.1`), `wbitt/network-multitool:latest`, containerlab (runtime only), draw.io XML.

Spec: `docs/superpowers/specs/2026-11-02-evpn-vxlan-leaf-spine-design.md`

## Global Constraints

- Every script: `#!/usr/bin/env bash`, `set -euo pipefail`; `scripts/lib.sh` is sourced, not executed. Start every Bash call with `export PATH="$HOME/.local/bin:$PATH"` (yq v4.44.3, shellcheck 0.10.0 live there).
- Tests never need Docker or containerlab; inject stubs via `DOCKER`.
- Scenario name `evpn-vxlan-leaf-spine`, topic `datacenter/evpn-vxlan`, `status: draft`, single variant `frr` with `images.router: quay.io/frrouting/frr:10.1`, `images.host: wbitt/network-multitool:latest`; exports `none`.
- Nodes: `spine1`, `spine2`, `leaf1`, `leaf2` (`linux`, FRR image, binds `configs/<r>/frr.conf:/etc/frr/frr.conf` and `configs/<r>/daemons:/etc/frr/daemons`), `h1`, `h2` (`linux`, multitool).
- Loopbacks / router-ids / ASNs: spine1 10.0.0.1 AS 65100, spine2 10.0.0.2 AS 65100, leaf1 10.0.0.11 AS 65001, leaf2 10.0.0.12 AS 65002 (all /32).
- Links (explicit interface names in `endpoints:`), all fabric links unnumbered:
  - `leaf1:eth1` ↔ `spine1:eth1` (taken down in the failover test)
  - `leaf1:eth2` ↔ `spine2:eth1`
  - `leaf2:eth1` ↔ `spine1:eth2`
  - `leaf2:eth2` ↔ `spine2:eth2`
  - `leaf1:eth3` ↔ `h1:eth1` (h1 10.10.0.1/24)
  - `leaf2:eth3` ↔ `h2:eth1` (h2 10.10.0.2/24)
- Every router `exec:` starts with `ip route del default` then `sysctl -qw net.ipv6.conf.all.disable_ipv6=0`. Leaves add, in order: `ip link add br10 type bridge`, `ip link add vxlan10 type vxlan id 10 local <loopback> dstport 4789 nolearning`, `ip link set vxlan10 master br10`, `ip link set eth3 master br10`, `ip link set br10 up`, `ip link set vxlan10 up`, `ip link set eth3 up`. Spines have no `ip link` lines. Hosts: `ip addr add 10.10.0.N/24 dev eth1` only, no default route changes.
- BGP on every router: `bgp router-id <loopback>`, `no bgp ebgp-requires-policy`, `no bgp default ipv4-unicast`, `bgp bestpath as-path multipath-relax`, `neighbor fabric peer-group`, `neighbor fabric remote-as external`, `neighbor eth1 interface peer-group fabric`, `neighbor eth2 interface peer-group fabric`; `address-family ipv4 unicast` with `neighbor fabric activate` and `redistribute connected`; `address-family l2vpn evpn` with `neighbor fabric activate`. Leaves add `advertise-all-vni` and a `vni 10` block with `rd auto`, `route-target import 65000:10`, `route-target export 65000:10`. Interfaces `eth1` and `eth2` on every router carry `no ipv6 nd suppress-ra` and `ipv6 nd ra-interval 10`.
- `daemons`: `zebra=yes`, `bgpd=yes`, `staticd=yes`, `ospfd=no`, rest `no`; `vtysh_enable=yes` and the `*_options` lines as in the OSPF scenario.
- Verification env knobs: `BOOT_TIMEOUT` (60), `BGP_TIMEOUT` (120), `EVPN_TIMEOUT` (60). `WAIT_INTERVAL` is lib.sh's existing knob.
- Container names are `clab-evpn-vxlan-leaf-spine-<node>`.
- Commit after every task with a conventional prefix, ending with the attribution lines the harness provides. No model identifiers in committed content.
- Work on branch `ccr-00157a22-qiys9w` (already restarted from `main`; the spec commit is on it). PR #5 is merged, so Task 6 opens a new draft PR.

---

## File map

| Path | Responsibility |
|---|---|
| `scenarios/evpn-vxlan-leaf-spine/scenario.yml` | metadata |
| `scenarios/evpn-vxlan-leaf-spine/topology.clab.yml` | 6 nodes, 6 links, exec lists (routing housekeeping, leaf dataplane, host addresses) |
| `scenarios/evpn-vxlan-leaf-spine/configs/{spine1,spine2,leaf1,leaf2}/{frr.conf,daemons}` | router configs |
| `scenarios/evpn-vxlan-leaf-spine/verify.sh` | checks incl. failover |
| `scenarios/evpn-vxlan-leaf-spine/README.md` | docs |
| `scenarios/evpn-vxlan-leaf-spine/export/{gns3,eve-ng}/.gitkeep` | empty export dirs |
| `docs/diagrams/evpn-vxlan-leaf-spine.drawio` | draw.io topology diagram |
| `tests/test_evpn_vxlan.sh` | structure, config, end-to-end stub tests |
| `tests/test_docs.sh` | conventions and simulator-doc assertions |
| `docs/conventions.md` | "Dataplane plumbing" section |
| `docs/simulators/gns3.md`, `docs/simulators/eve-ng.md` | one sentence on `exec:` plumbing not being exported |

---

### Task 1: Scenario skeleton and structure tests

**Files:**
- Create: `scenarios/evpn-vxlan-leaf-spine/scenario.yml`, `topology.clab.yml`, `verify.sh` (placeholder), `README.md` (stub), `export/gns3/.gitkeep`, `export/eve-ng/.gitkeep`
- Create: `tests/test_evpn_vxlan.sh`

**Interfaces:**
- Consumes: `tests/helpers.sh` (`assert_eq`, `assert_contains`, `assert_not_contains`, `assert_succeeds`, `assert_file_exists`, `make_tmpdir`, `run_tests`), `scripts/lib.sh` (`validate_scenario_yml DIR`, `meta DIR .path`, `build_topology DIR VARIANT` which prints the built file path).
- Produces: test-file globals `SCN`, `ROUTERS`, `LEAVES`, `SPINES`, `LINKS`, helpers `built`, `cleanup_built`, `exec_of NODE` used by Tasks 2–5.

- [ ] **Step 1: Write failing tests**

`tests/test_evpn_vxlan.sh`:
```bash
#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

SCN="$REPO_ROOT/scenarios/evpn-vxlan-leaf-spine"
SPINES="spine1 spine2"
LEAVES="leaf1 leaf2"
ROUTERS="$SPINES $LEAVES"

built() { build_topology "$SCN" frr; }
cleanup_built() { rm -f "$SCN"/.*.build.clab.yml; }
# helpers.sh already installs an EXIT trap; extend it rather than replace it.
trap '_cleanup_tmpdirs; cleanup_built' EXIT

# Link table: "A_endpoint B_endpoint"
LINKS="
leaf1:eth1 spine1:eth1
leaf1:eth2 spine2:eth1
leaf2:eth1 spine1:eth2
leaf2:eth2 spine2:eth2
leaf1:eth3 h1:eth1
leaf2:eth3 h2:eth1
"

exec_of() { N="$1" yq -r '.topology.nodes[strenv(N)].exec | join("\n")' "$SCN/topology.clab.yml"; }

test_scenario_yml_is_valid() { assert_succeeds validate_scenario_yml "$SCN"; }
test_scenario_is_draft_with_frr_variant() {
  assert_eq draft "$(meta "$SCN" .status)"
  assert_eq frr "$(meta "$SCN" .default_variant)"
  assert_eq "quay.io/frrouting/frr:10.1" "$(meta "$SCN" .variants.frr.images.router)"
  assert_eq "wbitt/network-multitool:latest" "$(meta "$SCN" .variants.frr.images.host)"
  assert_eq none "$(meta "$SCN" .simulators.gns3)"
  assert_eq none "$(meta "$SCN" '.simulators["eve-ng"]')"
  assert_file_exists "$SCN/export/gns3/.gitkeep"
  assert_file_exists "$SCN/export/eve-ng/.gitkeep"
}
test_topology_nodes() {
  local t; t="$SCN/topology.clab.yml"
  assert_eq evpn-vxlan-leaf-spine "$(yq -r .name "$t")"
  assert_eq "h1 h2 leaf1 leaf2 spine1 spine2" "$(yq -r '.topology.nodes | keys | sort | join(" ")' "$t")"
  assert_eq 4 "$(yq -r '[.topology.nodes[] | select(.image == "quay.io/frrouting/frr:10.1")] | length' "$t")"
  assert_eq 2 "$(yq -r '[.topology.nodes[] | select(.image == "wbitt/network-multitool:latest")] | length' "$t")"
  assert_eq 6 "$(yq -r '[.topology.nodes[] | select(.kind == "linux")] | length' "$t")"
}
test_topology_links_match_table() {
  local t; t="$SCN/topology.clab.yml"
  assert_eq 6 "$(yq -r '.topology.links | length' "$t")"
  local a b
  while read -r a b; do
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
test_routers_housekeeping_exec() {
  local r e
  for r in $ROUTERS; do
    e="$(exec_of "$r")"
    assert_eq "ip route del default" "$(head -1 <<<"$e")" "$r drops the management default first"
    assert_contains "$e" "sysctl -qw net.ipv6.conf.all.disable_ipv6=0" "$r enables IPv6 for BGP unnumbered"
  done
  for r in $SPINES; do
    assert_not_contains "$(exec_of "$r")" "ip link" "$r has no dataplane plumbing"
  done
}
test_leaf_dataplane_exec() {
  local e
  e="$(exec_of leaf1)"
  assert_contains "$e" "ip link add br10 type bridge"
  assert_contains "$e" "ip link add vxlan10 type vxlan id 10 local 10.0.0.11 dstport 4789 nolearning"
  assert_contains "$e" "ip link set vxlan10 master br10"
  assert_contains "$e" "ip link set eth3 master br10"
  assert_contains "$e" "ip link set br10 up"
  assert_contains "$e" "ip link set vxlan10 up"
  assert_contains "$e" "ip link set eth3 up"
  e="$(exec_of leaf2)"
  assert_contains "$e" "ip link add vxlan10 type vxlan id 10 local 10.0.0.12 dstport 4789 nolearning"
  assert_contains "$e" "ip link set eth3 master br10"
  # Order: bridge exists before anything is enslaved to it, devices up last.
  assert_eq "$(printf '%s\n' "ip link add br10 type bridge" "ip link add vxlan10 type vxlan id 10 local 10.0.0.12 dstport 4789 nolearning" "ip link set vxlan10 master br10" "ip link set eth3 master br10" "ip link set br10 up" "ip link set vxlan10 up" "ip link set eth3 up")" \
    "$(grep '^ip link' <<<"$e")" "leaf2 plumbing order"
}
test_hosts_get_address_only() {
  local e
  e="$(exec_of h1)"
  assert_contains "$e" "ip addr add 10.10.0.1/24 dev eth1"
  assert_not_contains "$e" "ip route" "h1 keeps its management route and needs no fabric default"
  e="$(exec_of h2)"
  assert_contains "$e" "ip addr add 10.10.0.2/24 dev eth1"
  assert_not_contains "$e" "ip route" "h2 keeps its management route and needs no fabric default"
}
test_verify_placeholder_is_executable_and_sources_lib() {
  [[ -x "$SCN/verify.sh" ]]
  # shellcheck disable=SC2016
  assert_contains "$(cat "$SCN/verify.sh")" 'source "${LIB_SH:?'
}
test_all_bind_sources_exist_in_built_topology() {
  local t src n=0; t="$(built)"
  while IFS= read -r src; do
    assert_file_exists "$(dirname "$t")/$src"
    n=$((n + 1))
  done < <(yq -r '.topology.nodes[].binds[]? | split(":") | .[0]' "$t")
  assert_eq 8 "$n" "bind source count"
}

run_tests
```

- [ ] **Step 2: Run to verify failure**

Run: `chmod +x tests/test_evpn_vxlan.sh && bash tests/test_evpn_vxlan.sh 2>&1 | tail -3`
Expected: all tests FAIL (scenario missing).

- [ ] **Step 3: Create `scenario.yml`**

```yaml
# Leaf-spine fabric: eBGP unnumbered underlay, BGP EVPN overlay, one L2 VNI. Topology in topology.clab.yml.
name: evpn-vxlan-leaf-spine
title: Two-spine two-leaf EVPN/VXLAN fabric with a stretched VLAN and spine-uplink failover
topic: datacenter/evpn-vxlan
status: draft                     # flip to ready after a live containerlab run (see README)
default_variant: frr
variants:
  frr:
    images:
      router: quay.io/frrouting/frr:10.1
      host: wbitt/network-multitool:latest
    notes: free images only; FRR 10.x syntax; Linux kernel bridge + VXLAN dataplane
simulators:
  containerlab: native
  gns3: none
  eve-ng: none
```

- [ ] **Step 4: Create `topology.clab.yml`**

```yaml
# Single source of truth. Interface names are explicit in every link so the
# README's ethN table and verify.sh's `ip link set eth1 down` on leaf1 are unambiguous.
#
# Routers drop the management default route (a kernel route that would shadow
# fabric routes) and enable IPv6 on every interface: BGP unnumbered peers over
# IPv6 link-local addresses learned from router advertisements.
# Leaves also build the Linux dataplane: bridge br10 with the VXLAN device
# (VNI 10, source = loopback, nolearning so remote MACs come only from EVPN)
# and the host-facing eth3 as an untagged access port.
name: evpn-vxlan-leaf-spine

topology:
  nodes:
    spine1:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/spine1/frr.conf:/etc/frr/frr.conf
        - configs/spine1/daemons:/etc/frr/daemons
      exec:
        - ip route del default
        - sysctl -qw net.ipv6.conf.all.disable_ipv6=0
    spine2:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/spine2/frr.conf:/etc/frr/frr.conf
        - configs/spine2/daemons:/etc/frr/daemons
      exec:
        - ip route del default
        - sysctl -qw net.ipv6.conf.all.disable_ipv6=0
    leaf1:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/leaf1/frr.conf:/etc/frr/frr.conf
        - configs/leaf1/daemons:/etc/frr/daemons
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
    leaf2:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/leaf2/frr.conf:/etc/frr/frr.conf
        - configs/leaf2/daemons:/etc/frr/daemons
      exec:
        - ip route del default
        - sysctl -qw net.ipv6.conf.all.disable_ipv6=0
        - ip link add br10 type bridge
        - ip link add vxlan10 type vxlan id 10 local 10.0.0.12 dstport 4789 nolearning
        - ip link set vxlan10 master br10
        - ip link set eth3 master br10
        - ip link set br10 up
        - ip link set vxlan10 up
        - ip link set eth3 up
    h1:
      kind: linux
      image: wbitt/network-multitool:latest
      exec:
        - ip addr add 10.10.0.1/24 dev eth1
    h2:
      kind: linux
      image: wbitt/network-multitool:latest
      exec:
        - ip addr add 10.10.0.2/24 dev eth1
  links:
    - endpoints: ["leaf1:eth1", "spine1:eth1"]   # taken down in the failover test
    - endpoints: ["leaf1:eth2", "spine2:eth1"]
    - endpoints: ["leaf2:eth1", "spine1:eth2"]
    - endpoints: ["leaf2:eth2", "spine2:eth2"]
    - endpoints: ["leaf1:eth3", "h1:eth1"]       # VLAN 10 access port
    - endpoints: ["leaf2:eth3", "h2:eth1"]       # VLAN 10 access port
```

- [ ] **Step 5: Placeholder `verify.sh`, README stub, export dirs, empty config dirs**

`scenarios/evpn-vxlan-leaf-spine/verify.sh`:
```bash
#!/usr/bin/env bash
# Verification for evpn-vxlan-leaf-spine. Run via: scripts/verify.sh evpn-vxlan-leaf-spine
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib.sh
source "${LIB_SH:?run this via scripts/verify.sh}"

fail "verify.sh not implemented yet"
```

`README.md` stub with headings only: `# evpn-vxlan-leaf-spine`, `## Objective`, `## Topology`, `## Design`, `## Tasks`, `## Verification`, `## Failover walkthrough`, `## Validation on a containerlab host`, `## Simulators`, `## Teardown`.

The bind-source test needs the eight config files to exist. Create them as placeholders that Tasks 2 and 3 overwrite:

```bash
cd scenarios/evpn-vxlan-leaf-spine
mkdir -p export/gns3 export/eve-ng configs/spine1 configs/spine2 configs/leaf1 configs/leaf2
touch export/gns3/.gitkeep export/eve-ng/.gitkeep
for r in spine1 spine2 leaf1 leaf2; do printf '! placeholder, replaced in Task 2/3\n' >configs/$r/frr.conf; printf '# placeholder\n' >configs/$r/daemons; done
chmod +x verify.sh
```

- [ ] **Step 6: Run tests**

Run: `bash tests/test_evpn_vxlan.sh && scripts/test.sh`
Expected: `test_evpn_vxlan.sh: 10 tests, 0 failed`; `ALL PASSED`; `git status` shows no `.build.clab.yml`.

- [ ] **Step 7: Commit**

```bash
git add scenarios/evpn-vxlan-leaf-spine tests/test_evpn_vxlan.sh
git commit -m "feat: scaffold evpn-vxlan-leaf-spine scenario (metadata, topology, dataplane exec)"
```

---

### Task 2: Spine configs (spine1, spine2)

**Files:**
- Modify: `scenarios/evpn-vxlan-leaf-spine/configs/spine1/{frr.conf,daemons}`, `configs/spine2/{frr.conf,daemons}` (replace placeholders)
- Modify: `tests/test_evpn_vxlan.sh`

**Interfaces:**
- Consumes: `SCN`, `SPINES`, `LEAVES`, `ROUTERS` from Task 1.
- Produces: test helpers `cfg NODE`, `daemons_of NODE`, `block NODE SECTION_HEADER` (prints one `interface X` / `router bgp N` block), `assert_router_base NODE LOOPBACK ASN`, `assert_fabric_bgp NODE`, `assert_ra_on NODE IFACE...`, reused by Task 3.

- [ ] **Step 1: Write failing tests** (insert above `run_tests`)

```bash
cfg() { cat "$SCN/configs/$1/frr.conf"; }
daemons_of() { cat "$SCN/configs/$1/daemons"; }
# Print one config block: from the line equal to $2 up to the next "!" line.
block() { sed -n "/^$2\$/,/^!/p" "$SCN/configs/$1/frr.conf"; }

# Every router: hostname, loopback, BGP base in its ASN, daemons sane.
assert_router_base() { # NODE LOOPBACK ASN
  local c; c="$(cfg "$1")"
  assert_contains "$c" "hostname $1"
  assert_contains "$(block "$1" "interface lo")" " ip address $2/32" "$1 loopback"
  assert_contains "$c" "router bgp $3"
  assert_contains "$c" " bgp router-id $2"
  local d; d="$(daemons_of "$1")"
  assert_contains "$d" "zebra=yes"
  assert_contains "$d" "bgpd=yes"
  assert_contains "$d" "ospfd=no"
  assert_contains "$d" "staticd=yes"
  assert_contains "$d" "vtysh_enable=yes"
}
# Unnumbered fabric peering shared by spines and leaves.
assert_fabric_bgp() { # NODE
  local b; b="$(sed -n '/^router bgp /,/^!/p' "$SCN/configs/$1/frr.conf")"
  assert_contains "$b" " no bgp ebgp-requires-policy"
  assert_contains "$b" " no bgp default ipv4-unicast"
  assert_contains "$b" " bgp bestpath as-path multipath-relax"
  assert_contains "$b" " neighbor fabric peer-group"
  assert_contains "$b" " neighbor fabric remote-as external"
  assert_contains "$b" " neighbor eth1 interface peer-group fabric"
  assert_contains "$b" " neighbor eth2 interface peer-group fabric"
  assert_contains "$b" " address-family ipv4 unicast"
  assert_contains "$b" "  redistribute connected"
  assert_contains "$b" " address-family l2vpn evpn"
  assert_eq 2 "$(grep -c '  neighbor fabric activate' <<<"$b")" "$1 activates the peer-group in both address families"
  assert_not_contains "$b" "neighbor eth3" "$1 host port is not a BGP peer"
}
# Router advertisements on each listed fabric interface (leaves learn link-local peers from them).
assert_ra_on() { # NODE IFACE...
  local r="$1"; shift
  local i b
  for i in "$@"; do
    b="$(block "$r" "interface $i")"
    assert_contains "$b" " no ipv6 nd suppress-ra" "$r $i RA enabled"
    assert_contains "$b" " ipv6 nd ra-interval 10" "$r $i RA interval"
    assert_not_contains "$b" " ip address" "$r $i is unnumbered"
  done
}

test_spine_configs_exist() {
  local r; for r in $SPINES; do assert_file_exists "$SCN/configs/$r/frr.conf"; assert_file_exists "$SCN/configs/$r/daemons"; done
}
test_spine_base_and_fabric_bgp() {
  assert_router_base spine1 10.0.0.1 65100; assert_fabric_bgp spine1; assert_ra_on spine1 eth1 eth2
  assert_router_base spine2 10.0.0.2 65100; assert_fabric_bgp spine2; assert_ra_on spine2 eth1 eth2
}
test_spines_relay_evpn_without_vtep_role() {
  local r c
  for r in $SPINES; do
    c="$(cfg "$r")"
    assert_not_contains "$c" "advertise-all-vni" "$r is not a VTEP"
    assert_not_contains "$c" " vni 10" "$r has no VNI block"
    assert_not_contains "$c" "route-target" "$r has no route-targets"
  done
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_evpn_vxlan.sh 2>&1 | tail -4`
Expected: the three `test_spine*` tests FAIL (placeholders lack the markers); earlier tests still pass.

- [ ] **Step 3: Write `configs/spine1/frr.conf`**

```
! spine1: AS 65100 spine. Unnumbered eBGP to both leaves, relays EVPN routes, no VTEP role.
frr defaults traditional
hostname spine1
log syslog informational
!
interface lo
 ip address 10.0.0.1/32
!
interface eth1
 description spine1-leaf1
 no ipv6 nd suppress-ra
 ipv6 nd ra-interval 10
!
interface eth2
 description spine1-leaf2
 no ipv6 nd suppress-ra
 ipv6 nd ra-interval 10
!
router bgp 65100
 bgp router-id 10.0.0.1
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 bgp bestpath as-path multipath-relax
 neighbor fabric peer-group
 neighbor fabric remote-as external
 neighbor eth1 interface peer-group fabric
 neighbor eth2 interface peer-group fabric
 !
 address-family ipv4 unicast
  redistribute connected
  neighbor fabric activate
 exit-address-family
 !
 address-family l2vpn evpn
  neighbor fabric activate
 exit-address-family
!
line vty
!
```

- [ ] **Step 4: Write `configs/spine2/frr.conf`**

Identical to spine1 except the first line (`! spine2: AS 65100 spine. ...`), `hostname spine2`, loopback `10.0.0.2/32`, `bgp router-id 10.0.0.2`, and the descriptions `spine2-leaf1` on `eth1` and `spine2-leaf2` on `eth2`.

- [ ] **Step 5: Write the two `daemons` files**

Same content for `configs/spine1/daemons` and `configs/spine2/daemons`:
```
# FRR daemons for an EVPN fabric router: zebra + bgpd (EVPN lives in bgpd).
zebra=yes
bgpd=yes
ospfd=no
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

- [ ] **Step 6: Run tests**

Run: `bash tests/test_evpn_vxlan.sh && scripts/test.sh`
Expected: `test_evpn_vxlan.sh: 13 tests, 0 failed`; `ALL PASSED`.

- [ ] **Step 7: Commit**

```bash
git add scenarios/evpn-vxlan-leaf-spine/configs/spine1 scenarios/evpn-vxlan-leaf-spine/configs/spine2 tests/test_evpn_vxlan.sh
git commit -m "feat: add spine FRR configs (eBGP unnumbered + EVPN relay) for evpn-vxlan-leaf-spine"
```

---

### Task 3: Leaf configs (leaf1, leaf2)

**Files:**
- Modify: `scenarios/evpn-vxlan-leaf-spine/configs/leaf1/{frr.conf,daemons}`, `configs/leaf2/{frr.conf,daemons}` (replace placeholders)
- Modify: `tests/test_evpn_vxlan.sh`

**Interfaces:**
- Consumes: `cfg`, `daemons_of`, `block`, `assert_router_base`, `assert_fabric_bgp`, `assert_ra_on` from Task 2.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Write failing tests** (insert above `run_tests`)

```bash
test_leaf_configs_exist() {
  local r; for r in $LEAVES; do assert_file_exists "$SCN/configs/$r/frr.conf"; assert_file_exists "$SCN/configs/$r/daemons"; done
}
test_leaf_base_and_fabric_bgp() {
  assert_router_base leaf1 10.0.0.11 65001; assert_fabric_bgp leaf1; assert_ra_on leaf1 eth1 eth2
  assert_router_base leaf2 10.0.0.12 65002; assert_fabric_bgp leaf2; assert_ra_on leaf2 eth1 eth2
}
test_leaves_are_vteps_with_explicit_route_targets() {
  local r e
  for r in $LEAVES; do
    e="$(sed -n '/^ address-family l2vpn evpn$/,/^ exit-address-family/p' "$SCN/configs/$r/frr.conf")"
    assert_contains "$e" "  advertise-all-vni" "$r advertises its VNIs"
    assert_contains "$e" "  vni 10" "$r VNI block"
    assert_contains "$e" "   rd auto" "$r RD"
    assert_contains "$e" "   route-target import 65000:10" "$r RT import"
    assert_contains "$e" "   route-target export 65000:10" "$r RT export"
    assert_contains "$e" "  exit-vni" "$r closes the VNI block"
    assert_not_contains "$(cfg "$r")" "interface eth3" "$r eth3 is a bridge member, not an FRR interface"
  done
}
test_leaf_asns_differ_and_match_spec() {
  assert_contains "$(cfg leaf1)" "router bgp 65001"
  assert_contains "$(cfg leaf2)" "router bgp 65002"
  assert_not_contains "$(cfg leaf1)" "router bgp 65002"
  assert_not_contains "$(cfg leaf2)" "router bgp 65001"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_evpn_vxlan.sh 2>&1 | tail -5`
Expected: the four `test_leaf*` tests FAIL; the rest pass.

- [ ] **Step 3: Write `configs/leaf1/frr.conf`**

```
! leaf1: AS 65001 leaf and VTEP (10.0.0.11). Unnumbered eBGP to both spines, EVPN for VNI 10.
! Explicit route-targets: FRR auto-derives RT as <ASN>:<VNI>, which would differ per leaf here.
frr defaults traditional
hostname leaf1
log syslog informational
!
interface lo
 ip address 10.0.0.11/32
!
interface eth1
 description leaf1-spine1 (taken down in the failover test)
 no ipv6 nd suppress-ra
 ipv6 nd ra-interval 10
!
interface eth2
 description leaf1-spine2
 no ipv6 nd suppress-ra
 ipv6 nd ra-interval 10
!
router bgp 65001
 bgp router-id 10.0.0.11
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 bgp bestpath as-path multipath-relax
 neighbor fabric peer-group
 neighbor fabric remote-as external
 neighbor eth1 interface peer-group fabric
 neighbor eth2 interface peer-group fabric
 !
 address-family ipv4 unicast
  redistribute connected
  neighbor fabric activate
 exit-address-family
 !
 address-family l2vpn evpn
  neighbor fabric activate
  advertise-all-vni
  vni 10
   rd auto
   route-target import 65000:10
   route-target export 65000:10
  exit-vni
 exit-address-family
!
line vty
!
```

- [ ] **Step 4: Write `configs/leaf2/frr.conf`**

Identical to leaf1 except the first comment line (`! leaf2: AS 65002 leaf and VTEP (10.0.0.12). ...`), `hostname leaf2`, loopback `10.0.0.12/32`, `router bgp 65002`, `bgp router-id 10.0.0.12`, and descriptions `leaf2-spine1` on `eth1` (no "taken down" note) and `leaf2-spine2` on `eth2`.

- [ ] **Step 5: Write the two `daemons` files**

Same content as the spine `daemons` file in Task 2 Step 5 (zebra, bgpd, staticd on; the rest off; `vtysh_enable=yes`; the `*_options` lines).

- [ ] **Step 6: Run tests**

Run: `bash tests/test_evpn_vxlan.sh && scripts/test.sh`
Expected: `test_evpn_vxlan.sh: 17 tests, 0 failed`; `ALL PASSED`.

- [ ] **Step 7: Commit**

```bash
git add scenarios/evpn-vxlan-leaf-spine/configs/leaf1 scenarios/evpn-vxlan-leaf-spine/configs/leaf2 tests/test_evpn_vxlan.sh
git commit -m "feat: add leaf FRR configs (VTEPs, advertise-all-vni, explicit RTs) for evpn-vxlan-leaf-spine"
```

---

### Task 4: `verify.sh` with failover, and stateful stub tests

**Files:**
- Modify: `scenarios/evpn-vxlan-leaf-spine/verify.sh` (replace placeholder)
- Modify: `tests/test_evpn_vxlan.sh`

**Interfaces:**
- Consumes: `scripts/lib.sh` helpers `log`, `fail`, `node_exec NODE CMD` (runs `docker exec clab-<lab>-NODE sh -c CMD`), `expect_contains NODE CMD EXPECTED`, `expect_not_contains NODE CMD UNEXPECTED`, `wait_for TIMEOUT NODE CMD EXPECTED` (fails with `'<cmd>' did not contain '<expected>'`). `scripts/verify.sh` exports `LAB_NAME`, `VARIANT`, `LIB_SH` and honours `DOCKER`, `WAIT_INTERVAL`.
- Produces: test helpers `make_frr_stub ROOT MODE` and `run_verify ROOT`.

- [ ] **Step 1: Write failing tests** (insert above `run_tests`)

```bash
# Stateful docker stub. The second argv word is the container name; the command is $5.
# It records "ip link set eth1 down/up" (leaf1's uplink to spine1) and whether a host
# ping has happened (MAC learning needs traffic), so routes and EVPN tables change state.
H1_MAC="aa:c1:ab:00:00:01"
H2_MAC="aa:c1:ab:00:00:02"
make_frr_stub() { # ROOT MODE
  local root="$1" mode="$2"
  mkdir -p "$root/bin"
  cat >"$root/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/docker.log"
node="\${2#clab-evpn-vxlan-leaf-spine-}"
cmd="\${5:-}"
mode="$mode"
down="$root/eth1_down"
pinged="$root/pinged"
h1mac="$H1_MAC"; h2mac="$H2_MAC"
# Two next hops normally; one once leaf1 eth1 is down (unless no-failover) or always in single-path.
paths() {
  if [[ "\$mode" == single-path ]]; then echo 1
  elif [[ -e "\$down" && "\$mode" != no-failover ]]; then echo 1
  else echo 2; fi
}
case "\$cmd" in
  *"ip link set eth1 down"*) touch "\$down"; exit 0 ;;
  *"ip link set eth1 up"*)   rm -f "\$down"; exit 0 ;;
  *"show version"*) echo "FRRouting 10.1 (\$node)" ;;
  *"show bgp ipv4 unicast summary json"*)
    if [[ "\$mode" == bgp-active && "\$node" == spine1 ]]; then echo 1; else echo 2; fi ;;
  *"show bgp l2vpn evpn summary json"*)
    if [[ "\$mode" == evpn-down && "\$node" == leaf1 ]]; then echo 1; else echo 2; fi ;;
  *"show bgp ipv4 unicast summary"*)
    echo "Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc"
    echo "eth1            4      65100       120       118        0    0    0 00:10:00            1        1 N/A"
    echo "eth2            4      65100       120       118        0    0    0 00:10:00            1        1 N/A" ;;
  *"show ip route 10.0.0.12/32' | grep -c"*|*"show ip route 10.0.0.11/32' | grep -c"*)
    paths ;;
  *"show ip route 10.0.0.12/32"*|*"show ip route 10.0.0.11/32"*)
    echo "Routing entry for 10.0.0.1x/32"
    echo '  Known via "bgp", distance 20, metric 0, best'
    echo "  Last update 00:10:00 ago"
    [[ "\$(paths)" == 2 ]] && echo "  * fe80::a8c1:abff:fe00:1, via eth1, weight 1"
    echo "  * fe80::a8c1:abff:fe00:2, via eth2, weight 1" ;;
  *"show evpn vni 10"*)
    echo "VNI: 10"
    echo " Type: L2"
    echo " VxLAN interface: vxlan10"
    if [[ "\$node" == leaf1 ]]; then echo " Local VTEP IP: 10.0.0.11"; r=10.0.0.12; else echo " Local VTEP IP: 10.0.0.12"; r=10.0.0.11; fi
    echo " Remote VTEPs for this VNI:"
    [[ "\$mode" == no-vtep ]] || echo "  \$r flood: HER" ;;
  *"show evpn mac vni 10"*)
    # Emulate the appended "| grep -i <mac>": print only the matching row.
    if [[ ! -e "\$pinged" ]]; then exit 0; fi
    case "\$cmd" in
      *"\$h1mac"*)
        if [[ "\$node" == leaf1 ]]; then echo "\$h1mac local eth3 0/0 0 0"
        elif [[ "\$mode" != mac-local-only ]]; then echo "\$h1mac remote 10.0.0.11 0/0 0 0"; fi ;;
      *"\$h2mac"*)
        if [[ "\$node" == leaf2 ]]; then echo "\$h2mac local eth3 0/0 0 0"
        elif [[ "\$mode" != mac-local-only ]]; then echo "\$h2mac remote 10.0.0.12 0/0 0 0"; fi ;;
    esac ;;
  *"cat /sys/class/net/eth1/address"*)
    if [[ "\$node" == h1 ]]; then echo "\$h1mac"; else echo "\$h2mac"; fi ;;
  *ping*) touch "\$pinged"; echo "3 packets transmitted, 3 received, 0% packet loss" ;;
  *) echo "unknown" ;;
esac
STUB
  chmod +x "$root/bin/docker"
}
run_verify() { # ROOT
  LIB_REPO_ROOT="$REPO_ROOT" DOCKER="$1/bin/docker" WAIT_INTERVAL=1 BOOT_TIMEOUT=2 BGP_TIMEOUT=2 EVPN_TIMEOUT=2 \
    "$REPO_ROOT/scripts/verify.sh" evpn-vxlan-leaf-spine
}

test_verify_passes_against_healthy_stub() {
  local root out; root="$(make_tmpdir)"; make_frr_stub "$root" ok
  out="$(run_verify "$root" 2>&1)"
  assert_contains "$out" "all checks passed"
  local dk; dk="$(cat "$root/docker.log")"
  assert_contains "$dk" "clab-evpn-vxlan-leaf-spine-leaf1 sh -c ip link set eth1 down"
  assert_contains "$dk" "clab-evpn-vxlan-leaf-spine-leaf1 sh -c ip link set eth1 up"
  assert_contains "$dk" "clab-evpn-vxlan-leaf-spine-spine2 sh -c vtysh -c 'show bgp l2vpn evpn summary json'"
  assert_contains "$dk" "clab-evpn-vxlan-leaf-spine-leaf2 sh -c vtysh -c 'show evpn mac vni 10' | grep -i $H1_MAC"
  assert_contains "$dk" "clab-evpn-vxlan-leaf-spine-h1 sh -c ping -c 3 -W 2 10.10.0.2"
  assert_not_contains "$dk" "ping -c 3 -W 2 10.10.0.1" "h2 never has to ping; one direction proves the stretched VLAN"
  [[ ! -e "$root/eth1_down" ]] || return 1   # link restored at the end
}
test_verify_fails_when_bgp_active() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" bgp-active
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "spine1: 'vtysh -c 'show bgp ipv4 unicast summary json'"
  assert_contains "$out" "did not contain '2'"
  assert_not_contains "$(cat "$root/docker.log")" "ip link set eth1 down" "failover never reached"
}
test_verify_fails_when_evpn_session_down() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" evpn-down
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "leaf1: 'vtysh -c 'show bgp l2vpn evpn summary json'"
  assert_contains "$out" "did not contain '2'"
}
test_verify_fails_when_single_path_before_failover() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" single-path
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "leaf1: 'vtysh -c 'show ip route 10.0.0.12/32' | grep -c ' eth[12]'' did not contain '2'"
  assert_not_contains "$(cat "$root/docker.log")" "show evpn vni" "fails before the EVPN checks"
}
test_verify_fails_when_no_remote_vtep() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" no-vtep
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "leaf1: 'vtysh -c 'show evpn vni 10'' did not contain '10.0.0.12'"
  assert_not_contains "$(cat "$root/docker.log")" "ping" "fails before any host traffic"
}
test_verify_fails_when_mac_only_local() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" mac-local-only
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "leaf2: 'vtysh -c 'show evpn mac vni 10' | grep -i $H1_MAC' did not contain '10.0.0.11'"
  assert_not_contains "$(cat "$root/docker.log")" "ip link set eth1 down" "failover never reached"
}
test_verify_fails_when_no_failover_and_still_restores_link() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" no-failover
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "leaf1: 'vtysh -c 'show ip route 10.0.0.12/32' | grep -c ' eth[12]'' did not contain '1'"
  assert_eq "ip link set eth1 up" "$(grep -o 'ip link set eth1 [a-z]*' "$root/docker.log" | tail -1)" "trap restored the link"
  [[ ! -e "$root/eth1_down" ]] || return 1
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_evpn_vxlan.sh 2>&1 | tail -9`
Expected: the seven `test_verify_*` tests FAIL (placeholder prints `verify.sh not implemented yet`); the rest pass.

- [ ] **Step 3: Write `verify.sh`**

```bash
#!/usr/bin/env bash
# Verification for evpn-vxlan-leaf-spine. Run via: scripts/verify.sh evpn-vxlan-leaf-spine
# scripts/verify.sh exports LAB_NAME, VARIANT and LIB_SH before calling this.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib.sh
source "${LIB_SH:?run this via scripts/verify.sh}"

boot_timeout="${BOOT_TIMEOUT:-60}"
bgp_timeout="${BGP_TIMEOUT:-120}"
evpn_timeout="${EVPN_TIMEOUT:-60}"

routers="spine1 spine2 leaf1 leaf2"
# Next-hop lines in the per-prefix view read "fe80::..., via eth1, weight 1";
# counting " eth[12]" tokens counts installed paths without depending on link-local addresses.
nexthops="grep -c ' eth[12]'"

log "== 1. FRR up on all routers"
for r in $routers; do
  wait_for "$boot_timeout" "$r" "vtysh -c 'show version'" "FRRouting"
done

log "== 2. BGP Established in ipv4 unicast and l2vpn evpn (two fabric neighbours per router)"
for r in $routers; do
  wait_for "$bgp_timeout" "$r" "vtysh -c 'show bgp ipv4 unicast summary json' | grep -c '\"state\":\"Established\"'" "2"
  wait_for "$bgp_timeout" "$r" "vtysh -c 'show bgp l2vpn evpn summary json' | grep -c '\"state\":\"Established\"'" "2"
  for state in Active Connect; do
    expect_not_contains "$r" "vtysh -c 'show bgp ipv4 unicast summary'" "$state"
  done
done

log "== 3. Remote leaf loopback reachable via both spines (ECMP)"
wait_for "$bgp_timeout" leaf1 "vtysh -c 'show ip route 10.0.0.12/32' | $nexthops" "2"
expect_contains leaf1 "vtysh -c 'show ip route 10.0.0.12/32'" 'Known via "bgp"'
wait_for "$bgp_timeout" leaf2 "vtysh -c 'show ip route 10.0.0.11/32' | $nexthops" "2"
expect_contains leaf2 "vtysh -c 'show ip route 10.0.0.11/32'" 'Known via "bgp"'

log "== 4. VTEP discovery: each leaf learns the other as a remote VTEP (EVPN type-3)"
wait_for "$evpn_timeout" leaf1 "vtysh -c 'show evpn vni 10'" "10.0.0.12"
wait_for "$evpn_timeout" leaf2 "vtysh -c 'show evpn vni 10'" "10.0.0.11"

log "== 5. Host reachability and MAC learning across the fabric (EVPN type-2)"
h1_mac="$(node_exec h1 "cat /sys/class/net/eth1/address")"
h2_mac="$(node_exec h2 "cat /sys/class/net/eth1/address")"
wait_for 30 h1 "ping -c 3 -W 2 10.10.0.2" "3 received"
wait_for "$evpn_timeout" leaf2 "vtysh -c 'show evpn mac vni 10' | grep -i $h1_mac" "10.0.0.11"
expect_contains leaf2 "vtysh -c 'show evpn mac vni 10' | grep -i $h1_mac" "remote"
expect_contains leaf1 "vtysh -c 'show evpn mac vni 10' | grep -i $h1_mac" "local"
wait_for "$evpn_timeout" leaf1 "vtysh -c 'show evpn mac vni 10' | grep -i $h2_mac" "10.0.0.12"
expect_contains leaf1 "vtysh -c 'show evpn mac vni 10' | grep -i $h2_mac" "remote"

log "== 6. Failover: leaf1 loses its uplink to spine1 (eth1); spine2 must carry the traffic"
restore_link() { node_exec leaf1 "ip link set eth1 up" >/dev/null 2>&1 || true; }
trap restore_link EXIT
node_exec leaf1 "ip link set eth1 down"
wait_for "$bgp_timeout" leaf1 "vtysh -c 'show ip route 10.0.0.12/32' | $nexthops" "1"
expect_not_contains leaf1 "vtysh -c 'show ip route 10.0.0.12/32'" "eth1"
expect_contains     leaf1 "vtysh -c 'show ip route 10.0.0.12/32'" "eth2"
expect_contains     leaf1 "vtysh -c 'show evpn vni 10'" "10.0.0.12"
wait_for 30 h1 "ping -c 3 -W 2 10.10.0.2" "3 received"

log "== 7. Restore the uplink; both paths return"
node_exec leaf1 "ip link set eth1 up"
trap - EXIT
wait_for "$bgp_timeout" leaf1 "vtysh -c 'show ip route 10.0.0.12/32' | $nexthops" "2"
wait_for 30 h1 "ping -c 3 -W 2 10.10.0.2" "3 received"

log "all checks passed"
```

Note on the `nexthops` variable: it is expanded inside the double-quoted command string, so the command lib.sh runs is literally `vtysh -c 'show ip route 10.0.0.12/32' | grep -c ' eth[12]'`, which is what the stub matches and what the failure messages in the tests quote.

- [ ] **Step 4: Run tests**

Run: `shellcheck scenarios/evpn-vxlan-leaf-spine/verify.sh tests/test_evpn_vxlan.sh && bash tests/test_evpn_vxlan.sh && scripts/test.sh`
Expected: no shellcheck output; `test_evpn_vxlan.sh: 24 tests, 0 failed`; `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add scenarios/evpn-vxlan-leaf-spine/verify.sh tests/test_evpn_vxlan.sh
git commit -m "feat: add evpn-vxlan-leaf-spine verification with spine-uplink failover and stub tests"
```

---

### Task 5: Documentation and diagram

**Files:**
- Modify: `scenarios/evpn-vxlan-leaf-spine/README.md` (replace stub)
- Create: `docs/diagrams/evpn-vxlan-leaf-spine.drawio`
- Modify: `docs/conventions.md` (add "### Dataplane plumbing" after "### Management default route")
- Modify: `docs/simulators/gns3.md`, `docs/simulators/eve-ng.md` (one bullet each under "## Hand-written export rules")
- Modify: `tests/test_docs.sh`, `tests/test_evpn_vxlan.sh`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_docs.sh` above `run_tests`:
```bash
test_conventions_describe_dataplane_plumbing() {
  local c; c="$(cat "$REPO_ROOT/docs/conventions.md")"
  assert_contains "$c" "### Dataplane plumbing"
  assert_contains "$c" "exec:"
  assert_contains "$c" "wait_for"
}
test_simulator_docs_note_exec_plumbing_is_not_exported() {
  assert_contains "$(cat "$REPO_ROOT/docs/simulators/gns3.md")" "exec:"
  assert_contains "$(cat "$REPO_ROOT/docs/simulators/eve-ng.md")" "exec:"
}
```
Append to `tests/test_evpn_vxlan.sh` above `run_tests`:
```bash
test_readme_documents_scenario() {
  local r; r="$(cat "$SCN/README.md")"
  for s in "## Objective" "## Topology" "## Design" "## Verification" "## Failover walkthrough" "## Validation on a containerlab host"; do
    assert_contains "$r" "$s"
  done
  assert_contains "$r" "docs/diagrams/evpn-vxlan-leaf-spine.drawio"
  assert_contains "$r" "leaf1:eth1"
  assert_contains "$r" "advertise-all-vni"
  assert_contains "$r" "route-target"
  assert_contains "$r" "nolearning"
  assert_contains "$r" "scripts/up.sh evpn-vxlan-leaf-spine --force"
  assert_contains "$r" "EVPN_TIMEOUT"
  assert_contains "$r" "next-hop-unchanged"
}
test_diagram_file_is_valid_drawio_xml() {
  local d; d="$REPO_ROOT/docs/diagrams/evpn-vxlan-leaf-spine.drawio"
  assert_file_exists "$d"
  assert_succeeds python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$d"
  local x; x="$(cat "$d")"
  for n in spine1 spine2 leaf1 leaf2 h1 h2; do assert_contains "$x" "$n" "diagram names $n"; done
  assert_contains "$x" "VNI 10"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_docs.sh 2>&1 | tail -3; bash tests/test_evpn_vxlan.sh 2>&1 | tail -3`
Expected: the two new docs tests and the two new scenario tests FAIL.

- [ ] **Step 3: Write the README**

`scenarios/evpn-vxlan-leaf-spine/README.md`:
````markdown
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
  loopback into the underlay. `no bgp ebgp-requires-policy` is needed because
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
  and brings them up. `nolearning` turns off kernel MAC learning on the VXLAN
  device, so remote MACs enter the bridge only through EVPN, which is what
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

Known risks to confirm on that run, each with its fallback:

| Risk | Symptom | Fallback |
|---|---|---|
| IPv6 disabled on fabric veths despite the sysctl | BGP neighbours stay `Active`; `ip -6 addr show eth1` has no `fe80::` | Add per-interface `net.ipv6.conf.eth1.disable_ipv6=0` lines to `exec:`. |
| Container lacks `NET_ADMIN` for `ip link add vxlan` | `exec` line fails in `containerlab deploy` output; no `vxlan10` | Add `privileged: true` (or the capability) to the leaf nodes in the topology. |
| Spines rewrite the EVPN next hop to themselves | `show bgp l2vpn evpn` on a leaf shows the spine loopback as next hop; no remote VTEP | Add `neighbor fabric next-hop-unchanged` under `address-family l2vpn evpn` on the spines. |
| Next-hop line format differs from `fe80::…, via eth1, weight 1` | Step 3 or 6 count check fails although `ip route` shows two paths | Adjust the grep pattern in `verify.sh` and the stub in `tests/test_evpn_vxlan.sh` to the real format. |

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
ip link add br10 type bridge
ip link add vxlan10 type vxlan id 10 local 10.0.0.11 dstport 4789 nolearning   # 10.0.0.12 on leaf2
ip link set vxlan10 master br10
ip link set eth3 master br10
ip link set br10 up
ip link set vxlan10 up
ip link set eth3 up
```

## Teardown

`scripts/down.sh evpn-vxlan-leaf-spine`
````

- [ ] **Step 4: Write the draw.io diagram**

`docs/diagrams/evpn-vxlan-leaf-spine.drawio` (same Cisco 19 stencils and colours as the two existing diagrams; `leaf1:eth1` thick amber as the failed link; the VXLAN tunnel dashed teal between the leaves):

```xml
<mxfile host="app.diagrams.net"><diagram name="evpn-vxlan-leaf-spine" id="evpn"><mxGraphModel adaptiveColors="auto"><root><mxCell id="0"/><mxCell id="1" parent="0"/>
<mxCell id="title" value="evpn-vxlan-leaf-spine &lt;small&gt;· 4× FRR, eBGP unnumbered underlay, BGP EVPN overlay, VNI 10&lt;/small&gt;" style="text;html=1;fontSize=20;fontStyle=1;align=left;verticalAlign=middle;" vertex="1" parent="1"><mxGeometry x="40" y="10" width="820" height="40" as="geometry"/></mxCell>
<mxCell id="fabric" value="Fabric · eBGP unnumbered (IPv6 link-local) · spines AS 65100" style="swimlane;startSize=26;fillColor=#dae8fc;strokeColor=#6c8ebf;html=1;fontSize=14;pointerEvents=0;" vertex="1" parent="1"><mxGeometry x="40" y="70" width="820" height="360" as="geometry"/></mxCell>
<mxCell id="spine1" value="spine1&lt;br&gt;&lt;small&gt;lo 10.0.0.1 · AS 65100&lt;/small&gt;" style="sketch=0;verticalLabelPosition=bottom;html=1;verticalAlign=top;aspect=fixed;align=center;pointerEvents=1;shape=mxgraph.cisco19.rect;prIcon=router;fillColor=#FAFAFA;strokeColor=#005073;fontSize=14;labelPerimeter=1;" vertex="1" parent="fabric"><mxGeometry x="218" y="50" width="64" height="50" as="geometry"/></mxCell>
<mxCell id="spine2" value="spine2&lt;br&gt;&lt;small&gt;lo 10.0.0.2 · AS 65100&lt;/small&gt;" style="sketch=0;verticalLabelPosition=bottom;html=1;verticalAlign=top;aspect=fixed;align=center;pointerEvents=1;shape=mxgraph.cisco19.rect;prIcon=router;fillColor=#FAFAFA;strokeColor=#005073;fontSize=14;labelPerimeter=1;" vertex="1" parent="fabric"><mxGeometry x="538" y="50" width="64" height="50" as="geometry"/></mxCell>
<mxCell id="leaf1" value="leaf1 (VTEP)&lt;br&gt;&lt;small&gt;lo 10.0.0.11 · AS 65001&lt;/small&gt;" style="sketch=0;verticalLabelPosition=bottom;html=1;verticalAlign=top;aspect=fixed;align=center;pointerEvents=1;shape=mxgraph.cisco19.rect;prIcon=router;fillColor=#FAFAFA;strokeColor=#005073;fontSize=14;labelPerimeter=1;" vertex="1" parent="fabric"><mxGeometry x="138" y="240" width="64" height="50" as="geometry"/></mxCell>
<mxCell id="leaf2" value="leaf2 (VTEP)&lt;br&gt;&lt;small&gt;lo 10.0.0.12 · AS 65002&lt;/small&gt;" style="sketch=0;verticalLabelPosition=bottom;html=1;verticalAlign=top;aspect=fixed;align=center;pointerEvents=1;shape=mxgraph.cisco19.rect;prIcon=router;fillColor=#FAFAFA;strokeColor=#005073;fontSize=14;labelPerimeter=1;" vertex="1" parent="fabric"><mxGeometry x="618" y="240" width="64" height="50" as="geometry"/></mxCell>
<mxCell id="l1s1" value="leaf1:eth1 · failed in step 6" style="endArrow=none;html=1;strokeWidth=3;strokeColor=#b45309;fontColor=#b45309;labelBackgroundColor=default;defaultLabelBackgroundColor=page;labelPlacement=auto;" edge="1" source="leaf1" target="spine1" parent="fabric"><mxGeometry relative="1" as="geometry"/></mxCell>
<mxCell id="l1s2" value="leaf1:eth2" style="endArrow=none;html=1;strokeColor=#005073;labelBackgroundColor=default;defaultLabelBackgroundColor=page;labelPlacement=auto;" edge="1" source="leaf1" target="spine2" parent="fabric"><mxGeometry relative="1" as="geometry"/></mxCell>
<mxCell id="l2s1" value="leaf2:eth1" style="endArrow=none;html=1;strokeColor=#005073;labelBackgroundColor=default;defaultLabelBackgroundColor=page;labelPlacement=auto;" edge="1" source="leaf2" target="spine1" parent="fabric"><mxGeometry relative="1" as="geometry"/></mxCell>
<mxCell id="l2s2" value="leaf2:eth2" style="endArrow=none;html=1;strokeColor=#005073;labelBackgroundColor=default;defaultLabelBackgroundColor=page;labelPlacement=auto;" edge="1" source="leaf2" target="spine2" parent="fabric"><mxGeometry relative="1" as="geometry"/></mxCell>
<mxCell id="vxlan" value="VXLAN VNI 10 · EVPN type-2/3 · RT 65000:10" style="endArrow=none;html=1;dashed=1;strokeWidth=2;strokeColor=#0b5c6b;fontColor=#0b5c6b;labelBackgroundColor=default;defaultLabelBackgroundColor=page;labelPlacement=auto;verticalAlign=top;" edge="1" source="leaf1" target="leaf2" parent="fabric"><mxGeometry relative="1" as="geometry"/></mxCell>
<mxCell id="h1" value="h1&lt;br&gt;&lt;small&gt;10.10.0.1/24&lt;/small&gt;" style="sketch=0;verticalLabelPosition=bottom;html=1;verticalAlign=top;aspect=fixed;align=center;pointerEvents=1;shape=mxgraph.cisco19.rect;prIcon=host_based_security;fillColor=#FAFAFA;strokeColor=#005073;fontSize=14;labelPerimeter=1;" vertex="1" parent="1"><mxGeometry x="185" y="490" width="50" height="50" as="geometry"/></mxCell>
<mxCell id="h2" value="h2&lt;br&gt;&lt;small&gt;10.10.0.2/24&lt;/small&gt;" style="sketch=0;verticalLabelPosition=bottom;html=1;verticalAlign=top;aspect=fixed;align=center;pointerEvents=1;shape=mxgraph.cisco19.rect;prIcon=host_based_security;fillColor=#FAFAFA;strokeColor=#005073;fontSize=14;labelPerimeter=1;" vertex="1" parent="1"><mxGeometry x="665" y="490" width="50" height="50" as="geometry"/></mxCell>
<mxCell id="lh1" value="eth3 · VLAN 10 access" style="endArrow=none;html=1;strokeColor=#005073;labelBackgroundColor=default;defaultLabelBackgroundColor=page;labelPlacement=auto;" edge="1" source="leaf1" target="h1" parent="1"><mxGeometry relative="1" as="geometry"/></mxCell>
<mxCell id="lh2" value="eth3 · VLAN 10 access" style="endArrow=none;html=1;strokeColor=#005073;labelBackgroundColor=default;defaultLabelBackgroundColor=page;labelPlacement=auto;" edge="1" source="leaf2" target="h2" parent="1"><mxGeometry relative="1" as="geometry"/></mxCell>
<mxCell id="leg" value="Legend: thick amber = uplink failed during verify.sh step 6 (traffic stays up via spine2, restored under trap) · dashed = VXLAN overlay between VTEPs · solid = unnumbered eBGP link" style="text;html=1;align=left;verticalAlign=middle;fontSize=12;" vertex="1" parent="1"><mxGeometry x="40" y="570" width="820" height="30" as="geometry"/></mxCell>
</root></mxGraphModel></diagram></mxfile>
```

- [ ] **Step 5: Add the conventions section**

In `docs/conventions.md`, directly after the "### Management default route" paragraph, add:

```markdown
### Dataplane plumbing

Linux-level objects a scenario needs beyond what FRR configures (bridges,
VXLAN devices, VLAN subinterfaces, sysctls) live in the node's `exec:` list in
`topology.clab.yml`, after `ip route del default`, in the order the kernel
needs them (create the bridge, create and enslave members, bring devices up).
Containerlab runs `exec:` after the container starts, with no ordering
guarantee against FRR's own startup, so `verify.sh` must not assume one: every
check that depends on both (a VNI present, a VTEP learned) is wrapped in
`wait_for`. GNS3 and EVE-NG have no equivalent hook, so a scenario that uses
`exec:` plumbing lists the commands in its README for manual entry.
```

- [ ] **Step 6: Add the simulator-doc bullets**

Under "## Hand-written export rules" in `docs/simulators/gns3.md`, append:
```markdown
- Containerlab `exec:` lines (management-route cleanup, bridge and VXLAN
  plumbing) are not carried into a `.gns3` file; the scenario README lists
  them for manual entry in the node console.
```
Under "## Hand-written export rules" in `docs/simulators/eve-ng.md`, append:
```markdown
- Containerlab `exec:` lines (management-route cleanup, bridge and VXLAN
  plumbing) are not carried into a `.unl` file; the scenario README lists
  them for manual entry in the node console.
```

- [ ] **Step 7: Run tests**

Run: `scripts/test.sh`
Expected: `test_docs.sh: 11 tests, 0 failed`; `test_evpn_vxlan.sh: 26 tests, 0 failed`; `ALL PASSED`.

- [ ] **Step 8: Commit**

```bash
git add scenarios/evpn-vxlan-leaf-spine/README.md docs/diagrams/evpn-vxlan-leaf-spine.drawio docs/conventions.md docs/simulators/gns3.md docs/simulators/eve-ng.md tests/test_docs.sh tests/test_evpn_vxlan.sh
git commit -m "docs: document evpn-vxlan-leaf-spine, add its diagram and the dataplane-plumbing convention"
```

---

### Task 6: Full suite, push, open draft PR

**Files:** none new.

- [ ] **Step 1: Full suite and built-topology sanity**

```bash
scripts/test.sh
bash -c 'source scripts/lib.sh; build_topology "$PWD/scenarios/evpn-vxlan-leaf-spine" frr' >/dev/null
yq -r '.topology.nodes[].binds[]? | split(":") | .[0]' scenarios/evpn-vxlan-leaf-spine/.frr.build.clab.yml \
  | while read -r f; do [[ -f "scenarios/evpn-vxlan-leaf-spine/$f" ]] && echo "ok $f" || echo "MISSING $f"; done
yq -r '.topology.nodes.leaf1.exec | join("\n")' scenarios/evpn-vxlan-leaf-spine/.frr.build.clab.yml
rm -f scenarios/evpn-vxlan-leaf-spine/.*.build.clab.yml
git status --short   # must be clean
```
Expected: `ALL PASSED`; eight `ok` lines; the nine leaf1 exec lines in order; clean status.

- [ ] **Step 2: Push**

```bash
git push -u origin ccr-00157a22-qiys9w
```

- [ ] **Step 3: Open a draft PR**

PR #5 is merged, so open a new draft PR from `ccr-00157a22-qiys9w` to `main` titled "EVPN/VXLAN leaf-spine scenario". Body: Summary (spec, scenario files, four configs, `verify.sh` with spine-uplink failover, diagram, docs, test counts), a "Not validated live" note listing the four known risks from the README table, and the attribution footer the harness provides. Then subscribe to the PR's activity.

- [ ] **Step 4: Confirm CI**

Check `ci / test` on the new head. Expected: green.

---

## Self-review notes

- Spec coverage: topology, nodes, links, management default and sysctl (T1); spine control plane (T2); leaf control plane incl. `advertise-all-vni`, `vni 10`, explicit RTs (T3); dataplane plumbing in `exec:` with order test (T1); verification steps 1–8 incl. MAC read at run time, ` eth[12]` next-hop count, trap restore (T4); tests: scenario.yml, built topology, links table, binds, exec lists, config markers, stub modes `bgp-active`, `evpn-down`, `no-vtep`, `mac-local-only`, `single-path`, `no-failover` with trap proof (T1–T4); README with design, walkthrough, risks table and manual-plumbing commands, diagram, conventions section, simulator-doc bullets (T5); exports `none` (T1); draft status and validation commands (T1, T5); PR (T6).
- Names used consistently: `SCN`, `SPINES`, `LEAVES`, `ROUTERS`, `LINKS`, `built`, `cleanup_built`, `exec_of`, `cfg`, `daemons_of`, `block`, `assert_router_base NODE LOOPBACK ASN`, `assert_fabric_bgp`, `assert_ra_on`, `H1_MAC`/`H2_MAC`, `make_frr_stub`, `run_verify`, env `BOOT_TIMEOUT`/`BGP_TIMEOUT`/`EVPN_TIMEOUT`, `nexthops`, `restore_link`, container prefix `clab-evpn-vxlan-leaf-spine-`.
- Stub/verify agreement: every command string `verify.sh` sends has a matching `case` arm in the stub (version, both JSON summaries before the plain summary, per-prefix route with and without the `| grep -c` suffix, `show evpn vni 10`, `show evpn mac vni 10 | grep -i <mac>`, the MAC read, `ping`, and the two `ip link set eth1` commands), and the failure messages the tests assert quote the exact command strings.
