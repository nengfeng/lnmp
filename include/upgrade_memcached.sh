#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Upgrade_Memcached() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${memcached_install_dir}/bin/memcached" ] && echo "${CWARNING}Memcached is not installed on your system! ${CEND}" && exit 1
  OLD_memcached_ver=$(${memcached_install_dir}/bin/memcached -V | awk '{print $2}')
  Latest_memcached_ver=$(curl --connect-timeout 2 -m 3 -s https://github.com/memcached/memcached/wiki/ReleaseNotes | grep 'internal present.*ReleaseNotes' |  grep -oE "[0-9]\.[0-9]\.[0-9]+" | head -1)
  Latest_memcached_ver=${Latest_memcached_ver:-1.6.35}
  echo "Current Memcached Version: ${CMSG}${OLD_memcached_ver}${CEND}"
  while :; do echo
    [ "${memcached_flag}" != 'y' ] && read -e -p "Please input upgrade Memcached Version(default: ${Latest_memcached_ver}): " NEW_memcached_ver
    NEW_memcached_ver=${NEW_memcached_ver:-${Latest_memcached_ver}}
    if [ "${NEW_memcached_ver}" != "${OLD_memcached_ver}" ]; then
      # Download from official source (mirror doesn't host memcached)
      DOWN_ADDR=https://www.memcached.org/files
      [ ! -e "memcached-${NEW_memcached_ver}.tar.gz" ] && wget -c ${DOWN_ADDR}/memcached-${NEW_memcached_ver}.tar.gz > /dev/null 2>&1
      if [ -e "memcached-${NEW_memcached_ver}.tar.gz" ]; then
        echo "Download [${CMSG}memcached-${NEW_memcached_ver}.tar.gz${CEND}] successfully! "
        break
      else
        echo "${CWARNING}Memcached version does not exist! ${CEND}"
      fi
    else
      echo "${CWARNING}input error! Upgrade Memcached version is the same as the old version${CEND}"
      exit
    fi
  done

  if [ -e "memcached-${NEW_memcached_ver}.tar.gz" ]; then
    echo "[${CMSG}memcached-${NEW_memcached_ver}.tar.gz${CEND}] found"
    if [ "${memcached_flag}" != 'y' ]; then
      echo "Press Ctrl+c to cancel or Press any key to continue..."
      char=$(get_char)
    fi
    tar xzf memcached-${NEW_memcached_ver}.tar.gz
    pushd memcached-${NEW_memcached_ver}
    [ -f Makefile ] && make clean || true
    ./configure --prefix=${memcached_install_dir}
    compile_check

    if [ -e "memcached" ]; then
      echo "Restarting Memcached..."
      service_action stop memcached
      make install
      service_action start memcached
      popd > /dev/null
      echo "You have ${CMSG}successfully${CEND} upgrade from ${CWARNING}${OLD_memcached_ver}${CEND} to ${CWARNING}${NEW_memcached_ver}${CEND}"
      cleanup_src memcached-${NEW_memcached_ver}
    else
      fail_msg "Memcached upgrade"
    fi
  fi
  popd > /dev/null
}
