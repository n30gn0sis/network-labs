#!/usr/bin/env bash
# Run all scaffolding tests: shellcheck on every script, then tests/test_*.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

usage() { echo "usage: scripts/test.sh    # runs shellcheck and all tests/test_*.sh"; }
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

for tool in shellcheck yq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found on PATH (see docs/conventions.md#development-tools)" >&2; exit 1; }
done
yq --version 2>&1 | grep -q 'mikefarah/yq' || { echo "error: yq must be mikefarah yq v4, found: $(yq --version 2>&1 | head -1)" >&2; exit 1; }

echo "== shellcheck"
mapfile -t scripts < <(find scripts tests scenarios -name '*.sh' -type f 2>/dev/null | sort)
shellcheck -x "${scripts[@]}"

echo "== tests"
status=0
for t in tests/test_*.sh; do
  echo "-- $t"
  bash "$t" || status=1
done

if [[ "$status" -ne 0 ]]; then
  echo "FAILED" >&2
  exit 1
fi
echo "ALL PASSED"
