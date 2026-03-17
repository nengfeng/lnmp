#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Download_src() {
  [ -s "${src_url##*/}" ] && echo "[${CMSG}${src_url##*/}${CEND}] found" || { 
    # Security: Use HTTPS with certificate verification
    # Removed --no-check-certificate to prevent MITM attacks
    # If certificate issues occur, ensure system CA certificates are up to date
    wget --limit-rate=100M --tries=6 -c ${src_url}
    sleep 1
  }
  if [ ! -e "${src_url##*/}" ]; then
    die_hard "Auto download failed! You can manually download ${src_url} into the src/ directory."
  fi
}
