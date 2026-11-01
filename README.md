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
scenarios/_template/ the template scripts/new-scenario.sh copies
scripts/            up.sh, down.sh, verify.sh, export.sh, new-scenario.sh, lib.sh, test.sh
docs/               conventions, simulator guides, design specs
images/             image policy
```

## Development

```bash
scripts/test.sh     # shellcheck + all tests (no Docker needed)
```
