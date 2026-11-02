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
test_routers_drop_management_default_route() {
  local t r e; t="$SCN/topology.clab.yml"
  for r in $ROUTERS; do
    e="$(R="$r" yq -r '.topology.nodes[strenv(R)].exec | join("\n")' "$t")"
    assert_contains "$e" "ip route del default" "$r drops the management default"
  done
  for r in h1 h2; do
    e="$(R="$r" yq -r '.topology.nodes[strenv(R)].exec | join("\n")' "$t")"
    assert_not_contains "$e" "ip route del default" "$r keeps its own default handling"
  done
}
test_verify_placeholder_is_executable_and_sources_lib() {
  [[ -x "$SCN/verify.sh" ]]
  # shellcheck disable=SC2016
  assert_contains "$(cat "$SCN/verify.sh")" 'source "${LIB_SH:?'
}

cfg() { cat "$SCN/configs/$1/frr.conf"; }
daemons_of() { cat "$SCN/configs/$1/daemons"; }

# Every router: hostname, loopback in area 0, router-id, daemons sane.
assert_router_base() { # R ROUTERID
  local c; c="$(cfg "$1")"
  assert_contains "$c" "hostname $1"
  assert_contains "$c" "interface lo"
  assert_contains "$c" " ip address $2/32"
  assert_contains "$(sed -n '/^interface lo$/,/^!/p' "$SCN/configs/$1/frr.conf")" " ip ospf area 0" "$1 lo area"
  assert_contains "$c" "router ospf"
  assert_contains "$c" " ospf router-id $2"
  local d; d="$(daemons_of "$1")"
  assert_contains "$d" "zebra=yes"
  assert_contains "$d" "ospfd=yes"
  assert_contains "$d" "staticd=yes"
  assert_contains "$d" "vtysh_enable=yes"
  assert_file_exists "$SCN/configs/$1/daemons"
}
# Every address the LINKS table assigns to R appears inside its interface block.
assert_addresses_from_table() { # R
  local a aaddr b baddr
  _assert_addr_in_block() { # R ENDPOINT ADDR
    local iface="${2#*:}" block
    block="$(sed -n "/^interface ${iface}\$/,/^!/p" "$SCN/configs/$1/frr.conf")"
    assert_contains "$block" " ip address $3" "$1 $iface"
  }
  while read -r a aaddr b baddr; do
    [[ -z "$a" ]] && continue
    [[ "${a%%:*}" == "$1" ]] && _assert_addr_in_block "$1" "$a" "$aaddr"
    [[ "${b%%:*}" == "$1" ]] && _assert_addr_in_block "$1" "$b" "$baddr"
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
  local t src n=0; t="$(built)"
  while IFS= read -r src; do
    assert_file_exists "$(dirname "$t")/$src"
    n=$((n + 1))
  done < <(yq -r '.topology.nodes[].binds[]? | split(":") | .[0]' "$t")
  assert_eq 12 "$n" "bind source count"
}

# Stateful docker stub. The second argv word is the container name; the command is $5.
# It records "ip link set eth2 down/up" in a flag file so routes/traceroute change state.
make_frr_stub() { # ROOT MODE
  local root="$1" mode="$2"
  mkdir -p "$root/bin"
  cat >"$root/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/docker.log"
node="\${2#clab-ospf-ebgp-two-as-}"
cmd="\${5:-}"
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
  *"grep '10.1.0.3/32'"*)
    if [[ -e "\$flag" && "\$mode" != no-reroute ]]; then echo "O>* 10.1.0.3/32 [110/20] via 10.1.12.2, eth3, weight 1, 00:00:05"; else echo "O>* 10.1.0.3/32 [110/10] via 10.1.13.2, eth2, weight 1, 00:10:00"; fi ;;
  *"show ip route ospf"*)
    if [[ "\$mode" == kernel-default ]]; then
      echo "K>* 0.0.0.0/0 [0/0] via 172.20.20.1, eth0"
      echo "O   0.0.0.0/0 [110/1] via 10.1.13.2, eth2"
    else echo "O>* 0.0.0.0/0 [110/1] via 10.1.13.2, eth2"; fi ;;
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
  assert_contains "$out" "grep -c Full' did not contain '2'"
  assert_not_contains "$(cat "$root/docker.log")" "ip link set eth2 down" "failover never reached"
}
test_verify_fails_when_bgp_active() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" bgp-active
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "did not contain 'Established'"
}
test_verify_fails_when_ospf_default_not_selected() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" kernel-default
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "did not contain 'O>* 0.0.0.0/0'"
  assert_not_contains "$(cat "$root/docker.log")" "ip link set eth2 down" "fails before failover"
}
test_verify_fails_when_no_reroute_and_still_restores_link() {
  local root out rc=0; root="$(make_tmpdir)"; make_frr_stub "$root" no-reroute
  out="$(run_verify "$root" 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "grep '10.1.0.3/32'' did not contain 'via 10.1.12.2'"
  assert_eq "ip link set eth2 up" "$(grep -o 'ip link set eth2 [a-z]*' "$root/docker.log" | tail -1)" "trap restored the link"
  [[ ! -e "$root/eth2_down" ]] || return 1
}

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

run_tests
