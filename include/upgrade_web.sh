#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Upgrade_Nginx() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${nginx_install_dir}/sbin/nginx" ] && echo "${CWARNING}Nginx is not installed on your system! ${CEND}" && exit 1
  OLD_nginx_ver_tmp=$(${nginx_install_dir}/sbin/nginx -v 2>&1)
  OLD_nginx_ver=${OLD_nginx_ver_tmp##*/}
  Latest_nginx_ver=$(curl --connect-timeout 2 -m 3 -s https://nginx.org/en/CHANGES | awk '/Changes with nginx/{print$0}' | awk '{print $4}' | head -1)
  echo
  echo "Current Nginx Version: ${CMSG}${OLD_nginx_ver}${CEND}"
  while :; do echo
    [ "${nginx_flag}" != 'y' ] && read -e -p "Please input upgrade Nginx Version(default: ${Latest_nginx_ver}): " NEW_nginx_ver
    NEW_nginx_ver=${NEW_nginx_ver:-${Latest_nginx_ver}}
    if [ "${NEW_nginx_ver}" != "${OLD_nginx_ver}" ]; then
      [ ! -e "nginx-${NEW_nginx_ver}.tar.gz" ] && wget -c https://nginx.org/download/nginx-${NEW_nginx_ver}.tar.gz > /dev/null 2>&1
      if [ -e "nginx-${NEW_nginx_ver}.tar.gz" ]; then
        src_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/openssl-${openssl_ver}.tar.gz" && Download_src
        src_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_ver}/pcre2-${pcre_ver}.tar.gz" && Download_src
        src_url="https://github.com/vision5/ngx_devel_kit/archive/refs/tags/0.3.3.tar.gz" && Download_src
        src_url="https://github.com/openresty/lua-nginx-module/archive/refs/tags/${lua_nginx_module_ver}.tar.gz" && Download_src
        tar xzf openssl-${openssl_ver}.tar.gz
        tar xzf pcre2-${pcre_ver}.tar.gz
        tar xzf ngx_devel_kit.tar.gz
        tar xzf lua-nginx-module-${lua_nginx_module_ver}.tar.gz
        echo "Download [${CMSG}nginx-${NEW_nginx_ver}.tar.gz${CEND}] successfully! "
        break
      else
        echo "${CWARNING}Nginx version does not exist! ${CEND}"
      fi
    else
      echo "${CWARNING}input error! Upgrade Nginx version is the same as the old version${CEND}"
      exit
    fi
  done

  if [ -e "nginx-${NEW_nginx_ver}.tar.gz" ]; then
    echo "[${CMSG}nginx-${NEW_nginx_ver}.tar.gz${CEND}] found"
    if [ "${nginx_flag}" != 'y' ]; then
      echo "Press Ctrl+c to cancel or Press any key to continue..."
      char=$(get_char)
    fi
    ${nginx_install_dir}/sbin/nginx -V &> $$
    nginx_configure_args_tmp=$(cat $$ | grep 'configure arguments:' | awk -F: '{print $2}')
    rm -rf $$
    nginx_configure_args=$(echo ${nginx_configure_args_tmp} | sed "s@lua-nginx-module-\w.\w\+.\w\+ @lua-nginx-module-${lua_nginx_module_ver} @" | sed "s@lua-nginx-module @lua-nginx-module-${lua_nginx_module_ver} @" | sed "s@--with-openssl=../openssl-\w.\w.\w\+ @--with-openssl=../openssl-${openssl_ver} @" | sed "s@--with-pcre=../pcre2-\w.\w\+ @--with-pcre=../pcre2-${pcre_ver} @")
    if echo "$nginx_configure_args" | grep -q lua-nginx-module; then
      ${current_dir}/upgrade.sh --script > /dev/null
      src_url="https://github.com/openresty/luajit2/archive/refs/tags/${luajit2_ver}.tar.gz" && Download_src
      tar xzf luajit2-${luajit2_ver}.tar.gz
      pushd luajit2-${luajit2_ver}
      make && make install
      popd > /dev/null
      rm -rf luajit2-${luajit2_ver}

      src_url="https://github.com/openresty/lua-resty-core/archive/refs/tags/${lua_resty_core_ver}.tar.gz" && Download_src
      tar xzf lua-resty-core-${lua_resty_core_ver}.tar.gz
      pushd lua-resty-core-${lua_resty_core_ver}
      make install
      popd > /dev/null
      rm -rf lua-resty-core-${lua_resty_core_ver}

      src_url="https://github.com/openresty/lua-resty-lrucache/archive/refs/tags/${lua_resty_lrucache_ver}.tar.gz" && Download_src
      tar xzf lua-resty-lrucache-${lua_resty_lrucache_ver}.tar.gz
      pushd lua-resty-lrucache-${lua_resty_lrucache_ver}
      make install
      popd > /dev/null
      rm -rf lua-resty-lrucache-${lua_resty_lrucache_ver}
    fi

    tar xzf nginx-${NEW_nginx_ver}.tar.gz
    pushd nginx-${NEW_nginx_ver}
    [ -f Makefile ] && make clean || true
    sed -i 's@CFLAGS="$CFLAGS -g"@#CFLAGS="$CFLAGS -g"@' auto/cc/gcc # close debug
    export LUAJIT_LIB=/usr/local/lib
    export LUAJIT_INC=/usr/local/include/luajit-2.1
    ./configure ${nginx_configure_args}
    compile_check
    if [ -f "objs/nginx" ]; then
      /bin/mv ${nginx_install_dir}/sbin/nginx{,$(date +%m%d)}
      /bin/cp objs/nginx ${nginx_install_dir}/sbin/nginx
      kill -USR2 $(cat /var/run/nginx.pid)
      sleep 1
      kill -QUIT $(cat /var/run/nginx.pid.oldbin)
      popd > /dev/null
      echo "You have ${CMSG}successfully${CEND} upgrade from ${CWARNING}${OLD_nginx_ver}${CEND} to ${CWARNING}${NEW_nginx_ver}${CEND}"
      cleanup_src nginx-${NEW_nginx_ver}
    else
      fail_msg "Nginx upgrade"
    fi
  fi
  popd > /dev/null
}

