#!/usr/bin/env bash
# Minimal test helpers. Source this at the top of every tests/test_*.sh,
# define functions named test_*, and call run_tests at the end.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

_TEST_FAILURES=0
_TEST_COUNT=0
_TMPDIRS=()

_cleanup_tmpdirs() {
  local d
  for d in "${_TMPDIRS[@]:-}"; do
    if [[ -n "$d" && -d "$d" ]]; then rm -rf "$d"; fi
  done
}
trap _cleanup_tmpdirs EXIT

make_tmpdir() {
  local d
  d="$(mktemp -d)"
  _TMPDIRS+=("$d")
  printf '%s\n' "$d"
}

_fail_assert() {
  printf '    ASSERT FAILED: %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-values differ}"
  [[ "$expected" == "$actual" ]] || _fail_assert "$msg: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-output missing text}"
  [[ "$haystack" == *"$needle"* ]] || _fail_assert "$msg: '$needle' not found in: $haystack"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-output has unexpected text}"
  [[ "$haystack" != *"$needle"* ]] || _fail_assert "$msg: '$needle' found in: $haystack"
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    _fail_assert "expected failure but succeeded: $*"
  fi
}

assert_succeeds() {
  if ! "$@" >/dev/null 2>&1; then
    _fail_assert "expected success but failed: $*"
  fi
}

assert_file_exists() {
  [[ -e "$1" ]] || _fail_assert "file missing: $1"
}

run_tests() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
    _TEST_COUNT=$((_TEST_COUNT + 1))
    if ( set -euo pipefail; "$t" ); then
      printf '  ok   %s\n' "$t"
    else
      printf '  FAIL %s\n' "$t"
      _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
  done
  printf '%s: %d tests, %d failed\n' "$(basename "$0")" "$_TEST_COUNT" "$_TEST_FAILURES"
  [[ "$_TEST_FAILURES" -eq 0 ]]
}
