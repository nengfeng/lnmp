#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Description: Auto-update component versions in versions.txt
#
# Strategy:
#   - Minor/patch updates (e.g., 8.5.3 → 8.5.4): auto-apply
#   - Major/LTS updates (e.g., 8.4 → 8.6): notify only
#   - Dry-run by default, use --apply to write changes
#
# Usage:
#   ./update_versions.sh           # Check only (dry-run)
#   ./update_versions.sh --apply   # Apply minor updates
#   ./update_versions.sh --json    # Output as JSON

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
current_dir=$(dirname "$(readlink -f "$0")")
cd "${current_dir}"

apply_changes="n"
output_json="n"
[ "$1" == "--apply" ] && apply_changes="y"
[ "$1" == "--json" ] && output_json="y"

. ./include/color.sh 2>/dev/null || true
. ./versions.txt

# Counters
total=0
up_to_date=0
minor_updated=0
major_available=0
check_failed=0

# Results storage
results=""

# Helper: compare version strings (returns 1 if $1 < $2)
version_lt() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ] && [ "$1" != "$2" ]
}

# Helper: get major.minor from version
major_minor() {
  echo "$1" | awk -F. '{print $1"."$2}'
}

# Helper: classify update type
# For major version tracking: only first number is "major"
# Returns: "same" "minor" "major" "older"
classify_update() {
  local current="$1" latest="$2"
  [ "$current" == "$latest" ] && echo "same" && return
  
  local cur_major=$(echo "$current" | cut -d. -f1)
  local lat_major=$(echo "$latest" | cut -d. -f1)
  
  if [ "$cur_major" != "$lat_major" ]; then
    echo "major"  # Different major version (e.g., PHP 8.4 → 8.5)
  elif version_lt "$current" "$latest"; then
    echo "minor"  # Same major, newer (e.g., PHP 8.5.3 → 8.5.4)
  else
    echo "older"  # Same major, older (shouldn't happen normally)
  fi
}

# Helper: check latest version from URL pattern
# Usage: check_latest <name> <current> <url> <regex>
check_latest() {
  local name="$1" current="$2" url="$3" regex="$4" sort_cmd="${5:-head -1}"
  total=$((total + 1))

  local latest
  latest=$(curl -sL --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | grep -oP "$regex" | eval "$sort_cmd")

  if [ -z "$latest" ]; then
    results="${results}⚠️  ${name}: 无法获取最新版本 (当前: ${current})\n"
    check_failed=$((check_failed + 1))
    return
  fi

  # Remove 'v' prefix if present
  latest="${latest#v}"
  current="${current#v}"

  if [ "$current" == "$latest" ]; then
    results="${results}✅ ${name}: ${current} (最新)\n"
    up_to_date=$((up_to_date + 1))
    return
  fi

  local update_type=$(classify_update "$current" "$latest")

  case "$update_type" in
    minor)
      # Minor/patch update
      results="${results}🔄 ${name}: ${current} → ${latest} (小版本更新)\n"
      minor_updated=$((minor_updated + 1))
      if [ "$apply_changes" == "y" ]; then
        local varname=$(grep "_ver=" versions.txt | grep "$current" | head -1 | cut -d= -f1)
        if [ -n "$varname" ]; then
          sed -i "s/^${varname}=.*/${varname}=${latest}/" versions.txt
          results="${results}   ✏️  已更新 ${varname}=${latest}\n"
        fi
      fi
      ;;
    major)
      results="${results}🆕 ${name}: ${current} → ${latest} (大版本更新，请手动确认)\n"
      major_available=$((major_available + 1))
      ;;
    *)
      results="${results}ℹ️  ${name}: ${current} (最新: ${latest})\n"
      up_to_date=$((up_to_date + 1))
      ;;
  esac
}

# ============================================
# Check each component
# ============================================

echo "${CCYAN}检查组件版本更新...${CEND}"
echo ""

# --- Nginx: stable only (even middle number) ---
nginx_stable=$(curl -sL --connect-timeout 5 --max-time 10 \
  "https://nginx.org/en/download.html" 2>/dev/null | \
  grep -oP 'Stable version.*?nginx-\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -n "$nginx_stable" ]; then
  total=$((total + 1))
  if [ "$nginx_ver" == "$nginx_stable" ]; then
    results="${results}✅ Nginx (stable): ${nginx_ver} (最新)\n"
    up_to_date=$((up_to_date + 1))
  elif version_lt "$nginx_ver" "$nginx_stable"; then
    results="${results}🔄 Nginx (stable): ${nginx_ver} → ${nginx_stable} (小版本更新)\n"
    minor_updated=$((minor_updated + 1))
    if [ "$apply_changes" == "y" ]; then
      sed -i "s/^nginx_ver=.*/nginx_ver=${nginx_stable}/" versions.txt
      results="${results}   ✏️  已更新 nginx_ver=${nginx_stable}\n"
    fi
  else
    results="${results}✅ Nginx (stable): ${nginx_ver} (最新: ${nginx_stable})\n"
    up_to_date=$((up_to_date + 1))
  fi
else
  results="${results}⚠️  Nginx (stable): 无法检测\n"
  check_failed=$((check_failed + 1))
fi

check_latest "OpenResty" "$openresty_ver" \
  "https://openresty.org/en/download.html" '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'

# --- Databases ---
# MySQL uses specific major versions
mysql84_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
  "https://dev.mysql.com/downloads/mysql/8.0.html" 2>/dev/null | \
  grep -oP 'mysql-8\.\d+\.\d+' | head -1 | grep -oP '8\.\d+\.\d+')
