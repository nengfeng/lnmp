#!/bin/bash
# Author:  Alpha Eva <kaneawk AT gmail.com>
# SPDX-License-Identifier: Apache-2.0
# Description: Download management with verified mirror support
#
# Mirror support is limited to components confirmed available:
#   - Node.js, MariaDB, OpenResty, libiconv, binutils
# All other components use official sources directly.

# php_ver_ge_84 / openssl_ver_ge_32 / can_use_openssl_argon2 live in
# include/common.sh (sourced before this file), so the argon2 decision in
# checkDownload below can call them directly.

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
  [ -z "$checksum_url" ] && return 0
  
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
    echo "${CFAILURE}Failed to download checksum file${CEND}"
    return 1
  fi
}

# 验证 SHA1 校验码
# 参数: 文件名 校验码URL
verify_sha1() {
  local file_name=$1
  local checksum_url=$2
  
  [ "${VERIFY_CHECKSUM}" != "yes" ] && return 0
  [ -z "$checksum_url" ] && return 0
  
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
    echo "${CFAILURE}Failed to download SHA1 checksum file${CEND}"
    return 1
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
    echo "${CFAILURE}Could not fetch PHP releases API${CEND}"
    return 1
  fi
  
  # 从 JSON 中提取对应文件的 sha256
  # JSON 格式: {"8.3.20":{"source":[{"filename":"php-8.3.20.tar.gz","sha256":"..."}]}}
  local expected
  expected=$(echo "$api_response" | grep -oP "\"${file_name}\"[^}]*\"sha256\"\s*:\s*\"\K[a-f0-9]{64}" | head -1)
  
  if [ -z "$expected" ]; then
    echo "${CFAILURE}Could not parse SHA256 from API response${CEND}"
    return 1
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
  wget "$md5_url" -O "${file_name}.md5" || {
    echo "${CFAILURE}Could not download MD5 file (network error?)${CEND}"
    return 1
  }
  
  local expected_md5=$(awk -v f="$file_name" '$2==f || $0 ~ f {print $1; exit}' "${file_name}.md5")
  [ -z "$expected_md5" ] && expected_md5=$(curl -s "$md5_url" | grep -w "$file_name" | awk '{print $1}')
  
  if [ -z "$expected_md5" ]; then
    echo "${CFAILURE}Could not extract MD5 from file${CEND}"
    return 1
  fi
  
  # 验证并重试下载
  local try_count=0
  local actual_md5=$(compute_md5 "$file_name")
  
  while [ "$actual_md5" != "$expected_md5" ]; do
    ((try_count++))
    echo "${CYELLOW}MD5 mismatch, retrying download... (${try_count}/6)${CEND}"
    # Remove stale/corrupted file so wget does a fresh download (not resume):
    # -c resumes on an existing file, so a complete-but-corrupted tarball would
    # be left untouched and the loop would spin for 6 iterations then die_hard.
    rm -f "${file_name}"
    # Keep stderr visible and check the exit code: a network failure leaves an
    # empty/absent file (NOT a genuine MD5 mismatch), and both were previously
    # reported as the same "MD5 mismatch".
    if ! wget "$download_url" -O "${file_name}"; then
      echo "${CFAILURE}wget failed to download ${file_name} (network error?)${CEND}"
    fi
    actual_md5=$(compute_md5 "${file_name}")
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
  # gpg and the upstream public keys are now provisioned before checkDownload
  # (install.sh installs gnupg and imports keys/*.asc). A missing gpg is thus
  # an abnormal environment, not the normal path; still skip rather than fail
  # the whole install on a tooling gap.
  if ! command -v gpg >/dev/null 2>&1; then
    echo "${CYELLOW}gpg not available, skipping ${component} PGP check${CEND}"
    return 0
  fi
  
  echo "Downloading ${component} PGP signature..."
  
  wget -q "$sig_url" -O "${file_name}.asc" 2>/dev/null || {
    echo "${CFAILURE}Could not download ${component} PGP signature${CEND}"
    return 1
  }
  
  gpg --verify "${file_name}.asc" "$file_name" 2>/dev/null
  local gpg_rc=$?
  if [ "$gpg_rc" -eq 0 ]; then
    echo "${CGREEN}${component} PGP signature verified${CEND}"
    return 0
  elif [ "$gpg_rc" -eq 1 ]; then
    echo "${CFAILURE}${component} PGP signature is BAD (file may be tampered)${CEND}"
    return 1
  else
    # gpg exits 2 (and above) when it could not check at all - e.g. the
    # signer's public key is not in the keyring. The keys are imported before
    # checkDownload now, so this is abnormal: fail loudly instead of skipping.
    echo "${CFAILURE}${component} PGP signature could not be verified (exit ${gpg_rc})${CEND}"
    return 1
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
  verify_sha256 "$file_name" "$checksum_url" || die_hard "Checksum verification failed for ${file_name}"
}

