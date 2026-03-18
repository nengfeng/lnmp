#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
#

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
clear
printf "
#######################################################################
#                              Install                                #
#######################################################################
"
# Check if user is root
[ "$(id -u)" != "0" ] && { echo "${CFAILURE}Error: You must be root to run this script${CEND}"; exit 1; }

current_dir=$(dirname "$(readlink -f "$0")")
pushd ${current_dir} > /dev/null
. ./versions.txt
. ./options.conf
. ./include/color.sh
. ./include/common.sh
. ./include/ip_detect.sh
. ./include/check_os.sh
. ./include/check_dir.sh
. ./include/download.sh
. ./include/get_char.sh
. ./include/ext-common.sh

dbrootpwd=$(< /dev/urandom tr -dc A-Za-z0-9 | head -c16)
dbpostgrespwd=$(< /dev/urandom tr -dc A-Za-z0-9 | head -c16)
dbinstallmethod=1

version() {
  echo "version: 1.1"
  echo "updated date: 2026-03-16"
}

Show_Help() {
  version
  echo "Usage: $0  command ...[parameters]....
  --version, -v               Show version info
  --nginx_option [1-3]        Install Nginx server version
  --php_option [1-3]         Install PHP version
  --mphp_ver [83~85]          Install another PHP version (PATH: ${php_install_dir}\${mphp_ver})
  --mphp_addons               Only install another PHP addons
  --phpcache_option [1-2]     Install PHP opcode cache, default: 1 opcache
  --php_extensions [ext name] Install PHP extensions, include ioncube,
                              imagick,gmagick,fileinfo,imap,ldap,phalcon,
                              yaf,redis,memcached,memcache,mongodb,swoole,xdebug
  --nodejs                    Install Nodejs
  --db_option [1-6]           Install DB version
  --dbinstallmethod [1-2]     DB install method, default: 1 binary install
  --dbrootpwd [password]      DB super password
  --pureftpd                  Install Pure-Ftpd
  --redis                     Install Redis
  --memcached                 Install Memcached
  --phpmyadmin                Install phpMyAdmin
  --ssh_port [No.]            SSH port
  --firewall                  Enable firewall
  --md5sum                    Check md5sum
  --reboot                    Restart the server after installation
  "
}
ARG_NUM=$#

# Parse PHP extension names from comma/space-separated string
# Usage: parse_php_extensions "imagick,redis,swoole"
parse_php_extensions() {
  local exts=$1
  [ -n "$(echo ${exts} | grep -w ioncube)" ] && pecl_ioncube=1
  [ -n "$(echo ${exts} | grep -w imagick)" ] && pecl_imagick=1
  [ -n "$(echo ${exts} | grep -w gmagick)" ] && pecl_gmagick=1
  [ -n "$(echo ${exts} | grep -w fileinfo)" ] && pecl_fileinfo=1
  [ -n "$(echo ${exts} | grep -w imap)" ] && pecl_imap=1
  [ -n "$(echo ${exts} | grep -w ldap)" ] && pecl_ldap=1
  [ -n "$(echo ${exts} | grep -w phalcon)" ] && pecl_phalcon=1
  [ -n "$(echo ${exts} | grep -w yaf)" ] && pecl_yaf=1
  [ -n "$(echo ${exts} | grep -w redis)" ] && pecl_redis=1
  [ -n "$(echo ${exts} | grep -w memcached)" ] && pecl_memcached=1
  [ -n "$(echo ${exts} | grep -w memcache)" ] && pecl_memcache=1
  [ -n "$(echo ${exts} | grep -w mongodb)" ] && pecl_mongodb=1
  [ -n "$(echo ${exts} | grep -w swoole)" ] && pecl_swoole=1
  [ -n "$(echo ${exts} | grep -w xdebug)" ] && pecl_xdebug=1
}

