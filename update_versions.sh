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
[[ "$1" == "--apply" ]] && apply_changes="y"
[[ "$1" == "--json" ]] && output_json="y"

. ./include/color.sh 2>/dev/null || true
. ./versions.txt

# GitHub API authentication (optional, raises rate limit from 60 to 5000/hr)
# Usage: GITHUB_TOKEN=ghp_xxx ./update_versions.sh
GITHUB_AUTH=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
  GITHUB_AUTH="Authorization: token ${GITHUB_TOKEN}"
fi

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
  [[ "$current" == "$latest" ]] && echo "same" && return
  
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
  latest=$(curl -sL --connect-timeout 5 --max-time 10 ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} "$url" 2>/dev/null | grep -oP "$regex" | eval "$sort_cmd")

  if [ -z "$latest" ]; then
    results="${results}⚠️  ${name}: 无法获取最新版本 (当前: ${current})\n"
    check_failed=$((check_failed + 1))
    return
  fi

  # Remove 'v' prefix if present
  latest="${latest#v}"
  current="${current#v}"

  if [[ "$current" == "$latest" ]]; then
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
      if [[ "$apply_changes" == "y" ]]; then
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
  if [[ "$nginx_ver" == "$nginx_stable" ]]; then
    results="${results}✅ Nginx (stable): ${nginx_ver} (最新)\n"
    up_to_date=$((up_to_date + 1))
  elif version_lt "$nginx_ver" "$nginx_stable"; then
    results="${results}🔄 Nginx (stable): ${nginx_ver} → ${nginx_stable} (小版本更新)\n"
    minor_updated=$((minor_updated + 1))
    if [[ "$apply_changes" == "y" ]]; then
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
      if [[ "$pg_current" == "$pg_latest" ]]; then
        results="${results}✅ PostgreSQL ${pg_major}: ${pg_current} (最新)\n"
        up_to_date=$((up_to_date + 1))
      elif version_lt "$pg_current" "$pg_latest"; then
        results="${results}🔄 PostgreSQL ${pg_major}: ${pg_current} → ${pg_latest} (小版本更新)\n"
        minor_updated=$((minor_updated + 1))
        [[ "$apply_changes" == "y" ]] && sed -i "s/^pgsql${pg_major}_ver=.*/pgsql${pg_major}_ver=${pg_latest}/" versions.txt
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
  ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
  "https://api.github.com/repos/php/php-src/tags?per_page=100" 2>/dev/null)
