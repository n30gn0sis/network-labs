# Multi-simulator network lab repository: design

Date: 2026-10-31
Status: approved for planning

## Goal

Set up `network-labs` as a repository of network engineering scenarios that run
on several free network simulators from a single source of truth. The scenarios
are for testing network designs and automation, so reproducibility and a
scriptable bring-up / verify / tear-down loop matter more than GUI polish.

This first pass delivers the **skeleton only**: repository layout, conventions,
a scenario template, thin shell scripts, documentation, and tests for the
scaffolding. No real scenario is written yet.

## Decisions already made

| Topic | Decision |
|---|---|
| Simulators | Containerlab (primary, scripted), GNS3, EVE-NG / PNETLab (export targets). Other free tools may be added later as further export targets. |
| Images | Free images by default (FRR, VyOS, Nokia SR Linux, Arista cEOS, Linux hosts). Vendor images (Cisco IOS-XE, Juniper, ...) are optional per-scenario variants that the user supplies. |
| Hosting | Undecided. Design keeps both the scripted path (Containerlab locally) and the manual-import path (GNS3 / EVE-NG files) open. |
| Tooling | Plain configuration files and shell scripts. No Ansible, Nornir or Python in this pass. |
| Topology format | Containerlab's `topology.clab.yml` is the single source of truth per scenario. GNS3 and EVE-NG files are derived exports; hand-written exports are allowed until converters exist. |
| Variants | Vendor-image variants are `yq`-merged overlays on the default topology, not full copies. |

## Approaches considered

- **A. Containerlab topology as single source of truth, other simulators as
  exports.** Chosen. One topology file per scenario, well-documented format,
  most scriptable simulator, vendor images via vrnetlab. GNS3 / EVE-NG support
  depends on converters that do not exist yet, so hand-written exports are
  allowed in the meantime.
- **B. One hand-written native file per simulator.** Rejected: three
  topologies per scenario drift apart.
- **C. netlab (netsim-tools) as abstraction layer.** Rejected: Python/Ansible
  dependency conflicts with the plain-shell choice, and netlab has no GNS3 or
  EVE-NG output.

## Repository layout

```
network-labs/
├── README.md                  # purpose, quick start, supported simulators
├── .gitignore                 # ignores scenarios/*/.build/ and containerlab runtime dirs
├── docs/
│   ├── conventions.md         # naming, image policy, scenario structure
│   ├── simulators/
│   │   ├── containerlab.md    # install, run, teardown
│   │   ├── gns3.md            # importing exported / hand-written projects; kind mapping
│   │   └── eve-ng.md          # importing .unl files; PNETLab notes; kind mapping
│   └── superpowers/specs/     # design documents
├── scenarios/
│   └── _template/             # copied by scripts/new-scenario.sh
│       ├── README.md          # objective, ASCII topology, tasks, verification steps
│       ├── scenario.yml       # metadata (see Scenario contract)
│       ├── topology.clab.yml  # single source of truth, default images
│       ├── verify.sh          # scenario-specific checks using scripts/lib.sh
│       ├── configs/
│       │   └── <node>/        # startup config per node, named after the clab node
│       ├── variants/          # optional vendor overlays, e.g. variants/cisco-iosxe/
│       └── export/
│           ├── gns3/          # .gns3 project: hand-written now, generated later
│           └── eve-ng/        # .unl lab: hand-written now, generated later
├── scripts/
│   ├── lib.sh                 # shared helpers for scripts and verify.sh files
│   ├── new-scenario.sh        # copy _template, replace placeholders
│   ├── up.sh                  # merge variant overlay, containerlab deploy
│   ├── down.sh                # containerlab destroy --cleanup
│   ├── verify.sh              # run a scenario's verify.sh
│   ├── export.sh              # report / later generate GNS3 and EVE-NG exports
│   └── test.sh                # tests for the scaffolding (see Testing)
├── images/
│   └── README.md              # image sources, what is free, what the user supplies
└── .github/workflows/ci.yml   # runs scripts/test.sh on push and pull request
```

### Two rules that make portability work

1. **Node names in `topology.clab.yml` are the key everywhere.** `configs/<node>/`,
   variant overlays and export files all refer to nodes by those names.
2. **`export/` is derived, never authoritative.** If an export file and the clab
   file disagree, the clab file wins. Every hand-written export records a header
   comment recording the clab file and git short SHA it was written from.

## Scenario contract

### `scenario.yml`

Small metadata read by the scripts. The topology itself lives only in
`topology.clab.yml`.

```yaml
name: ospf-three-router          # must equal the directory name
title: OSPF single-area, three routers
topic: routing/ospf
status: draft                    # draft | ready; scripts refuse `draft` without --force
default_variant: frr
variants:
  frr:                           # default: free images only
    images:
      router: quay.io/frrouting/frr:10.1
  cisco-iosxe:                   # optional vendor flavour
    images:
      router: vrnetlab/cisco_c8000v:17.12
    notes: requires image built with vrnetlab; see images/README.md
simulators:
  containerlab: native
  gns3: export/gns3/ospf-three-router.gns3    # relative path, or `none`
  eve-ng: export/eve-ng/ospf-three-router.unl # relative path, or `none`
```

