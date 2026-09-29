#!/usr/bin/env bash
#
# Destroy HyperShift Cluster
#
# Destroys an ephemeral OpenShift cluster created via HyperShift.
#
# USAGE:
#   scripts/destroy-cluster.sh <cluster-suffix-or-full-name>
#
# EXAMPLES:
#   scripts/destroy-cluster.sh ladas        # destroys rossoctl-hypershift-custom-ladas
#   scripts/destroy-cluster.sh pr529        # destroys rossoctl-hypershift-custom-pr529
#   scripts/destroy-cluster.sh rossoctl-hypershift-custom-ladas  # full name
#

set -euo pipefail

# Handle Ctrl+C properly - kill child processes only (not the terminal!)
cleanup() {
    echo ""
    echo -e "\033[0;31m✗ Interrupted! Killing child processes...\033[0m"
    # Kill only direct child processes, not the entire process group
    # Using pkill -P is safer than kill -$$ which can kill the terminal
    pkill -P $$ 2>/dev/null || true
    sleep 1
    pkill -9 -P $$ 2>/dev/null || true
    exit 130
}
trap cleanup SIGINT SIGTERM

# Detect CI mode
CI_MODE="${GITHUB_ACTIONS:-false}"

# Ensure ~/.local/bin is in PATH (where local-setup.sh installs hcp)
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/hypershift-lib.sh"

# Locate the hypershift-automation checkout (override, CI, sibling, or $HOME).
HYPERSHIFT_AUTOMATION_DIR=$(find_hypershift_automation_dir)

