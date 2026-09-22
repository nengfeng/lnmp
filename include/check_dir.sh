#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

# check MySQL dir
[ -d "${mysql_install_dir}/support-files" ] && { db_install_dir=${mysql_install_dir}; db_data_dir=${mysql_data_dir}; }
[ -d "${mariadb_install_dir}/support-files" ] && { db_install_dir=${mariadb_install_dir}; db_data_dir=${mariadb_data_dir}; }

# check Nginx dir
[ -e "${nginx_install_dir}/sbin/nginx" ] && web_install_dir=${nginx_install_dir}
[ -e "${tengine_install_dir}/sbin/nginx" ] && web_install_dir=${tengine_install_dir}
[ -e "${openresty_install_dir}/nginx/sbin/nginx" ] && web_install_dir=${openresty_install_dir}/nginx

# Decide which engine backs up a named database.
# Usage: detect_backup_engine <mysql_or_mariadb_install_dir> <pgsql_install_dir>
# Prints "mysql", "pgsql" or "none"; returns 1 only for "none".
#
# MySQL/MariaDB wins when both trees exist, because that is what the backup
# path has always driven. The PostgreSQL arm is the whole point of this
# function: db_install_dir is only ever assigned by the two checks above, so
# on a PostgreSQL-only host it is empty and every ${db_install_dir}/bin/mysql
# reference in tools/db_bk.sh collapsed to /bin/mysql. The existence probe
# then failed, "[dbname] not exist" was logged, and backup.sh flagged the run
# as failed - PostgreSQL databases were never backed up at all.
detect_backup_engine() {
  local mysql_dir=$1 pgsql_dir=$2
  if [ -n "${mysql_dir}" ] && [ -x "${mysql_dir}/bin/mysqldump" ]; then
    echo "mysql"
  elif [ -n "${pgsql_dir}" ] && [ -x "${pgsql_dir}/bin/pg_dump" ] && [ -x "${pgsql_dir}/bin/psql" ]; then
    echo "pgsql"
  else
    echo "none"
    return 1
  fi
}
