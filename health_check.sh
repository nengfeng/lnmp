#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# LNMP Stack Health Check Script
# Usage: ./health_check.sh [--fix]

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

current_dir=$(dirname "$(readlink -f $0)")
pushd ${current_dir} > /dev/null

. ./options.conf
. ./include/color.sh
. ./include/common.sh
. ./include/check_dir.sh

fix_mode="${1}"

# Counters
total_checks=0
passed_checks=0
warn_checks=0
fail_checks=0

# ============================================
# Helper functions
# ============================================
check_header() {
  echo
  echo "${CCYAN}========================================${CEND}"
  echo "${CCYAN} $1${CEND}"
  echo "${CCYAN}========================================${CEND}"
}

check_pass() {
  total_checks=$((total_checks + 1))
  passed_checks=$((passed_checks + 1))
  echo "  ${CGREEN}✅ PASS${CEND} $1"
}

check_warn() {
  total_checks=$((total_checks + 1))
  warn_checks=$((warn_checks + 1))
  echo "  ${CYELLOW}⚠️  WARN${CEND} $1"
}

check_fail() {
  total_checks=$((total_checks + 1))
  fail_checks=$((fail_checks + 1))
  echo "  ${CFAILURE}❌ FAIL${CEND} $1"
}

# ============================================
# 1. Service Status
# ============================================
check_services() {
  check_header "Service Status"

  # Nginx/Tengine/OpenResty
  if [ -e "${nginx_install_dir}/sbin/nginx" ]; then
    if svc_is_active nginx; then
      check_pass "Nginx: running"
    else
      check_fail "Nginx: not running"
      [[ "${fix_mode}" == "--fix" ]] && { svc_start nginx; echo "    → attempted start"; }
    fi
  elif [ -e "${tengine_install_dir}/sbin/nginx" ]; then
    if svc_is_active nginx; then
      check_pass "Tengine: running"
    else
      check_fail "Tengine: not running"
    fi
  elif [ -e "${openresty_install_dir}/nginx/sbin/nginx" ]; then
    if svc_is_active nginx; then
      check_pass "OpenResty: running"
    else
      check_fail "OpenResty: not running"
    fi
  else
    check_warn "Web server: not installed"
  fi

  # PHP-FPM
  if [ -e "${php_install_dir}/sbin/php-fpm" ]; then
    if svc_is_active php-fpm; then
      check_pass "PHP-FPM: running"
    else
      check_fail "PHP-FPM: not running"
      [[ "${fix_mode}" == "--fix" ]] && { svc_start php-fpm; echo "    → attempted start"; }
    fi
    # Check PHP version
    php_ver=$(${php_install_dir}/bin/php -v 2>/dev/null | head -1 | awk '{print $2}')
    [ -n "${php_ver}" ] && check_pass "PHP version: ${php_ver}"
  else
    check_warn "PHP: not installed"
  fi

  # MySQL/MariaDB
  if [ -e "${mysql_install_dir}/bin/mysqld" ]; then
    if svc_is_active mysqld; then
      check_pass "MySQL: running"
    else
      check_fail "MySQL: not running"
      [[ "${fix_mode}" == "--fix" ]] && { svc_start mysqld; echo "    → attempted start"; }
    fi
    mysql_ver=$(${mysql_install_dir}/bin/mysql -V 2>/dev/null | awk '{print $3}')
    [ -n "${mysql_ver}" ] && check_pass "MySQL version: ${mysql_ver}"
  elif [ -e "${mariadb_install_dir}/bin/mysqld" ]; then
    if svc_is_active mysqld; then
      check_pass "MariaDB: running"
    else
      check_fail "MariaDB: not running"
      [[ "${fix_mode}" == "--fix" ]] && { svc_start mysqld; echo "    → attempted start"; }
    fi
    mariadb_ver=$(${mariadb_install_dir}/bin/mysql -V 2>/dev/null | awk '{print $3}')
    [ -n "${mariadb_ver}" ] && check_pass "MariaDB version: ${mariadb_ver}"
  else
    check_warn "MySQL/MariaDB: not installed"
  fi

  # PostgreSQL
  if [ -e "${pgsql_install_dir}/bin/pg_ctl" ]; then
    if pgrep -x postgres > /dev/null 2>&1; then
      check_pass "PostgreSQL: running"
    else
      check_fail "PostgreSQL: not running"
    fi
  else
    check_warn "PostgreSQL: not installed"
  fi

  # Redis
  if [ -e "${redis_install_dir}/bin/redis-server" ]; then
    if pgrep -x redis-server > /dev/null 2>&1; then
      check_pass "Redis: running"
    else
      check_fail "Redis: not running"
      [[ "${fix_mode}" == "--fix" ]] && { svc_start redis; echo "    → attempted start"; }
    fi
  else
    check_warn "Redis: not installed"
  fi

  # Memcached
  if [ -e "${memcached_install_dir}/bin/memcached" ]; then
    if pgrep -x memcached > /dev/null 2>&1; then
      check_pass "Memcached: running"
    else
      check_fail "Memcached: not running"
    fi
  else
    check_warn "Memcached: not installed"
  fi
}

