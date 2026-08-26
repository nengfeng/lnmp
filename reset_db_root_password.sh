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
  echo "${CMSG}Stopping MySQL...${CEND}"
  svc_stop mysqld > /dev/null 2>&1
  local timeout=60
  while [ -n "$(pidof mysqld mariadbd)" ]; do
    [ $((timeout--)) -le 0 ] && { echo "${CFAILURE}Timeout waiting for MySQL to stop${CEND}"; popd; return 1; }
    sleep 1
  done

  # Start with grants bypassed (server forces skip-networking in this mode,
  # so exposure is limited to the local unix socket)
  echo "${CMSG}skip grant tables...${CEND}"
  sed -i '/\[mysqld\]/a\skip-grant-tables' /etc/my.cnf
  svc_start mysqld > /dev/null 2>&1
  timeout=60
  while [ -z "$(pidof mysqld mariadbd)" ]; do
    [ $((timeout--)) -le 0 ] && { echo "${CFAILURE}Timeout waiting for MySQL to start${CEND}"; sed -i '/^skip-grant-tables/d' /etc/my.cnf; popd; return 1; }
    sleep 1
  done
  sleep 2

  # Change the password WHILE grants are still bypassed:
  # FLUSH PRIVILEGES reloads the grant tables, enabling ALTER USER
  # (official recipe for skip-grant-tables mode)
  echo "${CMSG}Setting new password...${CEND}"
  local escaped_pwd=$(echo "${New_dbrootpwd}" | sed 's/\\/\\\\/g; s/'\''/\\'\''/g')
  local reset_ok=n rc_127=0
  ${db_install_dir}/bin/mysql -uroot -hlocalhost << EOF 2>/dev/null
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${escaped_pwd}';
EOF
  if [ $? -eq 0 ]; then
    reset_ok=y
    # root@'127.0.0.1' is optional: a manually removed account must not
    # mask the localhost success above
    ${db_install_dir}/bin/mysql -uroot -hlocalhost << EOF 2>/dev/null
FLUSH PRIVILEGES;
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${escaped_pwd}';
EOF
    rc_127=$?
    [ ${rc_127} -ne 0 ] && echo "${CWARNING}Warning: could not update root@'127.0.0.1' (account may not exist). The localhost password WAS changed.${CEND}"
  fi

  # Restore normal mode unconditionally (also cleans up on failure)
  echo "${CMSG}Removing skip-grant-tables and restarting MySQL...${CEND}"
  svc_stop mysqld > /dev/null 2>&1
  timeout=60
  while [ -n "$(pidof mysqld mariadbd)" ]; do
    [ $((timeout--)) -le 0 ] && { pidof mysqld mariadbd | xargs kill -9 > /dev/null 2>&1; break; }
    sleep 1
  done
  sed -i '/^skip-grant-tables/d' /etc/my.cnf
  svc_start mysqld > /dev/null 2>&1
  timeout=60
  while [ -z "$(pidof mysqld mariadbd)" ]; do
    [ $((timeout--)) -le 0 ] && { echo "${CFAILURE}Timeout waiting for MySQL to start${CEND}"; popd; return 1; }
    sleep 1
  done
  sleep 2

  if [[ "${reset_ok}" != y ]]; then
    echo "${CFAILURE}Failed to set the new password. Old password unchanged, please check the error log.${CEND}"
    popd; return 1
  fi

  # Verify the new credentials against the restarted, normally-authenticating server
  if ! ${db_install_dir}/bin/mysql -uroot -p"${New_dbrootpwd}" -hlocalhost -e "SELECT 1;" > /dev/null 2>&1; then
    echo "${CFAILURE}Verification failed with the new password, please inspect manually.${CEND}"
    popd; return 1
  fi

  sed -i "s+^dbrootpwd.*+dbrootpwd='${escaped_pwd}'+" ./options.conf
  chmod 600 ./options.conf
  [ -e ~/ReadMe ] && sed -i "s+^MySQL root password:.*+MySQL root password: ${New_dbrootpwd}+"  ~/ReadMe
  echo
  echo "Password reset successfully! "
  echo "The new password: ${CMSG}${New_dbrootpwd}${CEND}"
  echo
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
