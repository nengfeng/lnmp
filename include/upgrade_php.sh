#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

. ./include/ext-common.sh

# Default checksum verification setting
VERIFY_CHECKSUM="${VERIFY_CHECKSUM:-yes}"

# Roll back a failed PHP upgrade by restoring the pre-upgrade backup.
# Replaces the old `rm -rf php_install_dir && cp -a backup php_install_dir`
# sequence: the old form was irreversible -- if the restore cp failed (disk
# full, permissions), php_install_dir had already been deleted with no way
# back. Here the broken install is moved aside first (mv is reversible), so a
# failed restore can still be undone by moving the original directory back.
# Usage: _php_rollback  (relies on $php_install_dir and $backup_php_dir)
_php_rollback() {
  local broken="${php_install_dir}.broken_$(date +%m%d%H%M%S)"
  # Move the broken install aside instead of deleting it.
  if [ -e "${php_install_dir}" ]; then
    /bin/mv -f "${php_install_dir}" "${broken}" || {
      echo "${CFAILURE}Rollback aborted: could not move ${php_install_dir} aside.${CEND}"
      echo "${CYELLOW}Restore manually from ${BACKUP_DIR}.${CEND}"
      return 1
    }
  fi
  # Restore the backup into place.
  if ! cp -a "${backup_php_dir}" "${php_install_dir}"; then
    echo "${CFAILURE}Rollback restore failed! Reverting the move so nothing is lost.${CEND}"
    [ -e "${broken}" ] && /bin/mv -f "${broken}" "${php_install_dir}" 2>/dev/null
    echo "${CYELLOW}Restore manually from ${BACKUP_DIR}.${CEND}"
    return 1
  fi
  svc_start php-fpm
  echo "${CYELLOW}Rolled back. Broken install kept at ${broken} for inspection.${CEND}"
  return 0
}

# Restore a temporarily hidden /usr/local/include/iconv.h.  Older LNMP
# releases installed GNU libiconv into /usr/local; its iconv.h shadows glibc's
# and #defines iconv_open to libiconv_open, while this build is configured for
# glibc iconv, so bundled libgd fails with undefined references to libiconv_*.
_php_restore_iconv_header() {
  [ -n "${_php_iconv_bak:-}" ] && /bin/mv -f "${_php_iconv_bak}" "${_php_iconv_hdr}" 2>/dev/null
  _php_iconv_bak=""
}

# Is <version> inside the supported PHP minor window (8.PHP_MINOR_MIN ..
# 8.PHP_MINOR_MAX)?  The upgrade path reuses the installed configure command,
# so a minor bump (e.g. 8.4 -> 8.5) is allowed as long as the target minor is
# one this LNMP release supports.
_php_version_is_supported() {
  local ver=$1 minor
  [[ "${ver}" =~ ^8\.([0-9]+)\.([0-9]+)$ ]] || return 1
  minor=$((10#${BASH_REMATCH[1]}))
  php_tag_is_supported "8${minor}"
}

# Rebuild the PHP extension flags from the installed php.d ini files.
# options.conf does not persist the install-time --php_extensions choice, and
# after a minor bump (8.4 -> 8.5, new extension ABI) the old .so files are
# invisible to the new binary and must be recompiled.  Reading php.d is also
# deliberate: the old php binary can itself be broken (e.g. libzip soname
# changed under it), while the ini files are plain text.
_detect_enabled_php_exts() {
  local ini_dir="${php_install_dir}/etc/php.d" ini ext flag
  [ -d "${ini_dir}" ] || return 0
  for ini in "${ini_dir}"/*.ini; do
    [ -f "${ini}" ] || continue
    case "${ini##*/}" in
      00-ioncube.ini)   ext=ioncube ;;
      03-imagick.ini)   ext=imagick ;;
      04-fileinfo.ini)  ext=fileinfo ;;
      04-imap.ini)      ext=imap ;;
      04-ldap.ini)      ext=ldap ;;
      04-phalcon.ini)   ext=phalcon ;;
      04-yaf.ini)       ext=yaf ;;
      05-redis.ini)     ext=redis ;;
      05-memcached.ini) ext=memcached ;;
      05-memcache.ini)  ext=memcache ;;
      06-swoole.ini)    ext=swoole ;;
      07-mongodb.ini)   ext=mongodb ;;
      08-xdebug.ini)    ext=xdebug ;;
      *) continue ;;
    esac
    flag="${EXT_FLAGS[$ext]}"
    [ -n "${flag}" ] && printf -v "${flag}" 1
  done
}

