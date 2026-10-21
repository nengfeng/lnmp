#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
# Direct GitHub downloads through an address that is known to work.
#
# WHY
# ---
# In mainland China a GitHub release download is often painfully slow (a
# single stream to GitHub's CDN crawls at a few tens of KB/s) or hangs
# entirely when the name resolves to a poisoned address. The usual workaround
# is a third-party accelerator, but that trades the problem for a worse one:
# the accelerator serves the tarball AND the checksum file, so a SHA256 check
# verifies the accelerator against itself and proves nothing.
#
# This file takes the bytes from GitHub itself. The address may come from the
# local resolver, from a resolver over HTTPS, or from a list of addresses
# GitHub is known to use — whichever works. The trust anchor stays where it
# belongs: GitHub's TLS certificate. The download path never passes -k, so an
# address that does not serve GitHub fails the handshake and is discarded.
# (The checksum anchor lives in the repository, in component_checksums.txt,
# so the accelerator can still be used as a fallback transport without making
# the verification circular.)
#
# WHAT WAS LEARNED THE HARD WAY
# -----------------------------
# 1. THE ADDRESS THAT WORKS IS NOT THE ONE THAT LOOKS RIGHT. From a mainland
#    network the reachable address is GitHub's ASIA anycast (20.205.243.166
#    and friends), not the 140.82.x range. An early version kept a strict
#    allowlist of GitHub's ranges and therefore DISCARDED the one address
#    that would have worked.
#
# 2. THE LOCAL RESOLVER IS USUALLY RIGHT. The mainland run this was written
#    for resolved github.com to 20.205.243.166 — the correct Asia anycast —
#    so the local answer is tried FIRST. It is still verified against the
#    certificate, so a poisoned answer is simply rejected.
#
# 3. "KNOWN PREFIXES" WERE NOT ADDRESSES. A list of prefixes with the last
#    octet appended (20.205.243. + 1..4) probed addresses that do not exist;
#    the real one is 20.205.243.166. The probe budget was also spent entirely
#    on the first few prefixes, so the usable ones were never reached. The
#    list is now full addresses.
#
# 4. A PARALLEL DOWNLOAD IS ONLY A DOWNLOAD IF EVERY PART IS FETCHED THROUGH
#    THE SAME PINNED ADDRESS. The chunk requests have to carry the --resolve
#    arguments as well, or they go back to the poisoned name.
#
# 5. THE SERVER HAS TO CONFIRM THAT IT SERVED A RANGE. A server that ignores
#    the Range header answers 200 with the whole body, and concatenating
#    those parts would produce a file of N times the right size. Each part is
#    therefore checked against the length that was asked for.
#
# Everything here is best-effort: a failure returns non-zero and the caller
# falls back to the ordinary path. Nothing in this file may abort an install.

# Resolvers used to obtain an answer that is not poisoned. The first two are
# operated in China and answer over HTTPS, so their answers are not subject
# to the local resolver's poisoning.
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

# Addresses GitHub is known to use, tried when neither the local resolver nor
# an over-HTTPS resolver gives a usable answer.
#
# These are FULL ADDRESSES, not prefixes: an early version stored prefixes
# and appended the last octet, which probed addresses that do not exist.
#
# The 20.x entries are the ASIA anycast range (20.205.243.166 and friends),
# which is what a mainland network can actually reach; the 140.82.x and
# 192.30.x entries are the US ranges; the 185.199.x entries are Fastly, which
# is what serves the release assets themselves.
GH_KNOWN_ADDRS=(
  # Asia anycast
  "20.205.243.166" "20.27.177.113" "20.200.245.247" "20.201.28.151"
  "20.207.73.82"   "20.248.137.48" "20.26.156.215" "20.233.83.145"
  # US anycast
  "140.82.112.3" "140.82.113.3" "140.82.114.3" "140.82.121.3"
  # Fastly, which serves the release assets
  "185.199.108.133" "185.199.109.133" "185.199.110.133" "185.199.111.133"
)

# How many chunks to fetch at once.
# A single stream to GitHub's CDN from a mainland network is rate limited to
# roughly 17-25 KB/s; the same file over several parallel range requests is
# several times faster, because the limit is per stream and not per transfer.
GH_DIRECT_PARALLEL="${GH_DIRECT_PARALLEL:-8}"

