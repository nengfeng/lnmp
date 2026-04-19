#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: Upgrade script for LNMP stack components

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
clear
printf "
#######################################################################
#                    Upgrade Software versions                        #
#######################################################################
"
# Check if user is root
[ "$(id -u)" != "0" ] && { echo "${CFAILURE}Error: You must be root to run this script${CEND}"; exit 1; }

current_dir=$(dirname "$(readlink -f "$0")")
pushd "${current_dir}" > /dev/null
. ./versions.txt
. ./options.conf
. ./include/ip_detect.sh
. ./include/color.sh
. ./include/check_os.sh
. ./include/check_dir.sh
. ./include/download.sh
. ./include/check_download.sh
. ./include/get_char.sh
. ./include/upgrade_web.sh
. ./include/upgrade_db.sh
. ./include/upgrade_php.sh
. ./include/upgrade_redis.sh
. ./include/upgrade_memcached.sh
. ./include/upgrade_phpmyadmin.sh
. ./include/upgrade_script.sh

# get the out ip country
OUTIP_STATE=$(ip_state)

# ============================================
# Helper Functions
# ============================================

# Check if a component is installed
# Usage: check_installed <install_dir> <binary> <name>
check_installed() {
  local dir=$1 bin=$2 name=$3
  if [ ! -e "${dir}/${bin}" ]; then
    echo "${CWARNING}${name} is not installed${CEND}"
    return 1
  fi
  return 0
}

# Validate version format (X.Y.Z)
# Usage: validate_version <version> <name>
validate_version() {
  local ver=$1 name=$2
  if [ -n "${ver}" ] && [[ ! "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${CFAILURE}Invalid version format for ${name}: ${ver} (expected X.Y.Z)${CEND}"
    return 1
  fi
  return 0
}

# Show current versions of installed components
show_versions() {
  echo "${CCYAN}Current Versions:${CEND}"
  [ -e "${nginx_install_dir}/sbin/nginx" ] && echo "  Nginx: $(${nginx_install_dir}/sbin/nginx -v 2>&1 | awk -F/ '{print $2}')"
  [ -e "${tengine_install_dir}/sbin/nginx" ] && echo "  Tengine: $(${tengine_install_dir}/sbin/nginx -v 2>&1 | awk -F/ '{print $2}')"
  [ -e "${openresty_install_dir}/nginx/sbin/nginx" ] && echo "  OpenResty: $(${openresty_install_dir}/nginx/sbin/nginx -v 2>&1 | awk -F/ '{print $2}')"
  [ -e "${php_install_dir}/bin/php" ] && echo "  PHP: $(${php_install_dir}/bin/php -v 2>/dev/null | head -1 | awk '{print $2}')"
  if [ -e "${mysql_install_dir}/bin/mysql" ]; then
    echo "  MySQL: $(${mysql_install_dir}/bin/mysql -V 2>/dev/null | awk '{print $3}')"
  elif [ -e "${mariadb_install_dir}/bin/mysql" ]; then
    echo "  MariaDB: $(${mariadb_install_dir}/bin/mysql -V 2>/dev/null | awk '{print $3}')"
  fi
  [ -e "${redis_install_dir}/bin/redis-server" ] && echo "  Redis: $(${redis_install_dir}/bin/redis-server --version 2>/dev/null | awk -F= '{print $2}' | awk '{print $1}')"
  [ -e "${memcached_install_dir}/bin/memcached" ] && echo "  Memcached: $(${memcached_install_dir}/bin/memcached -V 2>&1 | awk '{print $2}')"
  echo
}

# ============================================
# Upgrade Functions
# ============================================

# Update CA root certificates
Upgrade_Cacert() {
  echo "${CMSG}Updating CA root certificates...${CEND}"
  
  pushd "${current_dir}/src" > /dev/null
  
  # Download latest cacert.pem
  echo "Downloading latest cacert.pem from curl.se..."
  wget -O cacert.pem.new https://curl.se/ca/cacert.pem
  
  if [ -s cacert.pem.new ]; then
    # Backup old file
    [ -f cacert.pem ] && mv cacert.pem cacert.pem.bak
    
    # Use new file
    mv cacert.pem.new cacert.pem
    
    # Update OpenSSL cert if installed
    if [ -d "${openssl_install_dir}" ]; then
      /bin/cp cacert.pem "${openssl_install_dir}/cert.pem"
      echo "${CSUCCESS}Updated ${openssl_install_dir}/cert.pem${CEND}"
    fi
    
    # Update system cert if exists
    if [ -f /etc/pki/tls/certs/ca-bundle.crt ]; then
      /bin/cp cacert.pem /etc/pki/tls/certs/ca-bundle.crt
    fi
    
    echo "${CSUCCESS}CA root certificates updated successfully!${CEND}"
  else
    echo "${CFAILURE}Failed to download cacert.pem${CEND}"
    rm -f cacert.pem.new
  fi
  
  popd > /dev/null
}

# ============================================
# Help & Menu
# ============================================

Show_Help() {
  echo
  echo "Usage: $0  command ...[version]....
  --help, -h                  Show this help message
  --version, -v               Show current component versions
  --nginx        [version]    Upgrade Nginx
  --tengine      [version]    Upgrade Tengine
  --openresty    [version]    Upgrade OpenResty
  --db           [version]    Upgrade MySQL/MariaDB
  --php          [version]    Upgrade PHP
  --redis        [version]    Upgrade Redis
  --memcached    [version]    Upgrade Memcached
  --phpmyadmin   [version]    Upgrade phpMyAdmin
  --script                    Upgrade scripts latest
  --acme.sh                   Upgrade acme.sh latest
  --cacert                    Update CA root certificates
  "
}

# Interactive upgrade menu
# Usage: Menu
# Description: Displays an interactive menu for selecting components to upgrade
Menu() {
  while :; do
    printf "
What Are You Doing?
\t${CMSG} 1${CEND}. Upgrade Nginx/Tengine/OpenResty
\t${CMSG} 2${CEND}. Upgrade MySQL/MariaDB
\t${CMSG} 3${CEND}. Upgrade PHP
\t${CMSG} 4${CEND}. Upgrade Redis
\t${CMSG} 5${CEND}. Upgrade Memcached
\t${CMSG} 6${CEND}. Upgrade phpMyAdmin
\t${CMSG} 7${CEND}. Upgrade scripts latest
\t${CMSG} 8${CEND}. Upgrade acme.sh latest
\t${CMSG} 9${CEND}. Update CA root certificates
\t${CMSG} q${CEND}. Exit
"
    echo
    read -e -p "Please input the correct option: " Upgrade_flag
    if [[ ! "${Upgrade_flag}" =~ ^[1-9,q]$ ]]; then
      echo "${CWARNING}input error! Please only input 1~9 and q${CEND}"
    else
      case "${Upgrade_flag}" in
        1)
          check_installed "${nginx_install_dir}/sbin" "nginx" "Nginx" && Upgrade_Nginx
          check_installed "${tengine_install_dir}/sbin" "nginx" "Tengine" && Upgrade_Tengine
          check_installed "${openresty_install_dir}/nginx/sbin" "nginx" "OpenResty" && Upgrade_OpenResty
          ;;
        2)
          Upgrade_DB
          ;;
        3)
          check_installed "${php_install_dir}/bin" "php" "PHP" && Upgrade_PHP
          ;;
        4)
          check_installed "${redis_install_dir}/bin" "redis-server" "Redis" && Upgrade_Redis
          ;;
        5)
          check_installed "${memcached_install_dir}/bin" "memcached" "Memcached" && Upgrade_Memcached
          ;;
        6)
          Upgrade_phpMyAdmin
          ;;
        7)
          Upgrade_Script
          ;;
        8)
          [ -e "${HOME}/.acme.sh/acme.sh" ] && { "${HOME}/.acme.sh/acme.sh" --force --upgrade; "${HOME}/.acme.sh/acme.sh" --version; }
          ;;
        9)
          Upgrade_Cacert
          ;;
        q)
          exit
          ;;
        *)
          echo "${CWARNING}Invalid option!${CEND}"
          ;;
      esac
    fi
  done
}

