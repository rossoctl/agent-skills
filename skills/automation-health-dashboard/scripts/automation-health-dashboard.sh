#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Automation Health Dashboard Generator — kagenti org
# Combines link-health and dep-bump program metrics into a single executive-
# facing markdown dashboard. Pushes to a standing fork-based PR.
#
# Usage:
#   bash automation-health-dashboard.sh --help
#   bash automation-health-dashboard.sh --dry-run
#   bash automation-health-dashboard.sh --live
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- CLI args ---
DRY_RUN=true
ORG="kagenti"
VERBOSE=false
SHOW_HELP=false
FORK_OWNER="${FORK_OWNER:-clawgenti}"
KAGENTI_DIR="${KAGENTI_DIR:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --live) DRY_RUN=false; shift ;;
    --reports-dir) REPORTS_DIR="$2"; shift 2 ;;
    --kagenti-dir) KAGENTI_DIR="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    --fork-owner) FORK_OWNER="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat <<'HELP'
Automation Health Dashboard Generator

Combines link-health and dep-bump program metrics into a single executive-
facing markdown file. Pushes to a standing fork-based PR in the org's main repo.

Usage:
  bash automation-health-dashboard.sh [OPTIONS]

Options:
  --dry-run           Generate and preview dashboard (default)
  --live              Commit and push to fork, create/update PR
  --reports-dir DIR   Base reports directory (default: $REPORTS_DIR or ./reports)
  --kagenti-dir DIR   Path to kagenti repo clone (default: $KAGENTI_DIR)
  --org NAME          GitHub org (default: kagenti)
  --fork-owner NAME   Fork owner for PR workflow (default: clawgenti)
  --verbose           Print diagnostic output
  --help, -h          Show this help

Environment:
  REPORTS_DIR   Base directory containing link-scan/ and dep-bump/ subdirs
  KAGENTI_DIR   Path to the org's main repo clone (for live mode git operations)
  FORK_OWNER    Fork owner for cross-fork PRs
HELP
  exit 0
fi

# --- Validate inputs ---
if [ -z "${REPORTS_DIR:-}" ]; then
  if [ -d "./reports" ]; then
    REPORTS_DIR="./reports"
  else
    echo "ERROR: REPORTS_DIR is not set and ./reports does not exist."
    echo "Export it to the directory containing program report subdirs:"
    echo "  export REPORTS_DIR=~/reports"
    exit 1
  fi
fi

LINK_SCAN_DIR="$REPORTS_DIR/link-scan"
DEP_BUMP_DIR="$REPORTS_DIR/dep-bump"
PR_REVIEW_DIR="$REPORTS_DIR/pr-review"

HAS_LINK_HEALTH=false
HAS_DEP_BUMP=false

if [ -f "$LINK_SCAN_DIR/latest.json" ] && [ -f "$LINK_SCAN_DIR/history.json" ]; then
  HAS_LINK_HEALTH=true
fi
if [ -f "$DEP_BUMP_DIR/latest.json" ] && [ -f "$DEP_BUMP_DIR/history.json" ]; then
  HAS_DEP_BUMP=true
fi

HAS_PR_REVIEW=false
if [ -f "$PR_REVIEW_DIR/fixer-history.json" ]; then
  HAS_PR_REVIEW=true
fi

if [ "$HAS_LINK_HEALTH" = false ] && [ "$HAS_DEP_BUMP" = false ] && [ "$HAS_PR_REVIEW" = false ]; then
  echo "ERROR: No program reports found in $REPORTS_DIR"
  echo "Expected one of: $LINK_SCAN_DIR/latest.json, $DEP_BUMP_DIR/latest.json, $PR_REVIEW_DIR/fixer-history.json"
  exit 1
fi

PROGRAMS_ACTIVE=0
if [ "$HAS_LINK_HEALTH" = true ]; then PROGRAMS_ACTIVE=$((PROGRAMS_ACTIVE + 1)); fi
if [ "$HAS_DEP_BUMP" = true ]; then PROGRAMS_ACTIVE=$((PROGRAMS_ACTIVE + 1)); fi
if [ "$HAS_PR_REVIEW" = true ]; then PROGRAMS_ACTIVE=$((PROGRAMS_ACTIVE + 1)); fi

# --- Setup ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

SCAN_TIME_ET=$(TZ="America/New_York" date +"%Y-%m-%d %H:%M ET")

