#!/usr/bin/env bash
# PR Review state library (RepoMan Phase 7).
#
# Converts pr-review's state between the on-disk ENVELOPE and the in-memory
# WORKING shape the scanner/fixer jq blocks operate on. Automation-only: NOT
# vendored to agent-skills, NOT part of core.sh/program-lib.sh. Source this
# AFTER program-lib.sh (it relies on core.sh's atomic_write_file).
#
# Envelope v1 (on disk):
#   {schema_version:1, program, acted_on:{"<repo>:<number>":{at,ttl_days,head_sha}},
#    program_data:{in_progress:[...]}}
# Working shape (in memory):
#   {reviewed:[{repo,number,head_sha,reviewed_at}], in_progress:[{repo,number,head_sha,started_at}]}

# Empty working shape (same literal the scripts used pre-envelope).
PR_REVIEW_WORKING_DEFAULT='{"in_progress": [], "reviewed": []}'

PR_REVIEW_TTL_DAYS=30
PR_REVIEW_SCHEMA_VERSION=1

# pr_review_state_load <state_file>
# Prints the WORKING shape JSON to stdout. Handles: envelope v1, legacy
# {in_progress,reviewed}, missing file, invalid JSON.
pr_review_state_load() {
  local file="$1"

  # Missing or unreadable -> empty working shape.
  if [ ! -f "$file" ]; then
    printf '%s\n' "$PR_REVIEW_WORKING_DEFAULT"
    return 0
  fi

  # Invalid JSON -> empty working shape (mirrors validate_json_schema's
  # reset-on-invalid behavior, but non-destructive: we do not rewrite the file).
  if ! jq empty "$file" 2>/dev/null; then
    echo "WARN: $file is not valid JSON, using empty state." >&2
    printf '%s\n' "$PR_REVIEW_WORKING_DEFAULT"
    return 0
  fi

  # Envelope v1 (has schema_version) -> unwrap to working shape.
  # Legacy (no schema_version) with array reviewed/in_progress -> pass through.
  # Anything else -> empty working shape.
  jq -c '
    if (.schema_version // null) != null then
      {
        reviewed: ([ (.acted_on // {}) | to_entries[]
          | { repo: (.value.repo // (.key | split(":")[0])),
              number: (.value.number // (.key | split(":")[1] | tonumber)),
              head_sha: .value.head_sha,
              reviewed_at: .value.at } ]),
        in_progress: ((.program_data.in_progress) // [])
      }
    elif ((.reviewed | type) == "array" and (.in_progress | type) == "array") then
      { reviewed: .reviewed, in_progress: .in_progress }
    else
      {reviewed: [], in_progress: []}
    end
  ' "$file" 2>/dev/null || printf '%s\n' "$PR_REVIEW_WORKING_DEFAULT"
}

# pr_review_state_write <working_json_file> <dest_file> <program_id>
# Wraps the working shape into envelope v1 and atomically writes it to dest.
pr_review_state_write() {
  local src="$1" dst="$2" program="$3"
  # Temp sits beside dst (same filesystem) so atomic_write_file's rename is
  # atomic. Guard the jq explicitly and clean up on failure: under the caller's
  # set -e a failed jq would otherwise abort before the rm and leak
  # state.json.env.<pid> into the reports dir.
  local tmp="${dst}.env.$$"

  if ! jq -c \
    --argjson sv "$PR_REVIEW_SCHEMA_VERSION" \
    --arg program "$program" \
    --argjson ttl "$PR_REVIEW_TTL_DAYS" '
    {
      schema_version: $sv,
      program: $program,
      acted_on: ( reduce (.reviewed[]?) as $r ({};
        . + { ("\($r.repo):\($r.number)"): {
                repo: $r.repo, number: $r.number,
                head_sha: $r.head_sha, at: $r.reviewed_at, ttl_days: $ttl } } ) ),
      program_data: { in_progress: (.in_progress // []) }
    }
  ' "$src" > "$tmp"; then
    echo "ERROR: pr_review_state_write: failed to build envelope from $src" >&2
    rm -f "$tmp"
    return 1
  fi

  atomic_write_file "$tmp" "$dst"
  rm -f "$tmp"
}
