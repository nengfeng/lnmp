#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Nginx_lua_waf() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${nginx_install_dir}/sbin/nginx" ] && echo "${CWARNING}Nginx is not installed on your system! ${CEND}" && exit 1
  if [ ! -e "/usr/local/lib/libluajit-5.1.so" ]; then
    # Quote the -name pattern (an unquoted one is expanded by the shell against
    # the CWD) and separate the arguments so an empty result is not fed to rm.
    [ -e "/usr/local/lib/libluajit-5.1.so.2.0.5" ] && find /usr/local -name '*luajit*' -print0 | xargs -0 -r rm -rf
    src_url="https://github.com/openresty/luajit2/archive/refs/tags/${luajit2_ver}.tar.gz" && Download_src
    tar xzf luajit2-${luajit2_ver}.tar.gz
    pushd luajit2-${luajit2_ver}
    make && make install || { fail_msg "LuaJIT"; }
    popd > /dev/null
    cleanup_src luajit2-${luajit2_ver}
  fi

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

  [ ! -h "/usr/local/share/lua/5.1" ] && { rm -rf /usr/local/share/lua/5.1 ; ln -s /usr/local/lib/lua /usr/local/share/lua/5.1; }
  if [ ! -e "/usr/local/lib/lua/5.1/cjson.so" ]; then
    src_url="https://github.com/openresty/lua-cjson/archive/refs/tags/${lua_cjson_ver}.tar.gz" && Download_src
    tar xzf lua-cjson-${lua_cjson_ver}.tar.gz
    pushd lua-cjson-${lua_cjson_ver}
    sed -i 's@^LUA_INCLUDE_DIR.*@&/luajit-2.1@' Makefile
    make && make install
    [ ! -e "/usr/local/lib/lua/5.1/cjson.so" ] && { fail_msg "lua-cjson"; }
    popd > /dev/null
    cleanup_src lua-cjson-${lua_cjson_ver}
  fi
  ${nginx_install_dir}/sbin/nginx -V &> $$
  nginx_configure_args_tmp=$(cat $$ | grep 'configure arguments:' | awk -F: '{print $2}')
  rm -rf $$
  # Defensive guard: every server this project builds (install_web_server) and
  # upgrades (upgrade_web.sh) ships with lua-nginx-module, so a missing module
  # here means the nginx was installed by some other means. We used to silently
  # recompile nginx in this branch, but that recompile was half-baked (it never
  # unpacked ngx_brotli, so any brotli-enabled build would fail to configure)
  # and duplicated the correct, complete lua-module addition that upgrade_web.sh
  # already performs. Recompiling here would also risk deploying waf config onto
  # an nginx that cannot interpret it. So abort with a clear pointer instead.
  if [ -z "$(echo ${nginx_configure_args_tmp} | grep lua-nginx-module)" ]; then
    echo "${CFAILURE}Current Nginx was not compiled with lua-nginx-module.${CEND}"
    echo "${CWARNING}Please upgrade Nginx first (upgrade_web.sh adds the Lua module automatically), then retry.${CEND}"
    popd > /dev/null
    return 1
  fi
  popd > /dev/null
}

