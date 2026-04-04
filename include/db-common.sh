#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: Common functions for MySQL/MariaDB installation

# ============================================
# Library Compatibility Functions
# ============================================

# Fix libaio.so.1 symlink for Debian 13+ / Ubuntu 24.04+ (time64 transition)
# MySQL/MariaDB expects libaio.so.1 but newer distros install libaio.so.1t64
# Usage: fix_libaio_symlink
fix_libaio_symlink() {
  local libaio_target="/usr/lib/x86_64-linux-gnu/libaio.so.1"
  
  # Check if libaio.so.1 already exists
  if [ -e "${libaio_target}" ]; then
    return 0
  fi
  
  # Find the actual libaio library (libaio.so.1t64 or libaio.so.1t64.x.x)
  local libaio_src=$(find /usr/lib -name 'libaio.so.1t64*' -type f 2>/dev/null | head -1)
  
  if [ -n "${libaio_src}" ]; then
    ln -sf "${libaio_src}" "${libaio_target}"
    ldconfig
    echo "${CMSG}Created libaio.so.1 symlink -> ${libaio_src}${CEND}"
    return 0
  fi
  
  # If no libaio at all, try to install it
  echo "${CWARNING}libaio library not found, attempting to install...${CEND}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get -y install libaio1t64 2>/dev/null || apt-get -y install libaio1 2>/dev/null
    # Try again after install
    libaio_src=$(find /usr/lib -name 'libaio.so.1t64*' -type f 2>/dev/null | head -1)
    if [ -n "${libaio_src}" ]; then
      ln -sf "${libaio_src}" "${libaio_target}"
      ldconfig
      echo "${CMSG}Created libaio.so.1 symlink -> ${libaio_src}${CEND}"
    fi
  fi
}

# ============================================
# Database Ready Check Functions
# ============================================

# Wait for MySQL/MariaDB to be ready to accept connections
# Usage: wait_for_db_ready install_dir [timeout_seconds] [socket_path]
# Returns: 0 on success, 1 on timeout
wait_for_db_ready() {
  local install_dir=$1
  local timeout=${2:-600}
  local socket=${3:-/tmp/mysql.sock}
  local mysql_cmd="${install_dir}/bin/mysql"
  
  # Detect mariadb command for MariaDB 11.x+
  [ -x "${install_dir}/bin/mariadb" ] && mysql_cmd="${install_dir}/bin/mariadb"
  
  local start_time=$(date +%s)
  local elapsed=0
  
  echo "${CMSG}Waiting for database to be ready...${CEND}"
  
  while [ ${elapsed} -lt ${timeout} ]; do
    # Check if socket exists (primary indicator of readiness)
    if [ -S "${socket}" ]; then
      socket_ready=1
      
      # Try to connect - try both with and without password
      # Fresh install: no password
      if ${mysql_cmd} -uroot -e "SELECT 1" >/dev/null 2>&1; then
        echo "${CSUCCESS}Database is ready!${CEND}"
        return 0
      fi
      
      # Reinstall or password already set: use password from config
      if [ -n "${dbrootpwd}" ]; then
        if ${mysql_cmd} -uroot -p"${dbrootpwd}" -e "SELECT 1" >/dev/null 2>&1; then
          echo "${CSUCCESS}Database is ready!${CEND}"
          return 0
        fi
      fi
      
      # Socket exists but auth failed - check if process is running
      # This handles reinstall scenarios with different password
      if pgrep -x "mariadbd" >/dev/null 2>&1 || pgrep -x "mysqld" >/dev/null 2>&1; then
        # Process running and socket exists - DB is ready
        # Auth failure is expected for reinstall with different password
        echo "${CSUCCESS}Database is ready (socket exists, process running)!${CEND}"
        return 0
      fi
    fi
    
    sleep 2
    elapsed=$(($(date +%s) - start_time))
    
    # Progress indicator every 30 seconds
    if [ $((elapsed % 30)) -eq 0 ] && [ ${elapsed} -gt 0 ]; then
      echo "${CMSG}Still waiting... (${elapsed}s elapsed, timeout at ${timeout}s)${CEND}"
    fi
  done
  
  echo "${CFAILURE}Database failed to become ready within ${timeout} seconds${CEND}"
  return 1
}

# ============================================
# Common MySQL Installation Functions
# ============================================

