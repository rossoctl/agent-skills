#!/usr/bin/env bash
# lib-env.sh — locate and load HyperShift credentials without assuming any repo
# layout.
#
# The original rossoctl scripts anchored the .env search on
# REPO_ROOT="$SCRIPT_DIR/../../.." (the rossoctl repo root). Inside an installed
# skill that path is meaningless, so credential discovery here is anchored on the
# caller's working directory ($PWD) plus an explicit override and a $HOME fallback.
#
# The common and preferred path is that the user has already sourced their
# .env file (so AWS_* and KUBECONFIG are exported); in that case callers skip
# file discovery entirely — see hs_creds_in_env below.
#
# Source via hypershift-lib.sh, not directly.

if [ -n "${_HS_LIB_ENV_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_HS_LIB_ENV_SOURCED=1

# hs_creds_in_env: return 0 if AWS creds + KUBECONFIG are already exported.
hs_creds_in_env() {
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] \
    && [ -n "${KUBECONFIG:-}" ]
}

# find_env_file: echo the path to a credentials .env file, or empty if none.
# Search order (first hit wins):
#   1. $HYPERSHIFT_ENV_FILE (explicit override)
#   2. $PWD/.env.${MANAGED_BY_TAG}
#   3. $PWD/.env.hypershift-ci   (legacy CI name)
#   4. first $PWD/.env.rossoctl-* match
#   5. $HOME/.config/hypershift/.env.${MANAGED_BY_TAG}
find_env_file() {
  local tag="${MANAGED_BY_TAG:-rossoctl-hypershift-custom}"

  if [ -n "${HYPERSHIFT_ENV_FILE:-}" ] && [ -f "$HYPERSHIFT_ENV_FILE" ]; then
    echo "$HYPERSHIFT_ENV_FILE"; return
  fi
  if [ -f "$PWD/.env.${tag}" ]; then
    echo "$PWD/.env.${tag}"; return
  fi
  if [ -f "$PWD/.env.hypershift-ci" ]; then
    echo "$PWD/.env.hypershift-ci"; return
  fi
  local match
  match=$(ls "$PWD"/.env.rossoctl-* 2>/dev/null | head -1)
  if [ -n "$match" ]; then
    echo "$match"; return
  fi
  if [ -f "$HOME/.config/hypershift/.env.${tag}" ]; then
    echo "$HOME/.config/hypershift/.env.${tag}"; return
  fi
  echo ""
}

# load_credentials: ensure AWS + KUBECONFIG are available. No-op if creds are
# already in the environment; otherwise sources a discovered .env file. Errors
# (exit 1) if nothing is found.
load_credentials() {
  local tag="${MANAGED_BY_TAG:-rossoctl-hypershift-custom}"

  if hs_creds_in_env; then
    MANAGED_BY_TAG="$tag"
    log_success "Using pre-sourced credentials from environment"
    return 0
  fi

  local env_file
  env_file=$(find_env_file)
  if [ -z "$env_file" ] || [ ! -f "$env_file" ]; then
    log_error "No credentials found. Either:"
    log_error "  1. Run: source .env.${tag}   (before this script), or"
    log_error "  2. Set HYPERSHIFT_ENV_FILE=/path/to/.env, or"
    log_error "  3. Run setup-hypershift-ci-credentials.sh to create one."
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$env_file"
  MANAGED_BY_TAG="${MANAGED_BY_TAG:-$tag}"
  log_success "Loaded credentials from $(basename "$env_file")"
}