# Sanitized username for default cluster suffix
SANITIZED_USER=$(echo "${USER:-local}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-10)

MANAGED_BY_TAG="${MANAGED_BY_TAG:-rossoctl-hypershift-custom}"

# Require cluster name/suffix
if [ $# -lt 1 ]; then
    # Load credentials to get MANAGED_BY_TAG for dynamic help message
    ENV_FILE=$(find_env_file)
    if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
        # shellcheck source=/dev/null
        source "$ENV_FILE"
    fi
    echo "Usage: $0 <cluster-suffix-or-full-name>" >&2
    echo "Example: $0 ${SANITIZED_USER}           # destroys ${MANAGED_BY_TAG}-${SANITIZED_USER}" >&2
    echo "Example: $0 pr529               # destroys ${MANAGED_BY_TAG}-pr529" >&2
    exit 1
fi

CLUSTER_INPUT="$1"

# Colors and logging helpers come from lib-common.sh (sourced above).

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║           Destroy HyperShift Cluster                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================================
# 1. Load credentials
# ============================================================================

if [ "$CI_MODE" = "true" ]; then
    # CI mode: credentials arrive via environment variables from GitHub secrets
    # (MANAGED_BY_TAG, AWS_*, HCP_ROLE_NAME, KUBECONFIG in GITHUB_ENV).
    log_success "Using CI credentials from environment"
else
    # Local mode: use pre-sourced env creds, or discover a .env file (see lib-env.sh).
    load_credentials
fi

# Construct full cluster name if only suffix was provided
# If input starts with MANAGED_BY_TAG, use as-is; otherwise prefix it
if [[ "$CLUSTER_INPUT" == "${MANAGED_BY_TAG}-"* ]]; then
    CLUSTER_NAME="$CLUSTER_INPUT"
else
    CLUSTER_NAME="${MANAGED_BY_TAG}-${CLUSTER_INPUT}"
fi
echo "Cluster to destroy: $CLUSTER_NAME"
echo ""

# ============================================================================
# 2. Verify prerequisites
# ============================================================================

if [ ! -d "$HYPERSHIFT_AUTOMATION_DIR" ]; then
    if [ "$CI_MODE" = "true" ]; then
        echo "Error: hypershift-automation not found at $HYPERSHIFT_AUTOMATION_DIR" >&2
        echo "Ensure the clone step ran before this script." >&2
    else
        echo "Error: hypershift-automation not found at $HYPERSHIFT_AUTOMATION_DIR" >&2
    fi
    exit 1
fi

# Verify KUBECONFIG is set
if [ -z "${KUBECONFIG:-}" ]; then
    if [ "$CI_MODE" = "true" ]; then
        echo "Error: KUBECONFIG not set. Check the setup-credentials step." >&2
    else
        echo "Error: KUBECONFIG not set. Is .env.hypershift-ci properly configured?" >&2
    fi
    exit 1
fi

if [ ! -f "$KUBECONFIG" ]; then
    echo "Error: KUBECONFIG file not found at $KUBECONFIG" >&2
    if [ "$CI_MODE" != "true" ]; then
        echo "Re-run setup-hypershift-ci-credentials.sh to regenerate it." >&2
    fi
    exit 1
fi

log_success "Using management cluster kubeconfig: $KUBECONFIG"

# ============================================================================
# 3. Verify AWS credentials
# ============================================================================

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    echo "Error: AWS credentials not set. Check .env.hypershift-ci" >&2
    exit 1
fi

log_success "AWS credentials configured"

# ============================================================================
# 4. Pre-check: Handle already-stuck finalizers BEFORE ansible
# ============================================================================

# Check if HostedCluster exists and is already stuck in deletion
HC_EXISTS=$(oc get hostedcluster -n clusters "$CLUSTER_NAME" -o name 2>/dev/null || echo "")
DELETION_TS=$(oc get hostedcluster -n clusters "$CLUSTER_NAME" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")

if [ -n "$HC_EXISTS" ] && [ -n "$DELETION_TS" ]; then
    log_info "HostedCluster already marked for deletion (since $DELETION_TS)"
    log_info "Checking if AWS resources are already cleaned up..."

    # Use the debug script with --check mode to verify AWS cleanup
    if "$SCRIPT_DIR/debug-aws-hypershift.sh" --check "$CLUSTER_NAME"; then
        log_success "All AWS resources are already deleted"

        # Get current finalizers
        FINALIZERS=$(oc get hostedcluster -n clusters "$CLUSTER_NAME" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || echo "")

        if [ -n "$FINALIZERS" ] && [ "$FINALIZERS" != "null" ]; then
            log_info "Removing stuck finalizer (skipping ansible wait loops)..."
            oc patch hostedcluster -n clusters "$CLUSTER_NAME" \
                -p '{"metadata":{"finalizers":null}}' --type=merge
            log_success "Finalizer removed"

            # Wait for deletion
            log_info "Waiting for HostedCluster to be deleted..."
            for _ in {1..30}; do
                if ! oc get hostedcluster -n clusters "$CLUSTER_NAME" &>/dev/null; then
                    log_success "HostedCluster deleted"
                    break
                fi
                sleep 2
            done

            # Skip ansible if cluster is now gone
            if ! oc get hostedcluster -n clusters "$CLUSTER_NAME" &>/dev/null; then
                log_success "Cluster cleanup complete (finalizer was stuck, no ansible needed)"
                # Jump to local file cleanup
                SKIP_ANSIBLE=true
            fi
        fi
    else
        log_info "AWS resources still exist, proceeding with ansible destroy..."
    fi
fi

# ============================================================================
# 5. Destroy cluster via ansible (if needed)
# ============================================================================

if [ "${SKIP_ANSIBLE:-false}" != "true" ]; then
    # Check if cluster still exists
    if oc get hostedcluster -n clusters "$CLUSTER_NAME" &>/dev/null; then
        log_info "Destroying cluster '$CLUSTER_NAME' via ansible..."

        _prev_dir="$PWD"
        cd "$HYPERSHIFT_AUTOMATION_DIR"

        ansible-playbook site.yml \
            -e '{"create": false, "destroy": true, "create_iam": false}' \
            -e '{"iam": {"hcp_role_name": "'"$HCP_ROLE_NAME"'"}}' \
            -e '{"clusters": [{"name": "'"$CLUSTER_NAME"'", "region": "'"$AWS_REGION"'"}]}' || true

        cd "$_prev_dir"

        # Post-ansible check for stuck finalizers
        HC_EXISTS=$(oc get hostedcluster -n clusters "$CLUSTER_NAME" -o name 2>/dev/null || echo "")

        if [ -n "$HC_EXISTS" ]; then
            log_info "HostedCluster still exists after ansible, checking AWS resources..."

            if "$SCRIPT_DIR/debug-aws-hypershift.sh" --check "$CLUSTER_NAME"; then
                log_success "All AWS resources are deleted"

                FINALIZERS=$(oc get hostedcluster -n clusters "$CLUSTER_NAME" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || echo "")

                if [ -n "$FINALIZERS" ] && [ "$FINALIZERS" != "null" ]; then
                    log_info "Removing stuck finalizer..."
                    oc patch hostedcluster -n clusters "$CLUSTER_NAME" \
                        -p '{"metadata":{"finalizers":null}}' --type=merge
                    log_success "Finalizer removed"

                    log_info "Waiting for HostedCluster to be deleted..."
                    for _ in {1..30}; do
                        if ! oc get hostedcluster -n clusters "$CLUSTER_NAME" &>/dev/null; then
                            log_success "HostedCluster deleted"
                            break
                        fi
                        sleep 2
                    done
                fi
            else
                echo -e "${RED}✗${NC} AWS resources still exist. Manual cleanup may be required."
                echo ""
                echo "  Run full debug for details:"
                echo "  scripts/debug-aws-hypershift.sh $CLUSTER_NAME"
            fi
        fi
    else
        log_success "Cluster already deleted"
    fi
fi

# ============================================================================
# 5b. Cleanup orphaned AWS resources (even if HostedCluster is gone)
# ============================================================================
# This handles the case where HostedCluster was deleted but AWS resources remain
# due to async cleanup failures or permission issues.

log_info "Checking for orphaned AWS resources..."
if ! "$SCRIPT_DIR/debug-aws-hypershift.sh" --check "$CLUSTER_NAME"; then
    log_info "Orphaned AWS resources detected, running forced cleanup..."

    _prev_dir="$PWD"
    cd "$HYPERSHIFT_AUTOMATION_DIR"

    # Use cluster_exists=true to force ansible to run AWS cleanup
    # even though the HostedCluster doesn't exist
    ansible-playbook site.yml \
        -e '{"create": false, "destroy": true, "create_iam": false, "cluster_exists": true}' \
        -e '{"iam": {"hcp_role_name": "'"$HCP_ROLE_NAME"'"}}' \
        -e '{"clusters": [{"name": "'"$CLUSTER_NAME"'", "region": "'"$AWS_REGION"'"}]}' || true

    cd "$_prev_dir"

    # Verify cleanup
    if "$SCRIPT_DIR/debug-aws-hypershift.sh" --check "$CLUSTER_NAME"; then
        log_success "Orphaned AWS resources cleaned up"
    else
        echo -e "${RED}✗${NC} Some AWS resources still remain. Manual cleanup may be required."
        echo "  Run: scripts/debug-aws-hypershift.sh $CLUSTER_NAME"
    fi
else
    log_success "No orphaned AWS resources"
fi

# ============================================================================
# 6. Verify control plane namespace cleanup
# ============================================================================
# Note: The ansible playbook (hypershift-automation) handles namespace cleanup.
# This section just verifies it worked and warns if it didn't.

CONTROL_PLANE_NS="clusters-$CLUSTER_NAME"
if oc get ns "$CONTROL_PLANE_NS" &>/dev/null; then
    # Namespace still exists after ansible - warn but don't fail
    echo -e "${YELLOW}!${NC} Control plane namespace '$CONTROL_PLANE_NS' still exists after cleanup"
    echo "  This may indicate an issue with the hypershift-automation playbook."
    echo "  To manually clean up:"
    echo "    oc delete ns $CONTROL_PLANE_NS --wait=false"
    echo "    oc patch ns $CONTROL_PLANE_NS -p '{\"metadata\":{\"finalizers\":null}}' --type=merge"
else
    log_success "Control plane namespace already deleted"
fi

# ============================================================================
# 7. Cleanup local files
# ============================================================================

CLUSTER_DIR="$HOME/clusters/hcp/$CLUSTER_NAME"
if [ -d "$CLUSTER_DIR" ]; then
    log_info "Removing local cluster directory..."
    rm -rf "$CLUSTER_DIR"
    log_success "Removed $CLUSTER_DIR"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Cluster Destroyed                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================================
# 8. Release CI Slot (for parallel run coordination)
# ============================================================================
# Release the CI slot so other runs can use it.
# Uses CLUSTER_SUFFIX to find the slot (from holderIdentity).

SLOTS_DIR="$SCRIPT_DIR/ci/slots"
if [[ -d "$SLOTS_DIR" ]]; then
    echo "=== Releasing CI Slot ==="
    # Export CLUSTER_SUFFIX for release.sh to find the correct slot
    export CLUSTER_SUFFIX
    "$SLOTS_DIR/release.sh" || true
    echo ""
fi