if [ -n "$php_tags" ] && [ "$php_tags" != "[]" ]; then
  for php_major in "8.3" "8.4" "8.5"; do
    total=$((total + 1))
    php_latest=$(echo "$php_tags" | python3 -c "
import json, sys, re
try:
    tags = json.load(sys.stdin)
    major = '${php_major}'
    for t in tags:
        v = t['name'].replace('php-','')
        if v.startswith(major + '.') and not re.search(r'(alpha|beta|RC|b\d)', v):
            print(v); break
except (json.JSONDecodeError, KeyError, TypeError):
    pass" 2>/dev/null)
    eval "php_current=\$php${php_major/./}_ver"
    if [ -n "$php_latest" ]; then
      if [[ "$php_current" == "$php_latest" ]]; then
        results="${results}✅ PHP ${php_major}: ${php_current} (最新)\n"
        up_to_date=$((up_to_date + 1))
      elif version_lt "$php_current" "$php_latest"; then
        results="${results}🔄 PHP ${php_major}: ${php_current} → ${php_latest} (小版本更新)\n"
        minor_updated=$((minor_updated + 1))
        [[ "$apply_changes" == "y" ]] && sed -i "s/^php${php_major/./}_ver=.*/php${php_major/./}_ver=${php_latest}/" versions.txt
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

# --- curl ---
check_latest "curl" "$curl_ver" \
  "https://curl.se/download.html" \
  '[0-9]+\.[0-9]+\.[0-9]+' "sort -V | tail -1"

# --- libsodium (GitHub) ---
libsodium_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
  ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
  "https://api.github.com/repos/jedisct1/libsodium/releases/latest" 2>/dev/null | \
  python3 -c "
import json,sys,re
try:
    data = json.load(sys.stdin)
    tag = data.get('tag_name','')
    ver = tag.lstrip('v').lstrip('release-')
    # Remove suffix like -RELEASE, -STABLE etc
    ver = re.split(r'[-_]', ver)[0]
    print(ver)
except: print('')
" 2>/dev/null)
if [ -n "$libsodium_latest" ]; then
  total=$((total + 1))
  if [[ "$libsodium_ver" == "$libsodium_latest" ]]; then
    results="${results}✅ libsodium: ${libsodium_ver} (最新)\n"
    up_to_date=$((up_to_date + 1))
  elif version_lt "$libsodium_ver" "$libsodium_latest"; then
    results="${results}🔄 libsodium: ${libsodium_ver} → ${libsodium_latest} (小版本更新)\n"
    minor_updated=$((minor_updated + 1))
    [[ "$apply_changes" == "y" ]] && sed -i "s/^libsodium_ver=.*/libsodium_ver=${libsodium_latest}/" versions.txt
  else
    results="${results}✅ libsodium: ${libsodium_ver} (最新: ${libsodium_latest})\n"
    up_to_date=$((up_to_date + 1))
  fi
else
  results="${results}⚠️  libsodium: 无法获取最新版本 (当前: ${libsodium_ver})\n"
  check_failed=$((check_failed + 1))
fi

# --- libiconv ---
check_latest "libiconv" "$libiconv_ver" \
  "https://ftp.gnu.org/pub/gnu/libiconv/" \
  'libiconv-\K[0-9]+\.[0-9]+' "sort -V | tail -1"

# --- memcached (GitHub tags) ---
memcached_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
  ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
  "https://api.github.com/repos/memcached/memcached/tags?per_page=10" 2>/dev/null | \
  python3 -c "
import json,sys,re
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list): sys.exit(1)
    tags = [t['name'] for t in data if isinstance(t, dict) and 'name' in t and re.match(r'^[0-9]+\.[0-9]+\.[0-9]+$', t['name'])]
    tags.sort(key=lambda v: [int(x) for x in v.split('.')], reverse=True)
    print(tags[0] if tags else '')
except: print('')
" 2>/dev/null)
if [ -n "$memcached_latest" ]; then
  total=$((total + 1))
  if [[ "$memcached_ver" == "$memcached_latest" ]]; then
    results="${results}✅ memcached: ${memcached_ver} (最新)\n"
    up_to_date=$((up_to_date + 1))
  elif version_lt "$memcached_ver" "$memcached_latest"; then
    results="${results}🔄 memcached: ${memcached_ver} → ${memcached_latest} (小版本更新)\n"
    minor_updated=$((minor_updated + 1))
    [[ "$apply_changes" == "y" ]] && sed -i "s/^memcached_ver=.*/memcached_ver=${memcached_latest}/" versions.txt
  else
    results="${results}✅ memcached: ${memcached_ver} (最新: ${memcached_latest})\n"
    up_to_date=$((up_to_date + 1))
  fi
else
  results="${results}⚠️  memcached: 无法获取最新版本 (当前: ${memcached_ver})\n"
  check_failed=$((check_failed + 1))
fi

# --- libmemcached ---
check_latest "libmemcached" "$libmemcached_ver" \
  "https://launchpad.net/libmemcached/+download" \
  'libmemcached-\K[0-9]+\.[0-9]+\.[0-9]+' "sort -V | tail -1"

# --- OpenSSL LTS (match same major.minor, e.g. 3.5.x when current is 3.5.5) ---
openssl_minor=$(echo "$openssl_ver" | cut -d. -f1,2)
check_latest "OpenSSL" "$openssl_ver" \
  "https://www.openssl.org/source/" \
  "openssl-\K${openssl_minor}\.[0-9]+" "sort -V | tail -1"

# --- PCRE2 (GitHub) ---
pcre2_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
  ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
  "https://api.github.com/repos/PCRE2Project/pcre2/releases/latest" 2>/dev/null | \
  python3 -c "
