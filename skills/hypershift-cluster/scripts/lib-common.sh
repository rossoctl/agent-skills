#!/usr/bin/env bash
# lib-common.sh — shared colors and logging helpers for the hypershift scripts.
#
# Source via hypershift-lib.sh, not directly. Provides the four log helpers that
# nearly every hypershift script uses (→ ✓ ⚠ ✗). Scripts that need side effects
# in their logger (e.g. preflight-check.sh increments an ERRORS counter, the setup
# script exits on error) keep their own log_error and only rely on the colors here.
#
# Colors honor NO_COLOR (https://no-color.org): if NO_COLOR is set to any value,
# all escapes are emptied.

# Guard against double-sourcing.
if [ -n "${_HS_LIB_COMMON_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_HS_LIB_COMMON_SOURCED=1

if [ -n "${NO_COLOR:-}" ]; then
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
else
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  CYAN=$'\033[0;36m'
  NC=$'\033[0m'
fi
export RED GREEN YELLOW BLUE CYAN NC

# Standard logging helpers (no side effects). Scripts needing side effects define
# their own log_error/log_warn after sourcing.
log_info()    { echo -e "${BLUE}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
