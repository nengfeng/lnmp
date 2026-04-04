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
  cnf_func=$2  # Global variable used by install_db_common
  local reset_master=${3:-no}

  local init_cmd="${mysql_install_dir}/bin/mysqld --initialize-insecure --user=mysql --basedir=${mysql_install_dir} --datadir=${mysql_data_dir}"
  local cleanup_func="cleanup_mysql_files"

  install_db_common \
    "mysql" \
    "${mysql_install_dir}" \
    "${mysql_data_dir}" \
    "${dbinstallmethod}" \
    "${boost_ver}" \
    "${THREAD}" \
    "${init_cmd}" \
    "${cleanup_func}" \
    "setup_mysql_root"
}
