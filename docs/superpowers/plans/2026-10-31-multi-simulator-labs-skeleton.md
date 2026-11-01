# Multi-Simulator Lab Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the repository skeleton for `network-labs`: layout, scenario template, thin shell scripts, docs, and scaffolding tests, so that a real scenario can be added later with `scripts/new-scenario.sh`.

**Architecture:** Each scenario lives in `scenarios/<name>/` with a Containerlab `topology.clab.yml` as its single source of truth, a `scenario.yml` of metadata, per-node `configs/`, optional `yq`-merged `variants/`, and derived `export/` files for GNS3 and EVE-NG. `scripts/*.sh` are thin wrappers that validate inputs and call `containerlab`; `scripts/lib.sh` holds the shared functions; `tests/test_*.sh` exercise everything without Docker.

**Tech Stack:** bash 5, mikefarah `yq` v4, `git`, `shellcheck` (dev), `containerlab` + `docker` (runtime only, never required by tests), GitHub Actions.

Spec: `docs/superpowers/specs/2026-10-31-multi-simulator-labs-design.md`

## Global Constraints

- Every script starts with `#!/usr/bin/env bash` and `set -euo pipefail`, prints usage on `-h`/`--help`, and fails with a one-line `error: ...` message before touching Docker.
- Runtime dependencies are only `bash`, `docker`, `containerlab`, `yq` (mikefarah v4), `git`. Dev dependency: `shellcheck`. No Python, Ansible, or other tooling.
- `yq` means mikefarah yq v4. The Python jq-wrapper `yq` is not acceptable; `require_yq4` must reject it. Install v4 from https://github.com/mikefarah/yq/releases (binary `yq_linux_amd64`) into `~/.local/bin/yq` if `yq --version` does not print `mikefarah/yq`.
- `shellcheck` from https://github.com/koalaman/shellcheck/releases (tarball, binary inside) into `~/.local/bin/shellcheck` if missing. CI's `ubuntu-latest` already has both tools.
- Node names in `topology.clab.yml` are the key everywhere: `configs/<node>/`, variant patches, export files.
- `export/` files are derived. Hand-written ones record `derived from topology.clab.yml @ <short sha>`: as a first-line XML comment in `.unl`; as the first line of a sidecar `<name>.gns3.derived` for JSON `.gns3` files.
- `.superpowers/` (SDD scratch) is git-ignored.
- Placeholder token in the template is exactly `__SCENARIO_NAME__`.
- `scenario.yml` required keys: `name`, `title`, `topic`, `status` (`draft`|`ready`), `default_variant`, `variants.<default_variant>`, `simulators.containerlab`, `simulators.gns3`, `simulators.eve-ng`. `name` must equal the directory name except for `_template`.
- Merged variant topologies go to `scenarios/<name>/.<variant>.build.clab.yml` (beside the source topology), which is git-ignored.
- Tests never need Docker or containerlab. External binaries are injected through `CLAB` (default `containerlab`) and `DOCKER` (default `docker`) environment variables so tests can point them at stubs.
- Commit after every task. Commit messages: conventional prefix (`feat:`, `test:`, `docs:`, `ci:`), end with the attribution lines given by the harness. No model identifiers anywhere in committed content.
- Work on branch `ccr-00157a22-qiys9w`.

---

## File map

| Path | Responsibility |
|---|---|
| `.gitignore` | ignore `scenarios/*/.*.build.clab.yml`, `clab-*/` runtime dirs |
| `scripts/lib.sh` | shared functions: logging, tool checks, scenario lookup, metadata, validation, variant resolution, topology build, node helpers |
| `scripts/test.sh` | run `shellcheck` on all scripts, then every `tests/test_*.sh`; exit non-zero on any failure |
| `tests/helpers.sh` | tiny assertion library and test runner used by every `tests/test_*.sh` |
| `tests/test_lib.sh` | tests for `lib.sh` functions |
| `tests/test_template.sh` | template passes validation and has every expected file |
| `tests/test_new_scenario.sh` | `new-scenario.sh` behaviour |
| `tests/test_up_down.sh` | `up.sh` / `down.sh` argument handling, draft refusal, stub invocation |
| `tests/test_verify.sh` | `verify.sh` runner and node helpers with a `DOCKER` stub |
| `tests/test_export.sh` | `export.sh` reporting and staleness check |
| `scenarios/_template/**` | the scenario template |
| `scripts/new-scenario.sh` | copy template, replace placeholder |
| `scripts/up.sh`, `scripts/down.sh` | deploy / destroy via `$CLAB` |
| `scripts/verify.sh` | run a scenario's `verify.sh` |
| `scripts/export.sh` | report export path, hand-written flag, staleness |
| `docs/conventions.md`, `docs/simulators/*.md`, `images/README.md` | documentation |
| `.github/workflows/ci.yml` | runs `scripts/test.sh` |
| `README.md` | purpose, quick start |

---

### Task 1: Dev tooling check, `.gitignore`, test harness

**Files:**
- Create: `.gitignore`
- Create: `tests/helpers.sh`
- Create: `scripts/test.sh`
- Create: `tests/test_helpers_selftest.sh`

**Interfaces:**
- Produces: `tests/helpers.sh` exporting `assert_eq EXPECTED ACTUAL [MSG]`, `assert_contains HAYSTACK NEEDLE [MSG]`, `assert_not_contains HAYSTACK NEEDLE [MSG]`, `assert_fails CMD...` (expects non-zero exit), `assert_succeeds CMD...`, `assert_file_exists PATH`, `make_tmpdir` (echoes a temp dir removed on exit), `run_tests` (runs all functions named `test_*` in the current file, prints summary, exits 1 if any failed). Each test file ends with `run_tests`.
- Produces: `scripts/test.sh` which later tasks add nothing to; it discovers `tests/test_*.sh` automatically.
- Produces: `REPO_ROOT` variable set by `tests/helpers.sh` (absolute path to the repository root).

- [ ] **Step 1: Verify or install dev tools**

Run:
```bash
yq --version; shellcheck --version | head -2
```
Expected: `yq (https://github.com/mikefarah/yq/) version v4.x` and `ShellCheck - shell script analysis tool`. If `yq --version` says `jq wrapper` or shellcheck is missing, install:
```bash
mkdir -p ~/.local/bin
curl -sSL -o ~/.local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 && chmod +x ~/.local/bin/yq
curl -sSL https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz | tar -xJ -C /tmp && mv /tmp/shellcheck-v0.10.0/shellcheck ~/.local/bin/
export PATH="$HOME/.local/bin:$PATH"
```
If downloads are blocked in your environment, stop and tell the user; CI will still run the tests.

- [ ] **Step 2: Write `.gitignore`**

```gitignore
# merged variant topologies and containerlab runtime directories
scenarios/*/.build/
scenarios/*/clab-*/
.build/
# local tooling scratch
.superpowers/
```

- [ ] **Step 3: Write `tests/helpers.sh`**

```bash
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
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
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
```

- [ ] **Step 4: Write a self-test for the helpers**

`tests/test_helpers_selftest.sh`:
```bash
#!/usr/bin/env bash
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
```

- [ ] **Step 5: Write `scripts/test.sh`**

```bash
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
mapfile -t scripts < <(find scripts tests scenarios -name '*.sh' -type f | sort)
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
```

- [ ] **Step 6: Make scripts executable and run**

Run: `chmod +x scripts/test.sh tests/*.sh && scripts/test.sh`
Expected: shellcheck clean, `test_helpers_selftest.sh: 7 tests, 0 failed`, `ALL PASSED`. (shellcheck may warn SC1091 on `source`; `-x` follows sources so it should resolve. If it still warns about the dynamic path, add `# shellcheck source=tests/helpers.sh` above the `source` line in the test file.)

- [ ] **Step 7: Commit**

```bash
git add .gitignore scripts/test.sh tests/helpers.sh tests/test_helpers_selftest.sh
git commit -m "test: add shell test harness and test runner"
```

---

### Task 2: `scripts/lib.sh` core: logging, tool checks, scenario lookup, metadata, validation

**Files:**
- Create: `scripts/lib.sh`
- Create: `tests/test_lib.sh`

