#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

# Only support PHP 8.3, 8.4, 8.5
# All supported PHP versions use the same OpenSSL configuration

openssl_ver_str=$(openssl version 2>/dev/null)
if [[ "${openssl_ver_str}" =~ OpenSSL\ 1\.0\.2 ]]; then
  php83_with_openssl="--with-openssl"
  php84_with_openssl="--with-openssl"
  php85_with_openssl="--with-openssl"

  php83_with_ssl="--with-ssl"
  php84_with_ssl="--with-ssl"
  php85_with_ssl="--with-ssl"

  php83_with_curl="--with-curl"
  php84_with_curl="--with-curl"
  php85_with_curl="--with-curl"
elif [[ "${openssl_ver_str}" =~ OpenSSL\ 1\.1 ]]; then
  php83_with_openssl="--with-openssl"
  php84_with_openssl="--with-openssl"
  php85_with_openssl="--with-openssl"

  php83_with_ssl="--with-ssl"
  php84_with_ssl="--with-ssl"
  php85_with_ssl="--with-ssl"

  php83_with_curl="--with-curl"
  php84_with_curl="--with-curl"
  php85_with_curl="--with-curl"

  [[ ${php_option} =~ ^[1-3]$ ]] && with_old_openssl_flag=y
elif [[ "${openssl_ver_str}" =~ OpenSSL\ 3\. ]]; then
  php83_with_openssl="--with-openssl"
  php84_with_openssl="--with-openssl"
  php85_with_openssl="--with-openssl"

  php83_with_ssl="--with-ssl"
  php84_with_ssl="--with-ssl"
  php85_with_ssl="--with-ssl"

  php83_with_curl="--with-curl"
  php84_with_curl="--with-curl"
  php85_with_curl="--with-curl"

  [[ ${php_option} =~ ^[1-3]$ ]] && with_old_openssl_flag=y
else
  php83_with_openssl="--with-openssl=${openssl_install_dir} --with-openssl-dir=${openssl_install_dir}"
  php84_with_openssl="--with-openssl=${openssl_install_dir} --with-openssl-dir=${openssl_install_dir}"
  php85_with_openssl="--with-openssl=${openssl_install_dir} --with-openssl-dir=${openssl_install_dir}"

  php83_with_ssl="--with-ssl=${openssl_install_dir}"
  php84_with_ssl="--with-ssl=${openssl_install_dir}"
  php85_with_ssl="--with-ssl=${openssl_install_dir}"

  php83_with_curl="--with-curl=${curl_install_dir}"
  php84_with_curl="--with-curl=${curl_install_dir}"
  php85_with_curl="--with-curl=${curl_install_dir}"

  with_old_openssl_flag=y
fi

Install_openSSL() {
  if [[ "${with_old_openssl_flag}" == 'y' ]]; then
    if [ ! -e "${openssl_install_dir}/lib/libssl.a" ]; then
      pushd ${current_dir}/src > /dev/null
      tar xzf openssl-${openssl_ver}.tar.gz
      pushd openssl-${openssl_ver} > /dev/null
      make clean
      ./config -Wl,-rpath=${openssl_install_dir}/lib -fPIC --prefix=${openssl_install_dir} --openssldir=${openssl_install_dir}
      make depend
      compile_and_install
      popd > /dev/null
      # OpenSSL 3.x 默认构建共享库，检查 libcrypto.so 或 libcrypto.a
      if [ -f "${openssl_install_dir}/lib/libcrypto.a" ] || [ -f "${openssl_install_dir}/lib/libcrypto.so" ] || [ -f "${openssl_install_dir}/lib64/libcrypto.so" ]; then
        success_msg "openSSL"
        /bin/cp cacert.pem ${openssl_install_dir}/cert.pem
        cleanup_src openssl-${openssl_ver}
      else
        fail_msg "openSSL"
      fi
      popd > /dev/null
    fi
  fi
}