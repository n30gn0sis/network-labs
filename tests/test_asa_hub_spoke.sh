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

# cfg_of VARIANT NODE -> absolute path of NODE's startup-config in the built topology
cfg_of() {
  local topo rel; topo="$(built "$1")"
  rel="$(N="$2" yq -r '.topology.nodes[strenv(N)]["startup-config"]' "$topo")"
  printf '%s/%s\n' "$(dirname "$topo")" "$rel"
}
# tunnel_block FILE TUNNEL -> lines of that interface block
tunnel_block() { sed -n "/^interface $2\$/,/^interface \|^route \|^!/p" "$1"; }
assert_common_base() { # file hostname inside_ip outside_ip
  local c; c="$(cat "$1")"
  assert_contains "$c" "hostname $2"
  assert_contains "$c" "interface GigabitEthernet0/0"
  assert_contains "$c" " nameif outside"
  assert_contains "$c" " security-level 0"
  assert_contains "$c" "interface GigabitEthernet0/1"
  assert_contains "$c" " nameif inside"
  assert_contains "$c" " security-level 100"
  assert_contains "$c" " ip address $3 255.255.255.0"
  assert_contains "$c" " ip address $4 255.255.255.0"
  assert_contains "$c" "inspect icmp"
  assert_not_contains "$c" "Management0/0"
  assert_not_contains "$c" "username admin"
}

test_vti_startup_configs_exist_for_all_asas() {
  local n
  for n in asa-hub asa-spoke1 asa-spoke2; do assert_file_exists "$(cfg_of vti-ikev2 "$n")"; done
}
test_vti_configs_share_base() {
  assert_common_base "$(cfg_of vti-ikev2 asa-hub)" asa-hub 10.1.0.1 203.0.113.1
  assert_common_base "$(cfg_of vti-ikev2 asa-spoke1)" asa-spoke1 10.2.0.1 203.0.113.2
  assert_common_base "$(cfg_of vti-ikev2 asa-spoke2)" asa-spoke2 10.3.0.1 203.0.113.3
}
test_vti_hub_has_two_tunnels_and_routes() {
  local c; c="$(cat "$(cfg_of vti-ikev2 asa-hub)")"
  assert_contains "$c" "crypto ikev2 enable outside"
  assert_contains "$c" "crypto ipsec profile VTI-PROFILE"
  assert_contains "$c" "interface Tunnel1"
  assert_contains "$c" "interface Tunnel2"
  assert_contains "$c" " tunnel destination 203.0.113.2"
  assert_contains "$c" " tunnel destination 203.0.113.3"
  assert_contains "$c" " tunnel protection ipsec profile VTI-PROFILE"
  assert_contains "$c" "route vti-spoke1 10.2.0.0 255.255.255.0 169.254.1.2"
  assert_contains "$c" "route vti-spoke2 10.3.0.0 255.255.255.0 169.254.2.2"
  assert_contains "$c" "same-security-traffic permit inter-interface"
  assert_contains "$c" "same-security-traffic permit intra-interface"
  assert_not_contains "$c" "crypto map"
  assert_contains "$(tunnel_block "$(cfg_of vti-ikev2 asa-hub)" Tunnel1)" " security-level 100"
  assert_contains "$(tunnel_block "$(cfg_of vti-ikev2 asa-hub)" Tunnel2)" " security-level 100"
}
test_vti_spokes_tunnel_to_hub() {
  local c
  c="$(cat "$(cfg_of vti-ikev2 asa-spoke1)")"
  assert_contains "$c" " tunnel destination 203.0.113.1"
  assert_contains "$c" " ip address 169.254.1.2 255.255.255.252"
  assert_contains "$c" "route vti-hub 10.0.0.0 255.0.0.0 169.254.1.1"
  assert_contains "$c" "same-security-traffic permit inter-interface"
  assert_contains "$(tunnel_block "$(cfg_of vti-ikev2 asa-spoke1)" Tunnel1)" " security-level 100"
  c="$(cat "$(cfg_of vti-ikev2 asa-spoke2)")"
  assert_contains "$c" " tunnel destination 203.0.113.1"
  assert_contains "$c" " ip address 169.254.2.2 255.255.255.252"
  assert_contains "$c" "route vti-hub 10.0.0.0 255.0.0.0 169.254.2.1"
  assert_contains "$c" "same-security-traffic permit inter-interface"
  assert_contains "$(tunnel_block "$(cfg_of vti-ikev2 asa-spoke2)" Tunnel1)" " security-level 100"
}
test_vti_psks_match_per_pair() {
  local hub s1 s2
  hub="$(cat "$(cfg_of vti-ikev2 asa-hub)")"; s1="$(cat "$(cfg_of vti-ikev2 asa-spoke1)")"; s2="$(cat "$(cfg_of vti-ikev2 asa-spoke2)")"
  assert_contains "$hub" "tunnel-group 203.0.113.2 ipsec-attributes"
  assert_contains "$hub" "tunnel-group 203.0.113.3 ipsec-attributes"
  assert_contains "$hub" "pre-shared-key LAB-PSK-SPOKE1"
  assert_contains "$hub" "pre-shared-key LAB-PSK-SPOKE2"
  assert_contains "$s1" "tunnel-group 203.0.113.1 ipsec-attributes"
  assert_contains "$s1" "pre-shared-key LAB-PSK-SPOKE1"
  assert_not_contains "$s1" "LAB-PSK-SPOKE2"
  assert_contains "$s2" "pre-shared-key LAB-PSK-SPOKE2"
  assert_not_contains "$s2" "LAB-PSK-SPOKE1"
  assert_not_contains "$hub$s1$s2" "pre-shared-key $"
}

