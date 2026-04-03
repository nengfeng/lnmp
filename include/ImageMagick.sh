#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_ImageMagick() {
  if [ -d "${imagick_install_dir}" ]; then
    echo "${CWARNING}ImageMagick already installed! ${CEND}"
  else
    pushd ${current_dir}/src > /dev/null
    local imagemagick_filename="ImageMagick-${imagemagick_ver}.tar.gz"
    # GitHub tag download: archive directory is ImageMagick-${ver}, not ImageMagick-ver
    local src_dir="ImageMagick-${imagemagick_ver}"
    
    if [ ! -f "${imagemagick_filename}" ]; then
      echo "${CFAILURE}${imagemagick_filename} not found!${CEND}"
      popd > /dev/null
      return 1
    fi
    
    tar xzf ${imagemagick_filename}
    #if [[ "${PM}" == 'yum' ]]; then
    #  yum -y install libwebp-devel
    #elif [[ "${PM}" == 'apt-get' ]]; then
    #  yum -y install libwebp-dev
    #fi
    pushd ${src_dir} > /dev/null
    ./configure --prefix=${imagick_install_dir} --enable-shared --enable-static
    compile_and_install
    
    # Create symlink for MagickWand-config if needed
    if [ -x "${imagick_install_dir}/bin/MagickWand-config" ]; then
      ln -sf ${imagick_install_dir}/bin/MagickWand-config /usr/local/bin/MagickWand-config 2>/dev/null
    fi
    
    popd > /dev/null
    cleanup_src ${src_dir}
  fi
}

Uninstall_ImageMagick() {
  if [ -d "${imagick_install_dir}" ]; then
    rm -rf ${imagick_install_dir}
    echo; echo "${CMSG}ImageMagick uninstall completed${CEND}"
  fi
}

Install_pecl_imagick() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    # Check if ImageMagick is installed
    if [ ! -d "${imagick_install_dir}" ]; then
      echo "${CFAILURE}ImageMagick not installed! Please install ImageMagick first.${CEND}"
      return 1
    fi
    
    pushd ${current_dir}/src > /dev/null
    phpExtensionDir=$(${php_install_dir}/bin/php-config --extension-dir)

    src_url=https://pecl.php.net/get/imagick-${imagick_ver}.tgz && Download_src
    tar xzf imagick-${imagick_ver}.tgz
    pushd imagick-${imagick_ver} > /dev/null
    
    # Set environment to find MagickWand-config
    export PKG_CONFIG_PATH=${imagick_install_dir}/lib/pkgconfig:/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH
    export PATH=${imagick_install_dir}/bin:$PATH
    
    ${php_install_dir}/bin/phpize
    ./configure --with-php-config=${php_install_dir}/bin/php-config --with-imagick=${imagick_install_dir}
    compile_and_install
    popd > /dev/null
    if [ -f "${phpExtensionDir}/imagick.so" ]; then
      echo 'extension=imagick.so' > ${php_install_dir}/etc/php.d/03-imagick.ini
      success_msg "PHP imagick module"
      cleanup_src imagick-${imagick_ver}
    else
      fail_msg "PHP imagick module"
    fi
    popd > /dev/null
  fi
}

Uninstall_pecl_imagick() {
  if [ -e "${php_install_dir}/etc/php.d/03-imagick.ini" ]; then
    rm -f ${php_install_dir}/etc/php.d/03-imagick.ini
    echo; echo "${CMSG}PHP imagick module uninstall completed${CEND}"
  else
    echo; echo "${CWARNING}PHP imagick module does not exist! ${CEND}"
  fi
}