**Interfaces:**
- Produces (all in `scripts/lib.sh`, sourced with `source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"` from scripts, or `source "$REPO_ROOT/scripts/lib.sh"` from tests):
  - `LIB_REPO_ROOT`: absolute repo root.
  - `log MSG...`: prints to stderr.
  - `fail MSG...`: prints `error: MSG` to stderr, exits 1.
  - `require_tools TOOL...`: `fail` if any is not on PATH.
  - `require_yq4`: `fail` unless `yq --version` contains `mikefarah/yq`.
  - `scenario_dir NAME`: echoes `$LIB_REPO_ROOT/scenarios/NAME`; `fail` if not a directory or if NAME contains `/`.
  - `meta DIR YQ_PATH`: echoes `yq -r "YQ_PATH" DIR/scenario.yml` (prints `null` when absent).
  - `validate_scenario_yml DIR`: prints one `scenario.yml: ...` line per problem to stderr, returns 1 if any; returns 0 when valid.
  - `resolve_variant DIR [VARIANT]`: echoes VARIANT if given and present under `.variants`, default_variant if empty; `fail` otherwise.

- [ ] **Step 1: Write failing tests**

`tests/test_lib.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$REPO_ROOT/scripts/lib.sh"

# Builds a valid scenario directory under a fake repo root and echoes the dir.
make_scenario() {
  local root="$1" name="$2" status="${3:-ready}"
  local dir="$root/scenarios/$name"
  mkdir -p "$dir"
  cat >"$dir/scenario.yml" <<EOF
name: $name
title: Test scenario
topic: test/topic
status: $status
default_variant: frr
variants:
  frr:
    images:
      router: quay.io/frrouting/frr:10.1
  cisco-iosxe:
    images:
      router: vrnetlab/cisco_c8000v:17.12
simulators:
  containerlab: native
  gns3: none
  eve-ng: none
EOF
  printf '%s\n' "$dir"
}

test_fail_prints_error_and_exits_1() {
  local out rc=0
  out="$( (fail "boom") 2>&1 )" || rc=$?
  assert_eq 1 "$rc" "exit code"
  assert_eq "error: boom" "$out"
}

test_require_tools_passes_for_present_tool() { assert_succeeds require_tools bash; }
test_require_tools_fails_for_missing_tool() { assert_fails require_tools definitely-not-a-tool-xyz; }
test_require_yq4_passes_with_v4() { assert_succeeds require_yq4; }

test_scenario_dir_resolves_existing() {
  local root; root="$(make_tmpdir)"
  make_scenario "$root" demo >/dev/null
  local got; got="$(LIB_REPO_ROOT="$root" scenario_dir demo)"
  assert_eq "$root/scenarios/demo" "$got"
}
test_scenario_dir_fails_for_missing() {
  local root; root="$(make_tmpdir)"
  assert_fails env LIB_REPO_ROOT="$root" bash -c 'source "'"$REPO_ROOT"'/scripts/lib.sh"; scenario_dir nope'
}
test_scenario_dir_rejects_slash() {
  assert_fails bash -c 'source "'"$REPO_ROOT"'/scripts/lib.sh"; scenario_dir ../etc'
}

test_meta_reads_value() {
  local root dir; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"
  assert_eq ready "$(meta "$dir" .status)"
  assert_eq quay.io/frrouting/frr:10.1 "$(meta "$dir" .variants.frr.images.router)"
}
test_meta_prints_null_when_missing() {
  local root dir; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"
  assert_eq null "$(meta "$dir" .nothing)"
}

test_validate_accepts_valid_scenario() {
  local root dir; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"
  assert_succeeds validate_scenario_yml "$dir"
}
test_validate_reports_missing_keys() {
  local root dir out; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"
  printf 'name: demo\n' >"$dir/scenario.yml"
  out="$(validate_scenario_yml "$dir" 2>&1)" && return 1
  assert_contains "$out" "missing key: title"
  assert_contains "$out" "missing key: simulators.eve-ng"
}
test_validate_rejects_bad_status() {
  local root dir out; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo wip)"
  out="$(validate_scenario_yml "$dir" 2>&1)" && return 1
  assert_contains "$out" "status must be draft or ready"
}
test_validate_rejects_name_mismatch() {
  local root dir out; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"
  sed -i 's/^name: demo/name: other/' "$dir/scenario.yml"
  out="$(validate_scenario_yml "$dir" 2>&1)" && return 1
  assert_contains "$out" "name 'other' must equal directory name 'demo'"
}
test_validate_allows_template_placeholder_name() {
  local root dir; root="$(make_tmpdir)"; dir="$(make_scenario "$root" _template)"
  sed -i 's/^name: _template/name: __SCENARIO_NAME__/' "$dir/scenario.yml"
  assert_succeeds validate_scenario_yml "$dir"
}
test_validate_requires_default_variant_defined() {
  local root dir out; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"
  sed -i 's/^default_variant: frr/default_variant: nope/' "$dir/scenario.yml"
  out="$(validate_scenario_yml "$dir" 2>&1)" && return 1
  assert_contains "$out" "default_variant 'nope' is not defined under variants"
}
test_validate_fails_when_file_missing() {
  local root; root="$(make_tmpdir)"; mkdir -p "$root/scenarios/empty"
  assert_fails validate_scenario_yml "$root/scenarios/empty"
}

test_resolve_variant_defaults() {
  local root dir; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"
  assert_eq frr "$(resolve_variant "$dir" "")"
  assert_eq frr "$(resolve_variant "$dir")"
}
test_resolve_variant_accepts_defined() {
  local root dir; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"
  assert_eq cisco-iosxe "$(resolve_variant "$dir" cisco-iosxe)"
}
test_resolve_variant_rejects_unknown() {
  local root dir; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"
  assert_fails bash -c 'source "'"$REPO_ROOT"'/scripts/lib.sh"; resolve_variant "'"$dir"'" junos'
}

run_tests
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_lib.sh`
Expected: fails immediately: `scripts/lib.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/lib.sh`**

```bash
#!/usr/bin/env bash
# Shared functions for network-labs scripts and scenario verify.sh files.
# Source this file; do not execute it.

LIB_REPO_ROOT="${LIB_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

log()  { printf '%s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || fail "'$t' not found on PATH"
  done
}

require_yq4() {
  require_tools yq
  yq --version 2>&1 | grep -q 'mikefarah/yq' \
    || fail "yq must be mikefarah yq v4 (https://github.com/mikefarah/yq); found: $(yq --version 2>&1 | head -1)"
}

# scenario_dir NAME -> absolute path to scenarios/NAME
scenario_dir() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "scenario name required"
  [[ "$name" != */* ]] || fail "scenario name must not contain '/': $name"
  local dir="$LIB_REPO_ROOT/scenarios/$name"
  [[ -d "$dir" ]] || fail "no such scenario: $name (expected $dir)"
  printf '%s\n' "$dir"
}

# meta DIR YQ_PATH -> raw value, or 'null' when absent
meta() {
  local dir="$1" path="$2"
  yq -r "$path" "$dir/scenario.yml"
}

# validate_scenario_yml DIR -> 0 if valid, else prints problems to stderr and returns 1
validate_scenario_yml() {
  local dir="$1" file="$1/scenario.yml" problems=0 key val
  if [[ ! -f "$file" ]]; then
    log "scenario.yml: missing in $dir"
    return 1
  fi
  if ! yq -e '.' "$file" >/dev/null 2>&1; then
    log "scenario.yml: not valid YAML"
    return 1
  fi
  for key in name title topic status default_variant simulators.containerlab simulators.gns3 simulators.eve-ng; do
    val="$(yq -r ".$key // \"null\"" "$file")"
    if [[ "$val" == "null" ]]; then
      log "scenario.yml: missing key: $key"
      problems=$((problems + 1))
    fi
  done
  val="$(yq -r '.status // "null"' "$file")"
  if [[ "$val" != "null" && "$val" != "draft" && "$val" != "ready" ]]; then
    log "scenario.yml: status must be draft or ready, got '$val'"
    problems=$((problems + 1))
  fi
  local name dirname
  name="$(yq -r '.name // "null"' "$file")"
  dirname="$(basename "$dir")"
  if [[ "$name" != "null" && "$dirname" != "_template" && "$name" != "$dirname" ]]; then
    log "scenario.yml: name '$name' must equal directory name '$dirname'"
    problems=$((problems + 1))
  fi
  local dv
  dv="$(yq -r '.default_variant // "null"' "$file")"
  if [[ "$dv" != "null" ]]; then
    if [[ "$(yq -r ".variants[\"$dv\"] // \"null\"" "$file")" == "null" ]]; then
      log "scenario.yml: default_variant '$dv' is not defined under variants"
      problems=$((problems + 1))
    fi
  fi
  [[ "$problems" -eq 0 ]]
}

# resolve_variant DIR [VARIANT] -> VARIANT if defined, else default_variant
resolve_variant() {
  local dir="$1" variant="${2:-}"
  if [[ -z "$variant" ]]; then
    variant="$(meta "$dir" .default_variant)"
  fi
  [[ "$(meta "$dir" ".variants[\"$variant\"]")" != "null" ]] \
    || fail "variant '$variant' is not defined in $dir/scenario.yml"
  printf '%s\n' "$variant"
}
```

