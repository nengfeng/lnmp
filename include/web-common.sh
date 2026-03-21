#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: Common functions for Nginx/Tengine/OpenResty installation

# Generate proxy.conf
# Usage: generate_proxy_conf install_dir
generate_proxy_conf() {
  local install_dir=$1
  cat > ${install_dir}/conf/proxy.conf << EOF
proxy_connect_timeout 300s;
proxy_send_timeout 900;
proxy_read_timeout 900;
proxy_buffer_size 32k;
proxy_buffers 4 64k;
proxy_busy_buffers_size 128k;
proxy_redirect off;
proxy_hide_header Vary;
proxy_set_header Accept-Encoding '';
proxy_set_header Referer \$http_referer;
proxy_set_header Cookie \$http_cookie;
proxy_set_header Host \$host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
EOF
}

# Configure nginx.conf after copy
# Usage: config_nginx_conf install_dir [scenario]
config_nginx_conf() {
  local install_dir=$1
  local scenario=${2:-"vps"}
  
  sed -i "s@/data/wwwroot/default@${wwwroot_dir}/default@" ${install_dir}/conf/nginx.conf
  sed -i "s@/data/wwwlogs@${wwwlogs_dir}@g" ${install_dir}/conf/nginx.conf
  sed -i "s@^user www www@user ${run_user} ${run_group}@" ${install_dir}/conf/nginx.conf
  
  # Configure based on server scenario
  config_nginx_scenario ${install_dir} ${scenario}
  
  # Add php-fpm status location if PHP is installed
  # Note: Main PHP uses 'php-cgi.sock', additional PHP versions use 'php{ver}-cgi.sock'
  if [ -e "${php_install_dir}/sbin/php-fpm" ] && [ -z "$(grep '/php-fpm_status' ${install_dir}/conf/nginx.conf)" ]; then
    sed -i "s@index index.html index.php;@index index.html index.php;\n    location ~ /php-fpm_status {\n        #fastcgi_pass remote_php_ip:9000;\n        fastcgi_pass unix:/dev/shm/php-cgi.sock;\n        fastcgi_index index.php;\n        include fastcgi.conf;\n        allow 127.0.0.1;\n        deny all;\n        }@" ${install_dir}/conf/nginx.conf
  fi
}

# Configure nginx based on server scenario (VPS vs Dedicated)
# Usage: config_nginx_scenario install_dir scenario
config_nginx_scenario() {
  local install_dir=$1
  local scenario=$2
  
  if [[ "${scenario}" == "dedicated" ]]; then
    # Dedicated server settings - higher performance
    sed -i 's@^worker_rlimit_nofile.*@worker_rlimit_nofile 102400;@' ${install_dir}/conf/nginx.conf
    sed -i 's@^  worker_connections.*@  worker_connections 102400;@' ${install_dir}/conf/nginx.conf
    sed -i 's@^  keepalive_timeout.*@  keepalive_timeout 300;@' ${install_dir}/conf/nginx.conf

    # Larger buffers for high traffic
    sed -i 's@^  client_header_buffer_size.*@  client_header_buffer_size 64k;@' ${install_dir}/conf/nginx.conf
    sed -i 's@^  large_client_header_buffers.*@  large_client_header_buffers 8 64k;@' ${install_dir}/conf/nginx.conf

    # FastCGI buffers
    sed -i 's@^  fastcgi_buffer_size.*@  fastcgi_buffer_size 128k;@' ${install_dir}/conf/nginx.conf
    sed -i 's@^  fastcgi_buffers.*@  fastcgi_buffers 8 128k;@' ${install_dir}/conf/nginx.conf
    sed -i 's@^  fastcgi_busy_buffers_size.*@  fastcgi_busy_buffers_size 256k;@' ${install_dir}/conf/nginx.conf

    # Enable open file cache for better static file performance
    # Use printf and append approach for multi-line config
    if ! grep -q "^  open_file_cache" ${install_dir}/conf/nginx.conf; then
      sed -i '/^  ##If you have a lot of static files/a\  ##Open file cache for static files\n  open_file_cache max=10000 inactive=30s;\n  open_file_cache_valid 60s;\n  open_file_cache_min_uses 2;\n  open_file_cache_errors on;' ${install_dir}/conf/nginx.conf
    fi

  else
    # VPS settings - resource conservative
    sed -i 's@^worker_rlimit_nofile.*@worker_rlimit_nofile 51200;@' ${install_dir}/conf/nginx.conf
    sed -i 's@^  worker_connections.*@  worker_connections 51200;@' ${install_dir}/conf/nginx.conf
    sed -i 's@^  keepalive_timeout.*@  keepalive_timeout 60;@' ${install_dir}/conf/nginx.conf

    # Smaller buffers to save memory
    sed -i 's@^  client_header_buffer_size.*@  client_header_buffer_size 32k;@' ${install_dir}/conf/nginx.conf
    sed -i 's@^  large_client_header_buffers.*@  large_client_header_buffers 4 32k;@' ${install_dir}/conf/nginx.conf

    # FastCGI buffers
    sed -i 's@^  fastcgi_buffer_size.*@  fastcgi_buffer_size 64k;@' ${install_dir}/conf/nginx.conf
    sed -i 's@^  fastcgi_buffers.*@  fastcgi_buffers 4 64k;@' ${install_dir}/conf/nginx.conf
    sed -i 's@^  fastcgi_busy_buffers_size.*@  fastcgi_busy_buffers_size 128k;@' ${install_dir}/conf/nginx.conf

    # Keep open_file_cache disabled for VPS (saves memory)
  fi
}

