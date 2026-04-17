#!/bin/bash
# Author:  Alpha Eva <kaneawk AT gmail.com>
# SPDX-License-Identifier: Apache-2.0
# Description: Download management with verified mirror support
#
# Mirror support is limited to components confirmed available:
#   - Node.js, MariaDB, OpenResty, libiconv, binutils
# All other components use official sources directly.

# ============================================
# OpenSSL version check (for Argon2 support)
# OpenSSL 3.2+ has built-in Argon2 support
openssl_ver_ge_32() {
  local ver
  ver=$(openssl version 2>/dev/null | awk '{print $2}')
  if [ -z "$ver" ]; then
    return 1
  fi
  local major=$(echo "$ver" | cut -d. -f1)
  local minor=$(echo "$ver" | cut -d. -f2)
  if [[ "$major" -ge 4 ]]; then
    return 0
  elif [[ "$major" -eq 3 ]]; then
    if [[ "$minor" -ge 2 ]]; then
      return 0
    fi
  fi
  return 1
}

# ============================================

# 计算 SHA256
compute_sha256() {
  local file=$1
  sha256sum "$file" 2>/dev/null | awk '{print $1}'
}

# 计算 MD5
compute_md5() {
  local file=$1
  md5sum "$file" 2>/dev/null | awk '{print $1}'
}

# 验证 SHA256 校验码
# 参数: 文件名 校验码URL
verify_sha256() {
  local file_name=$1
  local checksum_url=$2
  
  [ "${VERIFY_CHECKSUM}" != "yes" ] && return 0
  [ -n "$checksum_url" ] || return 0
  
  echo "Verifying SHA256 checksum for ${file_name}..."
  
  if wget -q "$checksum_url" -O "${file_name}.sha256" 2>/dev/null; then
    # 校验和文件可能是 "sha256" 或 "sha256  filename" 格式，只取第一个字段
    local expected=$(awk '{print $1}' "${file_name}.sha256" | tr -d '[:space:]')
    local actual=$(compute_sha256 "$file_name")
    
    if [[ "$expected" == "$actual" ]]; then
      echo "${CGREEN}Checksum verified: ${actual}${CEND}"
      return 0
    else
      echo "${CFAILURE}Checksum mismatch!${CEND}"
      echo "Expected: $expected"
      echo "Actual:   $actual"
      return 1
    fi
  else
    echo "${CYELLOW}Could not download checksum file, skipping verification${CEND}"
    return 0
  fi
}

# 验证 SHA1 校验码
# 参数: 文件名 校验码URL
verify_sha1() {
  local file_name=$1
  local checksum_url=$2
  
  [ "${VERIFY_CHECKSUM}" != "yes" ] && return 0
  [ -n "$checksum_url" ] || return 0
  
  echo "Verifying SHA1 checksum for ${file_name}..."
  
  if wget -q "$checksum_url" -O "${file_name}.sha1" 2>/dev/null; then
    local expected=$(awk '{print $1}' "${file_name}.sha1" | tr -d '[:space:]')
    local actual=$(sha1sum "$file_name" 2>/dev/null | awk '{print $1}')
    
    if [[ "$expected" == "$actual" ]]; then
      echo "${CGREEN}SHA1 checksum verified: ${actual}${CEND}"
      return 0
    else
      echo "${CFAILURE}SHA1 checksum mismatch!${CEND}"
      echo "Expected: $expected"
      echo "Actual:   $actual"
      return 1
    fi
  else
    echo "${CYELLOW}Could not download SHA1 checksum file, skipping verification${CEND}"
    return 0
  fi
}

