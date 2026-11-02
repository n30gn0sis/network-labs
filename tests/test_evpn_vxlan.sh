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

run_tests
