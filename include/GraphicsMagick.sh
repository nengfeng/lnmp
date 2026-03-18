#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_GraphicsMagick() {
  if [ -d "${gmagick_install_dir}" ]; then
    echo "${CWARNING}GraphicsMagick already installed! ${CEND}"
  else
    pushd ${current_dir}/src > /dev/null
    tar xJf GraphicsMagick-${graphicsmagick_ver}.tar.xz
    pushd GraphicsMagick-${graphicsmagick_ver} > /dev/null
    ./configure --prefix=${gmagick_install_dir} --enable-shared --enable-static --enable-symbol-prefix
    compile_and_install
    popd > /dev/null
    cleanup_src GraphicsMagick-${graphicsmagick_ver}
    popd > /dev/null
  fi
}

Uninstall_GraphicsMagick() {
  if [ -d "${gmagick_install_dir}" ]; then
    rm -rf ${gmagick_install_dir}
    echo; echo "${CMSG}GraphicsMagick uninstall completed${CEND}"
  fi
}

Install_pecl_gmagick() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)

    tar xzf gmagick-${gmagick_ver}.tgz
    pushd gmagick-${gmagick_ver} > /dev/null
    export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config --with-gmagick=${gmagick_install_dir}
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/gmagick.so" ]; then
      echo 'extension=gmagick.so' > ${php_install_dir}/etc/php.d/03-gmagick.ini
      success_msg "PHP gmagick module"
      cleanup_src gmagick-${gmagick_ver}
    else
      fail_msg "PHP gmagick module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_gmagick() {
  if [ -e "${php_install_dir}/etc/php.d/03-gmagick.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/03-gmagick.ini
    echo; echo "${CMSG}PHP gmagick module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP gmagick module does not exist! ${CEND}"
  fi
}