# assert_cryptomap_structure VARIANT IKE(ikev1|ikev2): ACLs, crypto map, routes, hairpin entries
assert_cryptomap_structure() {
  local v="$1" ike="$2" hub s1 s2
  hub="$(cat "$(cfg_of "$v" asa-hub)")"; s1="$(cat "$(cfg_of "$v" asa-spoke1)")"; s2="$(cat "$(cfg_of "$v" asa-spoke2)")"
  assert_common_base "$(cfg_of "$v" asa-hub)" asa-hub 10.1.0.1 203.0.113.1
  assert_common_base "$(cfg_of "$v" asa-spoke1)" asa-spoke1 10.2.0.1 203.0.113.2
  assert_common_base "$(cfg_of "$v" asa-spoke2)" asa-spoke2 10.3.0.1 203.0.113.3
  # hub ACLs incl. spoke-to-spoke hairpin entries
  assert_contains "$hub" "access-list L2L-SPOKE1 extended permit ip 10.1.0.0 255.255.255.0 10.2.0.0 255.255.255.0"
  assert_contains "$hub" "access-list L2L-SPOKE1 extended permit ip 10.3.0.0 255.255.255.0 10.2.0.0 255.255.255.0"
  assert_contains "$hub" "access-list L2L-SPOKE2 extended permit ip 10.1.0.0 255.255.255.0 10.3.0.0 255.255.255.0"
  assert_contains "$hub" "access-list L2L-SPOKE2 extended permit ip 10.2.0.0 255.255.255.0 10.3.0.0 255.255.255.0"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 10 match address L2L-SPOKE1"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 10 set peer 203.0.113.2"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 20 match address L2L-SPOKE2"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 20 set peer 203.0.113.3"
  assert_contains "$hub" "crypto map OUTSIDE_MAP interface outside"
  assert_contains "$hub" "route outside 10.2.0.0 255.255.255.0 203.0.113.2"
  assert_contains "$hub" "route outside 10.3.0.0 255.255.255.0 203.0.113.3"
  assert_contains "$hub" "crypto $ike enable outside"
  assert_contains "$hub" "same-security-traffic permit intra-interface"
  assert_not_contains "$hub" "interface Tunnel"
  # spokes
  assert_contains "$s1" "access-list L2L-HUB extended permit ip 10.2.0.0 255.255.255.0 10.0.0.0 255.0.0.0"
  assert_contains "$s1" "crypto map OUTSIDE_MAP 10 set peer 203.0.113.1"
  assert_contains "$s1" "route outside 10.0.0.0 255.0.0.0 203.0.113.1"
  assert_contains "$s1" "crypto $ike enable outside"
  assert_contains "$s2" "access-list L2L-HUB extended permit ip 10.3.0.0 255.255.255.0 10.0.0.0 255.0.0.0"
  assert_contains "$s2" "crypto map OUTSIDE_MAP 10 set peer 203.0.113.1"
  assert_contains "$s2" "route outside 10.0.0.0 255.0.0.0 203.0.113.1"
  # psks
  assert_contains "$hub" "LAB-PSK-SPOKE1"; assert_contains "$hub" "LAB-PSK-SPOKE2"
  assert_contains "$s1" "LAB-PSK-SPOKE1"; assert_not_contains "$s1" "LAB-PSK-SPOKE2"
  assert_contains "$s2" "LAB-PSK-SPOKE2"; assert_not_contains "$s2" "LAB-PSK-SPOKE1"
}
test_cryptomap_ikev2_patch_only_repoints_startup_configs() {
  local p; p="$SCN/variants/cryptomap-ikev2/topology.patch.yml"
  assert_file_exists "$p"
  assert_eq "asa-hub asa-spoke1 asa-spoke2" "$(yq -r '.topology.nodes | keys | sort | join(" ")' "$p")"
  assert_eq "startup-config" "$(yq -r '[.topology.nodes[] | keys[]] | unique | join(" ")' "$p")"
  assert_eq "variants/cryptomap-ikev2/configs/asa-hub/startup.cfg" "$(yq -r '.topology.nodes["asa-hub"]["startup-config"]' "$p")"
}
test_cryptomap_ikev2_built_topology_keeps_images_and_hosts() {
  local t; t="$(built cryptomap-ikev2)"
  assert_eq "vrnetlab/cisco_asav:9.18.4" "$(yq -r '.topology.nodes["asa-hub"].image' "$t")"
  assert_eq 7 "$(yq -r '.topology.nodes | length' "$t")"
  assert_eq 6 "$(yq -r '.topology.links | length' "$t")"
}
test_cryptomap_ikev2_configs() {
  assert_cryptomap_structure cryptomap-ikev2 ikev2
  local hub; hub="$(cat "$(cfg_of cryptomap-ikev2 asa-hub)")"
  assert_contains "$hub" "crypto ipsec ikev2 ipsec-proposal GCM"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 10 set ikev2 ipsec-proposal GCM"
  assert_contains "$hub" "ikev2 remote-authentication pre-shared-key LAB-PSK-SPOKE1"
  assert_not_contains "$hub" "ikev1"
}

run_tests
