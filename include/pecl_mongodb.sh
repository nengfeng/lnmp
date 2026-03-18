#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_pecl_mongodb() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)

    src_url=https://pecl.php.net/get/mongodb-${pecl_mongodb_ver}.tgz && Download_src
    tar xzf mongodb-${pecl_mongodb_ver}.tgz
    pushd mongodb-${pecl_mongodb_ver} > /dev/null
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/mongodb.so" ]; then
      echo 'extension=mongodb.so' > ${php_install_dir}/etc/php.d/07-mongodb.ini
      success_msg "PHP mongodb module"
      cleanup_src mongodb-${pecl_mongodb_ver}
    else
      fail_msg "PHP mongodb module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_mongodb() {
  if [ -e "${php_install_dir}/etc/php.d/07-mongodb.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/07-mongodb.ini
    echo; echo "${CMSG}PHP mongodb module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP mongodb module does not exist! ${CEND}"
  fi
}
