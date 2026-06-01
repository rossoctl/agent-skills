#!/usr/bin/env bash
# Shared infrastructure for kagenti automation programs (scanner/fixer pattern).
#
# Source this file at the top of program scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/program-lib.sh"
#
# Prerequisites: jq, gh (GitHub CLI), coreutils (comm, sort, wc, mktemp)

# =============================================================================
# WORKSPACE MANAGEMENT
# =============================================================================

# Create a temp directory and register automatic cleanup on script exit.
# After calling this, use $PROGRAM_TMPDIR for all temp files.
#
# Usage: setup_workspace "link-fixer"
# Args:
#   $1 - prefix for the temp directory name (default: "program")
setup_workspace() {
  local prefix="${1:-program}"

  PROGRAM_TMPDIR=$(mktemp -d "/tmp/${prefix}-XXXXXX")
  # Automatic cleanup: remove the temp dir when the script exits
  trap 'rm -rf "$PROGRAM_TMPDIR"' EXIT
}

# Generate a unique scan ID for today in the format YYYY-MM-DD-NNN.
# The sequence number (NNN) increments based on how many scans already
# ran today (read from history.json). This prevents ID collisions when
# a scanner is triggered multiple times in one day.
#
# Usage: SCAN_ID=$(generate_scan_id "$REPORTS_DIR" "2026-05-21")
# Args:
#   $1 - path to the reports directory (must contain history.json)
#   $2 - today's date in YYYY-MM-DD format
# Prints: the scan ID (e.g., "2026-05-21-002")
generate_scan_id() {
  local reports_dir="$1"
  local scan_date="$2"
  local last_seq=0

  # Count how many scans already happened today
  if [ -f "$reports_dir/history.json" ]; then
    last_seq=$(jq -r \
      --arg date "$scan_date" \
      '[.[] | select(.scan_id | startswith($date))] | length' \
      "$reports_dir/history.json")
  fi

  # Zero-padded sequence number
  printf "%s-%03d" "$scan_date" $((last_seq + 1))
}

# =============================================================================
# PATH VALIDATION
# =============================================================================

# Validate that REPOS_DIR is set and not pointing to a dangerous path.
# Rejects root filesystem paths, system directories, and $HOME itself
# (without a subdirectory). Intended to prevent accidental scanning or
# modification of system files.
#
# Usage: validate_repos_dir "$REPOS_DIR"
# Args:
#   $1 - the repos directory path to validate
# Returns: 0 if valid, exits with error message if invalid
validate_repos_dir() {
  local path="$1"

  if [ -z "$path" ]; then
    echo "ERROR: REPOS_DIR is not set." >&2
    echo "Export it to the directory containing your org's cloned repos:" >&2
    echo "  export REPOS_DIR=~/my-org" >&2
    exit 1
  fi

  # Resolve to absolute path for comparison
  local resolved
  resolved=$(cd "$path" 2>/dev/null && pwd) || resolved="$path"

  # Reject obviously dangerous paths
  local dangerous_paths=("/" "/etc" "/usr" "/var" "/sys" "/proc" "/bin" "/sbin" "/lib" "/tmp")
  for dangerous in "${dangerous_paths[@]}"; do
    if [ "$resolved" = "$dangerous" ]; then
      echo "ERROR: REPOS_DIR cannot be '$resolved' -- this is a system directory." >&2
      exit 1
    fi
  done

  # Reject $HOME itself (must be a subdirectory)
  if [ "$resolved" = "$HOME" ]; then
    echo "ERROR: REPOS_DIR cannot be your home directory itself." >&2
    echo "Use a subdirectory, e.g.: export REPOS_DIR=~/my-org" >&2
    exit 1
  fi

  # Check the directory exists
  if [ ! -d "$path" ]; then
    echo "ERROR: REPOS_DIR '$path' does not exist." >&2
    echo "Create it and clone your org's repos there, or set REPOS_DIR to an existing directory." >&2
    exit 1
  fi

  return 0
}

# =============================================================================
# ISSUE BODY VALIDATION
# =============================================================================