# Setup nginx service
# Usage: setup_nginx_service install_dir
setup_nginx_service() {
  local install_dir=$1
  
  /bin/cp ${current_dir}/systemd/nginx.service /lib/systemd/system/
  sed -i "s@/usr/local/nginx@${install_dir}@g" /lib/systemd/system/nginx.service
  service_action enable nginx
}

# Extract common build dependencies (PCRE2, OpenSSL)
# Usage: extract_web_deps
extract_web_deps() {
  pushd ${current_dir}/src > /dev/null
  tar xzf pcre2-${pcre_ver}.tar.gz
  tar xzf openssl-${openssl_ver}.tar.gz
  popd > /dev/null
}

# Cleanup build dependencies
# Usage: cleanup_web_deps
cleanup_web_deps() {
  pushd ${current_dir}/src > /dev/null
  rm -rf pcre2-${pcre_ver} openssl-${openssl_ver}
  popd > /dev/null
}

# Close debug in gcc
# Usage: close_gcc_debug source_dir
close_gcc_debug() {
  local src_dir=$1
  sed -i 's@CFLAGS="$CFLAGS -g"@#CFLAGS="$CFLAGS -g"@' ${src_dir}/auto/cc/gcc
}

# Install web server (Nginx/Tengine/OpenResty)
# Usage: install_web_server type version install_dir [extra_ld_opt]
# type: nginx, tengine, openresty
install_web_server() {
  local server_type=$1
  local server_ver=$2
  local install_dir=$3
  local extra_ld_opt=${4:-""}
  
  local src_name=${server_type}-${server_ver}
  local conf_dir=${install_dir}
  
  # OpenResty has different directory structure
  if [[ "${server_type}" == "openresty" ]]; then
    conf_dir=${install_dir}/nginx
  fi
  
  tar xzf pcre2-${pcre_ver}.tar.gz
  tar xzf ${src_name}.tar.gz
  tar xzf openssl-${openssl_ver}.tar.gz
  pushd ${src_name} > /dev/null
  
  # Close debug for nginx and openresty
  if [[ "${server_type}" == "nginx" ]]; then
    close_gcc_debug $(pwd)
  elif [[ "${server_type}" == "openresty" ]]; then
    close_gcc_debug bundle/nginx-${server_ver%.*}
  fi
  
  [ ! -d "${install_dir}" ] && mkdir -p ${install_dir}
  ./configure --prefix=${install_dir} --user=${run_user} --group=${run_group} \
    --with-http_stub_status_module --with-http_sub_module --with-http_v2_module \
    --with-http_v3_module --with-http_ssl_module --with-stream \
    --with-stream_ssl_preread_module --with-stream_ssl_module \
    --with-http_gzip_static_module --with-http_realip_module \
    --with-http_flv_module --with-http_mp4_module \
    --with-openssl=../openssl-${openssl_ver} \
    --with-pcre=../pcre2-${pcre_ver} --with-pcre-jit \
    --with-ld-opt="-ltcmalloc ${extra_ld_opt}" ${nginx_modules_options}
  
  compile_and_install
  
  if [ -e "${conf_dir}/conf/nginx.conf" ]; then
    popd > /dev/null
    cleanup_src pcre2-${pcre_ver} openssl-${openssl_ver} ${src_name}
    success_msg "${server_type}"
  else
    rm -rf ${install_dir}
    fail_msg "${server_type}"
  fi
}

# Post-install web server setup
# Usage: post_install_web_server install_dir [bin_dir] [scenario]
post_install_web_server() {
  local install_dir=$1
  local bin_dir=${2:-"${install_dir}/sbin"}
  local scenario=${3:-"vps"}
  
  add_to_path ${bin_dir}
  setup_nginx_service ${install_dir}
  
  mv ${install_dir}/conf/nginx.conf{,_bk}
  /bin/cp ${current_dir}/config/nginx.conf ${install_dir}/conf/nginx.conf
  config_nginx_conf ${install_dir} ${scenario}
  generate_proxy_conf ${install_dir}
  setup_nginx_logrotate ${wwwlogs_dir}
  ldconfig
  service_action start nginx
}

