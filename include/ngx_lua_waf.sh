#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Nginx_lua_waf() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${nginx_install_dir}/sbin/nginx" ] && echo "${CWARNING}Nginx is not installed on your system! ${CEND}" && exit 1
  if [ ! -e "/usr/local/lib/libluajit-5.1.so.2.1.0" ]; then
    [ -e "/usr/local/lib/libluajit-5.1.so.2.0.5" ] && find /usr/local -name *luajit* | xargs rm -rf
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
  nginx_configure_args=$(echo ${nginx_configure_args_tmp} | sed "s@--with-openssl=../openssl-\w.\w.\w\+ @--with-openssl=../openssl-${openssl_ver} @" | sed "s@--with-pcre=../pcre2-\w.\w\+ @--with-pcre=../pcre2-${pcre_ver} @")
  if [ -z "$(echo ${nginx_configure_args} | grep lua-nginx-module)" ]; then
    src_url=https://nginx.org/download/nginx-${nginx_ver}.tar.gz && Download_src
    src_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/openssl-${openssl_ver}.tar.gz" && Download_src
    src_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_ver}/pcre2-${pcre_ver}.tar.gz" && Download_src
    src_url="https://github.com/vision5/ngx_devel_kit/archive/refs/tags/0.3.3.tar.gz" && Download_src
    src_url="https://github.com/openresty/lua-nginx-module/archive/refs/tags/${lua_nginx_module_ver}.tar.gz" && Download_src
    tar xzf nginx-${nginx_ver}.tar.gz
    tar xzf openssl-${openssl_ver}.tar.gz
    tar xzf pcre2-${pcre_ver}.tar.gz
    tar xzf ngx_devel_kit.tar.gz
    tar xzf lua-nginx-module-${lua_nginx_module_ver}.tar.gz
    pushd nginx-${nginx_ver}
    make clean
    sed -i 's@CFLAGS="$CFLAGS -g"@#CFLAGS="$CFLAGS -g"@' auto/cc/gcc # close debug
    export LUAJIT_LIB=/usr/local/lib
    export LUAJIT_INC=/usr/local/include/luajit-2.1
    ./configure ${nginx_configure_args} --with-ld-opt="-Wl,-rpath,/usr/local/lib" --add-module=../lua-nginx-module-${lua_nginx_module_ver} --add-module=../ngx_devel_kit
    compile_check
    if [ -f "objs/nginx" ]; then
      /bin/mv ${nginx_install_dir}/sbin/nginx{,$(date +%m%d)}
      /bin/cp objs/nginx ${nginx_install_dir}/sbin/nginx
      kill -USR2 $(cat /var/run/nginx.pid)
      sleep 1
      kill -QUIT $(cat /var/run/nginx.pid.oldbin)
      popd > /dev/null
      success_msg "lua-nginx-module"
      sed -i "s@^nginx_modules_options='\(.*\)'@nginx_modules_options=\'\1 --with-ld-opt=\"-Wl,-rpath,/usr/local/lib\" --add-module=../lua-nginx-module-${lua_nginx_module_ver} --add-module=../ngx_devel_kit\'@" ../options.conf
      cleanup_src nginx-${nginx_ver}
    else
      fail_msg "lua-nginx-module"
    fi
  fi
  popd > /dev/null
}

Tengine_lua_waf() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${tengine_install_dir}/sbin/nginx" ] && echo "${CWARNING}Tengine is not installed on your system! ${CEND}" && exit 1
  if [ ! -e "/usr/local/lib/libluajit-5.1.so.2.1.0" ]; then
    [ -e "/usr/local/lib/libluajit-5.1.so.2.0.5" ] && find /usr/local -name *luajit* | xargs rm -rf
    src_url="https://github.com/openresty/luajit2/archive/refs/tags/${luajit2_ver}.tar.gz" && Download_src
    tar xzf luajit2-${luajit2_ver}.tar.gz
    pushd luajit2-${luajit2_ver}
    make && make install
    [ ! -e "/usr/local/lib/libluajit-5.1.so.2.1.0" ] && { fail_msg "LuaJIT"; }
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
  tengine_configure_args=$(echo ${tengine_configure_args_tmp} | sed "s@--with-openssl=../openssl-\w.\w.\w\+ @--with-openssl=../openssl-${openssl_ver} @" | sed "s@--with-pcre=../pcre2-\w.\w\+ @--with-pcre=../pcre2-${pcre_ver} @")
  if [ -z "$(echo ${tengine_configure_args} | grep lua)" ]; then
    src_url=https://tengine.taobao.org/download/tengine-${tengine_ver}.tar.gz && Download_src
    src_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/openssl-${openssl_ver}.tar.gz" && Download_src
    src_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_ver}/pcre2-${pcre_ver}.tar.gz" && Download_src
    src_url="https://github.com/vision5/ngx_devel_kit/archive/refs/tags/0.3.3.tar.gz" && Download_src
    src_url="https://github.com/openresty/lua-nginx-module/archive/refs/tags/${lua_nginx_module_ver}.tar.gz" && Download_src
    tar xzf tengine-${tengine_ver}.tar.gz
    tar xzf openssl-${openssl_ver}.tar.gz
    tar xzf pcre2-${pcre_ver}.tar.gz
    tar xzf ngx_devel_kit.tar.gz
    tar xzf lua-nginx-module.tar.gz
    pushd tengine-${tengine_ver}
    make clean
    export LUAJIT_LIB=/usr/local/lib
    export LUAJIT_INC=/usr/local/include/luajit-2.1
    ./configure ${tengine_configure_args} --with-ld-opt="-Wl,-rpath,/usr/local/lib" --add-module=../lua-nginx-module --add-module=../ngx_devel_kit
    compile_check
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
      sed -i "s@^nginx_modules_options='\(.*\)'@nginx_modules_options=\'\1 --with-ld-opt=\"-Wl,-rpath,/usr/local/lib\" --add-module=../lua-nginx-module --add-module=../ngx_devel_kit\'@" ../options.conf
      success_msg "lua_module"
      cleanup_src tengine-${tengine_ver}
    else
      fail_msg "lua_module"
    fi
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
  sed -i "s@/usr/local/nginx@${web_install_dir}:@" ${web_install_dir}/conf/waf/config.lua
  sed -i "s@/data/wwwlogs@${wwwlogs_dir}@" ${web_install_dir}/conf/waf/config.lua
  grep -q 'include waf.conf;' ${web_install_dir}/conf/nginx.conf || sed -i "s@ vhost/\*.conf;@&\n  include waf.conf;@" ${web_install_dir}/conf/nginx.conf
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