# ============================================
# Main
# ============================================

ARG_NUM=$#
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      Show_Help; exit 0
      ;;
    -v|--version)
      show_versions; exit 0
      ;;
    --nginx)
      nginx_flag=y; NEW_nginx_ver=$2; shift 2
      ;;
    --tengine)
      tengine_flag=y; NEW_tengine_ver=$2; shift 2
      ;;
    --openresty)
      openresty_flag=y; NEW_openresty_ver=$2; shift 2
      ;;
    --db)
      db_flag=y; NEW_db_ver=$2; shift 2
      ;;
    --php)
      php_flag=y; NEW_php_ver=$2; shift 2
      ;;
    --redis)
      redis_flag=y; NEW_redis_ver=$2; shift 2
      ;;
    --memcached)
      memcached_flag=y; NEW_memcached_ver=$2; shift 2
      ;;
    --phpmyadmin)
      phpmyadmin_flag=y; NEW_phpmyadmin_ver=$2; shift 2
      ;;
    --script)
      NEW_Script_ver=latest; shift 1
      ;;
    --acme.sh)
      NEW_acme_ver=latest; shift 1
      ;;
    --cacert)
      cacert_flag=y; shift 1
      ;;
    --)
      shift
      ;;
    *)
      echo "${CWARNING}ERROR: unknown argument! ${CEND}" && Show_Help && exit 1
      ;;
  esac
done

# Validate version formats
[ -n "${NEW_nginx_ver}" ] && validate_version "${NEW_nginx_ver}" "Nginx" || exit 1
[ -n "${NEW_tengine_ver}" ] && validate_version "${NEW_tengine_ver}" "Tengine" || exit 1
[ -n "${NEW_openresty_ver}" ] && validate_version "${NEW_openresty_ver}" "OpenResty" || exit 1
[ -n "${NEW_php_ver}" ] && validate_version "${NEW_php_ver}" "PHP" || exit 1
[ -n "${NEW_redis_ver}" ] && validate_version "${NEW_redis_ver}" "Redis" || exit 1
[ -n "${NEW_memcached_ver}" ] && validate_version "${NEW_memcached_ver}" "Memcached" || exit 1

if [[ "${ARG_NUM}" == 0 ]]; then
  Menu
else
  [[ "${nginx_flag}" == "y" ]] && Upgrade_Nginx
  [[ "${tengine_flag}" == "y" ]] && Upgrade_Tengine
  [[ "${openresty_flag}" == "y" ]] && Upgrade_OpenResty
  [[ "${db_flag}" == "y" ]] && Upgrade_DB
  [[ "${php_flag}" == "y" ]] && Upgrade_PHP
  [[ "${redis_flag}" == "y" ]] && Upgrade_Redis
  [[ "${memcached_flag}" == "y" ]] && Upgrade_Memcached
  [[ "${phpmyadmin_flag}" == "y" ]] && Upgrade_phpMyAdmin
  [[ "${NEW_Script_ver}" == "latest" ]] && Upgrade_Script
  [[ "${NEW_acme_ver}" == "latest" ]] && [ -e "${HOME}/.acme.sh/acme.sh" ] && { "${HOME}/.acme.sh/acme.sh" --force --upgrade; "${HOME}/.acme.sh/acme.sh" --version; }
  [[ "${cacert_flag}" == "y" ]] && Upgrade_Cacert
fi
