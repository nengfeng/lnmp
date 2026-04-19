#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_phpMyAdmin() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    pushd ${current_dir}/src > /dev/null
    tar xzf phpMyAdmin-${phpmyadmin_ver}-all-languages.tar.gz
    /bin/mv phpMyAdmin-${phpmyadmin_ver}-all-languages ${wwwroot_dir}/default/phpMyAdmin
    /bin/cp ${wwwroot_dir}/default/phpMyAdmin/{config.sample.inc.php,config.inc.php}
    mkdir ${wwwroot_dir}/default/phpMyAdmin/{upload,save}
    sed -i "s@UploadDir.*@UploadDir'\] = 'upload';@" ${wwwroot_dir}/default/phpMyAdmin/config.inc.php
    sed -i "s@SaveDir.*@SaveDir'\] = 'save';@" ${wwwroot_dir}/default/phpMyAdmin/config.inc.php
    sed -i "s@host'\].*@host'\] = '127.0.0.1';@" ${wwwroot_dir}/default/phpMyAdmin/config.inc.php
    sed -i "s@blowfish_secret.*;@blowfish_secret\'\] = \'$(head -c100 /dev/urandom | base64 | head -c 32)\';@" ${wwwroot_dir}/default/phpMyAdmin/config.inc.php
    # Set secure permissions for phpMyAdmin
    chmod 755 ${wwwroot_dir}/default/phpMyAdmin
    chown ${run_user}:${run_group} ${wwwroot_dir}/default/phpMyAdmin
    chmod 755 ${wwwroot_dir}/default/phpMyAdmin/{upload,save}
    chown ${run_user}:${run_group} ${wwwroot_dir}/default/phpMyAdmin/{upload,save}
    
    # Ensure proper permissions for subdirectories and files
    find ${wwwroot_dir}/default/phpMyAdmin -type d -exec chmod 755 {} \; 2>/dev/null
    find ${wwwroot_dir}/default/phpMyAdmin -type f -exec chmod 644 {} \; 2>/dev/null
    popd > /dev/null
  fi
}
