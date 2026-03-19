#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_pecl_ldap() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)
    PHP_detail_ver=$(${php_install_dir}/bin/php-config --version)
    src_url=https://www.php.net/distributions/php-${PHP_detail_ver}.tar.gz && Download_src
    tar xzf php-${PHP_detail_ver}.tar.gz
    pushd php-${PHP_detail_ver}/ext/ldap > /dev/null
    apt-get -y install libldap2-dev
    ln -s /usr/lib/${ARCH}-linux-gnu/libldap.so /usr/lib/
    ln -s /usr/lib/${ARCH}-linux-gnu/liblber.so /usr/lib/
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config --with-ldap --with-libdir=lib/x86_64-linux-gnu
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/ldap.so" ]; then
      echo 'extension=ldap.so' > ${php_install_dir}/etc/php.d/04-ldap.ini
      success_msg "PHP ldap module"
      cleanup_src php-${PHP_detail_ver}
    else
      fail_msg "PHP ldap module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_ldap() {
  if [ -e "${php_install_dir}/etc/php.d/04-ldap.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/04-ldap.ini
    echo; echo "${CMSG}PHP ldap module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP ldap module does not exist! ${CEND}"
  fi
}
