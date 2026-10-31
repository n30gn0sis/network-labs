#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

test_assert_eq_passes_on_equal() { assert_eq a a; }
test_assert_contains_finds_substring() { assert_contains "hello world" world; }
test_assert_not_contains() { assert_not_contains "hello" xyz; }
test_assert_fails_detects_failure() { assert_fails false; }
test_assert_succeeds_detects_success() { assert_succeeds true; }
test_make_tmpdir_creates_dir() {
  local d; d="$(make_tmpdir)"
  [[ -d "$d" ]]
}
test_repo_root_has_git_dir() { [[ -d "$REPO_ROOT/.git" ]]; }

test_failing_assert_midtest_fails_the_test() {
  local d f out rc=0; d="$(make_tmpdir)"; f="$d/test_probe.sh"
  cat >"$f" <<EOF
#!/usr/bin/env bash
source "$REPO_ROOT/tests/helpers.sh"
test_probe() { assert_eq a b; true; }
run_tests
EOF
  out="$(bash "$f" 2>&1)" || rc=$?
  assert_eq 1 "$rc" "probe file exit code"
  assert_contains "$out" "FAIL test_probe"
  assert_contains "$out" "1 tests, 1 failed"
}
test_passing_probe_reports_success() {
  local d f out rc=0; d="$(make_tmpdir)"; f="$d/test_probe.sh"
  cat >"$f" <<EOF
#!/usr/bin/env bash
source "$REPO_ROOT/tests/helpers.sh"
test_probe() { assert_eq a a; }
run_tests
EOF
  out="$(bash "$f" 2>&1)" || rc=$?
  assert_eq 0 "$rc" "probe file exit code"
  assert_contains "$out" "1 tests, 0 failed"
}

run_tests
