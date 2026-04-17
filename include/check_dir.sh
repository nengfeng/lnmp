#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

# check MySQL dir
[ -d "${mysql_install_dir}/support-files" ] && { db_install_dir=${mysql_install_dir}; db_data_dir=${mysql_data_dir}; } || true
[ -d "${mariadb_install_dir}/support-files" ] && { db_install_dir=${mariadb_install_dir}; db_data_dir=${mariadb_data_dir}; } || true

# check Nginx dir
[ -e "${nginx_install_dir}/sbin/nginx" ] && web_install_dir=${nginx_install_dir} || true
[ -e "${tengine_install_dir}/sbin/nginx" ] && web_install_dir=${tengine_install_dir} || true
[ -e "${openresty_install_dir}/nginx/sbin/nginx" ] && web_install_dir=${openresty_install_dir}/nginx || true
