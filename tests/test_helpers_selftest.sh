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

run_tests
