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

run_tests
