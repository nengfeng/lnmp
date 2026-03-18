#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

# Default checksum verification setting
VERIFY_CHECKSUM="${VERIFY_CHECKSUM:-yes}"

Upgrade_PHP() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${php_install_dir}" ] && echo "${CWARNING}PHP is not installed on your system! ${CEND}" && exit 1
  OLD_php_ver=$(${php_install_dir}/bin/php-config --version)
  pythonCtl=python
  command -v python3 > /dev/null 2>&1 && pythonCtl=python3
  Latest_php_ver=$(curl --connect-timeout 2 -m 3 -s https://www.php.net/releases/active.php | ${pythonCtl} -mjson.tool | awk '/version/{print $2}' | sed 's/"//g' | grep "${OLD_php_ver%.*}")
  Latest_php_ver=${Latest_php_ver:-8.3.20}
  echo
  echo "Current PHP Version: ${CMSG}$OLD_php_ver${CEND}"
  while :; do echo
    [ "${php_flag}" != 'y' ] && read -e -p "Please input upgrade PHP Version(Default: $Latest_php_ver): " NEW_php_ver
    NEW_php_ver=${NEW_php_ver:-${Latest_php_ver}}
    if [[ "${NEW_php_ver%.*}" == "${OLD_php_ver%.*}" ]]; then
      local file_name="php-${NEW_php_ver}.tar.gz"
      if [ ! -e "${file_name}" ]; then
        echo "Downloading PHP ${NEW_php_ver}..."
        # 尝试官方源
        src_url="https://www.php.net/distributions/${file_name}"
        Download_src
        # 验证 SHA256 校验码
        if [ -e "${file_name}" ]; then
          verify_sha256 "${file_name}" "https://www.php.net/distributions/${file_name}.sha256" || {
            # 校验失败，尝试 GitHub 备用源
            echo "${CYELLOW}Checksum verification failed, trying GitHub fallback...${CEND}"
            rm -f "${file_name}"
            src_url="https://github.com/php/php-src/archive/refs/tags/php-${NEW_php_ver}.tar.gz"
            Download_src
            # GitHub 下载需要重命名目录
            if [ -e "${file_name}" ]; then
              local archive_dir=$(tar -tzf "${file_name}" 2>/dev/null | head -1 | cut -d'/' -f1)
              if [ -n "${archive_dir}" ] && [ "${archive_dir}" != "php-${NEW_php_ver}" ]; then
                tar -xzf "${file_name}"
                mv "${archive_dir}" "php-${NEW_php_ver}"
                tar -czf "${file_name}" "php-${NEW_php_ver}"
                rm -rf "php-${NEW_php_ver}"
              fi
            fi
          }
        fi
      fi
      if [ -e "${file_name}" ]; then
        echo "Download [${CMSG}${file_name}${CEND}] successfully! "
      else
        echo "${CWARNING}PHP version does not exist or download failed! ${CEND}"
      fi
      break
    else
      echo "${CWARNING}input error! ${CEND}Please only input '${CMSG}${OLD_php_ver%.*}.xx${CEND}'"
      [[ "${php_flag}" == y ]] && exit
    fi
  done

  if [ -e "php-${NEW_php_ver}.tar.gz" ]; then
    echo "[${CMSG}php-${NEW_php_ver}.tar.gz${CEND}] found"
    if [ "${php_flag}" != 'y' ]; then
      echo "Press Ctrl+c to cancel or Press any key to continue..."
      char=$(get_char)
    fi
    tar xzf php-${NEW_php_ver}.tar.gz
    pushd php-${NEW_php_ver}
    if [ -e ext/openssl/openssl.c ] && ! grep -Eqi '^#ifdef RSA_SSLV23_PADDING' ext/openssl/openssl.c; then
      sed -i '/OPENSSL_SSLV23_PADDING/i#ifdef RSA_SSLV23_PADDING' ext/openssl/openssl.c
      sed -i '/OPENSSL_SSLV23_PADDING/a#endif' ext/openssl/openssl.c
    fi
    make clean
    export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig/:$PKG_CONFIG_PATH
    ${php_install_dir}/bin/php -i |grep 'Configure Command' | awk -F'=>' '{print $2}' | bash
    make ZEND_EXTRA_LIBS='-liconv' -j ${THREAD}
    echo "Stoping php-fpm..."
    svc_stop php-fpm
    make install
    echo "Starting php-fpm..."
    svc_start php-fpm
    popd > /dev/null
    echo "You have ${CMSG}successfully${CEND} upgrade from ${CWARNING}$OLD_php_ver${CEND} to ${CWARNING}${NEW_php_ver}${CEND}"
    rm -rf php-${NEW_php_ver}
  fi
  popd > /dev/null
}
