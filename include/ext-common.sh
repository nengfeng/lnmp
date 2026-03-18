#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: Unified PHP extension install/uninstall functions
#
# Extension registry - maps extension names to their script files and install functions.
# Format: ext_script|install_func|uninstall_func [extra_install_func]
#
# Some extensions (imagick, gmagick) require installing a base library first,
# then the PECL extension. The extra_install_func handles that.

declare -A EXT_SCRIPTS=(
  [ioncube]="ioncube.sh|Install_ionCube|Uninstall_ionCube"
  [imagick]="ImageMagick.sh|Install_ImageMagick|Install_pecl_imagick|Uninstall_ImageMagick|Uninstall_pecl_imagick"
  [gmagick]="GraphicsMagick.sh|Install_GraphicsMagick|Install_pecl_gmagick|Uninstall_GraphicsMagick|Uninstall_pecl_gmagick"
  [fileinfo]="pecl_fileinfo.sh|Install_pecl_fileinfo|Uninstall_pecl_fileinfo"
  [imap]="pecl_imap.sh|Install_pecl_imap|Uninstall_pecl_imap"
  [ldap]="pecl_ldap.sh|Install_pecl_ldap|Uninstall_pecl_ldap"
  [phalcon]="pecl_phalcon.sh|Install_pecl_phalcon|Uninstall_pecl_phalcon"
  [yaf]="pecl_yaf.sh|Install_pecl_yaf|Uninstall_pecl_yaf"
  [redis]="redis.sh|Install_pecl_redis|Uninstall_pecl_redis"
  [memcached]="memcached.sh|Install_pecl_memcached|Uninstall_pecl_memcached"
  [memcache]="memcached.sh|Install_pecl_memcache|Uninstall_pecl_memcache"
  [mongodb]="pecl_mongodb.sh|Install_pecl_mongodb|Uninstall_pecl_mongodb"
  [swoole]="pecl_swoole.sh|Install_pecl_swoole|Uninstall_pecl_swoole"
  [xdebug]="pecl_xdebug.sh|Install_pecl_xdebug|Uninstall_pecl_xdebug"
)

# Extension name to flag variable mapping
declare -A EXT_FLAGS=(
  [ioncube]=pecl_ioncube
  [imagick]=pecl_imagick
  [gmagick]=pecl_gmagick
  [fileinfo]=pecl_fileinfo
  [imap]=pecl_imap
  [ldap]=pecl_ldap
  [phalcon]=pecl_phalcon
  [yaf]=pecl_yaf
  [redis]=pecl_redis
  [memcached]=pecl_memcached
  [memcache]=pecl_memcache
  [mongodb]=pecl_mongodb
  [swoole]=pecl_swoole
  [xdebug]=pecl_xdebug
)

# Install a single PHP extension
# Usage: install_php_ext <ext_name>
install_php_ext() {
  local ext_name=$1
  local spec="${EXT_SCRIPTS[$ext_name]}"
  [ -z "$spec" ] && return

  local script=$(echo "$spec" | cut -d'|' -f1)
  local func1=$(echo "$spec" | cut -d'|' -f2)
  local func2=$(echo "$spec" | cut -d'|' -f3)

  . include/${script}
  ${func1} 2>&1 | tee -a ${current_dir}/install.log
  [[ -n "$func2" ]] && ${func2} 2>&1 | tee && ${current_dir}/install.log
}

# Uninstall a single PHP extension
# Usage: uninstall_php_ext <ext_name>
uninstall_php_ext() {
  local ext_name=$1
  local spec="${EXT_SCRIPTS[$ext_name]}"
  [ -z "$spec" ] && return

  local script=$(echo "$spec" | cut -d'|' -f1)
  local func_count=$(echo "$spec" | tr '|' '\n' | grep -c "^Uninstall_")

  . include/${script}
  # Uninstall functions are at fields 4+ (after script, install1, install2)
  local i=4
  while true; do
    local func=$(echo "$spec" | cut -d'|' -f${i})
    [ -z "$func" ] && break
    ${func}
    i=$((i+1))
  done
}

# Check if extension flag is set
# Usage: ext_enabled <ext_name>
# Returns 0 if enabled, 1 if not
ext_enabled() {
  local flag_name="${EXT_FLAGS[$1]}"
  [ -z "$flag_name" ] && return 1
  [[ "${!flag_name}" == 1 ]]
}

# Install all enabled PHP extensions
# Usage: install_enabled_exts [log_prefix]
install_enabled_exts() {
  for ext in "${!EXT_SCRIPTS[@]}"; do
    if ext_enabled "$ext"; then
      install_php_ext "$ext"
    fi
  done
}

# Uninstall all enabled PHP extensions
# Usage: uninstall_enabled_exts
uninstall_enabled_exts() {
  for ext in "${!EXT_SCRIPTS[@]}"; do
    if ext_enabled "$ext"; then
      uninstall_php_ext "$ext"
    fi
  done
}

# Reload PHP-FPM after extension changes
# Usage: reload_php_fpm
reload_php_fpm() {
  [ -e "${php_install_dir}/sbin/php-fpm" ] && svc_reload php-fpm yes
  [[ -n "${mphp_ver}" && -e "${php_install_dir}${mphp_ver}/sbin/php-fpm" ]] && svc_reload php${mphp_ver}-fpm yes
}