- [ ] **Step 4: Run tests**

Run: `chmod +x tests/test_lib.sh && scripts/test.sh`
Expected: `test_lib.sh: 19 tests, 0 failed`, `ALL PASSED`. If shellcheck complains about `LIB_REPO_ROOT` being unused in lib.sh, that's fine once Task 3 uses it; for now add `export LIB_REPO_ROOT` after the assignment.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/test_lib.sh
git commit -m "feat: add lib.sh with scenario lookup, metadata and validation"
```

---

### Task 3: Scenario template

**Files:**
- Create: `scenarios/_template/README.md`
- Create: `scenarios/_template/scenario.yml`
- Create: `scenarios/_template/topology.clab.yml`
- Create: `scenarios/_template/verify.sh`
- Create: `scenarios/_template/configs/r1/frr.conf`
- Create: `scenarios/_template/configs/r1/daemons`
- Create: `scenarios/_template/variants/README.md`
- Create: `scenarios/_template/export/gns3/.gitkeep`
- Create: `scenarios/_template/export/eve-ng/.gitkeep`
- Create: `tests/test_template.sh`

**Interfaces:**
- Consumes: `validate_scenario_yml` from Task 2.
- Produces: the template that `new-scenario.sh` (Task 4) copies. Placeholder `__SCENARIO_NAME__` appears in `README.md`, `scenario.yml`, `topology.clab.yml`. The template's `verify.sh` uses `expect_contains` and `wait_for` from Task 7 (they are sourced at run time, not needed for this task's tests).

- [ ] **Step 1: Write failing test**

`tests/test_template.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
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
```

- [ ] **Step 2: Run to verify failure**

Run: `chmod +x tests/test_template.sh && bash tests/test_template.sh`
Expected: `FAIL test_template_has_expected_files` and others; summary shows failures.

- [ ] **Step 3: Write the template files**

`scenarios/_template/scenario.yml`:
```yaml
# Scenario metadata. The topology itself lives in topology.clab.yml.
name: __SCENARIO_NAME__
title: Short descriptive title
topic: category/subtopic          # e.g. routing/ospf, switching/vlan
status: draft                     # draft | ready. Scripts refuse draft without --force.
default_variant: frr
variants:
  frr:                            # default variant: free images only
    images:
      router: quay.io/frrouting/frr:10.1
  # cisco-iosxe:                  # example vendor variant (uncomment to use)
  #   images:
  #     router: vrnetlab/cisco_c8000v:17.12
  #   notes: build the image with vrnetlab; see images/README.md
simulators:
  containerlab: native
  gns3: none                      # or export/gns3/__SCENARIO_NAME__.gns3
  eve-ng: none                    # or export/eve-ng/__SCENARIO_NAME__.unl
```

`scenarios/_template/topology.clab.yml`:
```yaml
# Single source of truth for this scenario's topology.
# Node names here are the key used by configs/<node>/, variants/, and export/.
name: __SCENARIO_NAME__

topology:
  nodes:
    r1:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/r1/frr.conf:/etc/frr/frr.conf
        - configs/r1/daemons:/etc/frr/daemons
  links: []
  # Example link once you have a second node:
  #   - endpoints: ["r1:eth1", "r2:eth1"]
```

`scenarios/_template/configs/r1/daemons`:
```
# FRR daemons to start. Enable what the scenario needs.
zebra=yes
bgpd=no
ospfd=no
ospf6d=no
ripd=no
isisd=no
staticd=yes
```

`scenarios/_template/configs/r1/frr.conf`:
```
! FRR startup configuration for r1
frr defaults traditional
hostname r1
log syslog informational
!
line vty
!
```

`scenarios/_template/verify.sh`:
```bash
#!/usr/bin/env bash
# Verification for __SCENARIO_NAME__. Run via: scripts/verify.sh <scenario> [--variant X]
# scripts/verify.sh exports LAB_NAME, VARIANT and LIB_SH before calling this.
set -euo pipefail
# shellcheck source=../../scripts/lib.sh
source "${LIB_SH:?run this via scripts/verify.sh}"

# Each check: expect_contains <node> <command> <expected substring>
# wait_for <timeout-seconds> <node> <command> <expected substring>
wait_for 30 r1 "vtysh -c 'show version'" "FRRouting"
expect_contains r1 "vtysh -c 'show running-config'" "hostname r1"

log "all checks passed"
```

`scenarios/_template/variants/README.md`:
```markdown
# Variants

A variant swaps images (and, when the NOS syntax differs, configs) without
changing the topology. Create `variants/<name>/` containing:

- `topology.patch.yml`: per-node overrides, deep-merged onto `topology.clab.yml`.
  Example:
  ```yaml
  topology:
    nodes:
      r1:
        kind: cisco_c8000v
        image: vrnetlab/cisco_c8000v:17.12
        binds: []
        startup-config: variants/cisco-iosxe/configs/r1/startup.cfg
  ```
- `configs/<node>/`: replacement startup configs for that NOS.

Nodes without an override keep the default topology and configs. Register the
variant under `variants:` in `scenario.yml`.
```

`scenarios/_template/README.md`:
```markdown
# __SCENARIO_NAME__

## Objective

What this scenario tests and why. One paragraph.

## Topology

```
+----+
| r1 |
+----+
```

Nodes: `r1` (FRR). Links: none yet.

## Variants

- `frr` (default): free images only.

## Tasks

1. Bring up: `scripts/up.sh __SCENARIO_NAME__`
2. Describe the configuration steps a human or script performs here.

## Verification

`scripts/verify.sh __SCENARIO_NAME__` checks:

- r1 answers `show version`.
- r1 running config has `hostname r1`.

## Simulators

| Simulator | Status |
|---|---|
| Containerlab | native |
| GNS3 | none (see `export/gns3/`) |
| EVE-NG | none (see `export/eve-ng/`) |

## Teardown

`scripts/down.sh __SCENARIO_NAME__`
```

Create empty `scenarios/_template/export/gns3/.gitkeep` and `scenarios/_template/export/eve-ng/.gitkeep`.

- [ ] **Step 4: Run tests**

Run: `chmod +x scenarios/_template/verify.sh && scripts/test.sh`
Expected: `test_template.sh: 7 tests, 0 failed`, `ALL PASSED`. The `# shellcheck source=` directive lets shellcheck resolve `log`, `wait_for` and `expect_contains` from `lib.sh`; `scripts/verify.sh` (Task 7) sets `LIB_SH` at run time.

- [ ] **Step 5: Commit**

```bash
git add scenarios/_template tests/test_template.sh
git commit -m "feat: add scenario template"
```

---

### Task 4: `scripts/new-scenario.sh`

**Files:**
- Create: `scripts/new-scenario.sh`
- Create: `tests/test_new_scenario.sh`

**Interfaces:**
- Consumes: `fail`, `log`, `LIB_REPO_ROOT` from `lib.sh`; template from Task 3.
- Produces: `scripts/new-scenario.sh NAME` creating `scenarios/NAME` with every `__SCENARIO_NAME__` replaced. Honors `LIB_REPO_ROOT` so tests can target a temp copy of the repo.

- [ ] **Step 1: Write failing test**

`tests/test_new_scenario.sh`:
```bash
#!/usr/bin/env bash
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
  LIB_REPO_ROOT="$root" "$NEW" ospf-basic >/dev/null
  assert_file_exists "$root/scenarios/ospf-basic/scenario.yml"
  assert_file_exists "$root/scenarios/ospf-basic/topology.clab.yml"
  assert_file_exists "$root/scenarios/ospf-basic/verify.sh"
  assert_file_exists "$root/scenarios/ospf-basic/export/gns3/.gitkeep"
  [[ -x "$root/scenarios/ospf-basic/verify.sh" ]]
}
test_replaces_placeholder_everywhere() {
  local root; root="$(fake_root)"
  LIB_REPO_ROOT="$root" "$NEW" ospf-basic >/dev/null
  if grep -r "__SCENARIO_NAME__" "$root/scenarios/ospf-basic" >/dev/null; then
    return 1
  fi
  assert_eq ospf-basic "$(yq -r .name "$root/scenarios/ospf-basic/scenario.yml")"
  assert_eq ospf-basic "$(yq -r .name "$root/scenarios/ospf-basic/topology.clab.yml")"
}
test_refuses_to_overwrite() {
  local root; root="$(fake_root)"
  LIB_REPO_ROOT="$root" "$NEW" ospf-basic >/dev/null
  assert_fails env LIB_REPO_ROOT="$root" "$NEW" ospf-basic
}
test_prints_next_steps() {
  local root out; root="$(fake_root)"
  out="$(LIB_REPO_ROOT="$root" "$NEW" ospf-basic 2>&1)"
  assert_contains "$out" "scenarios/ospf-basic"
  assert_contains "$out" "scenario.yml"
}

run_tests
```

