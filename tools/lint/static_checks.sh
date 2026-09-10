#!/bin/bash
# Static anti-regression checks for the LNMP installer (the exact bug classes
# fixed in v1.7.1). Hard-fails on regressions; reports advisory findings.
# Run: tools/lint/static_checks.sh   (exit 0 = clean)

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
FILES=$(find . -name '*.sh' -not -path './src/*')
FAIL=0

echo "== 1. bash syntax (bash -n) [HARD] =="
for f in $FILES; do
  bash -n "$f" 2>/dev/null || { echo "  syntax error in $f"; FAIL=1; }
done
echo "  done"

echo "== 2. 'cmd | tee' without PIPESTATUS in file [ADVISORY] =="
# A build/download piped to tee that is never PIPESTATUS-checked silently
# swallows its exit status. Advisory only (some '| tee' are log-only).
REPORT=0
for f in $FILES; do
  if grep -nE '\| *tee' "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
    if ! grep -q 'PIPESTATUS' "$f"; then
      echo "  $f: '| tee' present but no PIPESTATUS check - verify the pipeline's exit is handled"
      REPORT=1
    fi
  fi
done
[ "$REPORT" -eq 0 ] && echo "  OK"

echo "== 3. _extract_tar calls must be failure-guarded [HARD] =="
XBAD=1
while IFS=: read -r file lnum _; do :; done < <(grep -rnE '_extract_tar +\(' "$FILES" 2>/dev/null)
for f in $FILES; do
  n=0; g=0
  while IFS= read -r body; do
    n=$((n+1))
    echo "$body" | grep -q '||' && g=$((g+1))
  done < <(grep -E '_extract_tar +\(' "$f" 2>/dev/null)
  if [ "$n" -gt 0 ] && [ "$n" -ne "$g" ]; then
    echo "  $f: $((n-g)) unguarded _extract_tar call(s)"
    XBAD=0; FAIL=1
  fi
done
[ "$XBAD" -eq 1 ] && echo "  OK"

echo "== 4. pushd/popd balance per function [ADVISORY] =="
# enter_src_dir intentionally pushd's and leaves the popd to its caller.
awk '
  /^[ \t]*[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/ {
    if (fn != "" && p > q && name !~ /enter_src_dir/) print "  " FILE " " name " pushd=" p " popd=" q " (leak?)"
    fn = $0; name = $0; p = 0; q = 0
  }
  fn != "" && /pushd/ { p++ }
  fn != "" && /popd/  { q++ }
  END {
    if (fn != "" && p > q && name !~ /enter_src_dir/) print "  " FILE " " name " pushd=" p " popd=" q " (leak?)"
  }
' $FILES
echo "  (advisory only: early-return paths skew the naive per-function count)"

echo ""
if [ "$FAIL" -eq 0 ]; then echo "STATIC CHECKS: PASS"; exit 0; else echo "STATIC CHECKS: FAIL"; exit 1; fi
