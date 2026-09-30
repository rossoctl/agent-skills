#!/usr/bin/env bash
# lib-preflight.sh — lightweight capability guards reused across the hypershift
# scripts (binary presence, AWS auth, OpenShift auth, kubeconfig).
#
# These are the inline checks that check-quotas.sh, cleanup-stale-clusters.sh and
# debug-aws-hypershift.sh each duplicated. preflight-check.sh keeps its own richer,
# individually-reported checks — it does not use these.
#
# Source via hypershift-lib.sh, not directly.

if [ -n "${_HS_LIB_PREFLIGHT_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_HS_LIB_PREFLIGHT_SOURCED=1

# require_bins bin1 bin2 ...: exit 1 if any binary is missing from PATH.
require_bins() {
  local missing=()
  local b
  for b in "$@"; do
    command -v "$b" &>/dev/null || missing+=("$b")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Missing required tools: ${missing[*]}"
    log_error "Install them, or run the hypershift-preflight skill for guidance."
    exit 1
  fi
}

# require_aws_auth: exit 1 unless AWS credentials resolve.
require_aws_auth() {
  require_bins aws
  if ! aws sts get-caller-identity &>/dev/null; then
    log_error "AWS not authenticated. Set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY"
    log_error "or source your .env file, then retry."
    exit 1
  fi
}

# require_oc_auth: exit 1 unless oc is present and logged in.
require_oc_auth() {
  require_bins oc
  if ! oc whoami &>/dev/null; then
    log_error "Not logged into an OpenShift cluster (oc whoami failed)."
    log_error "Run: oc login <management-cluster-url>"
    exit 1
  fi
}

# require_kubeconfig: exit 1 unless KUBECONFIG points at an existing file.
require_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ] || [ ! -f "${KUBECONFIG:-}" ]; then
    log_error "KUBECONFIG is unset or points to a missing file: ${KUBECONFIG:-<unset>}"
    log_error "Source your .env file (it exports KUBECONFIG) and retry."
    exit 1
  fi
}
