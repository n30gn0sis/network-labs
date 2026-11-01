#!/usr/bin/env bash
# Report a scenario's GNS3 or EVE-NG export and whether it is stale.
# Converters do not exist yet; exports are hand-written from topology.clab.yml.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'USAGE'
usage: scripts/export.sh <scenario> gns3|eve-ng

Prints the export file recorded in scenario.yml and compares the short SHA in
its header ("derived from topology.clab.yml @ <sha>") with the last commit that
changed topology.clab.yml. Exits 1 when the export is stale.
USAGE
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 2 ]] || { usage >&2; fail "expected <scenario> and gns3|eve-ng"; }

scenario="$1" sim="$2"
case "$sim" in gns3|eve-ng) ;; *) fail "simulator must be gns3 or eve-ng, got '$sim'" ;; esac

require_yq4
dir="$(scenario_dir "$scenario")"
validate_scenario_yml "$dir" || fail "scenario.yml is invalid"

rel="$(meta "$dir" ".simulators[\"$sim\"]")"
if [[ "$rel" == "none" || "$rel" == "null" ]]; then
  echo "export: none"
  echo "note: $scenario has no $sim export; write one under export/$sim/ and record it in scenario.yml"
  exit 0
fi
file="$dir/$rel"
[[ -f "$file" ]] || fail "scenario.yml names $sim export '$rel' but $file does not exist"

echo "export: $rel"
echo "source: hand-written"

recorded="$(export_header_sha "$file")"
current="$(topology_last_sha "$dir")"
if [[ -z "$recorded" ]]; then
  echo "freshness: unknown (no header)"
  echo "note: for .unl add '<!-- derived from topology.clab.yml @ <short sha> -->' as the first line, or directly after the XML declaration,"
  echo "      or a sidecar '$rel.derived' whose first line is '# derived from topology.clab.yml @ <short sha>' for .gns3"
  exit 0
fi
if [[ -z "$current" ]]; then
  echo "freshness: unknown (topology not committed)"
  exit 0
fi
if [[ "$recorded" == "$current"* || "$current" == "$recorded"* ]]; then
  echo "freshness: current"
  exit 0
fi
echo "freshness: STALE (export @ $recorded, topology @ $current)"
echo "note: topology.clab.yml changed since the export was written; update export/$sim/ and its header"
exit 1
