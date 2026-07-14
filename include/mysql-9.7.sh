#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: MySQL 9.7 installer (delegates to unified mysql.sh)

. include/mysql.sh

Install_MySQL97() {
  Install_MySQL "${mysql97_ver}" "generate_my_cnf_mysql8" "no"
}
