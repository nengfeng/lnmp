#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_pecl_xdebug() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)

    src_url=https://pecl.php.net/get/xdebug-${xdebug_ver}.tgz && Download_src
    tar xzf xdebug-${xdebug_ver}.tgz
    pushd xdebug-${xdebug_ver} > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/xdebug.so" ]; then
      src_url="https://github.com/jokkedk/webgrind/archive/master.zip" && Download_src
      unzip -q webgrind-master.zip
      /bin/mv webgrind-master ${wwwroot_dir}/default/webgrind
      [ ! -e /tmp/xdebug ] && { mkdir /tmp/xdebug; chown ${run_user}:${run_group} /tmp/xdebug; }
      [ ! -e /tmp/webgrind ] && { mkdir /tmp/webgrind; chown ${run_user}:${run_group} /tmp/webgrind; }
      chown -R ${run_user}:${run_group} ${wwwroot_dir}/default/webgrind
      sed -i 's@static $storageDir.*@static $storageDir = "/tmp/webgrind";@' ${wwwroot_dir}/default/webgrind/config.php
      sed -i 's@static $profilerDir.*@static $profilerDir = "/tmp/xdebug";@' ${wwwroot_dir}/default/webgrind/config.php
      cat > ${php_install_dir}/etc/php.d/08-xdebug.ini << EOF
[xdebug]
zend_extension=xdebug.so
xdebug.trace_output_dir=/tmp/xdebug
xdebug.profiler_output_dir = /tmp/xdebug
xdebug.profiler_enable = On
xdebug.profiler_enable_trigger = 1
EOF
      success_msg "PHP xdebug module"
      echo; echo "Webgrind URL: ${CMSG}https://{Public IP}/webgrind ${CEND}"
      cleanup_src xdebug-${xdebug_ver}
    else
      fail_msg "PHP xdebug module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_xdebug() {
  if [ -e "${php_install_dir}/etc/php.d/08-xdebug.ini" ]; then
    rm -rf ${php_install_dir}/etc/php.d/08-xdebug.ini /tmp/{xdebug,webgrind} ${wwwroot_dir}/default/webgrind
    echo; echo "${CMSG}PHP xdebug module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP xdebug module does not exist! ${CEND}"
  fi
}
