#!/usr/bin/env bash
# Render .local/evidence/results.jsonl (latest result per check id) as Markdown + exit status.
source "$(dirname "$0")/lib/result.sh"
OUT="$EVIDENCE/REPORT.md"
[ -s "$RESULTS" ] || { echo "no results"; exit 1; }
jq -s 'group_by(.id) | map(max_by(.at)) | sort_by(.id)' "$RESULTS" > "$EVIDENCE/latest.json"
{
  echo "# Test report ($(date -u +%FT%TZ))"; echo
  jq -r '"PASS: \(map(select(.status=="PASS"))|length)  FAIL: \(map(select(.status=="FAIL"))|length)  BLOCKED: \(map(select(.status=="BLOCKED"))|length)"' "$EVIDENCE/latest.json"
  echo; echo "| Status | Check | Detail | Evidence |"; echo "|---|---|---|---|"
  jq -r '.[] | "| \(.status) | `\(.id)` | \(.message|gsub("\\|";"/")) | \(.evidence) |"' "$EVIDENCE/latest.json"
} > "$OUT"
cat "$OUT"
! jq -e 'any(.[]; .status=="FAIL")' "$EVIDENCE/latest.json" >/dev/null
