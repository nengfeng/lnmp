#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

. include/web-common.sh

Install_OpenResty() {
  pushd ${current_dir}/src > /dev/null
  create_run_user

  # OpenResty needs extra linker option
  install_web_server openresty ${openresty_ver} ${openresty_install_dir} "-Wl,-u,pcre_version"

  # OpenResty has different directory structure
  post_install_web_server ${openresty_install_dir}/nginx ${openresty_install_dir}/nginx/sbin ${server_scenario}

  popd > /dev/null
}
