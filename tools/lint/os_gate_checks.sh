#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Behavioural test for the supported-release gate.
#
# The gate lives in TWO places, and both must agree:
#   include/check_os.sh  - refuses early, with a message naming the release
#   include/check_sw.sh  - its case statements also *select the package list*
#                          per release, and refuse anything without one
# Neither static_checks.sh (which greps the tree) nor test_offline.sh (which
# stubs single functions) covers either one, and they drift quietly: turning
# the check back into a lower bound ("everything from Debian 12 up") is a small
# edit that nothing local questions, and adding a release to one file but not
# the other is exactly how Ubuntu 26.04 first failed (check_os.sh admitted it
# once patched, check_sw.sh still died on its case statement).
#
# Method: source the REAL files with every side effect stubbed, and assert
# accept/refuse per release -- against both gates, on the same table. No
# network, no container, milliseconds.
#
# Run: tools/lint/os_gate_checks.sh   (exit 0 = both gates behave as documented)
#
# The supported set -- Debian 12/13, Ubuntu 24.04/26.04 -- is the set
# .github/workflows/container.yml exercises, per the support policy in README:
# only the last two or three official releases of each distribution, Ubuntu LTS
# only. It is an exact list, not a floor, so a release newer than the list is
# refused as well -- there is no verified package list for it. Changing one
# place without the others is the mistake this test is meant to catch.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

# Scratch space, deliberately not `mktemp -d`. mktemp(1) honours TMPDIR/TEMP,
# and on Git Bash those hold Windows paths (C:\Users\...\Temp), which mktemp
# hands back verbatim: "C:\Users\...\Temp/tmp.XXXX" is not a usable POSIX path
# here, so every redirect below would land in a literal ./C:/... file, the
# fixtures would never be written and all 21 cases would report "refused" for
# entirely the wrong reason. Under the repository the path is always usable;
# .workbuddy/ is gitignored, so nothing shows up in git even if the trap does
# not get to run.
work="$ROOT/.workbuddy/tmp/os-gate.$$"
rm -rf "$work"
mkdir -p "$work" || { echo "cannot create a work directory under $ROOT/.workbuddy/tmp"; exit 1; }
trap 'rm -rf "$work"' EXIT

# `tr -d '\r'` is load-bearing on a checkout with core.autocrlf=true: a CRLF
# line makes bash source "path\r" and every case reports an error instead of a
# verdict, which looks like a gate failure rather than a test artefact.
sed "s#/etc/os-release#$work/os-release#g" include/check_os.sh | tr -d '\r' > "$work/check_os.sh"
tr -d '\r' < include/check_sw.sh > "$work/check_sw.sh"

# --- gate 1: include/check_os.sh -------------------------------------------
cat <<'PROBE' | tr -d '\r' > "$work/probe_os.sh"
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

# --- gate 2: include/check_sw.sh -------------------------------------------
# check_sw.sh is sourced only for its installDeps* functions; every command
# they call is replaced so nothing touches the host. The version variables are
# set directly, because in the real flow check_os.sh has already computed them
# -- that is what keeps this section a test of the second gate alone.
cat <<'PROBE' | tr -d '\r' > "$work/probe_sw.sh"
#!/bin/bash
die_hard(){ echo "REFUSED:$*"; exit 42; }
apt-get(){ return 0; }
uname(){ echo x86_64; }
# shellcheck source=/dev/null
. "${CHECK_SW_UNDER_TEST:?CHECK_SW_UNDER_TEST is not set}"
purge_conflicting_db_packages(){ return 0; }
install_security_updates(){ return 0; }
resolve_pkg_name(){ echo "$1"; }
apt_install_packages(){ return 0; }
if [ "${FIX_FAMILY}" = debian ]; then
  Debian_ver="${FIX_VER}"; Ubuntu_ver=""
  installDepsDebian || exit 90
else
  Ubuntu_ver="${FIX_VER}"; Debian_ver=""
  installDepsUbuntu || exit 90
fi
echo ACCEPTED
PROBE

PASS=0
FAIL=0

