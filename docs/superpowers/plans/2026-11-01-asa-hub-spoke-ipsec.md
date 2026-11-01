# ASA Hub-and-Spoke IPsec Scenario Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `scenarios/asa-hub-spoke-ipsec`: three ASAv firewalls in hub-and-spoke with one Linux host per site, in three variants (VTI/IKEv2 default, crypto-map/IKEv2, crypto-map/IKEv1), with Docker-free tests, SSH-based ASA verification helpers in `scripts/lib.sh`, and docs.

**Architecture:** The scenario follows the repository contract (`scenario.yml`, `topology.clab.yml` as single source of truth, `configs/<node>/`, `variants/<name>/topology.patch.yml` + `configs/`, `verify.sh`). Variants swap only the ASAs' `startup-config:` paths. `scripts/lib.sh` gains `node_mgmt_ip`, `asa_exec` (SSH via `sshpass`), `expect_not_contains`, and a `_run_on_node` dispatcher so `expect_contains`/`wait_for` reach nodes listed in `ASA_NODES` over SSH and everything else over `docker exec`. Tests stub `docker`, `ssh` and `sshpass` through environment variables exactly as the existing tests stub `CLAB`/`DOCKER`.

**Tech Stack:** bash 5, mikefarah `yq` v4, `shellcheck` (dev), containerlab + vrnetlab ASAv (runtime, never in tests), `ssh` + `sshpass` (runtime, optional).

Spec: `docs/superpowers/specs/2026-11-01-asa-hub-spoke-ipsec-design.md`

## Global Constraints

