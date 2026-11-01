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

# Stubs: docker answers `inspect` with a fixed IP; sshpass records argv and answers show commands.
make_asa_stubs() {
  local root="$1"
  mkdir -p "$root/bin"
  cat >"$root/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/docker.log"
case "\$*" in
  inspect*) echo "172.20.20.11" ;;
  *"ping"*) echo "5 packets transmitted, 5 received, 0% packet loss" ;;
  *) echo "unknown" ;;
esac
STUB
  cat >"$root/bin/sshpass" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/ssh.log"
case "\$*" in
  *"show version"*) echo "Cisco Adaptive Security Appliance Software Version 9.18(4)" ;;
  *"show crypto ikev2 sa"*) echo "Tunnel-id Local Remote"; echo "1 203.0.113.1/500 203.0.113.2/500 READY"; echo "2 203.0.113.1/500 203.0.113.3/500 READY" ;;
  *"pkts encaps"*) echo "      #pkts encaps: 42, #pkts encrypt: 42" ;;
  *) echo "unknown" ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho "ssh-should-not-run" >&2; exit 99\n' >"$root/bin/ssh"
  chmod +x "$root/bin/docker" "$root/bin/sshpass" "$root/bin/ssh"
}

test_node_mgmt_ip_reads_docker_inspect() {
  local root; root="$(make_tmpdir)"; make_asa_stubs "$root"
  assert_eq 172.20.20.11 "$(DOCKER="$root/bin/docker" LAB_NAME=demo node_mgmt_ip asa-hub)"
  assert_contains "$(cat "$root/docker.log")" "inspect -f {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}} clab-demo-asa-hub"
}
test_node_mgmt_ip_fails_when_empty() {
  local root; root="$(make_tmpdir)"; mkdir -p "$root/bin"
  printf '#!/usr/bin/env bash\necho ""\n' >"$root/bin/docker"; chmod +x "$root/bin/docker"
  assert_fails env DOCKER="$root/bin/docker" LAB_NAME=demo bash -c 'source "'"$REPO_ROOT"'/scripts/lib.sh"; node_mgmt_ip asa-hub'
}
test_asa_exec_builds_sshpass_command() {
  local root out; root="$(make_tmpdir)"; make_asa_stubs "$root"
  out="$(DOCKER="$root/bin/docker" SSHPASS_BIN="$root/bin/sshpass" SSH="$root/bin/ssh" LAB_NAME=demo asa_exec asa-hub "show version")"
  assert_contains "$out" "Cisco Adaptive Security Appliance"
  local logged; logged="$(cat "$root/ssh.log")"
  assert_contains "$logged" "-p CiscoAsa1! $root/bin/ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR admin@172.20.20.11 show version"
}
test_asa_exec_fails_when_mgmt_ip_unknown() {
  local root out rc=0; root="$(make_tmpdir)"; mkdir -p "$root/bin"
  printf '#!/usr/bin/env bash\ntrue\n' >"$root/bin/docker"; chmod +x "$root/bin/docker"
  printf '#!/usr/bin/env bash\necho "sshpass-should-not-run" >&2; exit 99\n' >"$root/bin/sshpass"; chmod +x "$root/bin/sshpass"
  printf '#!/usr/bin/env bash\nexit 99\n' >"$root/bin/ssh"; chmod +x "$root/bin/ssh"
  out="$(DOCKER="$root/bin/docker" SSHPASS_BIN="$root/bin/sshpass" SSH="$root/bin/ssh" LAB_NAME=demo ASA_NODES="asa-hub" \
    bash -c 'source "'"$REPO_ROOT"'/scripts/lib.sh"; expect_not_contains asa-hub "show x" "zzz"' 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "could not determine management IP"
}
test_asa_exec_honours_user_and_pass_overrides() {
  local root; root="$(make_tmpdir)"; make_asa_stubs "$root"
  DOCKER="$root/bin/docker" SSHPASS_BIN="$root/bin/sshpass" SSH="$root/bin/ssh" LAB_NAME=demo ASA_USER=ops ASA_PASS=s3cret asa_exec asa-hub "show version" >/dev/null
  assert_contains "$(cat "$root/ssh.log")" "-p s3cret $root/bin/ssh"
  assert_contains "$(cat "$root/ssh.log")" "ops@172.20.20.11"
}
test_asa_exec_fails_with_hint_when_sshpass_missing() {
  local root out rc=0; root="$(make_tmpdir)"; make_asa_stubs "$root"
  out="$(DOCKER="$root/bin/docker" SSHPASS_BIN="$root/bin/nonexistent" SSH="$root/bin/ssh" LAB_NAME=demo bash -c 'source "'"$REPO_ROOT"'/scripts/lib.sh"; asa_exec asa-hub "show version"' 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "sshpass"
  assert_contains "$out" "install"
}
test_run_on_node_routes_asa_nodes_over_ssh() {
  local root out; root="$(make_tmpdir)"; make_asa_stubs "$root"
  export DOCKER="$root/bin/docker" SSHPASS_BIN="$root/bin/sshpass" SSH="$root/bin/ssh" LAB_NAME=demo ASA_NODES="asa-hub asa-spoke1"
  out="$(_run_on_node asa-hub "show version")"
  assert_contains "$out" "Cisco Adaptive Security Appliance"
  assert_contains "$(cat "$root/ssh.log")" "admin@172.20.20.11 show version"
  out="$(_run_on_node h1 "ping -c 5 10.1.0.1")"
  assert_contains "$out" "5 received"
  assert_contains "$(cat "$root/docker.log")" "exec clab-demo-h1 sh -c ping -c 5 10.1.0.1"
  assert_not_contains "$(cat "$root/docker.log")" "exec clab-demo-asa-hub"
}
test_expect_contains_uses_asa_route() {
  local root; root="$(make_tmpdir)"; make_asa_stubs "$root"
  DOCKER="$root/bin/docker" SSHPASS_BIN="$root/bin/sshpass" SSH="$root/bin/ssh" LAB_NAME=demo ASA_NODES="asa-hub" \
    assert_succeeds expect_contains asa-hub "show crypto ikev2 sa" "203.0.113.3"
  DOCKER="$root/bin/docker" SSHPASS_BIN="$root/bin/sshpass" SSH="$root/bin/ssh" LAB_NAME=demo ASA_NODES="asa-hub" \
    assert_succeeds expect_not_contains asa-hub "show crypto ipsec sa peer 203.0.113.2 | include pkts encaps" "#pkts encaps: 0"
}

run_tests
