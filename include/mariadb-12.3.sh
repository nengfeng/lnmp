#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: MariaDB 12.3 installer (delegates to unified mariadb.sh)

. include/mariadb.sh

Install_MariaDB123() {
  Install_MariaDB "${mariadb123_ver}" "mariadb"
}