checkDownload() {
  pushd ${current_dir}/src > /dev/null

  # Per-component download fallback is off by default; individual blocks that
  # support a mirror/failover source set these right before their Download_src
  # call and clear them right after so the values do not leak into the next
  # component's download.
  local src_url_fallback=""
  local src_expected_dir=""

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

  # Note: ICU is deliberately NOT downloaded. PHP intl links the distro
  # libicu (>=72 across the support window) via pkg-config -- see the guard
  # in installDepsBySrc() in include/check_sw.sh.

  # OpenSSL for legacy or nginx
  if [[ "${with_old_openssl_flag}" == y ]]; then
    download_openssl
    echo "Download cacert.pem..."
    src_url=https://curl.se/ca/cacert.pem && Download_src
  fi
  if [[ ${nginx_option} =~ ^[1-3]$ ]]; then
    download_openssl
  fi

  # Memory allocator (tcmalloc / jemalloc)
  if [[ ${nginx_option} =~ ^[1-3]$ ]] || [[ "${db_option}" =~ ^[1-8]$ ]]; then
    case "${allocator_option:-3}" in
      2)
        echo "Download tcmalloc (gperftools)..."
        src_url="https://github.com/gperftools/gperftools/releases/download/gperftools-${tcmalloc_ver}/gperftools-${tcmalloc_ver}.tar.gz"
        Download_src
        ;;
      3)
        echo "Download jemalloc..."
        src_url="https://github.com/jemalloc/jemalloc/releases/download/${jemalloc_ver}/jemalloc-${jemalloc_ver}.tar.bz2"
        Download_src
        ;;
    esac
  fi

  # Nginx/Tengine/OpenResty
  case "${nginx_option}" in
    1)
      echo "Download nginx..."
      src_url="https://nginx.org/download/nginx-${nginx_ver}.tar.gz"
      local file_name="nginx-${nginx_ver}.tar.gz"
      Download_src
      verify_pgp_signature "$file_name" "https://nginx.org/download/nginx-${nginx_ver}.tar.gz.asc" "Nginx" || die_hard "PGP signature verification failed for ${file_name}"
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
      verify_pgp_signature "$file_name" "https://openresty.org/download/openresty-${openresty_ver}.tar.gz.asc" "OpenResty" || die_hard "PGP signature verification failed for ${file_name}"
      ;;
  esac

  # PCRE2 (GitHub releases)
  if [[ "${nginx_option}" =~ ^[1-3]$ ]]; then
    echo "Download pcre2..."
    src_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_ver}/pcre2-${pcre_ver}.tar.gz"
    Download_src
  fi

  # ngx_brotli + brotli (for nginx/tengine/openresty)
  if [[ "${nginx_option}" =~ ^[1-3]$ ]]; then
    echo "Download ngx_brotli..."
    src_url="https://github.com/google/ngx_brotli/archive/refs/heads/master.tar.gz" && Download_src "ngx_brotli-master.tar.gz"
    echo "Download brotli..."
    src_url="https://github.com/google/brotli/archive/refs/tags/v${brotli_ver}.tar.gz" && Download_src "brotli-${brotli_ver}.tar.gz"
  fi

  # Lua dependencies (for nginx+tcmalloc/lua or openresty)
  if [[ "${nginx_option}" =~ ^[1-3]$ ]]; then
    echo "Download luajit2..."
    src_url="https://github.com/openresty/luajit2/archive/v${luajit2_ver}.tar.gz"
    Download_src "luajit2-${luajit2_ver}.tar.gz"
    echo "Download lua-nginx-module..."
    src_url="https://github.com/openresty/lua-nginx-module/archive/v${lua_nginx_module_ver}.tar.gz"
    Download_src "lua-nginx-module-${lua_nginx_module_ver}.tar.gz"
    echo "Download lua-resty-core..."
    src_url="https://github.com/openresty/lua-resty-core/archive/v${lua_resty_core_ver}.tar.gz"
    Download_src "lua-resty-core-${lua_resty_core_ver}.tar.gz"
    echo "Download lua-resty-lrucache..."
    src_url="https://github.com/openresty/lua-resty-lrucache/archive/v${lua_resty_lrucache_ver}.tar.gz"
    Download_src "lua-resty-lrucache-${lua_resty_lrucache_ver}.tar.gz"
    echo "Download lua-cjson..."
    src_url="https://github.com/openresty/lua-cjson/archive/refs/tags/${lua_cjson_ver}.tar.gz"
    Download_src "lua-cjson-${lua_cjson_ver}.tar.gz"
  fi

  # ============================================
  # Database downloads
  # ============================================
  if [[ "${db_option}" =~ ^[1-8]$ ]]; then
    if [[ "${db_option}" == 3 ]] && [[ "${dbinstallmethod}" == "2" ]]; then
      # Only MySQL 8.0 source builds need an external boost (1.77.0); MySQL
      # 8.3+ bundles boost in the source and MariaDB's boost is optional, so
      # they download nothing here.
      echo "Download boost..."
      local boost_dl_ver=${boost_ver}
      local boostVersion2_dl=$(echo ${boost_dl_ver} | awk -F. '{print $1"_"$2"_"$3}')
      src_url="https://downloads.sourceforge.net/project/boost/boost/${boost_dl_ver}/boost_${boostVersion2_dl}.tar.gz"
      Download_src "boost_${boostVersion2_dl}.tar.gz"
    fi

    case "${db_option}" in
      1)
        # MySQL 9.7
        if [[ "${dbinstallmethod}" == "1" ]]; then
          echo "Download MySQL 9.7 binary..."
          FILE_NAME=mysql-${mysql97_ver}-linux-glibc2.28-$(uname -m).tar.xz
        else
          echo "Download MySQL 9.7 source..."
          FILE_NAME=mysql-${mysql97_ver}.tar.gz
        fi
        src_url="https://cdn.mysql.com/Downloads/MySQL-9.7/${FILE_NAME}"
        Download_src
        verify_md5_with_retry "$FILE_NAME" "https://cdn.mysql.com/Downloads/MySQL-9.7/${FILE_NAME}.md5" "$src_url" || die_hard "Checksum verification failed for ${FILE_NAME}"
        ;;
      2)
        # MySQL 8.4
        if [[ "${dbinstallmethod}" == "1" ]]; then
          echo "Download MySQL 8.4 binary..."
          FILE_NAME=mysql-${mysql84_ver}-linux-glibc2.28-$(uname -m).tar.xz
        else
          echo "Download MySQL 8.4 source..."
          FILE_NAME=mysql-${mysql84_ver}.tar.gz
        fi
        src_url="https://cdn.mysql.com/Downloads/MySQL-8.4/${FILE_NAME}"
        Download_src
        verify_md5_with_retry "$FILE_NAME" "https://cdn.mysql.com/Downloads/MySQL-8.4/${FILE_NAME}.md5" "$src_url" || die_hard "Checksum verification failed for ${FILE_NAME}"
        ;;
      3)
        # MySQL 8.0
        if [[ "${dbinstallmethod}" == "1" ]]; then
          echo "Download MySQL 8.0 binary..."
          FILE_NAME=mysql-${mysql80_ver}-linux-glibc2.28-$(uname -m).tar.xz
        else
          echo "Download MySQL 8.0 source..."
          FILE_NAME=mysql-${mysql80_ver}.tar.gz
        fi
        src_url="https://cdn.mysql.com/Downloads/MySQL-8.0/${FILE_NAME}"
        Download_src
        verify_md5_with_retry "$FILE_NAME" "https://cdn.mysql.com/Downloads/MySQL-8.0/${FILE_NAME}.md5" "$src_url" || die_hard "Checksum verification failed for ${FILE_NAME}"
        ;;
      [4-7])
        case "${db_option}" in
          4) mariadb_ver=${mariadb123_ver} ;;
          5) mariadb_ver=${mariadb118_ver} ;;
          6) mariadb_ver=${mariadb114_ver} ;;
          7) mariadb_ver=${mariadb1011_ver} ;;
        esac
        if [[ "${dbinstallmethod}" == "1" ]]; then
          FILE_NAME=mariadb-${mariadb_ver}-linux-systemd-$(uname -m).tar.gz
          FILE_TYPE=bintar-linux-systemd-$(uname -m)
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
        verify_md5_with_retry "$FILE_NAME" "https://archive.mariadb.org/mariadb-${mariadb_ver}/${FILE_TYPE}/md5sums.txt" "$src_url" || die_hard "Checksum verification failed for ${FILE_NAME}"
        ;;
      8)
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
  if [[ "${php_option}" =~ ^[1-${PHP_OPTION_MAX}]$ ]] || [[ "${mphp_ver}" =~ ^8[${PHP_MINOR_MIN}-${PHP_MINOR_MAX}]$ ]]; then
    echo "PHP dependencies..."
    # libiconv: no longer downloaded — PHP uses glibc iconv (no GNU libiconv needed)
    # curl (official only)
    src_url="https://curl.se/download/curl-${curl_ver}.tar.gz"
    Download_src
    verify_pgp_signature "curl-${curl_ver}.tar.gz" "https://curl.se/download/curl-${curl_ver}.tar.gz.asc" "Curl" || die_hard "PGP signature verification failed for curl-${curl_ver}.tar.gz"

    # freetype (official only, with GitHub fallback if savannah is down)
    src_url="https://download.savannah.gnu.org/releases/freetype/freetype-${freetype_ver}.tar.gz"
    src_url_fallback="https://github.com/freetype/freetype/archive/refs/tags/VER-${freetype_ver//./-}.tar.gz"
    src_expected_dir="freetype-${freetype_ver}"
    Download_src
    src_url_fallback=""
    src_expected_dir=""

    # freetype 2.14+ builds a 'dlg' git submodule (subprojects/dlg) that plain
    # source tarballs do not embed. Pre-download the pinned dlg archive so the
    # build can populate it, even when offline.
    if [[ "${freetype_ver}" =~ ^2\.(1[4-9]|[2-9][0-9])\. ]]; then
      src_url="https://github.com/nyorain/dlg/archive/${freetype_dlg_sha}.tar.gz"
      Download_src "freetype-dlg-${freetype_dlg_sha}.tar.gz"
    fi

    # argon2 (GitHub) - only needed when can't use OpenSSL built-in Argon2
    # Requires PHP 8.4+ AND OpenSSL 3.2+ to skip.
    # Decided from the concrete version strings (php_ver_to_use / mphp_php_ver,
    # set in install.sh before checkDownload runs) rather than the php_option
    # number, so a future PHP 8.6/8.7 needs no change here.
    local need_argon2=false
    if { [ -n "$php_ver_to_use" ] && ! php_ver_ge_84 "$php_ver_to_use"; } \
       || { [ -n "$mphp_php_ver" ] && ! php_ver_ge_84 "$mphp_php_ver"; }; then
      # PHP < 8.4 always needs the external libargon2
      need_argon2=true
    elif [ -n "$php_ver_to_use" ] || [ -n "$mphp_php_ver" ]; then
      # PHP 8.4+ - still need libargon2 when OpenSSL < 3.2
      if ! openssl_ver_ge_32; then
        need_argon2=true
      fi
    fi
    if [[ "${need_argon2}" == "true" ]]; then
      echo "Download argon2 (OpenSSL < 3.2 or PHP < 8.4)..."
      src_url="https://github.com/P-H-C/phc-winner-argon2/archive/refs/tags/${argon2_ver}.tar.gz"
      Download_src "phc-winner-argon2-${argon2_ver}.tar.gz"
    fi

    # libsodium (official only)
    src_url="https://download.libsodium.org/libsodium/releases/libsodium-${libsodium_ver}.tar.gz"
    Download_src
    verify_pgp_signature "libsodium-${libsodium_ver}.tar.gz" "https://download.libsodium.org/libsodium/releases/libsodium-${libsodium_ver}.tar.gz.sig" "libsodium" || die_hard "PGP signature verification failed for libsodium-${libsodium_ver}.tar.gz"

    # libzip (official only)
    src_url="https://libzip.org/download/libzip-${libzip_ver}.tar.gz"
    Download_src

    # binutils - installed via apt, no longer downloaded
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
    verify_php_sha256 "$file_name" "$php_ver_to_use" || die_hard "Checksum verification failed for ${file_name}"
  fi
  # Multi-PHP: also download the secondary PHP source if requested
  if [ -n "${mphp_php_ver}" ]; then
    echo "Download php-${mphp_php_ver} (multi-PHP)..."
    local file_name="php-${mphp_php_ver}.tar.gz"
    src_url="https://www.php.net/distributions/php-${mphp_php_ver}.tar.gz"
    Download_src
    verify_php_sha256 "$file_name" "${mphp_php_ver}" || die_hard "Checksum verification failed for ${file_name}"
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
    # Use Download_src (not bare wget) so an existing complete file is reused
    # instead of being re-fetched on every run; the GitHub tag archive unpacks
    # to ImageMagick-${ver}, which is exactly the dir the build step expects.
    src_url="https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${imagemagick_ver}.tar.gz"
    Download_src "${imagemagick_filename}"
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
      # Same policy as the PGP checks: "cannot check" (feed unreachable)
      # warns and continues, a real mismatch is fatal.
      wget -q "https://nodejs.org/dist/v${nodejs_ver}/SHASUMS256.txt" -O "SHASUMS256.txt" 2>/dev/null && {
        expected_sha256=$(grep "${file_name}" SHASUMS256.txt | awk '{print $1}')
        actual_sha256=$(sha256sum "$file_name" | awk '{print $1}')
        if [[ "$expected_sha256" == "$actual_sha256" ]]; then
          echo "${CGREEN}Node.js checksum verified${CEND}"
        else
          die_hard "Node.js checksum mismatch for ${file_name} (expected ${expected_sha256:-<none>}, got ${actual_sha256:-<none>})"
        fi
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
    verify_sha256 "$file_name" "https://files.phpmyadmin.net/phpMyAdmin/${phpmyadmin_ver}/${file_name}.sha256" || die_hard "Checksum verification failed for ${file_name}"
  fi

  popd > /dev/null
}
