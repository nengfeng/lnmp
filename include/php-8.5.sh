#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: PHP 8.5 installer (delegates to unified php.sh)

. include/php.sh

Install_PHP85() {
  Install_PHP "${php85_ver}" "${php85_with_ssl}"
}
