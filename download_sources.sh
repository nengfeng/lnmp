#!/bin/bash
# Author:  LNMP Installer
# SPDX-License-Identifier: Apache-2.0
# Description: 从官方源或国内镜像下载所有组件到 src 目录
# Usage: ./download_sources.sh [component1] [component2] ...
#        ./download_sources.sh --all
#        ./download_sources.sh --list
#
# Mirror Selection:
#   - Auto: Detect IP location automatically (default)
#   - MIRROR_MODE=china ./download_sources.sh ...  # Force use China mirrors
#   MIRROR_MODE=official ./download_sources.sh ... # Force use official sources
#
# Checksum Verification:
#   - Automatically verify SHA256/SHA1/MD5 checksums when available
#   - PGP signatures (.asc) require gnupg and imported keys

set -e

# ============================================
# 初始化
# ============================================
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SRC_DIR="${SCRIPT_DIR}/src"
VERSIONS_FILE="${SCRIPT_DIR}/versions.txt"
SOURCES_FILE="${SCRIPT_DIR}/sources.conf"
LOG_FILE="${SCRIPT_DIR}/download.log"

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# 镜像模式: auto, china, official
MIRROR_MODE="${MIRROR_MODE:-auto}"

# 是否验证校验码
VERIFY_CHECKSUM="${VERIFY_CHECKSUM:-yes}"
# Where the bundled upstream PGP public keys live. Derived from the script
# location; overridable so the offline tests (which source this file from
# tools/test_offline.sh, where $0-based derivation points elsewhere) can
# point at their own fixture keyring.
PGP_KEYS_DIR="${PGP_KEYS_DIR:-${SCRIPT_DIR}/keys}"

# Machine architecture token for binary tarball names (x86_64 / aarch64)
SYS_ARCH_M=$(uname -m)

# 检测系统架构
detect_arch() {
  local arch=$(uname -m)
  case $arch in
    x86_64|amd64)
      SYS_ARCH="amd64"
      SYS_ARCH_I="x86-64"   # ioncube 格式
      SYS_ARCH_N="x64"      # nodejs 格式
      ;;
    aarch64|arm64)
      SYS_ARCH="arm64"
      SYS_ARCH_I="aarch64"  # ioncube 格式
      SYS_ARCH_N="arm64"    # nodejs 格式
      ;;
    *)
      echo "Unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac
}
detect_arch

# 镜像基础 URL（从 options.conf 加载，或使用默认值）
if [ -f "${SCRIPT_DIR}/options.conf" ]; then
  . "${SCRIPT_DIR}/options.conf"
fi
MIRROR_BASE_URL="${MIRROR_BASE_URL:-https://mirrors.tuna.tsinghua.edu.cn}"
GITHUB_ACCELERATOR_URL="${GITHUB_ACCELERATOR_URL:-}"

# 日志函数
log() {
  local level=$1
  shift
  local msg="$*"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] [${level}] ${msg}" >> "${LOG_FILE}"
  case $level in
    INFO)  printf "%b" "${GREEN}[INFO]${NC} ${msg}\\n" >&2 ;;
    WARN)  printf "%b" "${YELLOW}[WARN]${NC} ${msg}\\n" >&2 ;;
    ERROR) printf "%b" "${RED}[ERROR]${NC} ${msg}\\n" >&2 ;;
    *)     printf "%b" "${msg}\\n" >&2 ;;
  esac
}

