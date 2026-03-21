#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_ZendOPcache() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    PHP_detail_ver=$(${php_install_dir}/bin/php-config --version)

    # PHP 8.5+ has opcache built-in, just need configuration (no .so file needed)
    if [[ "${PHP_detail_ver}" =~ ^8\.[5-9]\. ]] || [[ "${PHP_detail_ver}" =~ ^9\. ]]; then
      # Built-in opcache for PHP 8.5+
      cat > ${php_install_dir}/etc/php.d/02-opcache.ini << EOF
[opcache]
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=${Memory_limit}
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=100000
opcache.max_wasted_percentage=5
opcache.use_cwd=1
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.consistency_checks=0
EOF
      echo "${CSUCCESS}PHP opcache module (built-in) configured successfully! ${CEND}"
    else
      # PHP 8.4 and earlier: check for opcache.so
      phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)
      if [ -f "${phpExtensionDir}/opcache.so" ] || [ -f "${php_install_dir}/lib/php/extensions/*/opcache.so" ]; then
        cat > ${php_install_dir}/etc/php.d/02-opcache.ini << EOF
[opcache]
zend_extension=opcache.so
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=${Memory_limit}
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=100000
opcache.max_wasted_percentage=5
opcache.use_cwd=1
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.consistency_checks=0
EOF
        echo "${CSUCCESS}PHP opcache module installed successfully! ${CEND}"
      else
        echo "${CFAILURE}PHP opcache module not found! ${CEND}"
      fi
    fi
    popd > /dev/null
  fi
}

Uninstall_ZendOPcache() {
  if [ -e "${php_install_dir}/etc/php.d/02-opcache.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/02-opcache.ini
    echo; echo "${CMSG}PHP opcache module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP opcache module does not exist! ${CEND}"
  fi
}
