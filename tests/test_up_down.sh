#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

UP="$REPO_ROOT/scripts/up.sh"
DOWN="$REPO_ROOT/scripts/down.sh"

# Fake repo with one scenario and a containerlab stub that records its argv.
setup() {
  ROOT="$(make_tmpdir)"
  mkdir -p "$ROOT/scenarios" "$ROOT/bin"
  cp -r "$REPO_ROOT/scenarios/_template" "$ROOT/scenarios/_template"
  LIB_REPO_ROOT="$ROOT" "$REPO_ROOT/scripts/new-scenario.sh" demo >/dev/null 2>&1
  STUB_LOG="$ROOT/clab.log"
  cat >"$ROOT/bin/containerlab" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$STUB_LOG"
pwd >>"$STUB_LOG"
EOF
  chmod +x "$ROOT/bin/containerlab"
  export ROOT STUB_LOG
}
set_ready() { sed -i 's/^status: draft/status: ready/' "$ROOT/scenarios/demo/scenario.yml"; }
run_up()   { LIB_REPO_ROOT="$ROOT" CLAB="$ROOT/bin/containerlab" "$UP" "$@"; }
run_down() { LIB_REPO_ROOT="$ROOT" CLAB="$ROOT/bin/containerlab" "$DOWN" "$@"; }

test_up_help() { assert_contains "$("$UP" --help)" "usage: scripts/up.sh <scenario>"; }
test_down_help() { assert_contains "$("$DOWN" --help)" "usage: scripts/down.sh <scenario>"; }
test_up_fails_without_scenario() { assert_fails "$UP"; }
test_up_fails_for_unknown_scenario() { setup; assert_fails run_up nope; }
test_up_fails_on_unknown_option() { setup; set_ready; assert_fails run_up demo --bogus; }
test_up_refuses_draft() {
  setup
  local out rc=0
  out="$(run_up demo 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "status is draft"
  [[ ! -e "$STUB_LOG" ]]
}
test_up_force_allows_draft() {
  setup
  run_up demo --force >/dev/null 2>&1
  assert_file_exists "$STUB_LOG"
}
test_up_deploys_default_variant() {
  setup; set_ready
  run_up demo >/dev/null 2>&1
  local log; log="$(cat "$STUB_LOG")"
  assert_contains "$log" "deploy --topo $ROOT/scenarios/demo/.frr.build.clab.yml --reconfigure"
  assert_eq demo "$(yq -r .name "$ROOT/scenarios/demo/.frr.build.clab.yml")"
  assert_eq "$ROOT/scenarios/demo" "$(sed -n 2p "$STUB_LOG")" "runs from scenario dir"
}
test_up_rejects_malicious_variant() {
  setup; set_ready
  assert_fails run_up demo --variant 'x"] // "y'
  [[ ! -e "$STUB_LOG" ]]
}
test_up_rejects_unknown_variant() { setup; set_ready; assert_fails run_up demo --variant junos; }
test_up_fails_when_clab_missing() {
  setup; set_ready
  assert_fails env LIB_REPO_ROOT="$ROOT" CLAB="/nonexistent/containerlab" "$UP" demo
}
test_down_destroys_with_cleanup() {
  setup; set_ready
  run_down demo >/dev/null 2>&1
  assert_contains "$(cat "$STUB_LOG")" "destroy --topo $ROOT/scenarios/demo/.frr.build.clab.yml --cleanup"
  assert_eq "$ROOT/scenarios/demo" "$(sed -n 2p "$STUB_LOG")" "runs from scenario dir"
}
test_down_works_on_draft_without_force() {
  setup
  assert_succeeds run_down demo
}

run_tests
