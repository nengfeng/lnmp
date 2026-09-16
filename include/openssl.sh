#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

# All supported PHP versions use the same OpenSSL configure argument, so a
# single php_with_ssl variable serves every version (each include/php-X.Y.sh
# passes ${php_with_ssl} to the unified Install_PHP). Adding a new PHP version
# no longer needs a new variable here -- the value is identical across versions.
# The _with_openssl/_with_curl variants were removed as dead: php.sh hardcodes
# those two arguments and never consumed the per-version copies.

if openssl version | grep -Eqi 'OpenSSL 1.0.2*'; then
  php_with_ssl="--with-ssl"
elif openssl version | grep -Eqi 'OpenSSL 1.1.*'; then
  php_with_ssl="--with-ssl"

  [[ ${php_option} =~ ^[1-3]$ ]] && with_old_openssl_flag=y
elif openssl version | grep -Eqi 'OpenSSL 3.*'; then
  php_with_ssl="--with-ssl"

  [[ ${php_option} =~ ^[1-3]$ ]] && with_old_openssl_flag=y
else
  php_with_ssl="--with-ssl=${openssl_install_dir}"

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