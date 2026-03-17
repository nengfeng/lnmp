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
  if [ -e "${mysql_install_dir}/bin/mysql" ] && [ -n "${dbrootpwd}" ]; then
    if ${mysql_install_dir}/bin/mysql -uroot -p"${dbrootpwd}" -e "SELECT 1" > /dev/null 2>&1; then
      check_pass "MySQL connection: ok"
    else
      check_fail "MySQL connection: failed"
    fi
  elif [ -e "${mariadb_install_dir}/bin/mysql" ] && [ -n "${dbrootpwd}" ]; then
    if ${mariadb_install_dir}/bin/mysql -uroot -p"${dbrootpwd}" -e "SELECT 1" > /dev/null 2>&1; then
      check_pass "MariaDB connection: ok"
    else
      check_fail "MariaDB connection: failed"
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
# 4. System Resources
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
echo "║     LNMP Stack Health Check v1.0       ║"
echo "╚════════════════════════════════════════╝"
echo "${CEND}"
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
[[ "${fix_mode}" == "--fix" ]] && echo "${CYELLOW}Mode: Auto-fix enabled${CEND}"

check_services
check_ports
check_functional
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
