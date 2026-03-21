#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: Common functions for MySQL/MariaDB installation

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
  local root_pwd=$2
  local reset_master=${3:-no}
  
  ${install_dir}/bin/mysql -uroot -hlocalhost -e "create user root@'127.0.0.1' identified by \"${root_pwd}\";"
  ${install_dir}/bin/mysql -uroot -hlocalhost -e "grant all privileges on *.* to root@'127.0.0.1' with grant option;"
  ${install_dir}/bin/mysql -uroot -hlocalhost -e "grant all privileges on *.* to root@'localhost' with grant option;"
  ${install_dir}/bin/mysql -uroot -hlocalhost -e "alter user root@'localhost' identified by \"${root_pwd}\";"
  
  if [[ "${reset_master}" == "yes" ]]; then
    ${install_dir}/bin/mysql -uroot -p${root_pwd} -e "reset master;"
  fi
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
  sed -i 's@executing mysqld_safe@executing mysqld_safe\nexport LD_PRELOAD=/usr/local/lib/libtcmalloc.so@' ${install_dir}/bin/mysqld_safe
  sed -i "s@/usr/local/mysql@${install_dir}@g" ${install_dir}/bin/mysqld_safe
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
  local root_pwd=$2
  local cmd=${3:-mariadb}

  # Use ALTER USER syntax (compatible with MariaDB 10.11+ and 11.x)
  ${install_dir}/bin/${cmd} -e "CREATE USER IF NOT EXISTS root@'127.0.0.1' IDENTIFIED BY \"${root_pwd}\";"
  ${install_dir}/bin/${cmd} -e "GRANT ALL PRIVILEGES ON *.* TO root@'127.0.0.1' WITH GRANT OPTION;"
  ${install_dir}/bin/${cmd} -e "ALTER USER root@'localhost' IDENTIFIED BY \"${root_pwd}\";"
  ${install_dir}/bin/${cmd} -uroot -p${root_pwd} -e "DELETE FROM mysql.user WHERE Password='' AND User NOT LIKE 'mariadb.%';"
  ${install_dir}/bin/${cmd} -uroot -p${root_pwd} -e "DELETE FROM mysql.db WHERE User='';"
  ${install_dir}/bin/${cmd} -uroot -p${root_pwd} -e "DELETE FROM mysql.proxies_priv WHERE Host!='localhost';"
  ${install_dir}/bin/${cmd} -uroot -p${root_pwd} -e "DROP DATABASE IF EXISTS test;"
  ${install_dir}/bin/${cmd} -uroot -p${root_pwd} -e "RESET MASTER;"
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
mysql_native_password = on 

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

  if has_systemd; then
    # Use systemd service unit
    cat > /lib/systemd/system/mysqld.service << EOF
[Unit]
Description=MySQL/MariaDB Server
After=network.target

[Service]
Type=forking
PIDFile=${data_dir}/mysql.pid
ExecStart=${install_dir}/bin/mysqld_safe --basedir=${install_dir} --datadir=${data_dir} --pid-file=${data_dir}/mysql.pid
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    svc_daemon_reload
  else
    # Fallback to SysV init
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