Tengine_lua_waf() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${tengine_install_dir}/sbin/nginx" ] && echo "${CWARNING}Tengine is not installed on your system! ${CEND}" && exit 1
  if [ ! -e "/usr/local/lib/libluajit-5.1.so" ]; then
    # Quote the -name pattern (an unquoted one is expanded by the shell against
    # the CWD) and separate the arguments so an empty result is not fed to rm.
    [ -e "/usr/local/lib/libluajit-5.1.so.2.0.5" ] && find /usr/local -name '*luajit*' -print0 | xargs -0 -r rm -rf
    src_url="https://github.com/openresty/luajit2/archive/refs/tags/${luajit2_ver}.tar.gz" && Download_src
    tar xzf luajit2-${luajit2_ver}.tar.gz
    pushd luajit2-${luajit2_ver}
    make && make install
    [ ! -e "/usr/local/lib/libluajit-5.1.so" ] && { fail_msg "LuaJIT"; }
    popd > /dev/null
    cleanup_src luajit2-${luajit2_ver}
  fi
  if [ ! -e "/usr/local/lib/lua/5.1/cjson.so" ]; then
    src_url="https://github.com/openresty/lua-cjson/archive/refs/tags/${lua_cjson_ver}.tar.gz" && Download_src
    tar xzf lua-cjson-${lua_cjson_ver}.tar.gz
    pushd lua-cjson-${lua_cjson_ver}
    sed -i 's@^LUA_INCLUDE_DIR.*@&/luajit-2.1@' Makefile
    make && make install
    [ ! -e "/usr/local/lib/lua/5.1/cjson.so" ] && { fail_msg "lua-cjson"; }
    popd > /dev/null
    cleanup_src lua-cjson-${lua_cjson_ver}
  fi
  ${tengine_install_dir}/sbin/nginx -V &> $$
  tengine_configure_args_tmp=$(cat $$ | grep 'configure arguments:' | awk -F: '{print $2}')
  rm -rf $$
  # Same defensive guard as in Nginx_lua_waf above: Tengine built by this project
  # always ships lua support, so a missing module means it was installed by some
  # other means. The old code recompiled Tengine here, but that recompile never
  # unpacked ngx_brotli and duplicated what upgrade_web.sh already does correctly.
  # Abort with a pointer instead of deploying waf config onto a lua-less server.
  if [ -z "$(echo ${tengine_configure_args_tmp} | grep lua-nginx-module)" ]; then
    echo "${CFAILURE}Current Tengine was not compiled with lua-nginx-module.${CEND}"
    echo "${CWARNING}Please upgrade Tengine first (upgrade_web.sh adds the Lua module automatically), then retry.${CEND}"
    popd > /dev/null
    return 1
  fi
  popd > /dev/null
}

enable_lua_waf() {
  pushd ${current_dir}/src > /dev/null
  . ../include/check_dir.sh
  rm -f ngx_lua_waf.tar.gz
  src_url="https://github.com/loveshell/ngx_lua_waf/archive/master.tar.gz" && Download_src
  tar xzf ngx_lua_waf.tar.gz -C ${web_install_dir}/conf
  [ -e "${web_install_dir}/conf/resty" ] && /bin/mv ${web_install_dir}/conf/resty{,_bak}
  sed -i "s@/usr/local/nginx@${web_install_dir}@g" ${web_install_dir}/conf/waf.conf
  sed -i "s@/usr/local/nginx@${web_install_dir}@" ${web_install_dir}/conf/waf/config.lua
  sed -i "s@/data/wwwlogs@${wwwlogs_dir}@" ${web_install_dir}/conf/waf/config.lua
  [ -z "$(grep 'include waf.conf;' ${web_install_dir}/conf/nginx.conf)" ] && sed -i "s@ vhost/\*.conf;@&\n  include waf.conf;@" ${web_install_dir}/conf/nginx.conf
  ${web_install_dir}/sbin/nginx -t
  if [ $? -eq 0 ]; then
    svc_reload nginx
    echo "${CSUCCESS}ngx_lua_waf enabled successfully! ${CEND}"
    chown ${run_user}:${run_group} ${wwwlogs_dir}
  else
    echo "${CFAILURE}ngx_lua_waf enable failed! ${CEND}"
  fi
  popd > /dev/null
}

disable_lua_waf() {
  pushd ${current_dir}/src > /dev/null
  . ../include/check_dir.sh
  sed -i '/include waf.conf;/d' ${web_install_dir}/conf/nginx.conf
  ${web_install_dir}/sbin/nginx -t
  if [ $? -eq 0 ]; then
    rm -rf ${web_install_dir}/conf/{waf,waf.conf}
    [ -e "${web_install_dir}/conf/resty_bak" ] && /bin/mv ${web_install_dir}/conf/resty{_bak,}
    svc_reload nginx
    echo "${CSUCCESS}ngx_lua_waf disabled successfully! ${CEND}"
  else
    echo "${CFAILURE}ngx_lua_waf disable failed! ${CEND}"
  fi
  popd > /dev/null
}
