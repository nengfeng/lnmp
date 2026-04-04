#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: Common functions for LNMP installation scripts

# ============================================
# Mirror Detection (全局镜像源检测)
# ============================================
# Call init_mirror once to set USE_CHINA_MIRROR and mirror_link
# Then use get_mirror_url() or ${mirror_link} for downloads

USE_CHINA_MIRROR="n"
mirror_link="${MIRROR_BASE_URL:-https://mirrors.tuna.tsinghua.edu.cn}"

# Initialize mirror detection (call once at script start)
# Sets USE_CHINA_MIRROR=y if IP is in China
# Usage: init_mirror
init_mirror() {
  local location=""
  
  # Try ip_detect.sh first (if sourced)
  if command -v ip_state >/dev/null 2>&1; then
    location=$(ip_state 2>/dev/null)
  fi
  
  # Fallback: direct detection
  if [ -z "$location" ] || [[ "$location" == "unknown" ]]; then
    if command -v curl >/dev/null 2>&1; then
      location=$(curl -s --connect-timeout 3 --max-time 5 https://ipinfo.io/country 2>/dev/null | grep -oE '^[A-Z]{2}$')
    fi
  fi
  
  if [[ "$location" == "CN" ]]; then
    USE_CHINA_MIRROR="y"
  fi
}

# Get mirror URL (if China, use china_url; otherwise official_url)
# Usage: get_mirror_url "official_url" "china_url" "use_china_flag"
get_mirror_url() {
  local official_url=$1
  local china_url=$2
  local use_china=${3:-$USE_CHINA_MIRROR}
  
  if [[ "$use_china" == "y" ]] && [ -n "$china_url" ]; then
    echo "$china_url"
  else
    echo "$official_url"
  fi
}

# ============================================
# Error Handling Functions
# ============================================

# Clean exit with message
# Usage: die "Error message" [exit_code]
die() {
  local msg=$1
  local code=${2:-1}
  echo "${CFAILURE}${msg}${CEND}" >&2
  exit ${code}
}

# Kill current process (used for critical failures)
# Usage: die_hard "Error message"
die_hard() {
  local msg=$1
  echo "${CFAILURE}${msg}${CEND}" >&2
  kill -9 $$; exit 1
}

# ============================================
# User Input Functions
# ============================================

# Prompt for y/n confirmation
# Usage: confirm "Do you want to continue?" result_var
# Sets result_var to 'y' or 'n'
confirm() {
  local prompt=$1
  local var_name=$2
  local default=${3:-n}
  local value
  
  # Security: Validate var_name contains only valid variable name characters
  if ! [[ "${var_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "${CFAILURE}Invalid variable name${CEND}" >&2
    return 1
  fi
  
  while :; do
    read -e -p "${prompt} [y/n] (default: ${default}): " value
    value=${value:-${default}}
    case "${value}" in
      y|Y|n|N) break ;;
      *) echo "${CWARNING}input error! Please only input 'y' or 'n'${CEND}" ;;
    esac
  done
  # Security: Use declare -g instead of eval for indirect variable assignment
  declare -g "${var_name}=${value}"
}

# Prompt for numeric selection within a range
# Usage: select_number "Choose option" result_var min max default
select_number() {
  local prompt=$1
  local var_name=$2
  local min=$3
  local max=$4
  local default=${5:-$min}
  local value
  
  # Security: Validate var_name contains only valid variable name characters
  if ! [[ "${var_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "${CFAILURE}Invalid variable name${CEND}" >&2
    return 1
  fi
  
  while :; do
    read -e -p "${prompt} [${min}-${max}] (default: ${default}): " value
    value=${value:-${default}}
    if [[ "${value}" =~ ^[0-9]+$ ]] && [ "${value}" -ge "${min}" ] && [ "${value}" -le "${max}" ]; then
      break
    else
      echo "${CWARNING}input error! Please only input number ${min}~${max}${CEND}"
    fi
  done
  # Security: Use declare -g instead of eval for indirect variable assignment
  declare -g "${var_name}=${value}"
}

# Prompt for string input with validation
# Usage: input_string "Enter password" result_var [default_value]
input_string() {
  local prompt=$1
  local var_name=$2
  local default=$3
  local value
  
  # Security: Validate var_name contains only valid variable name characters
  if ! [[ "${var_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "${CFAILURE}Invalid variable name${CEND}" >&2
    return 1
  fi
  
  if [ -n "${default}" ]; then
    read -e -p "${prompt} (Default: ${default}): " value
    value=${value:-${default}}
  else
    read -e -p "${prompt}: " value
  fi
  # Security: Use declare -g instead of eval for indirect variable assignment
  declare -g "${var_name}=${value}"
}

# Prompt for password input with validation
# Usage: input_password "Enter password" result_var default_value min_len
input_password() {
  local prompt=$1
  local var_name=$2
  local default=$3
  local min_len=${4:-5}
  local value

  # Security: Validate var_name
  if ! [[ "${var_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "${CFAILURE}Invalid variable name${CEND}" >&2
    return 1
  fi

  while :; do
    read -e -p "${prompt} (default: ${default}): " value
    value=${value:-${default}}
    # Reject dangerous characters
    if [[ "$value" =~ [+|\&] ]]; then
      echo "${CWARNING}Password cannot contain + or | or & ${CEND}"
      continue
    fi
    if (( ${#value} >= ${min_len} )); then
      break
    else
      echo "${CWARNING}Password must be at least ${min_len} characters! ${CEND}"
    fi
  done
  declare -g "${var_name}=${value}"
}

# Escape password for safe use in config files and SQL
# Usage: escape_password "password"
# Returns escaped password suitable for sed replacement and SQL
escape_password() {
  local pwd="$1"
  echo "${pwd}" | sed 's/\\/\\\\/g; s/'\''/\\'\''/g'
}

# Check if a component is already installed, warn and return 1 if so
# Usage: check_installed <type> <path> <name>
# type: "file" (checks -e) or "dir" (checks -d)
check_installed() {
  local type=$1
  local path=$2
  local name=$3

  if [[ "${type}" == "dir" ]]; then
    [ -d "${path}" ] && { echo "${CWARNING}${name} already installed! ${CEND}"; return 1; }
  else
    [ -e "${path}" ] && { echo "${CWARNING}${name} already installed! ${CEND}"; return 1; }
  fi
  return 0
}

# ============================================
# System Functions
# ============================================

# Add directory to PATH in /etc/profile
# Usage: add_to_path /usr/local/nginx/sbin
add_to_path() {
  local install_dir=$1
  [ -z "$(grep ^'export PATH=' /etc/profile)" ] && echo "export PATH=${install_dir}:\$PATH" >> /etc/profile
  [[ -n "$(grep ^'export PATH=' /etc/profile)" && -z "$(grep ${install_dir} /etc/profile)" ]] && sed -i "s@^export PATH=\(.*\)@export PATH=${install_dir}:\1@" /etc/profile
  . /etc/profile
}

# Create run user and group if not exists
# Usage: create_run_user [username] [groupname]
create_run_user() {
  local user=${1:-${run_user:-www}}
  local group=${2:-${run_group:-www}}
  
  id -g ${group} >/dev/null 2>&1
  [ $? -ne 0 ] && groupadd ${group}
  id -u ${user} >/dev/null 2>&1
  [ $? -ne 0 ] && useradd -g ${group} -M -s /sbin/nologin ${user}
}

# Create mysql user if not exists
create_mysql_user() {
  id -u mysql >/dev/null 2>&1
  [ $? -ne 0 ] && useradd -M -s /sbin/nologin mysql
}

# Setup logrotate for nginx
# Usage: setup_nginx_logrotate /data/wwwlogs
setup_nginx_logrotate() {
  local logdir=$1
  cat > /etc/logrotate.d/nginx << EOF
${logdir}/*nginx.log {
  daily
  rotate 5
  missingok
  dateext
  compress
  notifempty
  sharedscripts
  postrotate
    [ -e /var/run/nginx.pid ] && kill -USR1 \$(cat /var/run/nginx.pid\)
  endscript
}
EOF
}

# Setup logrotate for MySQL/MariaDB
# Usage: setup_mysql_logrotate data_dir install_dir
setup_mysql_logrotate() {
  local datadir=$1
  local installdir=$2
  cat > /etc/logrotate.d/mysql << EOF
${datadir}/*-error.log
${datadir}/*-slow.log
${datadir}/*.log {
  daily
  rotate 7
  missingok
  dateext
  compress
  notifempty
  sharedscripts
  create 640 mysql mysql
  postrotate
    [ -e ${datadir}/mysql.pid ] && kill -USR1 \$(cat ${datadir}/mysql.pid\)
  endscript
}
EOF
}

# Setup logrotate for PHP-FPM
# Usage: setup_php_fpm_logrotate php_install_dir
setup_php_fpm_logrotate() {
  local phpdir=$1
  cat > /etc/logrotate.d/php-fpm << EOF
${phpdir}/log/*.log {
  daily
  rotate 5
  missingok
  dateext
  compress
  notifempty
  sharedscripts
  postrotate
    [ -e /run/php-fpm.pid ] && kill -USR1 \$(cat /run/php-fpm.pid\) 2>/dev/null || \
    [ -e ${phpdir}/var/run/php-fpm.pid ] && kill -USR1 \$(cat ${phpdir}/var/run/php-fpm.pid\) 2>/dev/null || \
    systemctl reload php-fpm 2>/dev/null || true
  endscript
}
EOF
}

# ============================================
# Download Functions
# ============================================

# Download and verify file with MD5
# Usage: download_verify url filename md5sum backup_url
download_verify() {
  local url=$1
  local filename=$2
  local expected_md5=$3
  local backup_url=${4:-}
  local try_count=0
  
  # Security: Use HTTPS with certificate verification
  wget -c ${url}
  
  while [ "$(md5sum ${filename} 2>/dev/null | awk '{print $1}')" != "${expected_md5}" ]; do
    if [ -n "${backup_url}" ] && [ ${try_count} -ge 3 ]; then
      wget -c ${backup_url}/${filename}
    else
      wget -c ${url}
    fi
    let "try_count++"
    [["$(md5sum ${filename} 2>/dev/null | awk '{print $1}')" == "${expected_md5}" || "${try_count}" == 6]] && break || continue
  done
  
  if [[ "${try_count}" == 6 ]]; then
    echo "${CFAILURE}${filename} download failed! ${CEND}"
    return 1
  fi
  return 0
}

# ============================================
# Utility Functions
# ============================================

# Check if command exists
# Usage: command_exists git
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Get memory size in MB
get_memory_size() {
  free -m | awk '/Mem:/ {print $2}'
}

# Get CPU core count
get_cpu_count() {
  grep -c processor /proc/cpuinfo
}

# Check if directory exists and create if not
# Usage: ensure_dir /path/to/directory
ensure_dir() {
  [ ! -d "$1" ] && mkdir -p "$1"
}

# Check if file exists
# Usage: file_exists /path/to/file
file_exists() {
  [ -f "$1" ]
}

# Get file size in bytes
# Usage: get_file_size /path/to/file
get_file_size() {
  stat -c %s "$1" 2>/dev/null || echo 0
}

# ============================================
# Compilation Functions
# ============================================

# Compile and install from source
# Usage: compile_and_install [extra_make_args]
compile_and_install() {
  make -j ${THREAD} ${1:+${1}} && make install
}

# Compile with error handling
# Usage: compile_check [extra_make_args]
compile_check() {
  local log_file="${current_dir}/compile_error.log"
  if ! make -j ${THREAD} ${1:+${1}} 2>&1 | tee "${log_file}"; then
    echo ""
    echo "${CFAILURE}========================================${CEND}"
    echo "${CFAILURE}Compilation failed!${CEND}"
    echo "${CFAILURE}========================================${CEND}"
    echo "Last 20 lines of error log:"
    tail -20 "${log_file}"
    echo ""
    echo "Full error log saved to: ${log_file}"
    die "Please check the error log and fix the issue"
  fi
  rm -f "${log_file}"
}

# ============================================
# Message Functions
# ============================================

# Print success message
# Usage: success_msg "Component name"
success_msg() {
  echo "${CSUCCESS}$1 installed successfully! ${CEND}"
}

# Print failure message and exit
# Usage: fail_msg "Component name"
fail_msg() {
  echo "${CFAILURE}$1 install failed, Please contact the author! ${CEND}"
  die_hard "Installation failed"
}

# Print info message
# Usage: info_msg "Message text"
info_msg() {
  echo "${CMSG}$1${CEND}"
}

# Print warning message
# Usage: warn_msg "Warning text"
warn_msg() {
  echo "${CWARNING}$1${CEND}"
}

# ============================================
# Service Management Functions (Unified Abstraction)
# ============================================
# All service operations go through these functions.
# They auto-detect systemd vs SysV init and use the appropriate backend.
#
# Supported services: nginx, mysqld, php-fpm, postgresql, redis-server,
#                     memcached, pureftpd, fail2ban, ssh, rsyslog
# ============================================

# Check if systemd is available
# Usage: has_systemd
has_systemd() {
  [ -e "/bin/systemctl" ] && [ -d "/run/systemd/system" ]
}

# Core service management function (internal)
# Usage: _svc <action> <service_name> [quiet]
# Returns: 0 on success, non-zero on failure
_svc() {
  local action=$1
  local service=$2
  local quiet=${3:-no}

  if has_systemd; then
    if [[ "${quiet}" == "yes" ]]; then
      systemctl ${action} ${service} 2>/dev/null
    else
      systemctl ${action} ${service}
    fi
  else
    if [[ "${quiet}" == "yes" ]]; then
      service ${service} ${action} 2>/dev/null
    else
      service ${service} ${action}
    fi
  fi
}

# Legacy wrapper - use svc_* functions for new code
# Usage: service_action start|stop|restart|reload|enable|disable service_name
service_action() {
  _svc "$1" "$2" "yes"
}

# Start a service
# Usage: svc_start <service_name> [quiet]
svc_start() {
  local service="$1"
  local quiet="${2:-no}"
  
  _svc start "${service}" "${quiet}"
  local result=$?
  
  # If systemctl start failed (e.g., timeout), check if process is actually running
  # This handles slow-starting services like MySQL/MariaDB on low-resource VPS
  if [ ${result} -ne 0 ]; then
    sleep 2
    if svc_is_active "${service}"; then
      [[ "${quiet}" != "yes" ]] && echo "${CMSG}${service} is running despite startup timeout${CEND}"
      return 0
    fi
  fi
  
  return ${result}
}

# Stop a service
# Usage: svc_stop <service_name> [quiet]
svc_stop() {
  _svc stop "$1" "${2:-yes}"
}

# Restart a service
# Usage: svc_restart <service_name> [quiet]
svc_restart() {
  _svc restart "$1" "${2:-no}"
}

# Reload a service
# Usage: svc_reload <service_name> [quiet]
svc_reload() {
  _svc reload "$1" "${2:-yes}"
}

# Enable a service (start on boot)
# Usage: svc_enable <service_name>
svc_enable() {
  if has_systemd; then
    systemctl enable "$1" 2>/dev/null
  else
    if command -v update-rc.d >/dev/null 2>&1; then
      update-rc.d "$1" defaults 2>/dev/null
    elif command -v chkconfig >/dev/null 2>&1; then
      chkconfig "$1" on 2>/dev/null
    fi
  fi
}

# Disable a service (no start on boot)
# Usage: svc_disable <service_name>
svc_disable() {
  if has_systemd; then
    systemctl disable "$1" 2>/dev/null
  else
    if command -v update-rc.d >/dev/null 2>&1; then
      update-rc.d "$1" remove 2>/dev/null
    elif command -v chkconfig >/dev/null 2>&1; then
      chkconfig "$1" off 2>/dev/null
    fi
  fi
}

# Enable and start a service
# Usage: enable_service <service_name>
enable_service() {
  local service=$1
  svc_enable "${service}"
  svc_start "${service}"
}

# Stop and disable a service
# Usage: disable_service <service_name>
disable_service() {
  local service=$1
  svc_stop "${service}" yes
  svc_disable "${service}"
}

# Check if a service is active/running
# Usage: svc_is_active <service_name>
# Returns: 0 if running, 1 if not
svc_is_active() {
  local service="$1"
  
  if has_systemd; then
    # First check systemd status
    if systemctl is-active --quiet "${service}" 2>/dev/null; then
      return 0
    fi
    
    # Fallback: check if process is actually running
    # This handles cases where systemd timed out but process started
    case "${service}" in
      mysqld|mariadb)
        pgrep -x "mariadbd" >/dev/null 2>&1 || pgrep -x "mysqld" >/dev/null 2>&1
        return $?
        ;;
      php-fpm|php*-fpm)
        pgrep -x "php-fpm" >/dev/null 2>&1
        return $?
        ;;
      nginx)
        pgrep -x "nginx" >/dev/null 2>&1
        return $?
        ;;
      redis-server|redis)
        pgrep -x "redis-server" >/dev/null 2>&1
        return $?
        ;;
      memcached)
        pgrep -x "memcached" >/dev/null 2>&1
        return $?
        ;;
      postgresql)
        pgrep -x "postgres" >/dev/null 2>&1
        return $?
        ;;
      pureftpd|pure-ftpd)
        pgrep -x "pure-ftpd" >/dev/null 2>&1
        return $?
        ;;
      *)
        # Generic fallback
        pgrep -x "${service}" >/dev/null 2>&1 || pgrep -f "${service}" >/dev/null 2>&1
        return $?
        ;;
    esac
  else
    pgrep -x "${service}" >/dev/null 2>&1 || pgrep -f "${service}" >/dev/null 2>&1
  fi
}

# Daemon reload (systemd only, no-op on SysV)
# Usage: svc_daemon_reload
svc_daemon_reload() {
  if has_systemd; then
    systemctl daemon-reload 2>/dev/null
  fi
}

# Restart web server (nginx/php-fpm)
# Usage: restart_web_services
restart_web_services() {
  svc_restart nginx yes
  svc_restart php-fpm yes
}

# Reload web server (nginx/php-fpm)
# Usage: reload_web_services
reload_web_services() {
  svc_reload nginx yes
  svc_reload php-fpm yes
}

# ============================================
# Path and Environment Functions
# ============================================

# Refresh PATH from /etc/profile
# Usage: refresh_path
refresh_path() {
  . /etc/profile
}

# Add library path to ldconfig
# Usage: add_lib_path /path/to/lib
add_lib_path() {
  local lib_path=$1
  [ -z "$(grep ${lib_path} /etc/ld.so.conf.d/*.conf 2>/dev/null)" ] && {
    echo "${lib_path}" > /etc/ld.so.conf.d/${lib_path##*/}.conf
    ldconfig
  }
}

# ============================================
# Cleanup Functions
# ============================================

# Cleanup source directory
# Usage: cleanup_src dir1 dir2 ...
cleanup_src() {
  rm -rf "$@"
}

# Cleanup multiple versioned directories
# Usage: cleanup_versions prefix- version1 version2
cleanup_versions() {
  local prefix=$1
  shift
  for ver in "$@"; do
    rm -rf ${prefix}-${ver}
  done
}

# Improve web directory permissions for enhanced security
# Usage: setup_web_directory_permissions
setup_web_directory_permissions() {
  # Set /data to 755 (keep existing behavior for compatibility)
  [ -d /data ] && chmod 755 /data
  
  # Set more restrictive permissions for web directories
  if [ -d "${wwwroot_dir}" ]; then
    # Web root: 750 (owner: rwx, group: r-x, others: none)
    # This prevents other users from accessing web files
    chmod 750 ${wwwroot_dir}
    chown ${run_user}:${run_group} ${wwwroot_dir}
    
    # Ensure subdirectories have appropriate permissions
    find ${wwwroot_dir} -type d -exec chmod 750 {} \; 2>/dev/null
    find ${wwwroot_dir} -type f -exec chmod 640 {} \; 2>/dev/null
    
    # Special case for default directory (may need 755 for nginx access)
    if [ -d "${wwwroot_dir}/default" ]; then
      chmod 755 ${wwwroot_dir}/default
      chown ${run_user}:${run_group} ${wwwroot_dir}/default
    fi
  fi
  
  if [ -d "${wwwlogs_dir}" ]; then
    # Log directory: 755 (needs execute permission for nginx/php-fpm)
    chmod 755 ${wwwlogs_dir}
    chown ${run_user}:${run_group} ${wwwlogs_dir}
    
    # Ensure log files have appropriate permissions
    find ${wwwlogs_dir} -type f -exec chmod 644 {} \; 2>/dev/null
  fi
  
  echo "${CMSG}Enhanced web directory permissions configured${CEND}"
}

# ============================================
# System Resource and Dependency Checks
# ============================================

# Check system resources before compilation
# Usage: check_system_resources
# Set SKIP_RESOURCE_CHECK=1 to bypass checks
check_system_resources() {
  echo "${CMSG}Checking system resources...${CEND}"
  
  # Check memory
  local mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
  local mem_mb=$((mem_kb / 1024))
  local mem_gb=$((mem_mb / 1024))
  
  echo "Memory: ${mem_gb}GB (${mem_mb}MB)"
  
  if [ $mem_mb -lt 1024 ]; then
    echo "${CWARNING}Warning: Less than 1GB RAM detected. Compilation may fail.${CEND}"
    echo "${CWARNING}Recommended: At least 2GB RAM for stable compilation.${CEND}"
    if [[ "${SKIP_RESOURCE_CHECK}" != "1" ]]; then
      confirm "Continue anyway?" continue_low_mem "n"
      [[ "$continue_low_mem" != "y" ]] && exit 1
    fi
  elif [ $mem_mb -lt 2048 ]; then
    echo "${CWARNING}Warning: Less than 2GB RAM. Consider adding swap space.${CEND}"
  fi
  
  # Check disk space
  local available_kb=$(df . 2>/dev/null | tail -1 | awk '{print $4}')
  local available_mb=$((available_kb / 1024))
  local available_gb=$((available_mb / 1024))
  
  echo "Available disk space: ${available_gb}GB (${available_mb}MB)"
  
  if [ $available_mb -lt 5120 ]; then
    echo "${CWARNING}Warning: Less than 5GB free disk space.${CEND}"
    echo "${CWARNING}Recommended: At least 10GB for compilation cache.${CEND}"
    if [[ "${SKIP_RESOURCE_CHECK}" != "1" ]]; then
      confirm "Continue anyway?" continue_low_space "n"
      [[ "$continue_low_space" != "y" ]] && exit 1
    fi
  elif [ $available_mb -lt 10240 ]; then
    echo "${CWARNING}Warning: Less than 10GB free disk space.${CEND}"
  fi
  
  echo "${CSUCCESS}System resource check passed${CEND}"
}

# Check compilation dependencies
# Usage: check_compilation_dependencies
check_compilation_dependencies() {
  echo "${CMSG}Checking compilation dependencies...${CEND}"
  
  local missing_deps=()
  
  # Check essential compilation tools
  if ! command -v gcc >/dev/null 2>&1; then
    missing_deps+=("gcc")
  fi
  
  if ! command -v make >/dev/null 2>&1; then
    missing_deps+=("make")
  fi
  
  # Check for cmake (needed for MySQL/MariaDB)
  if ! command -v cmake >/dev/null 2>&1; then
    missing_deps+=("cmake")
  fi
  
  # Check for wget/curl
  if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    missing_deps+=("wget or curl")
  fi
  
  if [ ${#missing_deps[@]} -gt 0 ]; then
    echo "${CFAILURE}Missing compilation dependencies:${CEND}"
    for dep in "${missing_deps[@]}"; do
      echo "  - $dep"
    done
    echo ""
    echo "Install with:"
    echo "  apt-get install -y gcc make cmake wget curl"
    exit 1
  fi
  
  echo "${CSUCCESS}Compilation dependencies check passed${CEND}"
}

# Compile with timeout and progress monitoring
# Usage: compile_with_progress [timeout_seconds] [extra_make_args]
compile_with_progress() {
  local timeout=${1:-3600}  # Default 1 hour
  local extra_args=${2:-}
  local log_file="${current_dir:-.}/compile_$(date +%Y%m%d_%H%M%S).log"
  
  echo "${CMSG}Starting compilation (timeout: ${timeout}s)...${CEND}"
  echo "Log file: ${log_file}"
  
  # Start compilation with timeout
  local exit_status=0
  if command -v timeout >/dev/null 2>&1; then
    # Use timeout command if available
    timeout ${timeout} make -j ${THREAD} ${extra_args} 2>&1 | tee "${log_file}"
    exit_status=${PIPESTATUS[0]}
  else
    # Fallback without timeout
    make -j ${THREAD} ${extra_args} 2>&1 | tee "${log_file}"
    exit_status=${PIPESTATUS[0]}
  fi
  
  if [ $exit_status -eq 0 ]; then
    echo "${CSUCCESS}Compilation successful${CEND}"
    make install 2>&1 | tee -a "${log_file}"
    return $?
  else
    echo "${CFAILURE}Compilation failed${CEND}"
    echo "Last 30 lines of log:"
    tail -30 "${log_file}"
    return 1
  fi
}
