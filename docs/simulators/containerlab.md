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
