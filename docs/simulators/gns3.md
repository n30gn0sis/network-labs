# GNS3

GNS3 is an export target. Until a converter exists, `export/gns3/<name>.gns3`
is written by hand from `topology.clab.yml` and recorded in `scenario.yml`
under `simulators.gns3`.

## Importing

1. In GNS3, File → Import portable project, or copy the `.gns3` file into a
   project directory on the GNS3 server.
2. Create the node templates listed below if they do not exist.
3. Attach the startup configs from `configs/<node>/` to each node.

## Node mapping

| clab kind | image (default variant) | GNS3 template |
|---|---|---|
| `linux` (FRR) | `quay.io/frrouting/frr` | Docker template, image `quay.io/frrouting/frr:<tag>`, console telnet |
| `linux` (host) | `wbitt/network-multitool` | Docker template |
| `vyos` / `linux` (VyOS) | `ghcr.io/sever-sever/vyos-container` | Docker template or VyOS QEMU appliance |
| `nokia_srlinux` | `ghcr.io/nokia/srlinux` | Docker template, privileged |
| `ceos` | `ceos:<version>` | Docker template (import image from Arista) |
| `cisco_c8000v` (vrnetlab) | vendor QEMU image | Cisco C8000v QEMU appliance |
| `cisco_asav` | vendor QEMU image (vrnetlab) | Cisco ASAv QEMU appliance (asav qcow2, 2 GB RAM, e1000 NICs) |
| `juniper_vjunosswitch` | vendor QEMU image | vJunos-switch QEMU appliance |

## Hand-written export rules

- `.gns3` files are JSON and cannot carry a comment, so the header goes in a
  sidecar: `export/gns3/<name>.gns3.derived` whose header line at the top is
  `# derived from topology.clab.yml @ <short sha>`.
- Node labels equal clab node names; links in the clab `links:` order.
- Check staleness with `scripts/export.sh <scenario> gns3`.
- Containerlab `exec:` lines (management-route cleanup, bridge and VXLAN
  plumbing) are not carried into a `.gns3` file; the scenario README lists
  them for manual entry in the node console.
