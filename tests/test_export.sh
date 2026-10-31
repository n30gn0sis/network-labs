#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=scripts/lib.sh
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