# ============================================
# 检测 IP 地理位置
# ============================================
detect_location() {
  local ip_info=""
  
  # 尝试使用 ipinfo.io
  if command -v curl >/dev/null 2>&1; then
    ip_info=$(curl -s --connect-timeout 5 https://ipinfo.io/json 2>/dev/null || true)
  fi
  
  if [ -z "$ip_info" ] && command -v wget >/dev/null 2>&1; then
    ip_info=$(wget -qO- --timeout=5 https://ipinfo.io/json 2>/dev/null || true)
  fi
  
  if [ -n "$ip_info" ]; then
    local country=$(echo "$ip_info" | grep -o '"country": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    if [ -n "$country" ]; then
      echo "$country"
      return
    fi
  fi
  
  # 无法检测，默认返回 unknown
  echo "unknown"
}

# ============================================
# 获取镜像模式
# ============================================
get_mirror_mode() {
  if [[ "$MIRROR_MODE" == "china" ]] || [[ "$MIRROR_MODE" == "official" ]]; then
    echo "$MIRROR_MODE"
    return
  fi
  
  # auto 模式：自动检测
  log INFO "Detecting IP location..."
  local location=$(detect_location)
  log INFO "Detected location: $location"
  
  if [[ "$location" == "CN" ]]; then
    echo "china"
  else
    echo "official"
  fi
}

# ============================================
# 读取版本号
# ============================================
declare -A VERSIONS

load_versions() {
  if [ ! -f "${VERSIONS_FILE}" ]; then
    log ERROR "versions.txt not found: ${VERSIONS_FILE}"
    exit 1
  fi
  
  while IFS='=' read -r key value; do
    # 跳过注释和空行
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    # 去除前后空格
    key=$(echo "$key" | tr -d '[:space:]')
    value=$(echo "$value" | tr -d '[:space:]')
    VERSIONS[$key]=$value
  done < "${VERSIONS_FILE}"

  # glibc tag baked into the MySQL binary tarball name (see versions.txt).
  # Kept in sync with install.sh / include/db-common.sh / include/upgrade_db.sh
  # so the offline pre-downloader fetches exactly the same file the install
  # expects.
  GLIBC_TAG="${VERSIONS[mysql_binary_glibc_tag]:-glibc2.28}"
  
  log INFO "Loaded ${#VERSIONS[@]} version definitions"
}

# ============================================
# 获取版本号
# ============================================
get_version() {
  local component=$1
  local ver=""
  
  # 组件名到版本变量的映射
  case $component in
    nginx)          ver=${VERSIONS[nginx_ver]} ;;
    tengine)        ver=${VERSIONS[tengine_ver]} ;;
    openresty)      ver=${VERSIONS[openresty_ver]} ;;
    openssl)        ver=${VERSIONS[openssl_ver]} ;;
    pcre)           ver=${VERSIONS[pcre_ver]} ;;
    nghttp2)        ver=${VERSIONS[nghttp2_ver]} ;;
    mysql97)        ver=${VERSIONS[mysql97_ver]} ;;
    mysql84)        ver=${VERSIONS[mysql84_ver]} ;;
    mysql80)        ver=${VERSIONS[mysql80_ver]} ;;
    mysql-src)      ver=${VERSIONS[mysql97_ver]} ;;
    mysql84-src)    ver=${VERSIONS[mysql84_ver]} ;;
    mysql80-src)    ver=${VERSIONS[mysql80_ver]} ;;
    mariadb123)     ver=${VERSIONS[mariadb123_ver]} ;;
    mariadb118)     ver=${VERSIONS[mariadb118_ver]} ;;
    mariadb)        ver=${VERSIONS[mariadb118_ver]} ;;
    mariadb114)     ver=${VERSIONS[mariadb114_ver]} ;;
    mariadb1011)    ver=${VERSIONS[mariadb1011_ver]} ;;
    mariadb-src)    ver=${VERSIONS[mariadb118_ver]} ;;
    mariadb114-src) ver=${VERSIONS[mariadb114_ver]} ;;
    mariadb1011-src) ver=${VERSIONS[mariadb1011_ver]} ;;
    postgresql)     ver=${VERSIONS[pgsql18_ver]} ;;
    postgresql18)   ver=${VERSIONS[pgsql18_ver]} ;;
    postgresql17)   ver=${VERSIONS[pgsql17_ver]} ;;
    postgresql16)   ver=${VERSIONS[pgsql16_ver]} ;;
    php)            ver=${VERSIONS[php84_ver]} ;;
    php83)          ver=${VERSIONS[php83_ver]} ;;
    php84)          ver=${VERSIONS[php84_ver]} ;;
    php85)          ver=${VERSIONS[php85_ver]} ;;
    curl)           ver=${VERSIONS[curl_ver]} ;;
    freetype)       ver=${VERSIONS[freetype_ver]} ;;
    libsodium)      ver=${VERSIONS[libsodium_ver]} ;;
    libzip)         ver=${VERSIONS[libzip_ver]} ;;

    argon2)         ver=${VERSIONS[argon2_ver]} ;;
    imagemagick)    ver=${VERSIONS[imagemagick_ver]} ;;
    redis)          ver=${VERSIONS[redis_ver]} ;;
    memcached)      ver=${VERSIONS[memcached_ver]} ;;
    libmemcached)   ver=${VERSIONS[libmemcached_ver]} ;;
    pureftpd)       ver=${VERSIONS[pureftpd_ver]} ;;
    nodejs)         ver=${VERSIONS[nodejs_ver]} ;;
    phpmyadmin)     ver=${VERSIONS[phpmyadmin_ver]} ;;
    tcmalloc)       ver=${VERSIONS[tcmalloc_ver]} ;;
    jemalloc)       ver=${VERSIONS[jemalloc_ver]} ;;
    boost)          ver=${VERSIONS[boost_ver]} ;;
    lua-nginx-module) ver=${VERSIONS[lua_nginx_module_ver]} ;;
    ngx-devel-kit)  ver=${VERSIONS[ngx_devel_kit_ver]} ;;
    luajit2)        ver=${VERSIONS[luajit2_ver]} ;;
    lua-resty-core) ver=${VERSIONS[lua_resty_core_ver]} ;;
    lua-resty-lrucache) ver=${VERSIONS[lua_resty_lrucache_ver]} ;;
    lua-cjson)      ver=${VERSIONS[lua_cjson_ver]} ;;
    pecl-redis)     ver=${VERSIONS[pecl_redis_ver]} ;;
    pecl-memcached) ver=${VERSIONS[pecl_memcached_ver]} ;;
    pecl-memcache)  ver=${VERSIONS[pecl_memcache_ver]} ;;
    pecl-mongodb)   ver=${VERSIONS[pecl_mongodb_ver]} ;;
    pecl-imagick)   ver=${VERSIONS[imagick_ver]} ;;
    pecl-apcu)      ver=${VERSIONS[apcu_ver]} ;;
    pecl-phalcon)   ver=${VERSIONS[phalcon_ver]} ;;
    pecl-yaf)       ver=${VERSIONS[yaf_ver]} ;;
    pecl-yar)       ver=${VERSIONS[yar_ver]} ;;
    pecl-swoole)    ver=${VERSIONS[swoole_ver]} ;;
    pecl-xdebug)    ver=${VERSIONS[xdebug_ver]} ;;
    brotli)         ver=${VERSIONS[brotli_ver]} ;;
    ngx-brotli)     ver="current" ;;
    ioncube)        ver="current" ;;
    cacert)         ver="current" ;;
    *)              ver="" ;;
  esac
  
  echo "$ver"
}

