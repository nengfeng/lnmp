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
    if [ ! -s "${UPGRADE_TMP_DIR}/lnmp.tar.gz" ] || ! tar xzf "${UPGRADE_TMP_DIR}/lnmp.tar.gz" -C "${UPGRADE_TMP_DIR}/"; then
      echo "${CFAILURE}LNMP upgrade failed: could not download or extract the package. Your files were not modified.${CEND}"
      popd > /dev/null
      return 1
    fi

    # GitHub branch archives extract to a single top-level dir named <repo>-<ref>
    # (here 'lnmp-main'), NOT 'lnmp'. Detect it rather than hardcoding, so a
    # future repo/ref rename can't break the overlay; verify it looks like a
    # real tree before touching any user files.
    new_root=$(find "${UPGRADE_TMP_DIR}" -mindepth 1 -maxdepth 1 -type d -print -quit)
    if [ -z "${new_root}" ] || [ ! -f "${new_root}/install.sh" ] || [ ! -f "${new_root}/options.conf" ]; then
      echo "${CFAILURE}LNMP upgrade failed: could not locate the extracted tree. Your files were not modified.${CEND}"
      popd > /dev/null
      return 1
    fi

    # Merge user settings into the NEW options.conf, then overlay the tree.
    # Use delete-and-append, NOT `sed s|||`: the sed replacement field expands
    # '&' to the whole match and '|' terminates the substitution — quoted
    # passwords like dbrootpwd='p&ss|word' (written by install.sh) get
    # corrupted. Keys absent from the new template (user-custom) are
    # preserved via the same append path. printf, not echo: echo eats
    # backslashes in values.
    /bin/cp -a ./options.conf "./options.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    grep -vE '^#|^$' ./options.conf | while IFS='=' read -r Key Value; do
      [[ "${Key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      [ -z "${Key}" ] && continue
      grep -v "^${Key}=" "${new_root}/options.conf" > "${new_root}/options.conf.new" 2>/dev/null \
        && mv "${new_root}/options.conf.new" "${new_root}/options.conf"
      printf '%s\n' "${Key}=${Value}" >> "${new_root}/options.conf"
    done
    /bin/cp -R "${new_root}/"* "${current_dir}/"
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
