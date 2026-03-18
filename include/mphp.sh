#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_MPHP() {
  if [ -e "${php_install_dir}/sbin/php-fpm" ]; then
    if [ -e "${php_install_dir}${mphp_ver}/bin/phpize" ]; then
      echo "${CWARNING}PHP${mphp_ver} already installed! ${CEND}"
    else
      [ -e "/lib/systemd/system/php-fpm.service" ] && /bin/mv /lib/systemd/system/php-fpm.service{,_bk}
      php_install_dir=${php_install_dir}${mphp_ver}
      case "${mphp_ver}" in
        83)
          . include/php-8.3.sh
          Install_PHP83 2>&1 | tee -a ${current_dir}/install.log
          ;;
        84)
          . include/php-8.4.sh
          Install_PHP84 2>&1 | tee -a ${current_dir}/install.log
          ;;
        85)
          . include/php-8.5.sh
          Install_PHP85 2>&1 | tee -a ${current_dir}/install.log
          ;;
        *)
          echo "${CWARNING}PHP${mphp_ver} is not supported. Only PHP 8.3, 8.4, 8.5 are supported. ${CEND}"
          exit 1
          ;;
      esac
      if [ -e "${php_install_dir}/sbin/php-fpm" ]; then
        svc_stop php-fpm
        sed -i "s@/dev/shm/php-cgi.sock@/dev/shm/php${mphp_ver}-cgi.sock@" ${php_install_dir}/etc/php-fpm.conf
        [ -e "/lib/systemd/system/php-fpm.service" ] && /bin/mv /lib/systemd/system/php-fpm.service /lib/systemd/system/php${mphp_ver}-fpm.service
        [ -e "/lib/systemd/system/php-fpm.service_bk" ] && /bin/mv /lib/systemd/system/php-fpm.service{_bk,}
        svc_daemon_reload
        svc_enable php${mphp_ver}-fpm
        svc_enable php-fpm
        svc_start php-fpm
        svc_start php${mphp_ver}-fpm
        sed -i "s@${php_install_dir}/bin:@@" /etc/profile
      fi
    fi
  else
    echo "${CWARNING}To use the multiple PHP versions, You need to use PHP-FPM! ${CEND}"
  fi
}