# Addresses that have been found to work, per host.
# A plain array would be lost whenever a function is called in a subshell —
# and the functions here are called in subshells (command substitution, process
# substitution) — so the cache is written to disk instead.
_GH_CACHE_DIR=""

_gh_cache_init() {
  [ -n "$_GH_CACHE_DIR" ] && return 0
  _GH_CACHE_DIR=$(mktemp -d 2>/dev/null) || _GH_CACHE_DIR=""
  [ -n "$_GH_CACHE_DIR" ] || return 1
  return 0
}

_gh_cache_get() {
  local f="${_GH_CACHE_DIR}/$1"
  # Always succeeds. A cache miss is not an error, and this function is called
  # from a command substitution: under "set -e" a non-zero status here would
  # terminate the calling subshell and the cache lookup would look like a
  # fatal error. That is exactly what happened — the candidate list came back
  # empty and the pinned path was reported as "no reachable address".
  [ -f "$f" ] && cat "$f" 2>/dev/null
  return 0
}

_gh_cache_set() {
  [ -n "$_GH_CACHE_DIR" ] || return 1
  printf '%s\n' "$2" > "${_GH_CACHE_DIR}/$1" 2>/dev/null
  return 0
}

# Is this address worth trying?
#
# This is a sanity filter, not the trust decision. The trust decision is the
# TLS certificate: the download path never passes -k, so an address that does
# not serve GitHub's certificate fails the handshake and the candidate is
# rejected. A strict allowlist of GitHub's ranges was tried first and was
# wrong twice over: it discarded the Asia anycast range (the only one
# reachable from a mainland network) and it would have to be amended every
# time GitHub adds a range.
#
# So: reject the addresses that cannot be right (loopback, private,
# link-local, 0.x) and let the certificate decide the rest.
_gh_addr_usable() {
  local ip="$1"
  case "$ip" in
    127.*|0.*|10.*|192.168.*|169.254.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-9].*|172.1[6-9].*|172.2*|172.3[01].*|224.*|240.*) return 1 ;;
    *) return 0 ;;
  esac
}

# The local resolver's answer for a host.
# This is tried first: on the mainland network this was written for, the
# local resolver answered correctly (github.com -> 20.205.243.166), and it
# costs nothing. The answer is verified against the certificate afterwards,
# so a poisoned answer is rejected rather than trusted.
_gh_system_dns() {
  local host="$1"
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u
    return 0
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$host" 2>/dev/null | grep -E '^[0-9]+\.'
  elif command -v host >/dev/null 2>&1; then
    host -t A "$host" 2>/dev/null | awk '/has address/{print $NF}'
  fi
}

# Resolve a hostname through one over-HTTPS resolver.
# Prints the address, or nothing when the endpoint did not answer.
_gh_doh_resolve_one() {
  local endpoint="$1" host="$2"
  # Short timeouts: these run in parallel, so the cost of one endpoint being
  # unreachable is its own timeout rather than everyone's.
  curl --connect-timeout 4 -m 8 -sk \
        -H 'accept: application/dns-json' \
        "${endpoint}?name=${host}&type=A" 2>/dev/null \
    | tr ',' '\n' | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}

