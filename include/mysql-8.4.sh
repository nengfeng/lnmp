#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: MySQL 8.4 installer (delegates to unified mysql.sh)

. include/mysql.sh

Install_MySQL84() {
  # MySQL 8.4 bundles boost in the source (8.3+), so no boost argument
  Install_MySQL "${mysql84_ver}" "generate_my_cnf_mysql8" "no"
}
