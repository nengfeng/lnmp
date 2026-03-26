#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: Common functions for PHP installation

# Check if PHP version is 8.4 or later
# PHP 8.4+ can use OpenSSL's built-in Argon2 via --with-openssl-argon2
php_ver_ge_84() {
  local ver=$1
  local major=$(echo "$ver" | cut -d. -f1)
  local minor=$(echo "$ver" | cut -d. -f2)
  [[ "$major" -ge 8 && "$minor" -ge 4 ]] || [[ "$major" -gt 8 ]]
}

# Check if OpenSSL version is 3.2 or later
# OpenSSL 3.2+ has built-in Argon2 support
openssl_ver_ge_32() {
  local ver
  ver=$(openssl version 2>/dev/null | awk '{print $2}')
  if [ -z "$ver" ]; then
    return 1
  fi
  local major=$(echo "$ver" | cut -d. -f1)
  local minor=$(echo "$ver" | cut -d. -f2)
  local patch=$(echo "$ver" | cut -d. -f3)
  # OpenSSL 3.2+ (version format: 3.2.0, 3.2.1, etc.)
  if [[ "$major" -ge 4 ]]; then
    return 0
  elif [[ "$major" -eq 3 ]]; then
    if [[ "$minor" -ge 2 ]]; then
      return 0
    fi
  fi
  return 1
}

# Check if we can use OpenSSL built-in Argon2
# Requires: PHP 8.4+ AND OpenSSL 3.2+
can_use_openssl_argon2() {
  local php_ver=$1
  php_ver_ge_84 "${php_ver}" && openssl_ver_ge_32
}

