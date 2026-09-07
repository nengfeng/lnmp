#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: Unified PHP installation function

# Install PHP (unified for all versions)
# Usage: Install_PHP <php_ver> <php_with_ssl>
#   php_ver:     e.g. php84_ver, php83_ver, php85_ver
#   php_with_ssl: SSL configure option from versions.txt
Install_PHP() {
  local php_ver=$1
  local php_ssl=$2

  pushd ${current_dir}/src > /dev/null

  . ../include/php-common.sh

  php_with_ssl=${php_ssl}
  php_with_openssl='--with-openssl'
  php_with_curl='--with-curl'

  create_run_user
  if ! install_php_deps ${php_ver}; then
    echo "${CFAILURE}PHP dependency build failed, aborting PHP installation${CEND}"
    popd > /dev/null
    return 1
  fi
  if ! install_php_source ${php_ver} ${php_install_dir} ${THREAD}; then
    popd > /dev/null
    return 1
  fi
  if ! post_install_php ${php_ver} ${php_install_dir} ${Mem} ${server_scenario}; then
    echo "${CFAILURE}PHP post-install configuration failed${CEND}"
    popd > /dev/null
    return 1
  fi

  popd > /dev/null
}
