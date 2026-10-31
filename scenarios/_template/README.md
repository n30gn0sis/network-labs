# __SCENARIO_NAME__

## Objective

What this scenario tests and why. One paragraph.

## Topology

```
+----+
| r1 |
+----+
```

Nodes: `r1` (FRR). Links: none yet.

## Variants

- `frr` (default): free images only.

## Tasks

1. Bring up: `scripts/up.sh __SCENARIO_NAME__`
2. Describe the configuration steps a human or script performs here.

## Verification

`scripts/verify.sh __SCENARIO_NAME__` checks:

- r1 answers `show version`.
- r1 running config has `hostname r1`.

## Simulators

| Simulator | Status |
|---|---|
| Containerlab | native |
| GNS3 | none (see `export/gns3/`) |
| EVE-NG | none (see `export/eve-ng/`) |

## Teardown

`scripts/down.sh __SCENARIO_NAME__`