echo "=== Automation Health Dashboard ==="
echo "Reports dir: $REPORTS_DIR"
echo "Programs available: $PROGRAMS_ACTIVE"
if [ "$DRY_RUN" = true ]; then
  echo "Mode: DRY RUN"
else
  echo "Mode: LIVE"
fi
echo ""

# =============================================================================
# Step 2: Compute executive summary metrics
# =============================================================================

LH_ISSUES_CREATED=0
LH_ISSUES_CLOSED=0
DB_ISSUES_CREATED=0
DB_ISSUES_CLOSED=0
DB_FIXER_CLOSED=0
TOTAL_PRS_OPENED=0
LAST_SCAN_DATE="unknown"

if [ "$HAS_LINK_HEALTH" = true ]; then
  LH_ISSUES_CREATED=$(jq '[.[] | .issues_created // 0] | add // 0' "$LINK_SCAN_DIR/history.json")
  LH_ISSUES_CLOSED=$(jq '[.[] | .issues_closed // 0] | add // 0' "$LINK_SCAN_DIR/history.json")
  lh_last_date=$(jq -r '.date // ""' "$LINK_SCAN_DIR/latest.json")
  if [ -n "$lh_last_date" ]; then
    LAST_SCAN_DATE="${lh_last_date%%T*}"
  fi
fi

if [ "$HAS_DEP_BUMP" = true ]; then
  DB_ISSUES_CREATED=$(jq '[.[] | .issues_created // 0] | add // 0' "$DEP_BUMP_DIR/history.json")
  DB_ISSUES_CLOSED=$(jq '[.[] | .issues_closed // 0] | add // 0' "$DEP_BUMP_DIR/history.json")
  db_last_date=$(jq -r '.date // ""' "$DEP_BUMP_DIR/latest.json")
  if [ -n "$db_last_date" ]; then
    db_date="${db_last_date%%T*}"
    if [ "$LAST_SCAN_DATE" = "unknown" ] || [[ "$db_date" > "$LAST_SCAN_DATE" ]]; then
      LAST_SCAN_DATE="$db_date"
    fi
  fi

  if [ -f "$DEP_BUMP_DIR/fixer-latest.json" ]; then
    DB_FIXER_CLOSED=$(jq '.issues_closed // 0' "$DEP_BUMP_DIR/fixer-latest.json")
    fixer_config_prs=$(jq '.config_prs_created // 0' "$DEP_BUMP_DIR/fixer-latest.json")
    TOTAL_PRS_OPENED=$((TOTAL_PRS_OPENED + fixer_config_prs))
  fi
fi

TOTAL_ISSUES_CREATED=$((LH_ISSUES_CREATED + DB_ISSUES_CREATED))
TOTAL_ISSUES_RESOLVED=$((LH_ISSUES_CLOSED + DB_ISSUES_CLOSED + DB_FIXER_CLOSED))
HOURS_SAVED=$(echo "$TOTAL_ISSUES_RESOLVED" | awk '{printf "%.1f", $1 * 0.25}')

if [ "$VERBOSE" = true ]; then
  echo "Executive metrics:"
  echo "  Issues created: $TOTAL_ISSUES_CREATED (LH: $LH_ISSUES_CREATED, DB: $DB_ISSUES_CREATED)"
  echo "  Issues resolved: $TOTAL_ISSUES_RESOLVED (LH: $LH_ISSUES_CLOSED, DB: $DB_ISSUES_CLOSED, fixer: $DB_FIXER_CLOSED)"
  echo "  PRs opened: $TOTAL_PRS_OPENED"
  echo "  Hours saved: $HOURS_SAVED"
  echo ""
fi

# =============================================================================
# Step 3: Compute link-health section
# =============================================================================

LH_REPOS_SCANNED=0
LH_TOTAL_LINKS=0
LH_BROKEN_INTERNAL=0
LH_BROKEN_EXTERNAL=0
LH_FIRST_INTERNAL=0
LH_FIRST_EXTERNAL=0
LH_TREND_TABLE="| - | - | - | - |"
lh_int_trend=""
lh_ext_trend=""