import json,sys
try:
    print(json.load(sys.stdin).get('tag_name',''))
except (json.JSONDecodeError, KeyError, TypeError):
    print('')
" 2>/dev/null)
pcre2_latest="${pcre2_latest#v}"
  pcre2_latest="${pcre2_latest#pcre2-}"
if [ -n "$pcre2_latest" ]; then
  total=$((total + 1))
  if [[ "$pcre_ver" == "$pcre2_latest" ]]; then
    results="${results}✅ PCRE2: ${pcre_ver} (最新)\n"
    up_to_date=$((up_to_date + 1))
  elif version_lt "$pcre_ver" "$pcre2_latest"; then
    results="${results}🔄 PCRE2: ${pcre_ver} → ${pcre2_latest} (小版本更新)\n"
    minor_updated=$((minor_updated + 1))
    [[ "$apply_changes" == "y" ]] && sed -i "s/^pcre_ver=.*/pcre_ver=${pcre2_latest}/" versions.txt
  else
    results="${results}✅ PCRE2: ${pcre_ver} (最新: ${pcre2_latest})\n"
    up_to_date=$((up_to_date + 1))
  fi
else
  results="${results}⚠️  PCRE2: 无法获取版本信息\n"
  check_failed=$((check_failed + 1))
fi

# --- LuaJIT (GitHub tags, sorted by date) ---
luajit_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
  ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
  "https://api.github.com/repos/openresty/luajit2/tags?per_page=20" 2>/dev/null | \
  python3 -c "
import json,sys,re
try:
    tags = [t['name'].lstrip('v') for t in json.load(sys.stdin) if isinstance(t, dict) and 'name' in t and re.match(r'2\.1-\d{8}$', t['name'].lstrip('v'))]
    tags.sort(reverse=True)
    print(tags[0] if tags else '')
except (json.JSONDecodeError, KeyError, TypeError):
    print('')
" 2>/dev/null)
if [ -n "$luajit_latest" ]; then
  total=$((total + 1))
  if [[ "$luajit2_ver" == "$luajit_latest" ]]; then
    results="${results}✅ LuaJIT: ${luajit2_ver} (最新)\n"
    up_to_date=$((up_to_date + 1))
  elif version_lt "$luajit2_ver" "$luajit_latest"; then
    results="${results}🔄 LuaJIT: ${luajit2_ver} → ${luajit_latest} (小版本更新)\n"
    minor_updated=$((minor_updated + 1))
    [[ "$apply_changes" == "y" ]] && sed -i "s/^luajit2_ver=.*/luajit2_ver=${luajit_latest}/" versions.txt
  else
    results="${results}✅ LuaJIT: ${luajit2_ver} (最新: ${luajit_latest})\n"
    up_to_date=$((up_to_date + 1))
  fi
else
  results="${results}⚠️  LuaJIT: 无法获取版本信息\n"
  check_failed=$((check_failed + 1))
fi

# --- ngx_devel_kit (GitHub tags) ---
# Note: This repo may have API rate limit issues, use longer timeout
ngx_devel_kit_latest=$(curl -sL --connect-timeout 15 --max-time 30 \
  ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
  "https://api.github.com/repos/simpl/ngx_devel_kit/tags?per_page=10" 2>/dev/null | \
  python3 -c "
import json,sys,re
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list): sys.exit(1)
    tags = [t['name'].lstrip('v') for t in data if isinstance(t, dict) and 'name' in t and re.match(r'^[0-9]+\.[0-9]+\.[0-9]+$', t['name'])]
    tags.sort(key=lambda v: [int(x) for x in v.split('.')], reverse=True)
    print(tags[0] if tags else '')
