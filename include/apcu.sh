#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_APCU() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)
    tar xzf apcu-${apcu_ver}.tgz
    pushd apcu-${apcu_ver} > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config
    compile_and_install
    if [ -f "${phpExtensionDir}/apcu.so" ]; then
      cat > ${php_install_dir}/etc/php.d/02-apcu.ini << EOF
[apcu]
extension=apcu.so
apc.enabled=1
apc.shm_size=32M
apc.ttl=7200
apc.enable_cli=1
EOF
      /bin/cp apc.php ${wwwroot_dir}/default
      popd > /dev/null
      success_msg "PHP APCu module"
      cleanup_src apcu-${apcu_ver} package.xml
    else
      fail_msg "PHP APCu module"
    fi
    popd > /dev/null
  fi
}

Uninstall_APCU() {
  if [ -e "${php_install_dir}/etc/php.d/02-apcu.ini" ]; then
    rm -rf ${php_install_dir}/etc/php.d/02-apcu.ini ${wwwroot_dir}/default/apc.php
    echo; echo "${CMSG}PHP apcu module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP apcu module does not exist! ${CEND}"
  fi
}