# Install MySQL from binary package
# Usage: install_mysql_binary mysql_ver install_dir
install_mysql_binary() {
  local mysql_ver=$1
  local install_dir=$2
  
  tar xJf mysql-${mysql_ver}-linux-glibc2.28-x86_64.tar.xz
  mv mysql-${mysql_ver}-linux-glibc2.28-x86_64/* ${install_dir}
  sed -i "s@/usr/local/mysql@${install_dir}@g" ${install_dir}/bin/mysqld_safe
}

# Install MySQL from source
# Usage: install_mysql_source mysql_ver install_dir data_dir boost_ver thread_count
install_mysql_source() {
  local mysql_ver=$1
  local install_dir=$2
  local data_dir=$3
  local boost_ver=$4
  local threads=$5
  
  local boostVersion2=$(echo ${boost_ver} | awk -F. '{print $1"_"$2"_"$3}')
  tar xzf boost_${boostVersion2}.tar.gz
  tar xzf mysql-${mysql_ver}.tar.gz
  pushd mysql-${mysql_ver}
  [ -e "/usr/bin/cmake3" ] && local CMAKE=cmake3 || local CMAKE=cmake
  $CMAKE . -DCMAKE_INSTALL_PREFIX=${install_dir} \
    -DMYSQL_DATADIR=${data_dir} \
    -DDOWNLOAD_BOOST=1 \
    -DWITH_BOOST=../boost_${boostVersion2} \
    -DFORCE_INSOURCE_BUILD=1 \
    -DSYSCONFDIR=/etc \
    -DWITH_INNOBASE_STORAGE_ENGINE=1 \
    -DWITH_FEDERATED_STORAGE_ENGINE=1 \
    -DWITH_BLACKHOLE_STORAGE_ENGINE=1 \
    -DWITH_MYISAM_STORAGE_ENGINE=1 \
    -DENABLED_LOCAL_INFILE=1 \
    -DCMAKE_C_COMPILER=/usr/bin/gcc \
    -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
    -DDEFAULT_CHARSET=utf8mb4
  make -j ${threads}
  make install
  popd
}

# Cleanup MySQL installation files
# Usage: cleanup_mysql_files mysql_ver install_method
cleanup_mysql_files() {
  local mysql_ver=$1
  local method=$2
  
  if [[ "${method}" == "1" ]]; then
    rm -rf mysql-${mysql_ver}-*-x86_64
  elif [[ "${method}" == "2" ]]; then
    local boostVersion2=$(echo ${boost_ver} | awk -F. '{print $1"_"$2"_"$3}')
    rm -rf mysql-${mysql_ver} boost_${boostVersion2}
  fi
}

# Setup MySQL root user
# Usage: setup_mysql_root install_dir root_password [reset_master]
setup_mysql_root() {
  local install_dir=$1
  local root_pwd=$(echo "$2" | sed 's/\\/\\\\/g; s/'\''/\\'\''/g; s/\$/\\$/g; s/`/\\`/g; s/"/\\"/g')
  local reset_master=${3:-no}
  
  # Wait for database to be ready
  wait_for_db_ready ${install_dir} || return 1
  
  # MySQL 8.0 uses --initialize-insecure which creates root@localhost with empty password
  
  # 1. Create root@'127.0.0.1'
  ${install_dir}/bin/mysql -uroot -hlocalhost -e "CREATE USER IF NOT EXISTS root@'127.0.0.1' IDENTIFIED BY \"${root_pwd}\";" || {
    echo "${CFAILURE}Failed to create root@'127.0.0.1' user${CEND}"
    return 1
  }
  
  # 2. Grant privileges to root@'127.0.0.1'
  ${install_dir}/bin/mysql -uroot -hlocalhost -e "GRANT ALL PRIVILEGES ON *.* TO root@'127.0.0.1' WITH GRANT OPTION;"
  
  # 3. Set password for root@'localhost'
  ${install_dir}/bin/mysql -uroot -hlocalhost -e "ALTER USER root@'localhost' IDENTIFIED BY \"${root_pwd}\";" || {
    echo "${CFAILURE}Failed to set root@localhost password${CEND}"
    return 1
  }
  
  # 4. Grant privileges to root@'localhost'
  ${install_dir}/bin/mysql -uroot -p"${root_pwd}" -e "GRANT ALL PRIVILEGES ON *.* TO root@'localhost' WITH GRANT OPTION;"
  
  if [[ "${reset_master}" == "yes" ]]; then
    ${install_dir}/bin/mysql -uroot -p"${root_pwd}" -e "RESET MASTER;"
  fi
  
  echo "${CSUCCESS}MySQL root user setup completed${CEND}"
}

# ============================================
# Common MariaDB Installation Functions
# ============================================

# Install MariaDB from binary package
# Usage: install_mariadb_binary mariadb_ver install_dir
install_mariadb_binary() {
  local mariadb_ver=$1
  local install_dir=$2
  
  tar zxf mariadb-${mariadb_ver}-linux-systemd-x86_64.tar.gz
  mv mariadb-${mariadb_ver}-linux-systemd-x86_64/* ${install_dir}
  
  # Inject tcmalloc for better memory performance
  # Use mariadbd-safe for MariaDB 11.x+, mysqld_safe for older versions
  local safe_script="${install_dir}/bin/mariadbd-safe"
  [ ! -f "${safe_script}" ] && safe_script="${install_dir}/bin/mysqld_safe"
  if [ -f "${safe_script}" ]; then
    sed -i 's@executing mysqld_safe@executing mysqld_safe\nexport LD_PRELOAD=/usr/local/lib/libtcmalloc.so@' ${safe_script}
    sed -i "s@/usr/local/mysql@${install_dir}@g" ${safe_script}
  fi
}

# Install MariaDB from source
# Usage: install_mariadb_source mariadb_ver install_dir data_dir boost_ver thread_count
install_mariadb_source() {
  local mariadb_ver=$1
  local install_dir=$2
  local data_dir=$3
  local boost_ver=$4
  local threads=$5
  
  local boostVersion2=$(echo ${boost_ver} | awk -F. '{print $1"_"$2"_"$3}')
  tar xzf boost_${boostVersion2}.tar.gz
  tar xzf mariadb-${mariadb_ver}.tar.gz
  pushd mariadb-${mariadb_ver}
  cmake . -DCMAKE_INSTALL_PREFIX=${install_dir} \
    -DMYSQL_DATADIR=${data_dir} \
    -DDOWNLOAD_BOOST=1 \
    -DWITH_BOOST=../boost_${boostVersion2} \
    -DSYSCONFDIR=/etc \
    -DWITH_INNOBASE_STORAGE_ENGINE=1 \
    -DWITH_PARTITION_STORAGE_ENGINE=1 \
    -DWITH_FEDERATED_STORAGE_ENGINE=1 \
    -DWITH_BLACKHOLE_STORAGE_ENGINE=1 \
    -DWITH_MYISAM_STORAGE_ENGINE=1 \
    -DWITH_EMBEDDED_SERVER=1 \
    -DENABLE_DTRACE=0 \
    -DENABLED_LOCAL_INFILE=1 \
    -DDEFAULT_CHARSET=utf8mb4 \
    -DDEFAULT_COLLATION=utf8mb4_general_ci \
    -DEXTRA_CHARSETS=all \
    -DCMAKE_EXE_LINKER_FLAGS='-ltcmalloc'
  make -j ${threads}
  make install
  popd
}

# Cleanup MariaDB installation files
# Usage: cleanup_mariadb_files mariadb_ver install_method
cleanup_mariadb_files() {
  local mariadb_ver=$1
  local method=$2
  
  if [[ "${method}" == "1" ]]; then
    rm -rf mariadb-${mariadb_ver}-linux-systemd-x86_64
  elif [[ "${method}" == "2" ]]; then
    local boostVersion2=$(echo ${boost_oldver} | awk -F. '{print $1"_"$2"_"$3}')
    rm -rf mariadb-${mariadb_ver} boost_${boostVersion2}
  fi
}

# Setup MariaDB root user
# Usage: setup_mariadb_root install_dir root_password [cmd_name]
# cmd_name: 'mariadb' (default) or 'mysql' for older versions
setup_mariadb_root() {
  local install_dir=$1
  local root_pwd=$(echo "$2" | sed 's/\\/\\\\/g; s/'\''/\\'\''/g; s/\$/\\$/g; s/`/\\`/g; s/"/\\"/g')
  local cmd=${3:-mariadb}

  # Wait for database to be ready
  wait_for_db_ready ${install_dir} || return 1

  # Use ALTER USER syntax (compatible with MariaDB 10.11+ and 11.x)
  # Note: MariaDB 10.4+ uses unix_socket auth by default, so root can connect without password
  
  # 1. Set password for root@'localhost' (this user already exists after mysql_install_db)
  local password_set=0
  
  # Try ALTER USER first
  if ${install_dir}/bin/${cmd} -uroot -e "ALTER USER root@'localhost' IDENTIFIED BY \"${root_pwd}\";" 2>/dev/null; then
    password_set=1
    echo "${CMSG}root@localhost password set via ALTER USER${CEND}"
  else
    # Fallback to SET PASSWORD
    if ${install_dir}/bin/${cmd} -uroot -e "SET PASSWORD FOR root@'localhost' = PASSWORD(\"${root_pwd}\");" 2>/dev/null; then
      password_set=1
      echo "${CMSG}root@localhost password set via SET PASSWORD${CEND}"
    fi
  fi
  
  if [ ${password_set} -eq 0 ]; then
    echo "${CFAILURE}Failed to set root@localhost password!${CEND}"
    echo "${CWARNING}This may indicate database initialization issues.${CEND}"
    return 1
  fi
  
  # 2. Create root@'127.0.0.1' with same password (using password now)
  ${install_dir}/bin/${cmd} -uroot -p"${root_pwd}" -e "CREATE USER IF NOT EXISTS root@'127.0.0.1' IDENTIFIED BY \"${root_pwd}\";"
  ${install_dir}/bin/${cmd} -uroot -p"${root_pwd}" -e "GRANT ALL PRIVILEGES ON *.* TO root@'127.0.0.1' WITH GRANT OPTION;"
  
  # 3. Cleanup
  ${install_dir}/bin/${cmd} -uroot -p"${root_pwd}" -e "DELETE FROM mysql.user WHERE Password='' AND User NOT LIKE 'mariadb.%';"
  ${install_dir}/bin/${cmd} -uroot -p"${root_pwd}" -e "DELETE FROM mysql.db WHERE User='';"
  ${install_dir}/bin/${cmd} -uroot -p"${root_pwd}" -e "DELETE FROM mysql.proxies_priv WHERE Host!='localhost';"
  ${install_dir}/bin/${cmd} -uroot -p"${root_pwd}" -e "DROP DATABASE IF EXISTS test;"
  ${install_dir}/bin/${cmd} -uroot -p"${root_pwd}" -e "RESET MASTER;"
  
  echo "${CSUCCESS}MariaDB root user setup completed${CEND}"
}

# ============================================
# MySQL/MariaDB Configuration Functions
# ============================================

# Configure my.cnf based on server scenario (VPS vs Dedicated)
# Usage: config_my_cnf_scenario my.cnf_path scenario memory_mb
# scenario: "vps" or "dedicated"
config_my_cnf_scenario() {
  local cnf_file=$1
  local scenario=$2
  local mem=$3
  
  # Calculate parameters based on scenario
  if [[ "${scenario}" == "dedicated" ]]; then
    # Dedicated server settings
    # Per-connection buffers (can be larger)
    sed -i 's@^sort_buffer_size.*@sort_buffer_size = 2M@' ${cnf_file}
    sed -i 's@^join_buffer_size.*@join_buffer_size = 2M@' ${cnf_file}
    sed -i 's@^read_buffer_size.*@read_buffer_size = 1M@' ${cnf_file}
    sed -i 's@^read_rnd_buffer_size.*@read_rnd_buffer_size = 1M@' ${cnf_file}
    
    # Connection settings
    local max_conn=$((${mem} / 4))
    [ ${max_conn} -gt 500 ] && max_conn=500
    [ ${max_conn} -lt 50 ] && max_conn=50
    sed -i "s@^max_connections.*@max_connections = ${max_conn}@" ${cnf_file}
    sed -i 's@^max_connect_errors.*@max_connect_errors = 1000@' ${cnf_file}
    sed -i 's@^back_log.*@back_log = 300@' ${cnf_file}
    
    # Thread cache
    local thread_cache=$((max_conn / 8))
    [ ${thread_cache} -lt 16 ] && thread_cache=16
    [ ${thread_cache} -gt 64 ] && thread_cache=64
    sed -i "s@^thread_cache_size.*@thread_cache_size = ${thread_cache}@" ${cnf_file}
    
    # InnoDB settings
    local innodb_buf=$((${mem} * 70 / 100))  # 70% of memory
    sed -i "s@^innodb_buffer_pool_size.*@innodb_buffer_pool_size = ${innodb_buf}M@" ${cnf_file}
    
    # InnoDB buffer pool instances (1 per GB, max 8)
    local instances=$((${innodb_buf} / 1024))
    [ ${instances} -lt 1 ] && instances=1
    [ ${instances} -gt 8 ] && instances=8
    sed -i "s@^#innodb_buffer_pool_instances.*@innodb_buffer_pool_instances = ${instances}@" ${cnf_file}
    # Add if not exists
    grep -q "^innodb_buffer_pool_instances" ${cnf_file} || \
      sed -i "/innodb_buffer_pool_size/a innodb_buffer_pool_instances = ${instances}" ${cnf_file}
    
    # Log file size (1/8 of buffer pool, max 256M)
    local log_size=$((${innodb_buf} / 8))
    [ ${log_size} -lt 32 ] && log_size=32
    [ ${log_size} -gt 256 ] && log_size=256
    sed -i "s@^innodb_log_file_size.*@innodb_log_file_size = ${log_size}M@" ${cnf_file}
    sed -i 's@^innodb_log_buffer_size.*@innodb_log_buffer_size = 8M@' ${cnf_file}
    
    # Add innodb_flush_method if not exists
    grep -q "^innodb_flush_method" ${cnf_file} || \
      sed -i "/innodb_log_buffer_size/a innodb_flush_method = O_DIRECT" ${cnf_file}
    
    # IO capacity for SSD/better storage
    sed -i 's@^#innodb_io_capacity.*@innodb_io_capacity = 1000@' ${cnf_file}
    grep -q "^innodb_io_capacity" ${cnf_file} || \
      sed -i "/innodb_flush_method/a innodb_io_capacity = 1000" ${cnf_file}
    grep -q "^innodb_io_capacity_max" ${cnf_file} || \
      sed -i "/innodb_io_capacity/a innodb_io_capacity_max = 2000" ${cnf_file}
    
    # Data safety for dedicated servers
    sed -i 's@^innodb_flush_log_at_trx_commit.*@innodb_flush_log_at_trx_commit = 1@' ${cnf_file}
    
    # Table and file settings
    sed -i 's@^table_open_cache.*@table_open_cache = 2000@' ${cnf_file}
    sed -i 's@^innodb_open_files.*@innodb_open_files = 2000@' ${cnf_file}
    
    # Temp tables
    sed -i 's@^tmp_table_size.*@tmp_table_size = 64M@' ${cnf_file}
    sed -i 's@^max_heap_table_size.*@max_heap_table_size = 64M@' ${cnf_file}
    
    # MyISAM
    local key_buf=$((${mem} / 10))
    [ ${key_buf} -gt 256 ] && key_buf=256
    [ ${key_buf} -lt 8 ] && key_buf=8
    sed -i "s@^key_buffer_size.*@key_buffer_size = ${key_buf}M@" ${cnf_file}
    sed -i 's@^myisam_sort_buffer_size.*@myisam_sort_buffer_size = 64M@' ${cnf_file}
    
    # Timeout
    sed -i 's@^interactive_timeout.*@interactive_timeout = 3600@' ${cnf_file}
    sed -i 's@^wait_timeout.*@wait_timeout = 3600@' ${cnf_file}
    
    # Query cache for MySQL 5.7/MariaDB (disable for high concurrency)
    sed -i 's@^query_cache_type.*@query_cache_type = 0@' ${cnf_file} 2>/dev/null
    sed -i 's@^query_cache_size.*@query_cache_size = 0@' ${cnf_file} 2>/dev/null
    
  else
    # VPS settings (resource-limited)
    # Per-connection buffers (smaller to save memory)
    sed -i 's@^sort_buffer_size.*@sort_buffer_size = 512K@' ${cnf_file}
    sed -i 's@^join_buffer_size.*@join_buffer_size = 512K@' ${cnf_file}
    sed -i 's@^read_buffer_size.*@read_buffer_size = 128K@' ${cnf_file}
    sed -i 's@^read_rnd_buffer_size.*@read_rnd_buffer_size = 256K@' ${cnf_file}
    
    # Connection settings
    local max_conn=$((${mem} / 8))
    [ ${max_conn} -gt 100 ] && max_conn=100
    [ ${max_conn} -lt 20 ] && max_conn=20
    sed -i "s@^max_connections.*@max_connections = ${max_conn}@" ${cnf_file}
    sed -i 's@^max_connect_errors.*@max_connect_errors = 100@' ${cnf_file}
    sed -i 's@^back_log.*@back_log = 150@' ${cnf_file}
    
    # Thread cache
    local thread_cache=$((max_conn / 4))
    [ ${thread_cache} -lt 4 ] && thread_cache=4
    [ ${thread_cache} -gt 16 ] && thread_cache=16
    sed -i "s@^thread_cache_size.*@thread_cache_size = ${thread_cache}@" ${cnf_file}
    
    # InnoDB settings
    local innodb_buf=$((${mem} / 2))  # 50% of memory
    sed -i "s@^innodb_buffer_pool_size.*@innodb_buffer_pool_size = ${innodb_buf}M@" ${cnf_file}
    
    # Single instance for VPS
    sed -i 's@^#innodb_buffer_pool_instances.*@innodb_buffer_pool_instances = 1@' ${cnf_file} 2>/dev/null
    
    # Log file size
    sed -i 's@^innodb_log_file_size.*@innodb_log_file_size = 32M@' ${cnf_file}
    sed -i 's@^innodb_log_buffer_size.*@innodb_log_buffer_size = 2M@' ${cnf_file}
    
    # Add innodb_flush_method if not exists
    grep -q "^innodb_flush_method" ${cnf_file} || \
      sed -i "/innodb_log_buffer_size/a innodb_flush_method = O_DIRECT" ${cnf_file}
    
    # IO capacity for VPS (usually slower storage)
    sed -i 's@^#innodb_io_capacity.*@innodb_io_capacity = 200@' ${cnf_file}
    grep -q "^innodb_io_capacity" ${cnf_file} || \
      sed -i "/innodb_flush_method/a innodb_io_capacity = 200" ${cnf_file}
    grep -q "^innodb_io_capacity_max" ${cnf_file} || \
      sed -i "/innodb_io_capacity/a innodb_io_capacity_max = 400" ${cnf_file}
    
    # Performance over safety for VPS
    # WARNING: innodb_flush_log_at_trx_commit = 2 may lose up to 1 second of data on crash
    # For production environments requiring full ACID compliance, change to 1
    echo "${CWARNING}[Security Notice] VPS mode: innodb_flush_log_at_trx_commit=2 may lose up to 1 second of data on crash.${CEND}"
    echo "${CMSG}For production environments requiring full ACID compliance, set server_scenario=dedicated or manually change to 1.${CEND}"
    sed -i 's@^innodb_flush_log_at_trx_commit.*@innodb_flush_log_at_trx_commit = 2@' ${cnf_file}
    
    # Table and file settings
    sed -i 's@^table_open_cache.*@table_open_cache = 400@' ${cnf_file}
    sed -i 's@^innodb_open_files.*@innodb_open_files = 500@' ${cnf_file}
    
    # Temp tables
    sed -i 's@^tmp_table_size.*@tmp_table_size = 16M@' ${cnf_file}
    sed -i 's@^max_heap_table_size.*@max_heap_table_size = 16M@' ${cnf_file}
    
    # MyISAM
    local key_buf=$((${mem} / 20))
    [ ${key_buf} -gt 16 ] && key_buf=16
    [ ${key_buf} -lt 4 ] && key_buf=4
    sed -i "s@^key_buffer_size.*@key_buffer_size = ${key_buf}M@" ${cnf_file}
    sed -i 's@^myisam_sort_buffer_size.*@myisam_sort_buffer_size = 8M@' ${cnf_file}
    
    # Timeout (shorter for VPS to release resources)
    sed -i 's@^interactive_timeout.*@interactive_timeout = 1800@' ${cnf_file}
    sed -i 's@^wait_timeout.*@wait_timeout = 1800@' ${cnf_file}
    
    # Query cache for MySQL 5.7/MariaDB (enable for low concurrency VPS)
    sed -i 's@^query_cache_type.*@query_cache_type = 1@' ${cnf_file} 2>/dev/null
    sed -i 's@^query_cache_size.*@query_cache_size = 8M@' ${cnf_file} 2>/dev/null
  fi
}

# Configure my.cnf based on memory size (additional fine-tuning)
# Usage: config_my_cnf_memory my.cnf_path memory_mb
config_my_cnf_memory() {
  local cnf_file=$1
  local mem=$2
  
  # Additional memory-based adjustments
  if [ ${mem} -le 1024 ]; then
    # Very low memory (<=1GB): further reduce buffers
    sed -i 's@^innodb_buffer_pool_size.*@innodb_buffer_pool_size = 128M@' ${cnf_file}
    sed -i 's@^max_connections.*@max_connections = 20@' ${cnf_file}
  elif [ ${mem} -le 2048 ]; then
    # Low memory (1-2GB)
    sed -i 's@^innodb_buffer_pool_size.*@innodb_buffer_pool_size = 512M@' ${cnf_file}
    sed -i 's@^max_connections.*@max_connections = 50@' ${cnf_file}
  fi
}

# Generate my.cnf for MySQL 8.x
# Usage: generate_my_cnf_mysql8 install_dir data_dir
generate_my_cnf_mysql8() {
  local install_dir=$1
  local data_dir=$2
  
  cat > /etc/my.cnf << EOF
[client]
port = 3306
socket = /tmp/mysql.sock
default-character-set = utf8mb4

[mysql]
prompt="MySQL [\\d]> "
no-auto-rehash

[mysqld]
port = 3306
socket = /tmp/mysql.sock

basedir = ${install_dir}
datadir = ${data_dir}
pid-file = ${data_dir}/mysql.pid
user = mysql
bind-address = 127.0.0.1
server-id = 1

init-connect = 'SET NAMES utf8mb4'
character-set-server = utf8mb4
collation-server = utf8mb4_0900_ai_ci

skip-name-resolve
local_infile = 0
#skip-networking
back_log = 150

max_connections = 100
max_connect_errors = 100
open_files_limit = 65535
table_open_cache = 400
max_allowed_packet = 32M
binlog_cache_size = 1M
max_heap_table_size = 16M
tmp_table_size = 16M

read_buffer_size = 128K
read_rnd_buffer_size = 256K
sort_buffer_size = 512K
join_buffer_size = 512K
key_buffer_size = 4M

thread_cache_size = 8

ft_min_word_len = 4

log_bin = mysql-bin
binlog_expire_logs_seconds = 604800

log_error = ${data_dir}/mysql-error.log
slow_query_log = 1
long_query_time = 1
slow_query_log_file = ${data_dir}/mysql-slow.log

performance_schema = 0
explicit_defaults_for_timestamp

#lower_case_table_names = 1

skip-external-locking

default_storage_engine = InnoDB
#default-storage-engine = MyISAM
innodb_file_per_table = 1
innodb_open_files = 500
innodb_buffer_pool_size = 64M
innodb_write_io_threads = 4
innodb_read_io_threads = 4
innodb_thread_concurrency = 0
innodb_purge_threads = 1
innodb_flush_log_at_trx_commit = 2
# Note: Value 2 may lose up to 1 second of data on crash. For production, use 1 for full ACID compliance.
# This default will be adjusted by config_my_cnf_scenario() based on server_scenario setting
innodb_log_buffer_size = 2M
#innodb_redo_log_capacity = 2G
innodb_max_dirty_pages_pct = 75
innodb_lock_wait_timeout = 120

bulk_insert_buffer_size = 8M
myisam_sort_buffer_size = 8M
myisam_max_sort_file_size = 10G

interactive_timeout = 1800
wait_timeout = 1800

[mysqldump]
quick
max_allowed_packet = 32M

[myisamchk]
key_buffer_size = 8M
sort_buffer_size = 8M
read_buffer = 4M
write_buffer = 4M
EOF
}

# Generate my.cnf for MySQL 8.0 (with binlog_format and log_file_size)
# Usage: generate_my_cnf_mysql80 install_dir data_dir
generate_my_cnf_mysql80() {
  local install_dir=$1
  local data_dir=$2
  
  cat > /etc/my.cnf << EOF
[client]
port = 3306
socket = /tmp/mysql.sock
default-character-set = utf8mb4

[mysql]
prompt="MySQL [\\d]> "
no-auto-rehash

[mysqld]
port = 3306
socket = /tmp/mysql.sock
default_authentication_plugin = mysql_native_password

basedir = ${install_dir}
datadir = ${data_dir}
pid-file = ${data_dir}/mysql.pid
user = mysql
bind-address = 127.0.0.1
server-id = 1

init-connect = 'SET NAMES utf8mb4'
character-set-server = utf8mb4
collation-server = utf8mb4_0900_ai_ci

skip-name-resolve
local_infile = 0
#skip-networking
back_log = 150

max_connections = 100
max_connect_errors = 100
open_files_limit = 65535
table_open_cache = 400
max_allowed_packet = 32M
binlog_cache_size = 1M
max_heap_table_size = 16M
tmp_table_size = 16M

read_buffer_size = 128K
read_rnd_buffer_size = 256K
sort_buffer_size = 512K
join_buffer_size = 512K
key_buffer_size = 4M

thread_cache_size = 8

ft_min_word_len = 4

log_bin = mysql-bin
binlog_format = mixed
binlog_expire_logs_seconds = 604800

log_error = ${data_dir}/mysql-error.log
slow_query_log = 1
long_query_time = 1
slow_query_log_file = ${data_dir}/mysql-slow.log

performance_schema = 0
explicit_defaults_for_timestamp

#lower_case_table_names = 1

skip-external-locking

default_storage_engine = InnoDB
#default-storage-engine = MyISAM
innodb_file_per_table = 1
innodb_open_files = 500
innodb_buffer_pool_size = 64M
innodb_write_io_threads = 4
innodb_read_io_threads = 4
innodb_thread_concurrency = 0
innodb_purge_threads = 1
innodb_flush_log_at_trx_commit = 2
# Note: Value 2 may lose up to 1 second of data on crash. For production, use 1 for full ACID compliance.
# This default will be adjusted by config_my_cnf_scenario() based on server_scenario setting
innodb_log_buffer_size = 2M
innodb_log_file_size = 32M
innodb_log_files_in_group = 3
innodb_max_dirty_pages_pct = 75
innodb_lock_wait_timeout = 120

bulk_insert_buffer_size = 8M
myisam_sort_buffer_size = 8M
myisam_max_sort_file_size = 10G

interactive_timeout = 1800
wait_timeout = 1800

[mysqldump]
quick
max_allowed_packet = 32M

[myisamchk]
key_buffer_size = 8M
sort_buffer_size = 8M
read_buffer = 4M
write_buffer = 4M
EOF
}

# Generate my.cnf for MariaDB
# Usage: generate_my_cnf_mariadb install_dir data_dir
generate_my_cnf_mariadb() {
  local install_dir=$1
  local data_dir=$2
  
  cat > /etc/my.cnf << EOF
[client]
port = 3306
socket = /tmp/mysql.sock
default-character-set = utf8mb4

[mysqld]
port = 3306
socket = /tmp/mysql.sock

basedir = ${install_dir}
datadir = ${data_dir}
pid-file = ${data_dir}/mysql.pid
user = mysql
bind-address = 127.0.0.1
server-id = 1

init-connect = 'SET NAMES utf8mb4'
character-set-server = utf8mb4

skip-name-resolve
local_infile = 0
#skip-networking
back_log = 150

max_connections = 100
max_connect_errors = 100
open_files_limit = 65535
table_open_cache = 400
max_allowed_packet = 32M
binlog_cache_size = 1M
max_heap_table_size = 16M
tmp_table_size = 16M

read_buffer_size = 128K
read_rnd_buffer_size = 256K
sort_buffer_size = 512K
join_buffer_size = 512K
key_buffer_size = 4M

thread_cache_size = 8

query_cache_type = 1
query_cache_size = 8M
query_cache_limit = 2M

ft_min_word_len = 4

log_bin = mysql-bin
binlog_format = mixed
expire_logs_days = 7

log_error = ${data_dir}/mysql-error.log
slow_query_log = 1
long_query_time = 1
slow_query_log_file = ${data_dir}/mysql-slow.log

performance_schema = 0

#lower_case_table_names = 1

skip-external-locking

default_storage_engine = InnoDB
innodb_file_per_table = 1
innodb_open_files = 500
innodb_buffer_pool_size = 64M
innodb_write_io_threads = 4
innodb_read_io_threads = 4
innodb_purge_threads = 1
innodb_flush_log_at_trx_commit = 2
# Note: Value 2 may lose up to 1 second of data on crash. For production, use 1 for full ACID compliance.
# This default will be adjusted by config_my_cnf_scenario() based on server_scenario setting
innodb_log_buffer_size = 2M
innodb_log_file_size = 32M
innodb_max_dirty_pages_pct = 75
innodb_lock_wait_timeout = 120

bulk_insert_buffer_size = 8M
myisam_sort_buffer_size = 8M
myisam_max_sort_file_size = 10G

interactive_timeout = 1800
wait_timeout = 1800

[mysqldump]
quick
max_allowed_packet = 32M

[myisamchk]
key_buffer_size = 8M
sort_buffer_size = 8M
read_buffer = 4M
write_buffer = 4M
EOF
}

# Generate my.cnf for MySQL 5.7 (with query_cache like MariaDB)
# Usage: generate_my_cnf_mysql57 install_dir data_dir

# Setup MySQL/MariaDB service
# Usage: setup_db_service install_dir data_dir
setup_db_service() {
  local install_dir=$1
  local data_dir=$2

  # Determine the actual daemon binary (not the safe wrapper)
  # mysqld_safe/mariadbd-safe are shell scripts that don't work well with systemd
  local daemon_cmd="mysqld"
  if [ -x "${install_dir}/bin/mariadbd" ]; then
    daemon_cmd="mariadbd"
  fi

  if has_systemd; then
    # Use systemd service unit
    # Use Type=simple with direct daemon binary (not *_safe wrapper)
    # Type=simple: systemd considers service started when process is forked
    # The daemon drops privileges to mysql user via --user=mysql in my.cnf
    # Our wait_for_db_ready() function handles checking actual readiness
    cat > /lib/systemd/system/mysqld.service << EOF
[Unit]
Description=MySQL/MariaDB Server
After=network.target

[Service]
Type=simple
ExecStart=${install_dir}/bin/${daemon_cmd} --basedir=${install_dir} --datadir=${data_dir} --pid-file=${data_dir}/mysql.pid --user=mysql
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5
TimeoutStartSec=600
TimeoutStopSec=100
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    svc_daemon_reload
    svc_enable mysqld
  else
    # Fallback to SysV init (use mysql.server which includes safe wrapper)
    /bin/cp ${install_dir}/support-files/mysql.server /etc/init.d/mysqld
    sed -i "s@^basedir=.*@basedir=${install_dir}@" /etc/init.d/mysqld
    sed -i "s@^datadir=.*@datadir=${data_dir}@" /etc/init.d/mysqld
    chmod +x /etc/init.d/mysqld
    svc_enable mysqld
  fi
}

# Post-install MySQL/MariaDB setup
# Usage: post_install_db install_dir db_type data_dir
post_install_db() {
  local install_dir=$1
  local db_type=$2  # mysql or mariadb
  local data_dir=$3

  # WSL compatibility
  [[ "${Wsl}" == true ]] && chmod 600 /etc/my.cnf

  # Cleanup conflicting configs
  rm -rf /etc/ld.so.conf.d/{mysql,mariadb}*.conf
  [ -e "${install_dir}/my.cnf" ] && rm -f ${install_dir}/my.cnf

  # Setup library path
  echo "${install_dir}/lib" > /etc/ld.so.conf.d/z-${db_type}.conf
  ldconfig

  # Setup logrotate
  [ -n "${data_dir}" ] && setup_mysql_logrotate "${data_dir}" "${install_dir}"
}