# Set PHP extension flags from number list
# Usage: set_php_ext_from_numbers "2 9 10"
set_php_ext_from_numbers() {
  local nums=$1
  [ -n "$(echo ${nums} | grep -w 1)" ]  && pecl_ioncube=1
  [ -n "$(echo ${nums} | grep -w 2)" ]  && pecl_imagick=1
  [ -n "$(echo ${nums} | grep -w 3)" ]  && pecl_gmagick=1
  [ -n "$(echo ${nums} | grep -w 4)" ]  && pecl_fileinfo=1
  [ -n "$(echo ${nums} | grep -w 5)" ]  && pecl_imap=1
  [ -n "$(echo ${nums} | grep -w 6)" ]  && pecl_ldap=1
  [ -n "$(echo ${nums} | grep -w 7)" ]  && pecl_phalcon=1
  [ -n "$(echo ${nums} | grep -w 8)" ]  && pecl_yaf=1
  [ -n "$(echo ${nums} | grep -w 9)" ]  && pecl_redis=1
  [ -n "$(echo ${nums} | grep -w 10)" ] && pecl_memcached=1
  [ -n "$(echo ${nums} | grep -w 11)" ] && pecl_memcache=1
  [ -n "$(echo ${nums} | grep -w 12)" ] && pecl_mongodb=1
  [ -n "$(echo ${nums} | grep -w 13)" ] && pecl_swoole=1
  [ -n "$(echo ${nums} | grep -w 14)" ] && pecl_xdebug=1
}

# Parse command-line arguments (pure bash, no eval)
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        Show_Help; exit 0
        ;;
      -v|-V|--version)
        version; exit 0
        ;;
      --nginx_option)
        nginx_option=$2; shift 2
        [[ ! ${nginx_option} =~ ^[1-3]$ ]] && { echo "${CWARNING}nginx_option input error! Please only input number 1~3${CEND}"; exit 1; }
        [ -e "${nginx_install_dir}/sbin/nginx" ] && { echo "${CWARNING}Nginx already installed! ${CEND}"; unset nginx_option; }
        [ -e "${tengine_install_dir}/sbin/nginx" ] && { echo "${CWARNING}Tengine already installed! ${CEND}"; unset nginx_option; }
        [ -e "${openresty_install_dir}/nginx/sbin/nginx" ] && { echo "${CWARNING}OpenResty already installed! ${CEND}"; unset nginx_option; }
        ;;
      --php_option)
        php_option=$2; shift 2
        [[ ! ${php_option} =~ ^[1-3]$ ]] && { echo "${CWARNING}php_option input error! Please only input number 1~3${CEND}"; exit 1; }
        [ -e "${php_install_dir}/bin/phpize" ] && { echo "${CWARNING}PHP already installed! ${CEND}"; unset php_option; }
        ;;
      --mphp_ver)
        mphp_ver=$2; mphp_flag=y; shift 2
        [[ ! "${mphp_ver}" =~ ^8[3-5]$ ]] && { echo "${CWARNING}mphp_ver input error! Please only input number 83~85${CEND}"; exit 1; }
        ;;
      --mphp_addons)
        mphp_addons_flag=y; shift 1
        ;;
      --phpcache_option)
        phpcache_option=$2; shift 2
        ;;
      --php_extensions)
        php_extensions=$2; shift 2
        parse_php_extensions "${php_extensions}"
        ;;
      --nodejs)
        nodejs_flag=y; shift 1
        [ -e "${nodejs_install_dir}/bin/node" ] && { echo "${CWARNING}Nodejs already installed! ${CEND}"; unset nodejs_flag; }
        ;;
      --db_option)
        db_option=$2; shift 2
        if [[ "${db_option}" =~ ^[1-6]$ ]]; then
          if [[ "${db_option}" == 6 ]]; then
            [ -e "${pgsql_install_dir}/bin/psql" ] && { echo "${CWARNING}PostgreSQL already installed! ${CEND}"; unset db_option; }
          else
            [ -d "${db_install_dir}/support-files" ] && { echo "${CWARNING}MySQL already installed! ${CEND}"; unset db_option; }
          fi
        else
          echo "${CWARNING}db_option input error! Please only input number 1~6${CEND}"
          exit 1
        fi
        ;;
      --dbrootpwd)
        dbrootpwd=$2; dbpostgrespwd="${dbrootpwd}"; shift 2
        ;;
      --dbinstallmethod)
        dbinstallmethod=$2; shift 2
        [[ ! ${dbinstallmethod} =~ ^[1-2]$ ]] && { echo "${CWARNING}dbinstallmethod input error! Please only input number 1~2${CEND}"; exit 1; }
        ;;
      --pureftpd)
        pureftpd_flag=y; shift 1
        [ -e "${pureftpd_install_dir}/sbin/pure-ftpwho" ] && { echo "${CWARNING}Pure-FTPd already installed! ${CEND}"; unset pureftpd_flag; }
        ;;
      --redis)
        redis_flag=y; shift 1
        [ -e "${redis_install_dir}/bin/redis-server" ] && { echo "${CWARNING}redis-server already installed! ${CEND}"; unset redis_flag; }
        ;;
      --memcached)
        memcached_flag=y; shift 1
        [ -e "${memcached_install_dir}/bin/memcached" ] && { echo "${CWARNING}memcached-server already installed! ${CEND}"; unset memcached_flag; }
        ;;
      --phpmyadmin)
        phpmyadmin_flag=y; shift 1
        [ -d "${wwwroot_dir}/default/phpMyAdmin" ] && { echo "${CWARNING}phpMyAdmin already installed! ${CEND}"; unset phpmyadmin_flag; }
        ;;
      --ssh_port)
        ssh_port=$2; shift 2
        ;;
      --firewall)
        firewall_flag=y; shift 1
        ;;
      --md5sum)
        md5sum_flag=y; shift 1
        ;;
      --reboot)
        reboot_flag=y; shift 1
        ;;
      --)
        shift
        ;;
      *)
        echo "${CWARNING}ERROR: unknown argument: $1 ${CEND}" && Show_Help && exit 1
        ;;
    esac
  done
}