# 验证 PHP SHA256 校验码（使用 PHP releases API）
# 参数: 文件名 PHP版本号
# PHP.net 不提供独立的 .sha256 文件，需要通过 API 获取
verify_php_sha256() {
  local file_name=$1
  local php_ver=$2
  
  [ "${VERIFY_CHECKSUM}" != "yes" ] && return 0
  
  echo "Verifying SHA256 checksum for ${file_name}..."
  
  # 从 PHP releases API 获取校验和（使用 JSON 格式，比序列化格式更可靠）
  local api_url="https://www.php.net/releases/index.php?json&version=${php_ver}&max=1"
  local api_response
  
  api_response=$(curl -s --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null)
  
  if [ -z "$api_response" ]; then
    echo "${CYELLOW}Could not fetch PHP releases API, skipping verification${CEND}"
    return 0
  fi
  
  # 从 JSON 中提取对应文件的 sha256
  # JSON 格式: {"8.3.20":{"source":[{"filename":"php-8.3.20.tar.gz","sha256":"..."}]}}
  local expected
  expected=$(echo "$api_response" | grep -oP "\"${file_name}\"[^}]*\"sha256\"\s*:\s*\"\K[a-f0-9]{64}" | head -1)
  
  if [ -z "$expected" ]; then
    echo "${CYELLOW}Could not parse SHA256 from API response, skipping verification${CEND}"
    return 0
  fi
  
  local actual
  actual=$(compute_sha256 "$file_name")
  
  if [[ "$expected" == "$actual" ]]; then
    echo "${CGREEN}Checksum verified: ${actual}${CEND}"
    return 0
  else
    echo "${CFAILURE}Checksum mismatch!${CEND}"
    echo "Expected: $expected"
    echo "Actual:   $actual"
    return 1
  fi
}

# 验证 MD5 校验码（带重试下载）
# 参数: 文件名 MD5校验码URL 下载URL
verify_md5_with_retry() {
  local file_name=$1
  local md5_url=$2
  local download_url=$3
  
  [ "${VERIFY_CHECKSUM}" != "yes" ] && return 0
  
  # 下载 MD5 文件
  wget -q "$md5_url" -O "${file_name}.md5" 2>/dev/null || {
    echo "${CYELLOW}Could not download MD5 file${CEND}"
    return 0
  }
  
  local expected_md5=$(awk '{print $1}' "${file_name}.md5")
  [ -z "$expected_md5" ] && expected_md5=$(curl -s "$md5_url" | grep "$file_name" | awk '{print $1}')
  
  if [ -z "$expected_md5" ]; then
    echo "${CYELLOW}Could not extract MD5 from file${CEND}"
    return 0
  fi
  
  # 验证并重试下载
  local try_count=0
  local actual_md5=$(compute_md5 "$file_name")
  
  while [ "$actual_md5" != "$expected_md5" ]; do
    echo "${CYELLOW}MD5 mismatch, retrying download... (${try_count}/6)${CEND}"
    wget -c "$download_url" -O "$file_name" 2>/dev/null
    ((try_count++))
    actual_md5=$(compute_md5 "$file_name")
    [[ "$actual_md5" == "$expected_md5" ]] || [ "$try_count" -ge 6 ] && break
  done
  
  if [ "$try_count" -ge 6 ] && [ "$actual_md5" != "$expected_md5" ]; then
    die_hard "${file_name} download failed after 6 retries"
  fi
  
  echo "${CGREEN}MD5 checksum verified${CEND}"
  return 0
}

# 验证 PGP 签名
# 参数: 文件名 签名URL 组件名
verify_pgp_signature() {
  local file_name=$1
  local sig_url=$2
  local component=$3
  
  [ "${VERIFY_CHECKSUM}" != "yes" ] && return 0
  ! command -v gpg >/dev/null 2>&1 && return 0
  
  echo "Downloading ${component} PGP signature..."
  
  if wget -q "$sig_url" -O "${file_name}.asc" 2>/dev/null; then
    if gpg --verify "${file_name}.asc" "$file_name" 2>/dev/null; then
      echo "${CGREEN}${component} PGP signature verified${CEND}"
    else
      echo "${CYELLOW}${component} PGP signature verification skipped (key may not be imported)${CEND}"
    fi
  else
    echo "${CYELLOW}Could not download ${component} PGP signature${CEND}"
  fi
}

