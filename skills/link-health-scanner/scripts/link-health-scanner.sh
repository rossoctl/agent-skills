#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Link Health Scanner
# Scans all repos for broken links, creates/closes GitHub issues, writes reports.
#
# Usage:
#   bash link-health-scanner.sh --help
#   bash link-health-scanner.sh --dry-run
#   bash link-health-scanner.sh --dry-run --org myorg
#   bash link-health-scanner.sh --issue-limit 3
# =============================================================================

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

# --- CLI args ---
DRY_RUN=false
ISSUE_LIMIT=0  # 0 = unlimited
ORG="kagenti"
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --issue-limit) ISSUE_LIMIT="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat << 'USAGE'
link-health-scanner -- Scan repos for broken links

USAGE:
  link-health-scanner.sh [OPTIONS]

OPTIONS:
  --dry-run         Scan and report only; do not create/close issues
  --issue-limit N   Create at most N issues per run (0 = unlimited)
  --org NAME        GitHub org to scan (default: kagenti)
  --help, -h        Show this help

ENVIRONMENT:
  REPOS_DIR         (required) Directory containing cloned org repos
  REPORTS_DIR       (optional) Where to write reports (default: ./reports)

PREREQUISITES:
  bash 4+, lychee, gh (authenticated), jq
USAGE
  exit 0
fi

# --- Configuration ---
# REPOS_DIR is required -- fail fast if not set
validate_repos_dir "${REPOS_DIR:-}"

REPORTS_DIR="${REPORTS_DIR:-./reports}"
SCAN_DATE=$(date -u +"%Y-%m-%d")
SCAN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MAX_HISTORY_ROWS=500
ESCALATION_THRESHOLD=20

# --- Workspace setup ---
setup_workspace "link-scanner"
TMPDIR="$PROGRAM_TMPDIR"
mkdir -p "$REPORTS_DIR"

# --- Scan ID ---
SCAN_ID=$(generate_scan_id "$REPORTS_DIR" "$SCAN_DATE")

echo "=== Link Health Scan $SCAN_ID ==="
echo "Org: $ORG"
echo "Repos dir: $REPOS_DIR"
echo "Reports dir: $REPORTS_DIR"
if [ "$DRY_RUN" = true ]; then echo "Mode: DRY RUN (no issues, no PRs)"; fi
if [ "$ISSUE_LIMIT" -gt 0 ]; then echo "Issue limit: $ISSUE_LIMIT"; fi

# --- Scan all repos ---
TOTAL_LINKS=0
TOTAL_ERRORS=0
REPOS_SCANNED=0
REPOS_FAILED=0

# Collect all broken links into a single JSONL file
: > "$TMPDIR/broken.jsonl"

