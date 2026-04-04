#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: Unified MariaDB installation function

. include/db-common.sh

# Install MariaDB (unified for all versions)
# Usage: Install_MariaDB <mariadb_ver> <root_cmd>
#   mariadb_ver: e.g. mariadb118_ver, mariadb114_ver, mariadb1011_ver
#   root_cmd:    'mariadb' (default) or 'mysql' (10.11 uses mysql command)
Install_MariaDB() {
  local mariadb_ver=$1
  local root_cmd=${2:-mariadb}

  # Fix libaio symlink for Debian 13+ / Ubuntu 24.04+
  fix_libaio_symlink

  pushd ${current_dir}/src > /dev/null
  create_mysql_user

  [ ! -d "${mariadb_install_dir}" ] && mkdir -p ${mariadb_install_dir}
  mkdir -p ${mariadb_data_dir}
  chown mysql:mysql -R ${mariadb_data_dir}

  if [[ "${dbinstallmethod}" == "1" ]]; then
    install_mariadb_binary ${mariadb_ver} ${mariadb_install_dir}
  elif [[ "${dbinstallmethod}" == "2" ]]; then
    install_mariadb_source ${mariadb_ver} ${mariadb_install_dir} ${mariadb_data_dir} ${boost_oldver} ${THREAD}
  fi

  if [ -d "${mariadb_install_dir}/support-files" ]; then
    local pwd_escaped=$(escape_password "${dbrootpwd}")
    sed -i "s+^dbrootpwd.*+dbrootpwd='${pwd_escaped}'+" ../options.conf
    chmod 600 ../options.conf
    success_msg "MariaDB"
    cleanup_mariadb_files ${mariadb_ver} ${dbinstallmethod}
  else
    rm -rf ${mariadb_install_dir}
    fail_msg "MariaDB"
    popd
    return 1
  fi

  setup_db_service ${mariadb_install_dir} ${mariadb_data_dir}
  popd

  generate_my_cnf_mariadb ${mariadb_install_dir} ${mariadb_data_dir}
  config_my_cnf_scenario /etc/my.cnf ${server_scenario} ${Mem}

  ${mariadb_install_dir}/scripts/mysql_install_db --user=mysql --basedir=${mariadb_install_dir} --datadir=${mariadb_data_dir}

  chown mysql:mysql -R ${mariadb_data_dir}
  [ -d "/etc/mysql" ] && /bin/mv /etc/mysql{,_bk}
  svc_start mysqld
  add_to_path ${mariadb_install_dir}/bin

  setup_mariadb_root ${mariadb_install_dir} ${dbrootpwd} ${root_cmd}

  post_install_db ${mariadb_install_dir} mariadb ${mariadb_data_dir}
  # Keep service running - install.sh will handle final service check
}