# The probes are not restricted to a single line of output: installDepsDebian/
# installDepsUbuntu print their progress ("Removing the conflicting packages...")
# before the verdict, so match the LAST verdict marker rather than comparing the
# whole block.
verdict() {  # verdict <raw output> -> accept | refuse | no-verdict
  local line result=""
  while IFS= read -r line; do
    case "$line" in
      ACCEPTED) result=accept ;;
      REFUSED*) result=refuse ;;
    esac
  done <<< "$1"
  echo "${result:-no-verdict}"
}

# case_run <ID> <VERSION_ID> <mapped-family> <mapped-version> <accept|refuse>
case_run() {
  printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="%s %s"\n' "$1" "$2" "$1" "$2" > "$work/os-release"
  local raw_os raw_sw got_os got_sw ok=1 line
  raw_os=$(CHECK_OS_UNDER_TEST="$work/check_os.sh" bash "$work/probe_os.sh" 2>/dev/null)
  raw_sw=$(FIX_FAMILY="$3" FIX_VER="$4" \
             CHECK_SW_UNDER_TEST="$work/check_sw.sh" bash "$work/probe_sw.sh" 2>/dev/null)
  got_os=$(verdict "$raw_os")
  got_sw=$(verdict "$raw_sw")
  [ "$got_os" = "$5" ] || ok=0
  [ "$got_sw" = "$5" ] || ok=0
  if [ "$ok" = 1 ]; then
    echo "  PASS  ${1} ${2} -> ${got_os} (check_os.sh + check_sw.sh)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  ${1} ${2} -> check_os.sh=${got_os} check_sw.sh=${got_sw} (expected ${5})"
    if [ "$got_os" != "$5" ]; then
      line=$(printf '%s' "$raw_os" | tail -n1 | cut -c1-150)
      echo "          check_os.sh said: ${line:-<no output>}"
    fi
    if [ "$got_sw" != "$5" ]; then
      line=$(printf '%s' "$raw_sw" | tail -n1 | cut -c1-150)
      echo "          check_sw.sh said: ${line:-<no output>}"
    fi
    FAIL=$((FAIL + 1))
  fi
}

echo "== supported releases are accepted =="
case_run debian     12      debian 12    accept
case_run debian     13      debian 13    accept
case_run ubuntu     24.04   ubuntu 24    accept
case_run ubuntu     26.04   ubuntu 26    accept

echo "== older releases are refused =="
case_run debian     11      debian 11    refuse
case_run debian     10      debian 10    refuse
case_run debian     9       debian 9     refuse
case_run ubuntu     22.04   ubuntu 22    refuse
case_run ubuntu     20.04   ubuntu 20    refuse
case_run ubuntu     18.04   ubuntu 18    refuse

echo "== derivatives are judged by the base they are built on =="
# Columns 3-4 are the base each derivative maps to in check_os.sh. Linux Mint
# 22.x and elementary OS 8.x are Ubuntu 24.04 based, Mint 21.x and elementary
# 7.x are 22.04 based, Kali is rolling (floored at Debian 12), deepin 23 is
# Debian 11. A new derivative release must be added to that table, or it is
# refused even when its base is supported.
case_run linuxmint  22      ubuntu 24    accept
case_run elementary 8       ubuntu 24    accept
case_run kali       2026.2  debian 12    accept
case_run linuxmint  21      ubuntu 22    refuse
case_run elementary 7       ubuntu 22    refuse
case_run deepin     23      debian 11    refuse

echo "== releases newer than the supported set are refused too =="
# Not out of caution for its own sake: there is no verified package list for
# them, so admitting one would fail later with a message that names a package
# instead of naming the release. Add the release here and to both files.
case_run ubuntu     25.10   ubuntu 25    refuse
case_run debian     14      debian 14    refuse
case_run deepin     25      debian 25    refuse

echo "== unrelated platforms are refused =="
case_run fedora   40      ubuntu 40    refuse
case_run centos   9       debian 9     refuse

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "OS GATE CHECKS: PASS ($PASS cases, both gates)"
  exit 0
fi
echo "OS GATE CHECKS: FAIL ($PASS passed, $FAIL failed)"
exit 1
