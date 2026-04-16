#!/bin/bash
# Author:  Alpha Eva <kaneawk AT gmail.com>
# SPDX-License-Identifier: Apache-2.0

installDepsDebian() {
  echo "${CMSG}Removing the conflicting packages...${CEND}"

  if [[ "${db_option}" =~ ^[1-6]$ ]]; then
    pkgList="mysql-client mysql-server mysql-common mysql-server-core-5.5 mysql-client-5.5 mariadb-client mariadb-server mariadb-common"
    for Package in ${pkgList};do
      apt-get -y purge ${Package}
    done
    dpkg -l | grep ^rc | awk '{print $2}' | xargs dpkg -P
  fi

  echo "${CMSG}Installing dependencies packages...${CEND}"
  apt-get -y update
  apt-get -y autoremove
  apt-get -yf install
  export DEBIAN_FRONTEND=noninteractive

  # critical security updates
  grep security /etc/apt/sources.list > /tmp/security.sources.list
  apt-get -y upgrade -o Dir::Etc::SourceList=/tmp/security.sources.list

  # Install needed packages
  case "${Debian_ver}" in
    9|10|11|12|13)
      pkgList="debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf libjpeg62-turbo-dev libjpeg-dev libpng-dev libgd-dev libxml2 libxml2-dev zlib1g zlib1g-dev libc6 libc6-dev libc-client2007e-dev libglib2.0-0 libglib2.0-dev bzip2 libzip-dev libbz2-1.0 libncurses5 libncurses5-dev libaio1 libaio-dev numactl libreadline-dev curl libcurl3-gnutls libcurl4-openssl-dev e2fsprogs libkrb5-3 libkrb5-dev libltdl-dev libidn11 libidn11-dev openssl net-tools libssl-dev libtool libevent-dev bison re2c libsasl2-dev libxslt1-dev libicu-dev libpsl-dev locales patch vim zip unzip tmux htop bc dc expect libexpat1-dev libonig-dev libtirpc-dev rsync git lsof lrzsz rsyslog cron logrotate chrony libsqlite3-dev psmisc wget sysv-rc apt-transport-https ca-certificates software-properties-common gnupg ufw"
      ;;
    *)
      die_hard "Your system Debian ${Debian_ver} are not supported!"
      ;;
  esac
  for Package in ${pkgList}; do
    apt-get --no-install-recommends -y install ${Package}
  done
  
  # Debian 13+ libaio time64 transition fix (same as Ubuntu 24.04+)
  if [[ "${Debian_ver}" =~ ^1[3-9]$ ]]; then
    if [ ! -e /usr/lib/x86_64-linux-gnu/libaio.so.1 ]; then
      libaio_src=$(find /usr/lib -name 'libaio.so.1t64*' 2>/dev/null | head -1)
      if [ -n "${libaio_src}" ]; then
        ln -sf "${libaio_src}" /usr/lib/x86_64-linux-gnu/libaio.so.1
        echo "${CMSG}Created libaio.so.1 symlink for Debian 13+ compatibility${CEND}"
      fi
    fi
  fi
}

installDepsUbuntu() {
  # Uninstall the conflicting software
  echo "${CMSG}Removing the conflicting packages...${CEND}"

  if [[ "${db_option}" =~ ^[1-6]$ ]]; then
    pkgList="mysql-client mysql-server mysql-common mysql-server-core-5.5 mysql-client-5.5 mariadb-client mariadb-server mariadb-common"
    for Package in ${pkgList};do
      apt-get -y purge ${Package}
    done
    dpkg -l | grep ^rc | awk '{print $2}' | xargs dpkg -P
  fi

  echo "${CMSG}Installing dependencies packages...${CEND}"
  apt-get -y update
  apt-get -y autoremove
  apt-get -yf install
  export DEBIAN_FRONTEND=noninteractive
  [[ "${Ubuntu_ver}" =~ ^22$ ]] && apt-get -y --allow-downgrades install libicu70=70.1-2 libglib2.0-0=2.72.1-1 libxml2-dev

  # critical security updates
  grep security /etc/apt/sources.list > /tmp/security.sources.list
  apt-get -y upgrade -o Dir::Etc::SourceList=/tmp/security.sources.list

  # Install needed packages
  pkgList="libperl-dev debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf libjpeg8 libjpeg8-dev libpng-dev libpng12-0 libpng12-dev libpng3 libxml2 libxml2-dev zlib1g zlib1g-dev libc6 libc6-dev libc-client2007e-dev libglib2.0-0 libglib2.0-dev bzip2 libzip-dev libbz2-1.0 libncurses5 libncurses5-dev libaio1 libaio-dev numactl libreadline-dev curl libcurl3-gnutls libcurl4-gnutls-dev libcurl4-openssl-dev e2fsprogs libkrb5-3 libkrb5-dev libltdl-dev libidn11 libidn11-dev openssl net-tools libssl-dev libtool libevent-dev re2c libsasl2-dev libxslt1-dev libicu-dev libpsl-dev libsqlite3-dev libcloog-ppl1 bison patch vim zip unzip tmux htop bc dc expect libexpat1-dev rsyslog libonig-dev libtirpc-dev libnss3 rsync git lsof lrzsz chrony psmisc wget sysv-rc apt-transport-https ca-certificates software-properties-common gnupg ufw"
  export DEBIAN_FRONTEND=noninteractive
  for Package in ${pkgList}; do
    apt-get --no-install-recommends -y install ${Package}
  done
  
  # Ubuntu 24.04+ libaio time64 transition fix
  # The package installs libaio.so.1t64 but MySQL expects libaio.so.1
  if [[ "${Ubuntu_ver}" =~ ^2[4-9]$ ]]; then
    if [ ! -e /usr/lib/x86_64-linux-gnu/libaio.so.1 ]; then
      # Find the actual libaio library file
      libaio_src=$(find /usr/lib -name 'libaio.so.1t64*' 2>/dev/null | head -1)
      if [ -n "${libaio_src}" ]; then
        ln -sf "${libaio_src}" /usr/lib/x86_64-linux-gnu/libaio.so.1
        echo "${CMSG}Created libaio.so.1 symlink for Ubuntu 24.04+ compatibility${CEND}"
      fi
    fi
  fi
}

installDepsBySrc() {
  pushd ${current_dir}/src > /dev/null
  if ! command -v icu-config > /dev/null 2>&1 || icu-config --version | grep -q '^3\.' || [[ "${Ubuntu_ver}" == "20" ]]; then
    tar xzf icu4c-${icu4c_ver}-src.tgz
    pushd icu/source > /dev/null
    ./configure --prefix=/usr/local
    compile_and_install
    popd > /dev/null
    cleanup_src icu
  fi

  if command -v lsof >/dev/null 2>&1; then
    echo 'already initialize' > ~/.lnmp
  else
    die_hard "${PM} config error parsing file failed"
  fi

  popd > /dev/null
}