# ============================================
# 2. Port Listening
# ============================================
check_ports() {
  check_header "Port Listening"

  check_port() {
    local port=$1 name=$2
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
      check_pass "Port ${port} (${name}): listening"
    else
      check_warn "Port ${port} (${name}): not listening"
    fi
  }

  check_port 80 "HTTP"
  check_port 443 "HTTPS"
  check_port 3306 "MySQL" 
  check_port 5432 "PostgreSQL"
  check_port 6379 "Redis"
  check_port 11211 "Memcached"
  check_port 21 "FTP"
}

# ============================================
# 3. Functional Tests
# ============================================
check_functional() {
  check_header "Functional Tests"

  # Nginx HTTP response
  if command -v curl > /dev/null 2>&1 && ss -tlnp 2>/dev/null | grep -q ":80 "; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 http://127.0.0.1/ 2>/dev/null)
    if [[ "${http_code}" == "200" ]] || [[ "${http_code}" == "301" ]] || [[ "${http_code}" == "302" ]]; then
      check_pass "HTTP (127.0.0.1): ${http_code}"
    else
      check_warn "HTTP (127.0.0.1): ${http_code}"
    fi
  fi

  # PHP execution
  if [ -e "${php_install_dir}/bin/php" ]; then
    php_test=$(${php_install_dir}/bin/php -r "echo 'ok';" 2>/dev/null)
    if [[ "${php_test}" == "ok" ]]; then
      check_pass "PHP execution: ok"
    else
      check_fail "PHP execution: failed"
    fi
  fi

  # MySQL connection
  if [ -e "${mysql_install_dir}/bin/mysql" ]; then
    if [ -z "${dbrootpwd}" ]; then
      check_warn "MySQL password unknown, skipped"
    elif ${mysql_install_dir}/bin/mysql -uroot -p"${dbrootpwd}" -e "SELECT 1" > /dev/null 2>&1; then
      check_pass "MySQL connection: ok"
    else
      # A stale password (user changed it manually, e.g. mysqladmin / ALTER
      # USER, without syncing options.conf) fails here while the DB is
      # healthy; the service's up/down is already reported by check_services.
      check_warn "MySQL connection: failed (root password may be out of sync with options.conf)"
    fi
  elif [ -e "${mariadb_install_dir}/bin/mysql" ]; then
    if [ -z "${dbrootpwd}" ]; then
      check_warn "MariaDB password unknown, skipped"
    elif ${mariadb_install_dir}/bin/mysql -uroot -p"${dbrootpwd}" -e "SELECT 1" > /dev/null 2>&1; then
      check_pass "MariaDB connection: ok"
    else
      check_warn "MariaDB connection: failed (root password may be out of sync with options.conf)"
    fi
  fi

  # Redis connection
  if [ -e "${redis_install_dir}/bin/redis-cli" ]; then
    redis_ping=$(${redis_install_dir}/bin/redis-cli ping 2>/dev/null)
    if [[ "${redis_ping}" == "PONG" ]]; then
      check_pass "Redis connection: PONG"
    else
      check_fail "Redis connection: failed"
    fi
  fi

  # SSL certificate check (if exists)
  if [ -d "${web_install_dir}/conf/ssl" ]; then
    for cert in ${web_install_dir}/conf/ssl/*.crt; do
      [ -f "${cert}" ] || continue
      domain=$(basename "${cert}" .crt)
      expiry=$(openssl x509 -in "${cert}" -noout -enddate 2>/dev/null | cut -d= -f2)
      if [ -n "${expiry}" ]; then
        expiry_epoch=$(date -d "${expiry}" +%s 2>/dev/null)
        now_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
        if [ ${days_left} -gt 30 ]; then
          check_pass "SSL ${domain}: ${days_left} days left"
        elif [ ${days_left} -gt 0 ]; then
          check_warn "SSL ${domain}: ${days_left} days left (expiring soon!)"
        else
          check_fail "SSL ${domain}: EXPIRED"
        fi
      fi
    done
  fi
}

# ============================================
# 4. Backups & Secret Files
# ============================================
check_backups() {
  check_header "Backups & Secret Files"

  # options.conf holds the DB root password in plaintext; install and every
  # writer chmod 600 it. Anything wider is a real exposure, not a nit.
  if [ -e "${current_dir}/options.conf" ]; then
    opts_perm=$(stat -c %a "${current_dir}/options.conf" 2>/dev/null)
    if [ "${opts_perm}" == "600" ]; then
      check_pass "options.conf permissions: 600"
    else
      check_fail "options.conf permissions: ${opts_perm} (expected 600 - it holds the DB root password). Fix: chmod 600 ${current_dir}/options.conf"
    fi
  fi

  # Backup freshness, judged the same way the backup scripts expire by age:
  # within the ${expired_days} retention window there must be at least one
  # restorable archive, otherwise the backup cron has been failing silently
  # while the oldest retained backups quietly age out.
  if [ -z "${backup_destination}" ] || [ -z "${backup_content}" ]; then
    check_warn "Backups: not configured (backup_destination/backup_content empty) - run backup_setup.sh"
    return
  fi
  if [ ! -d "${backup_dir}" ]; then
    check_fail "Backups: ${backup_dir} does not exist (backup.sh never ran, or the directory was deleted)"
    return
  fi
  dir_perm=$(stat -c %a "${backup_dir}" 2>/dev/null)
  if [ "${dir_perm}" == "700" ]; then
    check_pass "Backup directory permissions: 700"
  else
    check_warn "Backup directory permissions: ${dir_perm} (expected 700 - it holds unencrypted DB dumps)"
  fi

  window=${expired_days:-5}
  [[ "${window}" =~ ^[0-9]+$ ]] || window=5

  # Where do archives persist? backup.sh keeps local copies for 'local' and
  # 'remote' (SSH push) destinations; pure-cloud destinations (oss/cos/s3/...)
  # delete the local archive right after a successful upload
  # (backup.sh: "! has_local_backup && rm -f ..."), so an empty backup_dir is
  # a legitimate state there, and local freshness is only verifiable when
  # local or remote is configured.
  local_persist=n
  if [ -n "$(echo "${backup_destination}" | grep -ow 'local')" ] \
     || [ -n "$(echo "${backup_destination}" | grep -ow 'remote')" ]; then
    local_persist=y
  fi

  if [ -n "$(echo "${backup_content}" | grep -ow 'db')" ]; then
    if [ -z "${db_name}" ]; then
      check_warn "DB backup: configured but db_name is empty in options.conf"
    elif [ "${local_persist}" != y ]; then
      check_warn "DB backup: cloud-only destination - local archive freshness cannot be verified here (check the bucket)"
    else
      db_newest=$(find "${backup_dir}" -maxdepth 1 -name 'DB_*.tgz' -type f -printf '%T@\n' 2>/dev/null | sort -nr | head -1)
      if [ -z "${db_newest}" ]; then
        check_fail "DB backup: no DB_*.tgz archive in ${backup_dir} although db backup is configured"
      else
        db_age=$(( ($(date +%s) - ${db_newest%.*}) / 86400 ))
        if [ ${db_age} -le ${window} ]; then
          check_pass "DB backup: newest archive is ${db_age} day(s) old (retention ${window})"
        else
          check_fail "DB backup: newest archive is ${db_age} days old, retention is ${window} - the backup cron has been failing; check ${backup_dir}/db.log"
        fi
      fi
    fi
  fi

  if [ -n "$(echo "${backup_content}" | grep -ow 'web')" ]; then
    if [ -z "${website_name}" ]; then
      check_warn "Web backup: configured but website_name is empty in options.conf"
    elif [ "${local_persist}" != y ]; then
      check_warn "Web backup: cloud-only destination - local archive freshness cannot be verified here (check the bucket)"
    else
      # Sites too large to archive become rsync mirrors named after the site
      # itself (tools/website_bk.sh), so the newest artefact is either a
      # Web_<site>_*.tgz archive or a <site>/ directory - check both.
      web_newest=$(for W in $(echo "${website_name}" | tr ',' ' '); do
        [ -n "${W}" ] && find "${backup_dir}" -maxdepth 1 \( -name "Web_${W}_*.tgz" -type f -o -name "${W}" -type d \) -printf '%T@\n' 2>/dev/null
      done | sort -nr | head -1)
      if [ -z "${web_newest}" ]; then
        check_fail "Web backup: no Web_*.tgz archive or site mirror in ${backup_dir} although web backup is configured"
      else
        web_age=$(( ($(date +%s) - ${web_newest%.*}) / 86400 ))
        if [ ${web_age} -le ${window} ]; then
          check_pass "Web backup: newest artefact is ${web_age} day(s) old (retention ${window})"
        else
          check_fail "Web backup: newest artefact is ${web_age} days old, retention is ${window} - the backup cron has been failing; check ${backup_dir}/web.log"
        fi
      fi
    fi
  fi
}

# ============================================
# 5. System Resources
# ============================================
check_resources() {
  check_header "System Resources"

  # Disk usage
  disk_usage=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')
  disk_avail=$(df -h / | awk 'NR==2{print $4}')
  if [ ${disk_usage} -lt 80 ]; then
    check_pass "Disk usage: ${disk_usage}% (available: ${disk_avail})"
  elif [ ${disk_usage} -lt 90 ]; then
    check_warn "Disk usage: ${disk_usage}% (available: ${disk_avail})"
  else
    check_fail "Disk usage: ${disk_usage}% (available: ${disk_avail})"
  fi

  # Memory usage
  if command -v free > /dev/null 2>&1; then
    mem_total=$(free -m | awk '/Mem:/{print $2}')
    mem_used=$(free -m | awk '/Mem:/{print $3}')
    mem_pct=$((mem_used * 100 / mem_total))
    if [ ${mem_pct} -lt 80 ]; then
      check_pass "Memory usage: ${mem_pct}% (${mem_used}M / ${mem_total}M)"
    elif [ ${mem_pct} -lt 90 ]; then
      check_warn "Memory usage: ${mem_pct}% (${mem_used}M / ${mem_total}M)"
    else
      check_fail "Memory usage: ${mem_pct}% (${mem_used}M / ${mem_total}M)"
    fi
  fi

  # Load average
  load_avg=$(uptime | awk -F'load average:' '{print $2}' | xargs)
  cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
  load_1=$(echo "${load_avg}" | cut -d, -f1 | xargs)
  check_pass "Load average: ${load_avg} (${cpu_cores} cores)"

  # Swap usage
  if command -v free > /dev/null 2>&1; then
    swap_total=$(free -m | awk '/Swap:/{print $2}')
    if [ "${swap_total}" != "0" ] && [ -n "${swap_total}" ]; then
      swap_used=$(free -m | awk '/Swap:/{print $3}')
      swap_pct=$((swap_used * 100 / swap_total))
      if [ ${swap_pct} -lt 50 ]; then
        check_pass "Swap usage: ${swap_pct}% (${swap_used}M / ${swap_total}M)"
      else
        check_warn "Swap usage: ${swap_pct}% (${swap_used}M / ${swap_total}M)"
      fi
    fi
  fi

  # Zombie processes
  zombies=$(ps aux 2>/dev/null | awk '{print $8}' | grep -c Z)
  if [[ "${zombies}" == "0" ]]; then
    check_pass "Zombie processes: 0"
  else
    check_warn "Zombie processes: ${zombies}"
  fi
}

# ============================================
# Main
# ============================================
echo "${CCYAN}"
echo "╔════════════════════════════════════════╗"
echo "║     LNMP Stack Health Check v1.1       ║"
echo "╚════════════════════════════════════════╝"
echo "${CEND}"
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
[[ "${fix_mode}" == "--fix" ]] && echo "${CYELLOW}Mode: Auto-fix enabled${CEND}"

check_services
check_ports
check_functional
check_backups
check_resources

# Summary
echo
echo "${CCYAN}========================================${CEND}"
echo "${CCYAN} Summary${CEND}"
echo "${CCYAN}========================================${CEND}"
echo "  Total checks:  ${total_checks}"
echo "  ${CGREEN}Passed:        ${passed_checks}${CEND}"
[ ${warn_checks} -gt 0 ] && echo "  ${CYELLOW}Warnings:      ${warn_checks}${CEND}"
[ ${fail_checks} -gt 0 ] && echo "  ${CFAILURE}Failed:        ${fail_checks}${CEND}"
echo

if [ ${fail_checks} -eq 0 ] && [ ${warn_checks} -eq 0 ]; then
  echo "${CGREEN}✅ All checks passed! System is healthy.${CEND}"
elif [ ${fail_checks} -eq 0 ]; then
  echo "${CYELLOW}⚠️  System operational with warnings.${CEND}"
else
  echo "${CFAILURE}❌ Some checks failed. Review above.${CEND}"
  [ "${fix_mode}" != "--fix" ] && echo "${CYELLOW}Tip: Run with --fix to auto-restart failed services.${CEND}"
fi

popd > /dev/null

# Exit status has to reflect the result, otherwise cron jobs and monitoring
# agents always see success and failures go unnoticed.
#   0 - healthy (warnings only)
#   1 - at least one check failed
if [ ${fail_checks} -gt 0 ]; then
  exit 1
fi
exit 0
