#!/usr/bin/env bash
# Verification for __SCENARIO_NAME__. Run via: scripts/verify.sh <scenario> [--variant X]
# scripts/verify.sh exports LAB_NAME, VARIANT and LIB_SH before calling this.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib.sh
source "${LIB_SH:?run this via scripts/verify.sh}"

# Each check: expect_contains <node> <command> <expected substring>
# wait_for <timeout-seconds> <node> <command> <expected substring>
wait_for 30 r1 "vtysh -c 'show version'" "FRRouting"
expect_contains r1 "vtysh -c 'show running-config'" "hostname r1"

log "all checks passed"
