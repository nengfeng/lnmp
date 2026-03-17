#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: PHP 8.3 installer (delegates to unified php.sh)

. include/php.sh

Install_PHP83() {
  Install_PHP "${php83_ver}" "${php83_with_ssl}"
}