Upgrade_Tengine() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${tengine_install_dir}/sbin/nginx" ] && echo "${CWARNING}Tengine is not installed on your system! ${CEND}" && exit 1
  OLD_tengine_ver_tmp=$(${tengine_install_dir}/sbin/nginx -v 2>&1)
  OLD_tengine_ver="$(echo ${OLD_tengine_ver_tmp#*/} | awk '{print $1}')"
  Latest_tengine_ver=$(curl --connect-timeout 2 -m 3 -s https://tengine.taobao.org/changelog.html | grep -v generator | grep -oE "[0-9]\.[0-9]\.[0-9]+" | head -1)
  echo
  echo "Current Tengine Version: ${CMSG}${OLD_tengine_ver}${CEND}"
  while :; do echo
    [ "${tengine_flag}" != 'y' ] && read -e -p "Please input upgrade Tengine Version(default: ${Latest_tengine_ver}): " NEW_tengine_ver
    NEW_tengine_ver=${NEW_tengine_ver:-${Latest_tengine_ver}}
    if [ "${NEW_tengine_ver}" != "${OLD_tengine_ver}" ]; then
      [ ! -e "tengine-${NEW_tengine_ver}.tar.gz" ] && wget -c https://tengine.taobao.org/download/tengine-${NEW_tengine_ver}.tar.gz > /dev/null 2>&1
      if [ -e "tengine-${NEW_tengine_ver}.tar.gz" ]; then
        src_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/openssl-${openssl_ver}.tar.gz" && Download_src
        src_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_ver}/pcre2-${pcre_ver}.tar.gz" && Download_src
        tar xzf openssl-${openssl_ver}.tar.gz
        tar xzf pcre2-${pcre_ver}.tar.gz
        echo "Download [${CMSG}tengine-${NEW_tengine_ver}.tar.gz${CEND}] successfully! "
        break
      else
        echo "${CWARNING}Tengine version does not exist! ${CEND}"
      fi
    else
      echo "${CWARNING}input error! Upgrade Tengine version is the same as the old version${CEND}"
      exit
    fi
  done

  if [ -e "tengine-${NEW_tengine_ver}.tar.gz" ]; then
    echo "[${CMSG}tengine-${NEW_tengine_ver}.tar.gz${CEND}] found"
    if [ "${tengine_flag}" != 'y' ]; then
      echo "Press Ctrl+c to cancel or Press any key to continue..."
      char=$(get_char)
    fi
    tar xzf tengine-${NEW_tengine_ver}.tar.gz
    pushd tengine-${NEW_tengine_ver}
    [ -f Makefile ] && make clean || true
    ${tengine_install_dir}/sbin/nginx -V &> $$
    tengine_configure_args_tmp=$(cat $$ | grep 'configure arguments:' | awk -F: '{print $2}')
    rm -rf $$
    tengine_configure_args=$(echo ${tengine_configure_args_tmp} | sed "s@--with-openssl=../openssl-\w.\w.\w\+ @--with-openssl=../openssl-${openssl_ver} @" | sed "s@--with-pcre=../pcre2-\w.\w\+ @--with-pcre=../pcre2-${pcre_ver} @")
    export LUAJIT_LIB=/usr/local/lib
    export LUAJIT_INC=/usr/local/include/luajit-2.1
    ./configure ${tengine_configure_args}
    make
    if [ -f "objs/nginx" ]; then
      /bin/mv ${tengine_install_dir}/sbin/nginx{,$(date +%m%d)}
      /bin/mv ${tengine_install_dir}/modules{,$(date +%m%d)}
      /bin/cp objs/nginx ${tengine_install_dir}/sbin/nginx
      chmod +x ${tengine_install_dir}/sbin/*
      make install
      kill -USR2 $(cat /var/run/nginx.pid)
      sleep 1
      kill -QUIT $(cat /var/run/nginx.pid.oldbin)
      popd > /dev/null
      echo "You have ${CMSG}successfully${CEND} upgrade from ${CWARNING}$OLD_tengine_ver${CEND} to ${CWARNING}${NEW_tengine_ver}${CEND}"
      rm -rf tengine-${NEW_tengine_ver}
    else
      echo "${CFAILURE}Upgrade Tengine failed! ${CEND}"
    fi
  fi
  popd > /dev/null
}

Upgrade_OpenResty() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${openresty_install_dir}/nginx/sbin/nginx" ] && echo "${CWARNING}OpenResty is not installed on your system! ${CEND}" && exit 1
  OLD_openresty_ver_tmp=$(${openresty_install_dir}/nginx/sbin/nginx -v 2>&1)
  OLD_openresty_ver="$(echo ${OLD_openresty_ver_tmp#*/} | awk '{print $1}')"
  Latest_openresty_ver=$(curl --connect-timeout 2 -m 3 -s https://openresty.org/en/download.html | awk '/download\/openresty-/{print $0}' |  grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
  echo
  echo "Current OpenResty Version: ${CMSG}${OLD_openresty_ver}${CEND}"
  while :; do echo
    [ "${openresty_flag}" != 'y' ] && read -e -p "Please input upgrade OpenResty Version(default: ${Latest_openresty_ver}): " NEW_openresty_ver
    NEW_openresty_ver=${NEW_openresty_ver:-${Latest_openresty_ver}}
    if [ "${NEW_openresty_ver}" != "${OLD_openresty_ver}" ]; then
      [ ! -e "openresty-${NEW_openresty_ver}.tar.gz" ] && wget -c https://openresty.org/download/openresty-${NEW_openresty_ver}.tar.gz > /dev/null 2>&1
      if [ -e "openresty-${NEW_openresty_ver}.tar.gz" ]; then
        src_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/openssl-${openssl_ver}.tar.gz" && Download_src
        src_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_ver}/pcre2-${pcre_ver}.tar.gz" && Download_src
        tar xzf openssl-${openssl_ver}.tar.gz
        tar xzf pcre2-${pcre_ver}.tar.gz
        echo "Download [${CMSG}openresty-${NEW_openresty_ver}.tar.gz${CEND}] successfully! "
        break
      else
        echo "${CWARNING}OpenResty version does not exist! ${CEND}"
      fi
    else
      echo "${CWARNING}input error! Upgrade OpenResty version is the same as the old version${CEND}"
      exit
    fi
  done

  if [ -e "openresty-${NEW_openresty_ver}.tar.gz" ]; then
    echo "[${CMSG}openresty-${NEW_openresty_ver}.tar.gz${CEND}] found"
    if [ "${openresty_flag}" != 'y' ]; then
      echo "Press Ctrl+c to cancel or Press any key to continue..."
      char=$(get_char)
    fi
    tar xzf openresty-${NEW_openresty_ver}.tar.gz
    pushd openresty-${NEW_openresty_ver}
    [ -f Makefile ] && make clean || true
    sed -i 's@CFLAGS="$CFLAGS -g"@#CFLAGS="$CFLAGS -g"@' bundle/nginx-${NEW_openresty_ver%.*}/auto/cc/gcc # close debug
    ${openresty_install_dir}/nginx/sbin/nginx -V &> $$
    ./configure --prefix=${openresty_install_dir} --user=${run_user} --group=${run_user} --with-http_stub_status_module --with-http_sub_module --with-http_v2_module --with-http_ssl_module --with-http_gzip_static_module --with-http_realip_module --with-http_flv_module --with-http_mp4_module --with-openssl=../openssl-${openssl_ver} --with-pcre=../pcre2-${pcre_ver} --with-pcre-jit --with-ld-opt='-ltcmalloc -Wl,-u,pcre_version' ${nginx_modules_options}
    compile_check
    if [ -f "build/nginx-${NEW_openresty_ver%.*}/objs/nginx" ]; then
      /bin/mv ${openresty_install_dir}/nginx/sbin/nginx{,$(date +%m%d)}
      make install
      kill -USR2 $(cat /var/run/nginx.pid)
      sleep 1
      kill -QUIT $(cat /var/run/nginx.pid.oldbin)
      popd > /dev/null
      echo "You have ${CMSG}successfully${CEND} upgrade from ${CWARNING}${OLD_openresty_ver}${CEND} to ${CWARNING}${NEW_openresty_ver}${CEND}"
      cleanup_src openresty-${NEW_openresty_ver}
    else
      fail_msg "OpenResty upgrade"
    fi
  fi
  popd > /dev/null
}
