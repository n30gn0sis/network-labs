#!/usr/bin/env bash
# Shared functions for network-labs scripts and scenario verify.sh files.
# Source this file; do not execute it.

LIB_REPO_ROOT="${LIB_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export LIB_REPO_ROOT

# Make failures inside $(...) abort like they do at top level (bash >= 4.4).
shopt -s inherit_errexit

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
    if [[ "$(V="$dv" yq -r '.variants[strenv(V)] // "null"' "$file" 2>/dev/null || echo null)" == "null" ]]; then
      log "scenario.yml: default_variant '$dv' is not defined under variants"
      problems=$((problems + 1))
    fi
  fi
  [[ "$problems" -eq 0 ]]
}

# valid_variant_name NAME -> 0 if NAME is a safe variant identifier
valid_variant_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }

# resolve_variant DIR [VARIANT] -> VARIANT if defined, else default_variant
resolve_variant() {
  local dir="$1" variant="${2:-}"
  if [[ -z "$variant" ]]; then
    variant="$(meta "$dir" .default_variant)"
    valid_variant_name "$variant" || fail "invalid default_variant: $variant"
  fi
  valid_variant_name "$variant" || fail "invalid variant name: $variant"
  [[ "$(V="$variant" yq -r '.variants[strenv(V)] // "null"' "$dir/scenario.yml" 2>/dev/null || echo null)" != "null" ]] \
    || fail "variant '$variant' is not defined in $dir/scenario.yml"
  printf '%s\n' "$variant"
}

# build_topology DIR VARIANT -> writes DIR/.VARIANT.build.clab.yml and echoes the path.
# The file sits beside topology.clab.yml so containerlab resolves relative paths identically.
# Deep-merges variants/VARIANT/topology.patch.yml onto topology.clab.yml when present.
build_topology() {
  local dir="$1" variant="$2"
  local base="$dir/topology.clab.yml" patch="$dir/variants/$variant/topology.patch.yml"
  local out="$dir/.$variant.build.clab.yml"
  [[ -f "$base" ]] || fail "topology missing: $base"
  local tmp
  tmp="$(mktemp "$dir/.$variant.build.XXXXXX")" || fail "cannot create temp file in $dir"
  if [[ -f "$patch" ]]; then
    # shellcheck disable=SC2016  # $item is yq syntax, not shell
    yq eval-all '. as $item ireduce ({}; . * $item)' "$base" "$patch" >"$tmp" \
      || { rm -f "$tmp"; fail "cannot merge $patch onto $base"; }
  else
    cp "$base" "$tmp" || { rm -f "$tmp"; fail "cannot copy $base"; }
  fi
  mv "$tmp" "$out" || { rm -f "$tmp"; fail "cannot write $out"; }
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
  if [[ -n "$ARG_VARIANT" ]]; then
    valid_variant_name "$ARG_VARIANT" || fail "invalid variant name: $ARG_VARIANT"
  fi
}

# ---- node helpers for scenario verify.sh files ---------------------------
# Require LAB_NAME (set by scripts/verify.sh from the topology's `name`).
# DOCKER (default: docker) overrides the docker binary, e.g. for tests.

node_exec() {
  local node="$1" cmd="$2"
  [[ -n "${LAB_NAME:-}" ]] || fail "LAB_NAME is not set; run via scripts/verify.sh"
  "${DOCKER:-docker}" exec "clab-${LAB_NAME}-${node}" sh -c "$cmd"
}

# node_mgmt_ip NODE -> IPv4 address of clab-<lab>-NODE on the containerlab management network
node_mgmt_ip() {
  local node="$1" ip
  [[ -n "${LAB_NAME:-}" ]] || fail "LAB_NAME is not set; run via scripts/verify.sh"
  ip="$("${DOCKER:-docker}" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "clab-${LAB_NAME}-${node}")" || true
  [[ -n "$ip" ]] || fail "could not determine management IP of clab-${LAB_NAME}-${node}"
  printf '%s\n' "$ip"
}

# asa_exec NODE CMD -> runs CMD on an ASA over SSH to its management address.
# Env: ASA_USER (admin), ASA_PASS (Admin@123), SSH (ssh), SSHPASS (sshpass).
asa_exec() {
  local node="$1" cmd="$2" ip
  local sshpass_bin="${SSHPASS:-sshpass}" ssh_bin="${SSH:-ssh}"
  command -v "$sshpass_bin" >/dev/null 2>&1 \
    || fail "'$sshpass_bin' not found; ASA checks need sshpass (install: apt install sshpass / brew install hudochenkov/sshpass/sshpass)"
  command -v "$ssh_bin" >/dev/null 2>&1 || fail "'$ssh_bin' not found; ASA checks need an ssh client"
  ip="$(node_mgmt_ip "$node")"
  "$sshpass_bin" -p "${ASA_PASS:-Admin@123}" "$ssh_bin" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o LogLevel=ERROR \
    "${ASA_USER:-admin}@${ip}" "$cmd"
}

# _run_on_node NODE CMD -> runs CMD on NODE. Nodes listed in $ASA_NODES (space-separated,
# exported by a scenario's verify.sh) are reached over SSH via asa_exec; others via docker exec.
_run_on_node() {
  local node="$1" cmd="$2" n
  for n in ${ASA_NODES:-}; do
    if [[ "$n" == "$node" ]]; then
      asa_exec "$node" "$cmd"
      return
    fi
  done
  node_exec "$node" "$cmd"
}

expect_contains() {
  local node="$1" cmd="$2" expected="$3" out
  out="$(_run_on_node "$node" "$cmd" 2>&1)" || true
  if [[ "$out" == *"$expected"* ]]; then
    log "ok: $node: $cmd"
  else
    fail "$node: '$cmd' output did not contain '$expected'. Output: $out"
  fi
}

expect_not_contains() {
  local node="$1" cmd="$2" unexpected="$3" out
  out="$(_run_on_node "$node" "$cmd" 2>&1)" || true
  if [[ "$out" == *"$unexpected"* ]]; then
    fail "$node: '$cmd' output unexpectedly contained '$unexpected'. Output: $out"
  else
    log "ok: $node: $cmd (no '$unexpected')"
  fi
}

wait_for() {
  local timeout="$1" node="$2" cmd="$3" expected="$4"
  local interval="${WAIT_INTERVAL:-2}" elapsed=0 out
  while true; do
    out="$(_run_on_node "$node" "$cmd" 2>&1)" || true
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

# ---- export helpers --------------------------------------------------------

# export_header_sha FILE -> short sha from a "derived from topology.clab.yml @ <sha>" comment
# within the first two lines of FILE, else from the sidecar FILE.derived (for JSON exports), else "".
export_header_sha() {
  local file="$1" sha
  sha="$(head -n2 "$file" | sed -nE 's/.*derived from topology\.clab\.yml @ ([0-9a-f]{7,40}).*/\1/p')"
  if [[ -z "$sha" && -f "$file.derived" ]]; then
    sha="$(head -n2 "$file.derived" | sed -nE 's/.*derived from topology\.clab\.yml @ ([0-9a-f]{7,40}).*/\1/p')"
  fi
  printf '%s\n' "$sha"
}

# topology_last_sha DIR -> short sha of the last commit touching DIR/topology.clab.yml, or ""
topology_last_sha() {
  local dir="$1"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf '\n'; return 0; }
  git -C "$dir" log -n1 --format=%h -- "$dir/topology.clab.yml" 2>/dev/null || printf '\n'
}
