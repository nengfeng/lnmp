#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_memcached_server() {
  pushd ${current_dir}/src > /dev/null
  # memcached server
  id -u memcached >/dev/null 2>&1 || useradd -M -s /sbin/nologin memcached

  tar xzf memcached-${memcached_ver}.tar.gz
  pushd memcached-${memcached_ver} > /dev/null
  [ ! -d "${memcached_install_dir}" ] && mkdir -p ${memcached_install_dir}
  ./configure --prefix=${memcached_install_dir} --enable-sasl --enable-sasl-pwdb
  compile_and_install
  popd > /dev/null
  if [ -f "${memcached_install_dir}/bin/memcached" ]; then
    success_msg "memcached"
    cleanup_src memcached-${memcached_ver}
    ln -s ${memcached_install_dir}/bin/memcached /usr/bin/memcached
    /bin/cp ../systemd/memcached.service /lib/systemd/system/
    service_action enable memcached
    service_action start memcached
  else
    rm -rf ${memcached_install_dir}
    fail_msg "memcached-server"
  fi
  popd > /dev/null
}

Install_pecl_memcache() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)

    tar xzf memcache-${pecl_memcache_ver}.tgz
    pushd memcache-${pecl_memcache_ver} > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/memcache.so" ]; then
      echo "extension=memcache.so" > ${php_install_dir}/etc/php.d/05-memcache.ini
      success_msg "PHP memcache module"
      cleanup_src memcache-${pecl_memcache_ver}
    else
      fail_msg "PHP memcache module"
    fi
    popd > /dev/null
  fi
}

Install_pecl_memcached() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)
    # php memcached extension
    tar xzf libmemcached-${libmemcached_ver}.tar.gz
    patch -d libmemcached-${libmemcached_ver} -p0 < libmemcached-build.patch
    pushd libmemcached-${libmemcached_ver} > /dev/null
    sed -i "s@lthread -pthread -pthreads@lthread -lpthread -pthreads@" ./configure
    ./configure --with-memcached=${memcached_install_dir}
    compile_and_install
    popd > /dev/null
    cleanup_src libmemcached-${libmemcached_ver}

    tar xzf memcached-${pecl_memcached_ver}.tgz
    pushd memcached-${pecl_memcached_ver} > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/memcached.so" ]; then
      cat > ${php_install_dir}/etc/php.d/05-memcached.ini << EOF
extension=memcached.so
memcached.use_sasl=1
EOF
      success_msg "PHP memcached module"
      cleanup_src memcached-${pecl_memcached_ver}
    else
      fail_msg "PHP memcached module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_memcache() {
  if [ -e "${php_install_dir}/etc/php.d/05-memcache.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/05-memcache.ini
    echo; echo "${CMSG}PHP memcache module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP memcache module does not exist! ${CEND}"
  fi
}

Uninstall_pecl_memcached() {
  if [ -e "${php_install_dir}/etc/php.d/05-memcached.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/05-memcached.ini
    echo; echo "${CMSG}PHP memcached module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP memcached module does not exist! ${CEND}"
  fi
}
