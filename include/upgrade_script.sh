#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Upgrade_Script() {
  pushd ${current_dir} > /dev/null
  latest_md5=$(curl --connect-timeout 3 -m 5 -s "https://raw.githubusercontent.com/nengfeng/lnmp/main/md5sum.txt" | grep lnmp.tar.gz | awk '{print $1}' || true)
  [ ! -e README.md ] && ois_flag=n
  if [ "${script_md5}" != "${latest_md5}" ]; then
    UPGRADE_TMP_DIR=$(mktemp -d /tmp/lnmp_upgrade.XXXXXX)
    trap "rm -rf $UPGRADE_TMP_DIR" EXIT
    /bin/mv options.conf $UPGRADE_TMP_DIR/
    sed -i '/current_dir=/d' $UPGRADE_TMP_DIR/options.conf
    # Download from GitHub (lnmp.tar.gz is generated at release time)
    wget -qc "https://github.com/nengfeng/lnmp/archive/main.tar.gz" -O $UPGRADE_TMP_DIR/lnmp.tar.gz
    tar xzf $UPGRADE_TMP_DIR/lnmp.tar.gz -C $UPGRADE_TMP_DIR/
    /bin/cp -R $UPGRADE_TMP_DIR/lnmp/* ${current_dir}/
    /bin/rm -rf $UPGRADE_TMP_DIR/lnmp
    IFS=$'\n'
    for L in $(grep -vE '^#|^$' $UPGRADE_TMP_DIR/options.conf)
    do
      IFS=$IFS_old
      Key="$(echo ${L%%=*})"
      Value="$(echo ${L#*=})"
      sed -i "s|^${Key}=.*|${Key}=${Value}|" ./options.conf
    done
    rm -rf $UPGRADE_TMP_DIR
    trap - EXIT
    [[ "${ois_flag}" == "n" ]] && rm -f ss.sh LICENSE README.md
    sed -i "s@^script_md5=.*@script_md5=${latest_md5}@" ./options.conf
    if [ -e "${php_install_dir}/sbin/php-fpm" ]; then
      [ -n "$(grep ^cgi.fix_pathinfo=0 ${php_install_dir}/etc/php.ini)" ] && sed -i 's@^cgi.fix_pathinfo.*@;&@' ${php_install_dir}/etc/php.ini || true
      for php_ver in 83 84 85; do
        [ -e "/usr/local/php${php_ver}/etc/php.ini" ] && sed -i 's@^cgi.fix_pathinfo=0@;&@' /usr/local/php${php_ver}/etc/php.ini 2>/dev/null
      done
    fi
    [ -e "/lib/systemd/system/php-fpm.service" ] && { sed -i 's@^PrivateTmp.*@#&@g' /lib/systemd/system/php-fpm.service; svc_daemon_reload; }
    echo
    echo "${CSUCCESS}Congratulations! LNMP upgrade successful! ${CEND}"
    echo
  else
    echo "${CWARNING}Your LNMP already has the latest version or does not need to be upgraded! ${CEND}"
  fi
  popd > /dev/null
}
