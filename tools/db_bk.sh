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

# Pick the engine first (see detect_backup_engine in include/check_dir.sh).
# Without this the script only ever asked MySQL, and a PostgreSQL-only box
# reported every database as missing.
DB_ENGINE=$(detect_backup_engine "${db_install_dir}" "${pgsql_install_dir}")
if [ "${DB_ENGINE}" == "none" ]; then
  echo "[${DBname}] no supported database engine found (set db/pgsql install dirs in options.conf)" >> "${LogFile}"
  exit 1
fi

if [ "${DB_ENGINE}" == "pgsql" ]; then
  # pg_hba.conf runs both "local" and 127.0.0.1 in md5 mode, so connect over
  # TCP with the stored password: this script runs as root, which is not the
  # postgres role and would fail peer auth. Listing datnames and grepping -
  # rather than interpolating ${DBname} into SQL - keeps a name containing a
  # quote from changing the query.
  DB_tmp=$(PGPASSWORD="${dbpostgrespwd}" "${pgsql_install_dir}/bin/psql" -h 127.0.0.1 -U postgres -d postgres -tAc "SELECT datname FROM pg_database" 2>/dev/null | grep -Fxq "${DBname}" && echo OK)
else
  DB_tmp=$(${db_install_dir}/bin/mysql -uroot -p"${dbrootpwd}" -N -B -e "SHOW DATABASES" 2>/dev/null | grep -Fxq "${DBname}" && echo OK)
fi
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
  # pg_dump has no completion footer of its own, so each engine gets the
  # command it actually speaks.
  if [ "${DB_ENGINE}" == "pgsql" ]; then
    PGPASSWORD="${dbpostgrespwd}" "${pgsql_install_dir}/bin/pg_dump" -h 127.0.0.1 -U postgres "${DBname}" > "${DumpFile}"
  else
    ${db_install_dir}/bin/mysqldump -uroot -p"${dbrootpwd}" --routines --events "${DBname}" > "${DumpFile}"
  fi
  if [ $? -ne 0 ] || [ ! -s "${DumpFile}" ]; then
    echo "[${DumpFile}] Backup FAILED (dump error or empty file)" >> "${LogFile}"
    rm -f "${DumpFile}"
    exit 1
  fi
  # A truncated dump is a silent time bomb: the archive lists clean and the
  # restore dies half-way through. mysqldump always ends with a
  # "-- Dump completed" comment, so a missing footer means the write never
  # finished (disk full, killed mid-run).
  #
  # pg_dump emits no such footer, so there is nothing to grep for - but it
  # does not need one: it writes through the redirect, so a full disk or a
  # killed run makes write() fail and pg_dump exits non-zero, which the check
  # above already rejects. The footer guard is therefore MySQL/MariaDB-only
  # on purpose, not an oversight.
  if [ "${DB_ENGINE}" == "mysql" ] && ! tail -n 5 "${DumpFile}" | grep -q -- "-- Dump completed"; then
    echo "[${DumpFile}] Backup FAILED (dump truncated: no 'Dump completed' footer)" >> "${LogFile}"
    rm -f "${DumpFile}"
    exit 1
  fi
  chmod 600 "${DumpFile}"
  pushd "${backup_dir}" > /dev/null
  # tar -t proves the archive is a structurally complete gzip, not just a
  # non-empty file - the last bytes of a tar are what a truncated write loses.
  if tar czf "${NewFile}" "${DumpFile##*/}" >> ${LogFile} 2>&1 && [ -s "${NewFile}" ] \
     && tar -tzf "${NewFile}" > /dev/null 2>&1; then
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
exit 0
