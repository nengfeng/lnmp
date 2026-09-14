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

echo "== 5. package names proven absent must not reappear [HARD] =="
# Each of these aborted the ENTIRE dependency stage while it was present, and
# each was verified against the archives (Debian madison / packages.ubuntu.com):
#   libidn12-dev               - shipped by no Debian or Ubuntu release (libidn-dev is)
#   software-properties-common - unused here, and Debian 13 (trixie) dropped it
#   sysv-rc (Ubuntu only)      - shipped by no Ubuntu release; Debian still has it
# Only the package-list assignment lines are inspected, so the explanatory
# comments (which do name these packages) cannot trip the check.
debian_pkgs=$(sed -n '/^installDepsDebian/,/^}/p' include/check_sw.sh | grep -E '^[[:space:]]*(local )?(pkgCommon|pkgExtra)=')
ubuntu_pkgs=$(sed -n '/^installDepsUbuntu/,/^}/p' include/check_sw.sh | grep -E '^[[:space:]]*(local )?(pkgCommon|pkgExtra)=')
absent_ok=1
for n in libidn12-dev software-properties-common; do
  if echo "${debian_pkgs}${ubuntu_pkgs}" | grep -qw -- "$n"; then
    echo "  include/check_sw.sh: '$n' is not shipped by any supported release"
    absent_ok=0
  fi
done
if echo "${ubuntu_pkgs}" | grep -qw -- 'sysv-rc'; then
  echo "  include/check_sw.sh: 'sysv-rc' does not exist on Ubuntu (init-system-helpers provides update-rc.d)"
  absent_ok=0
fi
[ "$absent_ok" -eq 1 ] && echo "  OK" || FAIL=1

echo "== 6. entry-point scripts must not end on a bare '&&' compound [HARD] =="
# `test && action` as the script's LAST statement hands the script the status of
# `test`: when the test is false the script exits 1 even though every step before
# it succeeded.  install.sh used to end with
#     [[ "${reboot_flag}" == y ]] && reboot
# so every non-interactive install (CI, Ansible, docker build, `echo n | ...`)
# reported failure while printing the success banner.  Use `if ...; then ...; fi`
# instead.  A trailing '||' is fine: `a || b` returns 0 when a succeeds, and
# `a && { ...; exit 0; } || { ...; exit 1; }` ends on '||' with an explicit exit
# in both branches (tools/test_offline.sh relies on exactly that shape).  Only a
# last statement whose final operator is '&&' leaves the script exposed.
# include/*.sh are sourced libraries, so their last statement is not an exit code.
tail_ok=1
for f in $(find . -name '*.sh' -not -path './src/*' -not -path './include/*' -not -path './.workbuddy/*'); do
  last=$(grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | tail -1)
  case "$last" in
    *'&&'*)
      case "$last" in
        *'||'*) : ;;   # ends on '||' - it has its own fallback, not this bug class
        *) echo "  $f: last statement is a '&&' compound - the script exit status becomes that of its left-hand test"
           echo "        $last"
           tail_ok=0 ;;
      esac ;;
  esac
done
[ "$tail_ok" -eq 1 ] && echo "  OK" || FAIL=1

echo "== 7. svc_start must re-verify Type=simple units [HARD] =="
# systemd reports a Type=simple unit as started the moment the process is forked,
# so `systemctl start` returning 0 says nothing about whether the process will
# still be alive a moment later. Both php-fpm.service and the generated
# mysqld.service are Type=simple; without the re-check in svc_start a service
# that dies on the spot (missing shared library, unusable config) is recorded as
# installed while the installer prints its success banner -- which is how a
# php-fpm that could not load libsodium.so.26 got past a full install. The
# container smoke job runs weekly and off push, so this pin is what stands
# between a "simplification" of svc_start and the silent return of that bug.
# Details: .workbuddy/ci-smoke-round2.md (the smoke run that found it).
svc_start_body=$(sed -n '/^svc_start()/,/^}/p' include/common.sh)
svc_ok=1
if [ -z "${svc_start_body}" ]; then
  echo "  include/common.sh: svc_start() not found (renamed, or no longer a top-level function)"
  svc_ok=0
elif ! echo "${svc_start_body}" | grep -q 'svc_unit_is_simple'; then
  echo "  include/common.sh: svc_start() no longer re-checks Type=simple units"
  echo "        a service that dies right after fork would be reported as installed again"
  svc_ok=0
fi
[ "$svc_ok" -eq 1 ] && echo "  OK" || FAIL=1

echo ""
if [ "$FAIL" -eq 0 ]; then echo "STATIC CHECKS: PASS"; exit 0; else echo "STATIC CHECKS: FAIL"; exit 1; fi
