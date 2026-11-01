#!/usr/bin/env bash
# Verification for asa-hub-spoke-ipsec. Run via: scripts/verify.sh asa-hub-spoke-ipsec [--variant X]
# scripts/verify.sh exports LAB_NAME, VARIANT and LIB_SH before calling this.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib.sh
source "${LIB_SH:?run this via scripts/verify.sh}"

# ASA nodes are reached over SSH (asa_exec); hosts via docker exec.
export ASA_NODES="asa-hub asa-spoke1 asa-spoke2"

boot_timeout="${ASA_BOOT_TIMEOUT:-300}"   # ASAv takes 2-4 minutes to boot
sa_timeout="${ASA_SA_TIMEOUT:-120}"
ike=ikev2
# shellcheck disable=SC2153  # VARIANT is exported by scripts/verify.sh
[[ "$VARIANT" == "cryptomap-ikev1" ]] && ike=ikev1

log "== 1. ASAs booted and reachable over SSH"
for asa in asa-hub asa-spoke1 asa-spoke2; do
  wait_for "$boot_timeout" "$asa" "show version | include Software" "Cisco Adaptive Security Appliance"
done

log "== 2. Hosts reach their own ASA"
expect_contains h1 "ping -c 2 -W 2 10.1.0.1" "2 received"
expect_contains h2 "ping -c 2 -W 2 10.2.0.1" "2 received"
expect_contains h3 "ping -c 2 -W 2 10.3.0.1" "2 received"

log "== 3. Tunnels establish (crypto maps need interesting traffic; VTI comes up on its own)"
node_exec h2 "ping -c 3 -W 2 10.1.0.10" >/dev/null 2>&1 || true
node_exec h3 "ping -c 3 -W 2 10.1.0.10" >/dev/null 2>&1 || true
wait_for "$sa_timeout" asa-hub "show crypto $ike sa" "203.0.113.2"
wait_for "$sa_timeout" asa-hub "show crypto $ike sa" "203.0.113.3"

log "== 4. Traffic is encrypted (encaps counters non-zero on the hub)"
expect_contains h2 "ping -c 5 -W 2 10.1.0.10" "5 received"
expect_not_contains asa-hub "show crypto ipsec sa peer 203.0.113.2 | include pkts encaps" "#pkts encaps: 0"
expect_contains h3 "ping -c 5 -W 2 10.1.0.10" "5 received"
expect_not_contains asa-hub "show crypto ipsec sa peer 203.0.113.3 | include pkts encaps" "#pkts encaps: 0"

log "== 5. Spoke-to-spoke through the hub"
expect_contains h2 "ping -c 5 -W 2 10.3.0.10" "5 received"

if [[ "$VARIANT" == "vti-ikev2" ]]; then
  log "== 6. VTI interfaces up/up"
  expect_contains asa-hub "show interface Tunnel1 | include line protocol" "line protocol is up"
  expect_contains asa-hub "show interface Tunnel2 | include line protocol" "line protocol is up"
fi

log "all checks passed"
