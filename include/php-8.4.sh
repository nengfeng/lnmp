#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: PHP 8.4 installer (delegates to unified php.sh)

. include/php.sh

Install_PHP84() {
  Install_PHP "${php84_ver}" "${php84_with_ssl}"
}
