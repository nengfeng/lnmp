#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Upgrade_Redis() {
  pushd ${current_dir}/src > /dev/null
  [ ! -d "$redis_install_dir" ] && echo "${CWARNING}Redis is not installed on your system! ${CEND}" && exit 1
  OLD_redis_ver=$($redis_install_dir/bin/redis-cli --version | awk '{print $2}')
  Latest_redis_ver=$(curl --connect-timeout 2 -m 3 -s https://download.redis.io/releases/00-RELEASENOTES | awk '/Released/{print $2}' | head -1)
  Latest_redis_ver=${Latest_redis_ver:-7.4.2}
  echo "Current Redis Version: ${CMSG}$OLD_redis_ver${CEND}"
  while :; do echo
    [ "${redis_flag}" != 'y' ] && read -e -p "Please input upgrade Redis Version(default: ${Latest_redis_ver}): " NEW_redis_ver
    NEW_redis_ver=${NEW_redis_ver:-${Latest_redis_ver}}
    if [ "$NEW_redis_ver" != "$OLD_redis_ver" ]; then
      [ ! -e "redis-$NEW_redis_ver.tar.gz" ] && wget -c https://download.redis.io/releases/redis-$NEW_redis_ver.tar.gz > /dev/null 2>&1
      if [ -e "redis-$NEW_redis_ver.tar.gz" ]; then
        echo "Download [${CMSG}redis-$NEW_redis_ver.tar.gz${CEND}] successfully! "
        break
      else
        echo "${CWARNING}Redis version does not exist! ${CEND}"
      fi
    else
      echo "${CWARNING}input error! Upgrade Redis version is the same as the old version${CEND}"
      exit
    fi
  done

  if [ -e "redis-$NEW_redis_ver.tar.gz" ]; then
    echo "[${CMSG}redis-$NEW_redis_ver.tar.gz${CEND}] found"
    if [ "${redis_flag}" != 'y' ]; then
      echo "Press Ctrl+c to cancel or Press any key to continue..."
      char=$(get_char)
    fi
    tar xzf redis-$NEW_redis_ver.tar.gz
    pushd redis-$NEW_redis_ver
    [ -f Makefile ] && make clean || true
    compile_check

    if [ -f "src/redis-server" ]; then
      echo "Restarting Redis..."
      service_action stop redis-server
      /bin/cp src/{redis-benchmark,redis-check-aof,redis-check-rdb,redis-cli,redis-sentinel,redis-server} $redis_install_dir/bin/
      service_action start redis-server
      popd > /dev/null
      echo "You have ${CMSG}successfully${CEND} upgrade from ${CWARNING}$OLD_redis_ver${CEND} to ${CWARNING}$NEW_redis_ver${CEND}"
      cleanup_src redis-$NEW_redis_ver
    else
      fail_msg "Redis upgrade"
    fi
  fi
  popd > /dev/null
}
