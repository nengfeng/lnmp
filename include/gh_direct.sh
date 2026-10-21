#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
# Direct GitHub downloads through a clean IP.
#
# WHY
# ---
# In mainland China the github.com hostname is often answered with a poisoned
# address, so a direct download either hangs or crawls. The usual workaround is
# a third-party accelerator, but that trades the problem for a worse one: the
# accelerator serves the tarball AND the checksum file, so the SHA256 check
# verifies the accelerator against itself and proves nothing.
#
# The addresses GitHub actually uses are reachable; only the DNS answer is
# wrong. So: ask a resolver that is not poisoned (DoH), pin the answer, and
# download straight from GitHub. The trust anchor stays where it belongs —
# GitHub's TLS certificate — and nothing has to be trusted but the CA bundle.
#
# curl can pin an address (--resolve); wget cannot. The pinned path therefore
# uses curl, and wget stays as the fallback for hosts that are not pinned.
#
# Everything here is best-effort: a failure returns non-zero and the caller
# falls back to the ordinary path. Nothing in this file is allowed to abort an
# install.

# Resolvers used to obtain an un-poisoned answer. The first two are operated
# in China and answer over HTTPS, so their answers are not subject to the
# local resolver's poisoning.
GH_DOH_ENDPOINTS=(
  "https://223.5.5.5/resolve"      # AliDNS
  "https://doh.pub/dns-query"        # DNSPod
  "https://1.1.1.1/dns-query"        # Cloudflare
)

# Hostnames that have to be pinned together. A github.com release URL answers
# with a 302 to a different host that carries the real bytes, so pinning only
# github.com leaves the transfer to resolve the poisoned name again.
GH_PIN_HOSTS=(
  "github.com"
  "release-assets.githubusercontent.com"
  "objects.githubusercontent.com"
  "raw.githubusercontent.com"
  "codeload.github.com"
)

# Address blocks GitHub is known to use, tried when no resolver answers. Only
# the first address of each block is tried: they are all anycast, so one
# reachable address is enough.
GH_KNOWN_PREFIXES=(
  "140.82.112." "140.82.113." "140.82.114." "140.82.121."
  "185.199.108." "185.199.109." "185.199.110." "185.199.111."
)

# Cache of resolved addresses, so one download does not re-resolve every host.
declare -A _GH_RESOLVED=()

# Resolve a hostname through DoH.
# Prints the address, or nothing when no resolver answered.
_gh_doh_resolve() {
  local host="$1"
  local endpoint ip
  command -v curl >/dev/null 2>&1 || return 1
  for endpoint in "${GH_DOH_ENDPOINTS[@]}"; do
    ip=$(curl --connect-timeout 5 -m 10 -sk \
           -H 'accept: application/dns-json' \
           "${endpoint}?name=${host}&type=A" 2>/dev/null \
         | tr ',' '\n' | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
         | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    if [ -n "$ip" ]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

# Is this address one of GitHub's?
# A poisoned answer usually points at a loopback or a blackhole, so the
# resolver's answer is only accepted when it looks like a routable address in
# GitHub's space. This also stops a hijacked DoH response from redirecting the
# download somewhere else: the certificate check would fail anyway, but
# failing here is clearer and avoids sending the request at all.
_gh_addr_looks_sane() {
  local ip="$1"
  case "$ip" in
    140.82.*|185.199.*|192.30.*) return 0 ;;
    127.*|0.*|10.*|192.168.*|172.1[6-9].*|172.2*|172.3[01].*) return 1 ;;
    *) return 1 ;;
  esac
}

