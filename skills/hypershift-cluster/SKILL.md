---
name: hypershift-cluster
description: >-
  Create and destroy ephemeral HyperShift (hosted OpenShift) clusters on AWS.
  Owns the shared HyperShift scripts and lib that the other HyperShift skills
  reference. Use when you need to create a test OpenShift cluster, destroy one
  after testing, or look up cluster naming, environment variables, or the
  post-create deploy/e2e workflow.
license: Complete terms in LICENSE.txt
metadata: {"openclaw": {"requires": {"bins": ["bash", "aws", "oc", "jq", "ansible-playbook"]}}}
---

# HyperShift Cluster Management Skill

Create, destroy, and manage HyperShift clusters on AWS for testing.

This skill **owns the shared scripts**. Every HyperShift script and the shared
`hypershift-lib.sh` live under `scripts/` here; the other HyperShift skills point
at them via `../hypershift-cluster/scripts/...`. Run any script with no arguments
(or `--help` where supported) to see its options first.

## When to Use

- Need to create a test OpenShift cluster on AWS
- Destroying a cluster after testing
- User asks "create hypershift cluster" or "destroy cluster"
- Testing on real OpenShift (not Kind)

## Prerequisites

Before creating clusters, ensure setup is complete (see the `hypershift-setup`
skill for detail):

```bash
# 1. Run preflight check
scripts/preflight-check.sh

# 2. Setup credentials (first time only, requires IAM admin)
scripts/setup-hypershift-ci-credentials.sh

# 3. Setup local tools (hcp CLI, ansible, etc.)
scripts/local-setup.sh
```

The scripts locate your credentials file relative to your current working
directory (or via `$HYPERSHIFT_ENV_FILE`) and the `hypershift-automation` clone
via `$HYPERSHIFT_AUTOMATION_DIR` (falling back to a sibling of your cwd or
`$HOME/hypershift-automation`). They do not assume any particular repository
layout.

## Create Cluster

### Quick Create (Default Suffix)

```bash
# Creates: rossoctl-hypershift-custom-<username>
scripts/create-cluster.sh
```

### Create with Custom Suffix

```bash
# Creates: rossoctl-hypershift-custom-pr529
scripts/create-cluster.sh pr529

# Creates: rossoctl-hypershift-custom-mytest
scripts/create-cluster.sh mytest
```

### Create with Custom Configuration

```bash
# More worker nodes and larger instances
REPLICAS=3 INSTANCE_TYPE=m5.2xlarge scripts/create-cluster.sh

# Specific OCP version
OCP_VERSION=4.19.5 scripts/create-cluster.sh
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REPLICAS` | 2 | Number of worker nodes |
| `INSTANCE_TYPE` | m5.xlarge | AWS instance type |
| `OCP_VERSION` | 4.20.11 | OpenShift version |
| `CLUSTER_SUFFIX` | username | Suffix for cluster name |
| `MANAGED_BY_TAG` | rossoctl-hypershift-custom | IAM scope prefix |

## Destroy Cluster

### Quick Destroy

```bash
# Destroy by suffix
scripts/destroy-cluster.sh <suffix>

# Examples:
scripts/destroy-cluster.sh pr529
scripts/destroy-cluster.sh ladas
```

### Destroy by Full Name

```bash
scripts/destroy-cluster.sh rossoctl-hypershift-custom-pr529
```

## After Cluster Creation

The create script outputs next steps. A typical workflow deploys the platform
onto the new cluster. These deploy/e2e steps run from a rossoctl checkout (they
are not bundled with this skill):

```bash
# 1. Set kubeconfig to new cluster
export KUBECONFIG=~/clusters/hcp/<cluster-name>/auth/kubeconfig

# 2. Verify cluster access
oc get nodes
oc get clusterversion

# 3. Deploy the platform (from a rossoctl checkout)
./.github/scripts/operator/30-run-installer.sh --env ocp
./.github/scripts/operator/41-wait-crds.sh

# 4. Deploy demo agents
./.github/scripts/operator/71-build-weather-tool.sh
./.github/scripts/operator/72-deploy-weather-tool.sh
./.github/scripts/operator/74-deploy-weather-agent.sh

# 5. Run E2E tests
export AGENT_URL="https://$(oc get route -n team1 weather-service -o jsonpath='{.spec.host}')"
export ROSSOCTL_CONFIG_FILE=deployments/envs/ocp_values.yaml
./.github/scripts/operator/90-run-e2e-tests.sh
```

## Cluster Naming

Clusters are named: `${MANAGED_BY_TAG}-${CLUSTER_SUFFIX}`

| MANAGED_BY_TAG | Use Case | Example |
|----------------|----------|---------|
| `rossoctl-hypershift-custom` | Local development (default) | rossoctl-hypershift-custom-ladas |
| `rossoctl-hypershift-ci` | CI/CD pipelines | rossoctl-hypershift-ci-pr529 |

The cluster suffix is limited to 5 characters (AWS IAM role-name length limit).

## Troubleshooting

### Cluster Creation Stuck

```bash
# Check HostedCluster status (use management cluster kubeconfig)
source .env.rossoctl-hypershift-custom  # or .env.hypershift-ci
oc get hostedcluster -n clusters

# Check conditions
oc get hostedcluster -n clusters <cluster-name> -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" - "}{.message}{"\n"}{end}'

# Check NodePool
oc get nodepool -n clusters <cluster-name>
```

### Cluster Deletion Stuck

```bash
# Debug AWS resources (see the hypershift-debug skill)
scripts/debug-aws-hypershift.sh <cluster-name>

# Force remove finalizer (only if AWS resources are cleaned)
oc patch hostedcluster -n clusters <cluster-name> -p '{"metadata":{"finalizers":null}}' --type=merge
```

### Control Plane Namespace Issues

```bash
# If namespace is stuck terminating
oc delete ns clusters-<cluster-name> --wait=false
oc patch ns clusters-<cluster-name> -p '{"metadata":{"finalizers":null}}' --type=merge
```

### Check AWS Quotas

```bash
# Before creating clusters, check capacity (see the hypershift-quotas skill)
scripts/check-quotas.sh
```

## Related Skills

- **hypershift-setup**: Set up the local environment for HyperShift
- **hypershift-preflight**: Run pre-flight checks
- **hypershift-quotas**: Check AWS quotas and plan parallel capacity
- **hypershift-debug**: Debug AWS resources for stuck clusters
- **hypershift-cleanup**: TTL/label-based auto-cleanup of stale clusters
