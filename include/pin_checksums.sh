#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
# Look up an expected checksum in the repository's pinned list.
#
# WHY A LOCAL PIN
# --------------
# The checksum file for a component is published next to the component, on
# GitHub. That means the thing being verified and the thing verifying it can
# come from the same place — and when a third-party accelerator is in the
# path, they can come from the same third party, at which point the SHA256
# check is the accelerator comparing itself with itself and proves nothing.
#
# A checksum pinned in the repository breaks that circle: the expected value
# is part of the source tree, reviewed and version-controlled, and the network
# is only used to fetch the bytes. The trade is that a pin has to be updated
# when a version moves, which is what update_checksums.sh is for; the loader
# treats a stale pin as a mismatch to be reported, not silently ignored.
#
# Format: "<sha256>  <filename>", the same shape sha256sum produces, so the
# file can be checked with `sha256sum -c` and edited by hand.

# Where the pinned list lives.
#
# Resolved once, at source time, and kept in a variable.
#
# Resolving it at use time looks harmless and is not: BASH_SOURCE[0] is the
# path this file was sourced with, and when that path is relative ("include/
# pin_checksums.sh") the lookup resolves against whatever directory the caller
# happens to be in at that moment. A caller that changes directory then finds
# no pins at all — and that failure is silent: the trust anchor quietly
# degrades from "the value in the repository" to "whatever the network
# serves", which is exactly the circularity this file exists to prevent.
_GH_PIN_CHECKSUMS_FILE=""
_gpcd_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[ -n "$_gpcd_dir" ] && _GH_PIN_CHECKSUMS_FILE="${_gpcd_dir}/component_checksums.txt"
unset _gpcd_dir

_gh_pin_checksums_file() {
  printf '%s\n' "${_GH_PIN_CHECKSUMS_FILE}"
}

# Read the pinned checksum for a file.
# Prints the checksum, or nothing when the file is not pinned.
gh_pinned_checksum() {
  local filename="$1"
  local list
  list="$(_gh_pin_checksums_file)"
  [ -n "$list" ] && [ -f "$list" ] || return 1
  # Match the filename exactly at the end of the line, accepting both the GNU
  # two-space form and the binary-star form.
  local sum
  sum=$(grep -E "  ${filename//./\\.}$|\*${filename//./\\.}$" "$list" 2>/dev/null | awk '{print $1}' | head -1)
  [ -n "$sum" ] || return 1
  printf '%s\n' "$sum"
}

# Is this file pinned in the repository?
gh_is_pinned() {
  gh_pinned_checksum "$1" >/dev/null 2>&1
}
