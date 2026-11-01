#!/usr/bin/env bash
# Create a new scenario from scenarios/_template.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'USAGE'
usage: scripts/new-scenario.sh <name>

Copies scenarios/_template to scenarios/<name> and replaces __SCENARIO_NAME__.
<name> must match ^[a-z0-9][a-z0-9-]*$ (lowercase, digits, hyphens).
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; fail "scenario name required" ;;
esac
[[ $# -eq 1 ]] || { usage >&2; fail "exactly one argument expected"; }

name="$1"
[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid scenario name '$name' (use lowercase letters, digits, hyphens)"

template="$LIB_REPO_ROOT/scenarios/_template"
dest="$LIB_REPO_ROOT/scenarios/$name"
[[ -d "$template" ]] || fail "template missing: $template"
[[ ! -e "$dest" ]] || fail "scenario already exists: $dest"

cp -r "$template" "$dest"
while IFS= read -r -d '' f; do
  sed -i "s/__SCENARIO_NAME__/$name/g" "$f"
done < <(find "$dest" -type f -print0)
chmod +x "$dest/verify.sh"

log "created scenarios/$name"
log "next: edit scenarios/$name/scenario.yml, topology.clab.yml, configs/, README.md"
log "      then set status: ready and run scripts/up.sh $name"
