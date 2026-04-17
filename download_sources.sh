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

# 日志函数
log() {
  local level=$1
  shift
  local msg="$@"
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
  
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    # 跳过注释和空行
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    # 去除前后空格
    key=$(echo "$key" | tr -d '[:space:]')
    value=$(echo "$value" | tr -d '[:space:]')
    VERSIONS[$key]=$value
  done < "${VERSIONS_FILE}"
  
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
    mysql84)        ver=${VERSIONS[mysql84_ver]} ;;
    mysql80)        ver=${VERSIONS[mysql80_ver]} ;;
    mysql-src)      ver=${VERSIONS[mysql84_ver]} ;;
    mariadb)        ver=${VERSIONS[mariadb118_ver]} ;;
    mariadb-src)    ver=${VERSIONS[mariadb118_ver]} ;;
    postgresql)     ver=${VERSIONS[pgsql18_ver]} ;;
    php)            ver=${VERSIONS[php84_ver]} ;;
    php83)          ver=${VERSIONS[php83_ver]} ;;
    php84)          ver=${VERSIONS[php84_ver]} ;;
    php85)          ver=${VERSIONS[php85_ver]} ;;
    libiconv)       ver=${VERSIONS[libiconv_ver]} ;;
    curl)           ver=${VERSIONS[curl_ver]} ;;
    freetype)       ver=${VERSIONS[freetype_ver]} ;;
    libsodium)      ver=${VERSIONS[libsodium_ver]} ;;
    libzip)         ver=${VERSIONS[libzip_ver]} ;;
    binutils)       ver=${VERSIONS[binutils_ver]} ;;
    mhash)          ver=${VERSIONS[mhash_ver]} ;;
    argon2)         ver=${VERSIONS[argon2_ver]} ;;
    icu)            ver=${VERSIONS[icu4c_ver]} ;;
    imagemagick)    ver=${VERSIONS[imagemagick_ver]} ;;
    redis)          ver=${VERSIONS[redis_ver]} ;;
    memcached)      ver=${VERSIONS[memcached_ver]} ;;
    libmemcached)   ver=${VERSIONS[libmemcached_ver]} ;;
    pureftpd)       ver=${VERSIONS[pureftpd_ver]} ;;
    nodejs)         ver=${VERSIONS[nodejs_ver]} ;;
    phpmyadmin)     ver=${VERSIONS[phpmyadmin_ver]} ;;
    tcmalloc)       ver=${VERSIONS[tcmalloc_ver]} ;;
    boost)          ver=${VERSIONS[boost_ver]} ;;
    lua-nginx-module) ver=${VERSIONS[lua_nginx_module_ver]} ;;
    ngx-devel-kit)  ver="0.3.3" ;;
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
  
  return 1
}

