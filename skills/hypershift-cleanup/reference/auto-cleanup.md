# HyperShift Cluster Auto-Cleanup

Automated cleanup of stale HyperShift clusters based on time-to-live (TTL) labels.

## Overview

The auto-cleanup feature helps manage HyperShift cluster lifecycle by automatically marking clusters for deletion after a configurable TTL expires. This prevents forgotten clusters from accumulating AWS costs and helps maintain a clean testing environment.

## How It Works

1. **Opt-in**: Set `ENABLE_AUTO_CLEANUP=true` when creating a cluster
2. **Pattern-based TTL**: TTL is automatically determined by cluster name pattern
3. **Label-based tracking**: Cluster metadata is stored as Kubernetes labels
4. **Protection mechanisms**: Clusters can be protected from auto-deletion
5. **Scheduled cleanup**: A GitHub Actions workflow checks for stale clusters periodically (see `reactivate-scheduled-cleanup.md` and `../assets/cleanup-stale-hypershift-clusters.yaml`)

## TTL Defaults (Pattern-Based)

| Cluster Name Pattern | TTL | Use Case | Example |
|---------------------|-----|----------|---------|
| `*-pr-*` or `*-pr[0-9]*` | 3 hours | PR test clusters | `rossoctl-hypershift-ci-pr529` |
| `*-main-*` or `*-merge-*` | 6 hours | Post-merge test clusters | `rossoctl-hypershift-ci-main-test` |
| `rossoctl-hypershift-ci-*` | 3 hours | Generic CI clusters | `rossoctl-hypershift-ci-test123` |
| `rossoctl-hypershift-custom-*` | 168 hours (1 week) | Developer clusters | `rossoctl-hypershift-custom-ladas` |
| `*-team-*` | 168 hours (1 week) | Team shared clusters | `rossoctl-team-demo` |
| _Unknown pattern_ | 24 hours | Safety default | `my-custom-cluster` |

## Labels Applied

When auto-cleanup is enabled, the following labels are added to the `HostedCluster` resource:

```yaml
metadata:
  labels:
    rossoctl.io/auto-cleanup: "enabled"          # Marks cluster for auto-cleanup
    rossoctl.io/ttl-hours: "3"                   # TTL in hours (pattern-based)
    rossoctl.io/cluster-type: "ci-pr"            # Cluster type for categorization
    rossoctl.io/created-at: "2026-03-05T10:30:00Z"  # ISO 8601 creation timestamp
```

## Usage

### Create Cluster with Auto-Cleanup

```bash
# Enable auto-cleanup (uses pattern-based TTL)
ENABLE_AUTO_CLEANUP=true ../../hypershift-cluster/scripts/create-cluster.sh pr529

# Enable with custom TTL override (12 hours instead of pattern default)
ENABLE_AUTO_CLEANUP=true AUTO_CLEANUP_TTL_HOURS=12 \
  ../../hypershift-cluster/scripts/create-cluster.sh pr529
```

### Create Cluster WITHOUT Auto-Cleanup (Default)

```bash
# Auto-cleanup is disabled by default
../../hypershift-cluster/scripts/create-cluster.sh pr529
```

### Protect Cluster from Auto-Deletion

Add the `protected` label to prevent a cluster from being auto-deleted:

```bash
# Protect a cluster (even if TTL expires)
oc label hostedcluster rossoctl-hypershift-ci-pr529 -n clusters \
  rossoctl.io/protected=true

# Remove protection
oc label hostedcluster rossoctl-hypershift-ci-pr529 -n clusters \
  rossoctl.io/protected-
```

### Extend TTL Temporarily

```bash
# Extend TTL to 48 hours for an existing cluster
oc label hostedcluster rossoctl-hypershift-ci-pr529 -n clusters \
  rossoctl.io/ttl-hours=48 --overwrite
```

### Check Cluster Auto-Cleanup Status

```bash
# View auto-cleanup labels for all clusters
oc get hostedclusters -n clusters \
  -o custom-columns=NAME:.metadata.name,AUTO_CLEANUP:.metadata.labels.'rossoctl\.io/auto-cleanup',TTL:.metadata.labels.'rossoctl\.io/ttl-hours',TYPE:.metadata.labels.'rossoctl\.io/cluster-type',CREATED:.metadata.labels.'rossoctl\.io/created-at'

# Check specific cluster
oc get hostedcluster rossoctl-hypershift-ci-pr529 -n clusters \
  -o jsonpath='{.metadata.labels}'
```

## Manual Cleanup

The cleanup script identifies and deletes stale clusters based on their TTL:

```bash
# Dry run (show what would be deleted) - default mode
../../hypershift-cluster/scripts/cleanup-stale-clusters.sh --dry-run

# Apply cleanup (actually delete stale clusters)
../../hypershift-cluster/scripts/cleanup-stale-clusters.sh --apply

# Cleanup specific pattern only
../../hypershift-cluster/scripts/cleanup-stale-clusters.sh --apply --pattern "rossoctl-hypershift-ci-*"

# Verbose output (shows all clusters, not just stale)
../../hypershift-cluster/scripts/cleanup-stale-clusters.sh --dry-run --verbose
```

### How It Works

1. Fetches all `HostedCluster` resources with label `rossoctl.io/auto-cleanup=enabled`
2. For each cluster:
   - Checks if `rossoctl.io/protected=true` (skip if protected)
   - Calculates age from `rossoctl.io/created-at` label
   - Compares age against `rossoctl.io/ttl-hours` label
   - If age > TTL: marks as stale
3. In `--apply` mode: calls `destroy-cluster.sh` for each stale cluster
4. Logs all deletions to `/tmp/cleanup-<cluster-name>.log`

### Example Output

```bash
$ ../../hypershift-cluster/scripts/cleanup-stale-clusters.sh --dry-run --verbose

╔════════════════════════════════════════════════════════════════╗
║          Cleanup Stale HyperShift Clusters                     ║
╚════════════════════════════════════════════════════════════════╝

Mode: DRY-RUN (no deletions)

→ Finding clusters with auto-cleanup enabled...
✓ Found 3 cluster(s) with auto-cleanup enabled

⚠ STALE: rossoctl-hypershift-ci-pr529
       Age: 5h | TTL: 3h | Over by: 2h
       Type: ci-pr | Created: 2026-03-05T10:30:00Z
       Would delete (use --apply to execute)

✓ PROTECTED: rossoctl-hypershift-custom-demo

✓ OK: rossoctl-hypershift-ci-test123
       Age: 1h | TTL: 3h | Type: ci-generic

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Summary:
  Total clusters: 3
  Stale clusters: 1
  Protected clusters: 1
  Healthy clusters: 1

This was a DRY-RUN. No clusters were deleted.
To actually delete stale clusters, run with --apply flag.
```

## Scheduled Cleanup

A GitHub Actions workflow runs periodically to clean up stale clusters. The
workflow is bundled with this skill at
`../assets/cleanup-stale-hypershift-clusters.yaml`; see
`reactivate-scheduled-cleanup.md` for how to re-enable it in a repo.

- **Schedule**: Every 3 hours (matches fastest TTL)
- **Scheduled runs**: Apply mode with `--verbose --remove-stuck-finalizers`
- **Manual trigger**: `workflow_dispatch` with a `dry_run` input (defaults to true)
- **Audit trail**: Creates a GitHub issue for deletion events

## CI Integration

### Enable for CI Workflows

Add to your GitHub Actions workflow when creating a cluster:

```yaml
- name: Create HyperShift cluster
  env:
    ENABLE_AUTO_CLEANUP: "true"
    AUTO_CLEANUP_TTL_HOURS: "3"  # Optional override
  run: |
    bash create-cluster.sh pr${{ github.event.pull_request.number }}
```

### Example: PR Testing

```yaml
env:
  CLUSTER_SUFFIX: pr${{ github.event.pull_request.number }}
  ENABLE_AUTO_CLEANUP: "true"
  # TTL will be 3h (auto-detected from *-pr-* pattern)
```

## Safety Features

1. **Opt-in by default**: Auto-cleanup must be explicitly enabled
2. **Protection label**: `rossoctl.io/protected=true` prevents deletion
3. **Pattern-based defaults**: Conservative TTL for unknown patterns (24h)
4. **Dry-run mode**: Cleanup script shows impact before applying
5. **Audit trail**: Deletion events create GitHub issues
6. **Manual override**: TTL can be extended at any time

## Troubleshooting

### Cluster was deleted unexpectedly

Check if auto-cleanup was enabled:
```bash
# Check deleted cluster's last state (if still in etcd history)
oc get hostedcluster rossoctl-hypershift-ci-pr529 -n clusters \
  --ignore-not-found -o yaml | grep -A 5 "rossoctl.io"
```

### Protect all existing clusters

```bash
# Add protection to all clusters
oc get hostedclusters -n clusters -o name | while read cluster; do
  oc label $cluster rossoctl.io/protected=true
done
```

### Disable auto-cleanup for all future clusters

Don't set `ENABLE_AUTO_CLEANUP=true`. Auto-cleanup is **disabled by default**.

## Cost Impact

Example AWS costs saved per forgotten cluster (3 workers, m5.xlarge):

| Cluster Age | Cost |
|------------|------|
| 1 day | $13.82 |
| 1 week | $96.77 |
| 1 month | $414.72 |

Auto-cleanup with a 3-hour TTL prevents >95% of forgotten cluster costs.