# ============================================
# 构建下载URL
# ============================================
build_download_url() {
  local url_template=$1
  local filename_template=$2
  local ver=$3
  
  # 替换版本变量
  local url="${url_template}"
  local filename="${filename_template}"
  
  # 替换 {ver}
  url="${url//\{ver\}/$ver}"
  filename="${filename//\{ver\}/$ver}"
  
  # 替换 {ver_dash} (如 63_1 -> 63-1)
  local ver_dash="${ver//_/-}"
  url="${url//\{ver_dash\}/$ver_dash}"
  filename="${filename//\{ver_dash\}/$ver_dash}"
  
  # 替换 {ver_underscore} (如 1.77.0 -> 1_77_0)
  local ver_underscore=$(echo "$ver" | sed 's/\./_/g')
  url="${url//\{ver_underscore\}/$ver_underscore}"
  filename="${filename//\{ver_underscore\}/$ver_underscore}"
  
  # 替换 {major} (如 8.4.8 -> 8.4)
  local major=$(echo "$ver" | cut -d. -f1,2)
  url="${url//\{major\}/$major}"
  filename="${filename//\{major\}/$major}"
  
  echo "${url}|${filename}"
}

# ============================================
# 计算文件的校验码
# ============================================
compute_checksum() {
  local file=$1
  local type=$2
  
  case $type in
    sha256)
      sha256sum "$file" 2>/dev/null | awk '{print $1}'
      ;;
    sha1)
      sha1sum "$file" 2>/dev/null | awk '{print $1}'
      ;;
    md5)
      md5sum "$file" 2>/dev/null | awk '{print $1}'
      ;;
    *)
      echo ""
      ;;
  esac
}

# ============================================
# 下载校验码文件
# ============================================
download_checksum() {
  local checksum_url=$1
  local checksum_type=$2
  local filename=$3
  local accelerator_url=""

  local checksum_file="${filename}.${checksum_type}"

  log INFO "Downloading checksum: ${checksum_url}"

  if wget -q "${checksum_url}" -O "${checksum_file}" 2>/dev/null; then
    # 检查文件是否为空
    if [ -s "${checksum_file}" ]; then
      echo "${checksum_file}"
      return 0
    else
      log WARN "Downloaded checksum file is empty"
      rm -f "${checksum_file}"
    fi
  fi

  if [[ "${checksum_url}" == "https://github.com/"* ]] && [[ -n "${GITHUB_ACCELERATOR_URL:-}" ]]; then
    accelerator_url="${GITHUB_ACCELERATOR_URL%/}/${checksum_url}"
    log WARN "Official checksum unavailable, trying accelerator: ${accelerator_url}"
    if wget -q "${accelerator_url}" -O "${checksum_file}" 2>/dev/null && [ -s "${checksum_file}" ]; then
      echo "${checksum_file}"
      return 0
    fi
    rm -f "${checksum_file}"
  fi

  return 1
}

