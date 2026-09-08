#!/bin/bash
# BLOG:  https://github.com/nengfeng/lnmp
#
#

. ../options.conf
. ../include/check_dir.sh

DBname=$1
LogFile=${backup_dir}/db.log
# One timestamp for both names: two separate $(date) calls can cross a
# second boundary, giving the .sql and .tgz different names, which makes
# the "[ -e NewFile ]" guard and the tar step disagree about the filename
Ts=$(date +%Y%m%d_%H%M%S)
DumpFile=${backup_dir}/DB_${DBname}_${Ts}.sql
NewFile=${backup_dir}/DB_${DBname}_${Ts}.tgz

[ ! -e "${backup_dir}" ] && mkdir -p ${backup_dir}
# Backups are plain-text copies of the database - keep them private
chmod 700 ${backup_dir} 2>/dev/null

DB_tmp=$(${db_install_dir}/bin/mysql -uroot -p"${dbrootpwd}" -N -B -e "SHOW DATABASES" 2>/dev/null | grep -Fxq "${DBname}" && echo OK)
[ -z "${DB_tmp}" ] && { echo "[${DBname}] not exist" >> "${LogFile}" ; exit 1 ; }

# Expire backups by AGE, not by exact calendar date. The old pattern only
# matched files stamped with the date exactly ${expired_days} days ago, so a
# skipped day (or a second run on the same day) left files behind forever and
# the disk filled up.
if [ "${expired_days}" -gt 0 ] 2>/dev/null; then
  ExpiredList=$(find "${backup_dir}" -maxdepth 1 -type f -name "DB_${DBname}_*.tgz" -mtime +${expired_days} -print -exec rm -f {} + 2>/dev/null)
  [ -n "${ExpiredList}" ] && echo "Deleted expired backups: ${ExpiredList}" >> ${LogFile}
fi

if [ -e "${NewFile}" ]; then
  echo "[${NewFile}] The Backup File is exists, Can't Backup" >> ${LogFile}
else
  ${db_install_dir}/bin/mysqldump -uroot -p"${dbrootpwd}" --routines --events "${DBname}" > "${DumpFile}"
  if [ $? -ne 0 ] || [ ! -s "${DumpFile}" ]; then
    echo "[${DumpFile}] Backup FAILED (dump error or empty file)" >> "${LogFile}"
    rm -f "${DumpFile}"
    exit 1
  fi
  chmod 600 "${DumpFile}"
  pushd "${backup_dir}" > /dev/null
  if tar czf "${NewFile}" "${DumpFile##*/}" >> ${LogFile} 2>&1 && [ -s "${NewFile}" ]; then
    chmod 600 "${NewFile}"
    echo "[${NewFile}] Backup success ">> ${LogFile}
    rm -f "${DumpFile}"
    popd > /dev/null
  else
    # tar failures used to be written off as success by the following echo
    echo "[${NewFile}] Backup FAILED (tar error)" >> "${LogFile}"
    rm -f "${NewFile}" "${DumpFile}"
    popd > /dev/null
    exit 1
  fi
fi
