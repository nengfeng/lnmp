#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Behavioural test for the supported-release gate in include/check_os.sh.
#
# static_checks.sh greps the tree and test_offline.sh stubs single functions;
# neither covers a decision table that exists only as control flow. The gate is
# user-visible -- it decides whether the installer runs at all -- and drifts
# quietly: re-widening it to "Debian 9+" costs nothing locally and installs on
# a release nobody tests.
#
# Method: source the REAL file, with only its /etc/os-release path redirected
# to a fixture, in an environment where every side effect is stubbed. Then
# assert accept/refuse per release. No network, no container, milliseconds.
#
# Run: tools/lint/os_gate_checks.sh   (exit 0 = the gate behaves as documented)
#
# The supported set -- Debian 12/13, Ubuntu 24.04/26.04 -- is the same set
# .github/workflows/container.yml exercises. Changing one without the other is
# the mistake this test is meant to catch.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The real file, with the os-release path pointed at the fixture. The `tr -d
# '\r'` is load-bearing on a checkout with core.autocrlf=true: a CRLF line makes
# bash source "path\r" and every case then reports no-verdict instead of a
# verdict, which looks like a gate failure rather than a test artefact.
sed "s#/etc/os-release#$work/os-release#g" include/check_os.sh | tr -d '\r' > "$work/check_os.sh"

# Stubs: die_hard marks a refusal, and everything that would touch the host or
# is absent on a minimal shell is replaced. `tr -d '\r'` for the same reason as
# above -- the probe's own `. ...` line must not carry a CR.
cat <<'PROBE' | tr -d '\r' > "$work/probe.sh"
#!/bin/bash
die_hard(){ echo "REFUSED:$*"; exit 42; }
apt-get(){ return 0; }
arch(){ echo x86_64; }
uname(){ case "$1" in -m) echo x86_64 ;; -r) echo 6.8.0-generic ;; *) echo Linux ;; esac; }
# WORD_BIT=32 + LONG_BIT=64 is what check_os.sh reads as "normal 64-bit";
# anything else sends it down the "32-bit OS are not supported" branch.
getconf(){ case "$1" in WORD_BIT) echo 32 ;; LONG_BIT) echo 64 ;; esac; }
# shellcheck source=/dev/null
. "${CHECK_OS_UNDER_TEST:?CHECK_OS_UNDER_TEST is not set}"
echo ACCEPTED
PROBE

PASS=0
FAIL=0

case_run() {  # case_run <ID> <VERSION_ID> <accept|refuse>
  printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="%s %s"\n' "$1" "$2" "$1" "$2" > "$work/os-release"
  local out got
  out=$(CHECK_OS_UNDER_TEST="$work/check_os.sh" bash "$work/probe.sh" 2>/dev/null)
  case "$out" in
    ACCEPTED) got=accept ;;
    REFUSED*) got=refuse ;;
    *)        got="no-verdict" ;;
  esac
  if [ "$got" = "$3" ]; then
    echo "  PASS  ${1} ${2} -> ${got}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  ${1} ${2} -> ${got} (expected ${3})"
    FAIL=$((FAIL + 1))
  fi
}

echo "== supported releases are accepted =="
case_run debian   12      accept
case_run debian   13      accept
case_run ubuntu   24.04   accept
case_run ubuntu   26.04   accept

echo "== older releases are refused =="
case_run debian   11      refuse
case_run debian   10      refuse
case_run debian   9       refuse
case_run ubuntu   22.04   refuse
case_run ubuntu   20.04   refuse
case_run ubuntu   18.04   refuse

echo "== derivatives are judged by the base they are built on =="
# Linux Mint 22.x and elementary OS 8.x are Ubuntu 24.04 based; Mint 21.x and
# elementary 7.x are Ubuntu 22.04 based; Kali is rolling and tracks testing.
case_run linuxmint  22      accept
case_run elementary 8       accept
case_run kali       2026.2  accept
case_run linuxmint  21      refuse
case_run elementary 7       refuse
case_run deepin      23     refuse

echo "== newer than the supported set is accepted =="
# Everything is built from source; a newer release only has to resolve names.
case_run ubuntu   25.10   accept
case_run debian   14      accept
case_run deepin   25      accept

echo "== unrelated platforms are refused =="
case_run fedora   40      refuse
case_run centos   9       refuse

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "OS GATE CHECKS: PASS ($PASS cases)"
  exit 0
fi
echo "OS GATE CHECKS: FAIL ($PASS passed, $FAIL failed)"
exit 1
