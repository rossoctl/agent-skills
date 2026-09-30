---
name: hypershift-cleanup
description: >-
  TTL/label-based auto-cleanup of stale HyperShift clusters, plus the bundled
  scheduled-cleanup GitHub Actions workflow and how to reactivate it. Use when
  you need to find and delete stale clusters, understand the auto-cleanup TTL
  labels, protect a cluster from deletion, or re-enable scheduled cleanup.
license: Complete terms in LICENSE.txt
metadata: {"openclaw": {"requires": {"bins": ["bash", "aws", "oc", "jq"]}}}
---

# HyperShift Cluster Cleanup Skill

Automated cleanup of stale HyperShift clusters based on time-to-live (TTL)
labels, and the scheduled workflow that drives it.

Scripts referenced here live in `../hypershift-cluster/scripts/`. Deeper
references live under `reference/`, and the bundled workflow under `assets/`.

## When to Use

- Find and delete stale clusters that have exceeded their TTL
- Understand or set the auto-cleanup TTL labels on a cluster
- Protect a cluster from auto-deletion
- Remove stuck finalizers from clusters stuck in deletion
- Re-enable the scheduled cleanup GitHub Actions workflow

## Model in Brief

Auto-cleanup is **opt-in** and driven by labels on the `HostedCluster`:

| Label | Meaning |
|-------|---------|
| `rossoctl.io/auto-cleanup=enabled` | Cluster participates in cleanup |
| `rossoctl.io/ttl-hours=<N>` | Delete once age exceeds N hours |
| `rossoctl.io/protected=true` | Never delete (overrides TTL) |
| `rossoctl.io/cluster-type=<type>` | Categorization only |
| `rossoctl.io/created-at=<ISO8601>` | Creation timestamp for age calc |

Set them at creation with `ENABLE_AUTO_CLEANUP=true` (see
`reference/auto-cleanup.md` for the full pattern-based TTL table and cost model).

## Manual Cleanup

```bash
# Dry run (default): show what would be deleted, no changes
../hypershift-cluster/scripts/cleanup-stale-clusters.sh --dry-run

# Apply: actually delete stale clusters
../hypershift-cluster/scripts/cleanup-stale-clusters.sh --apply

# Only a pattern
../hypershift-cluster/scripts/cleanup-stale-clusters.sh --apply --pattern "rossoctl-hypershift-ci-*"

# Show all clusters (not just stale)
../hypershift-cluster/scripts/cleanup-stale-clusters.sh --dry-run --verbose

# Also force-remove finalizers from clusters stuck in deletion
../hypershift-cluster/scripts/cleanup-stale-clusters.sh --apply --remove-stuck-finalizers
```

In `--apply` mode the script calls `destroy-cluster.sh` per stale cluster
(handling ansible cleanup and stuck finalizers) and logs to
`/tmp/cleanup-<cluster-name>.log`. `--remove-stuck-finalizers` only strips a
finalizer after `debug-aws-hypershift.sh --check` confirms AWS resources are
already gone.

## Protect / Extend

```bash
# Protect a cluster from auto-deletion
oc label hostedcluster <name> -n clusters rossoctl.io/protected=true

# Remove protection
oc label hostedcluster <name> -n clusters rossoctl.io/protected-

# Extend TTL to 48h for an existing cluster
oc label hostedcluster <name> -n clusters rossoctl.io/ttl-hours=48 --overwrite
```

## Scheduled Cleanup Workflow

The scheduled workflow (`assets/cleanup-stale-hypershift-clusters.yaml`) runs
every 3 hours applying cleanup, and supports a manual `workflow_dispatch`
dry-run. It was removed from the source repo and bundled here for preservation.
To re-enable it in a repo, follow `reference/reactivate-scheduled-cleanup.md`
(it covers the required secrets, script paths, and a dry-run verification step).

## References

- `reference/auto-cleanup.md` — full TTL/label model, usage, safety, cost impact
- `reference/reactivate-scheduled-cleanup.md` — how to re-enable the workflow
- `assets/cleanup-stale-hypershift-clusters.yaml` — the bundled workflow

## Related Skills

- **hypershift-cluster**: Create and destroy clusters (owns the scripts)
- **hypershift-debug**: Debug stuck/orphaned AWS resources
