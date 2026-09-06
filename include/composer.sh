#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_composer() {
  if [ -e "${php_install_dir}/bin/phpize" ]; then
    if [ -e "/usr/local/bin/composer" ]; then
      echo "${CWARNING}PHP Composer already installed! ${CEND}"
    else
      pushd ${current_dir}/src > /dev/null
      local composer_dl=0
      if [[ "${OUTIP_STATE}"x == "CN"x ]]; then
        if wget -c https://mirrors.aliyun.com/composer/composer.phar -O /usr/local/bin/composer > /dev/null 2>&1; then
          composer_dl=1
        fi
      else
        if wget -c https://getcomposer.org/composer.phar -O /usr/local/bin/composer > /dev/null 2>&1; then
          composer_dl=1
        fi
      fi
      # wget -O creates the target even on failure; verify size + runability
      if [ ${composer_dl} == 1 ] && [ -s /usr/local/bin/composer ] \
        && ${php_install_dir}/bin/php /usr/local/bin/composer --version > /dev/null 2>&1; then
        chmod +x /usr/local/bin/composer
        # packagist.phpcomposer.com has been dead for years; use Aliyun mirror
        [[ "${OUTIP_STATE}"x == "CN"x ]] && ${php_install_dir}/bin/php /usr/local/bin/composer config -g repos.packagist composer https://mirrors.aliyun.com/composer/
        echo; echo "${CSUCCESS}PHP Composer installed successfully! ${CEND}"
      else
        rm -f /usr/local/bin/composer
        echo; echo "${CFAILURE}PHP Composer install failed, Please try again! ${CEND}"
      fi
      popd > /dev/null
    fi
  fi
}

Uninstall_composer() {
  if [ -e "/usr/local/bin/composer" ]; then
    rm -f /usr/local/bin/composer
    echo; echo "${CMSG}Composer uninstall completed${CEND}";
  else
    echo; echo "${CWARNING}Composer does not exist! ${CEND}"
  fi
}