parse_args "$@"

# Check md5sum (only for tarball installations)
[ -e "${current_dir}.tar.gz" ] && tool_file=${current_dir}.tar.gz
[ -e "${current_dir}-full.tar.gz" ] && tool_file=${current_dir}-full.tar.gz
if [[ ${ARG_NUM} == 0 ]] && [ ! -e ~/.lnmp ] && [ -n "${tool_file}" ]; then
  confirm "Do you want to check md5sum?" md5sum_flag n
fi
if [[ "${md5sum_flag}" == y ]] && [ -n "${tool_file}" ]; then
  script_md5=${tool_file##*/}
  if [ -e "${tool_file}" ]; then
    now_script_md5=$(md5sum ${tool_file} | awk '{print $1}')
    latest_script_md5=$(curl --connect-timeout 3 -m 5 -s "https://raw.githubusercontent.com/nengfeng/lnmp/main/md5sum.txt" | grep ${script_md5} | awk '{print $1}')
    if [ "${now_script_md5}" != "${latest_script_md5}" ]; then
      echo "${CFAILURE}Error: The md5 value of the installation package does not match the official website, please download again, url: https://github.com/nengfeng/lnmp${CEND}"
      exit 1
    fi
  else
    echo "${CFAILURE}Error: ${tool_file} does not exist${CEND}"
    exit 1
  fi
fi

# Use default SSH port 22. If you use another SSH port on your server
if [ -e "/etc/ssh/sshd_config" ]; then
  [ -z "$(grep ^Port /etc/ssh/sshd_config)" ] && now_ssh_port=22 || now_ssh_port=$(grep ^Port /etc/ssh/sshd_config | awk '{print $2}' | head -1)
  if [[ ${ARG_NUM} == 0 ]]; then
    input_string "Please input SSH port" ssh_port "${now_ssh_port}"
  fi
  ssh_port=${ssh_port:-${now_ssh_port}}
  if [[ "${ssh_port}" == "22" || ("${ssh_port}" -gt 1024 && "${ssh_port}" -lt 65535) ]] 2>/dev/null; then
    :
  else
    echo "${CWARNING}input error! Input range: 22,1025~65534${CEND}"
    exit 1
  fi

  if [[ -z "$(grep ^Port /etc/ssh/sshd_config)" && "${ssh_port}" != '22' ]]; then
    sed -i "s@^#Port.*@&\nPort ${ssh_port}@" /etc/ssh/sshd_config
  elif [ -n "$(grep ^Port /etc/ssh/sshd_config)" ]; then
    sed -i "s@^Port.*@Port ${ssh_port}@" /etc/ssh/sshd_config
  fi
fi

if [[ ${ARG_NUM} == 0 ]]; then
  if [ ! -e ~/.lnmp ]; then
    confirm "Do you want to enable firewall?" firewall_flag n
  fi

  # Web server
  confirm "Do you want to install Web server?" web_flag n
  if [[ "${web_flag}" == y ]]; then
    echo 'Please select Nginx server:'
    printf "%b" "	${CMSG}1${CEND}. Install Nginx\n"
    printf "%b" "	${CMSG}2${CEND}. Install Tengine\n"
    printf "%b" "	${CMSG}3${CEND}. Install OpenResty\n"
    printf "%b" "	${CMSG}4${CEND}. Do not install\n"
    select_number "Please input a number" nginx_option 1 4 1
    if [ "${nginx_option}" != '4' ]; then
      check_installed file "${nginx_install_dir}/sbin/nginx" "Nginx" || unset nginx_option
      check_installed file "${tengine_install_dir}/sbin/nginx" "Tengine" || unset nginx_option
      check_installed file "${openresty_install_dir}/nginx/sbin/nginx" "OpenResty" || unset nginx_option
    fi
  fi

  # Database
  confirm "Do you want to install Database?" db_flag n
  if [[ "${db_flag}" == y ]]; then
    echo 'Please select a version of the Database:'
    printf "%b" "	${CMSG}1${CEND}. Install MySQL-8.4\n"
    printf "%b" "	${CMSG}2${CEND}. Install MySQL-8.0\n"
    printf "%b" "	${CMSG}3${CEND}. Install MariaDB-11.8\n"
    printf "%b" "	${CMSG}4${CEND}. Install MariaDB-11.4\n"
    printf "%b" "	${CMSG}5${CEND}. Install MariaDB-10.11\n"
    printf "%b" "	${CMSG}6${CEND}. Install PostgreSQL\n"
    select_number "Please input a number" db_option 1 6 1

    if [[ "${db_option}" == 6 ]]; then
      check_installed file "${pgsql_install_dir}/bin/psql" "PostgreSQL" || unset db_option
    else
      check_installed dir "${db_install_dir}/support-files" "MySQL/MariaDB" || unset db_option
    fi

    if [ -n "${db_option}" ]; then
      # DB password
      if [[ "${db_option}" == 6 ]]; then
        input_password "Please input the postgres password" dbpwd "${dbpostgrespwd}" 5
        dbpostgrespwd=${dbpwd}
      else
        input_password "Please input the root password of MySQL" dbpwd "${dbrootpwd}" 5
        dbrootpwd=${dbpwd}
      fi

      # Install method (MySQL/MariaDB only)
      if [[ "${db_option}" =~ ^[1-5]$ ]]; then
        echo "Please choose installation of the database:"
        printf "%b" "	${CMSG}1${CEND}. Install database from binary package.\n"
        printf "%b" "	${CMSG}2${CEND}. Install database from source package.\n"
        select_number "Please input a number" dbinstallmethod 1 2 1

        echo "Please select server scenario for database tuning:"
        printf "%b" "	${CMSG}1${CEND}. VPS (Resource-limited virtual server)\n"
        printf "%b" "	${CMSG}2${CEND}. Dedicated Server (Resource-abundant dedicated server)\n"
        select_number "Please input a number" scenario_option 1 2 1
        if [[ "${scenario_option}" == 1 ]]; then
          server_scenario='vps'
        else
          server_scenario='dedicated'
        fi
        sed -i "s@^server_scenario=.*@server_scenario=${server_scenario}@" ./options.conf
      fi

      # PostgreSQL version
      if [[ "${db_option}" == 6 ]]; then
        echo 'Please select a version of the PostgreSQL:'
        printf "%b" "	${CMSG}1${CEND}. Install PostgreSQL-18\n"
        printf "%b" "	${CMSG}2${CEND}. Install PostgreSQL-17\n"
        printf "%b" "	${CMSG}3${CEND}. Install PostgreSQL-16\n"
        select_number "Please input a number" pgsql_option 1 3 1
        case "${pgsql_option}" in
          1) pgsql_ver=${pgsql18_ver} ;;
          2) pgsql_ver=${pgsql17_ver} ;;
          3) pgsql_ver=${pgsql16_ver} ;;
        esac

        echo "Please choose installation of PostgreSQL:"
        printf "%b" "	${CMSG}1${CEND}. Install from APT repository (Recommended).\n"
        printf "%b" "	${CMSG}2${CEND}. Install from source compilation.\n"
        select_number "Please input a number" pgsqlinstallmethod 1 2 1
      fi
    fi
  fi

  # PHP
  confirm "Do you want to install PHP?" php_flag n
  if [[ "${php_flag}" == y ]]; then
    check_installed file "${php_install_dir}/bin/phpize" "PHP" || unset php_option
    if [ -z "${php_option}" ] && [ ! -e "${php_install_dir}/bin/phpize" ]; then
      echo 'Please select a version of the PHP:'
      printf "%b" "	${CMSG}1${CEND}. Install php-8.3\n"
      printf "%b" "	${CMSG}2${CEND}. Install php-8.4\n"
      printf "%b" "	${CMSG}3${CEND}. Install php-8.5\n"
      select_number "Please input a number" php_option 1 3 2
    fi
  fi

  # PHP opcode cache and extensions
  if [[ ${php_option} =~ ^[1-3]$ ]] || [ -e "${php_install_dir}/bin/phpize" ]; then
    confirm "Do you want to install opcode cache of the PHP?" phpcache_flag n
    if [[ "${phpcache_flag}" == y ]]; then
      echo 'Please select a opcode cache of the PHP:'
      printf "%b" "	${CMSG}1${CEND}. Install Zend OPcache\n"
      printf "%b" "	${CMSG}2${CEND}. Install APCU\n"
      select_number "Please input a number" phpcache_option 1 2 1
    fi

    # PHP extensions
    echo
    echo 'Please select PHP extensions:'
    printf "%b" "	${CMSG} 0${CEND}. Do not install\n"
    printf "%b" "	${CMSG} 1${CEND}. Install ioncube\n"
    printf "%b" "	${CMSG} 2${CEND}. Install imagick\n"
    printf "%b" "	${CMSG} 3${CEND}. Install gmagick\n"
    printf "%b" "	${CMSG} 4${CEND}. Install fileinfo\n"
    printf "%b" "	${CMSG} 5${CEND}. Install imap\n"
    printf "%b" "	${CMSG} 6${CEND}. Install ldap\n"
    printf "%b" "	${CMSG} 7${CEND}. Install phalcon\n"
    printf "%b" "	${CMSG} 8${CEND}. Install yaf\n"
    printf "%b" "	${CMSG} 9${CEND}. Install redis\n"
    printf "%b" "	${CMSG}10${CEND}. Install memcached\n"
    printf "%b" "	${CMSG}11${CEND}. Install memcache\n"
    printf "%b" "	${CMSG}12${CEND}. Install mongodb\n"
    printf "%b" "	${CMSG}13${CEND}. Install swoole\n"
    printf "%b" "	${CMSG}14${CEND}. Install xdebug\n"
    read -e -p "Please input numbers (Default '2 9 10', space-separated): " phpext_option
    phpext_option=${phpext_option:-'2 9 10'}
    if [ "${phpext_option}" != '0' ]; then
      set_php_ext_from_numbers "${phpext_option}"
    fi
  fi

  # Optional components
  confirm "Do you want to install Nodejs?" nodejs_flag n
  [[ "${nodejs_flag}" == y ]] && check_installed file "${nodejs_install_dir}/bin/node" "Nodejs" || unset nodejs_flag

  confirm "Do you want to install Pure-FTPd?" pureftpd_flag n
  [[ "${pureftpd_flag}" == y ]] && check_installed file "${pureftpd_install_dir}/sbin/pure-ftpwho" "Pure-FTPd" || unset pureftpd_flag

  if [[ ${php_option} =~ ^[1-3]$ ]] || [ -e "${php_install_dir}/bin/phpize" ]; then
    confirm "Do you want to install phpMyAdmin?" phpmyadmin_flag n
    [[ "${phpmyadmin_flag}" == y ]] && check_installed dir "${wwwroot_dir}/default/phpMyAdmin" "phpMyAdmin" || unset phpmyadmin_flag
  fi

  confirm "Do you want to install redis-server?" redis_flag n
  [[ "${redis_flag}" == y ]] && check_installed file "${redis_install_dir}/bin/redis-server" "redis-server" || unset redis_flag

  confirm "Do you want to install memcached-server?" memcached_flag n
  [[ "${memcached_flag}" == y ]] && check_installed file "${memcached_install_dir}/bin/memcached" "memcached" || unset memcached_flag
