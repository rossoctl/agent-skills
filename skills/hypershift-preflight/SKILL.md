---
name: hypershift-preflight
description: >-
  Run pre-flight checks for HyperShift: verifies tools, AWS auth and IAM
  permissions, OpenShift auth and permissions, HyperShift install, operator OIDC,
  pull secret, base domain, and Route53 zone. Use when preparing for first-time
  setup, when a cluster fails to create, or when verifying the environment after
  changes.
license: Complete terms in LICENSE.txt
metadata: {"openclaw": {"requires": {"bins": ["bash", "aws", "oc", "jq"]}}}
---

# HyperShift Pre-flight Check Skill

Verify all prerequisites for HyperShift cluster provisioning before running setup
or creating clusters.

The `preflight-check.sh` script lives in `../hypershift-cluster/scripts/`.

## When to Use

- Before first-time HyperShift setup
- Troubleshooting failed cluster creation
- Verifying the environment after changes
- User asks "check hypershift prereqs" or "why won't cluster create"

## Quick Check

```bash
# Run all pre-flight checks
../hypershift-cluster/scripts/preflight-check.sh
```

## What It Checks

### 1. Tools for Setup
- `jq` - JSON processor
- `aws` - AWS CLI
- `oc` - OpenShift CLI

### 2. Tools for Cluster Creation
- `hcp` - HyperShift CLI (optional, installed by local-setup.sh)
- `ansible-playbook` - Ansible automation
- `ansible-galaxy` - Ansible collection manager

### 3. AWS Authentication
- AWS credentials configured
- Identity accessible

### 4. AWS IAM Permissions
- Can create IAM policies
- Can create IAM roles
- Not using CI credentials (needs admin for setup)

### 5. OpenShift Authentication
- Logged into the management cluster
- Server accessible

### 6. OpenShift Permissions
- Can create ClusterRoles
- Can create ClusterRoleBindings
- Can read secrets in the openshift-config namespace

### 7. HyperShift Installation
- HyperShift CRD exists on the management cluster

### 8. HyperShift Operator OIDC
- Operator has OIDC S3 configuration
- Required for AWS hosted clusters

### 9. Pull Secret
- Can access pull secret in openshift-config
- Pull secret is valid JSON
- Registry count verified

### 10. Base Domain
- Auto-detects from ingress config
- Falls back to existing hosted clusters

### 11. Route53 Hosted Zone
- Public hosted zone exists for base domain
- Required for DNS resolution

## Expected Output (Success)

```
╔════════════════════════════════════════════════════════════════╗
║           HyperShift CI Pre-flight Check                       ║
╚════════════════════════════════════════════════════════════════╝

→ Checking tools for setup...
✓ jq: jq-1.7.1
✓ aws: aws-cli/2.x.x
✓ oc: Client Version: 4.x.x

→ Checking tools for cluster creation...
✓ hcp: v4.x.x
✓ ansible-playbook: ansible-playbook 2.x.x
✓ ansible-galaxy: available

→ Checking AWS authentication...
✓ AWS authenticated: arn:aws:iam::xxx:user/xxx

→ Checking AWS IAM permissions for setup...
✓ AWS identity: arn:aws:iam::xxx:user/xxx
✓ AWS IAM: Can create policies
✓ AWS IAM: Can create roles

→ Checking OpenShift authentication...
✓ OpenShift authenticated: xxx @ https://xxx

→ Checking OpenShift permissions...
✓ Can create ClusterRoles
✓ Can create ClusterRoleBindings
✓ Can read secrets in openshift-config namespace

→ Checking HyperShift installation...
✓ HyperShift CRD found - HyperShift is installed

→ Checking HyperShift operator OIDC configuration...
✓ HyperShift operator has OIDC S3 configured

→ Checking pull secret accessibility...
✓ Pull secret valid (5 registries configured)

→ Checking base domain discovery...
✓ Base domain: octo-emerging.redhataicoe.com

→ Checking Route53 public hosted zone...
✓ Route53 public hosted zone found

╔════════════════════════════════════════════════════════════════╗
║  All checks passed! Ready to run setup script.                 ║
╚════════════════════════════════════════════════════════════════╝
```

## Common Errors and Fixes

### Missing Tools

```bash
# Install jq
brew install jq  # macOS
sudo apt install jq  # Ubuntu

# Install AWS CLI
# https://aws.amazon.com/cli/

# Install oc
# https://mirror.openshift.com/pub/openshift-v4/clients/ocp/

# Install ansible
pip install ansible-core
```

### AWS Not Authenticated

```bash
# Configure AWS credentials
aws configure

# Or set environment variables
export AWS_ACCESS_KEY_ID="xxx"
export AWS_SECRET_ACCESS_KEY="xxx"
export AWS_REGION="us-east-1"
```

### Using CI Credentials Instead of Admin

```bash
# Error: Logged in as CI user. Setup requires IAM admin.

# Fix: Unset CI credentials
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

# Use your admin profile
aws configure list
```

### OpenShift Not Logged In

```bash
# Login to the management cluster
oc login https://api.<management-cluster>:6443

# Verify
oc whoami
oc whoami --show-server
```

### HyperShift Not Installed

```
Error: HyperShift CRD not found.
```

The management cluster does not have HyperShift installed. Contact the cluster
admin or use a different management cluster.

### HyperShift Operator Missing OIDC

```
Error: HyperShift operator MISSING OIDC S3 configuration!
```

The operator was upgraded and lost OIDC config. Follow the fix instructions in the
preflight output (requires cluster-admin).

### No Public Route53 Zone

```
Error: No PUBLIC Route53 hosted zone found for xxx
```

HyperShift requires a public hosted zone for DNS. Either:
1. Create a public hosted zone in Route53
2. Update BASE_DOMAIN in the .env file to match an existing zone

## Manual Checks

### Check AWS Identity

```bash
aws sts get-caller-identity
```

### Check OpenShift Permissions

```bash
oc auth can-i create clusterroles
oc auth can-i create clusterrolebindings
oc auth can-i get secrets -n openshift-config
```

### Check HyperShift CRD

```bash
oc get crd hostedclusters.hypershift.openshift.io
```

### Check Operator OIDC Args

```bash
oc get deployment operator -n hypershift \
    -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep oidc
```

### Check Route53 Zones

```bash
aws route53 list-hosted-zones \
    --query "HostedZones[?Config.PrivateZone==\`false\`].Name" \
    --output table
```

## Next Steps After Preflight

If all checks pass:

```bash
# Set up credentials (first time only)
../hypershift-cluster/scripts/setup-hypershift-ci-credentials.sh

# Set up local tools
../hypershift-cluster/scripts/local-setup.sh

# Create a cluster
../hypershift-cluster/scripts/create-cluster.sh
```

## Related Skills

- **hypershift-setup**: Set up the local environment
- **hypershift-cluster**: Create and destroy clusters
- **hypershift-quotas**: Check AWS quotas
