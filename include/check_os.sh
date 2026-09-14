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
    # mapping pinned every 202x to Debian 10, which under the minimum below
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
  # are hand-maintained: a new derivative release has to be added, or the
  # minimum check below will refuse it even when its base is supported.
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

# Check OS Version -- the supported set is Debian 12/13 and Ubuntu 24.04/26.04,
# i.e. exactly what CI exercises (.github/workflows/container.yml). Anything
# older is refused, including derivative releases built on an older base;
# anything newer is accepted, because every component is built from source and
# the only thing a newer release has to provide is a resolvable package list.
# The :-99 default means "this family does not apply", so only the branch that
# was actually taken can fail the check.
if [ "${Debian_ver:-99}" -lt 12 ] 2>/dev/null || [ "${Ubuntu_ver:-99}" -lt 24 ] 2>/dev/null; then
  die_hard "Does not support this OS. Only Debian 12/13 and Ubuntu 24.04/26.04 are supported."
fi

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

if [[ "$(uname -r | awk -F- '{print $3}' 2>/dev/null)" == "Microsoft" ]]; then
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

# MySQL binary SSL library version
if [ ${Debian_ver} -ge 9 >/dev/null 2>&1 ] || [ ${Ubuntu_ver} -ge 16 >/dev/null 2>&1 ]; then
  sslLibVer=ssl102
else
  sslLibVer=unknown
fi

[ -e ~/.oneinstack ] && /bin/mv ~/.oneinstack ~/.lnmp
