#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

if [ -e "/etc/os-release" ]; then
  . /etc/os-release
else
  die_hard "/etc/os-release does not exist!"
fi

# Get OS Version
Platform=${ID,,}
VERSION_MAIN_ID=${VERSION_ID%%.*}
ARCH=$(arch)
if [[ "${Platform}" =~ ^debian$|^deepin$|^kali$ ]]; then
  PM=apt-get
  Family=debian
  Debian_ver=${VERSION_MAIN_ID}
  if [[ "${Platform}" =~ ^deepin$ ]]; then
    [[ "${Debian_ver}" =~ ^20$ ]] && Debian_ver=10
    [[ "${Debian_ver}" =~ ^23$ ]] && Debian_ver=11
  elif [[ "${Platform}" =~ ^kali$ ]]; then
    # Kali is rolling and tracks Debian testing, so its year-based VERSION_ID
    # (2022.1, 2026.2, ...) corresponds to no single Debian release. The old
    # mapping pinned every 202x to Debian 10, which under the gate below
    # would refuse every Kali release; floor it at Debian 12 (bookworm) so a
    # current Kali is not rejected. Granularity limit worth knowing: only the
    # year survives VERSION_MAIN_ID, so a pre-2023.3 Kali (Debian 11 based)
    # cannot be told apart from a current one and passes too.
    [[ "${Debian_ver}" =~ ^202[0-9]$ ]] && Debian_ver=12
  fi
elif [[ "${Platform}" =~ ^ubuntu$|^linuxmint$|^elementary$ ]]; then
  PM=apt-get
  Family=ubuntu
  Ubuntu_ver=${VERSION_MAIN_ID}
  # The derivative tables below translate a derivative's own version into the
  # Ubuntu LTS it is built on, because that is what decides support here. They
  # are hand-maintained: a new derivative release has to be added, or the gate
  # below will refuse it even when its base is supported.
  if [[ "${Platform}" =~ ^linuxmint$ ]]; then
    [[ "${VERSION_MAIN_ID}" =~ ^18$ ]] && Ubuntu_ver=16
    [[ "${VERSION_MAIN_ID}" =~ ^19$ ]] && Ubuntu_ver=18
    [[ "${VERSION_MAIN_ID}" =~ ^20$ ]] && Ubuntu_ver=20
    [[ "${VERSION_MAIN_ID}" =~ ^21$ ]] && Ubuntu_ver=22
    [[ "${VERSION_MAIN_ID}" =~ ^22$ ]] && Ubuntu_ver=24   # Mint 22.x is Ubuntu 24.04
  elif [[ "${Platform}" =~ ^elementary$ ]]; then
    [[ "${VERSION_MAIN_ID}" =~ ^5$ ]] && Ubuntu_ver=18
    [[ "${VERSION_MAIN_ID}" =~ ^6$ ]] && Ubuntu_ver=20
    [[ "${VERSION_MAIN_ID}" =~ ^7$ ]] && Ubuntu_ver=22
    [[ "${VERSION_MAIN_ID}" =~ ^8$ ]] && Ubuntu_ver=24   # elementary 8.x is Ubuntu 24.04
  fi
else
  die_hard "Does not support this OS. Only Debian 12/13 and Ubuntu 24.04/26.04 are supported."
fi

# Check OS Version -- only releases with a verified dependency list are
# accepted: Debian 12/13 and Ubuntu 24.04/26.04, the set CI exercises in
# .github/workflows/container.yml. That is the "last two or three official
# releases of each distribution (Ubuntu: LTS only)" policy documented in
# README, and it is maintained by hand on purpose -- it is not a lower bound.
# This is deliberately the SAME set as the case statements in
# include/check_sw.sh, which also pick the per-release package list: whichever
# layer is reached, an unsupported release is refused.
# A newer release is NOT accepted on faith -- there is no package list for it,
# so it would fail later with a message naming a package instead of the
# release. Add the release to both files (and to the CI matrix) when it has
# been verified.
# Derivative releases are judged by the base they are built on (see above).
# tools/lint/os_gate_checks.sh pins all of the above with an accept/refuse
# table, against both files at once.
case "${Family}" in
  debian)
    case "${Debian_ver}" in
      12|13) ;;
      *) die_hard "Does not support this OS. Only Debian 12/13 and Ubuntu 24.04/26.04 are supported (detected: Debian ${Debian_ver})." ;;
    esac
    ;;
  ubuntu)
    case "${Ubuntu_ver}" in
      24|26) ;;
      *) die_hard "Does not support this OS. Only Debian 12/13 and Ubuntu 24.04/26.04 are supported (detected: Ubuntu ${Ubuntu_ver})." ;;
    esac
    ;;
esac

# Probe gcc defensively: on a minimal image it is absent AND the package index
# is still empty at this point (the dependency stage runs 'apt-get update'
# later), so the install attempt fails. That must not abort the run --
# build-essential brings gcc in during that stage -- and an unknown version
# simply skips the redis downgrade below.
command -v gcc > /dev/null 2>&1 || $PM -y install gcc > /dev/null 2>&1
gcc_ver=$(gcc -dumpversion 2>/dev/null | awk -F. '{print $1}')

if [ -n "${gcc_ver}" ] && [ "${gcc_ver}" -lt 5 ] 2>/dev/null; then
  redis_ver=6.2.14
fi

if uname -m | grep -Eqi "arm|aarch64"; then
  armplatform="y"
  if uname -m | grep -Eqi "armv7"; then
    TARGET_ARCH="armv7"
  elif uname -m | grep -Eqi "armv8"; then
    TARGET_ARCH="arm64"
  elif uname -m | grep -Eqi "aarch64"; then
    TARGET_ARCH="aarch64"
  else
    TARGET_ARCH="unknown"
  fi
fi

# WSL1 kernel: 4.4.0-19041-Microsoft; WSL2: 5.15.90.1-microsoft-standard-WSL2.
# The old field-split missed WSL2 entirely (field 3 is "standard" there);
# a case-insensitive substring match covers both.
if uname -r 2>/dev/null | grep -qi microsoft; then
  Wsl=true
fi

if [[ "$(getconf WORD_BIT)" == "32" ]] && [[ "$(getconf LONG_BIT)" == "64" ]]; then
  if [[ "${TARGET_ARCH}" == 'aarch64' ]]; then
    SYS_ARCH=arm64
    SYS_ARCH_i=aarch64
    SYS_ARCH_n=arm64
  else
    SYS_ARCH=amd64 #openjdk
    SYS_ARCH_i=x86-64 #ioncube
    SYS_ARCH_n=x64 #nodejs
  fi
else
  die_hard "32-bit OS are not supported!"
fi

THREAD=$(grep 'processor' /proc/cpuinfo | sort -u | wc -l)
