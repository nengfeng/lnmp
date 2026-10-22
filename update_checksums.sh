#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
# Refresh the repository's pinned component checksums.
#
# WHY
# ---
# The expected checksum of every component is published next to the component,
# on GitHub. That is fine for detecting a corrupted download, but it is not
# tamper evidence: when a third-party accelerator is in the path, the same
# accelerator can serve the tarball AND the checksum file, and the SHA256
# comparison then verifies the accelerator against itself. A mirror that
# substitutes both files passes the check.
#
# Pinning the expected values in the repository breaks that circle. The pin is
# part of the source tree — reviewed, version-controlled, and changeable only
# by someone with the repository — and the network is then only responsible
# for delivering bytes that must match it.
#
# The cost is that a pin has to be refreshed when a version moves. That is
# what this script is for: it reads the published checksum files and rewrites
# the pin. Run it after update_versions.sh has moved a version.
#
# Usage:
#   ./update_checksums.sh            # refresh the pin
#   ./update_checksums.sh --check    # report drift, write nothing
#
# The pin file is component_checksums.txt, in the same "sha256  filename"
# shape sha256sum produces, so it can be checked with `sha256sum -c` and
# edited by hand.

set -u

current_dir=$(dirname "$(readlink -f "$0")")
cd "${current_dir}"

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

. ./include/color.sh 2>/dev/null || true
. ./include/gh_direct.sh 2>/dev/null || true

PIN_FILE="./component_checksums.txt"
CHECK_ONLY="n"
[[ "${1:-}" == "--check" ]] && CHECK_ONLY="y"

# The components whose checksums are published as a release file. The URL is
# the release's checksum file; the entry we keep is the tarball inside it.
#
# format: <url of the checksum file>|<name of the tarball inside it>
COMPONENTS=(
  "https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz.sha256|openssl-3.5.9.tar.gz"
  "https://github.com/openresty/luajit2/archive/refs/tags/v2.1-20261021.tar.gz|luajit2-2.1-20261021.tar.gz"
  "https://github.com/openresty/lua-nginx-module/archive/refs/tags/v0.10.32rc6.tar.gz|lua-nginx-module-0.10.32rc6.tar.gz"
  "https://github.com/openresty/nginx/archive/refs/tags/release-1.30.6.tar.gz|nginx-release-1.30.6.tar.gz"
)

# Fetch a file through a pinned address when possible.
fetch() {
  local url="$1" out="$2"
  if gh_direct_download "$url" "$out" 2>/dev/null && [ -s "$out" ]; then
    return 0
  fi
  curl -sL --connect-timeout 10 -m 120 -o "$out" "$url" 2>/dev/null && [ -s "$out" ]
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

new_pin="$work/pin.txt"
: > "$new_pin"

for entry in "${COMPONENTS[@]}"; do
  url="${entry%%|*}"
  name="${entry##*|}"

  # A release checksum file (.sha256 / SHASUMS256) usually names the tarball
  # itself; an archive URL has no checksum file, so the tarball is fetched and
  # hashed directly.
  sum=""
  if [[ "$url" == *".sha256" || "$url" == *"SHASUMS256" ]]; then
    if fetch "$url" "$work/sums.txt"; then
      sum=$(grep -iE "  ${name//./\\.}$|\*${name//./\\.}$" "$work/sums.txt" | awk '{print $1}' | head -1)
    fi
  fi

  if [ -z "$sum" ]; then
    # No published checksum for this one: fetch the file and hash it. The
    # result is only as trustworthy as the download, which is why this is the
    # fallback and not the primary path.
    if fetch "$url" "$work/$name"; then
      sum=$(sha256sum "$work/$name" | awk '{print $1}')
      echo "  (no published checksum for ${name}; hashed the download)"
    fi
  fi

  if [ -n "$sum" ]; then
    printf '%s  %s\n' "$sum" "$name" >> "$new_pin"
    echo "  ${name}  ${sum}"
  else
    echo "  ${name}  (could not obtain a checksum)"
  fi
done

if [ "$CHECK_ONLY" = "y" ]; then
  echo
  echo "--- 与现有 pin 的差异 ---"
  if [ -f "$PIN_FILE" ]; then
    diff <(sort "$PIN_FILE") <(sort "$new_pin") || true
  else
    echo "  (还没有 pin 文件)"
  fi
  exit 0
fi

cp "$new_pin" "$PIN_FILE"
echo
echo "已更新 ${PIN_FILE}"
exit 0
