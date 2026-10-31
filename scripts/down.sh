#!/usr/bin/env bash
# Destroy a deployed scenario.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: scripts/down.sh <scenario> [--variant <name>]

Runs `containerlab destroy --cleanup` on the scenario's built topology.
Environment: CLAB (default: containerlab) overrides the containerlab binary.
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -gt 0 ]] || { usage >&2; fail "scenario name required"; }

parse_scenario_args "$@"
require_yq4
dir="$(scenario_dir "$ARG_SCENARIO")"
validate_scenario_yml "$dir" || fail "scenario.yml is invalid"
variant="$(resolve_variant "$dir" "$ARG_VARIANT")"
clab="${CLAB:-containerlab}"
command -v "$clab" >/dev/null 2>&1 || fail "'$clab' not found; install containerlab or set CLAB"

topo="$(build_topology "$dir" "$variant")"
log "destroying $ARG_SCENARIO (variant: $variant)"
cd "$dir"
exec "$clab" destroy --topo "$topo" --cleanup