# Validate fields extracted from a scanner-created issue body.
# Returns 0 if all fields pass validation, 1 if any field is malformed.
# This prevents injection via crafted issue bodies.
#
# Usage:
#   if ! validate_issue_fields "$issue_repo" "$issue_file" "$broken_url" "$http_status" "$category"; then
#     echo "WARN: Skipping issue with malformed fields"
#     continue
#   fi
#
# Args:
#   $1 - repo field (expected: org/repo format)
#   $2 - file field (expected: relative path, no ..)
#   $3 - url field (expected: http:// or https://)
#   $4 - status field (expected: numeric or known text)
#   $5 - category field (expected: internal, external, or relative)
# Returns: 0 if valid, 1 if any field fails (prints warning to stderr)
validate_issue_fields() {
  local repo="$1"
  local file="$2"
  local url="$3"
  local status="$4"
  local category="$5"

  # Repo must match org/repo pattern
  if ! echo "$repo" | grep -qE '^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$'; then
    echo "  WARN: Invalid repo field: '$repo'" >&2
    return 1
  fi

  # File must not contain path traversal or shell metacharacters
  if echo "$file" | grep -qE '(\.\./|[;$`|&<>])'; then
    echo "  WARN: Invalid file field (contains unsafe characters): '$file'" >&2
    return 1
  fi

  # URL must start with http:// or https://
  if ! echo "$url" | grep -qE '^https?://'; then
    echo "  WARN: Invalid URL field (not http/https): '$url'" >&2
    return 1
  fi

  # Status must be numeric or a known enum token
  if ! echo "$status" | grep -qE '^([0-9]{3}|unknown|timeout|dns|unreachable|error)$'; then
    echo "  WARN: Invalid status field: '$status'" >&2
    return 1
  fi

  # Category must be a known value
  if ! echo "$category" | grep -qE '^(internal|external|relative)$'; then
    echo "  WARN: Invalid category field: '$category'" >&2
    return 1
  fi

  return 0
}

# =============================================================================
# PATH-SUFFIX SCORING
# =============================================================================