- [ ] **Step 2: Run to verify failure**

Run: `chmod +x tests/test_new_scenario.sh && bash tests/test_new_scenario.sh`
Expected: all tests FAIL (script missing).

- [ ] **Step 3: Write `scripts/new-scenario.sh`**

```bash
#!/usr/bin/env bash
# Create a new scenario from scenarios/_template.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: scripts/new-scenario.sh <name>

Copies scenarios/_template to scenarios/<name> and replaces __SCENARIO_NAME__.
<name> must match ^[a-z0-9][a-z0-9-]*$ (lowercase, digits, hyphens).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; fail "scenario name required" ;;
esac
[[ $# -eq 1 ]] || { usage >&2; fail "exactly one argument expected"; }

name="$1"
[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid scenario name '$name' (use lowercase letters, digits, hyphens)"

template="$LIB_REPO_ROOT/scenarios/_template"
dest="$LIB_REPO_ROOT/scenarios/$name"
[[ -d "$template" ]] || fail "template missing: $template"
[[ ! -e "$dest" ]] || fail "scenario already exists: $dest"

cp -r "$template" "$dest"
while IFS= read -r -d '' f; do
  sed -i "s/__SCENARIO_NAME__/$name/g" "$f"
done < <(find "$dest" -type f -print0)
chmod +x "$dest/verify.sh"

log "created scenarios/$name"
log "next: edit scenarios/$name/scenario.yml, topology.clab.yml, configs/, README.md"
log "      then set status: ready and run scripts/up.sh $name"
```

- [ ] **Step 4: Run tests**

Run: `chmod +x scripts/new-scenario.sh && scripts/test.sh`
Expected: `test_new_scenario.sh: 7 tests, 0 failed`, `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add scripts/new-scenario.sh tests/test_new_scenario.sh
git commit -m "feat: add new-scenario.sh to scaffold scenarios from the template"
```

---

### Task 5: Variant topology build (`build_topology` in `lib.sh`)

**Files:**
- Modify: `scripts/lib.sh` (append)
- Modify: `tests/test_lib.sh` (append tests before `run_tests`)

**Interfaces:**
- Produces: `build_topology DIR VARIANT` → writes `DIR/.build/VARIANT.clab.yml` and echoes its path. If `DIR/variants/VARIANT/topology.patch.yml` exists, it is deep-merged onto `DIR/topology.clab.yml`; otherwise the topology is copied unchanged. The `.build` dir is created on demand.

- [ ] **Step 1: Write failing tests** (append to `tests/test_lib.sh` above `run_tests`)

```bash
make_topology() {
  local dir="$1"
  cat >"$dir/topology.clab.yml" <<'EOF'
name: demo
topology:
  nodes:
    r1:
      kind: linux
      image: quay.io/frrouting/frr:10.1
      binds:
        - configs/r1/frr.conf:/etc/frr/frr.conf
    r2:
      kind: linux
      image: quay.io/frrouting/frr:10.1
  links:
    - endpoints: ["r1:eth1", "r2:eth1"]
EOF
}

test_build_topology_copies_default_without_patch() {
  local root dir out; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"; make_topology "$dir"
  out="$(build_topology "$dir" frr)"
  assert_eq "$dir/.build/frr.clab.yml" "$out"
  assert_eq quay.io/frrouting/frr:10.1 "$(yq -r .topology.nodes.r1.image "$out")"
  assert_eq r1:eth1 "$(yq -r '.topology.links[0].endpoints[0]' "$out")"
}
test_build_topology_merges_patch() {
  local root dir out; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"; make_topology "$dir"
  mkdir -p "$dir/variants/cisco-iosxe"
  cat >"$dir/variants/cisco-iosxe/topology.patch.yml" <<'EOF'
topology:
  nodes:
    r1:
      kind: cisco_c8000v
      image: vrnetlab/cisco_c8000v:17.12
      binds: []
EOF
  out="$(build_topology "$dir" cisco-iosxe)"
  assert_eq "$dir/.build/cisco-iosxe.clab.yml" "$out"
  assert_eq cisco_c8000v "$(yq -r .topology.nodes.r1.kind "$out")"
  assert_eq vrnetlab/cisco_c8000v:17.12 "$(yq -r .topology.nodes.r1.image "$out")"
  assert_eq 0 "$(yq -r '.topology.nodes.r1.binds | length' "$out")" "binds replaced by patch"
  assert_eq quay.io/frrouting/frr:10.1 "$(yq -r .topology.nodes.r2.image "$out")" "untouched node keeps default"
  assert_eq demo "$(yq -r .name "$out")"
}
test_build_topology_fails_without_topology_file() {
  local root dir; root="$(make_tmpdir)"; dir="$(make_scenario "$root" demo)"
  assert_fails bash -c 'source "'"$REPO_ROOT"'/scripts/lib.sh"; build_topology "'"$dir"'" frr'
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_lib.sh 2>&1 | tail -5`
Expected: three `FAIL test_build_topology_*` lines.

- [ ] **Step 3: Append to `scripts/lib.sh`**

```bash
# build_topology DIR VARIANT -> writes DIR/.build/VARIANT.clab.yml and echoes the path.
# Deep-merges variants/VARIANT/topology.patch.yml onto topology.clab.yml when present.
build_topology() {
  local dir="$1" variant="$2"
  local base="$dir/topology.clab.yml" patch="$dir/variants/$variant/topology.patch.yml"
  local out="$dir/.build/$variant.clab.yml"
  [[ -f "$base" ]] || fail "topology missing: $base"
  mkdir -p "$dir/.build"
  if [[ -f "$patch" ]]; then
    yq eval-all '. as $item ireduce ({}; . * $item)' "$base" "$patch" >"$out"
  else
    cp "$base" "$out"
  fi
  printf '%s\n' "$out"
}
```

Note for the implementer: yq's `*` on maps is a deep merge; for arrays it replaces (so `binds: []` clears the default binds, which is what the test asserts).

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: `test_lib.sh: 22 tests, 0 failed`, `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/test_lib.sh
git commit -m "feat: add build_topology with yq variant overlay merge"
```

---

### Task 6: `scripts/up.sh` and `scripts/down.sh`

**Files:**
- Create: `scripts/up.sh`
- Create: `scripts/down.sh`
- Create: `tests/test_up_down.sh`

**Interfaces:**
- Consumes: `scenario_dir`, `validate_scenario_yml`, `resolve_variant`, `build_topology`, `require_tools`, `require_yq4`, `fail`, `log`.
- Produces: `up.sh SCENARIO [--variant X] [--force]` runs `"$CLAB" deploy --topo <built> --reconfigure` from the scenario dir; `down.sh SCENARIO [--variant X]` runs `"$CLAB" destroy --topo <built> --cleanup`. `CLAB` defaults to `containerlab`.
- Common option parsing lives in a function `parse_scenario_args` in `lib.sh` producing globals `ARG_SCENARIO`, `ARG_VARIANT`, `ARG_FORCE`.

- [ ] **Step 1: Write failing test**

`tests/test_up_down.sh`:
```bash
#!/usr/bin/env bash
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
  assert_contains "$log" "deploy --topo $ROOT/scenarios/demo/.build/frr.clab.yml --reconfigure"
  assert_contains "$log" "$ROOT/scenarios/demo" "runs from scenario dir"
  assert_eq demo "$(yq -r .name "$ROOT/scenarios/demo/.build/frr.clab.yml")"
}
test_up_rejects_unknown_variant() { setup; set_ready; assert_fails run_up demo --variant junos; }
test_up_fails_when_clab_missing() {
  setup; set_ready
  assert_fails env LIB_REPO_ROOT="$ROOT" CLAB="/nonexistent/containerlab" "$UP" demo
}
test_down_destroys_with_cleanup() {
  setup; set_ready
  run_down demo >/dev/null 2>&1
  assert_contains "$(cat "$STUB_LOG")" "destroy --topo $ROOT/scenarios/demo/.build/frr.clab.yml --cleanup"
}
test_down_works_on_draft_without_force() {
  setup
  assert_succeeds run_down demo
}

run_tests
```

