#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

test_docs_exist() {
  local f
  for f in docs/conventions.md docs/simulators/containerlab.md docs/simulators/gns3.md docs/simulators/eve-ng.md images/README.md; do
    assert_file_exists "$REPO_ROOT/$f"
  done
}
test_conventions_cover_required_topics() {
  local c; c="$(cat "$REPO_ROOT/docs/conventions.md")"
  assert_contains "$c" "## Development tools"
  assert_contains "$c" "mikefarah"
  assert_contains "$c" "__SCENARIO_NAME__"
  assert_contains "$c" "derived from topology.clab.yml @"
  assert_contains "$c" "default_variant"
}
test_simulator_docs_have_kind_mapping() {
  assert_contains "$(cat "$REPO_ROOT/docs/simulators/gns3.md")" "| clab kind |"
  assert_contains "$(cat "$REPO_ROOT/docs/simulators/eve-ng.md")" "| clab kind |"
}
test_images_readme_lists_free_images() {
  local i; i="$(cat "$REPO_ROOT/images/README.md")"
  assert_contains "$i" "quay.io/frrouting/frr"
  assert_contains "$i" "vrnetlab"
}
test_readme_has_quick_start() {
  local r; r="$(cat "$REPO_ROOT/README.md")"
  assert_contains "$r" "scripts/new-scenario.sh"
  assert_contains "$r" "scripts/up.sh"
  assert_contains "$r" "scripts/verify.sh"
  assert_contains "$r" "scripts/down.sh"
  assert_contains "$r" "scripts/export.sh"
  assert_contains "$r" "docs/conventions.md"
}

run_tests
