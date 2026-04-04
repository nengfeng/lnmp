#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
#

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
clear
printf "
#######################################################################
#                              Uninstall                              #
#######################################################################
"
# Check if user is root
[ "$(id -u)" != "0" ] && { echo "${CFAILURE}Error: You must be root to run this script${CEND}"; exit 1; }

current_dir=$(dirname "$(readlink -f $0)")
pushd ${current_dir} > /dev/null
. ./options.conf
. ./include/color.sh
. ./include/common.sh
. ./include/ext-common.sh
. ./include/get_char.sh
. ./include/check_dir.sh

Show_Help() {
  echo
  echo "Usage: $0  command ...[parameters]....
  --quiet, -q                   quiet operation
  --all                         Uninstall All
  --web                         Uninstall Nginx/Tengine/OpenResty
  --mysql                       Uninstall MySQL/MariaDB
  --postgresql                  Uninstall PostgreSQL
  --mongodb                     Uninstall MongoDB
  --php                         Uninstall PHP (PATH: ${php_install_dir})
  --mphp_ver [83~85]            Uninstall another PHP version (PATH: ${php_install_dir}\${mphp_ver})
  --allphp                      Uninstall all PHP
  --phpcache                    Uninstall PHP opcode cache
  --php_extensions [ext name]   Uninstall PHP extensions, include ioncube,
                                imagick,fileinfo,imap,ldap,phalcon,
                                yaf,redis,memcached,memcache,mongodb,swoole,xdebug
  --pureftpd                    Uninstall PureFtpd
  --redis                       Uninstall Redis-server
  --memcached                   Uninstall Memcached-server
  --phpmyadmin                  Uninstall phpMyAdmin
  --nodejs                      Uninstall Nodejs (PATH: ${nodejs_install_dir})
  "
}

ARG_NUM=$#
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      Show_Help; exit 0
      ;;
    -q|--quiet)
      quiet_flag=y
      uninstall_flag=y
      shift 1
      ;;
    --all)
      all_flag=y
      web_flag=y
      mysql_flag=y
      postgresql_flag=y
      mongodb_flag=y
      allphp_flag=y
      nodejs_flag=y
      pureftpd_flag=y
      redis_flag=y
      memcached_flag=y
      phpmyadmin_flag=y
      shift 1
      ;;
    --web)
      web_flag=y; shift 1
      ;;
    --mysql)
      mysql_flag=y; shift 1
      ;;
    --postgresql)
      postgresql_flag=y; shift 1
      ;;
    --mongodb)
      mongodb_flag=y; shift 1
      ;;
    --php)
      php_flag=y; shift 1
      ;;
    --mphp_ver)
      mphp_ver=$2; mphp_flag=y; shift 2
      [[ ! "${mphp_ver}" =~ ^8[3-5]$ ]] && { echo "${CWARNING}mphp_ver input error! Please only input number 83~85${CEND}"; exit 1; }
      ;;
    --allphp)
      allphp_flag=y; shift 1
      ;;
    --phpcache)
      phpcache_flag=y; shift 1
      ;;
    --php_extensions)
      php_extensions=$2; shift 2
      [ -n "$(echo ${php_extensions} | grep -w ioncube)" ] && pecl_ioncube=1
      [ -n "$(echo ${php_extensions} | grep -w imagick)" ] && pecl_imagick=1
  
      [ -n "$(echo ${php_extensions} | grep -w fileinfo)" ] && pecl_fileinfo=1
      [ -n "$(echo ${php_extensions} | grep -w imap)" ] && pecl_imap=1
      [ -n "$(echo ${php_extensions} | grep -w ldap)" ] && pecl_ldap=1
      [ -n "$(echo ${php_extensions} | grep -w phalcon)" ] && pecl_phalcon=1
      [ -n "$(echo ${php_extensions} | grep -w yaf)" ] && pecl_yaf=1
      [ -n "$(echo ${php_extensions} | grep -w redis)" ] && pecl_redis=1
      [ -n "$(echo ${php_extensions} | grep -w memcached)" ] && pecl_memcached=1
      [ -n "$(echo ${php_extensions} | grep -w memcache)" ] && pecl_memcache=1
      [ -n "$(echo ${php_extensions} | grep -w mongodb)" ] && pecl_mongodb=1
      [ -n "$(echo ${php_extensions} | grep -w swoole)" ] && pecl_swoole=1
      [ -n "$(echo ${php_extensions} | grep -w xdebug)" ] && pecl_xdebug=1
      ;;
    --nodejs)
      nodejs_flag=y; shift 1
      ;;
    --pureftpd)
      pureftpd_flag=y; shift 1
      ;;
    --redis)
      redis_flag=y; shift 1
      ;;
    --memcached)
      memcached_flag=y; shift 1
      ;;
    --phpmyadmin)
      phpmyadmin_flag=y; shift 1
      ;;
    --)
      shift
      ;;
    *)
      echo "${CWARNING}ERROR: unknown argument! ${CEND}" && Show_Help && exit 1
      ;;
  esac