# Score a candidate path against a broken path by counting shared leading
# path segments (case-insensitive prefix match). This prioritizes candidates
# that share the most directory context with the broken URL, which best
# identifies where a renamed/moved file ended up.
#
# Example:
#   score_path_suffix "authbridge/cmd/authbridge/README.md" "authbridge/cmd/README.md"
#   # prints: 2 (shared prefix: authbridge/cmd)
#
# Args:
#   $1 - broken path (the original path from the URL)
#   $2 - candidate path (a found file)
# Prints: integer score (number of shared leading segments, 0 if none match)
score_path_suffix() {
  local broken_path="$1"
  local candidate_path="$2"

  # Lowercase both for case-insensitive comparison
  local broken_lower candidate_lower
  broken_lower=$(printf '%s' "$broken_path" | tr '[:upper:]' '[:lower:]')
  candidate_lower=$(printf '%s' "$candidate_path" | tr '[:upper:]' '[:lower:]')

  # Split paths into arrays by "/"
  IFS='/' read -ra broken_parts <<< "$broken_lower"
  IFS='/' read -ra candidate_parts <<< "$candidate_lower"

  local broken_len=${#broken_parts[@]}
  local candidate_len=${#candidate_parts[@]}
  local max_compare=$((broken_len < candidate_len ? broken_len : candidate_len))
  local score=0

  # Count shared leading segments
  local i
  for ((i = 0; i < max_compare; i++)); do
    if [ "${broken_parts[$i]}" = "${candidate_parts[$i]}" ]; then
      score=$((score + 1))
    else
      break
    fi
  done

  echo "$score"
}

# Given a broken path and a newline-separated list of candidates, find the
# best match by path-prefix score. Prints the winning candidate if there's
# a unique top scorer with score >= min_score; prints nothing otherwise.
#
# Usage:
#   winner=$(pick_best_candidate "$target_path" "$candidates" 1)
#
# Args:
#   $1 - broken path (from URL)
#   $2 - newline-separated candidate paths
#   $3 - minimum score threshold (default: 1)
# Prints: best candidate path if unique winner, empty if tied or below threshold
# Returns: 0 if unique winner found, 1 otherwise
pick_best_candidate() {
  local broken_path="$1"
  local candidates="$2"
  local min_score="${3:-1}"

  local best_score=0
  local best_candidate=""
  local tied=false

  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    local score
    score=$(score_path_suffix "$broken_path" "$candidate")

    if [ "$score" -gt "$best_score" ]; then
      best_score=$score
      best_candidate="$candidate"
      tied=false
    elif [ "$score" -eq "$best_score" ] && [ "$score" -gt 0 ]; then
      tied=true
    fi
  done <<< "$candidates"

  if [ "$best_score" -ge "$min_score" ] && [ "$tied" = false ] && [ -n "$best_candidate" ]; then
    echo "$best_candidate"
    return 0
  fi

  return 1
}

# =============================================================================
# DIFF LOGIC
# =============================================================================

# Compare current findings against a previous scan to determine what's new,
# what's fixed, and what's recurring. Uses set operations (comm) on sorted keys.
#
# After calling, three files are available in $PROGRAM_TMPDIR:
#   new_keys.txt       - items in current but not previous (just appeared)
#   fixed_keys.txt     - items in previous but not current (resolved)
#   recurring_keys.txt - items in both (still broken)
#
# Usage:
#   read -r new fixed recurring < <(diff_against_previous \
#     "$TMPDIR/current.jsonl" "$TMPDIR/prev.jsonl" '[.repo, .file, .url] | join("|")')
#
# Args:
#   $1 - path to current findings file (JSONL, one JSON object per line)
#   $2 - path to previous findings file (JSONL)
#   $3 - jq expression that extracts the comparison key from each object
#         (must produce a single string per line)
# Prints: three space-separated counts: "NEW FIXED RECURRING"
diff_against_previous() {
  local current_file="$1"
  local prev_file="$2"
  local key_expr="$3"

  # Extract and sort keys from both files
  jq -r "$key_expr" "$current_file" | sort > "$PROGRAM_TMPDIR/current_keys.txt"
  jq -r "$key_expr" "$prev_file"    | sort > "$PROGRAM_TMPDIR/prev_keys.txt"

  # Set operations using comm:
  #   comm -23 = lines only in file 1 (new items)
  #   comm -13 = lines only in file 2 (fixed items)
  #   comm -12 = lines in both files (recurring)
  comm -23 "$PROGRAM_TMPDIR/current_keys.txt" "$PROGRAM_TMPDIR/prev_keys.txt" \
    > "$PROGRAM_TMPDIR/new_keys.txt"

  comm -13 "$PROGRAM_TMPDIR/current_keys.txt" "$PROGRAM_TMPDIR/prev_keys.txt" \
    > "$PROGRAM_TMPDIR/fixed_keys.txt"

  comm -12 "$PROGRAM_TMPDIR/current_keys.txt" "$PROGRAM_TMPDIR/prev_keys.txt" \
    > "$PROGRAM_TMPDIR/recurring_keys.txt"

  # Count each set
  local new_count
  local fixed_count
  local recurring_count
  new_count=$(wc -l < "$PROGRAM_TMPDIR/new_keys.txt" | tr -d ' ')
  fixed_count=$(wc -l < "$PROGRAM_TMPDIR/fixed_keys.txt" | tr -d ' ')
  recurring_count=$(wc -l < "$PROGRAM_TMPDIR/recurring_keys.txt" | tr -d ' ')

  echo "$new_count $fixed_count $recurring_count"
}

# =============================================================================
# GITHUB ISSUES
# =============================================================================

# Check if an open issue already exists that matches a search query.
# Used for deduplication before creating new issues.
#
# Usage:
#   if existing=$(gh_issue_exists "kagenti/adk" "Broken link in README.md"); then
#     echo "Issue #$existing already open"
#   fi
#
# Args:
#   $1 - full repo name (e.g., "kagenti/adk")
#   $2 - search string (matched against issue title/body by GitHub)
# Returns: 0 if found (prints issue number), 1 if not found
gh_issue_exists() {
  local repo="$1"
  local search="$2"
  local result

  result=$(gh issue list \
    --repo "$repo" \
    --search "$search" \
    --state open \
    --json number \
    --jq '.[0].number' \
    2>/dev/null || echo "")

  if [ -n "$result" ] && [ "$result" != "null" ]; then
    echo "$result"
    return 0
  fi

  return 1
}

# Close an issue with a comment. Checks the exit code of `gh issue close`
# before reporting success -- this prevents the "close-before-verify" bug
# where we'd claim an issue was closed when the API call actually failed.
#
# Usage:
#   if close_issue_if_valid "kagenti/adk" "123" "Fixed in scan 2026-05-21-001."; then
#     echo "Closed"
#   fi
#
# Args:
#   $1 - full repo name
#   $2 - issue number
#   $3 - comment to add when closing
# Returns: 0 on success, 1 on failure (prints warning to stderr)
close_issue_if_valid() {
  local repo="$1"
  local number="$2"
  local comment="$3"

  if gh issue close "$number" --repo "$repo" --comment "$comment" 2>/dev/null; then
    return 0
  fi

  echo "  WARN: Failed to close issue #$number in $repo" >&2
  return 1
}

# Returns 0 if any open PR in $repo plausibly covers $issue_number.
# Prints the covering PR number on stdout when found (for logging).
#
# Uses a three-layer detection strategy:
#   Layer 1: GraphQL closingIssuesReferences (keyword-agnostic, author-agnostic)
#   Layer 2: Keyword text search across all authors (close/fix/resolve variants)
#   Layer 3: File + URL overlap in PR diffs (catches unlisted but covered issues)
#
# Args:
#   $1 - full repo name (e.g., "kagenti/adk")
#   $2 - issue number
#   $3 - (optional) source file path from the issue body
#   $4 - (optional) broken URL from the issue body
# Returns: 0 if covered, 1 otherwise
issue_has_open_pr() {
  local repo="$1"
  local issue_number="$2"
  local source_file="${3:-}"
  local broken_url="${4:-}"
  local owner="${repo%/*}"
  local repo_name="${repo#*/}"
  local pr_number

  # Layer 1: GraphQL closingIssuesReferences (cheapest, most authoritative)
  pr_number=$(gh api graphql -f query='
    query($owner:String!, $repo:String!, $num:Int!) {
      repository(owner:$owner, name:$repo) {
        issue(number:$num) {
          closedByPullRequestsReferences(first:5, includeClosedPrs:false) {
            nodes { number state }
          }
        }
      }
    }' \
    -F owner="$owner" -F repo="$repo_name" -F num="$issue_number" \
    --jq '.data.repository.issue.closedByPullRequestsReferences.nodes[] | select(.state == "OPEN") | .number' \
    2>/dev/null | head -1)

  if [ -n "$pr_number" ]; then
    echo "$pr_number"
    return 0
  fi

  # Layer 2: Keyword search fallback (broader text match, all authors)
  pr_number=$(gh pr list --repo "$repo" --state open \
    --search "#$issue_number" \
    --json number,body \
    --jq ".[] | select(.body | test(\"(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\\\s+#$issue_number\")) | .number" \
    2>/dev/null | head -1)

  if [ -n "$pr_number" ]; then
    echo "$pr_number"
    return 0
  fi

  # Layer 3: File + URL overlap (only when source_file and broken_url provided)
  if [ -n "$source_file" ] && [ -n "$broken_url" ]; then
    local pr_numbers
    pr_numbers=$(gh pr list --repo "$repo" --state open \
      --json number,files \
      --jq ".[] | select(.files[]?.path == \"$source_file\") | .number" \
      2>/dev/null)

    local candidate_pr
    local escaped_url
    escaped_url=$(printf '%s' "$broken_url" | sed -E 's/[.[\*^$()+?{|]/\\&/g')

    while IFS= read -r candidate_pr; do
      [ -z "$candidate_pr" ] && continue
      if gh pr diff "$candidate_pr" --repo "$repo" 2>/dev/null \
        | grep -q "^-.*$escaped_url"; then
        echo "$candidate_pr"
        return 0
      fi
    done <<< "$pr_numbers"
  fi

  return 1
}

# =============================================================================
# REPORTS
# =============================================================================

# Overwrite latest.json with the provided JSON content.
# Creates the reports directory if it doesn't exist.
#
# Usage:
#   write_report_latest "$REPORTS_DIR" "$json_string"
#
# Args:
#   $1 - path to the reports directory
#   $2 - JSON content to write (as a string)
#   $3 - (optional) filename (default: "latest.json")
write_report_latest() {
  local reports_dir="$1"
  local content="$2"
  local filename="${3:-latest.json}"

  mkdir -p "$reports_dir"
  printf '%s\n' "$content" > "$reports_dir/$filename"
}

# Append a row to history.json, keeping the file under a maximum row count.
# If history.json doesn't exist or is empty, initializes it as a JSON array.
# Oldest entries are trimmed when the cap is exceeded.
#
# Usage:
#   append_history_row "$REPORTS_DIR" "$history_row_json" 500
#   append_history_row "$REPORTS_DIR" "$row" 500 "fixer-history.json"
#
# Args:
#   $1 - path to the reports directory
#   $2 - JSON object to append (as a string, e.g., '{"scan_id":"...","date":"..."}')
#   $3 - maximum number of rows to keep (default: 500)
#   $4 - (optional) filename (default: "history.json")
append_history_row() {
  local reports_dir="$1"
  local row="$2"
  local max_rows="${3:-500}"
  local filename="${4:-history.json}"

  mkdir -p "$reports_dir"

  local history_file="$reports_dir/$filename"

  # If history file exists and is non-empty, append and trim
  if [ -f "$history_file" ] && [ -s "$history_file" ]; then
    local tmp_file="$PROGRAM_TMPDIR/history_new.json"

    jq \
      --argjson row "$row" \
      --argjson cap "$max_rows" \
      '. + [$row] | if length > $cap then .[-$cap:] else . end' \
      "$history_file" > "$tmp_file"

    mv "$tmp_file" "$history_file"
  else
    # Initialize as a single-element array
    echo "[$row]" > "$history_file"
  fi
}

# =============================================================================
# FORK / PR MANAGEMENT
# =============================================================================

# Ensure a fork of the target repo exists under the fork owner's account.
# If the fork doesn't exist, creates it and waits briefly for GitHub to
# propagate it (forks are not instantly available for push).
#
# Usage:
#   ensure_fork "kagenti" "adk" "clawgenti"
#
# Args:
#   $1 - org name (e.g., "kagenti")
#   $2 - repo name (e.g., "adk")
#   $3 - fork owner account (e.g., "clawgenti")
ensure_fork() {
  local org="$1"
  local repo_name="$2"
  local fork_owner="$3"

  # Check if fork already exists
  if gh repo view "$fork_owner/$repo_name" &>/dev/null 2>&1; then
    return 0
  fi

  # Create the fork
  gh repo fork "$org/$repo_name" --org "$fork_owner" --clone=false 2>/dev/null || true

  # Wait for GitHub to make the fork available for push
  sleep 5
}

# Create a cross-fork PR from a fix branch. This function handles:
#   1. Adding the fork as a git remote (idempotent)
#   2. Committing staged changes with DCO sign-off
#   3. Pushing the branch to the fork
#   4. Creating the PR against upstream main
#
# Prerequisites: caller must have already cd'd into the repo directory,
# created the branch, and staged the changes (git add).
#
# Usage:
#   pr_url=$(create_fork_pr "kagenti" "adk" "clawgenti" \
#     "fix/broken-links-2026-05-21" \
#     "docs: Fix broken link in README.md" \
#     "docs: Fix 1 broken internal link(s) in adk" \
#     "Automated fix by OpenClaw Link Health Fixer.")
#
# Args:
#   $1 - org name
#   $2 - repo name
#   $3 - fork owner
#   $4 - branch name
#   $5 - commit message
#   $6 - PR title
#   $7 - PR body
# Prints: the PR URL on success
# Returns: 0 on success, 1 on failure
create_fork_pr() {
  local org="$1"
  local repo_name="$2"
  local fork_owner="$3"
  local branch="$4"
  local commit_msg="$5"
  local pr_title="$6"
  local pr_body="$7"

  local fork_remote="${fork_owner}-fork"

  # Add fork remote (idempotent -- silently skips if already exists)
  if ! git remote get-url "$fork_remote" &>/dev/null 2>&1; then
    git remote add "$fork_remote" \
      "https://github.com/$fork_owner/$repo_name.git" 2>/dev/null || true
  fi

  # Commit with DCO sign-off (-s adds Signed-off-by trailer)
  git commit -s -m "$commit_msg"

  # Push branch to the fork
  if ! git push "$fork_remote" "$branch" --force-with-lease 2>/dev/null; then
    echo "  WARN: Failed to push branch $branch to $fork_owner/$repo_name" >&2
    return 1
  fi

  # Create cross-fork PR against upstream main
  local pr_url
  pr_url=$(gh pr create \
    --repo "$org/$repo_name" \
    --head "$fork_owner:$branch" \
    --base main \
    --title "$pr_title" \
    --body "$pr_body" \
    2>/dev/null)

  if [ -z "$pr_url" ]; then
    echo "  WARN: Failed to create PR for $org/$repo_name" >&2
    return 1
  fi

  echo "$pr_url"
}
