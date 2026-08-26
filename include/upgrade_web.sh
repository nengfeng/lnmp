#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

. include/common.sh

# Verified zero-downtime binary swap via USR2/QUIT.
# Usage: _nginx_hot_swap <active_bin> <backup_bin> <service_name>
# Assumes new binary already installed at <active_bin>.
# Only quits the old master after the new one is confirmed alive; restores
# the backup binary on any failure (old master keeps serving meanwhile).
_nginx_hot_swap() {
  local bin="$1" backup="$2" svc="$3"
  local pid_file=/var/run/nginx.pid
  local old_pid=$(cat ${pid_file} 2>/dev/null)
  local new_pid="" i=0
  if [ -n "${old_pid}" ] && kill -0 ${old_pid} 2>/dev/null; then
    kill -USR2 ${old_pid}
    while [ ${i} -lt 10 ]; do
      sleep 1
      new_pid=$(cat ${pid_file} 2>/dev/null)
      [ -n "${new_pid}" ] && [ "${new_pid}" != "${old_pid}" ] && kill -0 ${new_pid} 2>/dev/null && break
      i=$((i+1))
    done
    if [ -n "${new_pid}" ] && [ "${new_pid}" != "${old_pid}" ] && kill -0 ${new_pid} 2>/dev/null; then
      kill -QUIT ${old_pid}
      return 0
    fi
    echo "${CFAILURE}New Nginx master failed to start, old master still serving.${CEND}"
  else
    echo "${CWARNING}Nginx not running, starting with new binary...${CEND}"
    rm -f ${pid_file}
    svc_start ${svc}
    sleep 1
    new_pid=$(cat ${pid_file} 2>/dev/null)
    if [ -n "${new_pid}" ] && kill -0 ${new_pid} 2>/dev/null; then
      return 0
    fi
    echo "${CFAILURE}Nginx failed to start with new binary.${CEND}"
  fi
  if /bin/mv -f ${backup} ${bin}; then
    echo "Binary rolled back to previous version."
  else
    echo "${CFAILURE}Rollback failed! Please restore ${backup} manually.${CEND}"
  fi
  return 1
}

