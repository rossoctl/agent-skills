#!/usr/bin/env bash
# Regression test for scripts/vendor-engine.sh — the RepoMan v0.1.0 engine
# vendor + provenance stamp. Part of the RepoMan release (epic
# rossoctl/automation#72).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$SCRIPT_DIR/../scripts/vendor-engine.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

MANIFEST="automation-health-dashboard core dep-bump-fixer dep-bump-scanner \
extract-broken-links fork github-api link-health-fixer link-health-scanner \
org parse-diff-map pr-review-fixer pr-review-impact pr-review-lib \
pr-review-scanner program-lib repo-sync repoman-check repoman-index \
repoman-requirements repoman-run repoman-setup weekly-report"

# Fake automation source repo holding the 23 engine scripts, committed so it has a HEAD.
SRC="$TMP/auto"; mkdir -p "$SRC/scripts"
# shellcheck disable=SC2086
for f in $MANIFEST; do echo "#!/usr/bin/env bash" > "$SRC/scripts/$f.sh"; done
git -C "$SRC" init -q
git -C "$SRC" -c user.email=t@t -c user.name=t add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm init
DEST="$TMP/dest"

# --- Happy path: all 23 copied ---
if ! bash "$VENDOR" --source "$SRC" --dest "$DEST" >/dev/null 2>&1; then
  echo "FAIL: happy-path vendor returned non-zero"; fail=1
fi
n=$(find "$DEST" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" = "23" ]; then echo "PASS: 23 scripts copied"; else echo "FAIL: copied $n, expected 23"; fail=1; fi

# --- Provenance stamp: correct SOURCE repo HEAD sha + 23-file list (Task 2) ---
want=$(git -C "$SRC" rev-parse HEAD)
got=$(jq -r '.source_sha' "$DEST/_vendor.json" 2>/dev/null)
if [ "$got" = "$want" ]; then echo "PASS: stamp sha == source HEAD"; else echo "FAIL: stamp sha $got != source $want"; fail=1; fi
if jq -e '.files | length == 23' "$DEST/_vendor.json" >/dev/null 2>&1; then
  echo "PASS: stamp lists 23 files"; else echo "FAIL: stamp file list wrong"; fail=1; fi
if jq -e '.source_repo == "rossoctl/automation"' "$DEST/_vendor.json" >/dev/null 2>&1; then
  echo "PASS: stamp names source repo"; else echo "FAIL: stamp source_repo wrong"; fail=1; fi

# --- Idempotency: second run, same source => identical stamp sha ---
bash "$VENDOR" --source "$SRC" --dest "$DEST" >/dev/null 2>&1
got2=$(jq -r '.source_sha' "$DEST/_vendor.json" 2>/dev/null)
if [ "$got2" = "$want" ]; then echo "PASS: idempotent stamp sha"; else echo "FAIL: idempotency $got2 != $want"; fail=1; fi

# --- Missing source fails loud AND leaves the dest empty (no half-vendored dir) ---
# A file missing mid-manifest (org.sh) must abort BEFORE any copy, so the dest
# must contain zero .sh files — not a partial set with a stale _vendor.json.
BADDEST="$TMP/baddest"
missing_source_fails() (
  BAD="$TMP/bad"; mkdir -p "$BAD/scripts"
  # shellcheck disable=SC2086
  for f in $MANIFEST; do echo x > "$BAD/scripts/$f.sh"; done
  rm "$BAD/scripts/org.sh"
  git -C "$BAD" init -q
  git -C "$BAD" -c user.email=t@t -c user.name=t add -A
  git -C "$BAD" -c user.email=t@t -c user.name=t commit -qm init
  bash "$VENDOR" --source "$BAD" --dest "$BADDEST" >/dev/null 2>&1
)
if ! missing_source_fails; then echo "PASS: missing source fails loud"; else echo "FAIL: missing source did not fail"; fail=1; fi
copied=$(find "$BADDEST" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "${copied:-0}" = "0" ]; then echo "PASS: no half-vendored dir (dest empty on failure)"; else echo "FAIL: $copied files copied before the abort (half-vendored)"; fail=1; fi

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