- [ ] **Step 2: Run to verify failure**

Run: `chmod +x tests/test_up_down.sh && bash tests/test_up_down.sh 2>&1 | tail -3`
Expected: failures (scripts missing).

- [ ] **Step 3: Append `parse_scenario_args` to `scripts/lib.sh`**

```bash
# parse_scenario_args ARGS... -> sets ARG_SCENARIO, ARG_VARIANT, ARG_FORCE (0/1).
# Accepts: <scenario> [--variant X] [--force]. Calls fail on anything else.
parse_scenario_args() {
  ARG_SCENARIO="" ARG_VARIANT="" ARG_FORCE=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --variant)
        [[ $# -ge 2 ]] || fail "--variant requires a value"
        ARG_VARIANT="$2"; shift 2 ;;
      --variant=*) ARG_VARIANT="${1#--variant=}"; shift ;;
      --force) ARG_FORCE=1; shift ;;
      -*) fail "unknown option: $1" ;;
      *)
        [[ -z "$ARG_SCENARIO" ]] || fail "unexpected argument: $1"
        ARG_SCENARIO="$1"; shift ;;
    esac
  done
  [[ -n "$ARG_SCENARIO" ]] || fail "scenario name required"
}
```

- [ ] **Step 4: Write `scripts/up.sh`**

```bash
#!/usr/bin/env bash
# Deploy a scenario with containerlab.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: scripts/up.sh <scenario> [--variant <name>] [--force]

Merges the variant overlay (if any) into .build/<variant>.clab.yml and runs
`containerlab deploy`. Refuses scenarios with status: draft unless --force.
Environment: CLAB (default: containerlab) overrides the containerlab binary.
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -gt 0 ]] || { usage >&2; fail "scenario name required"; }

parse_scenario_args "$@"
require_yq4
dir="$(scenario_dir "$ARG_SCENARIO")"
validate_scenario_yml "$dir" || fail "scenario.yml is invalid"

if [[ "$(meta "$dir" .status)" == "draft" && "$ARG_FORCE" -ne 1 ]]; then
  fail "scenario '$ARG_SCENARIO' status is draft; set status: ready or pass --force"
fi

variant="$(resolve_variant "$dir" "$ARG_VARIANT")"
clab="${CLAB:-containerlab}"
command -v "$clab" >/dev/null 2>&1 || fail "'$clab' not found; install containerlab or set CLAB"

topo="$(build_topology "$dir" "$variant")"
log "deploying $ARG_SCENARIO (variant: $variant) from $topo"
cd "$dir"
exec "$clab" deploy --topo "$topo" --reconfigure
```

- [ ] **Step 5: Write `scripts/down.sh`**

```bash
#!/usr/bin/env bash
# Destroy a deployed scenario.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: scripts/down.sh <scenario> [--variant <name>]

Runs `containerlab destroy --cleanup` on the scenario's built topology.
Environment: CLAB (default: containerlab) overrides the containerlab binary.
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -gt 0 ]] || { usage >&2; fail "scenario name required"; }

parse_scenario_args "$@"
require_yq4
dir="$(scenario_dir "$ARG_SCENARIO")"
validate_scenario_yml "$dir" || fail "scenario.yml is invalid"
variant="$(resolve_variant "$dir" "$ARG_VARIANT")"
clab="${CLAB:-containerlab}"
command -v "$clab" >/dev/null 2>&1 || fail "'$clab' not found; install containerlab or set CLAB"

topo="$(build_topology "$dir" "$variant")"
log "destroying $ARG_SCENARIO (variant: $variant)"
cd "$dir"
exec "$clab" destroy --topo "$topo" --cleanup
```

- [ ] **Step 6: Run tests**

Run: `chmod +x scripts/up.sh scripts/down.sh && scripts/test.sh`
Expected: `test_up_down.sh: 12 tests, 0 failed`, `ALL PASSED`.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib.sh scripts/up.sh scripts/down.sh tests/test_up_down.sh
git commit -m "feat: add up.sh and down.sh wrapping containerlab deploy/destroy"
```

---

### Task 7: Node helpers and `scripts/verify.sh`

**Files:**
- Modify: `scripts/lib.sh` (append)
- Create: `scripts/verify.sh`
- Create: `tests/test_verify.sh`

**Interfaces:**
- Produces in `lib.sh`:
  - `node_exec NODE CMD`: runs `"$DOCKER" exec "clab-${LAB_NAME}-${NODE}" sh -c "CMD"`; `fail` if `LAB_NAME` unset.
  - `expect_contains NODE CMD EXPECTED`: `fail` unless `node_exec` output contains EXPECTED; logs `ok: NODE: CMD` on success.
  - `wait_for TIMEOUT NODE CMD EXPECTED`: retries every 2 seconds (override `WAIT_INTERVAL`) until output contains EXPECTED or TIMEOUT seconds pass, then `fail`.
- Produces: `scripts/verify.sh SCENARIO [--variant X]` exports `LAB_NAME` (from the built topology `.name`), `VARIANT`, `LIB_SH="$LIB_REPO_ROOT/scripts/lib.sh"`, then runs `DIR/verify.sh` from DIR.
- Consumes: the template's `verify.sh` sources `$LIB_SH` (Task 3 step 4 note).

- [ ] **Step 1: Write failing test**

`tests/test_verify.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$REPO_ROOT/scripts/lib.sh"

VERIFY="$REPO_ROOT/scripts/verify.sh"

# docker stub: echoes a canned reply based on the command it receives.
make_docker_stub() {
  local root="$1"
  mkdir -p "$root/bin"
  cat >"$root/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/docker.log"
case "\$*" in
  *"show version"*) echo "FRRouting 10.1" ;;
  *"show running-config"*) echo "hostname r1" ;;
  *) echo "unknown" ;;
esac
EOF
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
  printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "$LIB_SH"\nexpect_contains r1 "echo hi" "nope"\n' >"$ROOT/scenarios/demo/verify.sh"
  assert_fails env LIB_REPO_ROOT="$ROOT" DOCKER="$ROOT/bin/docker" "$VERIFY" demo
}
test_verify_exports_variant_and_lab_name() {
  setup_repo
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho "LAB=$LAB_NAME VARIANT=$VARIANT"\n' >"$ROOT/scenarios/demo/verify.sh"
  local out; out="$(LIB_REPO_ROOT="$ROOT" DOCKER="$ROOT/bin/docker" "$VERIFY" demo 2>&1)"
  assert_contains "$out" "LAB=demo VARIANT=frr"
}
test_verify_fails_for_unknown_scenario() { setup_repo; assert_fails env LIB_REPO_ROOT="$ROOT" "$VERIFY" nope; }

run_tests
```

- [ ] **Step 2: Run to verify failure**

Run: `chmod +x tests/test_verify.sh && bash tests/test_verify.sh 2>&1 | tail -3`
Expected: failures (functions and script missing).

- [ ] **Step 3: Append node helpers to `scripts/lib.sh`**

```bash
# ---- node helpers for scenario verify.sh files ---------------------------
# Require LAB_NAME (set by scripts/verify.sh from the topology's `name`).
# DOCKER (default: docker) overrides the docker binary, e.g. for tests.

node_exec() {
  local node="$1" cmd="$2"
  [[ -n "${LAB_NAME:-}" ]] || fail "LAB_NAME is not set; run via scripts/verify.sh"
  "${DOCKER:-docker}" exec "clab-${LAB_NAME}-${node}" sh -c "$cmd"
}

expect_contains() {
  local node="$1" cmd="$2" expected="$3" out
  out="$(node_exec "$node" "$cmd" 2>&1)" || true
  if [[ "$out" == *"$expected"* ]]; then
    log "ok: $node: $cmd"
  else
    fail "$node: '$cmd' output did not contain '$expected'. Output: $out"
  fi
}

wait_for() {
  local timeout="$1" node="$2" cmd="$3" expected="$4"
  local interval="${WAIT_INTERVAL:-2}" elapsed=0 out
  while true; do
    out="$(node_exec "$node" "$cmd" 2>&1)" || true
    if [[ "$out" == *"$expected"* ]]; then
      log "ok: $node: $cmd (after ${elapsed}s)"
      return 0
    fi
    if [[ "$elapsed" -ge "$timeout" ]]; then
      fail "$node: '$cmd' did not contain '$expected' within ${timeout}s. Last output: $out"
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}
```

- [ ] **Step 4: Write `scripts/verify.sh`**

```bash
#!/usr/bin/env bash
# Run a scenario's verify.sh against the deployed lab.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: scripts/verify.sh <scenario> [--variant <name>]

