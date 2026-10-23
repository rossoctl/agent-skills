#!/usr/bin/env bash
# repo-sync: keep the enrolled repo clones current. Reads the enrolled set from
# ~/.repoman/repos.json, clones-if-missing / pulls-if-present each repo under
# $REPOS_DIR/<owner>/<name>/. Read-only toward GitHub. Per-repo failures are
# logged and non-fatal; every other failure is surfaced to the caller.
set -uo pipefail

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

usage() {
  cat <<'EOF'
Usage: repo-sync.sh [--refresh-skills] [--dry-run] [--help]

Sync enrolled repo clones (from ~/.repoman/repos.json) under
<repos_dir>/<owner>/<name>/. Clones if missing, pulls (--ff-only) if present.
Read-only toward GitHub. A per-repo clone/pull failure is logged and does not
abort the run.

  --refresh-skills   Also pull a local agent-skills clone. Setting the
                     REPOMAN_SKILLS_DIR env var alone also triggers this;
                     the var selects the clone path (default ~/agent-skills).
  --dry-run          Preview only: print whether each enrolled repo would be
                     cloned (missing) or pulled (present), touch nothing on
                     disk or GitHub, and exit 0. Side-effect-free.
  --help             Show this help and exit 0.
EOF
}

REFRESH_SKILLS=0
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --refresh-skills) REFRESH_SKILLS=1; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Fail-loud inputs (rc surfaced): config sets REPOS_DIR/FORK_OWNER; enrolled set.
# repo-sync only uses REPOS_DIR, but repoman_config also validates and exports
# FORK_OWNER as a required key, so this run inherits a dependency on a key it
# does not itself use. Tracked for v0.1.1 (rossoctl/automation#98): let callers
# validate only the config keys they need.
repoman_config || exit 1
ENROLLED=$(repoman_get_repos) || exit 1

pulled=0; cloned=0; failed=0; enrolled=0
failures=""

# valid_slug SLUG — true if SLUG is a safe single path segment for an owner or
# repo name. repos.json is external input; an entry like "../../etc" or an
# absolute path would let a clone/mkdir escape the repos_dir tree. Restrict to
# GitHub-legal characters ([A-Za-z0-9._-]) and reject empty or "." / ".."
# (a "." component would still resolve inside the tree but is never a real repo,
# and ".." escapes it). Slashes cannot appear: they are already consumed by the
# owner/name split, so a "name" of "../../escape" arrives here as "../../escape"
# and is rejected for the ".." components and the "/" it still contains.
valid_slug() {
  local s="$1"
  case "$s" in
    ""|"."|"..") return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;  # any char outside the safe set (incl. "/")
  esac
  return 0
}

# Scratch file for capturing a per-repo git command's stderr, so its one-line
# error can be attached to that repo's summary entry (fail-loud: check mktemp's rc).
giterr=$(mktemp) || { echo "ERROR: mktemp failed" >&2; exit 1; }
trap 'rm -f "$giterr"' EXIT

# git_error_line FILE — print the one line of git's stderr that names the cause.
# git writes progress first ("Cloning into '...'", "From https://...") and the
# actual "fatal:"/"error:"/"remote:" line last, so head -n1 would grab the
# useless progress line. Prefer the last fatal/error/remote line; fall back to
# the last non-empty line; finally the first line. Never fails (display only).
git_error_line() {
  local f="$1" line=""
  line=$(grep -iE '^(fatal|error|remote):' "$f" 2>/dev/null | tail -n1)
  if [ -z "$line" ]; then
    line=$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -n1)
  fi
  if [ -z "$line" ]; then
    line=$(head -n1 "$f" 2>/dev/null)
  fi
  printf '%s' "$line"
}

while IFS= read -r full; do
  [ -n "$full" ] || continue
  enrolled=$((enrolled + 1))
  owner="${full%%/*}"; name="${full#*/}"
  # Reject path-traversal / unsafe entries before any mkdir/clone touches the
  # filesystem. Counted failed and named, like any other per-repo failure.
  if ! valid_slug "$owner" || ! valid_slug "$name"; then
    failed=$((failed + 1)); failures="$failures  $full (invalid owner/name)"$'\n'
    continue
  fi
  dir="$REPOS_DIR/$owner/$name"
  if [ -d "$dir/.git" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo "[DRY RUN] would pull $full (present at $dir)"; pulled=$((pulled + 1)); continue
    fi
    if git -C "$dir" pull --ff-only 2>"$giterr"; then
      pulled=$((pulled + 1))
    else
      msg=$(git_error_line "$giterr")
      failed=$((failed + 1)); failures="$failures  $full (pull): $msg"$'\n'
    fi
  else
    if [ "$DRY_RUN" = true ]; then
      echo "[DRY RUN] would clone $full -> $dir"; cloned=$((cloned + 1)); continue
    fi
    if ! mkdir -p "$REPOS_DIR/$owner"; then
      failed=$((failed + 1)); failures="$failures  $full (mkdir failed)"$'\n'
      continue
    fi
    if git clone "https://github.com/$owner/$name.git" "$dir" 2>"$giterr"; then
      cloned=$((cloned + 1))
    else
      msg=$(git_error_line "$giterr")
      failed=$((failed + 1)); failures="$failures  $full (clone): $msg"$'\n'
    fi
  fi
done <<< "$ENROLLED"

echo "repo-sync: pulled $pulled cloned $cloned failed $failed"
if [ "$failed" -gt 0 ]; then
  echo "failed repos:"
  printf '%s' "$failures"
fi

# Exit model: a per-repo failure is non-fatal so a single bad repo does not
# abort the sync of the rest. But if EVERY enrolled repo failed, the run
# accomplished nothing and must not report success -- that signals a systemic
# fault (bad config, network down, all clones broken), not one flaky repo.
rc=0
if [ "$enrolled" -gt 0 ] && [ "$failed" -eq "$enrolled" ]; then
  echo "ERROR: all $enrolled enrolled repos failed to sync" >&2
  rc=1
fi

# --- optional skills refresh (opt-in; fatal on failure; no bootstrap-clone) ---
# Two triggers, per spec: the --refresh-skills flag, OR a set REPOMAN_SKILLS_DIR
# (the flag wins if both are given, but either alone opts in). Setting the env
# var alone must not be a silent no-op, so it triggers the refresh here too.
if [ "$REFRESH_SKILLS" -eq 1 ] || [ -n "${REPOMAN_SKILLS_DIR:-}" ]; then
  skills_dir="${REPOMAN_SKILLS_DIR:-$HOME/agent-skills}"
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] would refresh skills clone at $skills_dir"
  elif [ -d "$skills_dir/.git" ]; then
    if git -C "$skills_dir" pull --ff-only; then
      echo "repo-sync: refreshed skills clone at $skills_dir"
    else
      echo "ERROR: skills refresh failed: git pull in $skills_dir" >&2
      rc=1
    fi
  else
    # Trigger-neutral wording: the refresh may have been requested by either the
    # flag or the env var, so name neither.
    echo "ERROR: skills refresh requested but no skills clone at $skills_dir" >&2
    echo "  (repo-sync does not bootstrap the skills clone; create it first)" >&2
    rc=1
  fi
fi
exit "$rc"
