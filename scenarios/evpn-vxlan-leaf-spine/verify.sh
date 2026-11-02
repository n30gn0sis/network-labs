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
