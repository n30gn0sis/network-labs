#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

SCN="$REPO_ROOT/scenarios/asa-hub-spoke-ipsec"
VARIANTS="vti-ikev2 cryptomap-ikev2 cryptomap-ikev1"

# built VARIANT -> path of the built topology (written beside topology.clab.yml, git-ignored)
built() { build_topology "$SCN" "$1"; }
cleanup_built() { rm -f "$SCN"/.*.build.clab.yml; }
# helpers.sh already installs an EXIT trap (_cleanup_tmpdirs); extend it rather than replace it
trap '_cleanup_tmpdirs; cleanup_built' EXIT

test_scenario_yml_is_valid() { assert_succeeds validate_scenario_yml "$SCN"; }
test_scenario_is_draft_until_validated() { assert_eq draft "$(meta "$SCN" .status)"; }
test_scenario_default_variant_is_vti() { assert_eq vti-ikev2 "$(meta "$SCN" .default_variant)"; }
test_scenario_defines_three_variants() {
  local v
  for v in $VARIANTS; do
    assert_eq "$v" "$(resolve_variant "$SCN" "$v")"
    assert_eq "vrnetlab/cisco_asav:9.18.4" "$(V="$v" yq -r '.variants[strenv(V)].images.asa' "$SCN/scenario.yml")"
  done
}
test_scenario_has_no_exports_yet() {
  assert_eq none "$(meta "$SCN" '.simulators.gns3')"
  assert_eq none "$(meta "$SCN" '.simulators["eve-ng"]')"
  assert_file_exists "$SCN/export/gns3/.gitkeep"
  assert_file_exists "$SCN/export/eve-ng/.gitkeep"
}
test_topology_has_expected_nodes() {
  local t; t="$SCN/topology.clab.yml"
  assert_eq asa-hub-spoke-ipsec "$(yq -r .name "$t")"
  assert_eq 3 "$(yq -r '[.topology.nodes[] | select(.kind == "cisco_asav")] | length' "$t")"
  assert_eq 4 "$(yq -r '[.topology.nodes[] | select(.kind == "linux")] | length' "$t")"
  assert_eq "asa-hub asa-spoke1 asa-spoke2 h1 h2 h3 wan" "$(yq -r '.topology.nodes | keys | sort | join(" ")' "$t")"
}
test_topology_has_six_links_into_wan_and_hosts() {
  local t; t="$SCN/topology.clab.yml"
  assert_eq 6 "$(yq -r '.topology.links | length' "$t")"
  assert_eq 3 "$(yq -r '[.topology.links[].endpoints[] | select(test("^wan:"))] | length' "$t")"
  local n
  for n in h1 h2 h3; do
    assert_eq 1 "$(N="$n" yq -r '[.topology.links[].endpoints[] | select(. == strenv(N) + ":eth1")] | length' "$t")"
  done
  for n in asa-hub asa-spoke1 asa-spoke2; do
    assert_eq 1 "$(N="$n" yq -r '[.topology.links[].endpoints[] | select(. == strenv(N) + ":eth1")] | length' "$t")" "$n outside"
    assert_eq 1 "$(N="$n" yq -r '[.topology.links[].endpoints[] | select(. == strenv(N) + ":eth2")] | length' "$t")" "$n inside"
  done
}
test_hosts_get_address_and_route_to_their_asa() {
  local t; t="$SCN/topology.clab.yml"
  assert_contains "$(yq -r '.topology.nodes.h1.exec | join("\n")' "$t")" "ip addr add 10.1.0.10/24 dev eth1"
  assert_contains "$(yq -r '.topology.nodes.h1.exec | join("\n")' "$t")" "ip route add 10.0.0.0/8 via 10.1.0.1"
  assert_contains "$(yq -r '.topology.nodes.h2.exec | join("\n")' "$t")" "ip addr add 10.2.0.10/24 dev eth1"
  assert_contains "$(yq -r '.topology.nodes.h2.exec | join("\n")' "$t")" "ip route add 10.0.0.0/8 via 10.2.0.1"
  assert_contains "$(yq -r '.topology.nodes.h3.exec | join("\n")' "$t")" "ip addr add 10.3.0.10/24 dev eth1"
  assert_contains "$(yq -r '.topology.nodes.h3.exec | join("\n")' "$t")" "ip route add 10.0.0.0/8 via 10.3.0.1"
}
test_wan_node_bridges_its_three_ports() {
  local ex; ex="$(yq -r '.topology.nodes.wan.exec | join("\n")' "$SCN/topology.clab.yml")"
  assert_contains "$ex" "ip link add br0 type bridge"
  assert_contains "$ex" "ip link set eth1 master br0"
  assert_contains "$ex" "ip link set eth2 master br0"
  assert_contains "$ex" "ip link set eth3 master br0"
  assert_contains "$ex" "ip link set br0 up"
}
# shellcheck disable=SC2016
test_verify_is_executable_and_sources_lib() {
  [[ -x "$SCN/verify.sh" ]]
  assert_contains "$(cat "$SCN/verify.sh")" 'source "${LIB_SH:?'
  assert_contains "$(cat "$SCN/verify.sh")" 'export ASA_NODES="asa-hub asa-spoke1 asa-spoke2"'
}

run_tests