# Original configure command for the installed PHP.  Prefer `php -i`; fall
# back to `php-config --configure-options` when the old php binary cannot run
# (libzip/other soname bumps).  php-config is a shell script and still works.
_php_configure_command() {
  local cmd
  cmd=$(${php_install_dir}/bin/php -i 2>/dev/null | grep 'Configure Command' | awk -F'=>' '{print $2}' | sed 's/^ *//')
  if [ -z "${cmd}" ]; then
    cmd="./configure $(${php_install_dir}/bin/php-config --configure-options 2>/dev/null)"
  fi
  printf '%s' "${cmd}"
}

Upgrade_PHP() {
  pushd ${current_dir}/src > /dev/null
  [ ! -e "${php_install_dir}" ] && echo "${CWARNING}PHP is not installed on your system! ${CEND}" && exit 1
  
  OLD_php_ver=$(${php_install_dir}/bin/php-config --version)
  pythonCtl=python
  command -v python3 > /dev/null 2>&1 && pythonCtl=python3
  Latest_php_ver=$(curl --connect-timeout 2 -m 3 -s https://www.php.net/releases/active.php | ${pythonCtl} -mjson.tool | awk '/version/{print $2}' | sed 's/"//g' | grep "${OLD_php_ver%.*}")
  # Fallback when the php.net API is unreachable: use the version recorded in
  # versions.txt for the installed minor series (e.g. 8.4 -> ${php84_ver}),
  # instead of a hardcoded 8.3.20 that silently drifts as support moves on.
  # Indirect expansion maps the minor "8.4" to the php84_ver variable.
  if [ -z "${Latest_php_ver}" ]; then
    local _pma_minor="$(printf '%s' "${OLD_php_ver%.*}" | tr -d '.')"
    local _pma_var="php${_pma_minor}_ver"
    Latest_php_ver="${!_pma_var:-8.3.20}"
  fi
  echo
  echo "Current PHP Version: ${CMSG}$OLD_php_ver${CEND}"

  # Capture the extension set before the install tree is replaced.
  _detect_enabled_php_exts
  
  while :; do echo
    [ "${php_flag}" != 'y' ] && read -e -p "Please input upgrade PHP Version(Default: $Latest_php_ver): " NEW_php_ver
    NEW_php_ver=${NEW_php_ver:-${Latest_php_ver}}
    if _php_version_is_supported "${NEW_php_ver}"; then
      local file_name="php-${NEW_php_ver}.tar.gz"
      if [ ! -s "${file_name}" ]; then
        echo "Downloading PHP ${NEW_php_ver}..."
        src_url="https://www.php.net/distributions/${file_name}"
        Download_src
        if [ -s "${file_name}" ]; then
          verify_php_sha256 "${file_name}" "${NEW_php_ver}" || {
            echo "${CYELLOW}Checksum verification failed, re-downloading from php.net...${CEND}"
            rm -f "${file_name}"
            src_url="https://www.php.net/distributions/${file_name}"
            Download_src
          }
        fi
      else
        # A cached archive must be verified too, otherwise a truncated or
        # corrupted tarball from an earlier interrupted run would skip the
        # checksum entirely. On mismatch, delete it and fall through to a
        # fresh download.
        if ! verify_php_sha256 "${file_name}" "${NEW_php_ver}"; then
          echo "${CYELLOW}Cached ${file_name} failed checksum verification, re-downloading...${CEND}"
          rm -f "${file_name}"
          src_url="https://www.php.net/distributions/${file_name}"
          Download_src
          if [ -s "${file_name}" ]; then
            verify_php_sha256 "${file_name}" "${NEW_php_ver}" || {
              echo "${CYELLOW}Checksum still failing after re-download, re-downloading from php.net...${CEND}"
              rm -f "${file_name}"
              src_url="https://www.php.net/distributions/${file_name}"
              Download_src
            }
          fi
        fi
      fi
      if [ -s "${file_name}" ]; then
        echo "Download [${CMSG}${file_name}${CEND}] successfully! "
      else
        echo "${CWARNING}PHP version does not exist or download failed! ${CEND}"
      fi
      break
    else
      echo "${CWARNING}input error! ${CEND}Please input a supported version '${CMSG}8.${PHP_MINOR_MIN}.xx ~ 8.${PHP_MINOR_MAX}.xx${CEND}'"
      [[ "${php_flag}" == y ]] && exit
    fi
  done

  # ========== 升级前备份（校验通过后再备份，避免无效输入也产生备份） ==========
  BACKUP_DIR="/data/backup/php_backup_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  echo "${CCYAN}Backing up PHP ${OLD_php_ver} to ${BACKUP_DIR}...${CEND}"

  # 备份并验证
  if ! cp -a "${php_install_dir}" "${BACKUP_DIR}/"; then
    echo "${CFAILURE}Backup failed! Aborting upgrade.${CEND}"
    rm -rf "${BACKUP_DIR}"
    exit 1
  fi

  # 验证备份完整性
  local backup_php_dir="${BACKUP_DIR}/$(basename "${php_install_dir}")"
  if [ ! -f "${backup_php_dir}/bin/php" ]; then
    echo "${CFAILURE}Backup verification failed! Aborting upgrade.${CEND}"
    rm -rf "${BACKUP_DIR}"
    exit 1
  fi
  echo "${CSUCCESS}Backup completed successfully.${CEND}"

  # 创建回滚脚本（使用硬编码路径）
  cat > "${BACKUP_DIR}/rollback.sh" << ROLLBACK_EOF
#!/bin/bash
echo "Rolling back PHP..."
svc_stop php-fpm
rm -rf "${php_install_dir}"
cp -a "${backup_php_dir}" "${php_install_dir}"
svc_start php-fpm
echo "PHP rolled back successfully"
ROLLBACK_EOF
  chmod +x "${BACKUP_DIR}/rollback.sh"
  # ======================================

  if [ -s "php-${NEW_php_ver}.tar.gz" ]; then
    echo "[${CMSG}php-${NEW_php_ver}.tar.gz${CEND}] found"
    if [ "${php_flag}" != 'y' ]; then
      echo "Press Ctrl+c to cancel or Press any key to continue..."
      char=$(get_char)
    fi
    if ! tar xzf php-${NEW_php_ver}.tar.gz; then
      echo "${CFAILURE}Extract failed: php-${NEW_php_ver}.tar.gz is corrupted or truncated. Upgrade aborted, nothing was changed.${CEND}"
      exit 1
    fi
    pushd php-${NEW_php_ver}
    if [ -e ext/openssl/openssl.c ] && ! grep -Eqi '^#ifdef RSA_SSLV23_PADDING' ext/openssl/openssl.c; then
      sed -i '/OPENSSL_SSLV23_PADDING/i#ifdef RSA_SSLV23_PADDING' ext/openssl/openssl.c
      sed -i '/OPENSSL_SSLV23_PADDING/a#endif' ext/openssl/openssl.c
    fi
    # Hide a stale GNU libiconv header for this build only.  The build uses
    # glibc iconv; the header is restored after make (and by the EXIT trap if
    # configure/make fails or the script is interrupted).
    _php_iconv_hdr="/usr/local/include/iconv.h"
    _php_iconv_bak=""
    if [ -f /usr/include/iconv.h ] && [ -f "${_php_iconv_hdr}" ] \
      && grep -q 'libiconv' "${_php_iconv_hdr}" 2>/dev/null; then
      _php_iconv_bak="${_php_iconv_hdr}.lnmp-bak"
      /bin/mv -f "${_php_iconv_hdr}" "${_php_iconv_bak}"
      trap _php_restore_iconv_header EXIT
    fi

    make clean || true
    export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig/:$PKG_CONFIG_PATH
    # Get original configure command and fix iconv settings.
    local configure_cmd
    configure_cmd=$(_php_configure_command)
    # Fix iconv: use glibc's iconv (bare --with-iconv, no GNU libiconv path/plug)
    configure_cmd=$(echo "${configure_cmd}" | sed 's|--with-iconv=[^ ]*|--with-iconv|g')
    # Force glibc iconv: do NOT link GNU libiconv even if present on the system
    if ! php_cv_iconv_errno=yes ac_cv_lib_iconv_libiconv_open=no bash -c "${configure_cmd}"; then
      echo "${CFAILURE}PHP configure failed! Upgrade aborted, nothing was changed.${CEND}"
      popd > /dev/null
      rm -rf php-${NEW_php_ver}
      exit 1
    fi
    # Guard make: an unchecked failure would let the verify step below run a
    # missing binary and misreport "Compilation verification failed".
    if ! make -j ${THREAD}; then
      echo "${CFAILURE}PHP compilation failed! Upgrade aborted, nothing was changed.${CEND}"
      popd > /dev/null
      rm -rf php-${NEW_php_ver}
      exit 1
    fi
    if [ -n "${_php_iconv_bak}" ]; then
      _php_restore_iconv_header
      trap - EXIT
    fi
    
    # ========== 【新增】编译后验证 ==========
    echo "Verifying compiled PHP binary..."
    if ! out=$("sapi/cli/php" -v 2>&1); then
      echo "${CFAILURE}Compilation verification failed! Rolling back...${CEND}"
      echo "${out}" | head -10
      # 注意：此时 php-fpm 还在运行，不需要启动
      popd > /dev/null
      rm -rf php-${NEW_php_ver}
      echo "${CYELLOW}To rollback, run: ${BACKUP_DIR}/rollback.sh${CEND}"
      exit 1
    fi
    # ========================================
    
    echo "Stoping php-fpm..."
    if ! svc_stop php-fpm; then
      echo "${CFAILURE}Failed to stop php-fpm! Aborting before replacing the running binary.${CEND}"
      echo "${CYELLOW}php-fpm is still running; make install would hit 'Text file busy'.${CEND}"
      echo "${CYELLOW}Stop it manually (systemctl stop php-fpm) then re-run the upgrade.${CEND}"
      popd > /dev/null || true
      rm -rf php-${NEW_php_ver}
      exit 1
    fi
    if ! make install; then
      echo "${CFAILURE}PHP installation failed! Rolling back...${CEND}"
      _php_rollback
      exit 1
    fi

    # A minor bump changes the extension ABI, so the old .so files no longer
    # load. Recompile every extension the old install had enabled. Same-minor
    # patch upgrades keep the same ABI and skip this extra rebuild.
    if [ "${OLD_php_ver%.*}" != "${NEW_php_ver%.*}" ]; then
      echo "Reinstalling PHP extensions..."
      if ! install_enabled_exts; then
        echo "${CFAILURE}PHP extension install failed! Rolling back...${CEND}"
        _php_rollback
        popd > /dev/null || true
        rm -rf php-${NEW_php_ver}
        exit 1
      fi
    fi
    
    # ========== 【新增】安装后验证 ==========
    echo "Verifying installed PHP..."
    if ! "${php_install_dir}/bin/php" -v > /dev/null 2>&1; then
      echo "${CFAILURE}Installation verification failed! Rolling back...${CEND}"
      _php_rollback
      exit 1
    fi

    # 验证服务是否正常
    echo "Starting php-fpm..."
    svc_start php-fpm
    sleep 2
    if ! svc_is_active php-fpm; then
      echo "${CWARNING}php-fpm failed to start! Rolling back...${CEND}"
      _php_rollback
      exit 1
    fi
    # ========================================
    
    popd > /dev/null || true
    echo "You have ${CMSG}successfully${CEND} upgraded from ${CWARNING}$OLD_php_ver${CEND} to ${CWARNING}${NEW_php_ver}${CEND}"
    echo "${CYELLOW}Backup location: ${BACKUP_DIR}${CEND}"
    echo "${CYELLOW}To rollback, run: ${BACKUP_DIR}/rollback.sh${CEND}"
    rm -rf php-${NEW_php_ver}
  fi
  popd > /dev/null || true
}
