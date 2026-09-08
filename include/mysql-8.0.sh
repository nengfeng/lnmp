#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: MySQL 8.0 installer (delegates to unified mysql.sh)

. include/mysql.sh

Install_MySQL80() {
  # source builds pin the older boost; binary installs ignore it
  Install_MySQL "${mysql80_ver}" "generate_my_cnf_mysql80" "yes" "${boost_oldver}"
}