fi

if [[ ${nginx_option} =~ ^[1-3]$ ]]; then
  [ ! -d ${wwwroot_dir}/default ] && mkdir -p ${wwwroot_dir}/default
  [ ! -d ${wwwlogs_dir} ] && mkdir -p ${wwwlogs_dir}
fi
[ -d /data ] && chmod 750 /data

# install wget gcc curl
if [ ! -e ~/.lnmp ]; then
  downloadDepsSrc=1
  apt-get -y update > /dev/null
  apt-get -y install wget gcc curl > /dev/null
fi

# get the IP information
IPADDR=$(ip_local)
OUTIP_STATE=$(ip_state)

# openSSL
. ./include/openssl.sh

# Check download source packages
. ./include/check_download.sh

[[ "${armplatform}" == "y" ]] && dbinstallmethod=2
checkDownload 2>&1 | tee -a ${current_dir}/install.log

# get OS Memory
. ./include/memory.sh

if [ ! -e ~/.lnmp ]; then
  # Check binary dependencies packages
  . ./include/check_sw.sh
  case "${Family}" in
    "debian")
      installDepsDebian 2>&1 | tee ${current_dir}/install.log
      . include/init_Debian.sh 2>&1 | tee -a ${current_dir}/install.log
      ;;
    "ubuntu")
      installDepsUbuntu 2>&1 | tee ${current_dir}/install.log
      . include/init_Ubuntu.sh 2>&1 | tee -a ${current_dir}/install.log
      ;;
  esac
  # Install dependencies from source package
  installDepsBySrc 2>&1 | tee -a ${current_dir}/install.log
