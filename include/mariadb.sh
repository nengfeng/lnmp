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

  local init_cmd="${mariadb_install_dir}/scripts/mysql_install_db --user=mysql --basedir=${mariadb_install_dir} --datadir=${mariadb_data_dir}"
  local cleanup_func="cleanup_mariadb_files"

  install_db_common \
    "mariadb" \
    "${mariadb_install_dir}" \
    "${mariadb_data_dir}" \
    "${dbinstallmethod}" \
    "${boost_oldver}" \
    "${THREAD}" \
    "${init_cmd}" \
    "${cleanup_func}" \
    "setup_mariadb_root"
}
