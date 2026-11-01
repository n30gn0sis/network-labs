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
  local a b
  while read -r a _ b _; do
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