fi

# start Time
startTime=$(date +%s)

# openSSL
Install_openSSL | tee -a ${current_dir}/install.log

# tcmalloc (gperftools)
if [[ ${nginx_option} =~ ^[1-3]$ ]] || [[ "${db_option}" =~ ^[1-6]$ ]]; then
  . include/tcmalloc.sh
  Install_Tcmalloc | tee -a ${current_dir}/install.log
fi

# Database
case "${db_option}" in
  1)
    . include/mysql-8.4.sh
    Install_MySQL84 2>&1 | tee -a ${current_dir}/install.log
    ;;
  2)
    . include/mysql-8.0.sh
    Install_MySQL80 2>&1 | tee -a ${current_dir}/install.log
    ;;
  3)
    . include/mariadb-11.8.sh
    Install_MariaDB118 2>&1 | tee -a ${current_dir}/install.log
    ;;
  4)
    . include/mariadb-11.4.sh
    Install_MariaDB114 2>&1 | tee -a ${current_dir}/install.log
    ;;
  5)
    . include/mariadb-10.11.sh
    Install_MariaDB1011 2>&1 | tee -a ${current_dir}/install.log
    ;;
  6)
    . include/postgresql.sh
    Install_PostgreSQL 2>&1 | tee -a ${current_dir}/install.log
    ;;
