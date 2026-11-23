#!/usr/bin/env bash
# Result recording: every check ends as PASS, FAIL or BLOCKED and points at an evidence file.
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib.sh"
EVIDENCE="$LOCAL_DIR/evidence"
RESULTS="$EVIDENCE/results.jsonl"
mkdir -p "$EVIDENCE"
SUITE="${SUITE:-$(basename "$(dirname "$0")")}"

_record() { # status id message evidence
  local ev="${4:-}"
  jq -cn --arg s "$1" --arg id "$SUITE/$2" --arg m "$3" --arg e "${ev#"$ROOT/"}" --arg t "$(date -u +%FT%TZ)" \
    '{status:$s,id:$id,message:$m,evidence:$e,at:$t}' >> "$RESULTS"
  local c; case $1 in PASS) c=32;; FAIL) c=31;; *) c=33;; esac
  printf '\033[1;%sm%-7s\033[0m %-48s %s\n' "$c" "$1" "$SUITE/$2" "$3"
  return 0   # suites keep going; report.sh decides the overall exit status
}
pass()    { _record PASS "$@"; }
fail()    { _record FAIL "$@"; }
blocked() { _record BLOCKED "$@"; }

# check <id> <message> <evidence-file> <command...>: PASS if command succeeds, else FAIL.
check() {
  local id=$1 msg=$2 ev=$3; shift 3
  if "$@" >"$ev" 2>&1; then pass "$id" "$msg" "$ev"; else fail "$id" "$msg" "$ev"; fi
}
ev() { echo "$EVIDENCE/$SUITE-$1"; }   # evidence path helper
