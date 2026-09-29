#!/usr/bin/env bash
# hypershift-lib.sh — thin aggregator that sources the flat lib-*.sh modules.
#
# Every hypershift script sources THIS file (not the individual modules):
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/hypershift-lib.sh"
#
# Modeled on rossoctl/automation's scripts/program-lib.sh: resolve this file's
# own directory, then source each sibling module from there. This keeps the
# scripts self-contained and free of the old REPO_ROOT="$SCRIPT_DIR/../../.."
# assumption.

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$_LIB_DIR/lib-common.sh"
# shellcheck source=/dev/null
source "$_LIB_DIR/lib-env.sh"
# shellcheck source=/dev/null
source "$_LIB_DIR/lib-preflight.sh"
# shellcheck source=/dev/null
source "$_LIB_DIR/lib-automation.sh"
