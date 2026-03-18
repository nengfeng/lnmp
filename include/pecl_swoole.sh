#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_pecl_swoole() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)

    src_url=https://pecl.php.net/get/swoole-${swoole_ver}.tgz && Download_src
    tar xzf swoole-${swoole_ver}.tgz
    pushd swoole-${swoole_ver} > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config --enable-openssl --with-openssl-dir=${openssl_install_dir} --enable-http2 --enable-swoole-json --enable-swoole-curl
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/swoole.so" ]; then
      echo 'extension=swoole.so' > ${php_install_dir}/etc/php.d/06-swoole.ini
      success_msg "PHP swoole module"
      cleanup_src swoole-${swoole_ver}
    else
      fail_msg "PHP swoole module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_swoole() {
  if [ -e "${php_install_dir}/etc/php.d/06-swoole.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/06-swoole.ini
    echo; echo "${CMSG}PHP swoole module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP swoole module does not exist! ${CEND}"
  fi
}
