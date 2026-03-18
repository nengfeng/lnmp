#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

. include/web-common.sh

Install_Nginx() {
  pushd ${current_dir}/src > /dev/null
  create_run_user

  install_web_server nginx ${nginx_ver} ${nginx_install_dir}
  post_install_web_server ${nginx_install_dir} "${nginx_install_dir}/sbin" ${server_scenario}

  popd > /dev/null
}