# Resolve a GitHub hostname to an address that is not poisoned.
# On success the address is left in _GH_RESOLVED_IP and 0 is returned.
#
# The result is deliberately NOT printed: a caller that captures it with $( )
# runs this in a subshell, and the cache below would be written there and lost
# with it — so every call would re-resolve, and because the resolvers answer
# with different anycast addresses each time, the same host would be pinned to
# a different address on every call.
gh_resolve_clean() {
  local host="$1"
  local ip

  _GH_RESOLVED_IP=""
  if [ -n "${_GH_RESOLVED[$host]:-}" ]; then
    _GH_RESOLVED_IP="${_GH_RESOLVED[$host]}"
    return 0
  fi

  ip=$(_gh_doh_resolve "$host") || ip=""
  if [ -z "$ip" ] || ! _gh_addr_looks_sane "$ip"; then
    ip=""
  fi

  # No resolver answered, or the answer was not one of GitHub's. Try the
  # known prefixes and keep the first that completes a TLS handshake.
  if [ -z "$ip" ]; then
    local prefix candidate
    for prefix in "${GH_KNOWN_PREFIXES[@]}"; do
      for candidate in $(seq 1 254); do
        candidate="${prefix}${candidate}"
        if command -v curl >/dev/null 2>&1 \
           && curl --connect-timeout 3 -m 6 -sk -o /dev/null \
                --resolve "${host}:443:${candidate}" "https://${host}/" 2>/dev/null; then
          ip="$candidate"
          break 2
        fi
      done
    done
  fi

  [ -z "$ip" ] && return 1
  _GH_RESOLVED[$host]="$ip"
  _GH_RESOLVED_IP="$ip"
  return 0
}

# Build the curl --resolve arguments for the hosts involved in a GitHub
# download. Prints one argument per line; empty when nothing could be pinned.
gh_resolve_args() {
  local host ip
  for host in "${GH_PIN_HOSTS[@]}"; do
    gh_resolve_clean "$host" || continue
    ip="$_GH_RESOLVED_IP"
    printf -- '--resolve\n%s:443:%s\n' "$host" "$ip"
  done
}

