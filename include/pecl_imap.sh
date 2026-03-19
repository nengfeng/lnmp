#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_pecl_imap() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    apt-get -y install libc-client2007e-dev
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)
    PHP_detail_ver=$(${php_install_dir}/bin/php-config --version)
    src_url=https://www.php.net/distributions/php-${PHP_detail_ver}.tar.gz && Download_src
    tar xzf php-${PHP_detail_ver}.tar.gz
    pushd php-${PHP_detail_ver}/ext/imap > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config --with-kerberos --with-imap --with-imap-ssl
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/imap.so" ]; then
      echo 'extension=imap.so' > ${php_install_dir}/etc/php.d/04-imap.ini
      success_msg "PHP imap module"
      cleanup_src php-${PHP_detail_ver}
    else
      fail_msg "PHP imap module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_imap() {
  if [ -e "${php_install_dir}/etc/php.d/04-imap.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/04-imap.ini
    echo; echo "${CMSG}PHP imap module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP imap module does not exist! ${CEND}"
  fi
}