esac

# PHP
case "${php_option}" in
  1)
    . include/php-8.3.sh
    Install_PHP83 2>&1 | tee -a ${current_dir}/install.log
    ;;
  2)
    . include/php-8.4.sh
    Install_PHP84 2>&1 | tee -a ${current_dir}/install.log
    ;;
  3)
    . include/php-8.5.sh
    Install_PHP85 2>&1 | tee -a ${current_dir}/install.log
    ;;
esac

PHP_addons() {
  # PHP opcode cache
  case "${phpcache_option}" in
    1)
      . include/zendopcache.sh
      Install_ZendOPcache 2>&1 | tee -a ${current_dir}/install.log
      ;;
    2)
      . include/apcu.sh
      Install_APCU 2>&1 | tee -a ${current_dir}/install.log
      ;;
  esac

  # Install all enabled PHP extensions (unified)
  install_enabled_exts

  # pecl_pgsql (special case: depends on PostgreSQL being installed)
  if [ -e "${pgsql_install_dir}/bin/psql" ]; then
    . include/pecl_pgsql.sh
    Install_pecl_pgsql 2>&1 | tee -a ${current_dir}/install.log
  fi
}

[ "${mphp_addons_flag}" != 'y' ] && PHP_addons

if [[ "${mphp_flag}" == y ]]; then
  . include/mphp.sh
  Install_MPHP 2>&1 | tee -a ${current_dir}/install.log
  php_install_dir=${php_install_dir}${mphp_ver}
  PHP_addons
