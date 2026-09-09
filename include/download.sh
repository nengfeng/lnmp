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
    case "${file_name}" in
      *.tar.gz|*.tgz)
        if command -v gzip >/dev/null 2>&1 && ! gzip -t "${file_name}" 2>/dev/null; then
          echo "${CWARNING}[${file_name}] is corrupted (truncated?), re-downloading${CEND}"
          rm -f "${file_name}"
          Download_src "$@"
          return $?
        fi ;;
      *.tar.xz)
        if command -v xz >/dev/null 2>&1 && ! xz -t "${file_name}" 2>/dev/null; then
          echo "${CWARNING}[${file_name}] is corrupted (truncated?), re-downloading${CEND}"
          rm -f "${file_name}"
          Download_src "$@"
          return $?
        fi ;;
      *.tar.bz2)
        if command -v bzip2 >/dev/null 2>&1 && ! bzip2 -t "${file_name}" 2>/dev/null; then
          echo "${CWARNING}[${file_name}] is corrupted (truncated?), re-downloading${CEND}"
          rm -f "${file_name}"
          Download_src "$@"
          return $?
        fi ;;
    esac
    echo "[${CMSG}${file_name}${CEND}] found"
    return 0
  fi

  # Candidate sources, in order: the primary src_url plus any fallbacks.
  local urls=( "${src_url}" )
  if [ -n "${src_url_fallback:-}" ]; then
    local _fb=()
    read -ra _fb <<< "${src_url_fallback}"
    urls+=( "${_fb[@]}" )
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
    last_url="${url}"
    if [ "${i}" -eq 0 ]; then
      echo "${CMSG}Downloading ${file_name}...${CEND}"
    else
      echo "${CMSG}Primary source unavailable - trying fallback: ${url}${CEND}"
    fi

    local attempt=1
    while [ $attempt -le $max_retries ]; do
      echo "Attempt $attempt of $max_retries..."

      # Use wget with enhanced settings (check wget exit code, not tee's via PIPESTATUS)
      wget \
        --timeout=60 \
        --tries=3 \
        --waitretry=${retry_delay} \
        --limit-rate=100M \
        --progress=bar:force \
        -c \
        -O "${file_name}" \
        "${url}" 2>&1 | tee -a "${current_dir}/download.log"
      local wget_exit_code=${PIPESTATUS[0]}
      if [ ${wget_exit_code} -eq 0 ] && [ -f "${file_name}" ] && [ -s "${file_name}" ]; then
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
