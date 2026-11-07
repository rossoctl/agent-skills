#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKETPLACE="$ROOT/.claude-plugin/marketplace.json"

jq -e '
  .name == "rossoctl-agent-skills"
  and ([.plugins[].name] | sort) ==
    ["byo-rossoctl-cortex", "github-pr-review", "hypershift"]
  and all(.plugins[]; .source == "./" and .strict == false)
  and ([.plugins[] | select(.name == "github-pr-review") | .skills] ==
    [["./skills/github-pr-review"]])
  and ([.plugins[] | select(.name == "byo-rossoctl-cortex") | .skills] ==
    [["./skills/byo-rossoctl-cortex"]])
  and ([.plugins[] | select(.name == "hypershift") | .skills | sort] ==
    [["./skills/hypershift", "./skills/hypershift-cleanup",
      "./skills/hypershift-cluster", "./skills/hypershift-debug",
      "./skills/hypershift-preflight", "./skills/hypershift-quotas",
      "./skills/hypershift-setup"]])
' "$MARKETPLACE" > /dev/null
echo "PASS: only retained plugins and their complete skill sets are published"

while IFS= read -r skill; do
  if [ ! -f "$ROOT/$skill/SKILL.md" ]; then
    echo "FAIL: marketplace skill does not exist: $skill" >&2
    exit 1
  fi
done < <(jq -r '.plugins[].skills[]' "$MARKETPLACE")
echo "PASS: every published skill has a SKILL.md"

for skill in repoman link-health-scanner link-health-fixer dep-bump-scanner \
  dep-bump-fixer automation-health-dashboard github-weekly-report repo-sync; do
  # Git does not track directories, so inspect files rather than empty leftovers.
  if [ -d "$ROOT/skills/$skill" ] &&
    [ -n "$(find "$ROOT/skills/$skill" -type f -print)" ]; then
    echo "FAIL: migrated skill still has files: $skill" >&2
    exit 1
  fi
done
echo "PASS: migrated skills and bundled engine are absent"

for path in scripts/vendor-engine.sh tests/test-vendor-engine.sh; do
  if [ -e "$ROOT/$path" ]; then
    echo "FAIL: obsolete vendoring tooling still exists: $path" >&2
    exit 1
  fi
done
echo "PASS: obsolete engine-vendoring tooling is absent"
