#!/bin/bash
# Author:  Alpha Eva <kaneawk AT gmail.com>
# SPDX-License-Identifier: Apache-2.0

# Machine architecture token for binary tarball names ($SYS_ARCH_M / aarch64)
SYS_ARCH_M=$(uname -m)

# Purge distro MySQL/MariaDB packages that conflict with our own installs.
# Usage: purge_conflicting_db_packages
purge_conflicting_db_packages() {
  if [[ "${db_option}" =~ ^[1-8]$ ]]; then
    local pkgList="mysql-client mysql-server mysql-common mariadb-client mariadb-server mariadb-common"
    local Package
    for Package in ${pkgList}; do
      apt-get -y purge ${Package} > /dev/null 2>&1
    done
    # Purge residual config; -r guards against an empty list (xargs would
    # otherwise run dpkg with no arguments and error out)
    dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' | xargs -r dpkg -P
  fi
}

# Install security updates only, working with both the legacy one-line
# sources.list format and the deb822 /etc/apt/sources.list.d/*.sources
# format used by Debian 12+/Ubuntu 24.04+ (where the main sources.list is
# usually empty and a plain 'grep security' found nothing).
# Usage: install_security_updates
install_security_updates() {
  local tmp_list=/tmp/security.sources.list

  # Legacy one-line format entries
  grep -hs '^deb .*security' /etc/apt/sources.list /etc/apt/sources.list.d/*.list > ${tmp_list} 2>/dev/null

  # deb822 format: convert 'Types: deb' + 'URIs/Suites' blocks into one-line
  if [ ! -s ${tmp_list} ] && ls /etc/apt/sources.list.d/*.sources > /dev/null 2>&1; then
    awk '
      FNR == 1 && inblock && isdeb { print "deb " types " " uris " " suites " " comps }
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { if (inblock && isdeb) { print "deb " types " " uris " " suites " " comps }; inblock=0; isdeb=0; next }
      /^[^[:space:]]/ { inblock=1 }
      inblock {
        if ($1 == "Types:") types=$2
        if ($1 == "URIs:") uris=$2
        if ($1 == "Suites:") suites=$2
        if ($1 == "Components:") comps=$2
        if (suites ~ /security|-security/) isdeb=1
      }
      END { if (inblock && isdeb) print "deb " types " " uris " " suites " " comps }
    ' /etc/apt/sources.list.d/*.sources >> ${tmp_list} 2>/dev/null
  fi

  if [ -s ${tmp_list} ]; then
    apt-get -y upgrade -o Dir::Etc::SourceList=${tmp_list} -o Dir::Etc::SourceParts=/dev/null
  else
    # No security entry found at all: fall back to a normal upgrade so the
    # box is not left completely unpatched
    echo "${CWARNING}No security sources found, running full upgrade instead${CEND}"
    apt-get -y upgrade
  fi
  rm -f ${tmp_list}
}

# Install a package list, aborting on the first package that cannot be
# installed (the old per-package loop swallowed every failure silently and
# left builds without their headers).
# Usage: apt_install_packages [pkg...]
apt_install_packages() {
  local Package failed=0
  for Package in "$@"; do
    if ! apt-get --no-install-recommends -y install "${Package}" > /dev/null 2>&1; then
      echo "${CFAILURE}Failed to install required package: ${Package}${CEND}"
      failed=1
    fi
  done
  [ ${failed} -ne 0 ] && return 1
  return 0
}

installDepsDebian() {
  echo "${CMSG}Removing the conflicting packages...${CEND}"
  purge_conflicting_db_packages

  echo "${CMSG}Installing dependencies packages...${CEND}"
  apt-get -y update || return 1
  apt-get -y autoremove > /dev/null 2>&1
  apt-get -yf install > /dev/null 2>&1
  export DEBIAN_FRONTEND=noninteractive

  install_security_updates || return 1

  # Packages common to Debian 9-13
  local pkgCommon="debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf libjpeg-dev libpng-dev libgd-dev libxml2 libxml2-dev zlib1g zlib1g-dev libc6 libc6-dev libglib2.0-0 libglib2.0-dev bzip2 libzip-dev libbz2-1.0 libaio1 libaio-dev numactl libreadline-dev curl libcurl4-openssl-dev e2fsprogs libkrb5-3 libkrb5-dev libltdl-dev openssl net-tools libssl-dev libtool libevent-dev bison re2c libsasl2-dev libxslt1-dev libicu-dev libpsl-dev locales patch vim zip unzip tmux htop bc dc expect libexpat1-dev libonig-dev libtirpc-dev rsync git lsof lrzsz rsyslog cron logrotate chrony libsqlite3-dev psmisc wget sysv-rc apt-transport-https ca-certificates software-properties-common gnupg ufw libmaxminddb-dev"

  # Per-release renames/removals:
  #   libc-client2007e-dev: gone in Debian 12+ (no uw-imap in the archive)
  #   libncurses5 -> libncurses6, libidn11 -> libidn12 (Debian 12+)
  #   libcurl3-gnutls: gone in Debian 12+ (libcurl4 covers it)
  #   libglib2.0-dev keeps working via the transitional name
  local pkgExtra=""
  case "${Debian_ver}" in
    9|10|11)
      pkgExtra="libncurses5 libncurses5-dev libidn11 libidn11-dev libcurl3-gnutls libc-client2007e-dev"
      ;;
    12|13)
      pkgExtra="libncurses6 libncurses-dev libidn12 libidn12-dev"
      ;;
    *)
      die_hard "Your system Debian ${Debian_ver} are not supported!"
      ;;
  esac

  apt_install_packages ${pkgCommon} ${pkgExtra} || return 1

  # libaio time64 transition (Debian 13+): package installs libaio.so.1t64
  # but MySQL binaries expect libaio.so.1
  if [[ "${Debian_ver}" =~ ^1[3-9]$ ]]; then
    if [ ! -e /usr/lib/$SYS_ARCH_M-linux-gnu/libaio.so.1 ]; then
      local libaio_src=$(find /usr/lib -name 'libaio.so.1t64*' 2>/dev/null | head -1)
      if [ -n "${libaio_src}" ]; then
        ln -sf "${libaio_src}" /usr/lib/$SYS_ARCH_M-linux-gnu/libaio.so.1
        echo "${CMSG}Created libaio.so.1 symlink for Debian 13+ compatibility${CEND}"
      fi
    fi
  fi
  return 0
}

installDepsUbuntu() {
  echo "${CMSG}Removing the conflicting packages...${CEND}"
  purge_conflicting_db_packages

  echo "${CMSG}Installing dependencies packages...${CEND}"
  apt-get -y update || return 1
  apt-get -y autoremove > /dev/null 2>&1
  apt-get -yf install > /dev/null 2>&1
  export DEBIAN_FRONTEND=noninteractive

  install_security_updates || return 1

  # Packages common to Ubuntu 16-24
  local pkgCommon="libperl-dev debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf libjpeg-dev libpng-dev libgd-dev libxml2 libxml2-dev zlib1g zlib1g-dev libc6 libc6-dev libglib2.0-0 libglib2.0-dev bzip2 libzip-dev libbz2-1.0 libaio1 libaio-dev numactl libreadline-dev curl e2fsprogs libkrb5-3 libkrb5-dev libltdl-dev openssl net-tools libssl-dev libtool libevent-dev re2c libsasl2-dev libxslt1-dev libicu-dev libpsl-dev libsqlite3-dev bison patch vim zip unzip tmux htop bc dc expect libexpat1-dev rsyslog libonig-dev libtirpc-dev libnss3 rsync git lsof lrzsz chrony psmisc wget sysv-rc apt-transport-https ca-certificates software-properties-common gnupg ufw libmaxminddb-dev"

  # Per-release renames/removals:
  #   libpng12*/libpng3/libjpeg8: gone since Ubuntu 18 (libpng-dev/libjpeg-dev)
  #   libcloog-ppl1: never existed on Ubuntu 22+
  #   libncurses5 -> libncurses6, libidn11 -> libidn12 (Ubuntu 22+)
  #   libcurl3-gnutls/libcurl4-gnutls-dev: folded into libcurl4 (22+)
  #   libc-client2007e-dev: not in Ubuntu 20.04+ archives
  local pkgExtra=""
  case "${Ubuntu_ver}" in
    16|18)
      pkgExtra="libjpeg8 libjpeg8-dev libpng12-0 libpng12-dev libpng3 libncurses5 libncurses5-dev libidn11 libidn11-dev libcurl3-gnutls libcurl4-gnutls-dev libcurl4-openssl-dev"
      ;;
    20)
      pkgExtra="libncurses5 libncurses5-dev libidn11 libidn11-dev libcurl3-gnutls libcurl4-gnutls-dev libcurl4-openssl-dev"
      ;;
    22|24)
      pkgExtra="libncurses6 libncurses-dev libidn12 libidn12-dev libcurl4-openssl-dev"
      ;;
    *)
      die_hard "Your system Ubuntu ${Ubuntu_ver} are not supported!"
      ;;
  esac

  apt_install_packages ${pkgCommon} ${pkgExtra} || return 1

  # libaio time64 transition (Ubuntu 24.04+): package installs libaio.so.1t64
  # but MySQL binaries expect libaio.so.1
  if [[ "${Ubuntu_ver}" =~ ^2[4-9]$ ]]; then
    if [ ! -e /usr/lib/$SYS_ARCH_M-linux-gnu/libaio.so.1 ]; then
      local libaio_src=$(find /usr/lib -name 'libaio.so.1t64*' 2>/dev/null | head -1)
      if [ -n "${libaio_src}" ]; then
        ln -sf "${libaio_src}" /usr/lib/$SYS_ARCH_M-linux-gnu/libaio.so.1
        echo "${CMSG}Created libaio.so.1 symlink for Ubuntu 24.04+ compatibility${CEND}"
      fi
    fi
  fi
  return 0
}

installDepsBySrc() {
  pushd ${current_dir}/src > /dev/null
  if ! command -v icu-config > /dev/null 2>&1 || icu-config --version | grep '^3.' || [[ "${Ubuntu_ver}" == "20" ]]; then
    tar xzf icu4c-${icu4c_ver}-src.tgz || { popd > /dev/null; return 1; }
    pushd icu/source > /dev/null
    ./configure --prefix=/usr/local || { popd > /dev/null; return 1; }
    compile_and_install || { popd > /dev/null; return 1; }
    popd > /dev/null
    cleanup_src icu
  fi

  if command -v lsof >/dev/null 2>&1; then
    echo 'already initialize' > ~/.lnmp
  else
    die_hard "${PM} config error parsing file failed"
  fi

  popd > /dev/null
  return 0
}