if [ "$HAS_LINK_HEALTH" = true ]; then
  LH_REPOS_SCANNED=$(jq '.repos_scanned // 0' "$LINK_SCAN_DIR/latest.json")
  LH_TOTAL_LINKS=$(jq '.total_links_checked // 0' "$LINK_SCAN_DIR/latest.json")
  LH_BROKEN_INTERNAL=$(jq '[.broken[] | select(.category == "internal")] | length' "$LINK_SCAN_DIR/latest.json" 2>/dev/null || echo "0")
  LH_BROKEN_EXTERNAL=$(jq '[.broken[] | select(.category == "external")] | length' "$LINK_SCAN_DIR/latest.json" 2>/dev/null || echo "0")

  # First scan values for trend comparison
  LH_FIRST_INTERNAL=$(jq '.[0].broken_internal // 0' "$LINK_SCAN_DIR/history.json")
  LH_FIRST_EXTERNAL=$(jq '.[0].broken_external // 0' "$LINK_SCAN_DIR/history.json")

  LH_INTERNAL_DELTA=$((LH_BROKEN_INTERNAL - LH_FIRST_INTERNAL))
  LH_EXTERNAL_DELTA=$((LH_BROKEN_EXTERNAL - LH_FIRST_EXTERNAL))

  # Format deltas with sign
  lh_int_trend=""
  if [ "$LH_INTERNAL_DELTA" -gt 0 ]; then lh_int_trend="+$LH_INTERNAL_DELTA from first scan"
  elif [ "$LH_INTERNAL_DELTA" -lt 0 ]; then lh_int_trend="$LH_INTERNAL_DELTA from first scan"
  fi
  lh_ext_trend=""
  if [ "$LH_EXTERNAL_DELTA" -gt 0 ]; then lh_ext_trend="+$LH_EXTERNAL_DELTA from first scan"
  elif [ "$LH_EXTERNAL_DELTA" -lt 0 ]; then lh_ext_trend="$LH_EXTERNAL_DELTA from first scan"
  fi

  # Trend table (last 10 scans)
  LH_TREND_TABLE=$(jq -r '
    .[-10:] | reverse | .[] |
    "| \(.date | split("T")[0]) | \(.broken_internal) | \(.broken_external) | \(if .new > .fixed then "+\(.new - .fixed)" elif .new < .fixed then "\(.new - .fixed)" else "0" end) |"
  ' "$LINK_SCAN_DIR/history.json" 2>/dev/null || echo "| - | - | - | - |")
fi

# =============================================================================
# Step 4: Compute dep-bump section
# =============================================================================

DB_REPOS_SCANNED=0
DB_TOTAL_OPEN_PRS=0
DB_STALE_COUNT=0
DB_SLA_COMPLIANCE=0
DB_MEDIAN_TTM=0
DB_BASELINE_TTM=0
DB_COVERAGE_REPOS=0
DB_COVERAGE_TOTAL=0
DB_COVERAGE_PCT=0
DB_TIER_TABLE="| - | - | - | - |"
DB_TREND_TABLE="| - | - | - | - |"

if [ "$HAS_DEP_BUMP" = true ]; then
  DB_REPOS_SCANNED=$(jq '.repos_scanned // 0' "$DEP_BUMP_DIR/latest.json")
  DB_TOTAL_OPEN_PRS=$(jq '.total_open_prs // 0' "$DEP_BUMP_DIR/latest.json")
  DB_STALE_COUNT=$(jq '.stale_prs | length' "$DEP_BUMP_DIR/latest.json" 2>/dev/null || echo "0")
  DB_COVERAGE_REPOS=$(jq '.repos_with_dependabot // 0' "$DEP_BUMP_DIR/latest.json")
  DB_COVERAGE_TOTAL=$DB_REPOS_SCANNED

  if [ "$DB_COVERAGE_TOTAL" -gt 0 ]; then
    DB_COVERAGE_PCT=$((DB_COVERAGE_REPOS * 100 / DB_COVERAGE_TOTAL))
  fi

  if [ "$DB_TOTAL_OPEN_PRS" -gt 0 ]; then
    DB_SLA_COMPLIANCE=$(( (DB_TOTAL_OPEN_PRS - DB_STALE_COUNT) * 100 / DB_TOTAL_OPEN_PRS ))
  else
    DB_SLA_COMPLIANCE=100
  fi

  if [ -f "$DEP_BUMP_DIR/fixer-latest.json" ]; then
    DB_MEDIAN_TTM=$(jq '.metrics.median_time_to_merge // 0' "$DEP_BUMP_DIR/fixer-latest.json")
  fi
  if [ -f "$DEP_BUMP_DIR/baseline.json" ]; then
    DB_BASELINE_TTM=$(jq '.median_time_to_merge_days // 0' "$DEP_BUMP_DIR/baseline.json")
  fi

  # Tier breakdown from stale_prs array
  DB_TIER_TABLE=$(jq -r '
    .stale_prs as $all |
    .total_open_prs as $total |
    [
      {tier: "Critical", sla: "3d",
       stale: ([$all[] | select(.severity == "critical")] | length)},
      {tier: "High", sla: "7d",
       stale: ([$all[] | select(.severity == "high")] | length)},
      {tier: "Medium", sla: "30d",
       stale: ([$all[] | select(.severity == "medium")] | length)},
      {tier: "Routine", sla: "14d",
       stale: ([$all[] | select(.severity == "routine")] | length)},
      {tier: "Major", sla: "30d",
       stale: ([$all[] | select(.severity == "major")] | length)}
    ] | .[] |
    "| \(.tier) | \(.stale) | \(.sla) |"
  ' "$DEP_BUMP_DIR/latest.json" 2>/dev/null || echo "| - | - | - |")

  # Trend table (last 10 scans)
  DB_TREND_TABLE=$(jq -r '
    .[-10:] | reverse | .[] |
    "| \(.date | split("T")[0]) | \(.stale_security // 0) | \(.stale_routine // 0) | \(if .new > .fixed then "+\(.new - .fixed)" elif .new < .fixed then "\(.new - .fixed)" else "0" end) |"
  ' "$DEP_BUMP_DIR/history.json" 2>/dev/null || echo "| - | - | - | - |")
fi

# =============================================================================
# Step 4b: Compute PR-review section
# =============================================================================

PR_REVIEWS_TOTAL=0
PR_REVIEWS_FAILED=0
PR_QUEUE_NOW=0
PR_TTM_REVIEWED="N/A"
PR_TTM_UNREVIEWED="N/A"
PR_TTM_BEFORE="N/A"
PR_TTM_AFTER="N/A"
PR_ACTIVATIONS_NOTE="n/a"
PR_TREND_TABLE="| - | - | - | - |"

if [ "$HAS_PR_REVIEW" = true ]; then
  PR_REVIEWS_TOTAL=$(jq '[.[] | .prs_reviewed // 0] | add // 0' "$PR_REVIEW_DIR/fixer-history.json")
  PR_REVIEWS_FAILED=$(jq '[.[] | .prs_failed // 0] | add // 0' "$PR_REVIEW_DIR/fixer-history.json")

  if [ -f "$PR_REVIEW_DIR/latest.json" ]; then
    PR_QUEUE_NOW=$(jq '.eligible_prs | length' "$PR_REVIEW_DIR/latest.json" 2>/dev/null || echo "0")
  fi

  if [ -f "$PR_REVIEW_DIR/impact.json" ]; then
    PR_TTM_REVIEWED=$(jq '.reviewed.median_ttm_hours // "N/A"'           "$PR_REVIEW_DIR/impact.json")
    PR_TTM_UNREVIEWED=$(jq '.unreviewed.median_ttm_hours // "N/A"'        "$PR_REVIEW_DIR/impact.json")
    PR_TTM_BEFORE=$(jq '.before_activation.median_ttm_hours // "N/A"'    "$PR_REVIEW_DIR/impact.json")
    PR_TTM_AFTER=$(jq '.after_activation.median_ttm_hours // "N/A"'      "$PR_REVIEW_DIR/impact.json")
    # Per-repo activation summary, e.g. "kagenti/kagenti since 2026-06-13; ..."
    PR_ACTIVATIONS_NOTE=$(jq -r '
      (.activations // []) |
      if length == 0 then "n/a"
      else [.[] | "\(.repo) since \(.activation | split("T")[0])"] | join("; ")
      end' "$PR_REVIEW_DIR/impact.json" 2>/dev/null || echo "n/a")
  fi

  # Trend: last 10 fixer runs (reviewed / processed / failed)
  # Date + time (UTC, to the minute) so multiple runs on the same day stay distinct.
  PR_TREND_TABLE=$(jq -r '
    .[-10:] | reverse | .[] |
    "| \(.date[0:16] | sub("T";" ")) | \(.prs_reviewed // 0) | \(.prs_processed // 0) | \(.prs_failed // 0) |"
  ' "$PR_REVIEW_DIR/fixer-history.json" 2>/dev/null || echo "| - | - | - | - |")

  if [ "$VERBOSE" = true ]; then
    echo "PR-review metrics:"
    echo "  Reviews (cumulative): $PR_REVIEWS_TOTAL (failed: $PR_REVIEWS_FAILED)"
    echo "  Queue now: $PR_QUEUE_NOW"
    echo "  TTM before/after activation: ${PR_TTM_BEFORE}h / ${PR_TTM_AFTER}h"
    echo "  TTM reviewed/unreviewed: ${PR_TTM_REVIEWED}h / ${PR_TTM_UNREVIEWED}h"
    echo "  Activations: $PR_ACTIVATIONS_NOTE"
    echo ""
  fi
fi

# =============================================================================
# Step 5: Compute cross-program coverage
# =============================================================================

COVERAGE_TABLE=""
REPOS_UNDER_ONE=0
REPOS_UNDER_ALL=0
TOTAL_UNIQUE_REPOS=0

# Collect repos from each program
lh_repos=""
db_repos=""
pr_repos=""

if [ "$HAS_LINK_HEALTH" = true ]; then
  lh_repos=$(jq -r '[.broken[].repo] | unique | .[] | split("/")[1]' "$LINK_SCAN_DIR/latest.json" 2>/dev/null | sort -u || true)
  # Also include repos scanned (from history, repos_scanned is a count not a list)
  # Fall back to broken repos as proxy for "scanned repos"
fi

if [ "$HAS_DEP_BUMP" = true ]; then
  # Repos with dependabot activity
  db_repos=$(jq -r '([.stale_prs[].repo] + [.coverage_gaps[].repo]) | unique | .[]' "$DEP_BUMP_DIR/latest.json" 2>/dev/null | sort -u || true)
fi

if [ "$HAS_PR_REVIEW" = true ]; then
  # Prefer per-repo activations from impact.json (short-name via split("/")[1]);
  # fall back to the four configured repo short-names.
  if [ -f "$PR_REVIEW_DIR/impact.json" ]; then
    pr_repos=$(jq -r '[.activations[].repo] | unique | .[] | split("/")[1]' "$PR_REVIEW_DIR/impact.json" 2>/dev/null | sort -u || true)
  fi
  if [ -z "$pr_repos" ]; then
    pr_repos=$(printf '%s\n' kagenti kagenti-extensions automation agent-skills | sort -u)
  fi
fi

# Merge and produce table
all_repos=$(printf '%s\n%s\n%s\n' "$lh_repos" "$db_repos" "$pr_repos" | sort -u | grep -v '^$' || true)
TOTAL_UNIQUE_REPOS=$(echo "$all_repos" | grep -c . || echo "0")

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  has_lh="no"
  has_db="no"
  has_pr="no"
  count=0

  if echo "$lh_repos" | grep -qxF "$repo"; then
    has_lh="yes"
    count=$((count + 1))
  fi
  if echo "$db_repos" | grep -qxF "$repo"; then
    has_db="yes"
    count=$((count + 1))
  fi
  if echo "$pr_repos" | grep -qxF "$repo"; then
    has_pr="yes"
    count=$((count + 1))
  fi

  COVERAGE_TABLE="${COVERAGE_TABLE}| $repo | $has_lh | $has_db | $has_pr | $count |
"
  if [ "$count" -ge 1 ]; then REPOS_UNDER_ONE=$((REPOS_UNDER_ONE + 1)); fi
  if [ "$count" -ge "$PROGRAMS_ACTIVE" ]; then REPOS_UNDER_ALL=$((REPOS_UNDER_ALL + 1)); fi
done <<< "$all_repos"

COVERAGE_ONE_PCT=0
COVERAGE_ALL_PCT=0
if [ "$TOTAL_UNIQUE_REPOS" -gt 0 ]; then
  COVERAGE_ONE_PCT=$((REPOS_UNDER_ONE * 100 / TOTAL_UNIQUE_REPOS))
  COVERAGE_ALL_PCT=$((REPOS_UNDER_ALL * 100 / TOTAL_UNIQUE_REPOS))
fi

# =============================================================================
# Step 6: Cron health
# =============================================================================

# Static entries — future version should read from jobs.json
CRON_TABLE="| link-health-scanner | Mon/Wed/Fri 7am ET | $LAST_SCAN_DATE | ok |
| link-health-fixer | Tue/Thu 8am ET | $LAST_SCAN_DATE | ok |
| dep-bump-scanner | Tue/Thu 10am ET | $LAST_SCAN_DATE | ok |
| dep-bump-fixer | Tue/Thu 12pm ET | $LAST_SCAN_DATE | ok |
| pr-review-scanner | every ~15 min | $LAST_SCAN_DATE | ok |
| pr-review-fixer | every ~15 min | $LAST_SCAN_DATE | ok |"

# =============================================================================
# Step 7: Generate markdown
# =============================================================================

cat > "$TMPDIR/automation-health.md" << DASHBOARD_EOF
# Automation Health Dashboard

> Last updated: $SCAN_TIME_ET | Programs: $PROGRAMS_ACTIVE active

## Executive Summary

| Metric | Value |
|--------|-------|
| Total issues auto-created | $TOTAL_ISSUES_CREATED (link-health: $LH_ISSUES_CREATED, dep-bump: $DB_ISSUES_CREATED) |
| Total issues auto-resolved | $TOTAL_ISSUES_RESOLVED |
| Total PRs auto-opened | $TOTAL_PRS_OPENED |
| Estimated hours saved | ${HOURS_SAVED} hrs (at 15 min/resolved issue) |
| PRs reviewed by clawgenti | $PR_REVIEWS_TOTAL |
| Programs active | $PROGRAMS_ACTIVE |
| Last successful scan | $LAST_SCAN_DATE |

## Link Health

| Metric | Value | Trend |
|--------|-------|-------|
| Repos scanned | $LH_REPOS_SCANNED | |
| Total links checked | $LH_TOTAL_LINKS | |
| Broken (internal) | $LH_BROKEN_INTERNAL | $lh_int_trend |
| Broken (external) | $LH_BROKEN_EXTERNAL | $lh_ext_trend |
| Issues created (cumulative) | $LH_ISSUES_CREATED | |
| Issues resolved (cumulative) | $LH_ISSUES_CLOSED | |

### Trend (last 10 scans)

| Date | Internal | External | Delta |
|------|----------|----------|-------|
$LH_TREND_TABLE

## Dependency Bumps

| Metric | Value | Trend |
|--------|-------|-------|
| Repos scanned | $DB_REPOS_SCANNED | |
| Open Dependabot PRs | $DB_TOTAL_OPEN_PRS | |
| Stale PRs (SLA breached) | $DB_STALE_COUNT | baseline: $(jq '.stale_count_at_baseline // "N/A"' "$DEP_BUMP_DIR/baseline.json" 2>/dev/null || echo "N/A") |
| SLA compliance rate | ${DB_SLA_COMPLIANCE}% | |
| Median time-to-merge | ${DB_MEDIAN_TTM}d | baseline: ${DB_BASELINE_TTM}d |
| Dependabot coverage | ${DB_COVERAGE_PCT}% ($DB_COVERAGE_REPOS/$DB_COVERAGE_TOTAL repos) | |

### By Severity Tier

| Tier | Stale | SLA |
|------|-------|-----|
$DB_TIER_TABLE

### Patch Velocity (last 10 scans)

| Date | Stale Security | Stale Routine | Delta |
|------|----------------|---------------|-------|
$DB_TREND_TABLE

## PR Review Bot

Headline impact — median time-to-merge before vs. after the bot became active in each repo:

| Metric | Value | Note |
|--------|-------|------|
| Median TTM — before activation | ${PR_TTM_BEFORE}h | per repo, PRs opened before its first bot review |
| Median TTM — after activation | ${PR_TTM_AFTER}h | per repo, PRs opened on/after its first bot review |
| PRs reviewed (cumulative) | $PR_REVIEWS_TOTAL | failed: $PR_REVIEWS_FAILED |
| Currently queued for review | $PR_QUEUE_NOW | |

> Per-repo activation: $PR_ACTIVATIONS_NOTE

Reviewed vs. unreviewed (secondary — interpret with care):

| Metric | Value | Note |
|--------|-------|------|
| Median TTM — reviewed | ${PR_TTM_REVIEWED}h | PRs clawgenti reviewed |
| Median TTM — unreviewed | ${PR_TTM_UNREVIEWED}h | PRs without a bot review |

> Reviewed PRs are self-selected: \`ready-for-ai-review\` is applied to substantive PRs, so a *higher* reviewed TTM reflects which PRs get reviewed, not the bot slowing merges. Use the before/after rows above for impact.

### Review Activity (last 10 runs)

| Date (UTC) | Reviewed | Processed | Failed |
|------------|----------|-----------|--------|
$PR_TREND_TABLE

## Cross-Program Coverage

| Repo | Link Health | Dep Bump | PR Review | Programs |
|------|-------------|----------|-----------|----------|
$COVERAGE_TABLE

### Coverage Summary
- Repos under at least one program: $REPOS_UNDER_ONE / $TOTAL_UNIQUE_REPOS (${COVERAGE_ONE_PCT}%)
- Repos under all programs: $REPOS_UNDER_ALL / $TOTAL_UNIQUE_REPOS (${COVERAGE_ALL_PCT}%)

## Cron Health

| Job | Schedule | Last Run | Status |
|-----|----------|----------|--------|
$CRON_TABLE

---
*Generated by Kagenti Automation Health Dashboard. Do not edit manually.*
DASHBOARD_EOF

echo "Dashboard generated ($TMPDIR/automation-health.md)"

# =============================================================================
# Step 8: Output or commit
# =============================================================================

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "[DRY RUN] Dashboard preview:"
  echo "---"
  cat "$TMPDIR/automation-health.md"
  echo "---"
  echo "[DRY RUN] Would push docs/automation-health.md to fork and create/update PR"
else
  if [ -z "$KAGENTI_DIR" ]; then
    echo "ERROR: KAGENTI_DIR is not set (required for live mode)."
    echo "Export it to the path of the kagenti/kagenti repo clone:"
    echo "  export KAGENTI_DIR=~/kagenti/kagenti"
    exit 1
  fi

  if [ ! -d "$KAGENTI_DIR/.git" ]; then
    echo "ERROR: $KAGENTI_DIR does not appear to be a git repository."
    exit 1
  fi

  FORK_REMOTE="$FORK_OWNER"
  DASHBOARD_BRANCH="automation/health-dashboard"

  cd "$KAGENTI_DIR"

  # Ensure fork remote exists
  if ! git remote get-url "$FORK_REMOTE" &>/dev/null; then
    git remote add "$FORK_REMOTE" "https://github.com/$FORK_OWNER/$ORG.git"
  fi

  # Fetch fork's branch if it exists, otherwise create from main
  if git fetch "$FORK_REMOTE" "$DASHBOARD_BRANCH" 2>/dev/null; then
    git checkout -B "$DASHBOARD_BRANCH" "$FORK_REMOTE/$DASHBOARD_BRANCH"
  else
    git fetch "$FORK_REMOTE" main 2>/dev/null || true
    git checkout -B "$DASHBOARD_BRANCH" "$FORK_REMOTE/main" 2>/dev/null \
      || git checkout -B "$DASHBOARD_BRANCH"
  fi

  mkdir -p docs
  cp "$TMPDIR/automation-health.md" docs/automation-health.md
  git add docs/automation-health.md
  git commit -s -m "docs: Update automation health dashboard ($SCAN_TIME_ET)" 2>/dev/null || echo "No changes to commit"
  git push "$FORK_REMOTE" "$DASHBOARD_BRANCH" 2>/dev/null || echo "WARN: Failed to push dashboard to fork"

  # Create or update standing cross-fork PR
  existing_pr=$(gh api "repos/$ORG/$ORG/pulls?head=$FORK_OWNER:$DASHBOARD_BRANCH&state=open" \
    --jq '.[0].number' 2>/dev/null || echo "")

  pr_body="## Summary

Auto-updated by Kagenti Automation Health Dashboard. This PR is continuously updated with each generation. Merge when convenient.

| Metric | Value |
|--------|-------|
| Programs active | $PROGRAMS_ACTIVE |
| Issues created (cumulative) | $TOTAL_ISSUES_CREATED |
| Issues resolved (cumulative) | $TOTAL_ISSUES_RESOLVED |
| Estimated hours saved | ${HOURS_SAVED} hrs |

## Related issue(s)

- kagenti/kagenti#1260"

  if [ -z "$existing_pr" ] || [ "$existing_pr" = "null" ]; then
    gh pr create --repo "$ORG/$ORG" \
      --head "$FORK_OWNER:$DASHBOARD_BRANCH" --base main \
      --title "docs: Automation health dashboard (auto-updated)" \
      --body "$pr_body" 2>/dev/null || echo "WARN: Failed to create dashboard PR"
  else
    gh pr edit "$existing_pr" --repo "$ORG/$ORG" --body "$pr_body" 2>/dev/null || true
  fi

  echo "Dashboard committed and pushed"
fi

echo ""
echo "=== Done ==="
