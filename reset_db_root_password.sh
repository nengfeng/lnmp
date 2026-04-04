#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
#

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
clear
printf "
#######################################################################
#                  Reset Database root password                       #
#######################################################################
"
current_dir=$(dirname "$(readlink -f $0)")
pushd ${current_dir} > /dev/null
. ./options.conf
. ./include/color.sh
. ./include/check_dir.sh
[ ! -d "${db_install_dir}" ] && { echo "${CFAILURE}Database is not installed on your system! ${CEND}"; exit 1; }

Show_Help() {
  echo "Usage: $0  command ...[parameters]....
  -h,  --help                  print this help.
  -q,  --quiet                 quiet operation.
  -f,  --force                 Lost Database Password? Forced reset password.
  -p,  --password [pass]       DB super password.
  "
}

New_dbrootpwd="$(< /dev/urandom tr -dc A-Za-z0-9 | head -c16)"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      Show_Help; exit 0
      ;;
    -q|--quiet)
      quiet_flag=y; shift 1
      ;;
    -f|--force)
      force_flag=y; shift 1
      ;;
    -p|--password)
      New_dbrootpwd=$2; shift 2
      if [[ "${New_dbrootpwd}" =~ [\'\\] ]]; then
        echo "${CFAILURE}Password cannot contain single quotes (') or backslashes (\\)${CEND}"
        exit 1
      fi
      password_flag=y
      ;;
    --)
      shift
      ;;
    *)
      echo "${CWARNING}ERROR: unknown argument! ${CEND}" && Show_Help && exit 1
      ;;
  esac
done

Input_dbrootpwd() {
  while :; do echo
    read -e -p "Please input the root password of database: " New_dbrootpwd
    [ -n "$(echo ${New_dbrootpwd} | grep '[+|&]')" ] && { echo "${CWARNING}input error,not contain a plus sign (+) and &${CEND}"; continue; }
    # Security: Block characters that could cause SQL injection
    # Single quotes and backslashes are particularly dangerous
    if [[ "${New_dbrootpwd}" =~ [\'\\] ]]; then
      echo "${CWARNING}input error, password cannot contain single quotes (') or backslashes (\\)${CEND}"
      continue
    fi
    (( ${#New_dbrootpwd} >= 5 )) && break || echo "${CWARNING}database root password least 5 characters! ${CEND}"
  done
}

Reset_Interaction_dbrootpwd() {
  local pwd_escaped=$(echo "${New_dbrootpwd}" | sed 's/\\/\\\\/g; s/'\''/\\'\''/g')
  ${db_install_dir}/bin/mysqladmin -uroot -p"${dbrootpwd}" password "${New_dbrootpwd}" -h localhost > /dev/null 2>&1
  status_Localhost=$(echo $?)
  ${db_install_dir}/bin/mysqladmin -uroot -p"${dbrootpwd}" password "${New_dbrootpwd}" -h 127.0.0.1 > /dev/null 2>&1
  status_127=$(echo $?)
  if [[ ${status_Localhost} == '0' && ${status_127} == '0' ]]; then
    sed -i "s+^dbrootpwd.*+dbrootpwd='${pwd_escaped}'+" ./options.conf
    chmod 600 ./options.conf
    echo
    echo "Password reset successfully! "
    echo "The new password: ${CMSG}${New_dbrootpwd}${CEND}"
    echo
  else
    echo "${CFAILURE}Reset Database root password failed! ${CEND}"
  fi
}

Reset_force_dbrootpwd() {
  DB_Ver="$(${db_install_dir}/bin/mysql_config --version)"
  echo "${CMSG}Stopping MySQL...${CEND}"
  svc_stop mysqld > /dev/null 2>&1
  while [ -n "$(ps -ef | grep mysqld | grep -v grep | awk '{print $2}')" ]; do
    sleep 1
  done
  echo "${CMSG}skip grant tables...${CEND}"
  sed -i '/\[mysqld\]/a\skip-grant-tables' /etc/my.cnf
  svc_start mysqld > /dev/null 2>&1
  sed -i '/^skip-grant-tables/d' /etc/my.cnf
  while [ -z "$(ps -ef | grep 'mysqld ' | grep -v grep | awk '{print $2}')" ]; do
    sleep 1
  done
  # Detect MySQL or MariaDB
  local escaped_pwd=$(echo "${New_dbrootpwd}" | sed 's/\\/\\\\/g; s/'\''/\\'\''/g')
  if ${db_install_dir}/bin/mysql -V | grep -qi MariaDB; then
    # MariaDB (10.11, 11.4, 11.8)
    # Detect MariaDB version to use correct command (mysql or mariadb)
    local mdb_cmd="mysql"
    local mdb_ver=$(${db_install_dir}/bin/mysql -V | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ $(echo "$mdb_ver" | cut -d. -f1) -ge 11 ]]; then
      mdb_cmd="mariadb"
    fi
    ${db_install_dir}/bin/${mdb_cmd} -uroot -hlocalhost << EOF
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${escaped_pwd}';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${escaped_pwd}';
FLUSH PRIVILEGES;
EOF
  else
    # MySQL 8.0/8.4
    ${db_install_dir}/bin/mysql -uroot -hlocalhost << EOF
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${escaped_pwd}';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '${escaped_pwd}';
FLUSH PRIVILEGES;
EOF
  fi
  if [ $? -eq 0 ]; then
    killall mysqld
    while [ -n "$(ps -ef | grep mysqld | grep -v grep | awk '{print $2}')" ]; do
      sleep 1
    done
    [ -n "$(ps -ef | grep mysqld | grep -v grep | awk '{print $2}')" ] && ps -ef | grep mysqld | grep -v grep | awk '{print $2}' | xargs kill -9 > /dev/null 2>&1
    svc_start mysqld > /dev/null 2>&1
    sed -i "s+^dbrootpwd.*+dbrootpwd='${escaped_pwd}'+" ./options.conf
    chmod 600 ./options.conf
    [ -e ~/ReadMe ] && sed -i "s+^MySQL root password:.*+MySQL root password: ${New_dbrootpwd}+"  ~/ReadMe
    echo
    echo "Password reset successfully! "
    echo "The new password: ${CMSG}${New_dbrootpwd}${CEND}"
    echo
  fi
}

[[ "${password_flag}" == y ]] && quiet_flag=y
if [[ "${quiet_flag}" == y ]]; then
  if [[ "${force_flag}" == y ]]; then
    Reset_force_dbrootpwd
  else
    sleep 2 && [ ! -e /tmp/mysql.sock ] && svc_start mysqld
    Reset_Interaction_dbrootpwd
  fi
else
  Input_dbrootpwd
  if [[ "${force_flag}" == y ]]; then
    Reset_force_dbrootpwd
  else
    Reset_Interaction_dbrootpwd
  fi
fi
popd > /dev/null
