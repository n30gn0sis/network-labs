# Variants

A variant swaps images (and, when the NOS syntax differs, configs) without
changing the topology. Create `variants/<name>/` containing:

- `topology.patch.yml`: per-node overrides, deep-merged onto `topology.clab.yml`.
  Example:
  ```yaml
  topology:
    nodes:
      r1:
        kind: cisco_c8000v
        image: vrnetlab/cisco_c8000v:17.12
        binds: []
        startup-config: variants/cisco-iosxe/configs/r1/startup.cfg
  ```
- `configs/<node>/`: replacement startup configs for that NOS.

Nodes without an override keep the default topology and configs. Register the
variant under `variants:` in `scenario.yml`.