# Skip MySQL complex check - just note

# MariaDB
check_latest "MariaDB 11.8" "$mariadb118_ver" \
  "https://downloads.mariadb.org/rest-api/mariadb/all-releases/?olderReleases=false" \
  '11\.8\.[0-9]+'

check_latest "MariaDB 11.4" "$mariadb114_ver" \
  "https://downloads.mariadb.org/rest-api/mariadb/all-releases/?olderReleases=false" \
  '11\.4\.[0-9]+'

# PostgreSQL - use official versions.json API
pgsql_json=$(curl -sL --connect-timeout 5 --max-time 10 \
  "https://www.postgresql.org/versions.json" 2>/dev/null)
if [ -n "$pgsql_json" ]; then
  for pg_major in 16 17 18; do
    total=$((total + 1))
    pg_latest=$(echo "$pgsql_json" | python3 -c "
import json,sys
for v in json.load(sys.stdin):
    if v['major']=='${pg_major}': print(v['major']+'.'+v.get('latestMinor','0'))" 2>/dev/null)
    eval "pg_current=\$pgsql${pg_major}_ver"
    if [ -n "$pg_latest" ]; then
      if [ "$pg_current" == "$pg_latest" ]; then
        results="${results}✅ PostgreSQL ${pg_major}: ${pg_current} (最新)\n"
        up_to_date=$((up_to_date + 1))
      elif version_lt "$pg_current" "$pg_latest"; then
        results="${results}🔄 PostgreSQL ${pg_major}: ${pg_current} → ${pg_latest} (小版本更新)\n"
        minor_updated=$((minor_updated + 1))
        [ "$apply_changes" == "y" ] && sed -i "s/^pgsql${pg_major}_ver=.*/pgsql${pg_major}_ver=${pg_latest}/" versions.txt
      else
        results="${results}✅ PostgreSQL ${pg_major}: ${pg_current} (最新: ${pg_latest})\n"
        up_to_date=$((up_to_date + 1))
      fi
    else
      results="${results}⚠️  PostgreSQL ${pg_major}: 无法解析版本\n"
      check_failed=$((check_failed + 1))
    fi
  done
else
  results="${results}⚠️  PostgreSQL: 无法获取版本信息\n"
  check_failed=$((check_failed + 3))
fi

# --- PHP (GitHub API for all active branches) ---
php_tags=$(curl -sL --connect-timeout 5 --max-time 10 \
  "https://api.github.com/repos/php/php-src/tags?per_page=100" 2>/dev/null)
if [ -n "$php_tags" ] && [ "$php_tags" != "[]" ]; then
  for php_major in "8.3" "8.4" "8.5"; do
    total=$((total + 1))
    php_latest=$(echo "$php_tags" | python3 -c "
import json, sys
tags = json.load(sys.stdin)
major = '${php_major}'
for t in tags:
    v = t['name'].replace('php-','')
    if v.startswith(major + '.'):
        print(v); break" 2>/dev/null)
    eval "php_current=\$php${php_major/./}_ver"
    if [ -n "$php_latest" ]; then
      if [ "$php_current" == "$php_latest" ]; then
        results="${results}✅ PHP ${php_major}: ${php_current} (最新)\n"
        up_to_date=$((up_to_date + 1))
      elif version_lt "$php_current" "$php_latest"; then
        results="${results}🔄 PHP ${php_major}: ${php_current} → ${php_latest} (小版本更新)\n"
        minor_updated=$((minor_updated + 1))
        [ "$apply_changes" == "y" ] && sed -i "s/^php${php_major/./}_ver=.*/php${php_major/./}_ver=${php_latest}/" versions.txt
      else
        results="${results}✅ PHP ${php_major}: ${php_current} (最新: ${php_latest})\n"
        up_to_date=$((up_to_date + 1))
      fi
    else
      results="${results}⚠️  PHP ${php_major}: 无法获取\n"
      check_failed=$((check_failed + 1))
    fi
  done
else
  results="${results}⚠️  PHP: GitHub API 不可用\n"
  check_failed=$((check_failed + 3))
fi

# --- Redis ---
check_latest "Redis" "$redis_ver" \
  "https://download.redis.io/redis-stable/00-RELEASENOTES" \
  '[0-9]+\.[0-9]+\.[0-9]+'

# --- Node.js ---
node_major=$(echo "$nodejs_ver" | cut -d. -f1)
check_latest "Node.js" "$nodejs_ver" \
  "https://nodejs.org/dist/latest-v${node_major}.x/SHASUMS256.txt" \
  "node-v\\K[0-9]+\.[0-9]+\.[0-9]+"

# --- PECL extensions (via GitHub API) ---
pecl_repos=(
  "pecl-redis:phpredis/phpredis:v${pecl_redis_ver}"
  "pecl-mongodb:mongodb/mongo-php-driver:v${pecl_mongodb_ver}"
  "pecl-swoole:swoole/swoole-src:v${swoole_ver}"
  "pecl-xdebug:xdebug/xdebug:${xdebug_ver}"
  "pecl-imagick:Imagick/imagick:${imagick_ver}"
  "pecl-apcu:krakjoe/apcu:v${apcu_ver}"
  "pecl-phalcon:phalcon/cphalcon:v${phalcon_ver}"
)

for item in "${pecl_repos[@]}"; do
  name="${item%%:*}"
  repo="${item#*:}"
  repo="${repo%:*}"
  current="${item##*:}"
  current="${current#v}"
  total=$((total + 1))

  latest=$(curl -sL --connect-timeout 5 --max-time 10 \
    "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null)
  latest="${latest#v}"

  if [ -z "$latest" ]; then
    results="${results}⚠️  ${name}: 无法获取 (当前: ${current})\n"
    check_failed=$((check_failed + 1))
  elif [ "$current" == "$latest" ]; then
    results="${results}✅ ${name}: ${current} (最新)\n"
    up_to_date=$((up_to_date + 1))
  elif [ "$(classify_update "$current" "$latest")" == "major" ]; then
    results="${results}🆕 ${name}: ${current} → ${latest} (大版本更新，请手动确认)\n"
    major_available=$((major_available + 1))
  elif version_lt "$current" "$latest"; then
    results="${results}🔄 ${name}: ${current} → ${latest} (小版本更新)\n"
    minor_updated=$((minor_updated + 1))
    if [ "$apply_changes" == "y" ]; then
      varname=$(grep "_ver=" versions.txt | grep "$current" | head -1 | cut -d= -f1)
      [ -n "$varname" ] && sed -i "s/^${varname}=.*/${varname}=${latest}/" versions.txt
    fi
  else
    results="${results}✅ ${name}: ${current} (最新: ${latest})\n"
    up_to_date=$((up_to_date + 1))
  fi
done

# --- Others ---
check_latest "phpMyAdmin" "$phpmyadmin_ver" \
  "https://www.phpmyadmin.net/" '[0-9]+\.[0-9]+\.[0-9]+'

check_latest "Pure-FTPd" "$pureftpd_ver" \
  "https://download.pureftpd.org/pub/pure-ftpd/releases/" \
  'pure-ftpd-\K[0-9]+\.[0-9]+\.[0-9]+' "sort -V | tail -1"

# --- Fail2ban (GitHub) ---
fail2ban_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
  "https://api.github.com/repos/fail2ban/fail2ban/releases/latest" 2>/dev/null | \
  grep -oP '"tag_name":\s*"\K[^"]+')
if [ -n "$fail2ban_latest" ] && [ "$fail2ban_ver" != "master" ]; then
  check_latest "fail2ban" "$fail2ban_ver" \
    "https://api.github.com/repos/fail2ban/fail2ban/releases/latest" \
    '[0-9]+\.[0-9]+\.[0-9]+'
fi

# ============================================
# Output Results
# ============================================

echo ""
echo "${CCYAN}========================================${CEND}"
echo "${CCYAN} 检查结果${CEND}"
echo "${CCYAN}========================================${CEND}"
echo ""
echo -e "$results"

echo "${CCYAN}========================================${CEND}"
echo "总计: ${total} 个组件"
echo "  ✅ 最新: ${up_to_date}"
echo "  🔄 小版本更新: ${minor_updated}"
echo "  🆕 大版本可用: ${major_available}"
echo "  ⚠️  检查失败: ${check_failed}"
echo ""

if [ "$apply_changes" == "n" ] && [ "$minor_updated" -gt 0 ]; then
  echo "${CYELLOW}提示: 使用 --apply 参数应用小版本更新${CEND}"
  echo "  ./update_versions.sh --apply"
fi
