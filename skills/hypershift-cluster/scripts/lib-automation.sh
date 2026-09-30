#!/usr/bin/env bash
# lib-automation.sh — locate the hypershift-automation clone.
#
# create-cluster.sh / destroy-cluster.sh drive ansible playbooks that live in a
# separate hypershift-automation repository. The original scripts found it as a
# sibling of the rossoctl repo root (with worktree-aware fallbacks). Inside a
# skill there is no repo root, so discovery is anchored on an override, the CI
# location, then $PWD and $HOME.
#
# Source via hypershift-lib.sh, not directly.

if [ -n "${_HS_LIB_AUTOMATION_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_HS_LIB_AUTOMATION_SOURCED=1

# find_hypershift_automation_dir: echo the hypershift-automation directory path,
# or empty if not found. Search order (first hit wins):
#   1. $HYPERSHIFT_AUTOMATION_DIR (explicit override)
#   2. /tmp/hypershift-automation  (when GITHUB_ACTIONS=true — CI clones here)
#   3. $PWD/../hypershift-automation (sibling of the working dir)
#   4. $HOME/hypershift-automation
find_hypershift_automation_dir() {
  if [ -n "${HYPERSHIFT_AUTOMATION_DIR:-}" ] && [ -d "$HYPERSHIFT_AUTOMATION_DIR" ]; then
    echo "$HYPERSHIFT_AUTOMATION_DIR"; return
  fi
  if [ "${GITHUB_ACTIONS:-false}" = "true" ] && [ -d "/tmp/hypershift-automation" ]; then
    echo "/tmp/hypershift-automation"; return
  fi
  local sibling
  sibling="$(cd "$PWD/.." 2>/dev/null && pwd)/hypershift-automation"
  if [ -d "$sibling" ]; then
    echo "$sibling"; return
  fi
  if [ -d "$HOME/hypershift-automation" ]; then
    echo "$HOME/hypershift-automation"; return
  fi
  echo ""
}
