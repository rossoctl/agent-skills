# Reactivate the Scheduled Cleanup Workflow

The scheduled cleanup workflow (`cleanup-stale-hypershift-clusters.yaml`) was
removed from `rossoctl/rossoctl` and preserved here as a skill asset at
`../assets/cleanup-stale-hypershift-clusters.yaml`. This doc explains how to
re-enable it in a repository.

## What the workflow does

- Runs on a schedule (`cron: '0 */3 * * *'` — every 3 hours) and applies cleanup
  with `--apply --verbose --remove-stuck-finalizers`.
- Supports `workflow_dispatch` with inputs: `dry_run` (default `true`),
  `pattern`, `verbose`, `remove_stuck_finalizers`.
- Installs `oc`/`kubectl` and `jq`, decodes a base64 management-cluster
  kubeconfig, optionally loads AWS credentials, runs the cleanup script, uploads
  deletion logs, and opens a GitHub audit issue listing deleted clusters.

## Prerequisites in the target repo

1. **The cleanup script must exist at the path the workflow calls.** The bundled
   workflow calls `./.github/scripts/hypershift/cleanup-stale-clusters.sh`. Either:
   - copy `../../hypershift-cluster/scripts/` (the script plus `hypershift-lib.sh`
     and its `lib-*.sh` siblings and `destroy-cluster.sh`/`debug-aws-hypershift.sh`,
     which `cleanup-stale-clusters.sh` calls) into `.github/scripts/hypershift/`; or
   - edit the workflow's `run:` lines to point at wherever you place the script.
2. **Repository secrets:**
   - `KUBECONFIG_HCP_MGMT` — base64-encoded kubeconfig for the management cluster.
   - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` — used for actual
     deletion (scheduled runs and manual `dry_run=false`).
3. **Permissions:** the workflow declares `contents: read` and `issues: write`
   (for the audit issue). Ensure Actions is allowed to create issues in the repo.

## Steps

```bash
# 1. Copy the workflow into the target repo
cp ../assets/cleanup-stale-hypershift-clusters.yaml \
   <repo>/.github/workflows/cleanup-stale-hypershift-clusters.yaml

# 2. Ensure the cleanup script (and its lib + sibling scripts) exist at the
#    path the workflow calls, or edit the workflow run: lines to match.

# 3. Set the required secrets
gh secret set KUBECONFIG_HCP_MGMT   --repo <owner>/<repo> < mgmt-kubeconfig.b64
gh secret set AWS_ACCESS_KEY_ID     --repo <owner>/<repo>
gh secret set AWS_SECRET_ACCESS_KEY --repo <owner>/<repo>
gh secret set AWS_REGION            --repo <owner>/<repo>

# 4. Commit and push, then verify with a manual dry-run
gh workflow run "Cleanup Stale HyperShift Clusters" \
   --repo <owner>/<repo> -f dry_run=true -f verbose=true
```

## Verify before trusting the schedule

Run a manual `workflow_dispatch` with `dry_run=true` first and confirm the log
lists the expected stale clusters (and that protected clusters are skipped)
before letting the 3-hour schedule apply deletions.

## Notes

- The workflow uses pinned action SHAs (checkout, upload-artifact,
  github-script). Bump them as needed for your repo's security policy.
- Deletion logs are uploaded as artifacts (`cleanup-logs-<run_id>`, 90-day
  retention) and each deletion run opens an audit issue labeled
  `infrastructure`, `automated-cleanup`, `hypershift`.