Upgrade_Nginx() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${nginx_install_dir}/sbin/nginx" ] && echo "${CWARNING}Nginx is not installed on your system! ${CEND}" && exit 1
  OLD_nginx_ver_tmp=$(${nginx_install_dir}/sbin/nginx -v 2>&1)
  OLD_nginx_ver=${OLD_nginx_ver_tmp##*/}
  Latest_nginx_ver=$(curl --connect-timeout 2 -m 3 -s https://nginx.org/en/download.html | grep -oP 'Stable version.*?nginx-\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  echo
  echo "Current Nginx Version: ${CMSG}${OLD_nginx_ver}${CEND}"

  # Check if existing Nginx was compiled with Lua module
  if ! ${nginx_install_dir}/sbin/nginx -V 2>&1 | grep -q "lua-nginx-module"; then
    echo
    echo "${CWARNING}警告: 当前 Nginx 未编译 Lua 模块！${CEND}"
    echo "${CWARNING}升级后将自动添加 Lua 模块（lua-nginx-module + LuaJIT）。${CEND}"
    if [ "${nginx_flag}" != 'y' ]; then
      read -e -p "是否继续? [y/N]: " confirm
      [[ "${confirm}" != [yY] ]] && echo "已取消升级。" && popd > /dev/null && return 1
    fi
  fi

  while :; do echo
    [ "${nginx_flag}" != 'y' ] && read -e -p "Please input upgrade Nginx Version(default: ${Latest_nginx_ver}): " NEW_nginx_ver
    NEW_nginx_ver=${NEW_nginx_ver:-${Latest_nginx_ver}}
    if [ "${NEW_nginx_ver}" != "${OLD_nginx_ver}" ] || [ "${nginx_flag}" = 'y' ]; then
      [ ! -e "nginx-${NEW_nginx_ver}.tar.gz" ] && wget -c https://nginx.org/download/nginx-${NEW_nginx_ver}.tar.gz > /dev/null 2>&1
      if [ -e "nginx-${NEW_nginx_ver}.tar.gz" ]; then
        src_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/openssl-${openssl_ver}.tar.gz" && Download_src
        src_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_ver}/pcre2-${pcre_ver}.tar.gz" && Download_src
        src_url="https://github.com/vision5/ngx_devel_kit/archive/refs/tags/v${ngx_devel_kit_ver}.tar.gz" && Download_src "ngx_devel_kit-${ngx_devel_kit_ver}.tar.gz"
        src_url="https://github.com/openresty/lua-nginx-module/archive/refs/tags/v${lua_nginx_module_ver}.tar.gz" && Download_src "lua-nginx-module-${lua_nginx_module_ver}.tar.gz"
        src_url="https://github.com/openresty/luajit2/archive/refs/tags/v${luajit2_ver}.tar.gz" && Download_src "luajit2-${luajit2_ver}.tar.gz"
        src_url="https://github.com/openresty/lua-resty-core/archive/refs/tags/v${lua_resty_core_ver}.tar.gz" && Download_src "lua-resty-core-${lua_resty_core_ver}.tar.gz"
        src_url="https://github.com/openresty/lua-resty-lrucache/archive/refs/tags/v${lua_resty_lrucache_ver}.tar.gz" && Download_src "lua-resty-lrucache-${lua_resty_lrucache_ver}.tar.gz"
        src_url="https://github.com/openresty/lua-cjson/archive/refs/tags/${lua_cjson_ver}.tar.gz" && Download_src "lua-cjson-${lua_cjson_ver}.tar.gz"
        src_url="https://github.com/google/ngx_brotli/archive/refs/heads/master.tar.gz" && Download_src "ngx_brotli-master.tar.gz"
        src_url="https://github.com/google/brotli/archive/refs/tags/v${brotli_ver}.tar.gz" && Download_src "brotli-${brotli_ver}.tar.gz"
        tar xzf openssl-${openssl_ver}.tar.gz
        tar xzf pcre2-${pcre_ver}.tar.gz
        tar xzf "ngx_devel_kit-${ngx_devel_kit_ver}.tar.gz"
        tar xzf "lua-nginx-module-${lua_nginx_module_ver}.tar.gz"
        tar xzf "lua-resty-core-${lua_resty_core_ver}.tar.gz"
        tar xzf "lua-resty-lrucache-${lua_resty_lrucache_ver}.tar.gz"
        tar xzf "lua-cjson-${lua_cjson_ver}.tar.gz"
        tar xzf "ngx_brotli-master.tar.gz"
        rm -rf ngx_brotli
        mv ngx_brotli-master ngx_brotli
        tar xzf "brotli-${brotli_ver}.tar.gz"
        rm -rf ngx_brotli/deps/brotli
        mkdir -p ngx_brotli/deps
        mv brotli-${brotli_ver} ngx_brotli/deps/brotli
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
    local nginx_v_tmp=$(mktemp "${current_dir}/src/nginx_v.XXXXXX")
    ${nginx_install_dir}/sbin/nginx -V &> "${nginx_v_tmp}"
    nginx_configure_args_tmp=$(grep 'configure arguments:' "${nginx_v_tmp}" | awk -F: '{print $2}')
    rm -f "${nginx_v_tmp}"
    nginx_configure_args=$(echo ${nginx_configure_args_tmp} | sed "s@lua-nginx-module-[0-9.]\+\(rc[0-9]\+\)\?@lua-nginx-module-${lua_nginx_module_ver}@" | sed "s@--with-openssl=../openssl-[0-9.]\+\(rc[0-9]\+\)\?@--with-openssl=../openssl-${openssl_ver}@" | sed "s@--with-pcre=../pcre2-[0-9.]\+\(rc[0-9]\+\)\?@--with-pcre=../pcre2-${pcre_ver}@")

    # Apply allocator from options.conf
    if [ -n "${allocator_ldflag}" ]; then
      nginx_configure_args=$(echo ${nginx_configure_args} | sed "s@--with-ld-opt=[^ ]*@--with-ld-opt=${allocator_ldflag}@")
      if [ -z "$(echo ${nginx_configure_args} | grep -- '--with-ld-opt')" ]; then
        nginx_configure_args="${nginx_configure_args} --with-ld-opt=${allocator_ldflag}"
      fi
    else
      nginx_configure_args=$(echo ${nginx_configure_args} | sed 's@--with-ld-opt=[^ ]*@@')
    fi

    # Always ensure lua modules are present in configure args
    if [ -z "$(echo ${nginx_configure_args} | grep lua-nginx-module)" ]; then
      nginx_configure_args="${nginx_configure_args} --add-module=../lua-nginx-module-${lua_nginx_module_ver}"
    fi
    # Always ensure ngx_brotli is present in configure args
    if [ -z "$(echo ${nginx_configure_args} | grep ngx_brotli)" ]; then
      nginx_configure_args="${nginx_configure_args} --add-module=../ngx_brotli"
    fi
    # lua-resty-core and lua-resty-lrucache are Lua libraries, not Nginx modules
    # They are installed separately below via make install

    # Build LuaJIT if not present
    if [ ! -e "/usr/local/lib/libluajit-5.1.so" ]; then
      ${current_dir}/upgrade.sh --script > /dev/null
      src_url="https://github.com/openresty/luajit2/archive/refs/tags/v${luajit2_ver}.tar.gz" && Download_src "luajit2-${luajit2_ver}.tar.gz"
      tar xzf "luajit2-${luajit2_ver}.tar.gz"
      pushd "luajit2-${luajit2_ver}"
      make && make install
      popd > /dev/null
      rm -rf "luajit2-${luajit2_ver}"
      ldconfig
    fi

    # Install lua-resty-core and lua-resty-lrucache (Lua libraries, not Nginx modules)
    src_url="https://github.com/openresty/lua-resty-core/archive/refs/tags/v${lua_resty_core_ver}.tar.gz" && Download_src "lua-resty-core-${lua_resty_core_ver}.tar.gz"
    tar xzf "lua-resty-core-${lua_resty_core_ver}.tar.gz"
    pushd "lua-resty-core-${lua_resty_core_ver}"
    make install LUA_LIB_DIR=/usr/local/lib/lua/5.1
    popd > /dev/null
    if [ -f "/usr/local/lib/lua/5.1/resty/core.lua" ] && [ ! -e "/usr/local/lib/lua/5.1/resty/core/init.lua" ]; then
        cp "/usr/local/lib/lua/5.1/resty/core.lua" "/usr/local/lib/lua/5.1/resty/core/init.lua"
    fi
    rm -rf "lua-resty-core-${lua_resty_core_ver}"

    src_url="https://github.com/openresty/lua-resty-lrucache/archive/refs/tags/v${lua_resty_lrucache_ver}.tar.gz" && Download_src "lua-resty-lrucache-${lua_resty_lrucache_ver}.tar.gz"
    tar xzf "lua-resty-lrucache-${lua_resty_lrucache_ver}.tar.gz"
    pushd "lua-resty-lrucache-${lua_resty_lrucache_ver}"
    make install LUA_LIB_DIR=/usr/local/lib/lua/5.1
    popd > /dev/null
    rm -rf "lua-resty-lrucache-${lua_resty_lrucache_ver}"

    # Build lua-cjson (Lua C module for JSON support)
    if [ ! -e "/usr/local/lib/lua/5.1/cjson.so" ]; then
      tar xzf "lua-cjson-${lua_cjson_ver}.tar.gz"
      pushd "lua-cjson-${lua_cjson_ver}"
      sed -i 's@^LUA_INCLUDE_DIR.*@&/luajit-2.1@' Makefile
      make -j$(nproc) && make install
      [ ! -e "/usr/local/lib/lua/5.1/cjson.so" ] && { fail_msg "lua-cjson"; }
      popd > /dev/null
      rm -rf "lua-cjson-${lua_cjson_ver}"
    fi

    tar xzf nginx-${NEW_nginx_ver}.tar.gz

    # Build brotli static library for ngx_brotli
    if [ -d "ngx_brotli/deps/brotli" ]; then
      local brotli_arch=""
      [[ "${armplatform}" != 'y' ]] && brotli_arch="-m64 "
      pushd ngx_brotli/deps/brotli > /dev/null
      mkdir -p out
      pushd out > /dev/null
      cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_C_FLAGS="${brotli_arch}-Ofast -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" \
        -DCMAKE_CXX_FLAGS="${brotli_arch}-Ofast -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" \
        -DCMAKE_INSTALL_PREFIX=./installed ..
      cmake --build . --config Release --target brotlienc
      popd > /dev/null
      popd > /dev/null
    fi

    pushd nginx-${NEW_nginx_ver}
    make clean
    sed -i 's@CFLAGS="$CFLAGS -g"@#CFLAGS="$CFLAGS -g"@' auto/cc/gcc # close debug
    export LUAJIT_LIB=/usr/local/lib
    export LUAJIT_INC=/usr/local/include/luajit-2.1
    ./configure ${nginx_configure_args}
    compile_check
    if [ -f "objs/nginx" ]; then
      echo "Config test with new binary......"
      if ! ./objs/nginx -t; then
        fail_msg "Nginx upgrade (config test failed)"
      fi
      local ts=$(date +%m%d%H%M%S)
      /bin/cp -a ${nginx_install_dir}/sbin/nginx ${nginx_install_dir}/sbin/nginx.bak${ts} || { fail_msg "Nginx upgrade (backup failed)"; }
      if ! /bin/cp objs/nginx ${nginx_install_dir}/sbin/nginx; then
        /bin/mv -f ${nginx_install_dir}/sbin/nginx.bak${ts} ${nginx_install_dir}/sbin/nginx 2>/dev/null
        fail_msg "Nginx upgrade (install new binary failed)"
      fi
      chmod +x ${nginx_install_dir}/sbin/nginx
      popd > /dev/null
      sed -i 's/^#brotli/brotli/' ${nginx_install_dir}/conf/nginx.conf 2>/dev/null
      if _nginx_hot_swap ${nginx_install_dir}/sbin/nginx ${nginx_install_dir}/sbin/nginx.bak${ts} nginx; then
        echo "You have ${CMSG}successfully${CEND} upgrade from ${CWARNING}${OLD_nginx_ver}${CEND} to ${CWARNING}${NEW_nginx_ver}${CEND}"
        cleanup_src nginx-${NEW_nginx_ver} ngx_brotli
      else
        echo "${CFAILURE}Nginx upgrade failed! ${CEND}"
      fi
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

  # Check if existing Tengine was compiled with Lua module
  if ! ${tengine_install_dir}/sbin/nginx -V 2>&1 | grep -q "lua-nginx-module"; then
    echo
    echo "${CWARNING}警告: 当前 Tengine 未编译 Lua 模块！${CEND}"
    echo "${CWARNING}升级后将自动添加 Lua 模块（lua-nginx-module + LuaJIT）。${CEND}"
    if [ "${tengine_flag}" != 'y' ]; then
      read -e -p "是否继续? [y/N]: " confirm
      [[ "${confirm}" != [yY] ]] && echo "已取消升级。" && popd > /dev/null && return 1
    fi
  fi

  while :; do echo
    [ "${tengine_flag}" != 'y' ] && read -e -p "Please input upgrade Tengine Version(default: ${Latest_tengine_ver}): " NEW_tengine_ver
    NEW_tengine_ver=${NEW_tengine_ver:-${Latest_tengine_ver}}
    if [ "${NEW_tengine_ver}" != "${OLD_tengine_ver}" ] || [ "${tengine_flag}" = 'y' ]; then
      [ ! -e "tengine-${NEW_tengine_ver}.tar.gz" ] && wget -c https://tengine.taobao.org/download/tengine-${NEW_tengine_ver}.tar.gz > /dev/null 2>&1
      if [ -e "tengine-${NEW_tengine_ver}.tar.gz" ]; then
        src_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/openssl-${openssl_ver}.tar.gz" && Download_src
        src_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_ver}/pcre2-${pcre_ver}.tar.gz" && Download_src
        src_url="https://github.com/openresty/lua-nginx-module/archive/refs/tags/v${lua_nginx_module_ver}.tar.gz" && Download_src "lua-nginx-module-${lua_nginx_module_ver}.tar.gz"
        src_url="https://github.com/openresty/luajit2/archive/refs/tags/v${luajit2_ver}.tar.gz" && Download_src "luajit2-${luajit2_ver}.tar.gz"
        src_url="https://github.com/openresty/lua-resty-core/archive/refs/tags/v${lua_resty_core_ver}.tar.gz" && Download_src "lua-resty-core-${lua_resty_core_ver}.tar.gz"
        src_url="https://github.com/openresty/lua-resty-lrucache/archive/refs/tags/v${lua_resty_lrucache_ver}.tar.gz" && Download_src "lua-resty-lrucache-${lua_resty_lrucache_ver}.tar.gz"
        src_url="https://github.com/openresty/lua-cjson/archive/refs/tags/${lua_cjson_ver}.tar.gz" && Download_src "lua-cjson-${lua_cjson_ver}.tar.gz"
        src_url="https://github.com/google/ngx_brotli/archive/refs/heads/master.tar.gz" && Download_src "ngx_brotli-master.tar.gz"
        src_url="https://github.com/google/brotli/archive/refs/tags/v${brotli_ver}.tar.gz" && Download_src "brotli-${brotli_ver}.tar.gz"
        tar xzf openssl-${openssl_ver}.tar.gz
        tar xzf pcre2-${pcre_ver}.tar.gz
        tar xzf "ngx_brotli-master.tar.gz"
        rm -rf ngx_brotli
        mv ngx_brotli-master ngx_brotli
        tar xzf "brotli-${brotli_ver}.tar.gz"
        rm -rf ngx_brotli/deps/brotli
        mkdir -p ngx_brotli/deps
        mv brotli-${brotli_ver} ngx_brotli/deps/brotli
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
    make clean
    local tengine_v_tmp=$(mktemp "${current_dir}/src/tengine_v.XXXXXX")
    ${tengine_install_dir}/sbin/nginx -V &> "${tengine_v_tmp}"
    tengine_configure_args_tmp=$(grep 'configure arguments:' "${tengine_v_tmp}" | awk -F: '{print $2}')
    rm -f "${tengine_v_tmp}"
    tengine_configure_args=$(echo ${tengine_configure_args_tmp} | sed "s@--with-openssl=../openssl-[0-9.]\+\(rc[0-9]\+\)\?@--with-openssl=../openssl-${openssl_ver}@" | sed "s@--with-pcre=../pcre2-[0-9.]\+\(rc[0-9]\+\)\?@--with-pcre=../pcre2-${pcre_ver}@")

    # Apply allocator from options.conf
    if [ -n "${allocator_ldflag}" ]; then
      tengine_configure_args=$(echo ${tengine_configure_args} | sed "s@--with-ld-opt=[^ ]*@--with-ld-opt=${allocator_ldflag}@")
      if [ -z "$(echo ${tengine_configure_args} | grep -- '--with-ld-opt')" ]; then
        tengine_configure_args="${tengine_configure_args} --with-ld-opt=${allocator_ldflag}"
      fi
    else
      tengine_configure_args=$(echo ${tengine_configure_args} | sed 's@--with-ld-opt=[^ ]*@@')
    fi

    # Always ensure lua modules are present in configure args
    if [ -z "$(echo ${tengine_configure_args} | grep lua-nginx-module)" ]; then
      tengine_configure_args="${tengine_configure_args} --add-module=../lua-nginx-module-${lua_nginx_module_ver}"
    fi
    # Always ensure ngx_brotli is present in configure args
    if [ -z "$(echo ${tengine_configure_args} | grep ngx_brotli)" ]; then
      tengine_configure_args="${tengine_configure_args} --add-module=../ngx_brotli"
    fi
    # lua-resty-core and lua-resty-lrucache are Lua libraries, not Nginx modules
    # They are installed separately below via make install

    # Build LuaJIT and install lua deps if not present
    if [ ! -e "/usr/local/lib/libluajit-5.1.so" ]; then
      ${current_dir}/upgrade.sh --script > /dev/null
      src_url="https://github.com/openresty/luajit2/archive/refs/tags/v${luajit2_ver}.tar.gz" && Download_src "luajit2-${luajit2_ver}.tar.gz"
      tar xzf "luajit2-${luajit2_ver}.tar.gz"
      pushd "luajit2-${luajit2_ver}"
      make && make install
      popd > /dev/null
      rm -rf "luajit2-${luajit2_ver}"
      ldconfig
    fi

    src_url="https://github.com/openresty/lua-resty-core/archive/refs/tags/v${lua_resty_core_ver}.tar.gz" && Download_src "lua-resty-core-${lua_resty_core_ver}.tar.gz"
    tar xzf "lua-resty-core-${lua_resty_core_ver}.tar.gz"
    pushd "lua-resty-core-${lua_resty_core_ver}"
    make install LUA_LIB_DIR=/usr/local/lib/lua/5.1
    popd > /dev/null
    if [ -f "/usr/local/lib/lua/5.1/resty/core.lua" ] && [ ! -e "/usr/local/lib/lua/5.1/resty/core/init.lua" ]; then
        cp "/usr/local/lib/lua/5.1/resty/core.lua" "/usr/local/lib/lua/5.1/resty/core/init.lua"
    fi
    rm -rf "lua-resty-core-${lua_resty_core_ver}"

    src_url="https://github.com/openresty/lua-resty-lrucache/archive/refs/tags/v${lua_resty_lrucache_ver}.tar.gz" && Download_src "lua-resty-lrucache-${lua_resty_lrucache_ver}.tar.gz"
    tar xzf "lua-resty-lrucache-${lua_resty_lrucache_ver}.tar.gz"
    pushd "lua-resty-lrucache-${lua_resty_lrucache_ver}"
    make install LUA_LIB_DIR=/usr/local/lib/lua/5.1
    popd > /dev/null
    rm -rf "lua-resty-lrucache-${lua_resty_lrucache_ver}"

    # Build lua-cjson (Lua C module for JSON support)
    if [ ! -e "/usr/local/lib/lua/5.1/cjson.so" ]; then
      tar xzf "lua-cjson-${lua_cjson_ver}.tar.gz"
      pushd "lua-cjson-${lua_cjson_ver}"
      sed -i 's@^LUA_INCLUDE_DIR.*@&/luajit-2.1@' Makefile
      make -j$(nproc) && make install
      [ ! -e "/usr/local/lib/lua/5.1/cjson.so" ] && { fail_msg "lua-cjson"; }
      popd > /dev/null
      rm -rf "lua-cjson-${lua_cjson_ver}"
    fi

    # Download lua-nginx-module for Tengine build
    src_url="https://github.com/openresty/lua-nginx-module/archive/refs/tags/v${lua_nginx_module_ver}.tar.gz" && Download_src "lua-nginx-module-${lua_nginx_module_ver}.tar.gz"
    tar xzf "lua-nginx-module-${lua_nginx_module_ver}.tar.gz"

    export LUAJIT_LIB=/usr/local/lib
    export LUAJIT_INC=/usr/local/include/luajit-2.1

    # Build brotli static library for ngx_brotli
    if [ -d "ngx_brotli/deps/brotli" ]; then
      local brotli_arch=""
      [[ "${armplatform}" != 'y' ]] && brotli_arch="-m64 "
      pushd ngx_brotli/deps/brotli > /dev/null
      mkdir -p out
      pushd out > /dev/null
      cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_C_FLAGS="${brotli_arch}-Ofast -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" \
        -DCMAKE_CXX_FLAGS="${brotli_arch}-Ofast -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" \
        -DCMAKE_INSTALL_PREFIX=./installed ..
      cmake --build . --config Release --target brotlienc
      popd > /dev/null
      popd > /dev/null
    fi

    ./configure ${tengine_configure_args}
    make
    if [ -f "objs/nginx" ]; then
      echo "Config test with new binary......"
      if ! ./objs/nginx -t; then
        fail_msg "Tengine upgrade (config test failed)"
      fi
      local ts=$(date +%m%d%H%M%S)
      /bin/cp -a ${tengine_install_dir}/sbin/nginx ${tengine_install_dir}/sbin/nginx.bak${ts} || { fail_msg "Tengine upgrade (backup failed)"; }
      if ! /bin/cp objs/nginx ${tengine_install_dir}/sbin/nginx; then
        /bin/mv -f ${tengine_install_dir}/sbin/nginx.bak${ts} ${tengine_install_dir}/sbin/nginx 2>/dev/null
        fail_msg "Tengine upgrade (install new binary failed)"
      fi
      chmod +x ${tengine_install_dir}/sbin/*
      [ -d ${tengine_install_dir}/modules ] && mv ${tengine_install_dir}/modules{,.bak${ts}}
      if ! make install > /dev/null 2>&1; then
        /bin/mv -f ${tengine_install_dir}/sbin/nginx.bak${ts} ${tengine_install_dir}/sbin/nginx 2>/dev/null
        fail_msg "Tengine upgrade (make install failed)"
      fi
      popd > /dev/null
      sed -i 's/^#brotli/brotli/' ${tengine_install_dir}/conf/nginx.conf 2>/dev/null
      if _nginx_hot_swap ${tengine_install_dir}/sbin/nginx ${tengine_install_dir}/sbin/nginx.bak${ts} nginx; then
        echo "You have ${CMSG}successfully${CEND} upgrade from ${CWARNING}$OLD_tengine_ver${CEND} to ${CWARNING}${NEW_tengine_ver}${CEND}"
        rm -rf tengine-${NEW_tengine_ver} ngx_brotli
      else
        [ -d ${tengine_install_dir}/modules.bak${ts} ] && rm -rf ${tengine_install_dir}/modules && mv ${tengine_install_dir}/modules.bak${ts} ${tengine_install_dir}/modules
        echo "${CFAILURE}Tengine upgrade failed! ${CEND}"
      fi
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
    if [ "${NEW_openresty_ver}" != "${OLD_openresty_ver}" ] || [ "${openresty_flag}" = 'y' ]; then
      [ ! -e "openresty-${NEW_openresty_ver}.tar.gz" ] && wget -c https://openresty.org/download/openresty-${NEW_openresty_ver}.tar.gz > /dev/null 2>&1
      if [ -e "openresty-${NEW_openresty_ver}.tar.gz" ]; then
        src_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/openssl-${openssl_ver}.tar.gz" && Download_src
        src_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_ver}/pcre2-${pcre_ver}.tar.gz" && Download_src
        src_url="https://github.com/openresty/lua-cjson/archive/refs/tags/${lua_cjson_ver}.tar.gz" && Download_src "lua-cjson-${lua_cjson_ver}.tar.gz"
        src_url="https://github.com/google/ngx_brotli/archive/refs/heads/master.tar.gz" && Download_src "ngx_brotli-master.tar.gz"
        src_url="https://github.com/google/brotli/archive/refs/tags/v${brotli_ver}.tar.gz" && Download_src "brotli-${brotli_ver}.tar.gz"
        tar xzf openssl-${openssl_ver}.tar.gz
        tar xzf pcre2-${pcre_ver}.tar.gz
        tar xzf "lua-cjson-${lua_cjson_ver}.tar.gz"
        tar xzf "ngx_brotli-master.tar.gz"
        rm -rf ngx_brotli
        mv ngx_brotli-master ngx_brotli
        tar xzf "brotli-${brotli_ver}.tar.gz"
        rm -rf ngx_brotli/deps/brotli
        mkdir -p ngx_brotli/deps
        mv brotli-${brotli_ver} ngx_brotli/deps/brotli
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

    # Build brotli static library for ngx_brotli
    if [ -d "ngx_brotli/deps/brotli" ]; then
      local brotli_arch=""
      [[ "${armplatform}" != 'y' ]] && brotli_arch="-m64 "
      pushd ngx_brotli/deps/brotli > /dev/null
      mkdir -p out
      pushd out > /dev/null
      cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_C_FLAGS="${brotli_arch}-Ofast -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" \
        -DCMAKE_CXX_FLAGS="${brotli_arch}-Ofast -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" \
        -DCMAKE_INSTALL_PREFIX=./installed ..
      cmake --build . --config Release --target brotlienc
      popd > /dev/null
      popd > /dev/null
    fi

    # Build lua-cjson (Lua C module for JSON support)
    if [ ! -e "/usr/local/lib/lua/5.1/cjson.so" ]; then
      tar xzf "lua-cjson-${lua_cjson_ver}.tar.gz"
      pushd "lua-cjson-${lua_cjson_ver}"
      sed -i 's@^LUA_INCLUDE_DIR.*@&/luajit-2.1@' Makefile
      make -j$(nproc) && make install
      [ ! -e "/usr/local/lib/lua/5.1/cjson.so" ] && { fail_msg "lua-cjson"; }
      popd > /dev/null
      rm -rf "lua-cjson-${lua_cjson_ver}"
    fi

    pushd openresty-${NEW_openresty_ver}
    make clean
    local nginx_bundle_dir=$(ls -d bundle/nginx-* 2>/dev/null | head -1)
    [ -n "$nginx_bundle_dir" ] && sed -i 's@CFLAGS="$CFLAGS -g"@#CFLAGS="$CFLAGS -g"@' "${nginx_bundle_dir}/auto/cc/gcc"
    ./configure --prefix=${openresty_install_dir} --user=${run_user} --group=${run_user} --with-http_stub_status_module --with-http_v2_module --with-http_v3_module --with-http_ssl_module --with-stream --with-stream_ssl_preread_module --with-stream_ssl_module --with-http_gzip_static_module --with-http_realip_module --with-openssl=../openssl-${openssl_ver} --with-pcre=../pcre2-${pcre_ver} --with-pcre-jit --add-module=../ngx_brotli --with-ld-opt="${allocator_ldflag:--ltcmalloc} -Wl,-u,pcre_version" ${nginx_modules_options}
    compile_check
    local nginx_build_dir=$(ls -d build/nginx-* 2>/dev/null | head -1)
    if [ -n "$nginx_build_dir" ] && [ -f "${nginx_build_dir}/objs/nginx" ]; then
      echo "Config test with new binary......"
      if ! ${nginx_build_dir}/objs/nginx -t; then
        fail_msg "OpenResty upgrade (config test failed)"
      fi
      local ts=$(date +%m%d%H%M%S)
      /bin/cp -a ${openresty_install_dir}/nginx/sbin/nginx ${openresty_install_dir}/nginx/sbin/nginx.bak${ts} || { fail_msg "OpenResty upgrade (backup failed)"; }
      if ! make install > /dev/null 2>&1; then
        /bin/mv -f ${openresty_install_dir}/nginx/sbin/nginx.bak${ts} ${openresty_install_dir}/nginx/sbin/nginx 2>/dev/null
        fail_msg "OpenResty upgrade (make install failed)"
      fi
      popd > /dev/null
      sed -i 's/^#brotli/brotli/' ${openresty_install_dir}/nginx/conf/nginx.conf 2>/dev/null
      if _nginx_hot_swap ${openresty_install_dir}/nginx/sbin/nginx ${openresty_install_dir}/nginx/sbin/nginx.bak${ts} nginx; then
        echo "You have ${CMSG}successfully${CEND} upgrade from ${CWARNING}${OLD_openresty_ver}${CEND} to ${CWARNING}${NEW_openresty_ver}${CEND}"
        cleanup_src openresty-${NEW_openresty_ver} ngx_brotli lua-cjson-${lua_cjson_ver}
      else
        echo "${CFAILURE}OpenResty upgrade failed! ${CEND}"
      fi
    else
      fail_msg "OpenResty upgrade"
    fi
  fi
  popd > /dev/null
}
