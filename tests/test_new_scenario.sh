#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

NEW="$REPO_ROOT/scripts/new-scenario.sh"

# A fake repo root containing a copy of the real template.
fake_root() {
  local root; root="$(make_tmpdir)"
  mkdir -p "$root/scenarios"
  cp -r "$REPO_ROOT/scenarios/_template" "$root/scenarios/_template"
  printf '%s\n' "$root"
}

test_usage_on_help() {
  local out; out="$("$NEW" --help)"
  assert_contains "$out" "usage: scripts/new-scenario.sh <name>"
}
test_fails_without_name() { assert_fails "$NEW"; }
test_rejects_invalid_name() {
  local root; root="$(fake_root)"
  assert_fails env LIB_REPO_ROOT="$root" "$NEW" "Bad Name"
  assert_fails env LIB_REPO_ROOT="$root" "$NEW" "_private"
}
test_creates_scenario_from_template() {
  local root; root="$(fake_root)"
  LIB_REPO_ROOT="$root" "$NEW" ospf-basic >/dev/null 2>&1
  assert_file_exists "$root/scenarios/ospf-basic/scenario.yml"
  assert_file_exists "$root/scenarios/ospf-basic/topology.clab.yml"
  assert_file_exists "$root/scenarios/ospf-basic/verify.sh"
  assert_file_exists "$root/scenarios/ospf-basic/export/gns3/.gitkeep"
  [[ -x "$root/scenarios/ospf-basic/verify.sh" ]]
}
test_replaces_placeholder_everywhere() {
  local root; root="$(fake_root)"
  LIB_REPO_ROOT="$root" "$NEW" ospf-basic >/dev/null 2>&1
  if grep -r "__SCENARIO_NAME__" "$root/scenarios/ospf-basic" >/dev/null; then
    return 1
  fi
  assert_eq ospf-basic "$(yq -r .name "$root/scenarios/ospf-basic/scenario.yml")"
  assert_eq ospf-basic "$(yq -r .name "$root/scenarios/ospf-basic/topology.clab.yml")"
}
test_refuses_to_overwrite() {
  local root; root="$(fake_root)"
  LIB_REPO_ROOT="$root" "$NEW" ospf-basic >/dev/null 2>&1
  assert_fails env LIB_REPO_ROOT="$root" "$NEW" ospf-basic
}
test_prints_next_steps() {
  local root out; root="$(fake_root)"
  out="$(LIB_REPO_ROOT="$root" "$NEW" ospf-basic 2>&1)"
  assert_contains "$out" "scenarios/ospf-basic"
  assert_contains "$out" "scenario.yml"
}

run_tests
