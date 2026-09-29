---
name: hypershift-setup
description: >-
  Set up the local environment for HyperShift testing: installs the hcp CLI,
  ansible collections, Python dependencies, clones hypershift-automation, and
  configures credentials. Use when setting up HyperShift for the first time,
  after reinstalling tools, or when the hcp CLI or ansible collections are missing.
license: Complete terms in LICENSE.txt
metadata: {"openclaw": {"requires": {"bins": ["bash", "aws", "oc", "jq", "ansible-playbook"]}}}
---

# HyperShift Local Setup Skill

Set up the local development environment for HyperShift cluster provisioning.

Scripts referenced here live in `../hypershift-cluster/scripts/`. Run any script
with no arguments (or `--help` where supported) to see its options first.

## When to Use

- First time setting up HyperShift testing
- After reinstalling tools or machine
- Missing hcp CLI or ansible collections
- User asks "setup hypershift" or "configure hypershift"

## Prerequisites

Before running setup:

1. **AWS CLI**: Configured with admin credentials
2. **OpenShift CLI (oc)**: Installed and logged into the management cluster
3. **Ansible**: `pip install ansible-core`
4. **Credentials file**: Created by `setup-hypershift-ci-credentials.sh`

## Quick Setup Workflow

```bash
# 1. Run preflight check first
../hypershift-cluster/scripts/preflight-check.sh

# 2. Set up credentials (requires IAM admin - first time only)
../hypershift-cluster/scripts/setup-hypershift-ci-credentials.sh

# 3. Set up local tools
../hypershift-cluster/scripts/local-setup.sh
```

## What local-setup.sh Does

1. **Loads credentials** from `.env.rossoctl-hypershift-custom` or `.env.hypershift-ci`
2. **Installs hcp CLI** from the OpenShift console to `~/.local/bin`
3. **Clones hypershift-automation** repository (fork with additional-tags support)
4. **Installs ansible collections**: kubernetes.core, amazon.aws, community.general
5. **Installs Python dependencies**: boto3, botocore, kubernetes, openshift
6. **Saves pull secret** to `~/.pullsecret.json`
7. **Verifies kubeconfig** for the management cluster

## Running local-setup.sh

```bash
../hypershift-cluster/scripts/local-setup.sh
```

Expected output:
```
✓ Loaded credentials from .env.rossoctl-hypershift-custom
✓ hcp CLI installed to ~/.local/bin
✓ Cloned to .../hypershift-automation
✓ Ansible collections installed
✓ Python dependencies installed
✓ Pull secret saved to ~/.pullsecret.json
✓ Management kubeconfig verified
```

## After Setup

```bash
# Create your first cluster
../hypershift-cluster/scripts/create-cluster.sh
```

See the `hypershift-cluster` skill for the full create/deploy/test workflow.

## Manual Steps

### Install hcp CLI Manually

If automatic download fails:

```bash
# 1. Get the console downloads URL
oc get consoleclidownloads hcp-cli-download -o jsonpath='{.spec.links}'

# 2. Download from the OpenShift console
# Go to: ? → Command Line Tools → Download hcp CLI

# 3. Extract to ~/.local/bin
tar -xzf hcp-*.tar.gz && mv hcp ~/.local/bin/
chmod +x ~/.local/bin/hcp

# 4. Add to PATH (add to ~/.zshrc or ~/.bashrc)
export PATH="$HOME/.local/bin:$PATH"
```

### Install Ansible Collections Manually

```bash
ansible-galaxy collection install kubernetes.core amazon.aws community.general --force-with-deps
pip install boto3 botocore kubernetes openshift PyYAML
```

### Clone hypershift-automation Manually

```bash
cd ..
git clone -b add-additional-tags-support https://github.com/Ladas/hypershift-automation.git
```

## Credentials File Structure

Setup creates `.env.rossoctl-hypershift-custom` (or `.env.hypershift-ci`) in your
working directory:

```bash
# AWS credentials (scoped to MANAGED_BY_TAG)
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION="us-east-1"

# Cluster configuration
export MANAGED_BY_TAG="rossoctl-hypershift-custom"
export BASE_DOMAIN="octo-emerging.redhataicoe.com"
export HCP_ROLE_NAME="rossoctl-hypershift-custom-hcp-role"

# Management cluster access
export KUBECONFIG="$HOME/.kube/rossoctl-hypershift-ci-mgmt.kubeconfig"

# Pull secret (for accessing Red Hat registries)
export PULL_SECRET='{"auths":{...}}'
```

The scripts locate this file relative to your current working directory (or via
`$HYPERSHIFT_ENV_FILE`); they do not assume any particular repository layout.

## Verify Setup

```bash
# Check hcp CLI
hcp version

# Check ansible
ansible-playbook --version
ansible-galaxy collection list | grep -E "kubernetes|amazon|community"

# Check AWS credentials
aws sts get-caller-identity

# Check management cluster access
source .env.rossoctl-hypershift-custom
oc get hostedclusters -n clusters
```

## Troubleshooting

### hcp CLI Not Found

```bash
# Add ~/.local/bin to PATH
export PATH="$HOME/.local/bin:$PATH"

# Check if installed
ls -la ~/.local/bin/hcp
```

### Ansible Collection Errors

```bash
ansible-galaxy collection install kubernetes.core amazon.aws community.general --force
```

### hypershift-automation Not Found

```bash
# Check the sibling directory (or $HYPERSHIFT_AUTOMATION_DIR)
ls -la ../hypershift-automation

# Re-run setup
../hypershift-cluster/scripts/local-setup.sh
```

### AWS Credentials Invalid

```bash
# Verify credentials work
source .env.rossoctl-hypershift-custom
aws sts get-caller-identity

# If using the wrong credentials (e.g., CI instead of admin)
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

### Management Cluster Access Denied

```bash
# Re-login to the management cluster
oc login <management-cluster-url>

# Re-run credentials setup
../hypershift-cluster/scripts/setup-hypershift-ci-credentials.sh
```

## Related Skills

- **hypershift-preflight**: Run full pre-flight checks
- **hypershift-cluster**: Create and destroy clusters
- **hypershift-quotas**: Check AWS quotas
