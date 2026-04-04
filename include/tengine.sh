#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

. include/web-common.sh

Install_Tengine() {
  if [ -e "${nginx_install_dir}/sbin/nginx" ]; then
    echo "${CFAILURE}Nginx is already installed! Please uninstall Nginx first.${CEND}"
    return 1
  fi
  if [ -e "${openresty_install_dir}/nginx/sbin/nginx" ]; then
    echo "${CFAILURE}OpenResty is already installed! Please uninstall OpenResty first.${CEND}"
    return 1
  fi

  pushd ${current_dir}/src > /dev/null
  create_run_user

  install_web_server tengine ${tengine_ver} ${tengine_install_dir}
  post_install_web_server ${tengine_install_dir} "${tengine_install_dir}/sbin" ${server_scenario}

  popd > /dev/null
}