# Install PHP dependency libraries
# Usage: install_php_deps [php_ver]
#   php_ver: PHP version string (e.g., "8.3.20", "8.4.10")
#   PHP 8.4+ uses OpenSSL built-in Argon2, no libargon2 needed
install_php_deps() {
  local php_ver=${1:-}
  pushd ${current_dir}/src > /dev/null

  # curl
  if [ ! -e "${curl_install_dir}/lib/libcurl.la" ]; then
    tar xzf curl-${curl_ver}.tar.gz
    pushd curl-${curl_ver} > /dev/null
    [ -e "/usr/local/lib/libnghttp2.so" ] && with_nghttp2='--with-nghttp2=/usr/local'
    ./configure --prefix=${curl_install_dir} ${php_with_ssl} ${with_nghttp2}
    compile_and_install
    popd > /dev/null
    cleanup_src curl-${curl_ver}
  fi

  # freetype
  if [ ! -e "${freetype_install_dir}/lib/libfreetype.la" ]; then
    tar xzf freetype-${freetype_ver}.tar.gz
    pushd freetype-${freetype_ver} > /dev/null
    ./configure --prefix=${freetype_install_dir} --enable-freetype-config
    compile_and_install
    ln -sf ${freetype_install_dir}/include/freetype2/* /usr/include/
    [ -d /usr/lib/pkgconfig ] && /bin/cp ${freetype_install_dir}/lib/pkgconfig/freetype2.pc /usr/lib/pkgconfig/
    popd > /dev/null
    cleanup_src freetype-${freetype_ver}
  fi

  # argon2 - only needed when can't use OpenSSL built-in Argon2
  # Requires PHP 8.4+ AND OpenSSL 3.2+ to skip libargon2
  if ! can_use_openssl_argon2 "${php_ver}"; then
    if [ ! -e "/usr/local/lib/pkgconfig/libargon2.pc" ]; then
      tar xzf phc-winner-argon2-${argon2_ver}.tar.gz
      pushd phc-winner-argon2-${argon2_ver} > /dev/null
      compile_and_install
      popd > /dev/null
      cleanup_src phc-winner-argon2-${argon2_ver}
      # Create pkg-config file (argon2 source doesn't include one)
      [ ! -d /usr/local/lib/pkgconfig ] && mkdir -p /usr/local/lib/pkgconfig
      cat > /usr/local/lib/pkgconfig/libargon2.pc << 'EOF'
prefix=/usr/local
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: libargon2
Description: Argon2 password hashing library
Version: 20190702
Libs: -L${libdir} -largon2
Cflags: -I${includedir}
EOF
    fi
  fi

  # libsodium
  if [ ! -e "/usr/local/lib/libsodium.la" ]; then
    tar xzf libsodium-${libsodium_ver}.tar.gz
    pushd libsodium-${libsodium_ver} > /dev/null
    ./configure --disable-dependency-tracking --enable-minimal
    compile_and_install
    popd > /dev/null
    cleanup_src libsodium-${libsodium_ver}
  fi

  # libzip
  if [ ! -e "/usr/local/lib/libzip.la" ]; then
    tar xzf libzip-${libzip_ver}.tar.gz
    pushd libzip-${libzip_ver} > /dev/null
    ./configure
    compile_and_install
    popd > /dev/null
    cleanup_src libzip-${libzip_ver}
  fi

  # mhash
  if [[ ! -e "/usr/local/include/mhash.h" && ! -e "/usr/include/mhash.h" ]]; then
    tar xzf mhash-${mhash_ver}.tar.gz
    pushd mhash-${mhash_ver} > /dev/null
    ./configure
    compile_and_install
    popd > /dev/null
    cleanup_src mhash-${mhash_ver}
  fi

  # binutils
  if [ ! -e "/usr/local/include/bfd.h" ]; then
    tar xzf binutils-${binutils_ver}.tar.gz
    pushd binutils-${binutils_ver} > /dev/null
    ./configure
    compile_and_install
    popd > /dev/null
    cleanup_src binutils-${binutils_ver}
  fi

  add_lib_path /usr/local/lib
  
  popd > /dev/null
}

# Generate php.ini configuration
# Usage: generate_php_ini php_install_dir
generate_php_ini() {
  local php_dir=$1
  
  sed -i "s@^memory_limit.*@memory_limit = ${Memory_limit}M@" ${php_dir}/etc/php.ini
  sed -i 's@^output_buffering =@output_buffering = On\noutput_buffering =@' ${php_dir}/etc/php.ini
  sed -i 's@^short_open_tag = Off@short_open_tag = On@' ${php_dir}/etc/php.ini
  sed -i 's@^expose_php = On@expose_php = Off@' ${php_dir}/etc/php.ini
  sed -i 's@^request_order.*@request_order = "CGP"@' ${php_dir}/etc/php.ini
  sed -i "s@^;date.timezone.*@date.timezone = ${timezone}@" ${php_dir}/etc/php.ini
  sed -i 's@^post_max_size.*@post_max_size = 100M@' ${php_dir}/etc/php.ini
  sed -i 's@^upload_max_filesize.*@upload_max_filesize = 50M@' ${php_dir}/etc/php.ini
  sed -i 's@^max_execution_time.*@max_execution_time = 600@' ${php_dir}/etc/php.ini
  sed -i 's@^;realpath_cache_size.*@realpath_cache_size = 2M@' ${php_dir}/etc/php.ini
  sed -i 's@^disable_functions.*@disable_functions = passthru,exec,system,chroot,chgrp,chown,shell_exec,proc_open,proc_get_status,proc_close,proc_nice,proc_terminate,ini_alter,ini_restore,dl,readlink,symlink,popepassthru,stream_socket_server,fsocket,popen,pcntl_exec,pcntl_fork,pcntl_signal,pcntl_wait,assert,show_source,syslog@' ${php_dir}/etc/php.ini
  [ -e /usr/sbin/sendmail ] && sed -i 's@^;sendmail_path.*@sendmail_path = /usr/sbin/sendmail -t -i@' ${php_dir}/etc/php.ini
  
  if [ "${with_old_openssl_flag}" = 'y' ]; then
    sed -i "s@^;curl.cainfo.*@curl.cainfo = \"${openssl_install_dir}/cert.pem\"@" ${php_dir}/etc/php.ini
    sed -i "s@^;openssl.cafile.*@openssl.cafile = \"${openssl_install_dir}/cert.pem\"@" ${php_dir}/etc/php.ini
    sed -i "s@^;openssl.capath.*@openssl.capath = \"${openssl_install_dir}/cert.pem\"@" ${php_dir}/etc/php.ini
  fi
}

# Generate opcache configuration
# Usage: generate_opcache_ini php_install_dir [zend_extension]
generate_opcache_ini() {
  local php_dir=$1
  local zend_ext=${2:-"opcache.so"}
  
  [[ "${phpcache_option}" == 1 ]] && cat > ${php_dir}/etc/php.d/02-opcache.ini << EOF
[opcache]
zend_extension=${zend_ext}
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=${Memory_limit}
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=100000
opcache.max_wasted_percentage=5
opcache.use_cwd=1
opcache.validate_timestamps=1
opcache.revalidate_freq=60
;opcache.save_comments=0
opcache.consistency_checks=0
;opcache.optimization_level=0
EOF
}

# Generate php-fpm.conf configuration
# Usage: generate_php_fpm_conf php_install_dir
generate_php_fpm_conf() {
  local php_dir=$1
  
  cat > ${php_dir}/etc/php-fpm.conf <<EOF
;;;;;;;;;;;;;;;;;;;;;
; FPM Configuration ;
;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;
; Global Options ;
;;;;;;;;;;;;;;;;;;

[global]
pid = run/php-fpm.pid
error_log = log/php-fpm.log
log_level = warning

emergency_restart_threshold = 30
emergency_restart_interval = 60s
process_control_timeout = 5s
daemonize = yes

;;;;;;;;;;;;;;;;;;;;
; Pool Definitions ;
;;;;;;;;;;;;;;;;;;;;

[${run_user}]
listen = /dev/shm/php-cgi.sock
listen.backlog = -1
listen.allowed_clients = 127.0.0.1
listen.owner = ${run_user}
listen.group = ${run_group}
listen.mode = 0666
user = ${run_user}
group = ${run_group}

pm = dynamic
pm.max_children = 12
pm.start_servers = 8
pm.min_spare_servers = 6
pm.max_spare_servers = 12
pm.max_requests = 2048
pm.process_idle_timeout = 10s
request_terminate_timeout = 120
request_slowlog_timeout = 0

pm.status_path = /php-fpm_status
slowlog = var/log/slow.log
rlimit_files = 51200
rlimit_core = 0

catch_workers_output = yes
;env[HOSTNAME] = $HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp
EOF
}

# Configure php-fpm pool based on memory and server scenario
# Usage: config_php_fpm_pool php_install_dir memory_mb [scenario]
# scenario: "vps" (default) or "dedicated"
config_php_fpm_pool() {
  local php_dir=$1
  local mem=$2
  local scenario=${3:-vps}
  
  if [[ "${scenario}" == "dedicated" ]]; then
    # Dedicated server: more aggressive settings
    # Each PHP-FPM worker uses ~20-40MB, allow more workers
    if [ ${mem} -le 4000 ]; then
      # 4GB or less
      sed -i "s@^pm.max_children.*@pm.max_children = 80@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.start_servers.*@pm.start_servers = 20@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.min_spare_servers.*@pm.min_spare_servers = 10@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.max_spare_servers.*@pm.max_spare_servers = 40@" ${php_dir}/etc/php-fpm.conf
    elif [[ ${mem} -gt 4000 && ${mem} -le 8000 ]]; then
      # 4-8GB
      sed -i "s@^pm.max_children.*@pm.max_children = 120@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.start_servers.*@pm.start_servers = 40@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.min_spare_servers.*@pm.min_spare_servers = 20@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.max_spare_servers.*@pm.max_spare_servers = 60@" ${php_dir}/etc/php-fpm.conf
    elif [[ ${mem} -gt 8000 && ${mem} -le 16000 ]]; then
      # 8-16GB
      sed -i "s@^pm.max_children.*@pm.max_children = 200@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.start_servers.*@pm.start_servers = 60@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.min_spare_servers.*@pm.min_spare_servers = 30@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.max_spare_servers.*@pm.max_spare_servers = 100@" ${php_dir}/etc/php-fpm.conf
    elif [ ${mem} -gt 16000 ]; then
      # 16GB+
      sed -i "s@^pm.max_children.*@pm.max_children = 300@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.start_servers.*@pm.start_servers = 100@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.min_spare_servers.*@pm.min_spare_servers = 50@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.max_spare_servers.*@pm.max_spare_servers = 150@" ${php_dir}/etc/php-fpm.conf
    fi
    # Dedicated server: increase file limits
    sed -i "s@^rlimit_files.*@rlimit_files = 65535@" ${php_dir}/etc/php-fpm.conf
  else
    # VPS: conservative settings (resource-limited)
    if [ ${mem} -le 1024 ]; then
      # 1GB or less - very limited
      sed -i "s@^pm.max_children.*@pm.max_children = 5@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.start_servers.*@pm.start_servers = 2@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.min_spare_servers.*@pm.min_spare_servers = 1@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.max_spare_servers.*@pm.max_spare_servers = 3@" ${php_dir}/etc/php-fpm.conf
    elif [ ${mem} -le 2048 ]; then
      # 1-2GB
      sed -i "s@^pm.max_children.*@pm.max_children = 10@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.start_servers.*@pm.start_servers = 4@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.min_spare_servers.*@pm.min_spare_servers = 2@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.max_spare_servers.*@pm.max_spare_servers = 6@" ${php_dir}/etc/php-fpm.conf
    elif [ ${mem} -le 3000 ]; then
      sed -i "s@^pm.max_children.*@pm.max_children = $((${mem}/3/20))@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.start_servers.*@pm.start_servers = $((${mem}/3/30))@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.min_spare_servers.*@pm.min_spare_servers = $((${mem}/3/40))@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.max_spare_servers.*@pm.max_spare_servers = $((${mem}/3/20))@" ${php_dir}/etc/php-fpm.conf
    elif [[ ${mem} -gt 3000 && ${mem} -le 4500 ]]; then
      sed -i "s@^pm.max_children.*@pm.max_children = 50@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.start_servers.*@pm.start_servers = 30@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.min_spare_servers.*@pm.min_spare_servers = 20@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.max_spare_servers.*@pm.max_spare_servers = 50@" ${php_dir}/etc/php-fpm.conf
    elif [[ ${mem} -gt 4500 && ${mem} -le 6500 ]]; then
      sed -i "s@^pm.max_children.*@pm.max_children = 60@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.start_servers.*@pm.start_servers = 40@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.min_spare_servers.*@pm.min_spare_servers = 30@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.max_spare_servers.*@pm.max_spare_servers = 60@" ${php_dir}/etc/php-fpm.conf
    elif [[ ${mem} -gt 6500 && ${mem} -le 8500 ]]; then
      sed -i "s@^pm.max_children.*@pm.max_children = 70@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.start_servers.*@pm.start_servers = 50@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.min_spare_servers.*@pm.min_spare_servers = 40@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.max_spare_servers.*@pm.max_spare_servers = 70@" ${php_dir}/etc/php-fpm.conf
    elif [ ${mem} -gt 8500 ]; then
      sed -i "s@^pm.max_children.*@pm.max_children = 80@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.start_servers.*@pm.start_servers = 60@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.min_spare_servers.*@pm.min_spare_servers = 50@" ${php_dir}/etc/php-fpm.conf
      sed -i "s@^pm.max_spare_servers.*@pm.max_spare_servers = 80@" ${php_dir}/etc/php-fpm.conf
    fi
  fi
}

# Setup php-fpm service
# Usage: setup_php_fpm_service php_install_dir
setup_php_fpm_service() {
  local php_dir=$1

  /bin/cp ${current_dir}/systemd/php-fpm.service /lib/systemd/system/
  sed -i "s@/usr/local/php@${php_dir}@g" /lib/systemd/system/php-fpm.service
  svc_daemon_reload
  svc_enable php-fpm
  svc_start php-fpm
}

# ============================================
# Common PHP Installation Function
# ============================================

# Install PHP from source (common function)
# Usage: install_php_source php_ver php_install_dir thread_count
# Required variables: php_with_ssl, php_with_curl, php_with_openssl, phpcache_option, php_modules_options
install_php_source() {
  local php_ver=$1
  local install_dir=$2
  local threads=$3
  
  tar xzf php-${php_ver}.tar.gz
  pushd php-${php_ver} > /dev/null
  make clean
  export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig/:$PKG_CONFIG_PATH
  [ ! -d "${install_dir}" ] && mkdir -p ${install_dir}
  
  # Build opcache argument (PHP 8.5 has it built-in)
  if [[ "${php_ver}" =~ ^8\.[0-4]\. ]]; then
    [[ "${phpcache_option}" == 1 ]] && local phpcache_arg='--enable-opcache' || local phpcache_arg='--disable-opcache'
  else
    local phpcache_arg=''
  fi
  
  # Build argon2 argument (PHP 8.4+ with OpenSSL 3.2+ uses built-in Argon2)
  if can_use_openssl_argon2 "${php_ver}"; then
    local argon2_arg='--with-openssl-argon2'
  else
    local argon2_arg='--with-password-argon2'
  fi
  
  ICONV_PLUG=1 ./configure --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) --prefix=${install_dir} --with-config-file-path=${install_dir}/etc \
    --with-config-file-scan-dir=${install_dir}/etc/php.d \
    --with-fpm-user=${run_user} --with-fpm-group=${run_group} --enable-fpm ${phpcache_arg} --disable-fileinfo \
    --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
    --with-iconv --with-freetype --with-jpeg --with-zlib \
    --enable-xml --disable-rpath --enable-bcmath --enable-shmop --enable-exif \
    --enable-sysvsem ${php_with_curl} --enable-mbregex \
    --enable-mbstring ${argon2_arg} --with-sodium=/usr/local --enable-gd ${php_with_openssl} \
    --with-mhash --enable-pcntl --enable-sockets --enable-ftp --enable-intl --with-xsl \
    --with-gettext --with-zip=/usr/local --enable-soap --disable-debug ${php_modules_options}
  make -j ${threads}
  make install
  popd > /dev/null
}

# Post-install PHP setup
# Usage: post_install_php php_ver php_install_dir memory_limit [scenario]
# scenario: "vps" (default) or "dedicated"
post_install_php() {
  local php_ver=$1
  local install_dir=$2
  local mem=$3
  local scenario=${4:-vps}
  
  if [ -e "${install_dir}/bin/phpize" ]; then
    [ ! -e "${install_dir}/etc/php.d" ] && mkdir -p ${install_dir}/etc/php.d
    echo "${CSUCCESS}PHP installed successfully! ${CEND}"
  else
    rm -rf ${install_dir}
    die_hard "PHP install failed, Please Contact the author!"
  fi

  add_to_path ${install_dir}/bin
  /bin/cp php-${php_ver}/php.ini-production ${install_dir}/etc/php.ini
  generate_php_ini ${install_dir}
  
  # PHP 8.5 has opcache built-in
  if [[ "${php_ver}" =~ ^8\.[0-4]\. ]]; then
    generate_opcache_ini ${install_dir}
  else
    # PHP 8.5+ opcache config (no zend_extension needed)
    cat > ${install_dir}/etc/php.d/02-opcache.ini << EOF
[opcache]
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=${Memory_limit}
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=100000
opcache.max_wasted_percentage=5
opcache.use_cwd=1
opcache.validate_timestamps=1
opcache.revalidate_freq=60
;opcache.save_comments=0
opcache.consistency_checks=0
;opcache.optimization_level=0
EOF
  fi
  
  generate_php_fpm_conf ${install_dir}
  config_php_fpm_pool ${install_dir} ${mem} ${scenario}
  setup_php_fpm_service ${install_dir}

  # Setup logrotate
  setup_php_fpm_logrotate ${install_dir}

  rm -rf php-${php_ver}
}
