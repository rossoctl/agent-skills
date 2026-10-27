#!/usr/bin/env bash
set -euo pipefail

# parse-diff-map.sh — Convert a unified diff into a structured JSON diff_map.
#
# Each file in the diff becomes an object with a path and array of hunks.
# Each hunk contains an array of lines with their absolute line numbers,
# the side they appear on (LEFT for removed, RIGHT for added/context),
# and their type (added, removed, context).
#
# This is used by the PR review fixer to give the agent precise line numbers
# for inline review comments, avoiding the need for hunk arithmetic in the LLM.
#
# Usage:
#   parse-diff-map.sh <diff-file>
#   cat some.diff | parse-diff-map.sh -
#
# Output (stdout): JSON array
#   [
#     {
#       "path": "src/foo.ts",
#       "hunks": [
#         {
#           "lines": [
#             {"line": 42, "side": "RIGHT", "type": "added", "content": "new code"},
#             {"line": 10, "side": "LEFT",  "type": "removed", "content": "old code"},
#             {"line": 43, "side": "RIGHT", "type": "context", "content": "unchanged"}
#           ]
#         }
#       ]
#     }
#   ]
#
# Exit codes:
#   0 - success (outputs JSON array, possibly empty [])
#   1 - usage error (no file argument or file not found)

# --- Argument handling ---
if [ $# -lt 1 ]; then
  echo "Usage: parse-diff-map.sh <diff-file>" >&2
  echo "       parse-diff-map.sh -   (read from stdin)" >&2
  exit 1
fi

DIFF_INPUT="$1"

if [ "$DIFF_INPUT" != "-" ] && [ ! -f "$DIFF_INPUT" ]; then
  echo "ERROR: File not found: $DIFF_INPUT" >&2
  exit 1
fi

# Empty input produces empty array
if [ "$DIFF_INPUT" != "-" ] && [ ! -s "$DIFF_INPUT" ]; then
  echo "[]"
  exit 0
fi

# --- AWK parser ---
# The parser is a state machine that tracks:
#   - Which file we are in (from +++ b/... lines)
#   - Which hunk we are in (from @@ lines)
#   - Current line numbers for old (left) and new (right) sides
#
# JSON is built incrementally with printf to avoid buffering issues.

awk '
BEGIN {
  printf "["
  first_file = 1
  in_hunk = 0
  started_file = 0
}

# New file boundary: "diff --git a/... b/..."
/^diff --git/ {
  if (in_hunk) {
    printf "]}"
    in_hunk = 0
  }
  if (started_file) {
    printf "]}"
  }
  started_file = 0
  first_hunk = 1
  src_path = ""
  next
}

# Source path from --- line (used as fallback for deleted files)
/^--- a\// {
  src_path = substr($0, 7)
  next
}

# Skip other --- lines (e.g. "--- /dev/null" for new files)
/^--- / { next }

# File path from +++ line (destination side)
/^\+\+\+ b\// {
  path = substr($0, 7)
  if (!first_file) printf ","
  printf "{\"path\":\"%s\",\"hunks\":[", path
  first_file = 0
  started_file = 1
  next
}

# Deleted file: +++ /dev/null — use the source path
/^\+\+\+ \/dev\/null/ {
  if (src_path != "") {
    if (!first_file) printf ","
    printf "{\"path\":\"%s\",\"hunks\":[", src_path
    first_file = 0
    started_file = 1
  }
  next
}

# Hunk header: @@ -old_start[,old_count] +new_start[,new_count] @@
/^@@ / {
  if (in_hunk) {
    # Close the previous hunk
    printf "]}"
  }
  if (!first_hunk) printf ","
  first_hunk = 0
  in_hunk = 1
  first_line = 1

  # Parse the line numbers from the hunk header.
  # Format: @@ -<old_start>[,<old_count>] +<new_start>[,<new_count>] @@
  # We strip the leading "@@ -" then split on space to get the two ranges.
  header = $0
  sub(/^@@ -/, "", header)
  split(header, parts, " ")

  # parts[1] = "old_start,old_count" (or just "old_start")
  split(parts[1], old_parts, ",")
  old_line = old_parts[1] + 0

  # parts[2] = "+new_start,new_count" (or just "+new_start")
  new_range = parts[2]
  sub(/^\+/, "", new_range)
  split(new_range, new_parts, ",")
  new_line = new_parts[1] + 0

  printf "{\"lines\":["
  next
}

# Added line (starts with +, not part of header)
in_hunk && /^\+/ {
  content = substr($0, 2)
  gsub(/\\/, "\\\\", content)
  gsub(/"/, "\\\"", content)
  gsub(/\t/, "\\t", content)
  gsub(/\r/, "", content)
  gsub(/\f/, "\\f", content)
  gsub(/\b/, "\\b", content)
  if (!first_line) printf ","
  printf "{\"line\":%d,\"side\":\"RIGHT\",\"type\":\"added\",\"content\":\"%s\"}", new_line, content
  new_line++
  first_line = 0
  next
}

# Removed line (starts with -)
in_hunk && /^-/ {
  content = substr($0, 2)
  gsub(/\\/, "\\\\", content)
  gsub(/"/, "\\\"", content)
  gsub(/\t/, "\\t", content)
  gsub(/\r/, "", content)
  gsub(/\f/, "\\f", content)
  gsub(/\b/, "\\b", content)
  if (!first_line) printf ","
  printf "{\"line\":%d,\"side\":\"LEFT\",\"type\":\"removed\",\"content\":\"%s\"}", old_line, content
  old_line++
  first_line = 0
  next
}

# Context line (starts with space)
in_hunk && /^ / {
  content = substr($0, 2)
  gsub(/\\/, "\\\\", content)
  gsub(/"/, "\\\"", content)
  gsub(/\t/, "\\t", content)
  gsub(/\r/, "", content)
  gsub(/\f/, "\\f", content)
  gsub(/\b/, "\\b", content)
  if (!first_line) printf ","
  printf "{\"line\":%d,\"side\":\"RIGHT\",\"type\":\"context\",\"content\":\"%s\"}", new_line, content
  old_line++
  new_line++
  first_line = 0
  next
}

END {
  if (in_hunk) printf "]}"
  if (started_file) printf "]}"
  printf "]\n"
}
' "$DIFF_INPUT"