fi

# Nginx server
case "${nginx_option}" in
  1)
    . include/nginx.sh
    Install_Nginx 2>&1 | tee -a ${current_dir}/install.log
    ;;
  2)
    . include/tengine.sh
    Install_Tengine 2>&1 | tee -a ${current_dir}/install.log
    ;;
  3)
    . include/openresty.sh
    Install_OpenResty 2>&1 | tee -a ${current_dir}/install.log
    ;;
esac

# Nodejs
if [[ "${nodejs_flag}" == y ]]; then
  . include/nodejs.sh
  Install_Nodejs 2>&1 | tee -a ${current_dir}/install.log
fi

# Pure-FTPd
if [[ "${pureftpd_flag}" == y ]]; then
  . include/pureftpd.sh
  Install_PureFTPd 2>&1 | tee -a ${current_dir}/install.log
fi

# phpMyAdmin
if [[ "${phpmyadmin_flag}" == y ]]; then
  . include/phpmyadmin.sh
  Install_phpMyAdmin 2>&1 | tee -a ${current_dir}/install.log
fi

# redis
if [[ "${redis_flag}" == y ]]; then
  . include/redis.sh
  Install_redis_server 2>&1 | tee -a ${current_dir}/install.log
fi

# memcached
if [[ "${memcached_flag}" == y ]]; then
  . include/memcached.sh
  Install_memcached_server 2>&1 | tee -a ${current_dir}/install.log
fi

# index example
if [ -d "${wwwroot_dir}/default" ]; then
  . include/demo.sh
  DEMO 2>&1 | tee -a ${current_dir}/install.log
fi

# get web_install_dir and db_install_dir
. include/check_dir.sh

# Starting DB
[ -d "/etc/mysql" ] && /bin/mv /etc/mysql{,_bk}
[ -d "${db_install_dir}/support-files" ] && ! svc_is_active mysqld && svc_start mysqld

# reload php
[ -e "${php_install_dir}/sbin/php-fpm" ] && svc_reload php-fpm yes
[[ -n "${mphp_ver}" && -e "${php_install_dir}${mphp_ver}/sbin/php-fpm" ]] && svc_reload php${mphp_ver}-fpm yes

