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
      read -e -p "Please input the root password of database: " NEW_dbrootpwd
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
  ${db_install_dir}/bin/mysqldump -uroot -p${dbrootpwd} --opt --all-databases > DB_all_backup_$(date +"%Y%m%d").sql
  [ -f "DB_all_backup_$(date +"%Y%m%d").sql" ] && echo "${DB} backup success, Backup file: ${MSG}$(pwd)/DB_all_backup_$(date +"%Y%m%d").sql${CEND}"

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
      [ ! -e "$(ls ${DB_filename}.tar.?z 2>/dev/null)" ] && wget -c ${DB_URL} > /dev/null 2>&1
      if [ -e "$(ls ${DB_filename}.tar.?z 2>/dev/null)" ]; then
        echo "Download [${CMSG}$(ls ${DB_filename}.tar.?z 2>/dev/null)${CEND}] successfully! "
      else
        echo "${CWARNING}${DB} version does not exist! ${CEND}"
      fi
      break
    else
      echo "${CWARNING}input error! ${CEND}Please only input '${CMSG}${OLD_db_ver%.*}.xx${CEND}'"
      [[ "${db_flag}" == y ]] && exit
    fi
  done

  if [ -e "$(ls ${DB_filename}.tar.?z 2>/dev/null)" ]; then
    echo "[${CMSG}$(ls ${DB_filename}.tar.?z 2>/dev/null)${CEND}] found"
    if [ "${db_flag}" != 'y' ]; then
      echo "Press Ctrl+c to cancel or Press any key to continue..."
      char=$(get_char)
    fi
    if [[ "${DB}" == MariaDB ]]; then
      tar xzf ${DB_filename}.tar.gz
      svc_stop mysqld
      mv ${mariadb_install_dir}{,_old_$(date +"%Y%m%d_%H%M%S")}
      mv ${mariadb_data_dir}{,_old_$(date +"%Y%m%d_%H%M%S")}
      [ ! -d "${mariadb_install_dir}" ] && mkdir -p ${mariadb_install_dir}
      mkdir -p ${mariadb_data_dir};chown mysql:mysql -R ${mariadb_data_dir}
      mv ${DB_filename}/* ${mariadb_install_dir}/
      # Inject tcmalloc for MariaDB (use mariadbd-safe for 11.x+, mysqld_safe for older)
      local safe_script="${mariadb_install_dir}/bin/mariadbd-safe"
      [ ! -f "${safe_script}" ] && safe_script="${mariadb_install_dir}/bin/mysqld_safe"
      [ -f "${safe_script}" ] && sed -i 's@executing mysqld_safe@executing mysqld_safe\nexport LD_PRELOAD=/usr/local/lib/libtcmalloc.so@' ${safe_script}
      ${mariadb_install_dir}/scripts/mysql_install_db --user=mysql --basedir=${mariadb_install_dir} --datadir=${mariadb_data_dir}
      chown mysql:mysql -R ${mariadb_data_dir}
      svc_start mysqld
      wait_for_db_ready ${mariadb_install_dir} || { echo "${CFAILURE}Database failed to start${CEND}"; return 1; }
      ${mariadb_install_dir}/bin/mysql < DB_all_backup_$(date +"%Y%m%d").sql
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
      tar xJf ${DB_filename}.tar.xz
      svc_stop mysqld
      mv ${mysql_install_dir}{,_old_$(date +"%Y%m%d_%H%M%S")}
      mv ${mysql_data_dir}{,_old_$(date +"%Y%m%d_%H%M%S")}
      [ ! -d "${mysql_install_dir}" ] && mkdir -p ${mysql_install_dir}
      mkdir -p ${mysql_data_dir};chown mysql:mysql -R ${mysql_data_dir}
      mv ${DB_filename}/* ${mysql_install_dir}/
      sed -i 's@executing mysqld_safe@executing mysqld_safe\nexport LD_PRELOAD=/usr/local/lib/libtcmalloc.so@' ${mysql_install_dir}/bin/mysqld_safe
      sed -i "s@/usr/local/mysql@${mysql_install_dir}@g" ${mysql_install_dir}/bin/mysqld_safe
      ${mysql_install_dir}/bin/mysqld --initialize-insecure --user=mysql --basedir=${mysql_install_dir} --datadir=${mysql_data_dir}

      chown mysql:mysql -R ${mysql_data_dir}
      [ -e "${mysql_install_dir}/my.cnf" ] && rm -rf ${mysql_install_dir}/my.cnf
      sed -i '/myisam_repair_threads/d' /etc/my.cnf
      svc_start mysqld
      wait_for_db_ready ${mysql_install_dir} || { echo "${CFAILURE}Database failed to start${CEND}"; return 1; }
      ${mysql_install_dir}/bin/mysql < DB_all_backup_$(date +"%Y%m%d").sql
      svc_restart mysqld
      ${mysql_install_dir}/bin/mysql -uroot -p${dbrootpwd} -e "drop database test;" >/dev/null 2>&1
      ${mysql_install_dir}/bin/mysql -uroot -p${dbrootpwd} -e "reset master;" >/dev/null 2>&1
      ${mysql_install_dir}/bin/mysql_upgrade -uroot -p${dbrootpwd} >/dev/null 2>&1
      # Reset root user permissions (including root@'127.0.0.1')
      setup_mysql_root ${mysql_install_dir} ${dbrootpwd}
      [ $? -eq 0 ] &&  echo "You have ${CMSG}successfully${CEND} upgrade from ${CMSG}${OLD_db_ver}${CEND} to ${CMSG}${NEW_db_ver}${CEND}"
    fi
  fi
}