# Can this URL be fetched through a pinned address?
# Probes with a small range request so the check is cheap.
gh_direct_probe() {
  local url="$1"
  command -v curl >/dev/null 2>&1 || return 1
  # Enabled by default; set GH_DIRECT_ENABLED=n to turn it off. The default
  # has to be a substitution: a caller running under `set -u` would abort on
  # an unset variable instead of taking the normal path.
  case "${GH_DIRECT_ENABLED:-y}" in
    n|N|no|NO|0) return 1 ;;
  esac
  local -a args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=( "$line" )
  done < <(gh_resolve_args)
  [ ${#args[@]} -eq 0 ] && return 1
  curl --connect-timeout 5 -m 15 -sk -L -o /dev/null -r 0-1023 \
       "${args[@]}" "$url" >/dev/null 2>&1
}

# How many chunks to fetch at once.
# A single stream to GitHub's CDN from a mainland network is rate limited to
# roughly 17 KB/s; the same file over several parallel range requests is
# several times faster, because the limit is per stream and not per transfer.
GH_DIRECT_PARALLEL="${GH_DIRECT_PARALLEL:-8}"

# Fetch a byte range into a file.
# Usage: _gh_fetch_range <url> <start> <end> <out>
_gh_fetch_range() {
  local url="$1" start="$2" end="$3" out="$4"
  curl --connect-timeout 10 -m 1800 --retry 3 --retry-delay 2 --retry-connrefused \
       -f -r "${start}-${end}" -o "$out" "$url" >/dev/null 2>&1
}

# Download a URL in parallel chunks.
# Usage: gh_direct_download_parallel <url> <output-file>
# Prints nothing. Returns 0 on success.
# Only usable when the server serves byte ranges; the caller falls back to a
# single stream when it does not.
gh_direct_download_parallel() {
  local url="$1" out="$2"
  local -a args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=( "$line" )
  done < <(gh_resolve_args)
  [ ${#args[@]} -eq 0 ] && return 1

  # The effective URL after the redirect, carrying the signed query through.
  local effective
  effective=$(curl --connect-timeout 10 -m 60 -skIL "${args[@]}" \
                -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null)
  [ -z "$effective" ] && effective="$url"

  # A one-byte range request answers with Content-Range, which both proves
  # that ranges work and gives the total size. Without it there is nothing to
  # split, and the single-stream path is the only option.
  local headers size
  headers=$(curl --connect-timeout 10 -m 30 -skI -r 0-0 "${args[@]}" "$effective" 2>/dev/null)
  size=$(printf '%s' "$headers" | grep -i '^content-range:' | tr -d '\r' | grep -oE '[0-9]+$')
  [ -n "$size" ] || return 1
  [ "$size" -gt 1048576 ] || return 1   # small files are not worth splitting

  local n="${GH_DIRECT_PARALLEL}"
  [ "$n" -lt 2 ] && return 1
  [ "$n" -gt 16 ] && n=16

  local work
  work=$(mktemp -d 2>/dev/null) || return 1

  local chunk=$(( (size + n - 1) / n ))
  local i start end
  local pids=()
  for i in $(seq 0 $((n - 1))); do
    start=$(( i * chunk ))
    end=$(( start + chunk - 1 ))
    [ $end -ge $size ] && end=$(( size - 1 ))
    [ $start -ge $size ] && continue
    _gh_fetch_range "$effective" "$start" "$end" "${work}/part.${i}" &
    pids+=($!)
  done

  local failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done

  if [ $failed -ne 0 ]; then
    # A chunk did not arrive. Clean up and let the caller fall back to the
    # single-stream path, which is slower but does not depend on ranges.
    rm -rf "$work"
    return 1
  fi

  # Assemble in order.
  : > "${out}.assembling"
  for i in $(seq 0 $((n - 1))); do
    [ -f "${work}/part.${i}" ] || { rm -rf "$work" "${out}.assembling"; return 1; }
    cat "${work}/part.${i}" >> "${out}.assembling"
  done
  mv -f "${out}.assembling" "$out"
  rm -rf "$work"
  return 0
}

# Download a URL through a pinned address.
# Usage: gh_direct_download <url> <output-file>
#
# The redirect is resolved first and the transfer then runs against the final
# URL. That is not just a saving of one hop: curl's -C - (resume) does not
# survive a 302, so a resumed transfer has to be aimed at the asset host
# directly. wget, which this path replaces, did re-issue the Range header
# after the redirect, which is why the old path could resume where curl
# cannot.
#
# Not every GitHub URL serves byte ranges. The release assets (the ones that
# carry the source tarballs) do; codeload, which serves the /archive/ form,
# answers a Range request with the whole body. curl exits 33 in that case, and
# the transfer is restarted from the beginning — the only correct thing to do
# when the server refuses to resume.
gh_direct_download() {
  local url="$1" out="$2"
  command -v curl >/dev/null 2>&1 || return 1
  # Enabled by default; set GH_DIRECT_ENABLED=n to turn it off. The default
  # has to be a substitution: a caller running under `set -u` would abort on
  # an unset variable instead of taking the normal path.
  case "${GH_DIRECT_ENABLED:-y}" in
    n|N|no|NO|0) return 1 ;;
  esac
  [[ "$url" == "https://github.com/"* || "$url" == "https://raw.githubusercontent.com/"* ]] || return 1

  local -a args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=( "$line" )
  done < <(gh_resolve_args)
  [ ${#args[@]} -eq 0 ] && return 1

  # The effective URL after the redirect, carrying the signed query through.
  local effective
  effective=$(curl --connect-timeout 10 -m 60 -skIL "${args[@]}" \
                -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null)
  [ -z "$effective" ] && effective="$url"

  # Parallel chunks first: a single stream to GitHub's CDN is rate limited to
  # roughly 17 KB/s from a mainland network, while several range requests at
  # once are several times faster. Falls through to the single-stream path
  # when the server does not serve ranges, or when a chunk fails.
  if gh_direct_download_parallel "$url" "$out"; then
    return 0
  fi

  local rc
  curl --connect-timeout 10 -m 1800 --retry 3 --retry-delay 2 --retry-connrefused \
       -C - -f "${args[@]}" -o "$out" "$effective" >/dev/null 2>&1
  rc=$?
  [ $rc -eq 0 ] && return 0

  # 33: the server does not serve byte ranges, so a partial file cannot be
  # continued — start over. Any other failure is left to the caller's own
  # retry path, with the partial file kept for the next attempt.
  if [ $rc -eq 33 ]; then
    rm -f "$out"
    curl --connect-timeout 10 -m 1800 --retry 3 --retry-delay 2 --retry-connrefused \
         -f "${args[@]}" -o "$out" "$effective" >/dev/null 2>&1
    return $?
  fi
  return $rc
}
