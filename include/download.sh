#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

# Direct GitHub downloads through an un-poisoned address.
# See include/gh_direct.sh for why this exists and how it is used.
if [ -n "${_GH_DIRECT_SH_LOADED:-}" ]; then
  :
else
  _GH_DIRECT_SH_LOADED=1
  _gh_direct_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  # Written as an if/else rather than a chain of && so that a missing file
  # cannot return non-zero from this line: several callers run with `set -e`,
  # where a non-zero status here would abort the whole install.
  if [ -n "$_gh_direct_dir" ] && [ -f "${_gh_direct_dir}/gh_direct.sh" ]; then
    . "${_gh_direct_dir}/gh_direct.sh"
  fi
fi

# Enhanced download function with retry, mirror failover and timeout
# Usage: Download_src [output_filename]
# Requires: src_url variable must be set before calling
# Optional caller-set variables:
#   src_url_fallback   space-separated alternate URLs (same target filename)
#   src_expected_dir   expected top-level dir of the archive; a fallback-sourced
#                      archive whose top-level dir differs is re-packed to match
#                      (e.g. GitHub auto-tag archives unpack to <repo>-<tag>)
# Probe archive integrity for a downloaded file (gzip -t / xz -t / bzip2 -t).
# A mirror that returns 200 OK with an HTML error page produces a non-empty
# file that still fails the probe, so "downloaded + non-empty" is not enough.
# Returns 0 when the file is a recognised archive type and passes its probe,
# or is not an archive / the probe tool is absent (nothing to check);
# non-zero when the archive is corrupt.
_archive_integrity_ok() {
  local file_name="$1"
  case "${file_name}" in
    *.tar.gz|*.tgz)
      command -v gzip >/dev/null 2>&1 || return 0
      gzip -t "${file_name}" 2>/dev/null
      ;;
    *.tar.xz)
      command -v xz >/dev/null 2>&1 || return 0
      xz -t "${file_name}" 2>/dev/null
      ;;
    *.tar.bz2)
      command -v bzip2 >/dev/null 2>&1 || return 0
      bzip2 -t "${file_name}" 2>/dev/null
      ;;
    *) return 0 ;;
  esac
}

# Align a GitHub-sourced archive's top-level dir with the expected build dir.
# GitHub auto-tag archives unpack to <repo>-<tag>, not the release dir, so a
# fallback-sourced archive must be re-packed before the build step will find it.
align_archive_top_dir() {
  local file_name="$1"
  local expected_dir="${2:-}"

  [ -n "${expected_dir}" ] || return 0
  command -v tar >/dev/null 2>&1 || return 0
  tar -tzf "${file_name}" >/dev/null 2>&1 || return 0

  local probe_dir
  probe_dir=$(tar -tzf "${file_name}" 2>/dev/null | head -1 | cut -d'/' -f1)
  [ -n "${probe_dir}" ] || return 0
  [ "${probe_dir}" = "${expected_dir}" ] && return 0

  local work=".repack_${file_name}_$$"
  rm -rf "${work}"
  mkdir -p "${work}"
  if tar -xzf "${file_name}" -C "${work}" 2>/dev/null \
     && mv "${work}/${probe_dir}" "${work}/${expected_dir}" 2>/dev/null \
     && tar -czf "${work}/${file_name}" -C "${work}" "${expected_dir}" 2>/dev/null; then
    mv -f "${work}/${file_name}" "${file_name}"
    rm -rf "${work}"
    echo "${CMSG}Repacked ${file_name} to expected top-level dir '${expected_dir}'...${CEND}"
    return 0
  fi
  rm -rf "${work}"
  return 1
}

# Probe whether a URL is actually present before a large download.
# Mirrors may lag behind upstream releases (for example a new OpenSSL version
# may not exist yet on a China mirror). wget with -c treats 404 as a resumable
# download failure and would otherwise retry an unavailable file many times.
# Exit code 8 from wget means "server error responses", including HTTP 404.
# Non-zero is not always definitive: callers should treat >=8 as an HTTP error
# and leave smaller wget failures to the normal retry path.
_url_availability_wget() {
  local url="$1"
  wget -q --spider --timeout=15 --tries=1 "$url" 2>/dev/null
  return $?
}