Required keys: `name`, `title`, `topic`, `status`, `default_variant`,
`variants` (containing at least `default_variant`), `simulators` (all three
keys present, each a path or `none` / `native`).

### Variants

`topology.clab.yml` uses the default variant's images. A variant directory
`variants/<name>/` may contain:

- `topology.patch.yml`: per-node `image` and `kind` overrides, deep-merged onto
  `topology.clab.yml` by `up.sh` using `yq`. The merged result is written to a
  git-ignored `.build/<variant>.clab.yml` and that file is deployed.
- `configs/<node>/`: replacement startup configs in that NOS's syntax.

Any node without an override falls back to the default topology and configs.

### Verification

Each scenario has a `verify.sh` that receives the scenario name and variant,
runs checks against nodes and exits non-zero on the first failure. It sources
`scripts/lib.sh`, which provides:

- `node_exec <node> <command>`: `docker exec` into the clab container (SSH when a
  management address is configured, later).
- `expect_contains <node> <command> <string>`: fail unless output contains string.
- `wait_for <seconds> <node> <command> <string>`: retry `expect_contains` until timeout.
- `log`, `fail`: consistent messages and exit codes.

The template's `verify.sh` is a short list of such calls, not a framework.

## Scripts

All scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, usage text on `-h`,
argument validation, check that the scenario directory exists, that
`scenario.yml` parses and has the required keys, and that required tools are on
`PATH`. They fail with a one-line message before touching Docker.

| Script | Behaviour |
|---|---|
| `new-scenario.sh <name>` | Copies `scenarios/_template` to `scenarios/<name>`, replaces `__SCENARIO_NAME__` placeholders, refuses to overwrite. |
| `up.sh <scenario> [--variant X] [--force]` | Resolves variant (default from `scenario.yml`), merges overlay if present, runs `containerlab deploy`. Refuses `status: draft` without `--force`. |
| `down.sh <scenario> [--variant X]` | `containerlab destroy --cleanup` on the deployed topology file. |
| `verify.sh <scenario> [--variant X]` | Runs the scenario's `verify.sh` with `lib.sh` on the path. |
| `export.sh <scenario> gns3\|eve-ng` | Prints the export path from `scenario.yml`, whether it is hand-written, and whether it is stale (header SHA differs from the last commit that touched `topology.clab.yml`). Later this invokes a converter. |
| `test.sh` | Runs all scaffolding tests (see Testing). |

Runtime dependencies: `bash`, `docker`, `containerlab`, `yq` (v4), `git`.
Development dependency: `shellcheck`.

## Image policy

Documented in `images/README.md` and `docs/conventions.md`:

- The default variant uses only freely pullable images: FRR, VyOS rolling,
  Nokia SR Linux, Arista cEOS (free account), Alpine / `network-multitool` hosts.
- Vendor images are never committed and never referenced by a URL that implies
  this repository hosts them. A variant records the expected image tag and links
  to the vrnetlab build recipe or vendor download page.
- `docs/simulators/gns3.md` and `eve-ng.md` each carry a mapping table:
  clab `kind` → GNS3 template → EVE-NG template name, so hand-written exports
  use consistent node types.

## Hand-written export rules

Until converters exist:

- Source commit header `derived from topology.clab.yml @ <git short sha>`:
  for `.unl` XML, a first-line XML comment; for `.gns3` (JSON, which cannot
  carry a comment), the first line of a sidecar `<name>.gns3.derived` file
  (`# derived from ...`). `export.sh` checks the file first, then the sidecar.
- Node labels identical to clab node names; links in the same order as the clab
  `links:` list.
- `export.sh` warns when the recorded SHA is older than the last commit that
  changed `topology.clab.yml`.

## Testing

No lab exists yet, so tests cover the scaffolding. `scripts/test.sh` runs:

1. `shellcheck` on every `*.sh`.
2. `scenario.yml` validation with `yq`: required keys present; `_template`
   passes with placeholder values.
3. `new-scenario.sh` smoke test: create a scenario in a temp directory, assert
   expected files exist and no `__SCENARIO_NAME__` placeholder remains.
4. `export.sh` staleness check against a fixture export with a wrong SHA
   (expects a warning) and a correct SHA (expects none).
5. Argument-validation tests: each script exits non-zero with a usage message
   on missing or unknown arguments and on a nonexistent scenario.

`.github/workflows/ci.yml` runs `scripts/test.sh` on push and pull request. No
Docker is required in CI.

## Out of scope for this pass

- The GNS3 and EVE-NG converters.
- Any real scenario (the first, likely a three-router OSPF lab on FRR, gets its
  own spec).
- Ansible / Nornir / Python integration.
- Remote GNS3 / EVE-NG API drivers.
- Other simulators (Kathará, Mininet, CML) as export targets.

Each of these gets its own spec → plan → implementation cycle.
