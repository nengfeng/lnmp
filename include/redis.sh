#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_redis_server() {
  pushd ${current_dir}/src > /dev/null
  tar xzf redis-${redis_ver}.tar.gz
  pushd redis-${redis_ver} > /dev/null
  compile_check
  if [ -f "src/redis-server" ]; then
    mkdir -p ${redis_install_dir}/{bin,etc,var}
    /bin/cp src/{redis-benchmark,redis-check-aof,redis-check-rdb,redis-cli,redis-sentinel,redis-server} ${redis_install_dir}/bin/
    /bin/cp redis.conf ${redis_install_dir}/etc/
    ln -s ${redis_install_dir}/bin/* /usr/local/bin/
    sed -i 's@pidfile.*@pidfile /var/run/redis/redis.pid@' ${redis_install_dir}/etc/redis.conf
    sed -i "s@logfile.*@logfile ${redis_install_dir}/var/redis.log@" ${redis_install_dir}/etc/redis.conf
    sed -i "s@^dir.*@dir ${redis_install_dir}/var@" ${redis_install_dir}/etc/redis.conf
    sed -i 's@daemonize no@daemonize yes@' ${redis_install_dir}/etc/redis.conf
    sed -i "s@^# bind 127.0.0.1@bind 127.0.0.1@" ${redis_install_dir}/etc/redis.conf
    redis_maxmemory=$(expr $Mem / 8)000000
    [ -z "$(grep ^maxmemory ${redis_install_dir}/etc/redis.conf)" ] && sed -i "s@maxmemory <bytes>@maxmemory <bytes>\nmaxmemory $(expr $Mem / 8)000000@" ${redis_install_dir}/etc/redis.conf
    success_msg "Redis-server"
    popd > /dev/null
    cleanup_src redis-${redis_ver}
    id -u redis >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin redis
    chown -R redis:redis ${redis_install_dir}/{var,etc}

    /bin/cp ../systemd/redis-server.service /lib/systemd/system/
    sed -i "s@/usr/local/redis@${redis_install_dir}@g" /lib/systemd/system/redis-server.service
    service_action enable redis-server
    service_action start redis-server
  else
    rm -rf ${redis_install_dir}
    fail_msg "Redis-server"
  fi
  popd > /dev/null
}

Install_pecl_redis() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)

    tar xzf redis-${pecl_redis_ver}.tgz
    pushd redis-${pecl_redis_ver} > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/redis.so" ]; then
      echo 'extension=redis.so' > ${php_install_dir}/etc/php.d/05-redis.ini
      success_msg "PHP Redis module"
      cleanup_src redis-${pecl_redis_ver}
    else
      fail_msg "PHP Redis module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_redis() {
  if [ -e "${php_install_dir}/etc/php.d/05-redis.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/05-redis.ini
    echo; echo "${CMSG}PHP redis module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP redis module does not exist! ${CEND}"
  fi
}