# ============================================
# 验证校验码
# ============================================
# ============================================
# PGP key import (pre-download path)
# ============================================
# The upstream public keys ship inside this tree (keys/*.asc, fingerprints
# pinned in keys/README.md - install.sh imports the same set for the install
# path). Idempotent: re-importing a known key is a no-op for gpg. An import
# failure means the tree is incomplete or tampered with, and verifying
# against it would be meaningless.
import_pgp_keys() {
  local key_dir="$1"
  if [ ! -d "${key_dir}" ] || ! ls "${key_dir}"/*.asc >/dev/null 2>&1; then
    log ERROR "keys/ with the upstream PGP public keys is missing from this tree - cannot verify signatures"
    return 1
  fi
  gpg --import "${key_dir}"/*.asc >/dev/null 2>&1 || {
    log ERROR "gpg --import failed for ${key_dir}/*.asc"
    return 1
  }
  return 0
}

verify_checksum() {
  local file=$1
  local checksum_file=$2
  local checksum_type=$3
  local filename=$4
  
  if [ ! -f "$file" ]; then
    log ERROR "File not found: $file"
    return 1
  fi
  
  if [ ! -f "$checksum_file" ]; then
    log ERROR "Checksum file not found: $checksum_file"
    return 1
  fi
  
  local expected_checksum=""
  local actual_checksum=""
  
  case $checksum_type in
    sha256)
      # 按文件名精确匹配（GNU 双空格 / BSD 星号）。多文件 digest 必须命中
      # 当前文件名；禁止 head -1 猜第一个条目——那会拿错对象的校验和去比。
      expected_checksum=$(grep -E "  ${filename}$|\*${filename}$" "$checksum_file" | awk '{print $1}')
      actual_checksum=$(sha256sum "$file" | awk '{print $1}')
      ;;
    sha1)
      # 支持 GNU 格式 (双空格) 和 BSD 格式 (星号)；同样禁止 head -1 兜底
      expected_checksum=$(grep -E "  ${filename}$|\*${filename}$" "$checksum_file" | awk '{print $1}')
      actual_checksum=$(sha1sum "$file" | awk '{print $1}')
      ;;
    md5)
      # 支持 GNU 格式 (双空格) 和 BSD 格式 (星号)；同样禁止 head -1 兜底
      expected_checksum=$(grep -E "  ${filename}$|\*${filename}$" "$checksum_file" | awk '{print $1}')
      actual_checksum=$(md5sum "$file" | awk '{print $1}')
      ;;
    asc)
      # PGP signature verification - mirrors verify_pgp_signature in
      # include/check_download.sh (the install path): a BAD signature or an
      # unverifiable one fails the component, never passes. The pre-download
      # path IS the offline supply chain, so it verifies exactly as strictly.
      if ! command -v gpg >/dev/null 2>&1; then
        # The install path gets gnupg from its dependency stage; this script
        # can run on a bare box before any of that, so try to self-provision.
        log WARN "gpg not found, attempting to install gnupg..."
        apt-get install -y gnupg >/dev/null 2>&1 || true
        if ! command -v gpg >/dev/null 2>&1; then
          log ERROR "gpg is not available - cannot verify PGP signatures. Install gnupg, or skip on purpose with --no-verify."
          return 1
        fi
      fi
      import_pgp_keys "${PGP_KEYS_DIR}" || return 1
      log INFO "Verifying PGP signature..."
      local gpg_out gpg_rc
      gpg_out=$(gpg --verify "$checksum_file" "$file" 2>&1)
      gpg_rc=$?
      if [ "$gpg_rc" -eq 0 ]; then
        log INFO "PGP signature verified successfully"
        return 0
      else
        if [ "$gpg_rc" -eq 1 ]; then
          log ERROR "PGP signature is BAD for ${file} (file may be tampered)"
        else
          # gpg exits 2+ when it could not check at all (e.g. signer key not
          # in the keyring) - the bundled keys make this abnormal: fail loud.
          log ERROR "PGP signature could not be verified for ${file} (gpg exit ${gpg_rc})"
        fi
        printf '%s\n' "$gpg_out" | tail -n 3 | while IFS= read -r gpg_line; do log ERROR "  gpg: ${gpg_line}"; done
        return 1
      fi
      ;;
    *)
      log ERROR "Unknown checksum type: $checksum_type"
      return 1
      ;;
  esac
  
  if [ -z "$expected_checksum" ]; then
    # 有些校验码文件直接就是校验码值（单行纯 hex）。多文件/HTML 内容
    # 会被拼成与 actual 长度不符的字符串，最终走 mismatch 失败。
    expected_checksum=$(cat "$checksum_file" | tr -d '[:space:]')
  fi
  
  if [ -z "$expected_checksum" ]; then
    log ERROR "Could not extract checksum from file (wrong format, or filename not present in a multi-file digest)"
    return 1
  fi
  
  # 转换为小写比较
  expected_checksum=$(echo "$expected_checksum" | tr '[:upper:]' '[:lower:]')
  actual_checksum=$(echo "$actual_checksum" | tr '[:upper:]' '[:lower:]')
  
  if [[ "$expected_checksum" == "$actual_checksum" ]]; then
    log INFO "Checksum verified (${checksum_type}): ${actual_checksum}"
    return 0
  else
    log ERROR "Checksum mismatch!"
    log ERROR "Expected: $expected_checksum"
    log ERROR "Actual:   $actual_checksum"
    return 1
  fi
}

# ============================================
# 下载文件
# ============================================
# Quick HEAD-like probe for mirror lag / missing files. wget exit 8 is an HTTP
# error response (including 404). Without this, mirrors that do not yet have a
# new release can consume many retries before fallback starts.
url_available() {
  local url=$1
  wget -q --spider --timeout=15 --tries=1 "$url" 2>/dev/null
  return $?
}

download_file() {
  local url=$1
  local filename=$2
  local checksum_url=$3
  local checksum_type=$4
  
  pushd "${SRC_DIR}" > /dev/null

  # Fail fast before downloading when the source is missing/unreachable.
  # Probe failures that are not clearly HTTP errors (network, DNS, TLS) still
  # fall through to wget, which has its own retry behaviour.
  local probe_rc=0
  if command -v wget >/dev/null 2>&1; then
    url_available "$url" || probe_rc=$?
  fi
  if [ ${probe_rc} -ge 4 ] && [ ${probe_rc} -lt 8 ]; then
    log WARN "Source not found (wget exit ${probe_rc}): ${url}"
    popd > /dev/null
    return 1
  fi
  if [ ${probe_rc} -eq 8 ]; then
    log WARN "Source returned HTTP error (wget exit 8): ${url}"
    popd > /dev/null
    return 1
  fi

  # GitHub can be reachable but painfully slow. Do a quick sample and prefer
  # the accelerator when the official source is lagging behind.
  if [[ "${url}" == "https://github.com/"* ]] && [ -n "${GITHUB_ACCELERATOR_URL:-}" ] && command -v curl >/dev/null 2>&1; then
    local _gh_primary_speed _gh_accel_url _gh_accel_speed _gh_min_kbps
    _gh_min_kbps="${GITHUB_SPEED_MIN_KBPS:-256}"
    _gh_min_speed=$(( _gh_min_kbps * 1024 ))
    _gh_accel_url="${GITHUB_ACCELERATOR_URL%/}/${url}"
    _gh_primary_speed=$(_url_speed_curl "${url}" "${GITHUB_SPEED_SAMPLE_BYTES:-2097152}" "${GITHUB_SPEED_TEST_SECONDS:-10}")
    if [ -n "${_gh_primary_speed}" ] && [ "${_gh_primary_speed}" -lt "${_gh_min_speed}" ]; then
      _gh_accel_speed=$(_url_speed_curl "${_gh_accel_url}" "${GITHUB_SPEED_SAMPLE_BYTES:-2097152}" "${GITHUB_SPEED_TEST_SECONDS:-10}")
      if [ -n "${_gh_accel_speed}" ] && [ "${_gh_accel_speed}" -ge "${_gh_min_speed}" ]; then
        log WARN "Official GitHub looks slow (${_gh_primary_speed} B/s < ${_gh_min_speed} B/s); switching to accelerator (${_gh_accel_speed} B/s)"
        url="${_gh_accel_url}"
      fi
    fi
  fi

  # 检查文件是否已存在
  if [ -f "${filename}" ]; then
    local filesize=$(stat -c%s "${filename}" 2>/dev/null || echo "0")
    if [ "$filesize" -gt 0 ]; then
      log INFO "File already exists: ${filename} (${filesize} bytes)"

      # 完整性探测：上次中断留下的截断文件不能当作完整缓存
      local probe_failed=n
      case "${filename}" in
        *.tar.gz|*.tgz)   command -v gzip  >/dev/null 2>&1 && ! gzip  -t "${filename}" 2>/dev/null && probe_failed=y ;;
        *.tar.xz)         command -v xz    >/dev/null 2>&1 && ! xz    -t "${filename}" 2>/dev/null && probe_failed=y ;;
        *.tar.bz2)        command -v bzip2 >/dev/null 2>&1 && ! bzip2 -t "${filename}" 2>/dev/null && probe_failed=y ;;
      esac
      if [[ "${probe_failed}" == y ]]; then
        log WARN "Existing file is corrupted (truncated?), re-downloading: ${filename}"
        rm -f "${filename}" "${filename}.part"
      else
        rm -f "${filename}.part"

      # 如果有校验码，验证已存在的文件
      if [[ -n "$checksum_url" ]] && [ -n "$checksum_type" ] && [[ "$VERIFY_CHECKSUM" == "yes" ]]; then
        local checksum_file="${filename}.${checksum_type}"
        if [ ! -f "$checksum_file" ]; then
          if download_checksum "$checksum_url" "$checksum_type" "$filename"; then
            if verify_checksum "$filename" "$checksum_file" "$checksum_type" "$filename"; then
              log INFO "Existing file verified successfully"
            else
              log WARN "Existing file failed verification, re-downloading..."
              rm -f "$filename" "$checksum_file"
              # Re-download (if-guard: a failure must not trip set -e and
              # abort the whole script — only this component should fail)
              if download_file "$url" "$filename" "$checksum_url" "$checksum_type"; then
                popd > /dev/null
                return 0
              else
                popd > /dev/null
                return 1
              fi
            fi
          fi
        else
          # 校验码文件已在：校验失败则删掉重下（原来只告警就放行，坏文件会一路带进编译）
          if ! verify_checksum "$filename" "$checksum_file" "$checksum_type" "$filename"; then
            log WARN "Existing file failed checksum verification, re-downloading..."
            rm -f "$filename" "$checksum_file"
            # if-guard: a failure must not trip set -e and abort the whole
            # script — only this component should fail
            if download_file "$url" "$filename" "$checksum_url" "$checksum_type"; then
              popd > /dev/null
              return 0
            else
              popd > /dev/null
              return 1
            fi
          fi
        fi
      fi

      popd > /dev/null
      return 0
      fi
    fi
  fi
  
  log INFO "Downloading: ${url}"

  # 下载到 .part 临时文件：最终文件名只会在完整下载后才出现；
  # 失败时保留 .part 以便下次 -c 断点续传。
  # 注意：无 pipefail 时 $? 是 tee 的退出码，必须用 PIPESTATUS[0]
  # 判定 wget 的真实退出码（tee 几乎总是成功，会吞掉下载错误）。
  local part_file="${filename}.part"
  wget --progress=bar:force -c "${url}" -O "${part_file}" 2>&1 | tee -a "${LOG_FILE}"
  local wget_rc=${PIPESTATUS[0]}
  if [ ${wget_rc} -eq 8 ]; then
    log WARN "Download source returned HTTP error; skipping retries: ${url}"
    [ -f "${part_file}" ] && [ ! -s "${part_file}" ] && rm -f "${part_file}"
    popd > /dev/null
    return 1
  fi
  if [ ${wget_rc} -eq 0 ] && [ -s "${part_file}" ]; then
    mv -f "${part_file}" "${filename}"
    if [ -f "${filename}" ]; then
      local filesize=$(stat -c%s "${filename}" 2>/dev/null || echo "0")
      if [ "$filesize" -gt 0 ]; then
        log INFO "Downloaded: ${filename} (${filesize} bytes)"

        # 下载并验证校验码
        if [[ -n "$checksum_url" ]] && [ -n "$checksum_type" ] && [[ "$VERIFY_CHECKSUM" == "yes" ]]; then
          local checksum_ok=0
          if download_checksum "$checksum_url" "$checksum_type" "$filename"; then
            if verify_checksum "$filename" "${filename}.${checksum_type}" "$checksum_type" "$filename"; then
              checksum_ok=1
            else
              log ERROR "Checksum verification failed, removing corrupted file"
              rm -f "$filename" "${filename}.${checksum_type}"
              popd > /dev/null
              return 1
            fi
          fi

          if [ "$checksum_ok" -eq 0 ] && [[ "${url}" == "https://github.com/"* ]] && [[ -n "${GITHUB_ACCELERATOR_URL}" ]]; then
            local accelerator_checksum="${GITHUB_ACCELERATOR_URL%/}/${checksum_url}"
            log WARN "Official checksum unavailable, trying accelerator: ${accelerator_checksum}"
            if download_checksum "$accelerator_checksum" "$checksum_type" "$filename"; then
              if ! verify_checksum "$filename" "${filename}.${checksum_type}" "$checksum_type" "$filename"; then
                log ERROR "Checksum verification failed, removing corrupted file"
                rm -f "$filename" "${filename}.${checksum_type}"
                popd > /dev/null
                return 1
              fi
              checksum_ok=1
            fi
          fi

          if [ "$checksum_ok" -eq 0 ]; then
            log ERROR "Could not download checksum file, treating as verification failure"
            rm -f "$filename"
            popd > /dev/null
            return 1
          fi
        fi

        popd > /dev/null
        return 0
      fi
    fi
  fi

  log ERROR "Failed to download: ${url} (wget exit code: ${wget_rc})"
  # 清理空的 .part 文件；非空则保留供断点续传
  [ -f "${part_file}" ] && [ ! -s "${part_file}" ] && rm -f "${part_file}"
  # 清理可能存在的空文件
  [ -f "${filename}" ] && [ ! -s "${filename}" ] && rm -f "${filename}"
  popd > /dev/null
  return 1
}

# ============================================
# 下载组件
# ============================================
download_component() {
  local component=$1
  local mirror_mode=$2
  local found=0
  
  while IFS= read -r line; do
    # 跳过注释和空行
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    [[ ! "$line" =~ \| ]] && continue
    
    # 新格式: 组件名|官方源|国内镜像|文件名|校验码URL|校验码类型|备用源|重命名目录
    local name=$(echo "$line" | cut -d'|' -f1)
    local official_url=$(echo "$line" | cut -d'|' -f2 | sed "s|\${MIRROR_BASE_URL}|${MIRROR_BASE_URL}|g" | sed "s|\${GITHUB_ACCELERATOR_URL}|${GITHUB_ACCELERATOR_URL}|g")
    local china_url=$(echo "$line" | cut -d'|' -f3 | sed "s|\${MIRROR_BASE_URL}|${MIRROR_BASE_URL}|g" | sed "s|\${GITHUB_ACCELERATOR_URL}|${GITHUB_ACCELERATOR_URL}|g")
    local filename_template=$(echo "$line" | cut -d'|' -f4)
    local checksum_url_template=$(echo "$line" | cut -d'|' -f5 | sed "s|\${MIRROR_BASE_URL}|${MIRROR_BASE_URL}|g" | sed "s|\${GITHUB_ACCELERATOR_URL}|${GITHUB_ACCELERATOR_URL}|g")
    local checksum_type=$(echo "$line" | cut -d'|' -f6)
    local fallback_url_template=$(echo "$line" | cut -d'|' -f7 | sed "s|\${MIRROR_BASE_URL}|${MIRROR_BASE_URL}|g" | sed "s|\${GITHUB_ACCELERATOR_URL}|${GITHUB_ACCELERATOR_URL}|g")
    local rename_dir_template=$(echo "$line" | cut -d'|' -f8)
    
    # 替换架构变量
    official_url=$(echo "$official_url" | sed "s/{arch_i}/${SYS_ARCH_I}/g" | sed "s/{arch_n}/${SYS_ARCH_N}/g" | sed "s/{arch_m}/${SYS_ARCH_M}/g" | sed "s/{glibc_tag}/${GLIBC_TAG}/g")
    china_url=$(echo "$china_url" | sed "s/{arch_i}/${SYS_ARCH_I}/g" | sed "s/{arch_n}/${SYS_ARCH_N}/g" | sed "s/{arch_m}/${SYS_ARCH_M}/g" | sed "s/{glibc_tag}/${GLIBC_TAG}/g")
    filename_template=$(echo "$filename_template" | sed "s/{arch_i}/${SYS_ARCH_I}/g" | sed "s/{arch_n}/${SYS_ARCH_N}/g" | sed "s/{arch_m}/${SYS_ARCH_M}/g" | sed "s/{glibc_tag}/${GLIBC_TAG}/g")
    
    if [[ "$name" == "$component" ]]; then
      found=1
      local ver=$(get_version "$component")
      
      if [ -z "$ver" ]; then
        log WARN "Version not found for component: $component"
        return 1
      fi
      
      # 选择镜像源
      local url_template
      if [[ "$mirror_mode" == "china" ]]; then
        url_template="$china_url"
      else
        url_template="$official_url"
      fi
      
      local download_info=$(build_download_url "$url_template" "$filename_template" "$ver")
      local url=$(echo "$download_info" | cut -d'|' -f1)
      local filename=$(echo "$download_info" | cut -d'|' -f2)
      
      # 构建校验码 URL
      local checksum_url=""
      if [ -n "$checksum_url_template" ]; then
        checksum_url=$(echo "$checksum_url_template" | sed "s/{ver}/$ver/g")
        local ver_dash="${ver//_/-}"
        checksum_url=$(echo "$checksum_url" | sed "s/{ver_dash}/$ver_dash/g")
        local ver_underscore=$(echo "$ver" | sed 's/\./_/g')
        checksum_url=$(echo "$checksum_url" | sed "s/{ver_underscore}/$ver_underscore/g")
      fi
      
      log INFO "Component: $component, Version: $ver, Mirror: $mirror_mode"
      
      # 尝试下载
      if download_file "$url" "$filename" "$checksum_url" "$checksum_type"; then
        return 0
      fi
      
      # 如果国内镜像失败，尝试官方源
      if [[ "$mirror_mode" == "china" ]] && [ "$china_url" != "$official_url" ]; then
        log WARN "China mirror failed, trying official source..."
        download_info=$(build_download_url "$official_url" "$filename_template" "$ver")
        url=$(echo "$download_info" | cut -d'|' -f1)
        if download_file "$url" "$filename" "$checksum_url" "$checksum_type"; then
          return 0
        fi
      fi
      
      # 尝试备用源 (如 GitHub)
      if [ -n "$fallback_url_template" ]; then
        log WARN "Primary sources failed, trying fallback (GitHub)..."
        local fallback_url=$(echo "$fallback_url_template" | sed "s/{ver}/$ver/g")
        local ver_dash="${ver//./-}"
        fallback_url=$(echo "$fallback_url" | sed "s/{ver_dash}/$ver_dash/g")
        local ver_underscore=$(echo "$ver" | sed 's/\./_/g')
        fallback_url=$(echo "$fallback_url" | sed "s/{ver_underscore}/$ver_underscore/g")
        
        # 从备用源下载到 src 目录
        cd "${SRC_DIR}"
        if wget -q "$fallback_url" -O "$filename" 2>/dev/null; then
          # 验证文件大小（确保不是空文件或错误页）
          local file_size=$(stat -c%s "$filename" 2>/dev/null || stat -f%z "$filename" 2>/dev/null || echo "0")
          if [ "$file_size" -gt 1000 ]; then
            log INFO "Fallback download successful: $filename"
            
            # 如果需要重命名解压目录
            if [ -n "$rename_dir_template" ]; then
              local expected_dir=$(echo "$rename_dir_template" | sed "s/{ver}/$ver/g")
              expected_dir=$(echo "$expected_dir" | sed "s/{ver_dash}/$ver_dash/g")
              expected_dir=$(echo "$expected_dir" | sed "s/{ver_underscore}/$ver_underscore/g")
              
              # 解压并重命名
              local archive_name=$(tar -tzf "$filename" 2>/dev/null | head -1 | cut -d'/' -f1)
              if [ -n "$archive_name" ] && [ "$archive_name" != "$expected_dir" ]; then
                tar -xzf "$filename" 2>/dev/null
                if [ -d "$archive_name" ]; then
                  mv "$archive_name" "$expected_dir"
                  # 重新打包为期望的文件名格式
                  tar -czf "$filename" "$expected_dir"
                  rm -rf "$expected_dir"
                  log INFO "Renamed archive directory: $archive_name -> $expected_dir"
                fi
              fi
            fi
            
            cd - > /dev/null
            return 0
          else
            log WARN "Fallback download appears corrupted, removing..."
            rm -f "$filename"
          fi
        fi
        cd - > /dev/null
      fi
      
      return 1
    fi
  done < "${SOURCES_FILE}"
  
  if [ $found -eq 0 ]; then
    log ERROR "Component not found in sources.conf: $component"
    return 1
  fi
}

# ============================================
# 列出所有可用组件
# ============================================
list_components() {
  printf "%b" "${CYAN}Available components:${NC}\n"
  echo ""
  printf "%-20s %-12s %-15s %s\n" "Component" "Version" "Mirrors" "Checksum"
  printf "%-20s %-12s %-15s %s\n" "---------" "-------" "-------" "--------"
  
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    [[ ! "$line" =~ \| ]] && continue
    
    local name=$(echo "$line" | cut -d'|' -f1)
    local official_url=$(echo "$line" | cut -d'|' -f2 | sed "s|\${MIRROR_BASE_URL}|${MIRROR_BASE_URL}|g" | sed "s|\${GITHUB_ACCELERATOR_URL}|${GITHUB_ACCELERATOR_URL}|g")
    local china_url=$(echo "$line" | cut -d'|' -f3 | sed "s|\${MIRROR_BASE_URL}|${MIRROR_BASE_URL}|g" | sed "s|\${GITHUB_ACCELERATOR_URL}|${GITHUB_ACCELERATOR_URL}|g")
    local checksum_type=$(echo "$line" | cut -d'|' -f6)
    
    # 替换架构变量
    official_url=$(echo "$official_url" | sed "s/{arch_i}/${SYS_ARCH_I}/g" | sed "s/{arch_n}/${SYS_ARCH_N}/g" | sed "s/{arch_m}/${SYS_ARCH_M}/g" | sed "s/{glibc_tag}/${GLIBC_TAG}/g")
    china_url=$(echo "$china_url" | sed "s/{arch_i}/${SYS_ARCH_I}/g" | sed "s/{arch_n}/${SYS_ARCH_N}/g" | sed "s/{arch_m}/${SYS_ARCH_M}/g" | sed "s/{glibc_tag}/${GLIBC_TAG}/g")
    local ver=$(get_version "$name")
    
    local mirror_status=""
    if [[ -z "$china_url" || "$official_url" == "$china_url" ]]; then
      mirror_status="official only"
    else
      mirror_status="official + china"
    fi
    
    local checksum_status="${checksum_type:-none}"
    
    if [ -n "$ver" ]; then
      printf "%-20s %-12s %-15s %s\n" "$name" "v$ver" "$mirror_status" "$checksum_status"
    else
      printf "%-20s %-12s %-15s %s\n" "$name" "N/A" "$mirror_status" "$checksum_status"
    fi
  done < "${SOURCES_FILE}"
}

# ============================================
# 下载所有组件
# ============================================
download_all() {
  local mirror_mode=$1
  local total=0
  local success=0
  local failed=0
  
  log INFO "Starting download all components (mirror: $mirror_mode)..."
  
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    [[ ! "$line" =~ \| ]] && continue
    
    local name=$(echo "$line" | cut -d'|' -f1)
    
    total=$((total+1))
    if download_component "$name" "$mirror_mode"; then
      success=$((success+1))
    else
      failed=$((failed+1))
    fi
    echo ""
  done < "${SOURCES_FILE}"
  
  echo ""
  log INFO "Download completed: Total=$total, Success=$success, Failed=$failed"
  # explicit if (not '&&' list): safe under set -e on the success path
  if [ ${failed} -gt 0 ]; then
    log WARN "${failed} component(s) failed to download"
    return 1
  fi
}

# ============================================
# 下载常用组件
# ============================================
download_common() {
  local mirror_mode=$1
  local failed=0
  log INFO "Downloading common components (mirror: $mirror_mode)..."
  
  # Web 核心组件
  local components=(
    "nginx"
    "openssl"
    "pcre"
    "nghttp2"
    "php"
    "curl"
    "freetype"
    "libsodium"
    "libzip"
    "argon2"
    "redis"
    "memcached"
    "libmemcached"
    "tcmalloc"
    "luajit2"
    "lua-nginx-module"
    "lua-resty-core"
    "lua-resty-lrucache"
    "pecl-redis"
    "pecl-memcached"
    "phpmyadmin"
    "cacert"
    # Database: the installer's default (db_option 1 = MySQL 9.7). Without a
    # database this set cannot install the M in LNMP, and --common is exactly
    # what include/download.sh points a failed downloader at - so following
    # that hint on a failed DB download used to fail a second time on the
    # same file. Other versions remain one named download away:
    #   ./download_sources.sh mariadb118
    "mysql97"
  )
  
  for comp in "${components[@]}"; do
    if ! download_component "$comp" "$mirror_mode"; then
      failed=$((failed+1))
    fi
    echo ""
  done
  if [ ${failed} -gt 0 ]; then
    log WARN "${failed} component(s) failed to download"
    return 1
  fi
}

# ============================================
# 显示帮助
# ============================================
show_help() {
  echo "Usage: $0 [OPTIONS] [COMPONENTS...]"
  echo ""
  echo "Download components from official sources or China mirrors to src/ directory."
  echo ""
  echo "Options:"
  echo "  --all          Download all components"
  echo "  --common       Download commonly used components only"
  echo "  --list         List all available components"
  echo "  --check        Check which files already exist"
  echo "  --china        Force use China mirrors"
  echo "  --official     Force use official sources"
  echo "  --no-verify    Skip checksum verification"
  echo "  -h, --help     Show this help message"
  echo ""
  echo "Environment Variables:"
  echo "  MIRROR_MODE      Set to 'china', 'official', or 'auto' (default: auto)"
  echo "  VERIFY_CHECKSUM  Set to 'yes' or 'no' (default: yes)"
  echo ""
  echo "Checksum Verification:"
  echo "  Supported types: sha256, sha1, md5, asc (PGP signature)"
  echo "  PGP verification requires gnupg and imported keys"
  echo ""
  echo "Examples:"
  echo "  $0 nginx php redis          # Download specific components"
  echo "  $0 --all                    # Download all components"
  echo "  $0 --common                 # Download common components"
  echo "  $0 --china nginx            # Download using China mirror"
  echo "  $0 --no-verify nginx        # Skip checksum verification"
  echo "  VERIFY_CHECKSUM=no $0 --all # Disable verification for all"
}

# ============================================
# 检查已有文件
# ============================================
check_existing() {
  printf "%b" "${CYAN}Existing files in src/ directory:${NC}\n"
  echo ""
  
  if [ ! -d "${SRC_DIR}" ]; then
    echo "src/ directory does not exist."
    return
  fi
  
  local count=0
  local total_size=0
  
  for f in "${SRC_DIR}"/*; do
    if [ -f "$f" ]; then
      local filename=$(basename "$f")
      local size=$(stat -c%s "$f" 2>/dev/null || echo "0")
      local size_mb=$((size / 1024 / 1024))
      printf "%-40s %6d MB\n" "$filename" "$size_mb"
      count=$((count+1))
      total_size=$((total_size+size))
    fi
  done
  
  echo ""
  local total_mb=$((total_size / 1024 / 1024))
  echo "Total: $count files, ${total_mb} MB"
}

# ============================================
# 主程序
# ============================================
main() {
  # 检查必要文件
  if [ ! -f "${SOURCES_FILE}" ]; then
    printf "%b" "${RED}ERROR: sources.conf not found${NC}\n"
    exit 1
  fi
  
  # 创建 src 目录
  mkdir -p "${SRC_DIR}"
  
  # 加载版本信息
  load_versions
  
  # 初始化日志
  echo "=== Download started at $(date) ===" > "${LOG_FILE}"
  
  # 解析参数
  local components=()
  local mode="select"
  local force_mirror=""
  
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      --list)
        list_components
        exit 0
        ;;
      --all)
        mode="all"
        shift
        ;;
      --common)
        mode="common"
        shift
        ;;
      --check)
        check_existing
        exit 0
        ;;
      --china)
        force_mirror="china"
        shift
        ;;
      --official)
        force_mirror="official"
        shift
        ;;
      --no-verify)
        VERIFY_CHECKSUM="no"
        shift
        ;;
      -*)
        printf "%b" "${RED}Unknown option: ${NC}\n"
        show_help
        exit 1
        ;;
      *)
        components+=("$1")
        shift
        ;;
    esac
  done
  
  # 确定镜像模式
  local mirror_mode
  if [ -n "$force_mirror" ]; then
    mirror_mode="$force_mirror"
  else
    mirror_mode=$(get_mirror_mode)
  fi
  
  log INFO "Using mirror mode: $mirror_mode"
  log INFO "Checksum verification: $VERIFY_CHECKSUM"
  
  # 执行下载
  case "$mode" in
    all)
      download_all "$mirror_mode" || exit 1
      ;;
    common)
      download_common "$mirror_mode" || exit 1
      ;;
    select)
      if [ ${#components[@]} -eq 0 ]; then
        show_help
        exit 1
      fi
      local select_failed=0
      for comp in "${components[@]}"; do
        if ! download_component "$comp" "$mirror_mode"; then
          select_failed=$((select_failed+1))
        fi
        echo ""
      done
      if [ ${select_failed} -gt 0 ]; then
        log WARN "${select_failed} component(s) failed to download"
        exit 1
      fi
      ;;
  esac
  
  echo ""
  log INFO "Done. Log file: ${LOG_FILE}"
}

# Run only when executed, not when sourced (tools/test_offline.sh sources
# this file to exercise verify_checksum offline).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
