# EVE-NG / PNETLab

EVE-NG (and PNETLab, which uses the same `.unl` format) is an export target.
Until a converter exists, `export/eve-ng/<name>.unl` is written by hand from
`topology.clab.yml` and recorded in `scenario.yml` under `simulators.eve-ng`.

## Importing

1. Copy the `.unl` file into `/opt/unetlab/labs/` on the EVE-NG host (or use
   the web UI import, which accepts a zip of `.unl` files).
2. Make sure the referenced images exist under `/opt/unetlab/addons/`
   (`qemu/` for QEMU, `dynamips/`, or Docker images for `docker` nodes).
3. Load startup configs from `configs/<node>/` into each node's startup-config.

## Node mapping

| clab kind | image (default variant) | EVE-NG template |
|---|---|---|
| `linux` (FRR) | `quay.io/frrouting/frr` | `docker` node, image `frrouting/frr` |
| `linux` (host) | `wbitt/network-multitool` | `docker` node or `linux` QEMU |
| `vyos` | VyOS | `vyos` QEMU template |
| `nokia_srlinux` | `ghcr.io/nokia/srlinux` | `docker` node (privileged) |
| `ceos` | `ceos:<version>` | `docker` node |
| `cisco_c8000v` | vendor QEMU image | `c8000v` QEMU template |
| `juniper_vjunosswitch` | vendor QEMU image | `vjunosswitch` QEMU template |

## Hand-written export rules

- First line after the XML declaration: `<!-- derived from topology.clab.yml @ <short sha> -->`.
- Node `name` attributes equal clab node names; networks/links in the clab
  `links:` order.
- Check staleness with `scripts/export.sh <scenario> eve-ng`.