Runs scenarios/<scenario>/verify.sh with LAB_NAME, VARIANT and LIB_SH exported.
Environment: DOCKER (default: docker) overrides the docker binary.
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -gt 0 ]] || { usage >&2; fail "scenario name required"; }

parse_scenario_args "$@"
require_yq4
dir="$(scenario_dir "$ARG_SCENARIO")"
validate_scenario_yml "$dir" || fail "scenario.yml is invalid"
variant="$(resolve_variant "$dir" "$ARG_VARIANT")"
[[ -x "$dir/verify.sh" ]] || fail "no executable verify.sh in $dir"

topo="$(build_topology "$dir" "$variant")"
LAB_NAME="$(yq -r .name "$topo")"
export LAB_NAME VARIANT="$variant" LIB_SH="$LIB_REPO_ROOT/scripts/lib.sh"

log "verifying $ARG_SCENARIO (variant: $variant, lab: $LAB_NAME)"
cd "$dir"
exec ./verify.sh
```

- [ ] **Step 5: Confirm the template sources `LIB_SH`**

Run: `grep -n 'source "${LIB_SH' scenarios/_template/verify.sh`
Expected: one match (added in Task 3). If missing, add `source "${LIB_SH:?run this via scripts/verify.sh}"` right after `set -euo pipefail`.

- [ ] **Step 6: Run tests**

Run: `chmod +x scripts/verify.sh && scripts/test.sh`
Expected: `test_verify.sh: 10 tests, 0 failed`, `ALL PASSED`. The `wait_for` timeout test takes about 2 seconds.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib.sh scripts/verify.sh scenarios/_template/verify.sh tests/test_verify.sh
git commit -m "feat: add verify.sh runner and node check helpers"
```

---

### Task 8: `scripts/export.sh` with staleness check

**Files:**
- Create: `scripts/export.sh`
- Modify: `scripts/lib.sh` (append `export_header_sha`, `topology_last_sha`)
- Create: `tests/test_export.sh`

**Interfaces:**
- Produces in `lib.sh`:
  - `export_header_sha FILE`: echoes the short SHA from a first-line comment matching `derived from topology.clab.yml @ <sha>` (works for `#` and `<!-- -->` comments). If FILE's first line has no header, checks the first line of the sidecar `FILE.derived` (used for JSON formats such as `.gns3` that cannot carry a comment). Echoes empty string if neither has one.
  - `topology_last_sha DIR`: echoes `git log -n1 --format=%h -- DIR/topology.clab.yml` run inside the repo, or empty if uncommitted / not a git repo.
- Produces: `scripts/export.sh SCENARIO gns3|eve-ng` prints:
  - `export: none` (exit 0) when `scenario.yml` says `none`;
  - `export: <path>`, `source: hand-written` (always, until converters exist), and one of `freshness: current`, `freshness: STALE (export @ X, topology @ Y)`, `freshness: unknown (no header)`, `freshness: unknown (topology not committed)`. Exit 1 on STALE, 0 otherwise. Exit 1 if the path in `scenario.yml` does not exist.
- Header placement rule: `.unl` files carry `<!-- derived from topology.clab.yml @ <sha> -->` as their first line; `.gns3` files are JSON and carry the header as the first line of a sidecar file `<name>.gns3.derived` next to them.

- [ ] **Step 1: Write failing test**

`tests/test_export.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$REPO_ROOT/scripts/lib.sh"

EXPORT="$REPO_ROOT/scripts/export.sh"

# Fake git repo with a committed demo scenario.
setup_repo() {
  ROOT="$(make_tmpdir)"
  mkdir -p "$ROOT/scenarios"
  cp -r "$REPO_ROOT/scenarios/_template" "$ROOT/scenarios/_template"
  LIB_REPO_ROOT="$ROOT" "$REPO_ROOT/scripts/new-scenario.sh" demo >/dev/null 2>&1
  git -C "$ROOT" init -q
  git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$ROOT" add -A
  git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q -m "add demo"
  export ROOT
}
topo_sha() { git -C "$ROOT" log -n1 --format=%h -- scenarios/demo/topology.clab.yml; }
set_gns3_export() { sed -i "s|^  gns3: none|  gns3: export/gns3/demo.gns3|" "$ROOT/scenarios/demo/scenario.yml"; }
write_export() { # sha -> JSON export plus sidecar header
  printf '{"name": "demo"}\n' >"$ROOT/scenarios/demo/export/gns3/demo.gns3"
  printf '# derived from topology.clab.yml @ %s\n' "$1" >"$ROOT/scenarios/demo/export/gns3/demo.gns3.derived"
}
run_export() { LIB_REPO_ROOT="$ROOT" "$EXPORT" "$@"; }

test_export_header_sha_hash_comment() {
  local f; f="$(make_tmpdir)/x.gns3"
  printf '# derived from topology.clab.yml @ abc1234\n{}\n' >"$f"
  assert_eq abc1234 "$(export_header_sha "$f")"
}
test_export_header_sha_xml_comment() {
  local f; f="$(make_tmpdir)/x.unl"
  printf '<!-- derived from topology.clab.yml @ def5678 -->\n<lab/>\n' >"$f"
  assert_eq def5678 "$(export_header_sha "$f")"
}
test_export_header_sha_empty_without_header() {
  local f; f="$(make_tmpdir)/x.unl"
  printf '<lab/>\n' >"$f"
  assert_eq "" "$(export_header_sha "$f")"
}
test_export_header_sha_reads_sidecar_for_json() {
  local f; f="$(make_tmpdir)/x.gns3"
  printf '{"name": "x"}\n' >"$f"
  printf '# derived from topology.clab.yml @ 1234abc\n' >"$f.derived"
  assert_eq 1234abc "$(export_header_sha "$f")"
}
test_export_header_sha_prefers_file_over_sidecar() {
  local f; f="$(make_tmpdir)/x.unl"
  printf '<!-- derived from topology.clab.yml @ aaaaaaa -->\n' >"$f"
  printf '# derived from topology.clab.yml @ bbbbbbb\n' >"$f.derived"
  assert_eq aaaaaaa "$(export_header_sha "$f")"
}
test_topology_last_sha_matches_git() {
  setup_repo
  assert_eq "$(topo_sha)" "$(topology_last_sha "$ROOT/scenarios/demo")"
}
test_topology_last_sha_empty_outside_git() {
  local d; d="$(make_tmpdir)"; mkdir -p "$d/s"; touch "$d/s/topology.clab.yml"
  assert_eq "" "$(topology_last_sha "$d/s")"
}

test_export_help() { assert_contains "$("$EXPORT" --help)" "usage: scripts/export.sh <scenario> gns3|eve-ng"; }
test_export_rejects_bad_simulator() { setup_repo; assert_fails run_export demo cml; }
test_export_requires_two_args() { setup_repo; assert_fails run_export demo; }
test_export_reports_none() {
  setup_repo
  assert_contains "$(run_export demo gns3)" "export: none"
}
test_export_fails_when_path_missing() {
  setup_repo; set_gns3_export
  assert_fails run_export demo gns3
}
test_export_current() {
  setup_repo; set_gns3_export; write_export "$(topo_sha)"
  local out; out="$(run_export demo gns3)"
  assert_contains "$out" "export: export/gns3/demo.gns3"
  assert_contains "$out" "source: hand-written"
  assert_contains "$out" "freshness: current"
}
test_export_stale_exits_1() {
  setup_repo; set_gns3_export; write_export 0000000
  local out rc=0
  out="$(run_export demo gns3 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "freshness: STALE (export @ 0000000, topology @ $(topo_sha))"
}
test_export_unknown_without_header() {
  setup_repo; set_gns3_export
  printf '{}\n' >"$ROOT/scenarios/demo/export/gns3/demo.gns3"
  rm -f "$ROOT/scenarios/demo/export/gns3/demo.gns3.derived"
  assert_contains "$(run_export demo gns3)" "freshness: unknown (no header)"
}
test_export_unknown_when_topology_uncommitted() {
  setup_repo; set_gns3_export; write_export abc1234
  echo "# touched" >>"$ROOT/scenarios/demo/topology.clab.yml"
  rm -rf "$ROOT/.git"
  assert_contains "$(run_export demo gns3)" "freshness: unknown (topology not committed)"
}

run_tests
```

- [ ] **Step 2: Run to verify failure**

Run: `chmod +x tests/test_export.sh && bash tests/test_export.sh 2>&1 | tail -3`
Expected: failures.

- [ ] **Step 3: Append to `scripts/lib.sh`**

