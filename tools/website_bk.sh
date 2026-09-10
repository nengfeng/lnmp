#!/bin/bash
# BLOG:  https://github.com/nengfeng/lnmp
#
#

. ../options.conf

WebSite=$1
LogFile=${backup_dir}/web.log
NewFile=${backup_dir}/Web_${WebSite}_$(date +%Y%m%d_%H).tgz
[ ! -e "${backup_dir}" ] && mkdir -p ${backup_dir}
chmod 700 ${backup_dir} 2>/dev/null
[ ! -e "${wwwroot_dir}/${WebSite}" ] && { echo "[${wwwroot_dir}/${WebSite}] not exist" >> ${LogFile} ;  exit 1 ; }

if [ "$(du -sm "${wwwroot_dir}/${WebSite}" | awk '{print $1}')" -lt "${web_archive_max_mb:-1024}" ]; then
  # Expire backups by AGE, not by exact calendar date - see db_bk.sh
  if [ "${expired_days}" -gt 0 ] 2>/dev/null; then
    ExpiredList=$(find "${backup_dir}" -maxdepth 1 -type f -name "Web_${WebSite}_*.tgz" -mtime +${expired_days} -print -exec rm -f {} + 2>/dev/null)
    [ -n "${ExpiredList}" ] && echo "Deleted expired backups: ${ExpiredList}" >> ${LogFile}
  fi

  if [ -e "${NewFile}" ]; then
    echo "[${NewFile}] The Backup File is exists, Can't Backup" >> ${LogFile}
  else
    pushd ${wwwroot_dir} > /dev/null
    if tar czf "${NewFile}" "./${WebSite}" >> ${LogFile} 2>&1 && [ -s "${NewFile}" ]; then
      chmod 600 "${NewFile}"
      echo "[${NewFile}] Backup success ">> ${LogFile}
      popd > /dev/null
    else
      echo "[${NewFile}] Backup FAILED (tar error)" >> "${LogFile}"
      rm -f "${NewFile}"
      popd > /dev/null
      exit 1
    fi
  fi
else
  # Site is too large to archive: keep a synced mirror under its own subdir
  # (${backup_dir}/${WebSite}). Both paths carry a trailing slash so
  # --delete is scoped to the site's mirror only - it must NEVER prune the
  # shared ${backup_dir}, which also holds DB_*.tgz and other Web_* archives.
  site_mirror="${backup_dir}/${WebSite}"
  mkdir -p "${site_mirror}"
  rsync -crazP --delete "${wwwroot_dir}/${WebSite}/" "${site_mirror}/" || {
    echo "[${wwwroot_dir}/${WebSite}] rsync backup FAILED" >> "${LogFile}"
    exit 1
  }
fi
