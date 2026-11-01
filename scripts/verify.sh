#!/usr/bin/env bash
# Run a scenario's verify.sh against the deployed lab.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'USAGE'
usage: scripts/verify.sh <scenario> [--variant <name>]

Runs scenarios/<scenario>/verify.sh with LAB_NAME, VARIANT and LIB_SH exported.
Environment: DOCKER (default: docker) overrides the docker binary.
USAGE
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -gt 0 ]] || { usage >&2; fail "scenario name required"; }

parse_scenario_args "$@"
require_yq4
dir="$(scenario_dir "$ARG_SCENARIO")"
validate_scenario_yml "$dir" || fail "scenario.yml is invalid"
variant="$(resolve_variant "$dir" "$ARG_VARIANT")"
[[ -x "$dir/verify.sh" ]] || fail "no executable verify.sh in $dir"

topo="$(build_topology "$dir" "$variant")"
LAB_NAME="$(yq -r .name "$topo")"
LIB_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
export LAB_NAME VARIANT="$variant" LIB_SH

log "verifying $ARG_SCENARIO (variant: $variant, lab: $LAB_NAME)"
cd "$dir"
exec ./verify.sh