for repo_dir in "$REPOS_DIR"/*/ "$REPOS_DIR"/.github/; do
  [ -d "$repo_dir" ] || continue
  repo_name=$(basename "$repo_dir")

  # Skip hidden dirs (except .github) and non-git dirs
  if [[ "$repo_name" == .* && "$repo_name" != ".github" ]] || [ ! -d "$repo_dir/.git" ]; then
    continue
  fi

  echo "Scanning $repo_name..."

  LYCHEE_OUTPUT="$TMPDIR/lychee_${repo_name}.json"

  # Run lychee -- scanner-level args applied to all repos
  LYCHEE_SCANNER_ARGS=(
    --format json
    --scheme http --scheme https
    --exclude 'localhost' --exclude '127\.0\.0\.1' --exclude 'localtest\.me'
    --exclude 'example\.com' --exclude 'example\.org'
    --exclude-all-private
    --exclude-path 'node_modules' --exclude-path 'vendor' --exclude-path '\.claude'
    --accept '200,204,206,403,429,502,503'
    --exclude 'console\.cloud\.google\.com'
    --timeout 10
    --max-retries 2
    --max-concurrency 8
  )

  if [ -f "$repo_dir/.lychee.toml" ]; then
    lychee "${LYCHEE_SCANNER_ARGS[@]}" --config "$repo_dir/.lychee.toml" "$repo_dir" > "$LYCHEE_OUTPUT" 2>/dev/null || true
  else
    lychee "${LYCHEE_SCANNER_ARGS[@]}" "$repo_dir" > "$LYCHEE_OUTPUT" 2>/dev/null || true
  fi

  if [ ! -s "$LYCHEE_OUTPUT" ]; then
    echo "  WARN: lychee produced no output for $repo_name"
    REPOS_FAILED=$((REPOS_FAILED + 1))
    continue
  fi

  # Parse results
  repo_total=$(jq '.total // 0' "$LYCHEE_OUTPUT")
  repo_errors=$(jq '.errors // 0' "$LYCHEE_OUTPUT")
  TOTAL_LINKS=$((TOTAL_LINKS + repo_total))
  TOTAL_ERRORS=$((TOTAL_ERRORS + repo_errors))
  REPOS_SCANNED=$((REPOS_SCANNED + 1))

  # Extract broken links from error_map (skip non-URL entries like "Error building URL")
  # Normalize lychee status to enum tokens: numeric codes stay as-is,
  # text statuses map to: timeout, dns, unreachable, error, unknown.
  # Suppress URLs with unreachable-by-design hostnames (cluster-local, .local, RFC1918).
  jq -r --arg repo "$repo_name" --arg org "$ORG" --arg repos_dir "$REPOS_DIR/$repo_name/" '
    .error_map // {} | to_entries[] |
    .key as $filepath |
    .value[] |
    select(.url | test("^https?://")) |
    # Suppress unreachable-by-design hostnames at URL level
    select(.url | test("://[^/]*\\.svc\\.cluster\\.local([:/]|$)") | not) |
    select(.url | test("://[^/]*\\.local([:/]|$)") | not) |
    select(.url | test("://(10\\.[0-9]|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]|192\\.168\\.[0-9])[0-9.]*([:/]|$)") | not) |
    (.status.code // .status.text // null) as $raw_status |
    (
      if $raw_status == null then "unknown"
      elif ($raw_status | type) == "number" then ($raw_status | tostring)
      elif ($raw_status | test("^[0-9]{3}$")) then $raw_status
      elif ($raw_status | ascii_downcase | test("timeout")) then "timeout"
      elif ($raw_status | ascii_downcase | test("resolve|dns")) then "dns"
      elif ($raw_status | ascii_downcase | test("refused|reset|closed|unreachable|connect")) then "unreachable"
      else "error"
      end
    ) as $status |
    {
      repo: ($org + "/" + $repo),
      file: ($filepath | ltrimstr($repos_dir) | ltrimstr("./")),
      url: .url,
      status: $status,
      category: (
        if (.url | test("github\\.com/" + $org)) then "internal"
        else "external"
        end
      )
    }
  ' "$LYCHEE_OUTPUT" >> "$TMPDIR/broken.jsonl" 2>/dev/null || true

  echo "  Links: $repo_total, Errors: $repo_errors"
done

echo ""
echo "=== Scan complete ==="
echo "Repos scanned: $REPOS_SCANNED (failed: $REPOS_FAILED)"
echo "Total links: $TOTAL_LINKS, Total errors: $TOTAL_ERRORS"

# --- Load previous scan for diffing ---
PREV_BROKEN="$TMPDIR/prev_broken.jsonl"
if [ -f "$REPORTS_DIR/latest.json" ]; then
  jq -c '.broken[]?' "$REPORTS_DIR/latest.json" > "$PREV_BROKEN" 2>/dev/null || true
else
  : > "$PREV_BROKEN"
fi

# --- Compute diff using shared library ---
DIFF_KEY='[.repo, .file, .url] | join("|")'
read -r NEW_LINKS FIXED_LINKS RECURRING_LINKS < <(
  diff_against_previous "$TMPDIR/broken.jsonl" "$PREV_BROKEN" "$DIFF_KEY"
)

echo "Delta: +$NEW_LINKS new, -$FIXED_LINKS fixed, $RECURRING_LINKS recurring"

# --- Count by category ---
BROKEN_INTERNAL=$(jq -s '[.[] | select(.category == "internal")] | length' "$TMPDIR/broken.jsonl" 2>/dev/null || echo 0)
BROKEN_EXTERNAL=$(jq -s '[.[] | select(.category == "external")] | length' "$TMPDIR/broken.jsonl" 2>/dev/null || echo 0)

# --- Create GitHub issues for NEW broken links ---
ISSUES_CREATED=0

while IFS='|' read -r issue_repo issue_file issue_url; do
  [ -z "$issue_repo" ] && continue

  # Check issue limit
  if [ "$ISSUE_LIMIT" -gt 0 ] && [ "$ISSUES_CREATED" -ge "$ISSUE_LIMIT" ]; then
    echo "  SKIP (issue limit $ISSUE_LIMIT reached): $issue_file:$issue_url"
    continue
  fi

  # Get the full broken link record
  link_record=$(jq -c "select(.repo == \"$issue_repo\" and .file == \"$issue_file\" and .url == \"$issue_url\")" "$TMPDIR/broken.jsonl" | head -1)
  [ -z "$link_record" ] && continue

  link_status=$(echo "$link_record" | jq -r '.status')
  link_category=$(echo "$link_record" | jq -r '.category')
  if [ "$link_category" = "internal" ]; then
    category_label="broken-link/internal"
  else
    category_label="broken-link/external"
  fi

  # Deduplication: skip if an open issue already exists for this link
  existing=$(gh_issue_exists "$issue_repo" "Broken link in $issue_file: $issue_url" || true)

  if [ -n "$existing" ]; then
    echo "  Issue #$existing already exists for $issue_file:$issue_url"
    continue
  fi

  # Create issue
  issue_title=":bug: Broken link in $issue_file: $issue_url"
  # Truncate title if too long (GitHub limit is 256)
  if [ ${#issue_title} -gt 250 ]; then
    issue_title="${issue_title:0:247}..."
  fi

  # Build verification note for ambiguous status codes
  verify_note=""
  case "$link_status" in
    *403*) verify_note="
> **Note:** This URL returned 403 (Forbidden). Some sites block automated scanners. The link may be valid when accessed from a browser. Please verify manually before fixing." ;;
    *503*) verify_note="
> **Note:** This URL returned 503 (Service Unavailable), which may indicate a temporarily unavailable service rather than a permanently broken link. Please verify manually before fixing." ;;
    *429*) verify_note="
> **Note:** This URL returned 429 (Too Many Requests). The link may be valid but rate-limited. Please verify manually before fixing." ;;
  esac

  issue_body="## Describe the bug

Broken link detected by automated link health scan.

**Repo:** $issue_repo
**File:** $issue_file
**Broken URL:** $issue_url
**HTTP Status:** $link_status
**First detected:** $SCAN_DATE
**Scan ID:** $SCAN_ID
$verify_note
## Steps To Reproduce

1. Open https://github.com/$issue_repo/blob/main/$issue_file
2. Click or follow the link to \`$issue_url\`
3. Observe $link_status error

## Expected Behavior

The link should resolve to valid documentation.

## Additional Context

Category: $link_category
Detected by: Link Health Scanner (scan $SCAN_ID)"

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would create issue on $issue_repo: $issue_file:$issue_url ($link_category)"
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
  elif gh issue create --repo "$issue_repo" \
    --title "$issue_title" \
    --label "kind/bug,$category_label" \
    --body "$issue_body" 2>/dev/null; then
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
    echo "  Created issue for $issue_file:$issue_url"
  else
    echo "  WARN: Failed to create issue for $issue_file:$issue_url"
  fi

  # Rate limit: small delay between issue creations
  sleep 1
done < "$TMPDIR/new_keys.txt"

echo "Issues created: $ISSUES_CREATED"

# --- Close issues for FIXED links ---
ISSUES_CLOSED=0

while IFS='|' read -r fix_repo fix_file fix_url; do
  [ -z "$fix_repo" ] && continue

  # Find the open issue for this link (empty string if none exists)
  issue_number=$(gh_issue_exists "$fix_repo" "Broken link in $fix_file: $fix_url" || true)

  # Skip if no matching issue was found
  if [ -z "$issue_number" ]; then
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would close issue #$issue_number for $fix_file:$fix_url"
    ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
  elif close_issue_if_valid "$fix_repo" "$issue_number" \
    "Link verified as fixed in scan $SCAN_ID ($SCAN_DATE). Auto-closing."; then
    ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
    echo "  Closed issue #$issue_number for $fix_file:$fix_url"
  fi
done < "$TMPDIR/fixed_keys.txt"

echo "Issues closed: $ISSUES_CLOSED"

# --- Write latest.json ---
BROKEN_ARRAY=$(jq -s '
  [.[] | . + {
    issue_number: null,
    first_detected: "'"$SCAN_DATE"'",
    context: ""
  }]
' "$TMPDIR/broken.jsonl" 2>/dev/null || echo "[]")

LATEST_JSON=$(cat << LATEST_EOF
{
  "scan_id": "$SCAN_ID",
  "date": "$SCAN_TIME",
  "duration_seconds": $SECONDS,
  "org": "$ORG",
  "repos_scanned": $REPOS_SCANNED,
  "repos_failed": $REPOS_FAILED,
  "total_links_checked": $TOTAL_LINKS,
  "broken": $BROKEN_ARRAY,
  "delta": {
    "new": $NEW_LINKS,
    "fixed": $FIXED_LINKS,
    "recurring": $RECURRING_LINKS
  }
}
LATEST_EOF
)

write_report_latest "$REPORTS_DIR" "$LATEST_JSON"
echo "Wrote $REPORTS_DIR/latest.json"

# --- Append to history.json ---
HISTORY_ROW=$(cat << HIST_EOF
{
  "scan_id": "$SCAN_ID",
  "date": "$SCAN_TIME",
  "org": "$ORG",
  "repos_scanned": $REPOS_SCANNED,
  "total_links_checked": $TOTAL_LINKS,
  "broken_internal": $BROKEN_INTERNAL,
  "broken_external": $BROKEN_EXTERNAL,
  "new": $NEW_LINKS,
  "fixed": $FIXED_LINKS,
  "issues_created": $ISSUES_CREATED,
  "issues_closed": $ISSUES_CLOSED
}
HIST_EOF
)

append_history_row "$REPORTS_DIR" "$HISTORY_ROW" "$MAX_HISTORY_ROWS"
echo "Appended to $REPORTS_DIR/history.json"

# --- Escalation check ---
if [ "$NEW_LINKS" -gt "$ESCALATION_THRESHOLD" ]; then
  echo ""
  echo "ALERT: Link health scan found $NEW_LINKS new broken links (threshold: $ESCALATION_THRESHOLD)."
  echo "This may indicate a bulk documentation change or a widespread external service outage."
  echo "Review issues at https://github.com/$ORG/issues?q=label:broken-link"
fi

# --- Summary ---
echo ""
echo "=== Scan $SCAN_ID Summary ==="
echo "Org: $ORG"
echo "Repos: $REPOS_SCANNED scanned, $REPOS_FAILED failed"
echo "Links: $TOTAL_LINKS checked, $((BROKEN_INTERNAL + BROKEN_EXTERNAL)) broken ($BROKEN_INTERNAL internal, $BROKEN_EXTERNAL external)"
echo "Delta: +$NEW_LINKS new, -$FIXED_LINKS fixed, $RECURRING_LINKS recurring"
echo "Issues: $ISSUES_CREATED created, $ISSUES_CLOSED closed"
echo "Duration: ${SECONDS}s"