except: print('')
" 2>/dev/null)
if [ -n "$ngx_devel_kit_latest" ]; then
  total=$((total + 1))
  if [[ "$ngx_devel_kit_ver" == "$ngx_devel_kit_latest" ]]; then
    results="${results}✅ ngx_devel_kit: ${ngx_devel_kit_ver} (最新)\n"
    up_to_date=$((up_to_date + 1))
  elif version_lt "$ngx_devel_kit_ver" "$ngx_devel_kit_latest"; then
    results="${results}🔄 ngx_devel_kit: ${ngx_devel_kit_ver} → ${ngx_devel_kit_latest} (小版本更新)\n"
    minor_updated=$((minor_updated + 1))
    [[ "$apply_changes" == "y" ]] && sed -i "s/^ngx_devel_kit_ver=.*/ngx_devel_kit_ver=${ngx_devel_kit_latest}/" versions.txt
  else
    results="${results}✅ ngx_devel_kit: ${ngx_devel_kit_ver} (最新: ${ngx_devel_kit_latest})\n"
    up_to_date=$((up_to_date + 1))
  fi
else
  results="${results}⚠️  ngx_devel_kit: 无法获取版本信息 (当前: ${ngx_devel_kit_ver})\n"
  check_failed=$((check_failed + 1))
fi

# --- lua-nginx-module (GitHub tags, no releases) ---
lua_nginx_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
  ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
  "https://api.github.com/repos/openresty/lua-nginx-module/tags?per_page=20" 2>/dev/null | \
  python3 -c "
import json,sys,re
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list):
        sys.exit(1)
    tags = [t['name'].lstrip('v') for t in data if isinstance(t, dict) and 'name' in t and not re.search(r'(alpha|beta|rc|RC|dev)', t['name'])]
    tags.sort(key=lambda v: [int(x) for x in re.split(r'[.\-]', v) if x.isdigit()], reverse=True)
    print(tags[0] if tags else '')
except (json.JSONDecodeError, KeyError, TypeError):
    print('')
" 2>/dev/null)
if [ -n "$lua_nginx_latest" ]; then
  total=$((total + 1))
  if [[ "$lua_nginx_module_ver" == "$lua_nginx_latest" ]]; then
    results="${results}✅ lua-nginx-module: ${lua_nginx_module_ver} (最新)\n"
    up_to_date=$((up_to_date + 1))
  elif version_lt "$lua_nginx_module_ver" "$lua_nginx_latest"; then
    results="${results}🔄 lua-nginx-module: ${lua_nginx_module_ver} → ${lua_nginx_latest} (小版本更新)\n"
    minor_updated=$((minor_updated + 1))
    [[ "$apply_changes" == "y" ]] && sed -i "s/^lua_nginx_module_ver=.*/lua_nginx_module_ver=${lua_nginx_latest}/" versions.txt
  else
    results="${results}✅ lua-nginx-module: ${lua_nginx_module_ver} (最新: ${lua_nginx_latest})\n"
    up_to_date=$((up_to_date + 1))
  fi
else
  results="${results}⚠️  lua-nginx-module: 无法获取版本信息\n"
  check_failed=$((check_failed + 1))
fi

# --- lua-resty-core & lua-resty-lrucache (version-locked to lua-nginx-module) ---
# These libraries must match the lua-nginx-module version exactly.
# When lua-nginx-module is updated, these must be updated together.
if [ -n "$lua_nginx_latest" ] && version_lt "$lua_nginx_module_ver" "$lua_nginx_latest"; then
  # lua-nginx-module has an update - check compatible resty libraries
  lua_core_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
    ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
    "https://api.github.com/repos/openresty/lua-resty-core/tags?per_page=20" 2>/dev/null | \
    python3 -c "
import json,sys,re
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list): sys.exit(1)
    tags = [t['name'].lstrip('v') for t in data if isinstance(t, dict) and 'name' in t and not re.search(r'(alpha|beta|rc|RC|dev)', t['name'])]
    tags.sort(key=lambda v: [int(x) for x in re.split(r'[.\-]', v) if x.isdigit()], reverse=True)
    print(tags[0] if tags else '')
except: print('')
" 2>/dev/null)
  lua_lrucache_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
    ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
    "https://api.github.com/repos/openresty/lua-resty-lrucache/tags?per_page=20" 2>/dev/null | \
    python3 -c "