- Every script: `#!/usr/bin/env bash`, `set -euo pipefail`; `lib.sh` is sourced, never executed, and already sets `shopt -s inherit_errexit`.
- `yq` is mikefarah yq v4. Dev tooling lives in `~/.local/bin`; start every Bash call with `export PATH="$HOME/.local/bin:$PATH"`.
- Tests never need Docker, containerlab, ssh or sshpass: inject stubs via `DOCKER`, `SSH`, `SSHPASS_BIN`, `CLAB`.
- Scenario name `asa-hub-spoke-ipsec`, topic `security/ipsec`, `status: draft` (stays draft until a real containerlab run; see spec "Real-world validation").
- Node names: `asa-hub`, `asa-spoke1`, `asa-spoke2`, `h1`, `h2`, `h3`, `wan`. ASA kind `cisco_asav`, image `vrnetlab/cisco_asav:9.18.4` (tag is a placeholder the user retags to match their build; recorded in `scenario.yml` `images:` and `notes:`). Hosts and `wan`: kind `linux`, image `wbitt/network-multitool:latest`.
- Addressing: WAN `203.0.113.0/24` (hub .1, spoke1 .2, spoke2 .3); inside `10.1.0.0/24` (hub), `10.2.0.0/24` (spoke1), `10.3.0.0/24` (spoke2); ASA inside `.1`, host `.10`; VTI `169.254.1.0/30` (hub .1, spoke1 .2), `169.254.2.0/30` (hub .1, spoke2 .2).
- ASAv interface mapping in containerlab: `eth1` = `GigabitEthernet0/0` (outside), `eth2` = `GigabitEthernet0/1` (inside). Links use `ethN` names.
- Crypto: IKEv2 `aes-gcm-256`, `prf sha384`, `group 19`, lifetime 86400; IPsec proposal `GCM` = `esp aes-gcm-256` / integrity null. IKEv1 `aes-256` / `sha` / `group 14` / pre-share / 86400; transform-set `AES256-SHA esp-aes-256 esp-sha-hmac`.
- Pre-shared keys: `LAB-PSK-SPOKE1` (hub↔spoke1), `LAB-PSK-SPOKE2` (hub↔spoke2).
- ASA access defaults: `ASA_USER=admin`, `ASA_PASS=CiscoAsa1!`, `SSH=ssh`, `SSHPASS_BIN=sshpass`, `ASA_SSH_TIMEOUT=30`, all overridable from the environment.
- `ASA_NODES` is a space-separated list of node names exported by a scenario's `verify.sh`; `_run_on_node` uses it to route commands.
- Variant names: `vti-ikev2` (default, configs in `configs/`), `cryptomap-ikev2`, `cryptomap-ikev1` (under `variants/`). Startup configs are named `startup.cfg` under `<...>/configs/<node>/`.
- Startup configs are ASA configuration-mode command lists applied by vrnetlab after its bootstrap (hostname, management interface, `admin` user, SSH on management). They must not touch `Management0/0`, the `admin` user, or SSH-on-management.
- Commit after every task with a conventional prefix (`feat:`, `test:`, `docs:`), ending with the attribution lines the harness provides. No model identifiers in committed content.
- Work on branch `ccr-00157a22-qiys9w` (already restarted from `main`; draft PR #2 is open and tracks this branch).

---

## File map

| Path | Responsibility |
|---|---|
| `scripts/lib.sh` | add `expect_not_contains`, `_run_on_node`, `node_mgmt_ip`, `asa_exec`; route `expect_contains`/`wait_for` through `_run_on_node` |
| `tests/test_verify.sh` | tests for the new helpers and routing |
| `scenarios/asa-hub-spoke-ipsec/scenario.yml` | metadata, three variants |
| `scenarios/asa-hub-spoke-ipsec/topology.clab.yml` | 7 nodes, 6 links, default `startup-config` paths |
| `scenarios/asa-hub-spoke-ipsec/configs/asa-{hub,spoke1,spoke2}/startup.cfg` | `vti-ikev2` configs |
| `scenarios/asa-hub-spoke-ipsec/variants/cryptomap-ikev2/{topology.patch.yml,configs/asa-*/startup.cfg}` | variant |
| `scenarios/asa-hub-spoke-ipsec/variants/cryptomap-ikev1/{topology.patch.yml,configs/asa-*/startup.cfg}` | variant |
| `scenarios/asa-hub-spoke-ipsec/verify.sh` | scenario checks |
| `scenarios/asa-hub-spoke-ipsec/README.md` | scenario documentation |
| `scenarios/asa-hub-spoke-ipsec/export/{gns3,eve-ng}/.gitkeep` | empty export dirs |
| `tests/test_asa_hub_spoke.sh` | scenario structure, config markers, end-to-end verify against stubs |
| `tests/test_docs.sh` | doc assertions for the new rows/sections |
| `images/README.md`, `docs/conventions.md`, `docs/simulators/gns3.md`, `docs/simulators/eve-ng.md` | doc updates |
| `docs/superpowers/specs/2026-11-01-asa-hub-spoke-ipsec-design.md` | amend `wan` node kind (Task 3) |

---

### Task 1: `expect_not_contains` and the `_run_on_node` dispatcher

**Files:**
- Modify: `scripts/lib.sh` (node helpers section, lines 145–180)
- Modify: `tests/test_verify.sh` (add tests before `run_tests`)

**Interfaces:**
- Consumes: `node_exec NODE CMD`, `log`, `fail` from `lib.sh`; `make_docker_stub ROOT` and the helpers in `tests/test_verify.sh`.
- Produces: `_run_on_node NODE CMD` (runs CMD on NODE; for now always via `node_exec`; Task 2 adds the SSH branch), `expect_not_contains NODE CMD UNEXPECTED`. `expect_contains` and `wait_for` now call `_run_on_node`; their signatures are unchanged.

- [ ] **Step 1: Write failing tests** (append to `tests/test_verify.sh` above `run_tests`)

```bash
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_verify.sh 2>&1 | tail -4`
Expected: the three new tests FAIL (`expect_not_contains`, `_run_on_node` not defined).

- [ ] **Step 3: Implement in `scripts/lib.sh`**

Replace the block from `expect_contains() {` through the end of `wait_for` with:

```bash
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
```

`asa_exec` does not exist yet; add a stub directly above `_run_on_node` so shellcheck and the dispatcher resolve it, to be replaced in Task 2:

```bash
# asa_exec NODE CMD -> replaced in Task 2 (SSH to the ASA's management address)
asa_exec() { fail "asa_exec not implemented"; }
```

- [ ] **Step 4: Run tests**

Run: `bash tests/test_verify.sh && scripts/test.sh`
Expected: `test_verify.sh: 13 tests, 0 failed`; full suite shellcheck clean, `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/test_verify.sh
git commit -m "feat: add expect_not_contains and route node checks through _run_on_node"
```

---

### Task 2: `node_mgmt_ip` and `asa_exec` over SSH

**Files:**
- Modify: `scripts/lib.sh` (replace the `asa_exec` stub; add `node_mgmt_ip`)
- Modify: `tests/test_verify.sh`

**Interfaces:**
- Consumes: `node_exec`, `fail`, `log`, `_run_on_node`, `LAB_NAME`, `DOCKER`.
- Produces: `node_mgmt_ip NODE` (echoes the container's management IPv4; fails if empty), `asa_exec NODE CMD` (runs `"$SSHPASS_BIN" -p "$ASA_PASS" "$SSH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR "$ASA_USER@<ip>" "CMD"`). Env: `ASA_USER` (default `admin`), `ASA_PASS` (default `CiscoAsa1!`), `SSH` (default `ssh`), `SSHPASS_BIN` (default `sshpass`).

- [ ] **Step 1: Write failing tests** (append above `run_tests`)

```bash
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
  assert_contains "$logged" "-p CiscoAsa1! $root/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR admin@172.20.20.11 show version"
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_verify.sh 2>&1 | tail -8`
Expected: the seven new tests FAIL (`node_mgmt_ip` undefined; `asa_exec` stub fails).

- [ ] **Step 3: Implement in `scripts/lib.sh`**

Replace the `asa_exec` stub with:

```bash
# node_mgmt_ip NODE -> IPv4 address of clab-<lab>-NODE on the containerlab management network
node_mgmt_ip() {
  local node="$1" ip
  [[ -n "${LAB_NAME:-}" ]] || fail "LAB_NAME is not set; run via scripts/verify.sh"
  ip="$("${DOCKER:-docker}" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "clab-${LAB_NAME}-${node}")" || true
  [[ -n "$ip" ]] || fail "could not determine management IP of clab-${LAB_NAME}-${node}"
  printf '%s\n' "$ip"
}

# asa_exec NODE CMD -> runs CMD on an ASA over SSH to its management address.
# Env: ASA_USER (admin), ASA_PASS (CiscoAsa1!), SSH (ssh), SSHPASS_BIN (sshpass).
asa_exec() {
  local node="$1" cmd="$2" ip
  local sshpass_bin="${SSHPASS_BIN:-sshpass}" ssh_bin="${SSH:-ssh}"
  command -v "$sshpass_bin" >/dev/null 2>&1 \
    || fail "'$sshpass_bin' not found; ASA checks need sshpass (install: apt install sshpass / brew install hudochenkov/sshpass/sshpass)"
  command -v "$ssh_bin" >/dev/null 2>&1 || fail "'$ssh_bin' not found; ASA checks need an ssh client"
  ip="$(node_mgmt_ip "$node")"
  "$sshpass_bin" -p "${ASA_PASS:-CiscoAsa1!}" "$ssh_bin" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o LogLevel=ERROR \
    "${ASA_USER:-admin}@${ip}" "$cmd"
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/test_verify.sh && scripts/test.sh`
Expected: `test_verify.sh: 20 tests, 0 failed`; `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/test_verify.sh
git commit -m "feat: add node_mgmt_ip and asa_exec for SSH-based ASA checks"
```

---

### Task 3: Scenario skeleton: `scenario.yml`, topology, hosts, structure tests

**Files:**
- Create: `scenarios/asa-hub-spoke-ipsec/scenario.yml`
- Create: `scenarios/asa-hub-spoke-ipsec/topology.clab.yml`
- Create: `scenarios/asa-hub-spoke-ipsec/export/gns3/.gitkeep`, `scenarios/asa-hub-spoke-ipsec/export/eve-ng/.gitkeep`
- Create: `scenarios/asa-hub-spoke-ipsec/verify.sh` (placeholder body; real checks in Task 7)
- Create: `scenarios/asa-hub-spoke-ipsec/README.md` (stub with headings; filled in Task 8)
- Create: `tests/test_asa_hub_spoke.sh`
- Modify: `docs/superpowers/specs/2026-11-01-asa-hub-spoke-ipsec-design.md` (node table: `wan` row)

**Interfaces:**
- Consumes: `validate_scenario_yml DIR`, `meta DIR PATH`, `build_topology DIR VARIANT`, `resolve_variant`.
- Produces: the scenario directory other tasks fill; test helpers `SCN` (scenario dir) and `built VARIANT` (echoes the built topology path) in `tests/test_asa_hub_spoke.sh`.

Do NOT use `scripts/new-scenario.sh` here: the template's FRR files would need deleting. Create the files directly.

- [ ] **Step 1: Write failing tests**

`tests/test_asa_hub_spoke.sh`:
```bash
#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

SCN="$REPO_ROOT/scenarios/asa-hub-spoke-ipsec"
VARIANTS="vti-ikev2 cryptomap-ikev2 cryptomap-ikev1"

# built VARIANT -> path of the built topology (written beside topology.clab.yml, git-ignored)
built() { build_topology "$SCN" "$1"; }
cleanup_built() { rm -f "$SCN"/.*.build.clab.yml; }
trap cleanup_built EXIT

test_scenario_yml_is_valid() { assert_succeeds validate_scenario_yml "$SCN"; }
test_scenario_is_draft_until_validated() { assert_eq draft "$(meta "$SCN" .status)"; }
test_scenario_default_variant_is_vti() { assert_eq vti-ikev2 "$(meta "$SCN" .default_variant)"; }
test_scenario_defines_three_variants() {
  local v
  for v in $VARIANTS; do
    assert_eq "$v" "$(resolve_variant "$SCN" "$v")"
    assert_eq "vrnetlab/cisco_asav:9.18.4" "$(V="$v" yq -r '.variants[strenv(V)].images.asa' "$SCN/scenario.yml")"
  done
}
test_scenario_has_no_exports_yet() {
  assert_eq none "$(meta "$SCN" '.simulators.gns3')"
  assert_eq none "$(meta "$SCN" '.simulators["eve-ng"]')"
  assert_file_exists "$SCN/export/gns3/.gitkeep"
  assert_file_exists "$SCN/export/eve-ng/.gitkeep"
}
test_topology_has_expected_nodes() {
  local t; t="$SCN/topology.clab.yml"
  assert_eq asa-hub-spoke-ipsec "$(yq -r .name "$t")"
  assert_eq 3 "$(yq -r '[.topology.nodes[] | select(.kind == "cisco_asav")] | length' "$t")"
  assert_eq 4 "$(yq -r '[.topology.nodes[] | select(.kind == "linux")] | length' "$t")"
  assert_eq "asa-hub asa-spoke1 asa-spoke2 h1 h2 h3 wan" "$(yq -r '.topology.nodes | keys | sort | join(" ")' "$t")"
}
test_topology_has_six_links_into_wan_and_hosts() {
  local t; t="$SCN/topology.clab.yml"
  assert_eq 6 "$(yq -r '.topology.links | length' "$t")"
  assert_eq 3 "$(yq -r '[.topology.links[].endpoints[] | select(test("^wan:"))] | length' "$t")"
  local n
  for n in h1 h2 h3; do
    assert_eq 1 "$(N="$n" yq -r '[.topology.links[].endpoints[] | select(. == strenv(N) + ":eth1")] | length' "$t")"
  done
  for n in asa-hub asa-spoke1 asa-spoke2; do
    assert_eq 1 "$(N="$n" yq -r '[.topology.links[].endpoints[] | select(. == strenv(N) + ":eth1")] | length' "$t")" "$n outside"
    assert_eq 1 "$(N="$n" yq -r '[.topology.links[].endpoints[] | select(. == strenv(N) + ":eth2")] | length' "$t")" "$n inside"
  done
}
test_hosts_get_address_and_route_to_their_asa() {
  local t; t="$SCN/topology.clab.yml"
  assert_contains "$(yq -r '.topology.nodes.h1.exec | join("\n")' "$t")" "ip addr add 10.1.0.10/24 dev eth1"
  assert_contains "$(yq -r '.topology.nodes.h1.exec | join("\n")' "$t")" "ip route add 10.0.0.0/8 via 10.1.0.1"
  assert_contains "$(yq -r '.topology.nodes.h2.exec | join("\n")' "$t")" "ip addr add 10.2.0.10/24 dev eth1"
  assert_contains "$(yq -r '.topology.nodes.h2.exec | join("\n")' "$t")" "ip route add 10.0.0.0/8 via 10.2.0.1"
  assert_contains "$(yq -r '.topology.nodes.h3.exec | join("\n")' "$t")" "ip addr add 10.3.0.10/24 dev eth1"
  assert_contains "$(yq -r '.topology.nodes.h3.exec | join("\n")' "$t")" "ip route add 10.0.0.0/8 via 10.3.0.1"
}
test_wan_node_bridges_its_three_ports() {
  local ex; ex="$(yq -r '.topology.nodes.wan.exec | join("\n")' "$SCN/topology.clab.yml")"
  assert_contains "$ex" "ip link add br0 type bridge"
  assert_contains "$ex" "ip link set eth1 master br0"
  assert_contains "$ex" "ip link set eth2 master br0"
  assert_contains "$ex" "ip link set eth3 master br0"
  assert_contains "$ex" "ip link set br0 up"
}
test_verify_is_executable_and_sources_lib() {
  [[ -x "$SCN/verify.sh" ]]
  assert_contains "$(cat "$SCN/verify.sh")" 'source "${LIB_SH:?'
  assert_contains "$(cat "$SCN/verify.sh")" 'export ASA_NODES="asa-hub asa-spoke1 asa-spoke2"'
}

run_tests
```

- [ ] **Step 2: Run to verify failure**

Run: `chmod +x tests/test_asa_hub_spoke.sh && bash tests/test_asa_hub_spoke.sh 2>&1 | tail -3`
Expected: every test FAILS (scenario directory missing).

- [ ] **Step 3: Create `scenario.yml`**

```yaml
# ASA hub-and-spoke IPsec. Topology in topology.clab.yml; variants swap ASA configs only.
name: asa-hub-spoke-ipsec
title: ASA hub-and-spoke site-to-site IPsec (VTI and crypto-map variants)
topic: security/ipsec
status: draft                     # flip to ready after a real containerlab run per variant (see README)
default_variant: vti-ikev2
variants:
  vti-ikev2:
    images:
      asa: vrnetlab/cisco_asav:9.18.4
    notes: route-based VTI over IKEv2; requires ASA 9.8+. Configs in configs/.
  cryptomap-ikev2:
    images:
      asa: vrnetlab/cisco_asav:9.18.4
    notes: policy-based crypto maps over IKEv2; any ASA 9.x.
  cryptomap-ikev1:
    images:
      asa: vrnetlab/cisco_asav:9.18.4
    notes: policy-based crypto maps over IKEv1; any ASA 9.x.
simulators:
  containerlab: native
  gns3: none
  eve-ng: none
```

- [ ] **Step 4: Create `topology.clab.yml`**

```yaml
# Single source of truth. Node names are the key for configs/, variants/ and export/.
# ASAv interface mapping in containerlab: eth1 = GigabitEthernet0/0 (outside), eth2 = GigabitEthernet0/1 (inside).
# The wan node is a Linux container bridging its three ports: a flat stand-in for the internet.
name: asa-hub-spoke-ipsec

topology:
  defaults:
    env:
      CLAB_MGMT_VRF: ""
  nodes:
    asa-hub:
      kind: cisco_asav
      image: vrnetlab/cisco_asav:9.18.4
      startup-config: configs/asa-hub/startup.cfg
    asa-spoke1:
      kind: cisco_asav
      image: vrnetlab/cisco_asav:9.18.4
      startup-config: configs/asa-spoke1/startup.cfg
    asa-spoke2:
      kind: cisco_asav
      image: vrnetlab/cisco_asav:9.18.4
      startup-config: configs/asa-spoke2/startup.cfg
    h1:
      kind: linux
      image: wbitt/network-multitool:latest
      exec:
        - ip addr add 10.1.0.10/24 dev eth1
        - ip route add 10.0.0.0/8 via 10.1.0.1
    h2:
      kind: linux
      image: wbitt/network-multitool:latest
      exec:
        - ip addr add 10.2.0.10/24 dev eth1
        - ip route add 10.0.0.0/8 via 10.2.0.1
    h3:
      kind: linux
      image: wbitt/network-multitool:latest
      exec:
        - ip addr add 10.3.0.10/24 dev eth1
        - ip route add 10.0.0.0/8 via 10.3.0.1
    wan:
      kind: linux
      image: wbitt/network-multitool:latest
      exec:
        - ip link add br0 type bridge
        - ip link set eth1 master br0
        - ip link set eth2 master br0
        - ip link set eth3 master br0
        - ip link set br0 up
  links:
    - endpoints: ["asa-hub:eth1", "wan:eth1"]
    - endpoints: ["asa-spoke1:eth1", "wan:eth2"]
    - endpoints: ["asa-spoke2:eth1", "wan:eth3"]
    - endpoints: ["asa-hub:eth2", "h1:eth1"]
    - endpoints: ["asa-spoke1:eth2", "h2:eth1"]
    - endpoints: ["asa-spoke2:eth2", "h3:eth1"]
```

Remove the `defaults:` block if `yq` or a later test complains about it; it is optional and only there to keep the file explicit. (If removed, nothing else changes.)

- [ ] **Step 5: Create `verify.sh` placeholder, README stub, export dirs**

`scenarios/asa-hub-spoke-ipsec/verify.sh` (Task 7 replaces the body):
```bash
#!/usr/bin/env bash
# Verification for asa-hub-spoke-ipsec. Run via: scripts/verify.sh asa-hub-spoke-ipsec [--variant X]
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib.sh
source "${LIB_SH:?run this via scripts/verify.sh}"

export ASA_NODES="asa-hub asa-spoke1 asa-spoke2"

fail "verify.sh not implemented yet"
```

`scenarios/asa-hub-spoke-ipsec/README.md` stub:
```markdown
# asa-hub-spoke-ipsec

## Objective

## Topology

## Variants

## Tasks

## Verification

## Simulators

## Teardown
```

```bash
mkdir -p scenarios/asa-hub-spoke-ipsec/export/gns3 scenarios/asa-hub-spoke-ipsec/export/eve-ng
touch scenarios/asa-hub-spoke-ipsec/export/gns3/.gitkeep scenarios/asa-hub-spoke-ipsec/export/eve-ng/.gitkeep
chmod +x scenarios/asa-hub-spoke-ipsec/verify.sh
```

- [ ] **Step 6: Amend the spec's node table**

In `docs/superpowers/specs/2026-11-01-asa-hub-spoke-ipsec-design.md`, replace the row
`| \`wan\` | \`bridge\` | — | flat stand-in for the internet |` with
`| \`wan\` | \`linux\` | \`wbitt/network-multitool\` | Linux container bridging its three ports (br0); flat stand-in for the internet. A containerlab \`bridge\` kind would need a pre-created host bridge. |`
and in "Scenario tests" change "one `bridge` node" to "one `linux` node named `wan`".

- [ ] **Step 7: Run tests**

Run: `bash tests/test_asa_hub_spoke.sh && scripts/test.sh`
Expected: `test_asa_hub_spoke.sh: 10 tests, 0 failed`; `ALL PASSED`.

- [ ] **Step 8: Commit**

```bash
git add scenarios/asa-hub-spoke-ipsec tests/test_asa_hub_spoke.sh docs/superpowers/specs/2026-11-01-asa-hub-spoke-ipsec-design.md
git commit -m "feat: scaffold asa-hub-spoke-ipsec scenario (metadata, topology, hosts)"
```

---

### Task 4: `vti-ikev2` ASA configs (default variant)

**Files:**
- Create: `scenarios/asa-hub-spoke-ipsec/configs/asa-hub/startup.cfg`
- Create: `scenarios/asa-hub-spoke-ipsec/configs/asa-spoke1/startup.cfg`
- Create: `scenarios/asa-hub-spoke-ipsec/configs/asa-spoke2/startup.cfg`
- Modify: `tests/test_asa_hub_spoke.sh`

**Interfaces:**
- Consumes: `built VARIANT`, `SCN` from Task 3.
- Produces: the three default startup configs; test helpers `cfg_of VARIANT NODE` (echoes the startup-config path from the built topology, resolved relative to the scenario dir).

- [ ] **Step 1: Write failing tests** (insert above `run_tests`)

```bash
# cfg_of VARIANT NODE -> absolute path of NODE's startup-config in the built topology
cfg_of() {
  local topo rel; topo="$(built "$1")"
  rel="$(N="$2" yq -r '.topology.nodes[strenv(N)]["startup-config"]' "$topo")"
  printf '%s/%s\n' "$(dirname "$topo")" "$rel"
}
assert_common_base() { # file hostname inside_ip
  local c; c="$(cat "$1")"
  assert_contains "$c" "hostname $2"
  assert_contains "$c" "interface GigabitEthernet0/0"
  assert_contains "$c" " nameif outside"
  assert_contains "$c" " security-level 0"
  assert_contains "$c" "interface GigabitEthernet0/1"
  assert_contains "$c" " nameif inside"
  assert_contains "$c" " security-level 100"
  assert_contains "$c" " ip address $3 255.255.255.0"
  assert_contains "$c" "inspect icmp"
  assert_not_contains "$c" "Management0/0"
  assert_not_contains "$c" "username admin"
}

test_vti_startup_configs_exist_for_all_asas() {
  local n
  for n in asa-hub asa-spoke1 asa-spoke2; do assert_file_exists "$(cfg_of vti-ikev2 "$n")"; done
}
test_vti_configs_share_base() {
  assert_common_base "$(cfg_of vti-ikev2 asa-hub)" asa-hub 10.1.0.1
  assert_common_base "$(cfg_of vti-ikev2 asa-spoke1)" asa-spoke1 10.2.0.1
  assert_common_base "$(cfg_of vti-ikev2 asa-spoke2)" asa-spoke2 10.3.0.1
}
test_vti_hub_has_two_tunnels_and_routes() {
  local c; c="$(cat "$(cfg_of vti-ikev2 asa-hub)")"
  assert_contains "$c" "crypto ikev2 enable outside"
  assert_contains "$c" "crypto ipsec profile VTI-PROFILE"
  assert_contains "$c" "interface Tunnel1"
  assert_contains "$c" "interface Tunnel2"
  assert_contains "$c" " tunnel destination 203.0.113.2"
  assert_contains "$c" " tunnel destination 203.0.113.3"
  assert_contains "$c" " tunnel protection ipsec profile VTI-PROFILE"
  assert_contains "$c" "route vti-spoke1 10.2.0.0 255.255.255.0 169.254.1.2"
  assert_contains "$c" "route vti-spoke2 10.3.0.0 255.255.255.0 169.254.2.2"
  assert_contains "$c" "same-security-traffic permit inter-interface"
  assert_contains "$c" "same-security-traffic permit intra-interface"
  assert_not_contains "$c" "crypto map"
}
test_vti_spokes_tunnel_to_hub() {
  local c
  c="$(cat "$(cfg_of vti-ikev2 asa-spoke1)")"
  assert_contains "$c" " tunnel destination 203.0.113.1"
  assert_contains "$c" " ip address 169.254.1.2 255.255.255.252"
  assert_contains "$c" "route vti-hub 10.0.0.0 255.0.0.0 169.254.1.1"
  c="$(cat "$(cfg_of vti-ikev2 asa-spoke2)")"
  assert_contains "$c" " tunnel destination 203.0.113.1"
  assert_contains "$c" " ip address 169.254.2.2 255.255.255.252"
  assert_contains "$c" "route vti-hub 10.0.0.0 255.0.0.0 169.254.2.1"
}
test_vti_psks_match_per_pair() {
  local hub s1 s2
  hub="$(cat "$(cfg_of vti-ikev2 asa-hub)")"; s1="$(cat "$(cfg_of vti-ikev2 asa-spoke1)")"; s2="$(cat "$(cfg_of vti-ikev2 asa-spoke2)")"
  assert_contains "$hub" "tunnel-group 203.0.113.2 ipsec-attributes"
  assert_contains "$hub" "tunnel-group 203.0.113.3 ipsec-attributes"
  assert_contains "$hub" "pre-shared-key LAB-PSK-SPOKE1"
  assert_contains "$hub" "pre-shared-key LAB-PSK-SPOKE2"
  assert_contains "$s1" "tunnel-group 203.0.113.1 ipsec-attributes"
  assert_contains "$s1" "pre-shared-key LAB-PSK-SPOKE1"
  assert_not_contains "$s1" "LAB-PSK-SPOKE2"
  assert_contains "$s2" "pre-shared-key LAB-PSK-SPOKE2"
  assert_not_contains "$s2" "LAB-PSK-SPOKE1"
  assert_not_contains "$hub$s1$s2" "pre-shared-key $"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_asa_hub_spoke.sh 2>&1 | tail -6`
Expected: the five new tests FAIL (config files missing).

- [ ] **Step 3: Write `configs/asa-hub/startup.cfg`**

```
! asa-hub: VTI over IKEv2 (default variant). Applied by vrnetlab after its bootstrap.
! Do not configure Management0/0, the admin user, or SSH here.
hostname asa-hub
same-security-traffic permit inter-interface
same-security-traffic permit intra-interface
!
interface GigabitEthernet0/0
 nameif outside
 security-level 0
 ip address 203.0.113.1 255.255.255.0
 no shutdown
interface GigabitEthernet0/1
 nameif inside
 security-level 100
 ip address 10.1.0.1 255.255.255.0
 no shutdown
!
object network NET-HUB
 subnet 10.1.0.0 255.255.255.0
object network NET-SPOKE1
 subnet 10.2.0.0 255.255.255.0
object network NET-SPOKE2
 subnet 10.3.0.0 255.255.255.0
nat (inside,outside) source static NET-HUB NET-HUB destination static NET-SPOKE1 NET-SPOKE1 no-proxy-arp route-lookup
nat (inside,outside) source static NET-HUB NET-HUB destination static NET-SPOKE2 NET-SPOKE2 no-proxy-arp route-lookup
!
class-map inspection_default
 match default-inspection-traffic
policy-map global_policy
 class inspection_default
  inspect icmp
service-policy global_policy global
!
crypto ikev2 policy 10
 encryption aes-gcm-256
 integrity null
 group 19
 prf sha384
 lifetime seconds 86400
crypto ikev2 enable outside
crypto ipsec ikev2 ipsec-proposal GCM
 protocol esp encryption aes-gcm-256
 protocol esp integrity null
crypto ipsec profile VTI-PROFILE
 set ikev2 ipsec-proposal GCM
!
tunnel-group 203.0.113.2 type ipsec-l2l
tunnel-group 203.0.113.2 ipsec-attributes
 ikev2 remote-authentication pre-shared-key LAB-PSK-SPOKE1
 ikev2 local-authentication pre-shared-key LAB-PSK-SPOKE1
tunnel-group 203.0.113.3 type ipsec-l2l
tunnel-group 203.0.113.3 ipsec-attributes
 ikev2 remote-authentication pre-shared-key LAB-PSK-SPOKE2
 ikev2 local-authentication pre-shared-key LAB-PSK-SPOKE2
!
interface Tunnel1
 nameif vti-spoke1
 ip address 169.254.1.1 255.255.255.252
 tunnel source interface outside
 tunnel destination 203.0.113.2
 tunnel mode ipsec ipv4
 tunnel protection ipsec profile VTI-PROFILE
 no shutdown
interface Tunnel2
 nameif vti-spoke2
 ip address 169.254.2.1 255.255.255.252
 tunnel source interface outside
 tunnel destination 203.0.113.3
 tunnel mode ipsec ipv4
 tunnel protection ipsec profile VTI-PROFILE
 no shutdown
!
route vti-spoke1 10.2.0.0 255.255.255.0 169.254.1.2 1
route vti-spoke2 10.3.0.0 255.255.255.0 169.254.2.2 1
```

- [ ] **Step 4: Write `configs/asa-spoke1/startup.cfg`**

```
! asa-spoke1: VTI over IKEv2 (default variant). Applied by vrnetlab after its bootstrap.
! Do not configure Management0/0, the admin user, or SSH here.
hostname asa-spoke1
!
interface GigabitEthernet0/0
 nameif outside
 security-level 0
 ip address 203.0.113.2 255.255.255.0
 no shutdown
interface GigabitEthernet0/1
 nameif inside
 security-level 100
 ip address 10.2.0.1 255.255.255.0
 no shutdown
!
object network NET-SPOKE1
 subnet 10.2.0.0 255.255.255.0
object network NET-REMOTE
 subnet 10.0.0.0 255.0.0.0
nat (inside,outside) source static NET-SPOKE1 NET-SPOKE1 destination static NET-REMOTE NET-REMOTE no-proxy-arp route-lookup
!
class-map inspection_default
 match default-inspection-traffic
policy-map global_policy
 class inspection_default
  inspect icmp
service-policy global_policy global
!
crypto ikev2 policy 10
 encryption aes-gcm-256
 integrity null
 group 19
 prf sha384
 lifetime seconds 86400
crypto ikev2 enable outside
crypto ipsec ikev2 ipsec-proposal GCM
 protocol esp encryption aes-gcm-256
 protocol esp integrity null
crypto ipsec profile VTI-PROFILE
 set ikev2 ipsec-proposal GCM
!
tunnel-group 203.0.113.1 type ipsec-l2l
tunnel-group 203.0.113.1 ipsec-attributes
 ikev2 remote-authentication pre-shared-key LAB-PSK-SPOKE1
 ikev2 local-authentication pre-shared-key LAB-PSK-SPOKE1
!
interface Tunnel1
 nameif vti-hub
 ip address 169.254.1.2 255.255.255.252
 tunnel source interface outside
 tunnel destination 203.0.113.1
 tunnel mode ipsec ipv4
 tunnel protection ipsec profile VTI-PROFILE
 no shutdown
!
route vti-hub 10.0.0.0 255.0.0.0 169.254.1.1 1
```

- [ ] **Step 5: Write `configs/asa-spoke2/startup.cfg`**

Identical to spoke1 with these substitutions: `hostname asa-spoke2`; outside `203.0.113.3`; inside `10.3.0.1`; `object network NET-SPOKE2` / `subnet 10.3.0.0 255.255.255.0` and the NAT line referencing `NET-SPOKE2`; PSK `LAB-PSK-SPOKE2` (both lines); Tunnel1 `ip address 169.254.2.2 255.255.255.252`; `route vti-hub 10.0.0.0 255.0.0.0 169.254.2.1 1`. The header comment says `asa-spoke2`.

- [ ] **Step 6: Run tests**

Run: `bash tests/test_asa_hub_spoke.sh && scripts/test.sh`
Expected: `test_asa_hub_spoke.sh: 15 tests, 0 failed`; `ALL PASSED`.

- [ ] **Step 7: Commit**

```bash
git add scenarios/asa-hub-spoke-ipsec/configs tests/test_asa_hub_spoke.sh
git commit -m "feat: add vti-ikev2 ASA configs for asa-hub-spoke-ipsec"
```

---

### Task 5: `cryptomap-ikev2` variant

**Files:**
- Create: `scenarios/asa-hub-spoke-ipsec/variants/cryptomap-ikev2/topology.patch.yml`
- Create: `scenarios/asa-hub-spoke-ipsec/variants/cryptomap-ikev2/configs/asa-{hub,spoke1,spoke2}/startup.cfg`
- Modify: `tests/test_asa_hub_spoke.sh`

**Interfaces:**
- Consumes: `cfg_of`, `assert_common_base`, `built` from Tasks 3–4.
- Produces: helper `assert_cryptomap_structure VARIANT IKE` used again by Task 6.

- [ ] **Step 1: Write failing tests** (insert above `run_tests`)

```bash
# assert_cryptomap_structure VARIANT IKE(ikev1|ikev2): ACLs, crypto map, routes, hairpin entries
assert_cryptomap_structure() {
  local v="$1" ike="$2" hub s1 s2
  hub="$(cat "$(cfg_of "$v" asa-hub)")"; s1="$(cat "$(cfg_of "$v" asa-spoke1)")"; s2="$(cat "$(cfg_of "$v" asa-spoke2)")"
  assert_common_base "$(cfg_of "$v" asa-hub)" asa-hub 10.1.0.1
  assert_common_base "$(cfg_of "$v" asa-spoke1)" asa-spoke1 10.2.0.1
  assert_common_base "$(cfg_of "$v" asa-spoke2)" asa-spoke2 10.3.0.1
  # hub ACLs incl. spoke-to-spoke hairpin entries
  assert_contains "$hub" "access-list L2L-SPOKE1 extended permit ip 10.1.0.0 255.255.255.0 10.2.0.0 255.255.255.0"
  assert_contains "$hub" "access-list L2L-SPOKE1 extended permit ip 10.3.0.0 255.255.255.0 10.2.0.0 255.255.255.0"
  assert_contains "$hub" "access-list L2L-SPOKE2 extended permit ip 10.1.0.0 255.255.255.0 10.3.0.0 255.255.255.0"
  assert_contains "$hub" "access-list L2L-SPOKE2 extended permit ip 10.2.0.0 255.255.255.0 10.3.0.0 255.255.255.0"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 10 match address L2L-SPOKE1"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 10 set peer 203.0.113.2"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 20 match address L2L-SPOKE2"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 20 set peer 203.0.113.3"
  assert_contains "$hub" "crypto map OUTSIDE_MAP interface outside"
  assert_contains "$hub" "route outside 10.2.0.0 255.255.255.0 203.0.113.2"
  assert_contains "$hub" "route outside 10.3.0.0 255.255.255.0 203.0.113.3"
  assert_contains "$hub" "crypto $ike enable outside"
  assert_contains "$hub" "same-security-traffic permit intra-interface"
  assert_not_contains "$hub" "interface Tunnel"
  # spokes
  assert_contains "$s1" "access-list L2L-HUB extended permit ip 10.2.0.0 255.255.255.0 10.0.0.0 255.0.0.0"
  assert_contains "$s1" "crypto map OUTSIDE_MAP 10 set peer 203.0.113.1"
  assert_contains "$s1" "route outside 10.0.0.0 255.0.0.0 203.0.113.1"
  assert_contains "$s1" "crypto $ike enable outside"
  assert_contains "$s2" "access-list L2L-HUB extended permit ip 10.3.0.0 255.255.255.0 10.0.0.0 255.0.0.0"
  assert_contains "$s2" "crypto map OUTSIDE_MAP 10 set peer 203.0.113.1"
  assert_contains "$s2" "route outside 10.0.0.0 255.0.0.0 203.0.113.1"
  # psks
  assert_contains "$hub" "LAB-PSK-SPOKE1"; assert_contains "$hub" "LAB-PSK-SPOKE2"
  assert_contains "$s1" "LAB-PSK-SPOKE1"; assert_not_contains "$s1" "LAB-PSK-SPOKE2"
  assert_contains "$s2" "LAB-PSK-SPOKE2"; assert_not_contains "$s2" "LAB-PSK-SPOKE1"
}
test_cryptomap_ikev2_patch_only_repoints_startup_configs() {
  local p; p="$SCN/variants/cryptomap-ikev2/topology.patch.yml"
  assert_file_exists "$p"
  assert_eq "asa-hub asa-spoke1 asa-spoke2" "$(yq -r '.topology.nodes | keys | sort | join(" ")' "$p")"
  assert_eq "startup-config" "$(yq -r '[.topology.nodes[] | keys[]] | unique | join(" ")' "$p")"
  assert_eq "variants/cryptomap-ikev2/configs/asa-hub/startup.cfg" "$(yq -r '.topology.nodes["asa-hub"]["startup-config"]' "$p")"
}
test_cryptomap_ikev2_built_topology_keeps_images_and_hosts() {
  local t; t="$(built cryptomap-ikev2)"
  assert_eq "vrnetlab/cisco_asav:9.18.4" "$(yq -r '.topology.nodes["asa-hub"].image' "$t")"
  assert_eq 7 "$(yq -r '.topology.nodes | length' "$t")"
  assert_eq 6 "$(yq -r '.topology.links | length' "$t")"
}
test_cryptomap_ikev2_configs() {
  assert_cryptomap_structure cryptomap-ikev2 ikev2
  local hub; hub="$(cat "$(cfg_of cryptomap-ikev2 asa-hub)")"
  assert_contains "$hub" "crypto ipsec ikev2 ipsec-proposal GCM"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 10 set ikev2 ipsec-proposal GCM"
  assert_contains "$hub" "ikev2 remote-authentication pre-shared-key LAB-PSK-SPOKE1"
  assert_not_contains "$hub" "ikev1"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_asa_hub_spoke.sh 2>&1 | tail -5`
Expected: the three new tests FAIL.

- [ ] **Step 3: Write `variants/cryptomap-ikev2/topology.patch.yml`**

```yaml
# Only the ASA startup configs change; images, hosts and links come from topology.clab.yml.
topology:
  nodes:
    asa-hub:
      startup-config: variants/cryptomap-ikev2/configs/asa-hub/startup.cfg
    asa-spoke1:
      startup-config: variants/cryptomap-ikev2/configs/asa-spoke1/startup.cfg
    asa-spoke2:
      startup-config: variants/cryptomap-ikev2/configs/asa-spoke2/startup.cfg
```

- [ ] **Step 4: Write `variants/cryptomap-ikev2/configs/asa-hub/startup.cfg`**

```
! asa-hub: policy-based crypto maps over IKEv2. Applied by vrnetlab after its bootstrap.
! Do not configure Management0/0, the admin user, or SSH here.
hostname asa-hub
same-security-traffic permit inter-interface
same-security-traffic permit intra-interface
!
interface GigabitEthernet0/0
 nameif outside
 security-level 0
 ip address 203.0.113.1 255.255.255.0
 no shutdown
interface GigabitEthernet0/1
 nameif inside
 security-level 100
 ip address 10.1.0.1 255.255.255.0
 no shutdown
!
object network NET-HUB
 subnet 10.1.0.0 255.255.255.0
object network NET-SPOKE1
 subnet 10.2.0.0 255.255.255.0
object network NET-SPOKE2
 subnet 10.3.0.0 255.255.255.0
nat (inside,outside) source static NET-HUB NET-HUB destination static NET-SPOKE1 NET-SPOKE1 no-proxy-arp route-lookup
nat (inside,outside) source static NET-HUB NET-HUB destination static NET-SPOKE2 NET-SPOKE2 no-proxy-arp route-lookup
!
class-map inspection_default
 match default-inspection-traffic
policy-map global_policy
 class inspection_default
  inspect icmp
service-policy global_policy global
!
! Crypto ACLs. The cross entries (10.3->10.2 and 10.2->10.3) make spoke-to-spoke traffic
! hairpin through the hub; without them spoke1<->spoke2 silently fails.
access-list L2L-SPOKE1 extended permit ip 10.1.0.0 255.255.255.0 10.2.0.0 255.255.255.0
access-list L2L-SPOKE1 extended permit ip 10.3.0.0 255.255.255.0 10.2.0.0 255.255.255.0
access-list L2L-SPOKE2 extended permit ip 10.1.0.0 255.255.255.0 10.3.0.0 255.255.255.0
access-list L2L-SPOKE2 extended permit ip 10.2.0.0 255.255.255.0 10.3.0.0 255.255.255.0
!
crypto ikev2 policy 10
 encryption aes-gcm-256
 integrity null
 group 19
 prf sha384
 lifetime seconds 86400
crypto ikev2 enable outside
crypto ipsec ikev2 ipsec-proposal GCM
 protocol esp encryption aes-gcm-256
 protocol esp integrity null
!
crypto map OUTSIDE_MAP 10 match address L2L-SPOKE1
crypto map OUTSIDE_MAP 10 set peer 203.0.113.2
crypto map OUTSIDE_MAP 10 set ikev2 ipsec-proposal GCM
crypto map OUTSIDE_MAP 20 match address L2L-SPOKE2
crypto map OUTSIDE_MAP 20 set peer 203.0.113.3
crypto map OUTSIDE_MAP 20 set ikev2 ipsec-proposal GCM
crypto map OUTSIDE_MAP interface outside
!
tunnel-group 203.0.113.2 type ipsec-l2l
tunnel-group 203.0.113.2 ipsec-attributes
 ikev2 remote-authentication pre-shared-key LAB-PSK-SPOKE1
 ikev2 local-authentication pre-shared-key LAB-PSK-SPOKE1
tunnel-group 203.0.113.3 type ipsec-l2l
tunnel-group 203.0.113.3 ipsec-attributes
 ikev2 remote-authentication pre-shared-key LAB-PSK-SPOKE2
 ikev2 local-authentication pre-shared-key LAB-PSK-SPOKE2
!
route outside 10.2.0.0 255.255.255.0 203.0.113.2 1
route outside 10.3.0.0 255.255.255.0 203.0.113.3 1
```

- [ ] **Step 5: Write `variants/cryptomap-ikev2/configs/asa-spoke1/startup.cfg`**

```
! asa-spoke1: policy-based crypto map over IKEv2. Applied by vrnetlab after its bootstrap.
! Do not configure Management0/0, the admin user, or SSH here.
hostname asa-spoke1
!
interface GigabitEthernet0/0
 nameif outside
 security-level 0
 ip address 203.0.113.2 255.255.255.0
 no shutdown
interface GigabitEthernet0/1
 nameif inside
 security-level 100
 ip address 10.2.0.1 255.255.255.0
 no shutdown
!
object network NET-SPOKE1
 subnet 10.2.0.0 255.255.255.0
object network NET-REMOTE
 subnet 10.0.0.0 255.0.0.0
nat (inside,outside) source static NET-SPOKE1 NET-SPOKE1 destination static NET-REMOTE NET-REMOTE no-proxy-arp route-lookup
!
class-map inspection_default
 match default-inspection-traffic
policy-map global_policy
 class inspection_default
  inspect icmp
service-policy global_policy global
!
access-list L2L-HUB extended permit ip 10.2.0.0 255.255.255.0 10.0.0.0 255.0.0.0
!
crypto ikev2 policy 10
 encryption aes-gcm-256
 integrity null
 group 19
 prf sha384
 lifetime seconds 86400
crypto ikev2 enable outside
crypto ipsec ikev2 ipsec-proposal GCM
 protocol esp encryption aes-gcm-256
 protocol esp integrity null
!
crypto map OUTSIDE_MAP 10 match address L2L-HUB
crypto map OUTSIDE_MAP 10 set peer 203.0.113.1
crypto map OUTSIDE_MAP 10 set ikev2 ipsec-proposal GCM
crypto map OUTSIDE_MAP interface outside
!
tunnel-group 203.0.113.1 type ipsec-l2l
tunnel-group 203.0.113.1 ipsec-attributes
 ikev2 remote-authentication pre-shared-key LAB-PSK-SPOKE1
 ikev2 local-authentication pre-shared-key LAB-PSK-SPOKE1
!
route outside 10.0.0.0 255.0.0.0 203.0.113.1 1
```

- [ ] **Step 6: Write `variants/cryptomap-ikev2/configs/asa-spoke2/startup.cfg`**

Same as spoke1 with: `hostname asa-spoke2`; outside `203.0.113.3`; inside `10.3.0.1`; `object network NET-SPOKE2` / `subnet 10.3.0.0 255.255.255.0` and NAT referencing `NET-SPOKE2`; `access-list L2L-HUB extended permit ip 10.3.0.0 255.255.255.0 10.0.0.0 255.0.0.0`; PSK `LAB-PSK-SPOKE2` (both lines); header comment `asa-spoke2`.

- [ ] **Step 7: Run tests**

Run: `bash tests/test_asa_hub_spoke.sh && scripts/test.sh`
Expected: `test_asa_hub_spoke.sh: 18 tests, 0 failed`; `ALL PASSED`.

- [ ] **Step 8: Commit**

```bash
git add scenarios/asa-hub-spoke-ipsec/variants/cryptomap-ikev2 tests/test_asa_hub_spoke.sh
git commit -m "feat: add cryptomap-ikev2 variant for asa-hub-spoke-ipsec"
```

---

### Task 6: `cryptomap-ikev1` variant

**Files:**
- Create: `scenarios/asa-hub-spoke-ipsec/variants/cryptomap-ikev1/topology.patch.yml`
- Create: `scenarios/asa-hub-spoke-ipsec/variants/cryptomap-ikev1/configs/asa-{hub,spoke1,spoke2}/startup.cfg`
- Modify: `tests/test_asa_hub_spoke.sh`

**Interfaces:**
- Consumes: `assert_cryptomap_structure`, `cfg_of`, `built`.

- [ ] **Step 1: Write failing tests** (insert above `run_tests`)

```bash
test_cryptomap_ikev1_patch_only_repoints_startup_configs() {
  local p; p="$SCN/variants/cryptomap-ikev1/topology.patch.yml"
  assert_file_exists "$p"
  assert_eq "startup-config" "$(yq -r '[.topology.nodes[] | keys[]] | unique | join(" ")' "$p")"
  assert_eq "variants/cryptomap-ikev1/configs/asa-spoke2/startup.cfg" "$(yq -r '.topology.nodes["asa-spoke2"]["startup-config"]' "$p")"
}
test_cryptomap_ikev1_configs() {
  assert_cryptomap_structure cryptomap-ikev1 ikev1
  local hub s1; hub="$(cat "$(cfg_of cryptomap-ikev1 asa-hub)")"; s1="$(cat "$(cfg_of cryptomap-ikev1 asa-spoke1)")"
  assert_contains "$hub" "crypto ikev1 policy 10"
  assert_contains "$hub" " authentication pre-share"
  assert_contains "$hub" " encryption aes-256"
  assert_contains "$hub" " hash sha"
  assert_contains "$hub" " group 14"
  assert_contains "$hub" "crypto ipsec ikev1 transform-set AES256-SHA esp-aes-256 esp-sha-hmac"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 10 set ikev1 transform-set AES256-SHA"
  assert_contains "$hub" "crypto map OUTSIDE_MAP 20 set ikev1 transform-set AES256-SHA"
  assert_contains "$hub" " ikev1 pre-shared-key LAB-PSK-SPOKE1"
  assert_contains "$s1" " ikev1 pre-shared-key LAB-PSK-SPOKE1"
  assert_not_contains "$hub" "ikev2"
  assert_not_contains "$s1" "ikev2"
}
test_cryptomap_variants_differ_only_in_ike_version() {
  # Strip IKE-specific lines; what remains must be identical between the two crypto-map variants.
  local n a b
  for n in asa-hub asa-spoke1 asa-spoke2; do
    a="$(grep -vE 'ikev[12]|transform-set|ipsec-proposal|GCM|integrity|prf |encryption|hash sha|group 1[49]|lifetime|authentication pre-share|^!' "$(cfg_of cryptomap-ikev2 "$n")")"
    b="$(grep -vE 'ikev[12]|transform-set|ipsec-proposal|GCM|integrity|prf |encryption|hash sha|group 1[49]|lifetime|authentication pre-share|^!' "$(cfg_of cryptomap-ikev1 "$n")")"
    assert_eq "$a" "$b" "$n non-IKE lines"
  done
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_asa_hub_spoke.sh 2>&1 | tail -4`
Expected: the three new tests FAIL.

- [ ] **Step 3: Write `variants/cryptomap-ikev1/topology.patch.yml`**

```yaml
# Only the ASA startup configs change; images, hosts and links come from topology.clab.yml.
topology:
  nodes:
    asa-hub:
      startup-config: variants/cryptomap-ikev1/configs/asa-hub/startup.cfg
    asa-spoke1:
      startup-config: variants/cryptomap-ikev1/configs/asa-spoke1/startup.cfg
    asa-spoke2:
      startup-config: variants/cryptomap-ikev1/configs/asa-spoke2/startup.cfg
```

- [ ] **Step 4: Write the three IKEv1 configs**

Copy each `variants/cryptomap-ikev2/configs/<node>/startup.cfg` to `variants/cryptomap-ikev1/configs/<node>/startup.cfg`, then in each file make exactly these replacements (and nothing else, so Step 1's "differ only in IKE version" test holds):

1. Header comment: `over IKEv2` → `over IKEv1`.
2. Replace the block
   ```
   crypto ikev2 policy 10
    encryption aes-gcm-256
    integrity null
    group 19
    prf sha384
    lifetime seconds 86400
   crypto ikev2 enable outside
   crypto ipsec ikev2 ipsec-proposal GCM
    protocol esp encryption aes-gcm-256
    protocol esp integrity null
   ```
   with
   ```
   crypto ikev1 policy 10
    authentication pre-share
    encryption aes-256
    hash sha
    group 14
    lifetime 86400
   crypto ikev1 enable outside
   crypto ipsec ikev1 transform-set AES256-SHA esp-aes-256 esp-sha-hmac
   ```
3. Every `crypto map OUTSIDE_MAP N set ikev2 ipsec-proposal GCM` → `crypto map OUTSIDE_MAP N set ikev1 transform-set AES256-SHA`.
4. Every pair
   ```
    ikev2 remote-authentication pre-shared-key <PSK>
    ikev2 local-authentication pre-shared-key <PSK>
   ```
   → the single line ` ikev1 pre-shared-key <PSK>`.

- [ ] **Step 5: Run tests**

Run: `bash tests/test_asa_hub_spoke.sh && scripts/test.sh`
Expected: `test_asa_hub_spoke.sh: 21 tests, 0 failed`; `ALL PASSED`. If `test_cryptomap_variants_differ_only_in_ike_version` fails, diff the two files (`diff <(grep -vE ... a) <(grep -vE ... b)`) and remove the stray difference; do not loosen the filter.

- [ ] **Step 6: Commit**

```bash
git add scenarios/asa-hub-spoke-ipsec/variants/cryptomap-ikev1 tests/test_asa_hub_spoke.sh
git commit -m "feat: add cryptomap-ikev1 variant for asa-hub-spoke-ipsec"
```

---

### Task 7: Scenario `verify.sh` and end-to-end test against stubs

**Files:**
- Modify: `scenarios/asa-hub-spoke-ipsec/verify.sh` (replace body)
- Modify: `tests/test_asa_hub_spoke.sh`

**Interfaces:**
- Consumes: `expect_contains`, `expect_not_contains`, `wait_for`, `node_exec`, `log`, `ASA_NODES`, `VARIANT`, `LAB_NAME`, `LIB_SH` (exported by `scripts/verify.sh`); `asa_exec` routing via `_run_on_node`.
- Produces: the scenario's verification; tests run the real `scripts/verify.sh` against stubbed `docker`, `sshpass`, `ssh`.

- [ ] **Step 1: Write failing tests** (insert above `run_tests`)

```bash
# Stubs that model a healthy lab: hosts answer pings, ASAs answer show commands.
# IKE=ikev1|ikev2 selects which `show crypto ... sa` returns peers; BROKEN=1 makes spoke2 unreachable.
make_lab_stubs() {
  local root="$1" ike="$2" broken="${3:-0}"
  mkdir -p "$root/bin"
  cat >"$root/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/docker.log"
case "\$*" in
  inspect*asa-hub) echo "172.20.20.11" ;;
  inspect*asa-spoke1) echo "172.20.20.12" ;;
  inspect*asa-spoke2) echo "172.20.20.13" ;;
  *"ping"*"10.3.0.10"*) if [[ "$broken" == 1 ]]; then echo "5 packets transmitted, 0 received, 100% packet loss"; else echo "5 packets transmitted, 5 received, 0% packet loss"; fi ;;
  *"ping -c 2"*) echo "2 packets transmitted, 2 received, 0% packet loss" ;;
  *"ping -c 3"*) echo "3 packets transmitted, 3 received, 0% packet loss" ;;
  *"ping -c 5"*) echo "5 packets transmitted, 5 received, 0% packet loss" ;;
  *) echo "unknown" ;;
esac
STUB
  cat >"$root/bin/sshpass" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/ssh.log"
case "\$*" in
  *"show version"*) echo "Cisco Adaptive Security Appliance Software Version 9.18(4)" ;;
  *"show crypto $ike sa"*) echo "Peer 203.0.113.2 READY"; echo "Peer 203.0.113.3 READY" ;;
  *"show crypto ikev"*) echo "There are no IKE SAs" ;;
  *"pkts encaps"*) echo "      #pkts encaps: 17, #pkts encrypt: 17" ;;
  *"show interface Tunnel"*) echo "Interface Tunnel1 \"vti-spoke1\", is up, line protocol is up" ;;
  *) echo "unknown" ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho "ssh must be invoked via sshpass stub" >&2; exit 99\n' >"$root/bin/ssh"
  chmod +x "$root/bin/docker" "$root/bin/sshpass" "$root/bin/ssh"
}
run_verify() { # root variant
  LIB_REPO_ROOT="$REPO_ROOT" DOCKER="$1/bin/docker" SSHPASS_BIN="$1/bin/sshpass" SSH="$1/bin/ssh" WAIT_INTERVAL=1 \
    "$REPO_ROOT/scripts/verify.sh" asa-hub-spoke-ipsec --variant "$2"
}
test_verify_passes_for_vti_against_healthy_stubs() {
  local root out; root="$(make_tmpdir)"; make_lab_stubs "$root" ikev2
  out="$(run_verify "$root" vti-ikev2 2>&1)"
  assert_contains "$out" "all checks passed"
  local ssh; ssh="$(cat "$root/ssh.log")"
  assert_contains "$ssh" "admin@172.20.20.11 show crypto ikev2 sa"
  assert_contains "$ssh" "show crypto ipsec sa peer 203.0.113.2 | include pkts encaps"
  assert_contains "$ssh" "show crypto ipsec sa peer 203.0.113.3 | include pkts encaps"
  assert_contains "$ssh" "show interface Tunnel1 | include line protocol"
  assert_contains "$ssh" "show interface Tunnel2 | include line protocol"
  local dk; dk="$(cat "$root/docker.log")"
  assert_contains "$dk" "exec clab-asa-hub-spoke-ipsec-h2 sh -c ping -c 5 -W 2 10.3.0.10"
  assert_not_contains "$dk" "exec clab-asa-hub-spoke-ipsec-asa-hub"
}
test_verify_uses_ikev1_show_for_ikev1_variant() {
  local root out; root="$(make_tmpdir)"; make_lab_stubs "$root" ikev1
  out="$(run_verify "$root" cryptomap-ikev1 2>&1)"
  assert_contains "$out" "all checks passed"
  assert_contains "$(cat "$root/ssh.log")" "show crypto ikev1 sa"
  assert_not_contains "$(cat "$root/ssh.log")" "show interface Tunnel"
}
test_verify_cryptomap_ikev2_skips_tunnel_interface_checks() {
  local root out; root="$(make_tmpdir)"; make_lab_stubs "$root" ikev2
  out="$(run_verify "$root" cryptomap-ikev2 2>&1)"
  assert_contains "$out" "all checks passed"
  assert_not_contains "$(cat "$root/ssh.log")" "show interface Tunnel"
}
test_verify_fails_when_spoke_to_spoke_ping_fails() {
  local root out rc=0; root="$(make_tmpdir)"; make_lab_stubs "$root" ikev2 1
  out="$(run_verify "$root" vti-ikev2 2>&1)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "error: h2: 'ping -c 5 -W 2 10.3.0.10'"
}
test_verify_fails_when_ike_sa_missing() {
  local root out rc=0; root="$(make_tmpdir)"; make_lab_stubs "$root" ikev1   # stub answers ikev1 only
  out="$(run_verify "$root" vti-ikev2 2>&1)" || rc=$?                     # variant asks for ikev2
  assert_eq 1 "$rc"
  assert_contains "$out" "show crypto ikev2 sa' did not contain '203.0.113.2'"
}
```

Note on timing: `wait_for 120 ...` in verify.sh with `WAIT_INTERVAL=1` makes the missing-SA test take about 120 s. To keep the suite fast, verify.sh reads the SA timeout from `ASA_SA_TIMEOUT` (default 120) and the boot timeout from `ASA_BOOT_TIMEOUT` (default 300); `run_verify` sets both to 2:

```bash
run_verify() { # root variant
  LIB_REPO_ROOT="$REPO_ROOT" DOCKER="$1/bin/docker" SSHPASS_BIN="$1/bin/sshpass" SSH="$1/bin/ssh" \
    WAIT_INTERVAL=1 ASA_BOOT_TIMEOUT=2 ASA_SA_TIMEOUT=2 \
    "$REPO_ROOT/scripts/verify.sh" asa-hub-spoke-ipsec --variant "$2"
}
```
Use this version of `run_verify`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_asa_hub_spoke.sh 2>&1 | tail -6`
Expected: the five new tests FAIL (`verify.sh not implemented yet`).

- [ ] **Step 3: Write `scenarios/asa-hub-spoke-ipsec/verify.sh`**

```bash
#!/usr/bin/env bash
# Verification for asa-hub-spoke-ipsec. Run via: scripts/verify.sh asa-hub-spoke-ipsec [--variant X]
# scripts/verify.sh exports LAB_NAME, VARIANT and LIB_SH before calling this.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib.sh
source "${LIB_SH:?run this via scripts/verify.sh}"

# ASA nodes are reached over SSH (asa_exec); hosts via docker exec.
export ASA_NODES="asa-hub asa-spoke1 asa-spoke2"

boot_timeout="${ASA_BOOT_TIMEOUT:-600}"   # ASAv takes 5-7 minutes to boot
sa_timeout="${ASA_SA_TIMEOUT:-120}"
ike=ikev2
[[ "$VARIANT" == "cryptomap-ikev1" ]] && ike=ikev1

log "== 1. ASAs booted and reachable over SSH"
for asa in asa-hub asa-spoke1 asa-spoke2; do
  wait_for "$boot_timeout" "$asa" "show version | include Software" "Cisco Adaptive Security Appliance"
done

log "== 2. Hosts reach their own ASA"
expect_contains h1 "ping -c 2 -W 2 10.1.0.1" "2 received"
expect_contains h2 "ping -c 2 -W 2 10.2.0.1" "2 received"
expect_contains h3 "ping -c 2 -W 2 10.3.0.1" "2 received"

log "== 3. Tunnels establish (crypto maps need interesting traffic; VTI comes up on its own)"
node_exec h2 "ping -c 3 -W 2 10.1.0.10" >/dev/null 2>&1 || true
node_exec h3 "ping -c 3 -W 2 10.1.0.10" >/dev/null 2>&1 || true
wait_for "$sa_timeout" asa-hub "show crypto $ike sa" "203.0.113.2"
wait_for "$sa_timeout" asa-hub "show crypto $ike sa" "203.0.113.3"

log "== 4. Traffic is encrypted (encaps counters non-zero on the hub)"
expect_contains h2 "ping -c 5 -W 2 10.1.0.10" "5 received"
expect_not_contains asa-hub "show crypto ipsec sa peer 203.0.113.2 | include pkts encaps" "#pkts encaps: 0"
expect_contains h3 "ping -c 5 -W 2 10.1.0.10" "5 received"
expect_not_contains asa-hub "show crypto ipsec sa peer 203.0.113.3 | include pkts encaps" "#pkts encaps: 0"

log "== 5. Spoke-to-spoke through the hub"
expect_contains h2 "ping -c 5 -W 2 10.3.0.10" "5 received"

if [[ "$VARIANT" == "vti-ikev2" ]]; then
  log "== 6. VTI interfaces up/up"
  expect_contains asa-hub "show interface Tunnel1 | include line protocol" "line protocol is up"
  expect_contains asa-hub "show interface Tunnel2 | include line protocol" "line protocol is up"
fi

log "all checks passed"
```

- [ ] **Step 4: Run tests**

Run: `bash tests/test_asa_hub_spoke.sh && scripts/test.sh`
Expected: `test_asa_hub_spoke.sh: 26 tests, 0 failed`; `ALL PASSED`. The two negative tests take a few seconds each (2 s timeouts).

- [ ] **Step 5: Commit**

```bash
git add scenarios/asa-hub-spoke-ipsec/verify.sh tests/test_asa_hub_spoke.sh
git commit -m "feat: add asa-hub-spoke-ipsec verification with stubbed end-to-end tests"
```

---

### Task 8: Documentation

**Files:**
- Modify: `scenarios/asa-hub-spoke-ipsec/README.md` (replace stub)
- Modify: `images/README.md` (vendor section)
- Modify: `docs/conventions.md` (Scripts and Development tools sections)
- Modify: `docs/simulators/gns3.md`, `docs/simulators/eve-ng.md` (mapping tables)
- Modify: `tests/test_docs.sh`
- Modify: `tests/test_asa_hub_spoke.sh` (README sections test)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_docs.sh` above `run_tests`:
```bash
test_docs_mention_asa_conventions() {
  local c; c="$(cat "$REPO_ROOT/docs/conventions.md")"
  assert_contains "$c" "ASA_NODES"
  assert_contains "$c" "asa_exec"
  assert_contains "$c" "sshpass"
  assert_contains "$c" "ASA_USER"
  assert_contains "$c" "expect_not_contains"
}
test_images_readme_lists_asav() {
  local i; i="$(cat "$REPO_ROOT/images/README.md")"
  assert_contains "$i" "vrnetlab/cisco_asav"
  assert_contains "$i" "ASAv"
}
test_simulator_docs_map_asav() {
  assert_contains "$(cat "$REPO_ROOT/docs/simulators/gns3.md")" "| \`cisco_asav\` |"
  assert_contains "$(cat "$REPO_ROOT/docs/simulators/eve-ng.md")" "| \`cisco_asav\` |"
}
```

Append to `tests/test_asa_hub_spoke.sh` above `run_tests`:
```bash
test_readme_documents_scenario() {
  local r; r="$(cat "$SCN/README.md")"
  assert_contains "$r" "## Objective"
  assert_contains "$r" "## Topology"
  assert_contains "$r" "## Variants"
  assert_contains "$r" "## Verification"
  assert_contains "$r" "## Validation on a containerlab host"
  assert_contains "$r" "GigabitEthernet1/1"
  assert_contains "$r" "BVI"
  assert_contains "$r" "LAB-PSK"
  assert_contains "$r" "hairpin"
  assert_contains "$r" "vrnetlab"
  assert_contains "$r" "scripts/up.sh asa-hub-spoke-ipsec --force"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_docs.sh 2>&1 | tail -4; bash tests/test_asa_hub_spoke.sh 2>&1 | tail -2`
Expected: the four new tests FAIL.

- [ ] **Step 3: Write the scenario README**

`scenarios/asa-hub-spoke-ipsec/README.md`:
````markdown
# asa-hub-spoke-ipsec

## Objective

Three Cisco ASA firewalls (ASAv in the lab, standing in for ASA 5506-X units) in a
hub-and-spoke site-to-site IPsec design, built three ways so the configurations can
be compared and tested: route-based VTI over IKEv2, policy-based crypto maps over
IKEv2, and policy-based crypto maps over IKEv1. One Linux host per site proves
end-to-end traffic, including spoke-to-spoke traffic hairpinning through the hub.

## Topology

```
        h1 (10.1.0.10)                 h2 (10.2.0.10)                h3 (10.3.0.10)
          |  inside 10.1.0.0/24          |  inside 10.2.0.0/24         |  inside 10.3.0.0/24
      asa-hub (.1)                  asa-spoke1 (.1)               asa-spoke2 (.1)
          | outside 203.0.113.1          | outside 203.0.113.2         | outside 203.0.113.3
          +------------------------------+-----------------------------+
                        wan  203.0.113.0/24  (Linux container acting as a bridge)
```

Tunnels: `asa-hub` ↔ `asa-spoke1` and `asa-hub` ↔ `asa-spoke2`. There is no
spoke-to-spoke tunnel; spoke1 ↔ spoke2 traffic goes through the hub.

Containerlab interface mapping for the ASAv nodes: `eth1` = `GigabitEthernet0/0`
(outside), `eth2` = `GigabitEthernet0/1` (inside). `Management0/0` sits on
containerlab's management network and is what `verify.sh` SSHes to.

### Interface names on real 5506-X hardware

| Role | ASAv (this lab) | ASA 5506-X |
|---|---|---|
| outside | `GigabitEthernet0/0` | `GigabitEthernet1/1` |
| inside | `GigabitEthernet0/1` | `GigabitEthernet1/2` |
| management | `Management0/0` | `Management1/1` |

The 5506-X factory configuration bridges `GigabitEthernet1/2`–`1/8` into `BVI1`;
remove that bridge-group configuration before applying these configs.

## Variants

| Variant | Tunnel style | Minimum ASA | Configs |
|---|---|---|---|
| `vti-ikev2` (default) | route-based VTI, IKEv2 | 9.8 | `configs/asa-*/startup.cfg` |
| `cryptomap-ikev2` | policy-based crypto map, IKEv2 | 9.x | `variants/cryptomap-ikev2/configs/` |
| `cryptomap-ikev1` | policy-based crypto map, IKEv1 | 9.x | `variants/cryptomap-ikev1/configs/` |

Crypto parameters: IKEv2 uses AES-256-GCM, PRF SHA-384, DH group 19; IPsec proposal
`GCM` (ESP AES-GCM-256). IKEv1 uses AES-256 / SHA-1 / DH group 14 with transform set
`AES256-SHA` (GCM is not available in IKEv1 on ASA).

Pre-shared keys are lab placeholders: `LAB-PSK-SPOKE1` and `LAB-PSK-SPOKE2`. Change
them before using these configs anywhere real.

### The crypto-map hairpin gotcha

With crypto maps, spoke-to-spoke traffic only works if the hub's crypto ACLs include
the cross entries: `L2L-SPOKE1` must permit `10.3.0.0/24 → 10.2.0.0/24` and
`L2L-SPOKE2` must permit `10.2.0.0/24 → 10.3.0.0/24`, and the hub needs
`same-security-traffic permit intra-interface`. Without them spoke1 ↔ spoke2 pings
fail while hub ↔ spoke traffic looks healthy. The VTI variant has no such ACLs: the
hub simply routes between the two tunnel interfaces.

The two crypto-map variants differ only in the IKE version lines; diff them to see
exactly what moving from IKEv1 to IKEv2 changes.

## Tasks

1. Build the ASAv image with vrnetlab (https://github.com/srl-labs/vrnetlab, `asav/`)
   from your ASAv qcow2 and tag it `vrnetlab/cisco_asav:9.18.4`, or edit the tag in
   `topology.clab.yml` and `scenario.yml` to match your build.
2. Bring up a variant: `scripts/up.sh asa-hub-spoke-ipsec --force [--variant cryptomap-ikev2|cryptomap-ikev1]`
   (`--force` while the scenario is `draft`).
3. Wait for the ASAs to boot (5–7 minutes), then run the verification.

## Verification

`scripts/verify.sh asa-hub-spoke-ipsec [--variant X]` checks, in order:

1. All three ASAs answer `show version` over SSH (management network).
2. Each host pings its own ASA's inside address.
3. After hosts send traffic toward the hub, `show crypto ikev2 sa` (or `ikev1`) on the
   hub lists both spoke peers.
4. Host pings succeed and the hub's `#pkts encaps` for each peer is non-zero, so the
   traffic really went through the tunnels.
5. h2 pings h3 through the hub.
6. VTI variant only: `Tunnel1` and `Tunnel2` on the hub are up/up.

SSH defaults are vrnetlab's `admin` / `CiscoAsa1!`; override with `ASA_USER` and
`ASA_PASS`. `sshpass` and an `ssh` client must be installed.

## Validation on a containerlab host

CI cannot run containerlab or ASAv, so this scenario stays `status: draft` until the
following has passed once per variant on a machine with containerlab, Docker and the
vrnetlab ASAv image:

```bash
for v in vti-ikev2 cryptomap-ikev2 cryptomap-ikev1; do
  scripts/up.sh asa-hub-spoke-ipsec --force --variant "$v"
  scripts/verify.sh asa-hub-spoke-ipsec --variant "$v"
  scripts/down.sh asa-hub-spoke-ipsec --variant "$v"
done
```

The commit that flips `status` to `ready` records the ASAv and containerlab versions
used here:

- ASAv version: not yet validated
- containerlab version: not yet validated

## Simulators

| Simulator | Status |
|---|---|
| Containerlab | native (vrnetlab `cisco_asav`) |
| GNS3 | none yet (ASAv QEMU appliance; see `docs/simulators/gns3.md`) |
| EVE-NG | none yet (`asav` template; see `docs/simulators/eve-ng.md`) |

## Teardown

`scripts/down.sh asa-hub-spoke-ipsec [--variant X]`
````

- [ ] **Step 4: Update `images/README.md`**

Under "## Vendor images (optional variants)", after the existing paragraph, add:

```markdown
| Role | Image tag used in this repo | Source |
|---|---|---|
| Firewall (Cisco ASAv) | `vrnetlab/cisco_asav:<version>` (scenarios use `9.18.4`) | ASAv qcow2 from Cisco (licensed); build with vrnetlab `asav/` and `docker tag` to match |

ASAv notes: vrnetlab bootstraps the `admin` user with password `CiscoAsa1!` and SSH on
`Management0/0`; scenario startup configs are applied after that bootstrap and must not
change it. The VTI scenario variants need ASA 9.8 or newer.
```

- [ ] **Step 5: Update `docs/conventions.md`**

In "## Scripts", after the sentence about `CLAB`/`DOCKER` overrides, add:

```markdown
Scenario `verify.sh` files use four verbs from `scripts/lib.sh`: `expect_contains`,
`expect_not_contains`, `wait_for` and `node_exec`. Nodes are reached with `docker exec`
by default. A scenario whose nodes cannot be driven that way (QEMU-based network OSes
behind vrnetlab, such as ASAv) exports `ASA_NODES="<node> <node> ..."`; the verbs then
reach those nodes over SSH to their containerlab management address via `asa_exec`.
`asa_exec` uses `sshpass` and `ssh`, with `ASA_USER` (default `admin`), `ASA_PASS`
(default `CiscoAsa1!`), `SSH` and `SSHPASS_BIN` overridable from the environment.
```

In "## Development tools", change the runtime line to end with: "...mikefarah** (https://github.com/mikefarah/yq). Scenarios that set `ASA_NODES` additionally need `ssh` and `sshpass` at run time (not for the tests)."

- [ ] **Step 6: Update the simulator mapping tables**

`docs/simulators/gns3.md`: add the row
`| \`cisco_asav\` (vrnetlab) | vendor QEMU image | Cisco ASAv QEMU appliance (asav qcow2, 2 GB RAM, e1000 NICs) |`
after the `cisco_c8000v` row.

`docs/simulators/eve-ng.md`: add the row
`| \`cisco_asav\` | vendor QEMU image | \`asav\` QEMU template |`
after the `cisco_c8000v` row.

- [ ] **Step 7: Run tests**

Run: `scripts/test.sh`
Expected: `test_docs.sh: 8 tests, 0 failed`; `test_asa_hub_spoke.sh: 27 tests, 0 failed`; `ALL PASSED`.

- [ ] **Step 8: Commit**

```bash
git add scenarios/asa-hub-spoke-ipsec/README.md images/README.md docs/conventions.md docs/simulators tests/test_docs.sh tests/test_asa_hub_spoke.sh
git commit -m "docs: document asa-hub-spoke-ipsec, ASAv image and ASA_NODES convention"
```

---

### Task 9: Full suite, push, update PR #2

**Files:** none new.

- [ ] **Step 1: Full suite and a built-topology sanity pass**

Run:
```bash
scripts/test.sh
for v in vti-ikev2 cryptomap-ikev2 cryptomap-ikev1; do
  bash -c 'source scripts/lib.sh; build_topology "$PWD/scenarios/asa-hub-spoke-ipsec" '"$v" >/dev/null
  yq -r '.topology.nodes[] | select(.kind=="cisco_asav") | .["startup-config"]' "scenarios/asa-hub-spoke-ipsec/.$v.build.clab.yml" \
    | while read -r f; do [[ -f "scenarios/asa-hub-spoke-ipsec/$f" ]] && echo "ok $v $f" || echo "MISSING $v $f"; done
done
rm -f scenarios/asa-hub-spoke-ipsec/.*.build.clab.yml
git status --short   # must be clean: built files are git-ignored
```
Expected: `ALL PASSED`; nine `ok` lines; clean status.

- [ ] **Step 2: Push**

```bash
git push -u origin ccr-00157a22-qiys9w
```

- [ ] **Step 3: Update PR #2**

Draft PR #2 already tracks this branch. Update its body (do not open a new PR): replace the "Status" section with a summary of what landed (scenario files, three variants, `asa_exec`/`expect_not_contains`/`_run_on_node` in `lib.sh`, 27 scenario tests + 7 lib tests, docs), keep the "Not yet done" items (real containerlab validation; exports), and tick the two test-plan boxes that CI will confirm. Keep the attribution footer.

- [ ] **Step 4: Confirm CI**

Check the `ci / test` run on the new head. Expected: green.

---

## Self-review notes

- Spec coverage: topology/addressing (T3), interface mapping + BVI note (T8 README), shared base config and NAT exemption (T4–T6 configs, `assert_common_base`), the three variants with the exact crypto parameters (T4, T5, T6), variant wiring via `startup-config` patches (T5, T6), `node_mgmt_ip` / `asa_exec` / `_run_on_node` / `expect_not_contains` (T1, T2), scenario `verify.sh` steps 1–8 (T7), scenario tests incl. markers, cross-ACL entries, PSK checks (T4–T7), lib tests (T1, T2), real-world validation commands and `draft` status (T3 scenario.yml, T8 README), docs changes (T8), exports `none` (T3). Spec deviation: `wan` is a `linux` container bridge, amended in the spec in T3.
- Names used consistently: `ASA_NODES`, `asa_exec`, `node_mgmt_ip`, `_run_on_node`, `expect_not_contains`, `ASA_USER`, `ASA_PASS`, `SSH`, `SSHPASS_BIN`, `ASA_BOOT_TIMEOUT`, `ASA_SA_TIMEOUT`, `WAIT_INTERVAL`, `cfg_of`, `built`, `assert_common_base`, `assert_cryptomap_structure`, `make_asa_stubs`, `make_lab_stubs`, `run_verify`, node names, ACL names `L2L-SPOKE1`/`L2L-SPOKE2`/`L2L-HUB`, crypto map `OUTSIDE_MAP`, proposal `GCM`, profile `VTI-PROFILE`, transform set `AES256-SHA`, tunnel nameifs `vti-spoke1`/`vti-spoke2`/`vti-hub`.
- Test counts in "Expected" lines are the number of `test_*` functions at that point; trust `0 failed` / `ALL PASSED` if a count is off by one.
