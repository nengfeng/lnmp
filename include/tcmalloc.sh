#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_Tcmalloc() {
  if [ ! -e "/usr/local/lib/libtcmalloc.so" ]; then
    pushd ${current_dir}/src > /dev/null
    tar xzf gperftools-${tcmalloc_ver}.tar.gz
    pushd gperftools-${tcmalloc_ver} > /dev/null
    ./configure --prefix=/usr/local
    compile_and_install
    popd > /dev/null
    if [ -f "/usr/local/lib/libtcmalloc.so" ]; then
      add_lib_path /usr/local/lib
      success_msg "tcmalloc (gperftools)"
      cleanup_src gperftools-${tcmalloc_ver}
    else
      fail_msg "tcmalloc"
    fi
    popd > /dev/null
  fi
}