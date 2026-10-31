#!/usr/bin/env bash
# Deploy a scenario with containerlab.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: scripts/up.sh <scenario> [--variant <name>] [--force]

Merges the variant overlay (if any) into .<variant>.build.clab.yml
beside topology.clab.yml and runs
`containerlab deploy`. Refuses scenarios with status: draft unless --force.
Environment: CLAB (default: containerlab) overrides the containerlab binary.
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -gt 0 ]] || { usage >&2; fail "scenario name required"; }

parse_scenario_args "$@"
require_yq4
dir="$(scenario_dir "$ARG_SCENARIO")"
validate_scenario_yml "$dir" || fail "scenario.yml is invalid"

if [[ "$(meta "$dir" .status)" == "draft" && "$ARG_FORCE" -ne 1 ]]; then
  fail "scenario '$ARG_SCENARIO' status is draft; set status: ready or pass --force"
fi

variant="$(resolve_variant "$dir" "$ARG_VARIANT")"
clab="${CLAB:-containerlab}"
command -v "$clab" >/dev/null 2>&1 || fail "'$clab' not found; install containerlab or set CLAB"

topo="$(build_topology "$dir" "$variant")"
log "deploying $ARG_SCENARIO (variant: $variant) from $topo"
cd "$dir"
exec "$clab" deploy --topo "$topo" --reconfigure
