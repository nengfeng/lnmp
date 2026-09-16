#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Upgrade_phpMyAdmin() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${wwwroot_dir}/default/phpMyAdmin" ] && echo "${CWARNING}phpMyAdmin is not installed on your system! ${CEND}" && exit 1
  OLD_phpmyadmin_ver=$(grep Version ${wwwroot_dir}/default/phpMyAdmin/README | awk '{print $2}')
  Latest_phpmyadmin_ver=$(curl --connect-timeout 2 -m 3 -s https://www.phpmyadmin.net/files/ | grep -oP 'href="/files/[0-9]+\.[0-9]+\.[0-9]+/"' | head -1 | sed 's/.*\/files\/\([0-9.]*\)\/.*/\1/')
  Latest_phpmyadmin_ver=${Latest_phpmyadmin_ver:-5.2.2}
  echo "Current phpMyAdmin Version: ${CMSG}${OLD_phpmyadmin_ver}${CEND}"
  while :; do echo
    [ "${phpmyadmin_flag}" != 'y' ] && read -e -p "Please input upgrade phpMyAdmin Version(default: ${Latest_phpmyadmin_ver}): " NEW_phpmyadmin_ver
    NEW_phpmyadmin_ver=${NEW_phpmyadmin_ver:-${Latest_phpmyadmin_ver}}
    if [ "${NEW_phpmyadmin_ver}" != "${OLD_phpmyadmin_ver}" ]; then
      [ ! -s "phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz" ] && { wget -c "https://files.phpmyadmin.net/phpMyAdmin/${NEW_phpmyadmin_ver}/phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz" > /dev/null 2>&1 || rm -f "phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz"; }
      if [ -s "phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz" ]; then
        gzip -t "phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz" 2>/dev/null || \
          { echo "${CFAILURE}phpMyAdmin archive is corrupted, re-downloading...${CEND}"; rm -f "phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz"; wget -c "https://files.phpmyadmin.net/phpMyAdmin/${NEW_phpmyadmin_ver}/phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz" > /dev/null 2>&1; }
        # Re-verify what the re-download produced: without this a second corrupt
        # archive was still announced as a successful download and only blew up
        # later, at extraction time.
        if ! gzip -t "phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz" 2>/dev/null; then
          rm -f "phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz"
          echo "${CWARNING}phpMyAdmin-${NEW_phpmyadmin_ver} is still corrupt, please try again! ${CEND}"
          continue
        fi
        echo "Download [${CMSG}phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz${CEND}] successfully! "
        break
      else
        echo "${CWARNING}phpMyAdmin version does not exist! ${CEND}"
      fi
    else
      echo "${CWARNING}input error! Upgrade phpMyAdmin version is the same as the old version${CEND}"
      exit
    fi
  done

  if [ -s "phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz" ]; then
    echo "[${CMSG}phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz${CEND}] found"
    if [ "${phpmyadmin_flag}" != 'y' ]; then
      echo "Press Ctrl+c to cancel or Press any key to continue..."
      char=$(get_char)
    fi
    # Verify extraction BEFORE removing the old installation, so a corrupt
    # archive cannot leave the site with no phpMyAdmin at all
    tar xzf phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages.tar.gz || {
      echo "${CFAILURE}Extraction failed, old installation is intact. ${CEND}"
      exit 1
    }
    [ -d "phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages" ] || {
      echo "${CFAILURE}Extracted archive missing expected directory, old installation is intact. ${CEND}"
      exit 1
    }
    # Replace the old install by moving it aside first (rename is reversible),
    # then moving the new tree into place. If the move fails (cross-device,
    # disk full), move the old tree back so the site is never left without
    # phpMyAdmin. Never rm -rf the old install before the new one is in place.
    local pma_ts=$(date +%m%d%H%M%S)
    /bin/mv ${wwwroot_dir}/default/phpMyAdmin ${wwwroot_dir}/default/phpMyAdmin.old${pma_ts} || \
      { echo "${CFAILURE}Failed to move old phpMyAdmin aside, upgrade aborted. ${CEND}"; exit 1; }
    if ! /bin/mv phpMyAdmin-${NEW_phpmyadmin_ver}-all-languages ${wwwroot_dir}/default/phpMyAdmin; then
      /bin/mv ${wwwroot_dir}/default/phpMyAdmin.old${pma_ts} ${wwwroot_dir}/default/phpMyAdmin
      echo "${CFAILURE}Failed to move new phpMyAdmin into place, old install restored. ${CEND}"
      exit 1
    fi
    /bin/cp ${wwwroot_dir}/default/phpMyAdmin/{config.sample.inc.php,config.inc.php}
    mkdir ${wwwroot_dir}/default/phpMyAdmin/{upload,save}
    sed -i "s@UploadDir.*@UploadDir'\] = 'upload';@" ${wwwroot_dir}/default/phpMyAdmin/config.inc.php
    sed -i "s@SaveDir.*@SaveDir'\] = 'save';@" ${wwwroot_dir}/default/phpMyAdmin/config.inc.php
    sed -i "s@host'\].*@host'\] = '127.0.0.1';@" ${wwwroot_dir}/default/phpMyAdmin/config.inc.php
    sed -i "s@blowfish_secret.*;@blowfish_secret\'\] = \'$(openssl rand -base64 32 | head -c 32)\';@" ${wwwroot_dir}/default/phpMyAdmin/config.inc.php
    # Set secure permissions for upgraded phpMyAdmin
    chmod 755 ${wwwroot_dir}/default/phpMyAdmin
    chown ${run_user}:${run_group} ${wwwroot_dir}/default/phpMyAdmin
    chmod 755 ${wwwroot_dir}/default/phpMyAdmin/{upload,save}
    chown ${run_user}:${run_group} ${wwwroot_dir}/default/phpMyAdmin/{upload,save}
    
    # Ensure proper permissions for subdirectories and files
    find ${wwwroot_dir}/default/phpMyAdmin -type d -exec chmod 755 {} \; 2>/dev/null
    find ${wwwroot_dir}/default/phpMyAdmin -type f -exec chmod 644 {} \; 2>/dev/null
    echo "You have ${CMSG}successfully${CEND} upgrade from ${CWARNING}$OLD_phpmyadmin_ver${CEND} to ${CWARNING}$NEW_phpmyadmin_ver${CEND}"
  fi
  popd > /dev/null
}