# Candidate addresses for a host, most likely first.
# Prints one address per line: the local resolver's answer, then the
# over-HTTPS resolvers' answers, then the known addresses.
_gh_candidate_list() {
  local host="$1"
  local ip

  local cached
  cached=$(_gh_cache_get "pin_${host}")
  [ -n "$cached" ] && printf '%s\n' "$cached"

  # The local resolver first: it is instant and, where the name is not
  # poisoned, it is the address that works.
  while read -r ip; do
    [ -n "$ip" ] && _gh_addr_usable "$ip" && printf '%s\n' "$ip"
  done < <(_gh_system_dns "$host")

  # The over-HTTPS resolvers are asked in parallel. Asked one after another
  # they cost the sum of their timeouts, and one unreachable endpoint then
  # delays every download by its full timeout — 30 seconds before the first
  # candidate exists, on the network that needs this path most.
  local tmp
  tmp=$(mktemp -d 2>/dev/null) || tmp=""
  local pids=() i=0
  if [ -n "$tmp" ]; then
    for endpoint in "${GH_DOH_ENDPOINTS[@]}"; do
      _gh_doh_resolve_one "$endpoint" "$host" > "${tmp}/${i}.ip" 2>/dev/null &
      pids+=($!)
      i=$((i + 1))
    done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null; done
    for f in "${tmp}"/*.ip; do
      [ -f "$f" ] || continue
      ip=$(cat "$f" 2>/dev/null || true)
      [ -n "$ip" ] && _gh_addr_usable "$ip" && printf '%s\n' "$ip"
    done
    rm -rf "$tmp"
  fi

  # The addresses GitHub is known to use.
  for ip in "${GH_KNOWN_ADDRS[@]}"; do
    printf '%s\n' "$ip"
  done
}

# Does this address really serve this host?
# The certificate is checked (no -k): that is what makes an arbitrary
# address safe to try.
_gh_probe_address() {
  local host="$1" ip="$2"
  command -v curl >/dev/null 2>&1 || return 1
  curl --connect-timeout 4 -m 8 -s -o /dev/null \
       --resolve "${host}:443:${ip}" "https://${host}/" >/dev/null 2>&1
}

# Find an address that works for a host.
# On success _GH_PICKED_IP holds the address. Returns non-zero when no
# candidate could be reached.
_gh_pick_address() {
  local host="$1"
  local cand
  _GH_PICKED_IP=""

  _gh_cache_init || true

  local cached
  cached=$(_gh_cache_get "pin_${host}")
  if [ -n "$cached" ]; then
    _GH_PICKED_IP="$cached"
    return 0
  fi

  while read -r cand; do
    [ -n "$cand" ] || continue
    _gh_addr_usable "$cand" || continue
    if _gh_probe_address "$host" "$cand"; then
      _GH_PICKED_IP="$cand"
      _gh_cache_set "pin_${host}" "$cand" || true
      return 0
    fi
  done < <(_gh_candidate_list "$host")

  return 1
}

# The --resolve arguments for the current download.
# Fills the global array _GH_RESOLVE_ARGS.
# $1: host to pin to $2; $2: that address (empty: pick one).
gh_resolve_args() {
  local primary_host="${1:-}" primary_ip="${2:-}"
  _GH_RESOLVE_ARGS=()
  local host ip
  for host in "${GH_PIN_HOSTS[@]}"; do
    if [ "$host" = "$primary_host" ] && [ -n "$primary_ip" ]; then
      ip="$primary_ip"
    else
      _gh_pick_address "$host" || continue
      ip="$_GH_PICKED_IP"
    fi
    _GH_RESOLVE_ARGS+=( --resolve "${host}:443:${ip}" )
  done
}

# Pin a host that is not in GH_PIN_HOSTS but appeared in a redirect.
_gh_ensure_pinned() {
  local host="$1"
  local arg
  for arg in "${_GH_RESOLVE_ARGS[@]}"; do
    case "$arg" in
      "${host}:443:"*) return 0 ;;
    esac
  done
  _gh_pick_address "$host" || return 1
  _GH_RESOLVE_ARGS+=( --resolve "${host}:443:${_GH_PICKED_IP}" )
  return 0
}

# Host part of a URL.
_gh_url_host() {
  local url="$1"
  local h="${url#*://}"
  h="${h%%/*}"
  h="${h%%\?*}"
  h="${h%%:*}"
  printf '%s\n' "$h"
}

# Ask the server for the URL after redirects, and for the total size.
# The range request answers 206 with a Content-Range header that carries both
# the size and the proof that the server serves ranges. A HEAD request is no
# good: servers commonly ignore Range on HEAD and answer without a
# Content-Range, which is what silently disabled the parallel path.
#
# Prints: "<effective-url> <total-size>" on one line.
_gh_effective_and_size() {
  local url="$1"
  local raw
  raw=$(curl --connect-timeout 10 -m 60 -sS -L -r 0-0 -D - -o /dev/null \
          -w 'GH_EFFECTIVE:%{url_effective}' \
          "${_GH_RESOLVE_ARGS[@]}" "$url" 2>/dev/null || true)
  [ -n "$raw" ] || return 1

  local effective size
  effective=$(printf '%s' "$raw" | tr -d '\r' | grep -a '^GH_EFFECTIVE:' | tail -1 | sed 's/^GH_EFFECTIVE://')
  size=$(printf '%s' "$raw" | tr -d '\r' | grep -ai '^content-range:' | tail -1 | grep -oE '[0-9]+$' || true)
  [ -n "$effective" ] || effective="$url"
  [ -n "$size" ] || return 1

  printf '%s %s\n' "$effective" "$size"
  return 0
}

# Fetch a byte range into a file.
# The pinned addresses are passed on: a chunk request that does not carry
# them goes back to the possibly poisoned name, which defeats the whole
# point.
_gh_fetch_range() {
  local url="$1" start="$2" end="$3" out="$4"
  curl --connect-timeout 10 -m 1800 --retry 3 --retry-delay 2 --retry-connrefused \
       -s -f -r "${start}-${end}" -o "$out" "${_GH_RESOLVE_ARGS[@]}" "$url" >/dev/null 2>&1
}

# Download a URL in parallel chunks.
# Usage: gh_direct_download_parallel <url> <output-file>
# Returns 0 on success. The caller falls back to the single-stream path when
# this returns non-zero.
gh_direct_download_parallel() {
  local url="$1" out="$2"
  command -v curl >/dev/null 2>&1 || return 1
  [ ${#_GH_RESOLVE_ARGS[@]} -gt 0 ] || return 1

  local n="${GH_DIRECT_PARALLEL}"
  [ "$n" -ge 2 ] || return 1
  [ "$n" -gt 16 ] && n=16

  local info effective size
  info=$(_gh_effective_and_size "$url") || return 1
  effective="${info%% *}"
  size="${info##* }"
  [ -n "$size" ] || return 1
  [ "$size" -gt 1048576 ] || return 1   # small files are not worth splitting

  # The final host may not be one of the pinned ones.
  local ehost
  ehost=$(_gh_url_host "$effective")
  [ -n "$ehost" ] && _gh_ensure_pinned "$ehost" || true

  local work
  work=$(mktemp -d 2>/dev/null) || return 1

  local chunk=$(( (size + n - 1) / n ))
  local i start end expected
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

  # Every part must be exactly as long as was asked for. A server that
  # ignores the Range header answers 200 with the whole body, and those
  # parts would concatenate into a file N times too long.
  if [ $failed -ne 0 ]; then
    rm -rf "$work"
    return 1
  fi
  for i in $(seq 0 $((n - 1))); do
    start=$(( i * chunk ))
    end=$(( start + chunk - 1 ))
    [ $end -ge $size ] && end=$(( size - 1 ))
    [ $start -ge $size ] && continue
    expected=$(( end - start + 1 ))
    local actual
    actual=$(stat -c%s "${work}/part.${i}" 2>/dev/null || echo 0)
    if [ "$actual" != "$expected" ]; then
      rm -rf "$work"
      return 1
    fi
  done

  : > "${out}.assembling"
  for i in $(seq 0 $((n - 1))); do
    [ -f "${work}/part.${i}" ] || { rm -rf "$work" "${out}.assembling"; return 1; }
    cat "${work}/part.${i}" >> "${out}.assembling"
  done
  mv -f "${out}.assembling" "$out"
  rm -rf "$work"
  return 0
}

# Measure the speed of the pinned path with a bounded parallel sample.
# Prints bytes/sec, or nothing when the probe could not run.
#
# The sample is taken the same way the download will be taken — several range
# requests at once — because a single-stream sample understates the parallel
# path by exactly the factor that matters. The mainland limit is per stream,
# so one stream measures 22 KB/s while eight of them move 176 KB/s, and a
# gate on the single-stream number would throw away the fast path.
gh_direct_speed_probe() {
  local url="$1"
  local sample_bytes="${2:-1048576}"
  local max_time="${3:-10}"
  command -v curl >/dev/null 2>&1 || return 1

  gh_resolve_args "" ""
  [ ${#_GH_RESOLVE_ARGS[@]} -gt 0 ] || return 1

  local info effective size
  info=$(_gh_effective_and_size "$url") || return 1
  effective="${info%% *}"
  size="${info##* }"
  [ -n "$size" ] || return 1
  [ "$size" -gt "$sample_bytes" ] || sample_bytes="$size"

  local n="${GH_DIRECT_PARALLEL}"
  [ "$n" -ge 2 ] || n=2
  [ "$n" -gt 16 ] && n=16

  local work
  work=$(mktemp -d 2>/dev/null) || return 1

  local chunk=$(( sample_bytes / n ))
  [ "$chunk" -lt 1 ] && chunk=1
  local i start end
  local pids=()
  local t0 t1
  t0=$(date +%s%N)
  for i in $(seq 0 $((n - 1))); do
    start=$(( i * chunk ))
    end=$(( start + chunk - 1 ))
    [ $end -ge $size ] && end=$(( size - 1 ))
    [ $start -ge $size ] && continue
    curl --connect-timeout 5 -m "${max_time}" -s -f -r "${start}-${end}" \
         -o "${work}/p.${i}" "${_GH_RESOLVE_ARGS[@]}" "$effective" >/dev/null 2>&1 &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null; done
  t1=$(date +%s%N)

  local bytes=0 f sz
  for f in "${work}"/*; do
    [ -f "$f" ] || continue
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    bytes=$(( bytes + sz ))
  done
  rm -rf "$work"

  [ "$bytes" -gt 0 ] || return 1
  local ns=$(( t1 - t0 ))
  [ "$ns" -gt 0 ] || ns=1
  printf '%d\n' "$(( bytes * 1000000000 / ns ))"
}

# Download a URL through an address that is known to work.
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
# answers a Range request with the whole body. curl exits 33 in that case,
# and the transfer is restarted from the beginning — the only correct thing
# to do when the server refuses to resume.
#
# When one address does not work, the next candidate is tried: any single
# GitHub address may be unreachable or throttled from a given network.
gh_direct_download() {
  local url="$1" out="$2"
  command -v curl >/dev/null 2>&1 || return 1
  case "${GH_DIRECT_ENABLED:-y}" in
    n|N|no|NO|0) return 1 ;;
  esac
  [[ "$url" == "https://github.com/"* || "$url" == "https://raw.githubusercontent.com/"* ]] || return 1

  local host
  host=$(_gh_url_host "$url")

  _gh_cache_init || true

  local cand tried=0 rc
  local -a seen=()
  while read -r cand; do
    [ -n "$cand" ] || continue
    # Skip an address that was already tried for this host.
    local dup="no" s
    for s in "${seen[@]}"; do
      [ "$s" = "$cand" ] && dup="yes" && break
    done
    [ "$dup" = "yes" ] && continue
    seen+=("$cand")

    tried=$((tried + 1))
    [ $tried -gt 12 ] && break

    gh_resolve_args "$host" "$cand"
    [ ${#_GH_RESOLVE_ARGS[@]} -gt 0 ] || continue

    # Parallel chunks first: a single stream to GitHub's CDN is rate limited
    # to roughly 20 KB/s from a mainland network, while several range
    # requests at once are several times faster.
    if gh_direct_download_parallel "$url" "$out"; then
      _gh_cache_set "pin_${host}" "$cand" || true
      echo "gh_direct: ${host} via ${cand} (${GH_DIRECT_PARALLEL} parallel ranges)" >&2
      return 0
    fi

    # Single stream, with resume.
    local effective
    effective=$(curl --connect-timeout 10 -m 60 -sSIL "${_GH_RESOLVE_ARGS[@]}" \
                  -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null || true)
    [ -n "$effective" ] || effective="$url"

    curl --connect-timeout 10 -m 1800 --retry 3 --retry-delay 2 --retry-connrefused \
         -C - -f "${_GH_RESOLVE_ARGS[@]}" -o "$out" "$effective" >/dev/null 2>&1
    rc=$?
    if [ $rc -eq 0 ]; then
      _gh_cache_set "pin_${host}" "$cand" || true
      echo "gh_direct: ${host} via ${cand} (single stream)" >&2
      return 0
    fi

    # 33: the server does not serve byte ranges, so a partial file cannot be
    # continued — start over. Any other failure is left to the caller's own
    # retry path, with the partial file kept for the next attempt.
    if [ $rc -eq 33 ]; then
      rm -f "$out"
      curl --connect-timeout 10 -m 1800 --retry 3 --retry-delay 2 --retry-connrefused \
           -f "${_GH_RESOLVE_ARGS[@]}" -o "$out" "$effective" >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        _gh_cache_set "pin_${host}" "$cand" || true
        echo "gh_direct: ${host} via ${cand} (single stream)" >&2
        return 0
      fi
    fi
    rm -f "$out"
  done < <(_gh_candidate_list "$host")

  # Every candidate failed. Say so: a silent failure here is what made the
  # first mainland run look like "the pinned path was never tried".
  echo "gh_direct: no reachable address for ${host} (tried ${tried} candidates)" >&2
  return 1
}
