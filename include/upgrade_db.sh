#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

. include/db-common.sh

Upgrade_DB() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${db_install_dir}/bin/mysql" ] && echo "${CWARNING}MySQL/MariaDB is not installed on your system! ${CEND}" && exit 1
  [[ "${armplatform}" == y ]] && echo "${CWARNING}The arm architecture operating system does not support upgrading MySQL/MariaDB! ${CEND}" && exit 1

  # check db passwd
  while :; do
    ${db_install_dir}/bin/mysql -uroot -p${dbrootpwd} -e "quit" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
      break
    else
      echo
      read -e -p "Please input the root password of database: " NEW_dbrootpwd || { echo "${CFAILURE}No interactive terminal available (stdin closed), aborting.${CEND}" && exit 1; }
      ${db_install_dir}/bin/mysql -uroot -p${NEW_dbrootpwd} -e "quit" >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        dbrootpwd=${NEW_dbrootpwd}
        local pwd_escaped=$(echo "${dbrootpwd}" | sed 's/\\/\\\\/g; s/'\''/\\'\''/g')
        sed -i "s+^dbrootpwd.*+dbrootpwd='${pwd_escaped}'+" ../options.conf
        chmod 600 ../options.conf
        break
      else
        echo "${CFAILURE}${DB} root password incorrect,Please enter again! ${CEND}"
      fi
    fi
  done

  OLD_db_ver_tmp=$(${db_install_dir}/bin/mysql -uroot -p${dbrootpwd} -e 'select version()\G;' | grep version | awk '{print $2}')
  if [[ -n "$(${db_install_dir}/bin/mysql -V | grep -i MariaDB)" ]]; then
    [[ "${OUTIP_STATE}"x == "China"x ]] && DOWN_ADDR=https://mirrors.tuna.tsinghua.edu.cn/mariadb || DOWN_ADDR=https://archive.mariadb.org
    DB=MariaDB
    OLD_db_ver=$(echo ${OLD_db_ver_tmp} | awk -F'-' '{print $1}')
  else
    DOWN_ADDR=https://cdn.mysql.com/Downloads
    DB=MySQL
    OLD_db_ver=${OLD_db_ver_tmp%%-log}
  fi

  #backup
  echo
  echo "${CSUCCESS}Starting ${DB} backup${CEND}......"
  local DB_backup_file="DB_all_backup_$(date +"%Y%m%d").sql"
  ${db_install_dir}/bin/mysqldump -uroot -p${dbrootpwd} --opt --all-databases --routines --events > "${DB_backup_file}"
  if [ $? -eq 0 ] && [ -s "${DB_backup_file}" ]; then
    echo "${DB} backup success, Backup file: ${MSG}$(pwd)/${DB_backup_file}${CEND}"
  else
    rm -f "${DB_backup_file}"
    echo "${CFAILURE}${DB} backup failed (check password/disk space)! Upgrade aborted, your data is untouched.${CEND}"
    return 1
  fi

  #upgrade
  echo
  echo "Current ${DB} Version: ${CMSG}${OLD_db_ver}${CEND}"
  while :; do echo
    [ "${db_flag}" != 'y' ] && read -e -p "Please input upgrade ${DB} Version(example: ${OLD_db_ver}): " NEW_db_ver
    if [[ "$(echo ${NEW_db_ver} | awk -F. '{print $1"."$2}')" == "$(echo ${OLD_db_ver} | awk -F. '{print $1"."$2}')" ]]; then
      if [[ "${DB}" == MariaDB ]]; then
        DB_filename=mariadb-${NEW_db_ver}-linux-systemd-x86_64
        DB_URL=${DOWN_ADDR}/mariadb-${NEW_db_ver}/bintar-linux-systemd-x86_64/${DB_filename}.tar.gz
      elif [[ "${DB}" == MySQL ]]; then
        DB_filename=mysql-${NEW_db_ver}-linux-glibc2.28-x86_64
        DB_URL=${DOWN_ADDR}/MySQL-$(echo ${NEW_db_ver} | awk -F. '{print $1"."$2}')/${DB_filename}.tar.xz
      fi
      local db_archive_file=""
      for _f in ${DB_filename}.tar.?z; do
        [ -f "$_f" ] && db_archive_file="$_f" && break
      done
      [ -z "${db_archive_file}" ] && { wget -c ${DB_URL} > /dev/null 2>&1; }
      for _f in ${DB_filename}.tar.?z; do
        [ -f "$_f" ] && db_archive_file="$_f" && break
      done
      if [ -n "${db_archive_file}" ]; then
        echo "Download [${CMSG}${db_archive_file}${CEND}] successfully! "
      else
        echo "${CWARNING}${DB} version does not exist! ${CEND}"
      fi
      break
    else
      echo "${CWARNING}input error! ${CEND}Please only input '${CMSG}${OLD_db_ver%.*}.xx${CEND}'"
      [[ "${db_flag}" == y ]] && exit
    fi
  done

  local db_archive_file=""
  for _f in ${DB_filename}.tar.?z; do
    [ -f "$_f" ] && db_archive_file="$_f" && break
  done
  if [ -z "${db_archive_file}" ]; then
    echo "Downloading ${CMSG}${DB_URL}${CEND}......"
    wget -c ${DB_URL} > /dev/null 2>&1
  fi
  for _f in ${DB_filename}.tar.?z; do
    [ -f "$_f" ] && db_archive_file="$_f" && break
  done

  if [ -z "${db_archive_file}" ]; then
    echo "${CFAILURE}Archive not found and download failed! Upgrade aborted, nothing was changed.${CEND}"
    return 1
  fi
  echo "[${CMSG}${db_archive_file}${CEND}] found"
  if [ "${db_flag}" != 'y' ]; then
    echo "Press Ctrl+c to cancel or Press any key to continue..."
    char=$(get_char)
  fi
  if [[ "${DB}" == MariaDB ]]; then
      rm -rf ${DB_filename}
      echo "Extracting ${db_archive_file}......"
      if ! tar xzf "${db_archive_file}"; then
        echo "${CFAILURE}Extract failed: ${db_archive_file} is corrupted or truncated! Nothing was changed, please delete it and retry.${CEND}"
        return 1
      fi
      if [ ! -e "${DB_filename}/bin/mysqld" ] || [ ! -f "${DB_filename}/scripts/mysql_install_db" ]; then
        echo "${CFAILURE}Extracted tree incomplete (missing bin/mysqld or scripts/mysql_install_db)! Nothing was changed.${CEND}"
        return 1
      fi
      svc_stop mysqld
      local timeout=60
      while pidof mysqld mariadbd >/dev/null 2>&1; do
        [ $((timeout--)) -le 0 ] && { echo "${CFAILURE}Timeout waiting for MySQL to stop${CEND}"; return 1; }
        sleep 1
      done
      mv ${mariadb_install_dir}{,_old_$(date +"%Y%m%d_%H%M%S")}
      mv ${mariadb_data_dir}{,_old_$(date +"%Y%m%d_%H%M%S")}
      [ ! -d "${mariadb_install_dir}" ] && mkdir -p ${mariadb_install_dir}
      mkdir -p ${mariadb_data_dir};chown mysql:mysql -R ${mariadb_data_dir}
      mv ${DB_filename}/* ${mariadb_install_dir}/
      # Inject tcmalloc for MariaDB (use mariadbd-safe for 11.x+, mysqld_safe for older)
      local safe_script="${mariadb_install_dir}/bin/mariadbd-safe"
      [ ! -f "${safe_script}" ] && safe_script="${mariadb_install_dir}/bin/mysqld_safe"
      [ -f "${safe_script}" ] && sed -i 's@executing mysqld_safe@executing mysqld_safe\nexport LD_PRELOAD=/usr/local/lib/'"${allocator_so:-libtcmalloc.so}"'@' ${safe_script}
      ${mariadb_install_dir}/scripts/mysql_install_db --user=mysql --basedir=${mariadb_install_dir} --datadir=${mariadb_data_dir}
      chown mysql:mysql -R ${mariadb_data_dir}
      svc_start mysqld
      wait_for_db_ready ${mariadb_install_dir} || { echo "${CFAILURE}Database failed to start${CEND}"; return 1; }
      echo "Restoring data from ${DB_backup_file}......"
      if ! ${mariadb_install_dir}/bin/mysql < "${DB_backup_file}"; then
        echo "${CFAILURE}Data restore failed! Old data preserved at ${mariadb_data_dir}_old_*, please restore manually.${CEND}"
        return 1
      fi
      svc_restart mysqld
      ${mariadb_install_dir}/bin/mysql -uroot -p${dbrootpwd} -e "drop database test;" >/dev/null 2>&1
      ${mariadb_install_dir}/bin/mysql -uroot -p${dbrootpwd} -e "reset master;" >/dev/null 2>&1
      ${mariadb_install_dir}/bin/mysql_upgrade -uroot -p${dbrootpwd} >/dev/null 2>&1
      # Reset root user permissions (including root@'127.0.0.1')
      local root_cmd="mysql"
      [ -x "${mariadb_install_dir}/bin/mariadb" ] && root_cmd="mariadb"
      setup_mariadb_root ${mariadb_install_dir} ${dbrootpwd} ${root_cmd}
      [ $? -eq 0 ] &&  echo "You have ${CMSG}successfully${CEND} upgrade from ${CMSG}${OLD_db_ver}${CEND} to ${CMSG}${NEW_db_ver}${CEND}"
    elif [[ "${DB}" == MySQL ]]; then
      rm -rf ${DB_filename}
      echo "Extracting ${db_archive_file}......"
      if ! tar xJf "${db_archive_file}"; then
        echo "${CFAILURE}Extract failed: ${db_archive_file} is corrupted or truncated! Nothing was changed, please delete it and retry.${CEND}"
        return 1
      fi
      if [ ! -f "${DB_filename}/bin/mysqld" ]; then
        echo "${CFAILURE}Extracted tree incomplete (missing bin/mysqld)! Nothing was changed.${CEND}"
        return 1
      fi
      svc_stop mysqld
      local timeout=60
      while pidof mysqld >/dev/null 2>&1; do
        [ $((timeout--)) -le 0 ] && { echo "${CFAILURE}Timeout waiting for MySQL to stop${CEND}"; return 1; }
        sleep 1
      done
      mv ${mysql_install_dir}{,_old_$(date +"%Y%m%d_%H%M%S")}
      mv ${mysql_data_dir}{,_old_$(date +"%Y%m%d_%H%M%S")}
      [ ! -d "${mysql_install_dir}" ] && mkdir -p ${mysql_install_dir}
      mkdir -p ${mysql_data_dir};chown mysql:mysql -R ${mysql_data_dir}
      mv ${DB_filename}/* ${mysql_install_dir}/
      sed -i 's@executing mysqld_safe@executing mysqld_safe\nexport LD_PRELOAD=/usr/local/lib/'"${allocator_so:-libtcmalloc.so}"'@' ${mysql_install_dir}/bin/mysqld_safe
      sed -i "s@/usr/local/mysql@${mysql_install_dir}@g" ${mysql_install_dir}/bin/mysqld_safe
      ${mysql_install_dir}/bin/mysqld --initialize-insecure --user=mysql --basedir=${mysql_install_dir} --datadir=${mysql_data_dir}

      chown mysql:mysql -R ${mysql_data_dir}
      [ -e "${mysql_install_dir}/my.cnf" ] && rm -rf ${mysql_install_dir}/my.cnf
      sed -i '/myisam_repair_threads/d' /etc/my.cnf
      svc_start mysqld
      wait_for_db_ready ${mysql_install_dir} || { echo "${CFAILURE}Database failed to start${CEND}"; return 1; }
      echo "Restoring data from ${DB_backup_file}......"
      if ! ${mysql_install_dir}/bin/mysql < "${DB_backup_file}"; then
        echo "${CFAILURE}Data restore failed! Old data preserved at ${mysql_data_dir}_old_*, please restore manually.${CEND}"
        return 1
      fi
      svc_restart mysqld
      ${mysql_install_dir}/bin/mysql -uroot -p${dbrootpwd} -e "drop database test;" >/dev/null 2>&1
      ${mysql_install_dir}/bin/mysql -uroot -p${dbrootpwd} -e "reset master;" >/dev/null 2>&1
      ${mysql_install_dir}/bin/mysql_upgrade -uroot -p${dbrootpwd} >/dev/null 2>&1
      # Reset root user permissions (including root@'127.0.0.1')
      setup_mysql_root ${mysql_install_dir} ${dbrootpwd}
      [ $? -eq 0 ] &&  echo "You have ${CMSG}successfully${CEND} upgrade from ${CMSG}${OLD_db_ver}${CEND} to ${CMSG}${NEW_db_ver}${CEND}"
    fi
}
