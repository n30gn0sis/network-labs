#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=scripts/lib.sh
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
test_require_tools_fails_for_missing_tool() {
  assert_fails bash -c 'source "'"$REPO_ROOT"'/scripts/lib.sh"; require_tools definitely-not-a-tool-xyz'
}
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

run_tests
