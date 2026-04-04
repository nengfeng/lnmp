#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: Unified MySQL installation function

. include/db-common.sh

# Install MySQL (unified for all versions)
# Usage: Install_MySQL <mysql_ver> <cnf_func> <reset_master>
#   mysql_ver:  e.g. mysql84_ver or mysql80_ver
#   cnf_func:   generate_my_cnf_mysql8 or generate_my_cnf_mysql80
#   reset_master: yes or no (MySQL 8.0 needs reset master)
Install_MySQL() {
  local mysql_ver=$1
  local cnf_func=$2
  local reset_master=${3:-no}

  # Fix libaio symlink for Debian 13+ / Ubuntu 24.04+
  fix_libaio_symlink

  pushd ${current_dir}/src > /dev/null
  create_mysql_user

  [ ! -d "${mysql_install_dir}" ] && mkdir -p ${mysql_install_dir}
  mkdir -p ${mysql_data_dir}
  chown mysql:mysql -R ${mysql_data_dir}

  if [[ "${dbinstallmethod}" == "1" ]]; then
    install_mysql_binary ${mysql_ver} ${mysql_install_dir}
  elif [[ "${dbinstallmethod}" == "2" ]]; then
    install_mysql_source ${mysql_ver} ${mysql_install_dir} ${mysql_data_dir} ${boost_ver} ${THREAD}
  fi

  if [ -d "${mysql_install_dir}/support-files" ]; then
    sed -i 's@executing mysqld_safe@executing mysqld_safe\nexport LD_PRELOAD=/usr/local/lib/libtcmalloc.so@' ${mysql_install_dir}/bin/mysqld_safe
    local pwd_escaped=$(escape_password "${dbrootpwd}")
    sed -i "s+^dbrootpwd.*+dbrootpwd='${pwd_escaped}'+" ../options.conf
    chmod 600 ../options.conf
    success_msg "MySQL"
    cleanup_mysql_files ${mysql_ver} ${dbinstallmethod}
  else
    rm -rf ${mysql_install_dir}
    fail_msg "MySQL"
    popd
    return 1
  fi

  setup_db_service ${mysql_install_dir} ${mysql_data_dir}
  popd

  ${cnf_func} ${mysql_install_dir} ${mysql_data_dir}
  config_my_cnf_scenario /etc/my.cnf ${server_scenario} ${Mem}

  ${mysql_install_dir}/bin/mysqld --initialize-insecure --user=mysql --basedir=${mysql_install_dir} --datadir=${mysql_data_dir}

  chown mysql:mysql -R ${mysql_data_dir}
  [ -d "/etc/mysql" ] && /bin/mv /etc/mysql{,_bk}
  svc_start mysqld
  add_to_path ${mysql_install_dir}/bin

  setup_mysql_root ${mysql_install_dir} ${dbrootpwd} ${reset_master}

  post_install_db ${mysql_install_dir} mysql ${mysql_data_dir}
  # Keep service running - install.sh will handle final service check
}