import json,sys,re
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list): sys.exit(1)
    tags = [t['name'].lstrip('v') for t in data if isinstance(t, dict) and 'name' in t and not re.search(r'(alpha|beta|rc|RC|dev)', t['name'])]
    tags.sort(key=lambda v: [int(x) for x in re.split(r'[.\-]', v) if x.isdigit()], reverse=True)
    print(tags[0] if tags else '')
except: print('')
" 2>/dev/null)

  total=$((total + 2))
  if [ -n "$lua_core_latest" ] && version_lt "$lua_resty_core_ver" "$lua_core_latest"; then
    results="${results}🔄 lua-resty-core: ${lua_resty_core_ver} → ${lua_core_latest} (同步 lua-nginx-module 升级)\n"
    minor_updated=$((minor_updated + 1))
    [[ "$apply_changes" == "y" ]] && sed -i "s/^lua_resty_core_ver=.*/lua_resty_core_ver=${lua_core_latest}/" versions.txt
  else
    results="${results}✅ lua-resty-core: ${lua_resty_core_ver} (最新)\n"
    up_to_date=$((up_to_date + 1))
  fi
  if [ -n "$lua_lrucache_latest" ] && version_lt "$lua_resty_lrucache_ver" "$lua_lrucache_latest"; then
    results="${results}🔄 lua-resty-lrucache: ${lua_resty_lrucache_ver} → ${lua_lrucache_latest} (同步 lua-nginx-module 升级)\n"
    minor_updated=$((minor_updated + 1))
    [[ "$apply_changes" == "y" ]] && sed -i "s/^lua_resty_lrucache_ver=.*/lua_resty_lrucache_ver=${lua_lrucache_latest}/" versions.txt
  else
    results="${results}✅ lua-resty-lrucache: ${lua_resty_lrucache_ver} (最新)\n"
    up_to_date=$((up_to_date + 1))
  fi
else
  # lua-nginx-module is up-to-date, check resty libraries independently
  lua_core_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
    ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
    "https://api.github.com/repos/openresty/lua-resty-core/tags?per_page=20" 2>/dev/null | \
    python3 -c "
import json,sys,re
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list): sys.exit(1)
    tags = [t['name'].lstrip('v') for t in data if isinstance(t, dict) and 'name' in t and not re.search(r'(alpha|beta|rc|RC|dev)', t['name'])]
    tags.sort(key=lambda v: [int(x) for x in re.split(r'[.\-]', v) if x.isdigit()], reverse=True)
    print(tags[0] if tags else '')
except: print('')
" 2>/dev/null)
  lua_lrucache_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
    ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
    "https://api.github.com/repos/openresty/lua-resty-lrucache/tags?per_page=20" 2>/dev/null | \
    python3 -c "
import json,sys,re
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list): sys.exit(1)
    tags = [t['name'].lstrip('v') for t in data if isinstance(t, dict) and 'name' in t and not re.search(r'(alpha|beta|rc|RC|dev)', t['name'])]
    tags.sort(key=lambda v: [int(x) for x in re.split(r'[.\-]', v) if x.isdigit()], reverse=True)
    print(tags[0] if tags else '')
