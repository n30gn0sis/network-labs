# Images

This repository never contains network OS images. It records which image a
scenario expects and where to get it.

## Free images (default variants)

| Role | Image | Source |
|---|---|---|
| Router (FRR) | `quay.io/frrouting/frr:<tag>` | https://quay.io/repository/frrouting/frr |
| Router (VyOS) | `ghcr.io/sever-sever/vyos-container` or VyOS rolling | https://vyos.net |
| Switch/router (Nokia SR Linux) | `ghcr.io/nokia/srlinux:<tag>` | https://learn.srlinux.dev |
| Switch (Arista cEOS) | `ceos:<version>` | free download with an Arista account; `docker import` |
| Linux host | `wbitt/network-multitool` or `alpine` | Docker Hub |

## Vendor images (optional variants)

Vendor images are licensed. You supply them. Build QEMU-based images for
Containerlab with vrnetlab (https://github.com/srl-labs/vrnetlab) and tag them
as the variant's `topology.patch.yml` expects, e.g.
`vrnetlab/cisco_c8000v:17.12`. For GNS3 and EVE-NG, install the vendor QEMU
image using that simulator's own procedure; the mapping tables in
`docs/simulators/` give the template names.

| Role | Image tag used in this repo | Source |
|---|---|---|
| Firewall (Cisco ASAv) | `vrnetlab/cisco_asav:<version>` (scenarios use `9.18.4`) | ASAv qcow2 from Cisco (licensed); build with vrnetlab `asav/` and `docker tag` to match |

ASAv notes: vrnetlab bootstraps the `admin` user with password `Admin@123` and SSH on
`Management0/0`; scenario startup configs are applied after that bootstrap and must not
change it. The VTI scenario variants need ASA 9.8 or newer.

A variant's `notes:` field in `scenario.yml` should say which image build the
scenario was tested with.
