#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_pecl_pgsql() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)
    PHP_detail_ver=$(${php_install_dir}/bin/php-config --version)
    tar xzf php-${PHP_detail_ver}.tar.gz
    pushd php-${PHP_detail_ver}/ext/pgsql > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-pgsql=${pgsql_install_dir} --with-php-config=${php_install_dir}/bin/php-config
    compile_and_install
    popd > /dev/null
    pushd php-${PHP_detail_ver}/ext/pdo_pgsql > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-pdo-pgsql=${pgsql_install_dir} --with-php-config=${php_install_dir}/bin/php-config
    compile_and_install
    popd > /dev/null
    if [[ -f "${phpExtensionDir}/pgsql.so" && -f "${phpExtensionDir}/pdo_pgsql.so" ]]; then
      echo 'extension=pgsql.so' > ${php_install_dir}/etc/php.d/07-pgsql.ini
      echo 'extension=pdo_pgsql.so' >> ${php_install_dir}/etc/php.d/07-pgsql.ini
      success_msg "PHP pgsql module"
      cleanup_src php-${PHP_detail_ver}
    else
      fail_msg "PHP pgsql module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_pgsql() {
  if [ -e "${php_install_dir}/etc/php.d/07-pgsql.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/07-pgsql.ini
    echo; echo "${CMSG}PHP pgsql module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP pgsql module does not exist! ${CEND}"
  fi
}