except: print('')
" 2>/dev/null)
  total=$((total + 2))
  if [ -n "$lua_core_latest" ]; then
    if [[ "$lua_resty_core_ver" == "$lua_core_latest" ]]; then
      results="${results}✅ lua-resty-core: ${lua_resty_core_ver} (最新)\n"
      up_to_date=$((up_to_date + 1))
    elif version_lt "$lua_resty_core_ver" "$lua_core_latest"; then
      results="${results}⚠️  lua-resty-core: ${lua_resty_core_ver} → ${lua_core_latest} 可用 (需同步升级 lua-nginx-module)\n"
    else
      results="${results}✅ lua-resty-core: ${lua_resty_core_ver} (最新: ${lua_core_latest})\n"
      up_to_date=$((up_to_date + 1))
    fi
  else
    results="${results}⚠️  lua-resty-core: 无法获取版本信息\n"
    check_failed=$((check_failed + 1))
  fi
  if [ -n "$lua_lrucache_latest" ]; then
    if [[ "$lua_resty_lrucache_ver" == "$lua_lrucache_latest" ]]; then
      results="${results}✅ lua-resty-lrucache: ${lua_resty_lrucache_ver} (最新)\n"
      up_to_date=$((up_to_date + 1))
    elif version_lt "$lua_resty_lrucache_ver" "$lua_lrucache_latest"; then
      results="${results}⚠️  lua-resty-lrucache: ${lua_resty_lrucache_ver} → ${lua_lrucache_latest} 可用 (需同步升级 lua-nginx-module)\n"
    else
      results="${results}✅ lua-resty-lrucache: ${lua_resty_lrucache_ver} (最新: ${lua_lrucache_latest})\n"
      up_to_date=$((up_to_date + 1))
    fi
  else
    results="${results}⚠️  lua-resty-lrucache: 无法获取版本信息\n"
    check_failed=$((check_failed + 1))
  fi
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
  latest=""
  total=$((total + 1))

  latest=$(curl -sL --connect-timeout 5 --max-time 10 \
    ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
    "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | \
    python3 -c "
import json,sys
try:
    tag = json.load(sys.stdin).get('tag_name','')
    print(tag.lstrip('v'))
except (json.JSONDecodeError, KeyError, TypeError):
    print('')
" 2>/dev/null)

  if [ -z "$latest" ]; then
    results="${results}⚠️  ${name}: 无法获取 (当前: ${current})\n"
    check_failed=$((check_failed + 1))
  elif [[ "$current" == "$latest" ]]; then
    results="${results}✅ ${name}: ${current} (最新)\n"
    up_to_date=$((up_to_date + 1))
  elif [ "$(classify_update "$current" "$latest")" == "major" ]; then
    results="${results}🆕 ${name}: ${current} → ${latest} (大版本更新，请手动确认)\n"
    major_available=$((major_available + 1))
  elif version_lt "$current" "$latest"; then
    results="${results}🔄 ${name}: ${current} → ${latest} (小版本更新)\n"
    minor_updated=$((minor_updated + 1))
    if [[ "$apply_changes" == "y" ]]; then
      varname=$(grep "_ver=" versions.txt | grep "$current" | head -1 | cut -d= -f1)
      [ -n "$varname" ] && sed -i "s/^${varname}=.*/${varname}=${latest}/" versions.txt
    fi
  else
    results="${results}✅ ${name}: ${current} (最新: ${latest})\n"
    up_to_date=$((up_to_date + 1))
  fi
done

# --- Others ---
# phpMyAdmin: use context-aware regex to avoid matching unrelated numbers
check_latest "phpMyAdmin" "$phpmyadmin_ver" \
  "https://www.phpmyadmin.net/" 'Download\s+\K[0-9]+\.[0-9]+\.[0-9]+'

check_latest "Pure-FTPd" "$pureftpd_ver" \
  "https://download.pureftpd.org/pub/pure-ftpd/releases/" \
  'pure-ftpd-\K[0-9]+\.[0-9]+\.[0-9]+' "sort -V | tail -1"

# --- Fail2ban (GitHub) ---
fail2ban_latest=$(curl -sL --connect-timeout 5 --max-time 10 \
  ${GITHUB_AUTH:+-H "$GITHUB_AUTH"} \
  "https://api.github.com/repos/fail2ban/fail2ban/releases/latest" 2>/dev/null | \
  grep -oP '"tag_name":\s*"\K[0-9]+\.[0-9]+\.[0-9]+')
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
printf "%b\n" "$results"

echo "${CCYAN}========================================${CEND}"
echo "总计: ${total} 个组件"
echo "  ✅ 最新: ${up_to_date}"
echo "  🔄 小版本更新: ${minor_updated}"
echo "  🆕 大版本可用: ${major_available}"
echo "  ⚠️  检查失败: ${check_failed}"
echo ""

if [[ "$apply_changes" == "n" ]] && [ "$minor_updated" -gt 0 ]; then
  echo "${CYELLOW}提示: 使用 --apply 参数应用小版本更新${CEND}"
  echo "  ./update_versions.sh --apply"
fi
