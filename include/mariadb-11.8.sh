#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: MariaDB 11.8 installer (delegates to unified mariadb.sh)

. include/mariadb.sh

Install_MariaDB118() {
  Install_MariaDB "${mariadb118_ver}" "mariadb"
}
