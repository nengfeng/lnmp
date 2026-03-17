#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_pecl_yaf() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)

    src_url=https://pecl.php.net/get/yaf-${yaf_ver}.tgz && Download_src
    tar xzf yaf-${yaf_ver}.tgz
    pushd yaf-${yaf_ver} > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/yaf.so" ]; then
      echo 'extension=yaf.so' > ${php_install_dir}/etc/php.d/04-yaf.ini
      success_msg "PHP yaf module"
      cleanup_src yaf-${yaf_ver}
    else
      fail_msg "PHP yaf module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_yaf() {
  if [ -e "${php_install_dir}/etc/php.d/04-yaf.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/04-yaf.ini
    echo; echo "${CMSG}PHP yaf module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP yaf module does not exist! ${CEND}"
  fi
}
