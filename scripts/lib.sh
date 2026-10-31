#!/usr/bin/env bash
# Shared functions for network-labs scripts and scenario verify.sh files.
# Source this file; do not execute it.

LIB_REPO_ROOT="${LIB_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export LIB_REPO_ROOT

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

# build_topology DIR VARIANT -> writes DIR/.build/VARIANT.clab.yml and echoes the path.
# Deep-merges variants/VARIANT/topology.patch.yml onto topology.clab.yml when present.
build_topology() {
  local dir="$1" variant="$2"
  local base="$dir/topology.clab.yml" patch="$dir/variants/$variant/topology.patch.yml"
  local out="$dir/.build/$variant.clab.yml"
  [[ -f "$base" ]] || fail "topology missing: $base"
  mkdir -p "$dir/.build"
  local tmp
  tmp="$(mktemp "$dir/.build/.$variant.XXXXXX")"
  if [[ -f "$patch" ]]; then
    # shellcheck disable=SC2016  # $item is yq syntax, not shell
    yq eval-all '. as $item ireduce ({}; . * $item)' "$base" "$patch" >"$tmp" \
      || { rm -f "$tmp"; fail "cannot merge $patch onto $base"; }
  else
    cp "$base" "$tmp" || { rm -f "$tmp"; fail "cannot copy $base"; }
  fi
  mv "$tmp" "$out"
  printf '%s\n' "$out"
}

# parse_scenario_args ARGS... -> sets ARG_SCENARIO, ARG_VARIANT, ARG_FORCE (0/1).
# Accepts: <scenario> [--variant X] [--force]. Calls fail on anything else.
# shellcheck disable=SC2034  # ARG_* globals are consumed by the calling scripts
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