# ============================================
# 验证校验码
# ============================================
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
      # 先尝试匹配包含文件名的行，再尝试纯校验码
      # 支持 GNU 格式 (双空格) 和 BSD 格式 (星号)
      expected_checksum=$(grep -E "  ${filename}$|\*${filename}$" "$checksum_file" | awk '{print $1}')
      [ -z "$expected_checksum" ] && expected_checksum=$(grep -E "^[a-fA-F0-9]{64}$" "$checksum_file" | head -1)
      actual_checksum=$(sha256sum "$file" | awk '{print $1}')
      ;;
    sha1)
      # 支持 GNU 格式 (双空格) 和 BSD 格式 (星号)
      expected_checksum=$(grep -E "  ${filename}$|\*${filename}$" "$checksum_file" | awk '{print $1}')
      [ -z "$expected_checksum" ] && expected_checksum=$(grep -E "^[a-fA-F0-9]{40}$" "$checksum_file" | head -1)
      actual_checksum=$(sha1sum "$file" | awk '{print $1}')
      ;;
    md5)
      # 支持 GNU 格式 (双空格) 和 BSD 格式 (星号)
      expected_checksum=$(grep -E "  ${filename}$|\*${filename}$" "$checksum_file" | awk '{print $1}')
      [ -z "$expected_checksum" ] && expected_checksum=$(grep -E "^[a-fA-F0-9]{32}$" "$checksum_file" | head -1)
      actual_checksum=$(md5sum "$file" | awk '{print $1}')
      ;;
    asc)
      # PGP 签名验证
      if command -v gpg >/dev/null 2>&1; then
        log INFO "Verifying PGP signature..."
        if gpg --verify "$checksum_file" "$file" 2>/dev/null; then
          log INFO "PGP signature verified successfully"
          return 0
        else
          log WARN "PGP signature verification failed (key may not be imported)"
          return 0  # 不阻断安装，仅警告
        fi
      else
        log WARN "gpg not found, skipping PGP verification"
        return 0
      fi
      ;;
    *)
      log WARN "Unknown checksum type: $checksum_type"
      return 0
      ;;
  esac
  
  if [ -z "$expected_checksum" ]; then
    # 有些校验码文件直接就是校验码值
    expected_checksum=$(cat "$checksum_file" | tr -d '[:space:]')
  fi
  
  if [ -z "$expected_checksum" ]; then
    log WARN "Could not extract checksum from file"
    return 0
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
download_file() {
  local url=$1
  local filename=$2
  local checksum_url=$3
  local checksum_type=$4
  
  pushd "${SRC_DIR}" > /dev/null
  
  # 检查文件是否已存在
  if [ -f "${filename}" ]; then
    local filesize=$(stat -c%s "${filename}" 2>/dev/null || echo "0")
    if [ "$filesize" -gt 0 ]; then
      log INFO "File already exists: ${filename} (${filesize} bytes)"
      
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
              # 重新下载
              download_file "$url" "$filename" "$checksum_url" "$checksum_type"
              popd > /dev/null
              return $?
            fi
          fi
        else
          verify_checksum "$filename" "$checksum_file" "$checksum_type" "$filename"
        fi
      fi
      
      popd > /dev/null
      return 0
    fi
  fi
  
  log INFO "Downloading: ${url}"
  
  # 使用 wget 下载，支持断点续传
  if wget --progress=bar:force -c "${url}" -O "${filename}" 2>&1 | tee -a "${LOG_FILE}"; then
    if [ -f "${filename}" ]; then
      local filesize=$(stat -c%s "${filename}" 2>/dev/null || echo "0")
      if [ "$filesize" -gt 0 ]; then
        log INFO "Downloaded: ${filename} (${filesize} bytes)"
        
        # 下载并验证校验码
        if [[ -n "$checksum_url" ]] && [ -n "$checksum_type" ] && [[ "$VERIFY_CHECKSUM" == "yes" ]]; then
          if download_checksum "$checksum_url" "$checksum_type" "$filename"; then
            if ! verify_checksum "$filename" "${filename}.${checksum_type}" "$checksum_type" "$filename"; then
              log ERROR "Checksum verification failed, removing corrupted file"
              rm -f "$filename" "${filename}.${checksum_type}"
              popd > /dev/null
              return 1
            fi
          else
            log WARN "Could not download checksum file, skipping verification"
          fi
        fi
        
        popd > /dev/null
        return 0
      fi
    fi
  fi
  
  log ERROR "Failed to download: ${url}"
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
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    # 跳过注释和空行
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    [[ ! "$line" =~ \| ]] && continue
    
    # 新格式: 组件名|官方源|国内镜像|文件名|校验码URL|校验码类型|备用源|重命名目录
    local name=$(echo "$line" | cut -d'|' -f1)
    local official_url=$(echo "$line" | cut -d'|' -f2 | sed "s|\${MIRROR_BASE_URL}|${MIRROR_BASE_URL}|g")
    local china_url=$(echo "$line" | cut -d'|' -f3 | sed "s|\${MIRROR_BASE_URL}|${MIRROR_BASE_URL}|g")
    local filename_template=$(echo "$line" | cut -d'|' -f4)
    local checksum_url_template=$(echo "$line" | cut -d'|' -f5 | sed "s|\${MIRROR_BASE_URL}|${MIRROR_BASE_URL}|g")
    local checksum_type=$(echo "$line" | cut -d'|' -f6)
    local fallback_url_template=$(echo "$line" | cut -d'|' -f7)
    local rename_dir_template=$(echo "$line" | cut -d'|' -f8)
    
    # 替换架构变量
    official_url=$(echo "$official_url" | sed "s/{arch_i}/${SYS_ARCH_I}/g" | sed "s/{arch_n}/${SYS_ARCH_N}/g")
    china_url=$(echo "$china_url" | sed "s/{arch_i}/${SYS_ARCH_I}/g" | sed "s/{arch_n}/${SYS_ARCH_N}/g")
    filename_template=$(echo "$filename_template" | sed "s/{arch_i}/${SYS_ARCH_I}/g" | sed "s/{arch_n}/${SYS_ARCH_N}/g")
    
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
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    [[ ! "$line" =~ \| ]] && continue
    
    local name=$(echo "$line" | cut -d'|' -f1)
    local official_url=$(echo "$line" | cut -d'|' -f2 | sed "s|\${MIRROR_BASE_URL}|${MIRROR_BASE_URL}|g")
    local china_url=$(echo "$line" | cut -d'|' -f3 | sed "s|\${MIRROR_BASE_URL}|${MIRROR_BASE_URL}|g")
    local checksum_type=$(echo "$line" | cut -d'|' -f6)
    
    # 替换架构变量
    official_url=$(echo "$official_url" | sed "s/{arch_i}/${SYS_ARCH_I}/g" | sed "s/{arch_n}/${SYS_ARCH_N}/g")
    china_url=$(echo "$china_url" | sed "s/{arch_i}/${SYS_ARCH_I}/g" | sed "s/{arch_n}/${SYS_ARCH_N}/g")
    local ver=$(get_version "$name")
    
    local mirror_status=""
    if [[ "$official_url" == "$china_url" ]]; then
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
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    [[ ! "$line" =~ \| ]] && continue
    
    local name=$(echo "$line" | cut -d'|' -f1)
    
    ((++total))
    if download_component "$name" "$mirror_mode"; then
      ((++success))
    else
      ((++failed))
    fi
    echo ""
  done < "${SOURCES_FILE}"
  
  echo ""
  log INFO "Download completed: Total=$total, Success=$success, Failed=$failed"
}

# ============================================
# 下载常用组件
# ============================================
download_common() {
  local mirror_mode=$1
  log INFO "Downloading common components (mirror: $mirror_mode)..."
  
  # Web 核心组件
  local components=(
    "nginx"
    "openssl"
    "pcre"
    "nghttp2"
    "php"
    "libiconv"
    "curl"
    "freetype"
    "libsodium"
    "libzip"
    "argon2"
    "mhash"
    "binutils"
    "redis"
    "memcached"
    "libmemcached"
    "tcmalloc"
    "pecl-redis"
    "pecl-memcached"
    "phpmyadmin"
    "cacert"
  )
  
  for comp in "${components[@]}"; do
    download_component "$comp" "$mirror_mode" || true
    echo ""
  done
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
      ((count++))
      ((total_size += size))
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
      download_all "$mirror_mode"
      ;;
    common)
      download_common "$mirror_mode"
      ;;
    select)
      if [ ${#components[@]} -eq 0 ]; then
        show_help
        exit 1
      fi
      for comp in "${components[@]}"; do
        download_component "$comp" "$mirror_mode" || true
        echo ""
      done
      ;;
  esac
  
  echo ""
  log INFO "Done. Log file: ${LOG_FILE}"
}

main "$@"
