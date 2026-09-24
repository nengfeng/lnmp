#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

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
  local accelerator="${GITHUB_ACCELERATOR_URL:-}"
  if [ -z "${accelerator}" ] || [[ "${url}" != "https://github.com/"* ]]; then
    return
  fi
  printf '%s\n' "${accelerator%/}/${url}"
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
  raw=$(curl --connect-timeout 5 -m "${max_time}" -sS -L -o /dev/null -r "0-${range_end}" -w '%{speed_download}' "${url}" 2>/dev/null)
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

  # GitHub URLs can be reachable but painfully slow. If so, do a quick sample
  # and prefer the accelerator instead of waiting on the full download.
  if [[ "${urls[0]}" == "https://github.com/"* ]] && [ -n "${GITHUB_ACCELERATOR_URL:-}" ] && command -v curl >/dev/null 2>&1; then
    local primary_speed accel_url min_speed
    min_speed=$(github_speed_min_bytes)
    accel_url=$(github_accelerator_url "${urls[0]}")
    if [ -n "${accel_url}" ]; then
      primary_speed=$(_url_speed_curl "${urls[0]}" "${GITHUB_SPEED_SAMPLE_BYTES:-2097152}" "${GITHUB_SPEED_TEST_SECONDS:-10}")
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
        else
          # Align the archive's top-level dir with what the build step expects.
          # GitHub auto-tag archives unpack to <repo>-<tag> (e.g.
          # freetype-VER-2-14-3), not the release dir (freetype-2.14.3), so a
          # fallback-sourced archive must be re-packed before it will build.
          if [ -n "${src_expected_dir:-}" ] && tar -tzf "${file_name}" >/dev/null 2>&1; then
            local probe_dir
            probe_dir=$(tar -tzf "${file_name}" 2>/dev/null | head -1 | cut -d'/' -f1)
            if [ -n "${probe_dir}" ] && [ "${probe_dir}" != "${src_expected_dir}" ]; then
              echo "${CMSG}Repacking ${file_name} to expected top-level dir '${src_expected_dir}'...${CEND}"
              local work=".repack_${file_name}_$$"
              rm -rf "${work}"
              mkdir -p "${work}"
              if tar -xzf "${file_name}" -C "${work}" 2>/dev/null \
                 && mv "${work}/${probe_dir}" "${work}/${src_expected_dir}" 2>/dev/null \
                 && tar -czf "${work}/${file_name}" -C "${work}" "${src_expected_dir}" 2>/dev/null; then
                mv -f "${work}/${file_name}" "${file_name}"
              fi
              rm -rf "${work}"
            fi
          fi
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
