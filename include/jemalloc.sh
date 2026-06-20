#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_Jemalloc() {
  if [ ! -e "/usr/local/lib/libjemalloc.so" ]; then
    pushd ${current_dir}/src > /dev/null
    tar xjf jemalloc-${jemalloc_ver}.tar.bz2
    pushd jemalloc-${jemalloc_ver} > /dev/null
    ./configure --prefix=/usr/local
    compile_and_install
    popd > /dev/null
    if [ -f "/usr/local/lib/libjemalloc.so" ]; then
      add_lib_path /usr/local/lib
      success_msg "jemalloc"
      cleanup_src jemalloc-${jemalloc_ver}
    else
      fail_msg "jemalloc"
    fi
    popd > /dev/null
  fi
}