download_openssl() {
  echo "Download openSSL..."
  local file_name="openssl-${openssl_ver}.tar.gz"
  local official_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/${file_name}"
  local china_url="${MIRROR_BASE_URL}/openssl/source/${file_name}"
  src_url=$(get_mirror_url "$official_url" "$china_url" "$USE_CHINA_MIRROR")
  Download_src
  # OpenSSL GitHub releases 提供 SHA256 校验
  local checksum_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/${file_name}.sha256"
  verify_sha256 "$file_name" "$checksum_url"
}

checkDownload() {
  pushd ${current_dir}/src > /dev/null

  # Mirror detection
  if [[ "${MIRROR_MODE}" == "china" ]]; then
    USE_CHINA_MIRROR="y"
  elif [[ "${MIRROR_MODE}" == "official" ]]; then
    USE_CHINA_MIRROR="n"
  else
    init_mirror
  fi
  echo "Mirror mode: $([[ "$USE_CHINA_MIRROR" == "y" ]] && echo "China (MIRROR_BASE_URL)" || echo "Official sources")"

  VERIFY_CHECKSUM="${VERIFY_CHECKSUM:-yes}"

  # icu (GitHub only)
  if ! command -v icu-config >/dev/null 2>&1 || ! icu-config --version | grep -q '^3.' || [[ "${Ubuntu_ver}" == "20" ]]; then
    echo "Download icu..."
    src_url="https://github.com/unicode-org/icu/releases/download/release-${icu4c_ver/_/-}/icu4c-${icu4c_ver}-src.tgz"
    Download_src
  fi

  # OpenSSL for legacy or nginx
  if [[ "${with_old_openssl_flag}" == y ]]; then
    download_openssl
    echo "Download cacert.pem..."
    src_url=https://curl.se/ca/cacert.pem && Download_src
  fi
  if [[ ${nginx_option} =~ ^[1-3]$ ]]; then
    download_openssl
  fi

  # tcmalloc (GitHub releases)
  if [[ ${nginx_option} =~ ^[1-3]$ ]] || [[ "${db_option}" =~ ^[1-6]$ ]]; then
    echo "Download tcmalloc (gperftools)..."
    src_url="https://github.com/gperftools/gperftools/releases/download/gperftools-${tcmalloc_ver}/gperftools-${tcmalloc_ver}.tar.gz"
    Download_src
  fi

  # Nginx/Tengine/OpenResty
  case "${nginx_option}" in
    1)
      echo "Download nginx..."
      src_url="https://nginx.org/download/nginx-${nginx_ver}.tar.gz"
      local file_name="nginx-${nginx_ver}.tar.gz"
      Download_src
      verify_pgp_signature "$file_name" "https://nginx.org/download/nginx-${nginx_ver}.tar.gz.asc" "Nginx"
      ;;
    2)
      echo "Download tengine..."
      src_url="https://tengine.taobao.org/download/tengine-${tengine_ver}.tar.gz"
      Download_src
      ;;
    3)
      echo "Download openresty..."
      # ✅ Confirmed available on Tsinghua mirror
      local official_url="https://openresty.org/download/openresty-${openresty_ver}.tar.gz"
      local china_url="${MIRROR_BASE_URL}/openresty/openresty-${openresty_ver}.tar.gz"
      local file_name="openresty-${openresty_ver}.tar.gz"
      src_url=$(get_mirror_url "$official_url" "$china_url" "$USE_CHINA_MIRROR")
      Download_src
      verify_pgp_signature "$file_name" "https://openresty.org/download/openresty-${openresty_ver}.tar.gz.asc" "OpenResty"
      ;;
  esac

  # PCRE2 (GitHub releases)
  if [[ "${nginx_option}" =~ ^[1-3]$ ]]; then
    echo "Download pcre2..."
    src_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_ver}/pcre2-${pcre_ver}.tar.gz"
    Download_src
  fi

  # ============================================
  # Database downloads
  # ============================================
  if [[ "${db_option}" =~ ^[1-6]$ ]]; then
    if [[ "${db_option}" =~ ^[2-5]$ ]] && [[ "${dbinstallmethod}" == "2" ]]; then
      [[ "${db_option}" =~ ^[2-5]$ ]] && boost_ver=${boost_oldver}
      echo "Download boost..."
      boostVersion2=$(echo ${boost_ver} | awk -F. '{print $1"_"$2"_"$3}')
      src_url="https://downloads.sourceforge.net/project/boost/boost/${boost_ver}/boost_${boostVersion2}.tar.gz"
      Download_src
    fi

    case "${db_option}" in
      1)
        # MySQL 8.4
        if [[ "${dbinstallmethod}" == "1" ]]; then
          echo "Download MySQL 8.4 binary..."
          FILE_NAME=mysql-${mysql84_ver}-linux-glibc2.28-x86_64.tar.xz
        else
          echo "Download MySQL 8.4 source..."
          FILE_NAME=mysql-${mysql84_ver}.tar.gz
        fi
        src_url="https://cdn.mysql.com/Downloads/MySQL-8.4/${FILE_NAME}"
        Download_src
        verify_md5_with_retry "$FILE_NAME" "https://cdn.mysql.com/Downloads/MySQL-8.4/${FILE_NAME}.md5" "$src_url"
        ;;
      2)
        # MySQL 8.0
        if [[ "${dbinstallmethod}" == "1" ]]; then
          echo "Download MySQL 8.0 binary..."
          FILE_NAME=mysql-${mysql80_ver}-linux-glibc2.28-x86_64.tar.xz
        else
          echo "Download MySQL 8.0 source..."
          FILE_NAME=mysql-${mysql80_ver}.tar.gz
        fi
        src_url="https://cdn.mysql.com/Downloads/MySQL-8.0/${FILE_NAME}"
        Download_src
        verify_md5_with_retry "$FILE_NAME" "https://cdn.mysql.com/Downloads/MySQL-8.0/${FILE_NAME}.md5" "$src_url"
        ;;
      [3-5])
        case "${db_option}" in
          3) mariadb_ver=${mariadb118_ver} ;;
          4) mariadb_ver=${mariadb114_ver} ;;
          5) mariadb_ver=${mariadb1011_ver} ;;
        esac
        if [[ "${dbinstallmethod}" == "1" ]]; then
          FILE_NAME=mariadb-${mariadb_ver}-linux-systemd-x86_64.tar.gz
          FILE_TYPE=bintar-linux-systemd-x86_64
        else
          FILE_NAME=mariadb-${mariadb_ver}.tar.gz
          FILE_TYPE=source
        fi
        echo "Download MariaDB ${FILE_NAME}..."
        # ✅ Confirmed available on Tsinghua mirror
        local official_url="https://archive.mariadb.org/mariadb-${mariadb_ver}/${FILE_TYPE}/${FILE_NAME}"
        local china_url="${MIRROR_BASE_URL}/mariadb/mariadb-${mariadb_ver}/${FILE_TYPE}/${FILE_NAME}"
        src_url=$(get_mirror_url "$official_url" "$china_url" "$USE_CHINA_MIRROR")
        Download_src
        verify_md5_with_retry "$FILE_NAME" "https://archive.mariadb.org/mariadb-${mariadb_ver}/${FILE_TYPE}/md5sums.txt" "$src_url"
        ;;
      6)
        # PostgreSQL (APT repo or source)
        if [[ "${pgsqlinstallmethod}" == "2" ]]; then
          echo "Download PostgreSQL source..."
          src_url="https://ftp.postgresql.org/pub/source/v${pgsql_ver}/postgresql-${pgsql_ver}.tar.gz"
          Download_src
        else
          echo "PostgreSQL will be installed from APT repository."
        fi
        ;;
    esac
  fi

  # ============================================
  # PHP downloads
  # ============================================
  if [[ "${php_option}" =~ ^[1-3]$ ]] || [[ "${mphp_ver}" =~ ^8[3-5]$ ]]; then
    echo "PHP dependencies..."
    # libiconv - ✅ Confirmed on mirror
    local official_url="https://ftp.gnu.org/gnu/libiconv/libiconv-${libiconv_ver}.tar.gz"
    local china_url="${MIRROR_BASE_URL}/gnu/libiconv/libiconv-${libiconv_ver}.tar.gz"
    src_url=$(get_mirror_url "$official_url" "$china_url" "$USE_CHINA_MIRROR")
    Download_src

    # curl (official only)
    src_url="https://curl.se/download/curl-${curl_ver}.tar.gz"
    Download_src
    verify_pgp_signature "curl-${curl_ver}.tar.gz" "https://curl.se/download/curl-${curl_ver}.tar.gz.asc" "Curl"

    # freetype (official only)
    src_url="https://download.savannah.gnu.org/releases/freetype/freetype-${freetype_ver}.tar.gz"
    Download_src

    # argon2 (GitHub) - only needed when can't use OpenSSL built-in Argon2
    # Requires PHP 8.4+ AND OpenSSL 3.2+ to skip
    # php_option: 1=8.3, 2=8.4, 3=8.5 | mphp_ver: 83, 84, 85
    local need_argon2=false
    if [[ "${php_option}" == "1" ]] || [[ "${mphp_ver}" == "83" ]]; then
      need_argon2=true
    elif [[ "${php_option}" =~ ^[23]$ ]] || [[ "${mphp_ver}" =~ ^8[45]$ ]]; then
      # PHP 8.4/8.5 - check OpenSSL version
      if ! openssl_ver_ge_32; then
        need_argon2=true
      fi
    fi
    if [[ "${need_argon2}" == "true" ]]; then
      echo "Download argon2 (OpenSSL < 3.2 or PHP < 8.4)..."
      src_url="https://github.com/P-H-C/phc-winner-argon2/archive/refs/tags/${argon2_ver}.tar.gz"
      Download_src
    fi

    # libsodium (official only)
    src_url="https://download.libsodium.org/libsodium/releases/libsodium-${libsodium_ver}.tar.gz"
    Download_src
    verify_pgp_signature "libsodium-${libsodium_ver}.tar.gz" "https://download.libsodium.org/libsodium/releases/libsodium-${libsodium_ver}.tar.gz.sig" "libsodium"

    # libzip (official only)
    src_url="https://libzip.org/download/libzip-${libzip_ver}.tar.gz"
    Download_src

    # binutils - ✅ Confirmed on mirror
    local official_url="https://ftp.gnu.org/gnu/binutils/binutils-${binutils_ver}.tar.gz"
    local china_url="${MIRROR_BASE_URL}/gnu/binutils/binutils-${binutils_ver}.tar.gz"
    src_url=$(get_mirror_url "$official_url" "$china_url" "$USE_CHINA_MIRROR")
    Download_src

    # mhash (SourceForge)
    src_url="https://downloads.sourceforge.net/project/mhash/mhash/${mhash_ver}/mhash-${mhash_ver}.tar.gz"
    Download_src
  fi

  # PHP source
  if [ -n "$php_ver_to_use" ]; then
    echo "Download php..."
    local file_name="php-${php_ver_to_use}.tar.gz"
    src_url="https://www.php.net/distributions/php-${php_ver_to_use}.tar.gz"
    Download_src
    verify_php_sha256 "$file_name" "$php_ver_to_use"
  fi

  # APCU (PECL - official only)
  if [[ "${phpcache_option}" == "2" ]]; then
    echo "Download apcu..."
    src_url="https://pecl.php.net/get/apcu-${apcu_ver}.tgz"
    Download_src
  fi

  # ionCube (official only)
  if [[ "${pecl_ioncube}" == 1 ]]; then
    echo "Download ioncube..."
    src_url="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${SYS_ARCH_i}.tar.gz"
    Download_src
  fi

  # ImageMagick + imagick (GitHub + PECL)
  if [[ "${pecl_imagick}" == 1 ]]; then
    echo "Download ImageMagick..."
    local imagemagick_filename="ImageMagick-${imagemagick_ver}.tar.gz"
    wget --tries=6 -c -O "${imagemagick_filename}" "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${imagemagick_ver}.tar.gz"
    echo "Download imagick..."
    src_url="https://pecl.php.net/get/imagick-${imagick_ver}.tgz"
    Download_src
  fi

  # Redis server
  if [[ "${redis_flag}" == y ]]; then
    echo "Download redis-server..."
    src_url="https://download.redis.io/releases/redis-${redis_ver}.tar.gz"
    Download_src
  fi

  # PECL redis
  if [[ "${pecl_redis}" == 1 ]]; then
    echo "Download pecl_redis..."
    src_url="https://pecl.php.net/get/redis-${pecl_redis_ver}.tgz"
    Download_src
  fi

  # Memcached server
  if [[ "${memcached_flag}" == y ]]; then
    echo "Download memcached-server..."
    src_url="https://www.memcached.org/files/memcached-${memcached_ver}.tar.gz"
    Download_src
  fi

  # PECL memcached + libmemcached
  if [[ "${pecl_memcached}" == 1 ]]; then
    echo "Download libmemcached..."
    src_url="https://launchpad.net/libmemcached/1.0/${libmemcached_ver}/+download/libmemcached-${libmemcached_ver}.tar.gz"
    Download_src
    echo "Download pecl_memcached..."
    src_url="https://pecl.php.net/get/memcached-${pecl_memcached_ver}.tgz"
    Download_src
  fi

  # PECL memcache
  if [[ "${pecl_memcache}" == 1 ]]; then
    echo "Download pecl_memcache..."
    src_url="https://pecl.php.net/get/memcache-${pecl_memcache_ver}.tgz"
    Download_src
  fi

  # PECL mongodb
  if [[ "${pecl_mongodb}" == 1 ]]; then
    echo "Download pecl_mongodb..."
    src_url="https://pecl.php.net/get/mongodb-${pecl_mongodb_ver}.tgz"
    Download_src
  fi

  # Node.js - ✅ Confirmed on mirror
  if [[ "${nodejs_flag}" == y ]]; then
    echo "Download Node.js..."
    local official_url="https://nodejs.org/dist/v${nodejs_ver}/node-v${nodejs_ver}-linux-${SYS_ARCH_n}.tar.gz"
    local china_url="${MIRROR_BASE_URL}/nodejs-release/v${nodejs_ver}/node-v${nodejs_ver}-linux-${SYS_ARCH_n}.tar.gz"
    local file_name="node-v${nodejs_ver}-linux-${SYS_ARCH_n}.tar.gz"
    src_url=$(get_mirror_url "$official_url" "$china_url" "$USE_CHINA_MIRROR")
    Download_src
    if [[ "${VERIFY_CHECKSUM}" == "yes" ]]; then
      echo "Verifying Node.js checksum..."
      wget -q "https://nodejs.org/dist/v${nodejs_ver}/SHASUMS256.txt" -O "SHASUMS256.txt" 2>/dev/null && {
        expected_sha256=$(grep "${file_name}" SHASUMS256.txt | awk '{print $1}')
        actual_sha256=$(sha256sum "$file_name" | awk '{print $1}')
        [[ "$expected_sha256" == "$actual_sha256" ]] && echo "${CGREEN}Node.js checksum verified${CEND}" || echo "${CFAILURE}Node.js checksum mismatch!${CEND}"
      } || echo "${CYELLOW}Could not verify Node.js checksum${CEND}"
    fi
  fi

  # Pure-FTPd (official only)
  if [[ "${pureftpd_flag}" == y ]]; then
    echo "Download pureftpd..."
    src_url="https://download.pureftpd.org/pub/pure-ftpd/releases/pure-ftpd-${pureftpd_ver}.tar.gz"
    Download_src
  fi

  # phpMyAdmin (official only)
  if [[ "${phpmyadmin_flag}" == y ]]; then
    echo "Download phpMyAdmin..."
    local file_name="phpMyAdmin-${phpmyadmin_ver}-all-languages.tar.gz"
    src_url="https://files.phpmyadmin.net/phpMyAdmin/${phpmyadmin_ver}/${file_name}"
    Download_src
    verify_sha256 "$file_name" "https://files.phpmyadmin.net/phpMyAdmin/${phpmyadmin_ver}/${file_name}.sha256"
  fi

  popd > /dev/null
}
