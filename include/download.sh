#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

# Enhanced download function with retry and timeout
# Usage: Download_src
# Requires: src_url variable must be set before calling
Download_src() {
  local file_name="${src_url##*/}"
  
  # Check if file already exists and has content
  if [ -s "${file_name}" ]; then
    echo "[${CMSG}${file_name}${CEND}] found"
    return 0
  fi
  
  echo "${CMSG}Downloading ${file_name}...${CEND}"
  
  # Enhanced retry mechanism
  local max_retries=10
  local retry_delay=10
  local timeout=300
  local attempt=1
  
  while [ $attempt -le $max_retries ]; do
    echo "Attempt $attempt of $max_retries..."
    
    # Use wget with enhanced settings
    if wget \
      --timeout=60 \
      --tries=3 \
      --waitretry=${retry_delay} \
      --limit-rate=100M \
      --progress=bar:force \
      -c \
      ${src_url} 2>&1 | tee -a ${current_dir}/download.log; then
      
      # Verify download success
      if [ -f "${file_name}" ] && [ -s "${file_name}" ]; then
        echo "${CSUCCESS}Successfully downloaded ${file_name}${CEND}"
        return 0
      fi
    fi
    
    echo "${CWARNING}Download attempt $attempt failed${CEND}"
    
    # Progressive delay
    if [ $attempt -lt $max_retries ]; then
      local delay=$((retry_delay * attempt))
      echo "Waiting ${delay} seconds before retry..."
      sleep $delay
    fi
    
    attempt=$((attempt + 1))
  done
  
  # All retries failed
  echo ""
  echo "${CFAILURE}========================================${CEND}"
  echo "${CFAILURE}Download failed after $max_retries attempts${CEND}"
  echo "${CFAILURE}========================================${CEND}"
  echo "URL: ${src_url}"
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
