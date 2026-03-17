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
    [[ "${Debian_ver}" =~ ^202 ]] && Debian_ver=10
  fi
elif [[ "${Platform}" =~ ^ubuntu$|^linuxmint$|^elementary$ ]]; then
  PM=apt-get
  Family=ubuntu
  Ubuntu_ver=${VERSION_MAIN_ID}
  if [[ "${Platform}" =~ ^linuxmint$ ]]; then
    [[ "${VERSION_MAIN_ID}" =~ ^18$ ]] && Ubuntu_ver=16
    [[ "${VERSION_MAIN_ID}" =~ ^19$ ]] && Ubuntu_ver=18
    [[ "${VERSION_MAIN_ID}" =~ ^20$ ]] && Ubuntu_ver=20
    [[ "${VERSION_MAIN_ID}" =~ ^21$ ]] && Ubuntu_ver=22
  elif [[ "${Platform}" =~ ^elementary$ ]]; then
    [[ "${VERSION_MAIN_ID}" =~ ^5$ ]] && Ubuntu_ver=18
    [[ "${VERSION_MAIN_ID}" =~ ^6$ ]] && Ubuntu_ver=20
    [[ "${VERSION_MAIN_ID}" =~ ^7$ ]] && Ubuntu_ver=22
  fi
else
  die_hard "Does not support this OS. Only Debian 9+, Ubuntu 16+ are supported."
fi

# Check OS Version
if [ ${Debian_ver} -lt 9 >/dev/null 2>&1 ] || [ ${Ubuntu_ver} -lt 16 >/dev/null 2>&1 ]; then
  die_hard "Does not support this OS, Please install Debian 9+,Ubuntu 16+"
fi

command -v gcc > /dev/null 2>&1 || $PM -y install gcc
gcc_ver=$(gcc -dumpversion | awk -F. '{print $1}')

[ ${gcc_ver} -lt 5 >/dev/null 2>&1 ] && redis_ver=6.2.14

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