```bash
# ---- export helpers --------------------------------------------------------

# export_header_sha FILE -> short sha from a first-line "derived from topology.clab.yml @ <sha>"
# comment in FILE, else from the sidecar FILE.derived (for JSON exports), else "".
export_header_sha() {
  local file="$1" sha
  sha="$(head -n1 "$file" | sed -nE 's/.*derived from topology\.clab\.yml @ ([0-9a-f]{7,40}).*/\1/p')"
  if [[ -z "$sha" && -f "$file.derived" ]]; then
    sha="$(head -n1 "$file.derived" | sed -nE 's/.*derived from topology\.clab\.yml @ ([0-9a-f]{7,40}).*/\1/p')"
  fi
  printf '%s\n' "$sha"
}

# topology_last_sha DIR -> short sha of the last commit touching DIR/topology.clab.yml, or ""
topology_last_sha() {
  local dir="$1"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf '\n'; return 0; }
  git -C "$dir" log -n1 --format=%h -- "$dir/topology.clab.yml" 2>/dev/null || printf '\n'
}
```

- [ ] **Step 4: Write `scripts/export.sh`**

```bash
#!/usr/bin/env bash
# Report a scenario's GNS3 or EVE-NG export and whether it is stale.
# Converters do not exist yet; exports are hand-written from topology.clab.yml.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: scripts/export.sh <scenario> gns3|eve-ng

Prints the export file recorded in scenario.yml and compares the short SHA in
its header ("derived from topology.clab.yml @ <sha>") with the last commit that
changed topology.clab.yml. Exits 1 when the export is stale.
EOF
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
  echo "note: add a first line '<!-- derived from topology.clab.yml @ <short sha> -->' to .unl files,"
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
```

- [ ] **Step 5: Run tests**

Run: `chmod +x scripts/export.sh && scripts/test.sh`
Expected: `test_export.sh: 16 tests, 0 failed`, `ALL PASSED`.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib.sh scripts/export.sh tests/test_export.sh
git commit -m "feat: add export.sh reporting hand-written exports and staleness"
```

---

### Task 9: Documentation: conventions, simulator guides, image policy

**Files:**
- Create: `docs/conventions.md`
- Create: `docs/simulators/containerlab.md`
- Create: `docs/simulators/gns3.md`
- Create: `docs/simulators/eve-ng.md`
- Create: `images/README.md`
- Create: `tests/test_docs.sh`

**Interfaces:**
- Consumes: the behaviour of every script above; docs must match their usage text.

- [ ] **Step 1: Write failing test**

`tests/test_docs.sh`:
```bash
#!/usr/bin/env bash
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

run_tests
```

- [ ] **Step 2: Run to verify failure**

Run: `chmod +x tests/test_docs.sh && bash tests/test_docs.sh 2>&1 | tail -2`
Expected: failures.

- [ ] **Step 3: Write `docs/conventions.md`**

```markdown
# Conventions

## Scenario structure

Every scenario lives in `scenarios/<name>/`, created with
`scripts/new-scenario.sh <name>` from `scenarios/_template` (placeholder
`__SCENARIO_NAME__` is replaced everywhere).

| File | Purpose |
|---|---|
| `scenario.yml` | metadata read by the scripts (see below) |
| `topology.clab.yml` | the topology, single source of truth |
| `configs/<node>/` | startup configs, directory named after the clab node |
| `variants/<name>/` | optional `topology.patch.yml` and `configs/` overlays |
| `export/gns3/`, `export/eve-ng/` | derived simulator files |
| `verify.sh` | checks, run via `scripts/verify.sh` |
| `README.md` | objective, topology, tasks, verification |

### `scenario.yml` required keys

`name` (equals directory name), `title`, `topic`, `status` (`draft` or
`ready`), `default_variant`, `variants.<default_variant>`,
`simulators.containerlab`, `simulators.gns3`, `simulators.eve-ng` (a path
relative to the scenario, `native`, or `none`).

### Naming

- Scenario names: `^[a-z0-9][a-z0-9-]*$`, e.g. `ospf-single-area`.
- Node names: short, lowercase (`r1`, `sw1`, `h1`). They are the key for
  `configs/`, variant patches and export files; never rename a node in one
  place only.
- Topics: `category/subtopic`, e.g. `routing/bgp`, `switching/vlan`.

### Status

`draft` scenarios are refused by `scripts/up.sh` unless `--force`. Set
`status: ready` once `verify.sh` passes on the default variant.

## Variants

The default variant uses free images. A variant directory may hold
`topology.patch.yml` (deep-merged onto the topology by `yq`; arrays replace,
maps merge) and `configs/<node>/` replacements. Every variant must be listed
under `variants:` in `scenario.yml`. Merged topologies are written to
`.build/<variant>.clab.yml` (git-ignored).

## Exports

`export/` is derived. If an export disagrees with `topology.clab.yml`, the
topology wins. Hand-written exports record the source commit as
`derived from topology.clab.yml @ <short sha>`: `.unl` files carry it as a
first-line XML comment (`<!-- ... -->`); `.gns3` files are JSON, so it goes in
the first line of a sidecar `<name>.gns3.derived` (`# ...`). Exports use the
same node labels as the topology and list links in the same order.
`scripts/export.sh <scenario> gns3|eve-ng` reports whether an export is stale.

## Scripts

All scripts use `set -euo pipefail`, print usage on `-h`, and validate
arguments and `scenario.yml` before doing anything. Binaries are overridable
for testing: `CLAB` (containerlab), `DOCKER` (docker).

## Development tools