endTime=$(date +%s)
((installTime=($endTime-$startTime)/60))
echo "####################Congratulations########################"
echo "Total Install Time: ${CQUESTION}${installTime}${CEND} minutes"
[[ "${nginx_option}" =~ ^[1-3]$ ]] && printf "%b" "\n$(printf "%-32s" "Nginx install dir":)${CMSG}${web_install_dir}${CEND}\n"
[[ "${db_option}" =~ ^[1-5]$ ]] && printf "%b" "\n$(printf "%-32s" "Database install dir:")${CMSG}${db_install_dir}${CEND}\n"
[[ "${db_option}" =~ ^[1-5]$ ]] && echo "$(printf "%-32s" "Database data dir:")${CMSG}${db_data_dir}${CEND}"
[[ "${db_option}" =~ ^[1-5]$ ]] && echo "$(printf "%-32s" "Database user:")${CMSG}root${CEND}"
[[ "${db_option}" =~ ^[1-5]$ ]] && echo "$(printf "%-32s" "Database password:")${CMSG}${dbrootpwd}${CEND}"
[[ "${db_option}" == 6 ]] && printf "%b" "\n$(printf "%-32s" "PostgreSQL install dir:")${CMSG}${pgsql_install_dir}${CEND}\n"
[[ "${db_option}" == 6 ]] && echo "$(printf "%-32s" "PostgreSQL data dir:")${CMSG}${pgsql_data_dir}${CEND}"
[[ "${db_option}" == 6 ]] && echo "$(printf "%-32s" "PostgreSQL user:")${CMSG}postgres${CEND}"
[[ "${db_option}" == 6 ]] && echo "$(printf "%-32s" "postgres password:")${CMSG}${dbpostgrespwd}${CEND}"
[[ "${php_option}" =~ ^[1-3]$ ]] && printf "%b" "\n$(printf "%-32s" "PHP install dir:")${CMSG}${php_install_dir}${CEND}\n"
[[ "${phpcache_option}" == 1 ]] && echo "$(printf "%-32s" "Opcache Control Panel URL:")${CMSG}https://${IPADDR}/ocp.php${CEND}"
[[ "${phpcache_option}" == 2 ]] && echo "$(printf "%-32s" "APC Control Panel URL:")${CMSG}https://${IPADDR}/apc.php${CEND}"
[[ "${pureftpd_flag}" == y ]] && printf "%b" "\n$(printf "%-32s" "Pure-FTPd install dir:")${CMSG}${pureftpd_install_dir}${CEND}\n"
[[ "${pureftpd_flag}" == y ]] && echo "$(printf "%-32s" "Create FTP virtual script:")${CMSG}./pureftpd_vhost.sh${CEND}"
[[ "${phpmyadmin_flag}" == y ]] && printf "%b" "\n$(printf "%-32s" "phpMyAdmin dir:")${CMSG}${wwwroot_dir}/default/phpMyAdmin${CEND}\n"
[[ "${phpmyadmin_flag}" == y ]] && echo "$(printf "%-32s" "phpMyAdmin Control Panel URL:")${CMSG}https://${IPADDR}/phpMyAdmin${CEND}"
[[ "${redis_flag}" == y ]] && printf "%b" "\n$(printf "%-32s" "redis install dir:")${CMSG}${redis_install_dir}${CEND}\n"
[[ "${memcached_flag}" == y ]] && printf "%b" "\n$(printf "%-32s" "memcached install dir:")${CMSG}${memcached_install_dir}${CEND}\n"
if [[ ${nginx_option} =~ ^[1-3]$ ]]; then
  printf "%b" "\n$(printf "%-32s" "Index URL:")${CMSG}https://${IPADDR}/${CEND}\n"
fi
if [[ ${ARG_NUM} == 0 ]]; then
  echo "${CMSG}Please restart the server and see if the services start up fine.${CEND}"
  confirm "Do you want to restart OS?" reboot_flag n
fi
[[ "${reboot_flag}" == y ]] && reboot
