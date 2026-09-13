#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
# Read memory from /proc/meminfo rather than 'free': this file runs before the
# dependency stage installs procps, and a missing 'free' made both values empty
# -- which the arithmetic below reads as 0, i.e. the <=640M profile and
# THREAD=1 (single-threaded builds) on an arbitrarily large machine.
Mem=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
Swap=$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
Mem=${Mem:-512}
Swap=${Swap:-0}

if [[ "${Mem}" -le 640 ]]; then
  Mem_level=512M
  Memory_limit=64
  THREAD=1
elif [[ "${Mem}" -gt 640 && "${Mem}" -le 1280 ]]; then
  Mem_level=1G
  Memory_limit=128
elif [[ "${Mem}" -gt 1280 && "${Mem}" -le 2500 ]]; then
  Mem_level=2G
  Memory_limit=192
elif [[ "${Mem}" -gt 2500 && "${Mem}" -le 3500 ]]; then
  Mem_level=3G
  Memory_limit=256
elif [[ "${Mem}" -gt 3500 && "${Mem}" -le 4500 ]]; then
  Mem_level=4G
  Memory_limit=320
elif [[ "${Mem}" -gt 4500 && "${Mem}" -le 8000 ]]; then
  Mem_level=6G
  Memory_limit=384
elif [[ "${Mem}" -gt 8000 ]]; then
  Mem_level=8G
  Memory_limit=448
fi

# add swapfile
if [ ! -e ~/.lnmp ] && [[ "${Swap}" == '0' ]] && [[ "${Mem}" -le 2048 ]]; then
  echo "${CWARNING}Add Swap file, It may take a few minutes... ${CEND}"
  dd if=/dev/zero of=/swapfile count=2048 bs=1M
  mkswap /swapfile
  swapon /swapfile
  chmod 600 /swapfile
  [ -z "$(grep swapfile /etc/fstab)" ] && echo '/swapfile    swap    swap    defaults    0 0' >> /etc/fstab
fi
