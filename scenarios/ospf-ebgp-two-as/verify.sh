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
