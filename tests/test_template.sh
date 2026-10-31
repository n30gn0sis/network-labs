#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

TEMPLATE="$REPO_ROOT/scenarios/_template"

test_template_has_expected_files() {
  local f
  for f in README.md scenario.yml topology.clab.yml verify.sh \
           configs/r1/frr.conf configs/r1/daemons variants/README.md \
           export/gns3/.gitkeep export/eve-ng/.gitkeep; do
    assert_file_exists "$TEMPLATE/$f"
  done
}
test_template_scenario_yml_is_valid() { assert_succeeds validate_scenario_yml "$TEMPLATE"; }
test_template_is_draft() { assert_eq draft "$(meta "$TEMPLATE" .status)"; }
test_template_uses_placeholder_in_name() { assert_eq __SCENARIO_NAME__ "$(meta "$TEMPLATE" .name)"; }
test_template_topology_is_valid_yaml_with_placeholder_name() {
  assert_eq __SCENARIO_NAME__ "$(yq -r .name "$TEMPLATE/topology.clab.yml")"
  assert_eq r1 "$(yq -r '.topology.nodes | keys | .[0]' "$TEMPLATE/topology.clab.yml")"
}
test_template_verify_is_executable() { [[ -x "$TEMPLATE/verify.sh" ]]; }
test_template_readme_has_sections() {
  local readme; readme="$(cat "$TEMPLATE/README.md")"
  assert_contains "$readme" "## Objective"
  assert_contains "$readme" "## Topology"
  assert_contains "$readme" "## Tasks"
  assert_contains "$readme" "## Verification"
}

run_tests
