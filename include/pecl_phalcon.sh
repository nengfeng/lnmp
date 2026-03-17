#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_pecl_phalcon() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)

    src_url=https://pecl.php.net/get/phalcon-${phalcon_ver}.tgz && Download_src
    tar xzf phalcon-${phalcon_ver}.tgz
    pushd phalcon-${phalcon_ver} > /dev/null
    ${php_install_dir}/bin/phpize
    info_msg "It may take a few minutes... "
    ./configure --with-php-config=${php_install_dir}/bin/php-config
    compile_and_install
    popd > /dev/null

    if [ -f "${phpExtensionDir}/phalcon.so" ]; then
      echo 'extension=phalcon.so' > ${php_install_dir}/etc/php.d/04-phalcon.ini
      success_msg "PHP phalcon module"
      cleanup_src phalcon-${phalcon_ver}
    else
      fail_msg "PHP phalcon module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_phalcon() {
  if [ -e "${php_install_dir}/etc/php.d/04-phalcon.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/04-phalcon.ini
    echo; echo "${CMSG}PHP phalcon module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP phalcon module does not exist! ${CEND}"
  fi
}
