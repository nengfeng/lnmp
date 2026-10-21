#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
# Regression tests for the GitHub download helpers.
#
# WHY THIS FILE EXISTS
# --------------------
# The download helpers are used from scripts that run under "set -e", and
# several bugs lived exactly in that gap:
#
#   * A cache lookup that returned non-zero on a miss was called in a command
#     substitution. Under "set -e" the assignment terminated the calling
#     subshell, so the candidate list came back empty and the pinned path
#     reported "no reachable address" — while the same code worked fine when
#     it was tested without "set -e".
#   * The pinned checksum list was resolved relative to the current directory
#     at use time, so a caller that changed directory found no pins at all.
#     That failure is silent: the trust anchor quietly degrades from "the
#     value in the repository" to "whatever the network serves".
#
# So this test runs under "set -e" on purpose, and it changes directory
# before the checksum lookup on purpose. Both are the conditions that broke.

set -e
set -u

current_dir="$(dirname "$(readlink -f "$0")")"

# Sourced with a relative path on purpose: the helpers must not depend on the
# directory the caller happens to be in.
cd "${current_dir}"
. ./include/gh_direct.sh
. ./include/pin_checksums.sh
. ./include/download.sh

fail=0
pass=0

ok() {
  pass=$((pass + 1))
  echo "  ok    $1"
}

no() {
  fail=$((fail + 1))
  echo "  FAIL  $1"
}

check() {
  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    no "$1 (expected '$2', got '$3')"
  fi
}

echo "Testing the GitHub download helpers"
echo "====================================="

# --------------------------------------------------------------------------
# The cache lookup must succeed even when there is nothing cached.
#
# This is the bug that made the pinned path report "no reachable address" on
# every mainland run: under "set -e" the assignment of a failing command
# substitution kills the subshell it runs in, and the candidate list was
# built inside such a subshell.
# --------------------------------------------------------------------------
echo
echo "Cache lookup on a miss:"
_gh_cache_init
out=$(_gh_cache_get "definitely-not-cached")
check "an empty cache lookup returns success" "0" "$?"
check "an empty cache lookup prints nothing" "" "${out}"

# --------------------------------------------------------------------------
# Address filtering: only the addresses that cannot be right are rejected.
# The Asia anycast range has to be accepted — it is the one a mainland
# network can reach, and rejecting it was the original mistake.
# --------------------------------------------------------------------------
echo
echo "Address filtering:"
for ip in 20.205.243.166 20.27.177.113 140.82.114.3 185.199.108.133; do
  if _gh_addr_usable "$ip"; then ok "$ip is usable"; else no "$ip is usable"; fi
done
for ip in 127.0.0.1 0.0.0.0 10.1.1.1 192.168.1.1 172.16.0.1 169.254.1.1; do
  if _gh_addr_usable "$ip"; then no "$ip is rejected"; else ok "$ip is rejected"; fi
done

# --------------------------------------------------------------------------
# The known address list must hold full addresses.
#
# An earlier version stored prefixes and appended the last octet, which
# probed addresses that do not exist (20.205.243.1 instead of
# 20.205.243.166) and silently disabled the fallback.
# --------------------------------------------------------------------------
echo
echo "Known address list:"
bad=0
for ip in "${GH_KNOWN_ADDRS[@]}"; do
  case "$ip" in
    *.*.*.*) ;;
    *) bad=1; no "'${ip}' is not an address" ;;
  esac
done
[ "$bad" -eq 0 ] && ok "every known address is a complete address"

# --------------------------------------------------------------------------
# URL helpers.
# --------------------------------------------------------------------------
echo
echo "URL helpers:"
check "host of a github URL" "github.com" "$(_gh_url_host 'https://github.com/a/b')"
check "host of a URL with a query" "github.com" "$(_gh_url_host 'https://github.com/a?b=c')"

# --------------------------------------------------------------------------
# The accelerator helper must succeed when there is no accelerator.
#
# The caller captures it in a command substitution; under "set -e" a
# non-zero status there would terminate the install for a URL that simply
# has no accelerator.
# --------------------------------------------------------------------------
echo
echo "Accelerator helper:"
unset GITHUB_ACCELERATOR_URL
out=$(github_accelerator_url "https://github.com/a/b")
check "no accelerator configured returns success" "0" "$?"
check "no accelerator configured prints nothing" "" "${out}"

# --------------------------------------------------------------------------
# The accelerator list.
#
# A single accelerator is a single point of failure for the mainland
# fallback path, and these services do go away. The primary value stays a
# single URL because many places build "${GITHUB_ACCELERATOR_URL%/}/${url}";
# the extra ones live in their own variable.
# --------------------------------------------------------------------------
echo
echo "Accelerator list:"
GITHUB_ACCELERATOR_URL="https://a.example"
GITHUB_ACCELERATOR_FALLBACKS="https://b.example https://c.example"
list=$(gh_accelerator_list)
check "three accelerators are configured" "3" "$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
check "the primary accelerator comes first" "https://a.example" "$(printf '%s\n' "$list" | head -1)"

GITHUB_ACCELERATOR_FALLBACKS="https://b.example,https://a.example"
list=$(gh_accelerator_list)
check "a duplicate is dropped" "2" "$(printf '%s\n' "$list" | wc -l | tr -d ' ')"

GITHUB_ACCELERATOR_FALLBACKS=""
check "the accelerator URL is built correctly" \
  "https://a.example/https://github.com/x/y" \
  "$(github_accelerator_url 'https://github.com/x/y')"

# --------------------------------------------------------------------------
# The pinned checksum must be found regardless of the current directory.
# --------------------------------------------------------------------------
echo
echo "Pinned checksum lookup:"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
cp "${current_dir}/component_checksums.txt" "${tmp}/"
(
  cd "${tmp}"
  # Deliberately sourced from a relative path in a different directory.
  . "${current_dir}/include/pin_checksums.sh"
  sum=$(gh_pinned_checksum "openssl-3.5.9.tar.gz" || true)
  if [ -n "$sum" ]; then
    echo "  ok    the pinned checksum is found from another directory"
  else
    echo "  FAIL  the pinned checksum is NOT found from another directory"
    exit 1
  fi
)

echo
echo "====================================="
echo "Passed: ${pass}, Failed: ${fail}"
[ "$fail" -eq 0 ] || exit 1
echo "All tests passed."
