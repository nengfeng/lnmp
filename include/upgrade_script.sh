#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Upgrade_Script() {
  pushd ${current_dir} > /dev/null
  latest_md5=$(curl --connect-timeout 3 -m 5 -fsS "https://raw.githubusercontent.com/nengfeng/lnmp/main/md5sum.txt" 2>/dev/null | awk -v f="lnmp.tar.gz" '$2==f {print $1}')
  [ ! -e README.md ] && ois_flag=n
  if [ -z "${latest_md5}" ] || [ "${script_md5}" != "${latest_md5}" ]; then
    UPGRADE_TMP_DIR=$(mktemp -d /tmp/lnmp_upgrade.XXXXXX)
    trap 'rm -rf "${UPGRADE_TMP_DIR}"' EXIT

    # Download and extract FIRST; user files are only touched after the
    # new tree is verified good (a failed download previously deleted
    # options.conf via the EXIT trap and still reported success)
    wget -qc "https://github.com/nengfeng/lnmp/archive/main.tar.gz" -O "${UPGRADE_TMP_DIR}/lnmp.tar.gz"
    if [ ! -s "${UPGRADE_TMP_DIR}/lnmp.tar.gz" ] || ! tar xzf "${UPGRADE_TMP_DIR}/lnmp.tar.gz" -C "${UPGRADE_TMP_DIR}/" || [ ! -d "${UPGRADE_TMP_DIR}/lnmp" ]; then
      echo "${CFAILURE}LNMP upgrade failed: could not download or extract the package. Your files were not modified.${CEND}"
      popd > /dev/null
      return 1
    fi

    # Merge user settings into the NEW options.conf, then overlay the tree
    grep -vE '^#|^$' ./options.conf | while IFS='=' read -r Key Value; do
      [ -n "${Key}" ] && sed -i "s|^${Key}=.*|${Key}=${Value}|" "${UPGRADE_TMP_DIR}/lnmp/options.conf"
    done
    /bin/cp -R "${UPGRADE_TMP_DIR}/lnmp/"* "${current_dir}/"
    rm -rf "${UPGRADE_TMP_DIR}"
    trap - EXIT
    [[ "${ois_flag}" == "n" ]] && rm -f ss.sh LICENSE README.md
    [ -n "${latest_md5}" ] && sed -i "s@^script_md5=.*@script_md5=${latest_md5}@" ./options.conf
    if [ -e "${php_install_dir}/sbin/php-fpm" ]; then
      [ -n "$(grep ^cgi.fix_pathinfo=0 ${php_install_dir}/etc/php.ini)" ] && sed -i 's@^cgi.fix_pathinfo.*@;&@' ${php_install_dir}/etc/php.ini
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