# Build a GitHub accelerator URL. Empty output means this URL has no accelerator.
github_accelerator_url() {
  local url="$1"
  # Returns success, not "no accelerator": the caller captures this in a
  # command substitution, and under "set -e" a non-zero status there would
  # terminate the install for a URL that simply has no accelerator.
  [[ "${url}" == "https://github.com/"* ]] || return 0
  if command -v gh_accelerator_list >/dev/null 2>&1; then
    local first
    first=$(gh_accelerator_list | head -1)
    [ -n "$first" ] && printf '%s\n' "${first}/${url}"
    return 0
  fi
  local accelerator="${GITHUB_ACCELERATOR_URL:-}"
  [ -n "$accelerator" ] && printf '%s\n' "${accelerator%/}/${url}"
  return 0
}

# Probe a URL's transfer speed with a short ranged curl sample.
# Prints bytes/sec on success; non-zero exit if curl is unavailable or the
# probe does not finish in time. Range requests keep the sample bounded even
# when GitHub is slow but reachable.
_url_speed_curl() {
  local url="$1"
  local sample_bytes="${2:-${GITHUB_SPEED_SAMPLE_BYTES:-2097152}}"
  local max_time="${3:-${GITHUB_SPEED_TEST_SECONDS:-10}}"
  local range_end=$((sample_bytes - 1))

  command -v curl >/dev/null 2>&1 || return 1

  local raw
  raw=$(curl --connect-timeout 5 -m "${max_time}" -sS -L -o /dev/null -r "0-${range_end}" -w '%{speed_download}' "${url}" 2>/dev/null || true)
  [ -n "${raw}" ] || return 1

  printf '%d\n' "${raw%.*}"
}

# Resolve the configured GitHub speed threshold in bytes/sec.
github_speed_min_bytes() {
  local min_kbps="${GITHUB_SPEED_MIN_KBPS:-256}"
  printf '%d\n' "$((min_kbps * 1024))"
}

# Append accelerator fallbacks for every GitHub URL in the array named by $1.
github_accelerator_urls() {
  local -n _urls=$1
  local _acc
  local _u
  # Every configured accelerator becomes a fallback source, not just the first
  # one: these services come and go, and one dead accelerator would otherwise
  # take the whole mainland fallback path down with it.
  if command -v gh_accelerator_urls_for >/dev/null 2>&1; then
    for _u in "${_urls[@]}"; do
      for _acc in $(gh_accelerator_urls_for "${_u}"); do
        local _found="no"
        local _x
        for _x in "${_urls[@]}"; do
          [ "$_x" = "${_acc}" ] && _found="yes" && break
        done
        [ "$_found" = "no" ] && _urls+=( "${_acc}" )
      done
    done
    return 0
  fi
  for _acc in $(for _u in "${_urls[@]}"; do github_accelerator_url "${_u}"; done); do
    local _found="no"
    local _u
    for _u in "${_urls[@]}"; do
      [ "${_u}" = "${_acc}" ] && _found="yes" && break
    done
    [ "${_found}" = "no" ] && _urls+=( "${_acc}" )
  done
}