done

Uninstall_status() {
  if [ "${quiet_flag}" != 'y' ]; then
    while :; do echo
      read -e -p "Do you want to uninstall? [y/n]: " uninstall_flag
      if [[ ! ${uninstall_flag} =~ ^[y,n]$ ]]; then
        echo "${CWARNING}input error! Please only input 'y' or 'n'${CEND}"
      else
        break
      fi
    done
  fi
}

Print_Warn() {
  echo
  echo "${CWARNING}You will uninstall lnmp, Please backup your configure files and DB data! ${CEND}"
}

Print_web() {
  [ -d "${nginx_install_dir}" ] && echo "${nginx_install_dir}"
  [ -d "${tengine_install_dir}" ] && echo "${tengine_install_dir}"
  [ -d "${openresty_install_dir}" ] && echo "${openresty_install_dir}"
  [ -e "/etc/init.d/nginx" ] && echo /etc/init.d/nginx
  [ -e "/lib/systemd/system/nginx.service" ] && echo /lib/systemd/system/nginx.service
  [ -e "/etc/logrotate.d/nginx" ] && echo /etc/logrotate.d/nginx
}

Uninstall_Web() {
  [ -d "${nginx_install_dir}" ] && { killall nginx > /dev/null 2>&1; rm -rf "${nginx_install_dir}" /etc/init.d/nginx /etc/logrotate.d/nginx; sed -i "\:${nginx_install_dir}/sbin:d" /etc/profile; echo "${CMSG}Nginx uninstall completed! ${CEND}"; }
  [ -d "${tengine_install_dir}" ] && { killall nginx > /dev/null 2>&1; rm -rf "${tengine_install_dir}" /etc/init.d/nginx /etc/logrotate.d/nginx; sed -i "\:${tengine_install_dir}/sbin:d" /etc/profile; echo "${CMSG}Tengine uninstall completed! ${CEND}"; }
  [ -d "${openresty_install_dir}" ] && { killall nginx > /dev/null 2>&1; rm -rf "${openresty_install_dir}" /etc/init.d/nginx /etc/logrotate.d/nginx; sed -i "\:${openresty_install_dir}/nginx/sbin:d" /etc/profile; echo "${CMSG}OpenResty uninstall completed! ${CEND}"; }
  [ -e "/lib/systemd/system/nginx.service" ] && { svc_disable nginx > /dev/null 2>&1; rm -f /lib/systemd/system/nginx.service; }
  if [ -e "${wwwroot_dir}" ]; then
    read -e -p "Move ${wwwroot_dir} to ${wwwroot_dir}_bak? (y/n): " move_www
    [[ "${move_www}" == "y" ]] && /bin/mv "${wwwroot_dir}" "${wwwroot_dir}_$(date +%Y%m%d%H)"
  fi
  sed -i 's@^website_name=.*@website_name=@' ./options.conf
  sed -i 's@^backup_content=.*@backup_content=@' ./options.conf
}

Print_MySQL() {
  [ -e "/etc/logrotate.d/mysql" ] && echo /etc/logrotate.d/mysql
  [ -e "${db_install_dir}" ] && echo ${db_install_dir}
  [ -e "/etc/init.d/mysqld" ] && echo /etc/init.d/mysqld
  [ -e "/etc/my.cnf" ] && echo /etc/my.cnf
}

