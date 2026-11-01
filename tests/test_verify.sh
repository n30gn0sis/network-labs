#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

VERIFY="$REPO_ROOT/scripts/verify.sh"

# docker stub: echoes a canned reply based on the command it receives.
make_docker_stub() {
  local root="$1"
  mkdir -p "$root/bin"
  cat >"$root/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/docker.log"
case "\$*" in
  *"show version"*) echo "FRRouting 10.1" ;;
  *"show running-config"*) echo "hostname r1" ;;
  *) echo "unknown" ;;
esac
STUB
  chmod +x "$root/bin/docker"
}

test_node_exec_targets_clab_container() {
  local root; root="$(make_tmpdir)"; make_docker_stub "$root"
  local out; out="$(DOCKER="$root/bin/docker" LAB_NAME=demo node_exec r1 "vtysh -c 'show version'")"
  assert_eq "FRRouting 10.1" "$out"
  assert_contains "$(cat "$root/docker.log")" "exec clab-demo-r1 sh -c vtysh -c 'show version'"
}
test_node_exec_fails_without_lab_name() {
  local root; root="$(make_tmpdir)"; make_docker_stub "$root"
  assert_fails env DOCKER="$root/bin/docker" bash -c 'unset LAB_NAME; source "'"$REPO_ROOT"'/scripts/lib.sh"; node_exec r1 true'
}
test_expect_contains_passes_and_fails() {
  local root; root="$(make_tmpdir)"; make_docker_stub "$root"
  export DOCKER="$root/bin/docker" LAB_NAME=demo
  assert_succeeds expect_contains r1 "vtysh -c 'show version'" "FRRouting"
  assert_fails bash -c 'source "'"$REPO_ROOT"'/scripts/lib.sh"; expect_contains r1 "vtysh -c \"show version\"" "Junos"'
}
test_wait_for_times_out() {
  local root; root="$(make_tmpdir)"; make_docker_stub "$root"
  local start end
  start=$(date +%s)
  assert_fails env DOCKER="$root/bin/docker" LAB_NAME=demo WAIT_INTERVAL=1 \
    bash -c 'source "'"$REPO_ROOT"'/scripts/lib.sh"; wait_for 2 r1 "echo" "never"'
  end=$(date +%s)
  [[ $((end - start)) -ge 2 ]]
}
test_wait_for_succeeds_immediately() {
  local root; root="$(make_tmpdir)"; make_docker_stub "$root"
  DOCKER="$root/bin/docker" LAB_NAME=demo assert_succeeds wait_for 5 r1 "vtysh -c 'show version'" "FRRouting"
}

# Fake repo with a demo scenario for the runner tests.
setup_repo() {
  ROOT="$(make_tmpdir)"
  mkdir -p "$ROOT/scenarios"
  cp -r "$REPO_ROOT/scenarios/_template" "$ROOT/scenarios/_template"
  LIB_REPO_ROOT="$ROOT" "$REPO_ROOT/scripts/new-scenario.sh" demo >/dev/null 2>&1
  make_docker_stub "$ROOT"
  export ROOT
}
test_verify_help() { assert_contains "$("$VERIFY" --help)" "usage: scripts/verify.sh <scenario>"; }
test_verify_runs_template_checks_against_stub() {
  setup_repo
  local out
  out="$(LIB_REPO_ROOT="$ROOT" DOCKER="$ROOT/bin/docker" WAIT_INTERVAL=1 "$VERIFY" demo 2>&1)"
  assert_contains "$out" "all checks passed"
  assert_contains "$(cat "$ROOT/docker.log")" "clab-demo-r1"
}
test_verify_fails_when_check_fails() {
  setup_repo
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "$LIB_SH"\nexpect_contains r1 "echo hi" "nope"\n' >"$ROOT/scenarios/demo/verify.sh"
  assert_fails env LIB_REPO_ROOT="$ROOT" DOCKER="$ROOT/bin/docker" "$VERIFY" demo
}
test_verify_exports_variant_and_lab_name() {
  setup_repo
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho "LAB=$LAB_NAME VARIANT=$VARIANT"\n' >"$ROOT/scenarios/demo/verify.sh"
  local out; out="$(LIB_REPO_ROOT="$ROOT" DOCKER="$ROOT/bin/docker" "$VERIFY" demo 2>&1)"
  assert_contains "$out" "LAB=demo VARIANT=frr"
}
test_verify_fails_for_unknown_scenario() { setup_repo; assert_fails env LIB_REPO_ROOT="$ROOT" "$VERIFY" nope; }
test_expect_not_contains_passes_when_absent() {
  local root; root="$(make_tmpdir)"; make_docker_stub "$root"
  DOCKER="$root/bin/docker" LAB_NAME=demo assert_succeeds expect_not_contains r1 "vtysh -c 'show version'" "Junos"
}
test_expect_not_contains_fails_when_present() {
  local root out rc=0; root="$(make_tmpdir)"; make_docker_stub "$root"
  out="$(DOCKER="$root/bin/docker" LAB_NAME=demo bash -c 'source "'"$REPO_ROOT"'/scripts/lib.sh"; expect_not_contains r1 "vtysh -c \"show version\"" "FRRouting"' 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "error: r1:"
  assert_contains "$out" "unexpectedly contained 'FRRouting'"
}
test_run_on_node_defaults_to_node_exec() {
  local root; root="$(make_tmpdir)"; make_docker_stub "$root"
  local out; out="$(DOCKER="$root/bin/docker" LAB_NAME=demo ASA_NODES="" _run_on_node r1 "vtysh -c 'show version'")"
  assert_eq "FRRouting 10.1" "$out"
  assert_contains "$(cat "$root/docker.log")" "exec clab-demo-r1"
}

run_tests