Download_src() {
  # Usage: Download_src [output_filename]
  # If output_filename is provided, download to that name; otherwise use URL basename
  local file_name="${src_url##*/}"
  if [ -n "$1" ]; then
    file_name="$1"
  fi

  # 这个包是从哪儿来的：GitHub 直连还是加速器。
  # 后面校验校验和时要用：包和校验和都来自同一个加速器时，SHA256 就是拿它
  # 自己跟它自己比，被篡改的包一样能过——那种组合必须直接拒绝。
  GH_TARBALL_SOURCE="github"

  # Check if file already exists and has content
  if [ -s "${file_name}" ]; then
    # Integrity probe for cached archives: a truncated file from a previous
    # interrupted download must not be trusted ("non-empty != complete")
    if ! _archive_integrity_ok "${file_name}"; then
      echo "${CWARNING}[${file_name}] is corrupted (truncated?), re-downloading${CEND}"
      rm -f "${file_name}"
      Download_src "$@"
      return $?
    fi
    # Align the cached archive too, not only a fresh download: a cache left
    # un-repacked (by an older build, the pinned-address path, or a
    # hand-placed GitHub auto-tag archive) would otherwise keep failing the
    # build step forever. Idempotent: an already-matching archive only pays
    # for one listing.
    if ! align_archive_top_dir "${file_name}" "${src_expected_dir:-}"; then
      echo "${CWARNING}[${file_name}] could not be aligned to its expected top-level dir; if the build complains about a missing dir, delete it and re-download${CEND}"
    fi
    echo "[${CMSG}${file_name}${CEND}] found"
    return 0
  fi

    # Candidate sources, in order: the primary src_url plus any fallbacks.
  local urls=( "${src_url}" )
  if [ -n "${src_url_fallback:-}" ]; then
    local _fb
    read -ra _fb <<< "${src_url_fallback}"
    urls+=( "${_fb[@]}" )
  fi

  # GitHub Releases/archives are common in this installer. In mainland China
  # the official GitHub URL may be slow or blocked, so add a configurable
  # accelerator as a final fallback instead of burning the install on GitHub.
  github_accelerator_urls urls

  # 首选：固定未被污染的 IP 直连，并行分块下载。
  #
  # 并行的理由：单条 TCP 流到 GitHub 的 CDN 在境内被限速到十几 KB/s，
  # 而这个限制是按流算的，不是按整个传输算的，所以分成几段同时拉会快好几倍。
  local _pinned_done="n"

  # 境外先走普通下载，境内先走固定 IP/加速器（判定见 gh_direct_preferred）。
  #
  # 固定 IP 路径不是境外不能用，而是没必要先绕：直连 GitHub 通常更快，
  # 而且走代理的主机对"绕过 DNS 直连某个 IP"的行为不可预期。境外的
  # 固定 IP 只当救援（普通源全失败后，见本函数末尾）。
  local _prefer_pinned="n"
  if command -v gh_direct_preferred >/dev/null 2>&1 && gh_direct_preferred; then
    _prefer_pinned="y"
  fi

  # 测速固定 IP 路径，再决定要不要用它下这个文件。
  #
  # 境内单流到 GitHub 常常被限到十几 KB/s：能通，但 51MB 要拖四十分钟。
  # 与其先花四十分钟再发现，不如先花十秒测一下，慢就直接交给加速器。
  #
  # 这不改变信任模型：归档的完整性由仓库里钉死的校验和（component_checksums.txt）
  # 保证，加速器只负责搬运字节——它没法让一个错误的文件通过校验。而固定 IP
  # 路径拿到的校验和文件本身也是走 GitHub 的 TLS 证书验证的，来源可分。
  if [ "$_prefer_pinned" = "y" ] \
     && [[ "${urls[0]}" == "https://github.com/"* || "${urls[0]}" == "https://raw.githubusercontent.com/"* ]] \
     && [ -n "${GITHUB_ACCELERATOR_URL:-}" ] \
     && command -v gh_direct_speed_probe >/dev/null 2>&1; then
    local pinned_speed min_speed
    min_speed=$(github_speed_min_bytes)
    pinned_speed=$(gh_direct_speed_probe "${urls[0]}" "${GH_DIRECT_SPEED_SAMPLE_BYTES:-524288}" "${GH_DIRECT_SPEED_TEST_SECONDS:-8}" || true)
    if [ -n "$pinned_speed" ] && [ "$pinned_speed" -lt "${min_speed}" ]; then
      # Every configured accelerator is measured and the fastest one is used.
      # A single dead accelerator would otherwise take the whole fallback
      # path down with it.
      local accel_url=""
      local accel_speed=0
      if command -v gh_fastest_accelerator >/dev/null 2>&1; then
        # The speed comes back with the URL: the caller captures this in a
        # subshell, and a variable set in a subshell does not survive it.
        local info
        info=$(gh_fastest_accelerator "${urls[0]}" "${min_speed}" || true)
        accel_url="${info%% *}"
        accel_speed="${info##* }"
        case "$accel_speed" in
          ''|*[!0-9]*) accel_speed=0 ;;
        esac
      else
        accel_url=$(github_accelerator_url "${urls[0]}")
      fi
      # Only switch when the accelerator is actually faster. Switching to a
      # slower one would make the download worse, not better.
      if [ -n "$accel_url" ] && [ "$accel_speed" -ge "$pinned_speed" ]; then
        echo "${CMSG}Pinned path looks slow (${pinned_speed} B/s < ${min_speed} B/s); switching to the accelerator (${accel_speed} B/s)${CEND}"
        local reordered=() _u
        reordered+=( "${accel_url}" )
        for _u in "${urls[@]}"; do
          [ "$_u" = "${accel_url}" ] && continue
          reordered+=( "${_u}" )
        done
        urls=( "${reordered[@]}" )
        GH_TARBALL_SOURCE="accelerator"
      fi
    fi
  fi

  # 首选：固定未被污染的 IP 直连，并行分块下载。
  #
  # 这一步必须在测速之后。测速在前会把 urls[0] 换成加速器地址，下面这段
  # 就因为不再是 github.com 而整段跳过——境内实测就是这样：日志里
  # 只有 wget 的输出，固定 IP 路径根本没被尝试过。
  #
  # 并行的理由：单条 TCP 流到 GitHub 的 CDN 在境内被限速到十几 KB/s，
  # 而这个限制是按流算的，不是按整个传输算的，所以分成几段同时拉会快好几倍。
  if [ "$_prefer_pinned" = "y" ] \
     && [[ "${urls[0]}" == "https://github.com/"* || "${urls[0]}" == "https://raw.githubusercontent.com/"* ]]; then
    if gh_direct_download "${urls[0]}" "${file_name}"; then
      echo "${CMSG}Fetched through a pinned address (no poisoned DNS involved)${CEND}"
      _pinned_done="y"
    else
      rm -f "${file_name}"
    fi
  fi

  # GitHub URLs can be reachable but painfully slow. If so, do a quick sample
  # and prefer the accelerator instead of waiting on the full download.
  if [ "$_prefer_pinned" = "y" ] && [ "$_pinned_done" != "y" ] && [[ "${urls[0]}" == "https://github.com/"* ]] && [ -n "${GITHUB_ACCELERATOR_URL:-}" ] && command -v curl >/dev/null 2>&1; then
    local primary_speed accel_url min_speed
    min_speed=$(github_speed_min_bytes)
    accel_url=$(github_accelerator_url "${urls[0]}")
    if [ -n "${accel_url}" ]; then
      primary_speed=$(_url_speed_curl "${urls[0]}" "${GITHUB_SPEED_SAMPLE_BYTES:-2097152}" "${GITHUB_SPEED_TEST_SECONDS:-10}" || true)
      if [ -n "${primary_speed}" ] && [ "${primary_speed}" -lt "${min_speed}" ]; then
        echo "${CMSG}GitHub primary looks slow (${primary_speed} B/s < ${min_speed} B/s); preferring accelerator${CEND}"
        local reordered=()
        reordered+=( "${accel_url}" )
        local _u
        for _u in "${urls[@]}"; do
          [ "${_u}" = "${accel_url}" ] && continue
          reordered+=( "${_u}" )
        done
        urls=( "${reordered[@]}" )
      fi
    fi
  fi

  # 固定 IP 直连已经拿到文件：不再走下面的重试循环（那会把同样的内容再下一遍）。
  # 拿到的是裸字节，和 wget 路径一样先做完整性探测、对齐顶层目录，通过才算成功。
  # GitHub 自动 tag 包解出来是 <repo>-<tag> 目录：不对齐就会原样进构建步骤，
  # 报 "extraction did not produce ..."（境内固定 IP 路径正是这种包的常见入口）。
  if [ "$_pinned_done" = "y" ]; then
    if [ -s "${file_name}" ]; then
      if _archive_integrity_ok "${file_name}" \
         && align_archive_top_dir "${file_name}" "${src_expected_dir:-}"; then
        echo "[${CMSG}${file_name}${CEND}] fetched via a pinned address"
        return 0
      fi
      echo "${CWARNING}Pinned fetch of ${file_name} failed verification, falling back to the source list${CEND}"
      rm -f "${file_name}"
    else
      rm -f "${file_name}"
    fi
  fi

  # Multiple sources: fewer retries each so we fail over quickly. A single
  # source keeps the original generous budget.
  local max_retries=10
  if [ "${#urls[@]}" -gt 1 ]; then
    max_retries=3
  fi
  local retry_delay=10

  local last_url=""
  local i
  for i in "${!urls[@]}"; do
    local url="${urls[i]}"
    local unavailable_exit=""
    last_url="${url}"

    # 记下这个包是从加速器来的（如果是从加速器来的话）。
    if command -v gh_is_accelerator_url >/dev/null 2>&1; then
      gh_is_accelerator_url "$url" && GH_TARBALL_SOURCE="accelerator"
    else
      case "$url" in
        "${GITHUB_ACCELERATOR_URL%/}/"*) GH_TARBALL_SOURCE="accelerator" ;;
      esac
    fi

    if [ "${i}" -eq 0 ]; then
      echo "${CMSG}Downloading ${file_name}...${CEND}"
    else
      echo "${CMSG}Primary source unavailable - trying fallback: ${url}${CEND}"
    fi

    # Fail over immediately for missing resources. Probe with HEAD-like wget
    # spider; on failure, preserve wget's exit code so unavailable/404 sources
    # do not burn the normal retry budget.
    if command -v wget >/dev/null 2>&1; then
      _url_availability_wget "${url}"
      unavailable_exit=$?
    fi

    if [ -n "${unavailable_exit}" ] && [ "${unavailable_exit}" -ge 8 ]; then
      # HTTP error responses such as 404 mean retrying the same URL is useless;
      # fall over immediately. Keep transient network/DNS/TLS probe failures on
      # the normal wget retry path below.
      echo "${CWARNING}Download source unavailable (wget exit ${unavailable_exit}): ${url}${CEND}"
      rm -f "${file_name}"
      continue
    fi

    local attempt=1
    while [ $attempt -le $max_retries ]; do
      echo "Attempt $attempt of $max_retries..."

      # Use wget with enhanced settings (check wget exit code, not tee's via PIPESTATUS)
      wget \
        --timeout=60 \
        --tries=3 \
        --waitretry=${retry_delay} \
        --progress=bar:force \
        -c \
        -O "${file_name}" \
        "${url}" 2>&1 | tee -a "${current_dir}/download.log"
      local wget_exit_code=${PIPESTATUS[0]}
      if [ ${wget_exit_code} -eq 8 ]; then
        echo "${CWARNING}Download source returned HTTP error (wget exit 8), skipping retries: ${url}${CEND}"
        if [ -f "${file_name}" ] && [ ! -s "${file_name}" ]; then
          rm -f "${file_name}"
        fi
        break
      fi
      if [ ${wget_exit_code} -eq 0 ] && [ -f "${file_name}" ] && [ -s "${file_name}" ]; then
        # A mirror returning 200 OK + an HTML error page yields a non-empty
        # file that is not a valid archive; probe it before trusting the size.
        if ! _archive_integrity_ok "${file_name}"; then
          echo "${CWARNING}Downloaded ${file_name} failed integrity probe (mirror returned HTML?), discarding...${CEND}"
          rm -f "${file_name}"
        elif ! align_archive_top_dir "${file_name}" "${src_expected_dir:-}"; then
          # A failed alignment must not be trusted as a download: the build
          # step would fail with "did not produce ...", so discard and retry.
          echo "${CWARNING}Downloaded ${file_name} failed top-level dir alignment, discarding...${CEND}"
          rm -f "${file_name}"
        else
          echo "${CSUCCESS}Successfully downloaded ${file_name} (source: ${url})${CEND}"
          return 0
        fi
      fi

      echo "${CWARNING}Download attempt $attempt from ${url} failed${CEND}"

      # Progressive delay
      if [ $attempt -lt $max_retries ]; then
        local delay=$((retry_delay * attempt))
        echo "Waiting ${delay} seconds before retry..."
        sleep $delay
      fi

      attempt=$((attempt + 1))
    done

    # This source exhausted its retries; drop the partial file and try next.
    if [ "${i}" -lt $(( ${#urls[@]} - 1 )) ]; then
      echo "${CWARNING}Source ${url} exhausted after ${max_retries} attempts; trying next source...${CEND}"
      rm -f "${file_name}"
    fi
  done

  # 境外救援：普通源全部失败时，再试一次固定 IP。
  #
  # 境外默认不先走固定 IP（见 gh_direct_preferred），但 DNS 被污染、代理
  # 配置异常时，它仍可能是唯一能出去的路。境内不会走到这里——那边固定 IP
  # 一开始就试过了。
  if [ "$_prefer_pinned" != "y" ] \
     && [[ "${urls[0]}" == "https://github.com/"* || "${urls[0]}" == "https://raw.githubusercontent.com/"* ]] \
     && command -v gh_direct_download >/dev/null 2>&1; then
    echo "${CMSG}Direct sources failed; retrying through a pinned address...${CEND}"
    rm -f "${file_name}"
    if gh_direct_download "${urls[0]}" "${file_name}" \
       && _archive_integrity_ok "${file_name}" \
       && align_archive_top_dir "${file_name}" "${src_expected_dir:-}"; then
      echo "[${CMSG}${file_name}${CEND}] fetched via a pinned address"
      return 0
    fi
    rm -f "${file_name}"
  fi

  # All sources failed
  echo ""
  echo "${CFAILURE}========================================${CEND}"
  echo "${CFAILURE}Download failed from all ${#urls[@]} source(s); last: ${last_url}${CEND}"
  echo "${CFAILURE}========================================${CEND}"
  echo "URL (primary): ${src_url}"
  [ -n "${src_url_fallback:-}" ] && echo "URLs (fallback): ${src_url_fallback}"
  echo "File: ${file_name}"
  echo ""
  echo "Possible solutions:"
  echo "1. Check your network connection"
  echo "2. Try manual download: wget ${src_url}"
  echo "3. Use pre-download: ./download_sources.sh --common"
  echo "4. Check download log: ${current_dir}/download.log"
  echo ""

  die_hard "Auto download failed! Please manually download ${src_url} into the src/ directory."
}