Print_PostgreSQL() {
  [ -e "${pgsql_install_dir}" ] && echo ${pgsql_install_dir}
  [ -e "/etc/init.d/postgresql" ] && echo /etc/init.d/postgresql
  [ -e "/lib/systemd/system/postgresql.service" ] && echo /lib/systemd/system/postgresql.service
}

Print_MongoDB() {
  [ -e "${mongo_install_dir}" ] && echo ${mongo_install_dir}
  [ -e "/etc/init.d/mongod" ] && echo /etc/init.d/mongod
  [ -e "/lib/systemd/system/mongod.service" ] && echo /lib/systemd/system/mongod.service
  [ -e "/etc/mongod.conf" ] && echo /etc/mongod.conf
}

Uninstall_MySQL() {
  # uninstall mysql,mariadb
  if [ -d "${db_install_dir}/support-files" ]; then
    svc_stop mysqld > /dev/null 2>&1
    rm -rf "${db_install_dir}" /etc/init.d/mysqld /etc/my.cnf /etc/logrotate.d/mysql*
    # Remove ld.so.conf.d entries for mysql/mariadb
    rm -f /etc/ld.so.conf.d/*mysql*.conf /etc/ld.so.conf.d/*mariadb*.conf
    id -u mysql >/dev/null 2>&1 ; [ $? -eq 0 ] && userdel mysql
    if [ -e "${db_data_dir}" ]; then
      read -e -p "Move ${db_data_dir} to ${db_data_dir}_bak? (y/n): " move_db
      [[ "${move_db}" == "y" ]] && /bin/mv "${db_data_dir}" "${db_data_dir}_$(date +%Y%m%d%H)"
    fi
    sed -i 's@^dbrootpwd=.*@dbrootpwd=@' ./options.conf
    sed -i "\:${db_install_dir}/bin:d" /etc/profile
    echo "${CMSG}MySQL uninstall completed! ${CEND}"
  fi
}

Uninstall_PostgreSQL() {
  # uninstall postgresql
  if [ -e "${pgsql_install_dir}/bin/psql" ]; then
    svc_stop postgresql > /dev/null 2>&1
    rm -rf "${pgsql_install_dir}" /etc/init.d/postgresql
    [ -e "/lib/systemd/system/postgresql.service" ] && { svc_disable postgresql > /dev/null 2>&1; rm -f /lib/systemd/system/postgresql.service; }
    [ -e "${php_install_dir}/etc/php.d/07-pgsql.ini" ] && rm -f "${php_install_dir}/etc/php.d/07-pgsql.ini"
    id -u postgres >/dev/null 2>&1 ; [ $? -eq 0 ] && userdel postgres
    if [ -e "${pgsql_data_dir}" ]; then
      read -e -p "Move ${pgsql_data_dir} to ${pgsql_data_dir}_bak? (y/n): " move_pg
      [[ "${move_pg}" == "y" ]] && /bin/mv "${pgsql_data_dir}" "${pgsql_data_dir}_$(date +%Y%m%d%H)"
    fi
    sed -i 's@^dbpostgrespwd=.*@dbpostgrespwd=@' ./options.conf
    sed -i "\:${pgsql_install_dir}/bin:d" /etc/profile
    echo "${CMSG}PostgreSQL uninstall completed! ${CEND}"
  fi
}

Uninstall_MongoDB() {
  # uninstall mongodb
  if [ -e "${mongo_install_dir}/bin/mongo" ]; then
    svc_stop mongod > /dev/null 2>&1
    rm -rf "${mongo_install_dir}" /etc/mongod.conf /etc/init.d/mongod /tmp/mongo*.sock
    [ -e "/lib/systemd/system/mongod.service" ] && { svc_disable mongod > /dev/null 2>&1; rm -f /lib/systemd/system/mongod.service; }
    [ -e "${php_install_dir}/etc/php.d/07-mongo.ini" ] && rm -f "${php_install_dir}/etc/php.d/07-mongo.ini"
    [ -e "${php_install_dir}/etc/php.d/07-mongodb.ini" ] && rm -f "${php_install_dir}/etc/php.d/07-mongodb.ini"
    id -u mongod >/dev/null 2>&1 ; [ $? -eq 0 ] && userdel mongod
    if [ -e "${mongo_data_dir}" ]; then
      read -e -p "Move ${mongo_data_dir} to ${mongo_data_dir}_bak? (y/n): " move_mongo
      [[ "${move_mongo}" == "y" ]] && /bin/mv "${mongo_data_dir}" "${mongo_data_dir}_$(date +%Y%m%d%H)"
    fi
    sed -i 's@^dbmongopwd=.*@dbmongopwd=@' ./options.conf
    sed -i "\:${mongo_install_dir}/bin:d" /etc/profile
    echo "${CMSG}MongoDB uninstall completed! ${CEND}"
  fi
}

Uninstall_MongoDB() {
  # uninstall mongodb
  if [ -e "${mongo_install_dir}/bin/mongo" ]; then
    svc_stop mongod > /dev/null 2>&1
    rm -rf ${mongo_install_dir} /etc/mongod.conf /etc/init.d/mongod /tmp/mongo*.sock
    [ -e "/lib/systemd/system/mongod.service" ] && { svc_disable mongod > /dev/null 2>&1; rm -f /lib/systemd/system/mongod.service; }
    [ -e "${php_install_dir}/etc/php.d/07-mongo.ini" ] && rm -f ${php_install_dir}/etc/php.d/07-mongo.ini
    [ -e "${php_install_dir}/etc/php.d/07-mongodb.ini" ] && rm -f ${php_install_dir}/etc/php.d/07-mongodb.ini
    id -u mongod > /dev/null 2>&1 ; [ $? -eq 0 ] && userdel mongod
    [ -e "${mongo_data_dir}" ] && /bin/mv ${mongo_data_dir}{,$(date +%Y%m%d%H)}
    sed -i 's@^dbmongopwd=.*@dbmongopwd=@' ./options.conf
    sed -i "s@${mongo_install_dir}/bin:@@" /etc/profile
    echo "${CMSG}MongoDB uninstall completed! ${CEND}"
  fi
}

Print_PHP() {
  [ -e "${php_install_dir}" ] && echo ${php_install_dir}
  [ -e "/etc/init.d/php-fpm" ] && echo /etc/init.d/php-fpm
  [ -e "/lib/systemd/system/php-fpm.service" ] && echo /lib/systemd/system/php-fpm.service
}

Print_MPHP() {
  [ -e "${php_install_dir}${mphp_ver}" ] && echo ${php_install_dir}${mphp_ver}
  [ -e "/etc/init.d/php${mphp_ver}-fpm" ] && echo /etc/init.d/php${mphp_ver}-fpm
  [ -e "/lib/systemd/system/php${mphp_ver}-fpm.service" ] && echo /lib/systemd/system/php${mphp_ver}-fpm.service
}

Print_ALLPHP() {
  [ -e "${php_install_dir}" ] && echo ${php_install_dir}
  [ -e "/etc/init.d/php-fpm" ] && echo /etc/init.d/php-fpm
  [ -e "/lib/systemd/system/php-fpm.service" ] && echo /lib/systemd/system/php-fpm.service
  for php_ver in 83 84 85; do
    [ -e "${php_install_dir}${php_ver}" ] && echo ${php_install_dir}${php_ver}
    [ -e "/etc/init.d/php${php_ver}-fpm" ] && echo /etc/init.d/php${php_ver}-fpm
    [ -e "/lib/systemd/system/php${php_ver}-fpm.service" ] && echo /lib/systemd/system/php${php_ver}-fpm.service
  done
  [ -e "${imagick_install_dir}" ] && echo ${imagick_install_dir}
  [ -e "${curl_install_dir}" ] && echo ${curl_install_dir}
  [ -e "${freetype_install_dir}" ] && echo ${freetype_install_dir}
}

Uninstall_PHP() {
  [ -e "/etc/init.d/php-fpm" ] && { svc_stop php-fpm > /dev/null 2>&1; rm -f /etc/init.d/php-fpm /etc/logrotate.d/php-fpm; }
  [ -e "/lib/systemd/system/php-fpm.service" ] && { svc_stop php-fpm > /dev/null 2>&1; svc_disable php-fpm > /dev/null 2>&1; rm -f /lib/systemd/system/php-fpm.service; }
  [ -e "${php_install_dir}" ] && { rm -rf ${php_install_dir}; echo "${CMSG}PHP uninstall completed! ${CEND}"; }
  sed -i "s@${php_install_dir}/bin:@@" /etc/profile
}

Uninstall_MPHP() {
  [ -e "/etc/init.d/php${mphp_ver}-fpm" ] && { svc_stop php${mphp_ver}-fpm > /dev/null 2>&1; rm -f /etc/init.d/php${mphp_ver}-fpm; }
  [ -e "/lib/systemd/system/php${mphp_ver}-fpm.service" ] && { svc_stop php${mphp_ver}-fpm > /dev/null 2>&1; svc_disable php${mphp_ver}-fpm > /dev/null 2>&1; rm -f /lib/systemd/system/php${mphp_ver}-fpm.service; }
  [ -e "${php_install_dir}${mphp_ver}" ] && { rm -rf ${php_install_dir}${mphp_ver}; echo "${CMSG}PHP${mphp_ver} uninstall completed! ${CEND}"; }
}

Uninstall_ALLPHP() {
  [ -e "/etc/init.d/php-fpm" ] && { svc_stop php-fpm > /dev/null 2>&1; rm -f /etc/init.d/php-fpm; }
  [ -e "/lib/systemd/system/php-fpm.service" ] && { svc_stop php-fpm > /dev/null 2>&1; svc_disable php-fpm > /dev/null 2>&1; rm -f /lib/systemd/system/php-fpm.service; }
  [ -e "${php_install_dir}" ] && { rm -rf ${php_install_dir}; echo "${CMSG}PHP uninstall completed! ${CEND}"; }
  sed -i "s@${php_install_dir}/bin:@@" /etc/profile
  for php_ver in 83 84 85; do
    [ -e "/etc/init.d/php${php_ver}-fpm" ] && { svc_stop php${php_ver}-fpm > /dev/null 2>&1; rm -f /etc/init.d/php${php_ver}-fpm; }
    [ -e "/lib/systemd/system/php${php_ver}-fpm.service" ] && { svc_stop php${php_ver}-fpm > /dev/null 2>&1; svc_disable php${php_ver}-fpm > /dev/null 2>&1; rm -f /lib/systemd/system/php${php_ver}-fpm.service; }
    [ -e "${php_install_dir}${php_ver}" ] && { rm -rf ${php_install_dir}${php_ver}; echo "${CMSG}PHP${php_ver} uninstall completed! ${CEND}"; }
  done
  [ -e "${imagick_install_dir}" ] && rm -rf ${imagick_install_dir}
  [ -e "${curl_install_dir}" ] && rm -rf ${curl_install_dir}
  [ -e "${freetype_install_dir}" ] && rm -rf ${freetype_install_dir}
}

Uninstall_PHPcache() {
  . include/zendopcache.sh
  . include/apcu.sh
  Uninstall_ZendOPcache
  Uninstall_APCU
  # reload php
  [ -e "${php_install_dir}/sbin/php-fpm" ] && { svc_reload php-fpm; }
  [[ -n "${mphp_ver}" && -e "${php_install_dir}${mphp_ver}/sbin/php-fpm" ]] && { svc_reload php${mphp_ver}-fpm; }
}

Uninstall_PHPext() {
  uninstall_enabled_exts
  reload_php_fpm
}

Menu_PHPext() {
  while :; do
    echo 'Please select uninstall PHP extensions:'
    printf "%b" "\t${CMSG} 0${CEND}. Do not uninstall\n"
    printf "%b" "\t${CMSG} 1${CEND}. Uninstall ioncube\n"
    printf "%b" "\t${CMSG} 2${CEND}. Uninstall imagick\n"
    printf "%b" "\t${CMSG} 3${CEND}. Uninstall fileinfo\n"
    printf "%b" "\t${CMSG} 4${CEND}. Uninstall imap\n"
    printf "%b" "\t${CMSG} 5${CEND}. Uninstall ldap\n"
    printf "%b" "\t${CMSG} 6${CEND}. Uninstall phalcon\n"
    printf "%b" "\t${CMSG} 7${CEND}. Uninstall yaf\n"
    printf "%b" "\t${CMSG} 8${CEND}. Uninstall redis\n"
    printf "%b" "\t${CMSG} 9${CEND}. Uninstall memcached\n"
    printf "%b" "\t${CMSG}10${CEND}. Uninstall memcache\n"
    printf "%b" "\t${CMSG}11${CEND}. Uninstall mongodb\n"
    printf "%b" "\t${CMSG}12${CEND}. Uninstall swoole\n"
    printf "%b" "\t${CMSG}13${CEND}. Uninstall xdebug\n"
    read -e -p "Please input a number:(Default 0 press Enter) " phpext_option
    phpext_option=${phpext_option:-0}
    [ "${phpext_option}" = '0' ] && break
    array_phpext=(${phpext_option})
    array_all=(1 2 3 4 5 6 7 8 9 10 11 12 13)
    for v in ${array_phpext[@]}
    do
      [ -z "$(echo ${array_all[@]} | grep -w ${v})" ] && phpext_flag=1
    done
    if [[ "${phpext_flag}" == 1 ]]; then
      unset phpext_flag
      echo; echo "${CWARNING}input error! Please only input number 0~13${CEND}"; echo
      continue
    else
      [ -n "$(echo ${array_phpext[@]} | grep -w 1)" ] && pecl_ioncube=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 2)" ] && pecl_imagick=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 3)" ] && pecl_fileinfo=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 4)" ] && pecl_imap=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 5)" ] && pecl_ldap=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 6)" ] && pecl_phalcon=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 7)" ] && pecl_yaf=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 8)" ] && pecl_redis=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 9)" ] && pecl_memcached=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 10)" ] && pecl_memcache=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 11)" ] && pecl_mongodb=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 12)" ] && pecl_swoole=1
      [ -n "$(echo ${array_phpext[@]} | grep -w 13)" ] && pecl_xdebug=1
      break
    fi
  done
}

Print_PureFtpd() {
  [ -e "${pureftpd_install_dir}" ] && echo ${pureftpd_install_dir}
  [ -e "/etc/init.d/pureftpd" ] && echo /etc/init.d/pureftpd
  [ -e "/lib/systemd/system/pureftpd.service" ] && echo /lib/systemd/system/pureftpd.service
}

Uninstall_PureFtpd() {
  [ -e "${pureftpd_install_dir}" ] && { svc_stop pureftpd > /dev/null 2>&1; rm -rf ${pureftpd_install_dir} /etc/init.d/pureftpd; echo "${CMSG}Pureftpd uninstall completed! ${CEND}"; }
  [ -e "/lib/systemd/system/pureftpd.service" ] && { svc_disable pureftpd > /dev/null 2>&1; rm -f /lib/systemd/system/pureftpd.service; }
}

Print_Redis_server() {
  [ -e "${redis_install_dir}" ] && echo ${redis_install_dir}
  [ -e "/etc/init.d/redis-server" ] && echo /etc/init.d/redis-server
  [ -e "/lib/systemd/system/redis-server.service" ] && echo /lib/systemd/system/redis-server.service
}

Uninstall_Redis_server() {
  [ -e "${redis_install_dir}" ] && { svc_stop redis-server > /dev/null 2>&1; rm -rf ${redis_install_dir} /etc/init.d/redis-server /usr/local/bin/redis-*; echo "${CMSG}Redis uninstall completed! ${CEND}"; }
  [ -e "/lib/systemd/system/redis-server.service" ] && { svc_disable redis-server > /dev/null 2>&1; rm -f /lib/systemd/system/redis-server.service; }
}

Print_Memcached_server() {
  [ -e "${memcached_install_dir}" ] && echo ${memcached_install_dir}
  [ -e "/etc/init.d/memcached" ] && echo /etc/init.d/memcached
  [ -e "/usr/bin/memcached" ] && echo /usr/bin/memcached
  [ -e "/lib/systemd/system/memcached.service" ] && echo /lib/systemd/system/memcached.service
}

Uninstall_Memcached_server() {
  [ -e "${memcached_install_dir}" ] && { svc_stop memcached > /dev/null 2>&1; rm -rf ${memcached_install_dir} /etc/init.d/memcached /usr/bin/memcached; echo "${CMSG}Memcached uninstall completed! ${CEND}"; }
  [ -e "/lib/systemd/system/memcached.service" ] && { svc_disable memcached > /dev/null 2>&1; rm -f /lib/systemd/system/memcached.service; }
}

Print_phpMyAdmin() {
  [ -d "${wwwroot_dir}/default/phpMyAdmin" ] && echo ${wwwroot_dir}/default/phpMyAdmin
}

Uninstall_phpMyAdmin() {
  [ -d "${wwwroot_dir}/default/phpMyAdmin" ] && rm -rf ${wwwroot_dir}/default/phpMyAdmin
}

Print_openssl() {
  [ -d "${openssl_install_dir}" ] && echo ${openssl_install_dir}
}

Uninstall_openssl() {
  [ -d "${openssl_install_dir}" ] && rm -rf ${openssl_install_dir}
}

Print_Nodejs() {
  [ -e "${nodejs_install_dir}" ] && echo ${nodejs_install_dir}
  [ -e "/etc/profile.d/nodejs.sh" ] && echo /etc/profile.d/nodejs.sh
}

Menu() {
while :; do
  printf "
What Are You Doing?
\t${CMSG} 0${CEND}. Uninstall All
\t${CMSG} 1${CEND}. Uninstall Nginx/Tengine/OpenResty
\t${CMSG} 2${CEND}. Uninstall MySQL/MariaDB
\t${CMSG} 3${CEND}. Uninstall PostgreSQL
\t${CMSG} 4${CEND}. Uninstall MongoDB
\t${CMSG} 5${CEND}. Uninstall all PHP
\t${CMSG} 6${CEND}. Uninstall PHP opcode cache
\t${CMSG} 7${CEND}. Uninstall PHP extensions
\t${CMSG} 8${CEND}. Uninstall PureFtpd
\t${CMSG} 9${CEND}. Uninstall Redis
\t${CMSG}10${CEND}. Uninstall Memcached
\t${CMSG}11${CEND}. Uninstall phpMyAdmin
\t${CMSG}12${CEND}. Uninstall Nodejs (PATH: ${nodejs_install_dir})
\t${CMSG} q${CEND}. Exit
"
  echo
  read -e -p "Please input the correct option: " Number
  if [[ ! "${Number}" =~ ^[0-9,q]$|^1[0-2]$ ]]; then
    echo "${CWARNING}input error! Please only input 0~12 and q${CEND}"
  else
    case "$Number" in
    0)
      Print_Warn
      Print_web
      Print_MySQL
      Print_PostgreSQL
      Print_MongoDB
      Print_ALLPHP
      Print_PureFtpd
      Print_Redis_server
      Print_Memcached_server
      Print_openssl
      Print_phpMyAdmin
      Print_Nodejs
      Uninstall_status
      if [[ "${uninstall_flag}" == y ]]; then
        Uninstall_Web
        Uninstall_MySQL
        Uninstall_PostgreSQL
        Uninstall_MongoDB
        Uninstall_ALLPHP
        Uninstall_PureFtpd
        Uninstall_Redis_server
        Uninstall_Memcached_server
        Uninstall_openssl
        Uninstall_phpMyAdmin
        . include/nodejs.sh; Uninstall_Nodejs
      else
        exit
      fi
      ;;
    1)
      Print_Warn
      Print_web
      Uninstall_status
      [[ "${uninstall_flag}" == y ]] && Uninstall_Web || exit
      ;;
    2)
      Print_Warn
      Print_MySQL
      Uninstall_status
      [[ "${uninstall_flag}" == y ]] && Uninstall_MySQL || exit
      ;;
    3)
      Print_Warn
      Print_PostgreSQL
      Uninstall_status
      [[ "${uninstall_flag}" == y ]] && Uninstall_PostgreSQL || exit
      ;;
    4)
      Print_Warn
      Print_MongoDB
      Uninstall_status
      [[ "${uninstall_flag}" == y ]] && Uninstall_MongoDB || exit
      ;;
    5)
      Print_ALLPHP
      Uninstall_status
      [[ "${uninstall_flag}" == y ]] && Uninstall_ALLPHP || exit
      ;;
    6)
      Uninstall_status
      [[ "${uninstall_flag}" == y ]] && Uninstall_PHPcache || exit
      ;;
    7)
      Menu_PHPext
      [ "${phpext_option}" != '0' ] && Uninstall_status
      [[ "${uninstall_flag}" == y ]] && Uninstall_PHPext || exit
      ;;
    8)
      Print_PureFtpd
      Uninstall_status
      [[ "${uninstall_flag}" == y ]] && Uninstall_PureFtpd || exit
      ;;
    9)
      Print_Redis_server
      Uninstall_status
      [[ "${uninstall_flag}" == y ]] && Uninstall_Redis_server || exit
      ;;
    10)
      Print_Memcached_server
      Uninstall_status
      [[ "${uninstall_flag}" == y ]] && Uninstall_Memcached_server || exit
      ;;
    11)
      Print_phpMyAdmin
      Uninstall_status
      [[ "${uninstall_flag}" == y ]] && Uninstall_phpMyAdmin || exit
      ;;
    12)
      Print_Nodejs
      Uninstall_status
      [[ "${uninstall_flag}" == y ]] && { . include/nodejs.sh; Uninstall_Nodejs; } || exit
      ;;
    q)
      exit
      ;;
    esac
  fi
done
}

if [ ${ARG_NUM} -eq 0 ]; then
  Menu
else
  [[ "${web_flag}" == y ]] && Print_web
  [[ "${mysql_flag}" == y ]] && Print_MySQL
  [[ "${postgresql_flag}" == y ]] && Print_PostgreSQL
  [[ "${mongodb_flag}" == y ]] && Print_MongoDB
  if [[ "${allphp_flag}" == y ]]; then
    Print_ALLPHP
  else
    [[ "${php_flag}" == y ]] && Print_PHP
    [[ "${mphp_flag}" == y ]] && [ "${phpcache_flag}" != 'y' ] && [ -z "${php_extensions}" ] && Print_MPHP
  fi
  [[ "${pureftpd_flag}" == y ]] && Print_PureFtpd
  [[ "${redis_flag}" == y ]] && Print_Redis_server
  [[ "${memcached_flag}" == y ]] && Print_Memcached_server
  [[ "${phpmyadmin_flag}" == y ]] && Print_phpMyAdmin
  [[ "${nodejs_flag}" == y ]] && Print_Nodejs
  [[ "${all_flag}" == y ]] && Print_openssl
  Uninstall_status
  if [[ "${uninstall_flag}" == y ]]; then
    [[ "${web_flag}" == y ]] && Uninstall_Web
    [[ "${mysql_flag}" == y ]] && Uninstall_MySQL
    [[ "${postgresql_flag}" == y ]] && Uninstall_PostgreSQL
    [[ "${mongodb_flag}" == y ]] && Uninstall_MongoDB
    if [[ "${allphp_flag}" == y ]]; then
      Uninstall_ALLPHP
    else
      [[ "${php_flag}" == y ]] && Uninstall_PHP
      [[ "${phpcache_flag}" == y ]] && Uninstall_PHPcache
      [ -n "${php_extensions}" ] && Uninstall_PHPext
      [[ "${mphp_flag}" == y ]] && [ "${phpcache_flag}" != 'y' ] && [ -z "${php_extensions}" ] && Uninstall_MPHP
      [[ "${mphp_flag}" == y ]] && [[ "${phpcache_flag}" == y ]] && Uninstall_PHPcache
      [[ "${mphp_flag}" == y ]] && [ -n "${php_extensions}" ] && Uninstall_PHPext
    fi
    [[ "${pureftpd_flag}" == y ]] && Uninstall_PureFtpd
    [[ "${redis_flag}" == y ]] && Uninstall_Redis_server
    [[ "${memcached_flag}" == y ]] && Uninstall_Memcached_server
    [[ "${phpmyadmin_flag}" == y ]] && Uninstall_phpMyAdmin
    [[ "${nodejs_flag}" == y ]] && { . include/nodejs.sh; Uninstall_Nodejs; }
    [[ "${all_flag}" == y ]] && Uninstall_openssl
  fi
fi
