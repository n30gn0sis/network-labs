#!/usr/bin/env bash
# Verification for asa-hub-spoke-ipsec. Run via: scripts/verify.sh asa-hub-spoke-ipsec [--variant X]
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib.sh
source "${LIB_SH:?run this via scripts/verify.sh}"

export ASA_NODES="asa-hub asa-spoke1 asa-spoke2"

fail "verify.sh not implemented yet"
