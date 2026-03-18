#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_pecl_fileinfo() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)
    PHP_detail_ver=$(${php_install_dir}/bin/php-config --version)
    src_url=https://secure.php.net/distributions/php-${PHP_detail_ver}.tar.gz && Download_src
    tar xzf php-${PHP_detail_ver}.tar.gz
    pushd php-${PHP_detail_ver}/ext/fileinfo > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config
    sed -i 's@^CFLAGS =.*@CFLAGS = -std=c99 -g@' Makefile
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/fileinfo.so" ]; then
      echo 'extension=fileinfo.so' > ${php_install_dir}/etc/php.d/04-fileinfo.ini
      success_msg "PHP fileinfo module"
      cleanup_src php-${PHP_detail_ver}
    else
      fail_msg "PHP fileinfo module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_fileinfo() {
  if [ -e "${php_install_dir}/etc/php.d/04-fileinfo.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/04-fileinfo.ini
    echo; echo "${CMSG}PHP fileinfo module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP fileinfo module does not exist! ${CEND}"
  fi
}
