#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: MariaDB 10.11 installer (delegates to unified mariadb.sh)

. include/mariadb.sh

Install_MariaDB1011() {
  Install_MariaDB "${mariadb1011_ver}" "mysql"
}