Runtime: `bash`, `docker`, `containerlab`, `git`, and `yq` **v4 from
mikefarah** (https://github.com/mikefarah/yq). The Python `yq` jq-wrapper is a
different program and is rejected by the scripts.

Development: `shellcheck`. Run `scripts/test.sh` before committing; CI runs
the same script.

Install on Linux without a package manager:

```bash
mkdir -p ~/.local/bin
curl -sSL -o ~/.local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && chmod +x ~/.local/bin/yq
curl -sSL https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz | tar -xJ -C /tmp && mv /tmp/shellcheck-v0.10.0/shellcheck ~/.local/bin/
```
```

- [ ] **Step 4: Write `docs/simulators/containerlab.md`**

```markdown
# Containerlab

Containerlab is the primary, scripted simulator. `topology.clab.yml` is run
directly.

## Install

Follow https://containerlab.dev/install/ (Linux with Docker). Verify with
`containerlab version`.

## Run a scenario

```bash
scripts/up.sh <scenario> [--variant <name>]     # deploy
scripts/verify.sh <scenario> [--variant <name>] # run checks
scripts/down.sh <scenario> [--variant <name>]   # destroy and clean up
```

`up.sh` merges the variant overlay into `.build/<variant>.clab.yml` and runs
`containerlab deploy --topo <file> --reconfigure` from the scenario directory,
so relative `binds:` paths resolve against the scenario.

Containers are named `clab-<lab name>-<node>`; `node_exec` in `verify.sh`
relies on that.

## Vendor images

Containerlab runs QEMU-based vendor images through vrnetlab
(https://containerlab.dev/manual/vrnetlab/). Build the image, then reference
its tag in a variant's `topology.patch.yml`. See `images/README.md`.
```

- [ ] **Step 5: Write `docs/simulators/gns3.md`**

```markdown
# GNS3

GNS3 is an export target. Until a converter exists, `export/gns3/<name>.gns3`
is written by hand from `topology.clab.yml` and recorded in `scenario.yml`
under `simulators.gns3`.

## Importing

1. In GNS3, File → Import portable project, or copy the `.gns3` file into a
   project directory on the GNS3 server.
2. Create the node templates listed below if they do not exist.
3. Attach the startup configs from `configs/<node>/` to each node.

## Node mapping

| clab kind | image (default variant) | GNS3 template |
|---|---|---|
| `linux` (FRR) | `quay.io/frrouting/frr` | Docker template, image `quay.io/frrouting/frr:<tag>`, console telnet |
| `linux` (host) | `wbitt/network-multitool` | Docker template |
| `vyos` / `linux` (VyOS) | `ghcr.io/sever-sever/vyos-container` | Docker template or VyOS QEMU appliance |
| `nokia_srlinux` | `ghcr.io/nokia/srlinux` | Docker template, privileged |
| `ceos` | `ceos:<version>` | Docker template (import image from Arista) |
| `cisco_c8000v` (vrnetlab) | vendor QEMU image | Cisco C8000v QEMU appliance |
| `juniper_vjunosswitch` | vendor QEMU image | vJunos-switch QEMU appliance |

## Hand-written export rules

- `.gns3` files are JSON and cannot carry a comment, so the header goes in a
  sidecar: `export/gns3/<name>.gns3.derived` whose first line is
  `# derived from topology.clab.yml @ <short sha>`.
- Node labels equal clab node names; links in the clab `links:` order.
- Check staleness with `scripts/export.sh <scenario> gns3`.
```

- [ ] **Step 6: Write `docs/simulators/eve-ng.md`**

```markdown
# EVE-NG / PNETLab

EVE-NG (and PNETLab, which uses the same `.unl` format) is an export target.
Until a converter exists, `export/eve-ng/<name>.unl` is written by hand from
`topology.clab.yml` and recorded in `scenario.yml` under `simulators.eve-ng`.

## Importing

1. Copy the `.unl` file into `/opt/unetlab/labs/` on the EVE-NG host (or use
   the web UI import, which accepts a zip of `.unl` files).
2. Make sure the referenced images exist under `/opt/unetlab/addons/`
   (`qemu/` for QEMU, `dynamips/`, or Docker images for `docker` nodes).
3. Load startup configs from `configs/<node>/` into each node's startup-config.

## Node mapping

| clab kind | image (default variant) | EVE-NG template |
|---|---|---|
| `linux` (FRR) | `quay.io/frrouting/frr` | `docker` node, image `frrouting/frr` |
| `linux` (host) | `wbitt/network-multitool` | `docker` node or `linux` QEMU |
| `vyos` | VyOS | `vyos` QEMU template |
| `nokia_srlinux` | `ghcr.io/nokia/srlinux` | `docker` node (privileged) |
| `ceos` | `ceos:<version>` | `docker` node |
| `cisco_c8000v` | vendor QEMU image | `c8000v` QEMU template |
| `juniper_vjunosswitch` | vendor QEMU image | `vjunosswitch` QEMU template |

## Hand-written export rules

- First line after the XML declaration: `<!-- derived from topology.clab.yml @ <short sha> -->`.
- Node `name` attributes equal clab node names; networks/links in the clab
  `links:` order.
- Check staleness with `scripts/export.sh <scenario> eve-ng`.
```

- [ ] **Step 7: Write `images/README.md`**

```markdown
# Images

This repository never contains network OS images. It records which image a
scenario expects and where to get it.

## Free images (default variants)

| Role | Image | Source |
|---|---|---|
| Router (FRR) | `quay.io/frrouting/frr:<tag>` | https://quay.io/repository/frrouting/frr |
| Router (VyOS) | `ghcr.io/sever-sever/vyos-container` or VyOS rolling | https://vyos.net |
| Switch/router (Nokia SR Linux) | `ghcr.io/nokia/srlinux:<tag>` | https://learn.srlinux.dev |
| Switch (Arista cEOS) | `ceos:<version>` | free download with an Arista account; `docker import` |
| Linux host | `wbitt/network-multitool` or `alpine` | Docker Hub |

## Vendor images (optional variants)

Vendor images are licensed. You supply them. Build QEMU-based images for
Containerlab with vrnetlab (https://github.com/srl-labs/vrnetlab) and tag them
as the variant's `topology.patch.yml` expects, e.g.
`vrnetlab/cisco_c8000v:17.12`. For GNS3 and EVE-NG, install the vendor QEMU
image using that simulator's own procedure; the mapping tables in
`docs/simulators/` give the template names.

A variant's `notes:` field in `scenario.yml` should say which image build the
scenario was tested with.
```

- [ ] **Step 8: Run tests**

Run: `scripts/test.sh`
Expected: `test_docs.sh: 4 tests, 0 failed`, `ALL PASSED`.

- [ ] **Step 9: Commit**

```bash
git add docs/conventions.md docs/simulators images/README.md tests/test_docs.sh
git commit -m "docs: add conventions, simulator guides and image policy"
```

---

### Task 10: CI workflow, README, push and draft PR

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `README.md`
- Modify: `tests/test_docs.sh` (add README test)

- [ ] **Step 1: Add README test** (append to `tests/test_docs.sh` above `run_tests`)

```bash
test_readme_has_quick_start() {
  local r; r="$(cat "$REPO_ROOT/README.md")"
  assert_contains "$r" "scripts/new-scenario.sh"
  assert_contains "$r" "scripts/up.sh"
  assert_contains "$r" "scripts/verify.sh"
  assert_contains "$r" "scripts/down.sh"
  assert_contains "$r" "scripts/export.sh"
  assert_contains "$r" "docs/conventions.md"
}
```

Run: `bash tests/test_docs.sh 2>&1 | tail -2`
Expected: `FAIL test_readme_has_quick_start`.

- [ ] **Step 2: Write `README.md`**

```markdown
# network-labs

Reproducible network engineering scenarios for testing designs and automation,
runnable on several free simulators from one source of truth.

- **Containerlab** runs each scenario's `topology.clab.yml` directly.
- **GNS3** and **EVE-NG / PNETLab** use derived export files (hand-written for
  now; converters planned).
- Default variants use free images (FRR, VyOS, SR Linux, cEOS). Vendor images
  are optional variants you supply.

## Quick start

```bash
scripts/new-scenario.sh my-lab          # scaffold scenarios/my-lab from the template
$EDITOR scenarios/my-lab/scenario.yml   # metadata; set status: ready when done
$EDITOR scenarios/my-lab/topology.clab.yml
scripts/up.sh my-lab                    # containerlab deploy
scripts/verify.sh my-lab                # run the scenario's checks
scripts/down.sh my-lab                  # destroy
scripts/export.sh my-lab gns3           # report GNS3 export status
```

Requirements: `bash`, `docker`, `containerlab`, `git`, mikefarah `yq` v4.
See `docs/conventions.md` for layout, naming and the variant/export rules, and
`docs/simulators/` for per-simulator guides.

## Layout

```
scenarios/<name>/   scenario.yml, topology.clab.yml, configs/, variants/, export/, verify.sh
scenarios/_template feel free to copy by hand, but scripts/new-scenario.sh does it for you
scripts/            up.sh, down.sh, verify.sh, export.sh, new-scenario.sh, lib.sh, test.sh
docs/               conventions, simulator guides, design specs
images/             image policy
```

## Development

```bash
scripts/test.sh     # shellcheck + all tests (no Docker needed)
```
```

- [ ] **Step 3: Write `.github/workflows/ci.yml`**

```yaml
name: ci
on:
  push:
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Tool versions
        run: |
          yq --version
          shellcheck --version
      - name: Run scaffolding tests
        run: scripts/test.sh
```

- [ ] **Step 4: Run the full suite**

Run: `scripts/test.sh`
Expected: shellcheck clean, every `test_*.sh` reports `0 failed`, `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add README.md .github/workflows/ci.yml tests/test_docs.sh
git commit -m "ci: run scaffolding tests on push; add README"
```

- [ ] **Step 6: Push and open a draft PR**

```bash
git push -u origin ccr-00157a22-qiys9w
```
Then create a draft pull request against the repository's default branch (the remote is empty, so this branch may become the default; if `main` does not exist, create the PR after pushing `main` or ask the user which base to use). Title: `Repository skeleton for multi-simulator network labs`. Body: summary of the layout, scripts, tests, and a link to the spec. Subscribe to PR activity.

- [ ] **Step 7: Verify CI**

Check the Actions run for the PR. Expected: `ci / test` green. If `yq` on the runner is not mikefarah v4 (it is on `ubuntu-latest`, but if it ever changes), add a step before the tests: `sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq`.

---

## Self-review notes

- Spec coverage: layout (T1, T3, T9, T10), scenario contract and validation (T2, T3), variants via yq overlay (T5), scripts with validation and `-h` (T4, T6, T7, T8), node helpers (T7), image policy and kind mapping tables (T9), hand-written export header and staleness (T8, T9), tests for shellcheck / validation / new-scenario / staleness / argument validation (T1–T8), CI without Docker (T10), `.gitignore` for `.build/` (T1).
- Names used consistently: `LIB_REPO_ROOT`, `scenario_dir`, `meta`, `validate_scenario_yml`, `resolve_variant`, `build_topology`, `parse_scenario_args` (`ARG_SCENARIO`, `ARG_VARIANT`, `ARG_FORCE`), `node_exec`, `expect_contains`, `wait_for`, `export_header_sha`, `topology_last_sha`, env `CLAB`, `DOCKER`, `LAB_NAME`, `VARIANT`, `LIB_SH`, `WAIT_INTERVAL`.
- Test counts in "Expected" lines are the number of `test_*` functions in each file at that point; if a count differs by one because a test was added or merged, trust `0 failed` and `ALL PASSED`.
