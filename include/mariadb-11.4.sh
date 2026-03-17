#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: MariaDB 11.4 installer (delegates to unified mariadb.sh)

. include/mariadb.sh

Install_MariaDB114() {
  Install_MariaDB "${mariadb114_ver}" "mariadb"
}
