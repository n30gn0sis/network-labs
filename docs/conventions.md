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
`.<variant>.build.clab.yml` beside `topology.clab.yml` (git-ignored) so relative
paths resolve exactly as in the source file.

## Exports

`export/` is derived. If an export disagrees with `topology.clab.yml`, the
topology wins. Hand-written exports record the source commit as
`derived from topology.clab.yml @ <short sha>`: `.unl` files carry it as an
XML comment (`<!-- ... -->`) on the first line or directly after the XML
declaration; `.gns3` files are JSON, so it goes in
a header line at the top of a sidecar `<name>.gns3.derived` (`# ...`). Exports use the
same node labels as the topology and list links in the same order.
`scripts/export.sh <scenario> gns3|eve-ng` reports whether an export is stale.

## Scripts

All scripts use `set -euo pipefail`, print usage on `-h`, and validate
arguments and `scenario.yml` before doing anything. Binaries are overridable
for testing: `CLAB` (containerlab), `DOCKER` (docker).

Scenario `verify.sh` files use four verbs from `scripts/lib.sh`: `expect_contains`,
`expect_not_contains`, `wait_for` and `node_exec`. Nodes are reached with `docker exec`
by default. A scenario whose nodes cannot be driven that way (QEMU-based network OSes
behind vrnetlab, such as ASAv) exports `ASA_NODES="<node> <node> ..."`; the verbs then
reach those nodes over SSH to their containerlab management address via `asa_exec`.
`asa_exec` uses `sshpass` and `ssh`, with `ASA_USER` (default `admin`), `ASA_PASS`
(default `CiscoAsa1!`), `SSH` and `SSHPASS_BIN` (the sshpass binary path) overridable
from the environment. `ASA_SSH_TIMEOUT` (default 30 seconds) bounds each SSH call via
coreutils `timeout`. The ASAv scenario's `verify.sh` also honours `ASA_BOOT_TIMEOUT`
(default 600) and `ASA_SA_TIMEOUT` (default 120). If a server ignores SSH exec
requests, feed the commands on stdin instead of as an ssh argument.

### Failure injection

A scenario that breaks something to test convergence (for example
`node_exec r1 "ip link set eth2 down"`) must restore it even when a later
check fails. Define a restore function and register it with
`trap restore_link EXIT` before injecting the failure, perform the degraded
checks, then restore explicitly and clear the trap with `trap - EXIT` before
the final checks. Prefer kernel-level injection (`ip link set`) over
daemon-level `shutdown` commands: it models a real link loss and needs no
NOS-specific syntax.

## Development tools

Runtime: `bash`, `docker`, `containerlab`, `git`, and `yq` **v4 from
mikefarah** (https://github.com/mikefarah/yq). The Python `yq` jq-wrapper is a
different program and is rejected by the scripts. Scenarios that set `ASA_NODES` additionally need `ssh` and `sshpass` at run time (not for the tests).

Development: `shellcheck`. Run `scripts/test.sh` before committing; CI runs
the same script.

Install on Linux without a package manager:

```bash
mkdir -p ~/.local/bin
curl -sSL -o ~/.local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && chmod +x ~/.local/bin/yq
curl -sSL https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz | tar -xJ -C /tmp && mv /tmp/shellcheck-v0.10.0/shellcheck ~/.local/bin/
```
