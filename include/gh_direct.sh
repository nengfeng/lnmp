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

# Should the pinned-address path be tried FIRST?
#
# The pinned path exists for mainland networks, where github.com can resolve
# to a poisoned address and a single stream is throttled to a crawl. Outside
# the mainland GitHub is normally fast and the direct name works, so going
# through the pinned machinery first only adds resolution probes and a detour
# that can break downloads on a host that reaches the network through a proxy.
#
# GH_DIRECT_ENABLED keeps its old meaning when set explicitly:
#   y / yes / force  -> prefer the pinned path everywhere
#   n / no / 0       -> never use it (gh_direct_download refuses)
# Otherwise the decision is geographic. An unknown location keeps the old
# China-safe default: the pinned path works anywhere, and a mainland box whose
# geo lookup is blocked must not silently lose it.
#
# This is about ordering, not availability: outside the mainland the pinned
# path is still used as a rescue after the direct download fails.
gh_direct_preferred() {
  case "${GH_DIRECT_ENABLED:-}" in
    y|Y|yes|YES|force|FORCE|1) return 0 ;;
    n|N|no|NO|0) return 1 ;;
  esac
  case "${OUTIP_STATE:-}" in
    CN) return 0 ;;
    ""|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

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

# The cache directory is created once, when this file is sourced, and not
# when it is first needed.
#
# The reason is the subshell: the callers capture things in command
# substitutions, and a subshell that creates its own cache directory writes
# the entry there — where the parent will never look. The parent then creates
# a second directory, and the address that was already found is looked up
# again from scratch. Every resolution is then paid for twice, which is
# exactly the kind of waste that turns into seconds on a slow network.
_gh_cache_init || true

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

# ---------------------------------------------------------------- addresses
#
# THE RESOLUTION HAS TO BE BOUNDED.
#
# A mainland network cannot reach some of GitHub's hosts at all —
# objects.githubusercontent.com and codeload.github.com are the usual two —
# and an unreachable host used to cost the sum of its candidates' timeouts:
# tens of seconds each, all of it silent, which is what made the install
# look frozen with no output at all. Three rules now apply:
#
#   * the candidates of one host are probed at the same time, so a single
#     unreachable address does not delay the others;
#   * the phases (local resolver, over-HTTPS resolver, known addresses) are
#     tried in order and the first that works wins;
#   * the whole thing runs under a deadline, and whatever has been found by
#     then is used.
#
# Progress is printed. A download that is thinking has to say so.

# How long one address may take to answer a probe.
GH_DIRECT_PROBE_TIMEOUT="${GH_DIRECT_PROBE_TIMEOUT:-5}"
# How long the resolution of all hosts may take in total.
GH_DIRECT_RESOLVE_BUDGET="${GH_DIRECT_RESOLVE_BUDGET:-20}"
# How many candidates are tried per host.
GH_DIRECT_MAX_CANDIDATES="${GH_DIRECT_MAX_CANDIDATES:-8}"

# The measured speed of the accelerator gh_fastest_accelerator picked.
_GH_FASTEST_ACCEL_SPEED=0

# The deadline of the current resolution, as a unix timestamp. 0 = no limit.
_GH_RESOLVE_DEADLINE=0

_gh_deadline_hit() {
  [ "$_GH_RESOLVE_DEADLINE" -gt 0 ] || return 1
  [ "$(date +%s)" -ge "$_GH_RESOLVE_DEADLINE" ]
}

# The local resolver's answer for a host.
#
# This is tried first: it is instant and, where the name is not poisoned,
# it is the address that works. The answer is verified against the
# certificate afterwards, so a poisoned answer is rejected rather than
# trusted.
_gh_candidates_local() {
  local host="$1" ip
  while read -r ip; do
    [ -n "$ip" ] && _gh_addr_usable "$ip" && printf '%s\n' "$ip"
  done < <(_gh_system_dns "$host")
  return 0
}

# The over-HTTPS resolvers' answers.
#
# The resolvers are asked in parallel. Asked one after another they cost the
# sum of their timeouts, and one unreachable endpoint then delays every
# download by its full timeout — 30 seconds before the first candidate
# exists, on the network that needs this path most.
_gh_candidates_doh() {
  local host="$1" ip
  local tmp
  tmp=$(mktemp -d 2>/dev/null) || return 0
  local pids=() i=0
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
  return 0
}

# The addresses GitHub is known to use.
_gh_candidates_known() {
  local ip
  for ip in "${GH_KNOWN_ADDRS[@]}"; do
    printf '%s\n' "$ip"
  done
  return 0
}

# Candidate addresses for a host, most likely first.
# Prints one address per line: the cached one, the local resolver's answer,
# the over-HTTPS resolvers' answers, then the known addresses.
_gh_candidate_list() {
  local host="$1"
  local ip

  local cached
  cached=$(_gh_cache_get "pin_${host}")
  [ -n "$cached" ] && printf '%s\n' "$cached"

  _gh_candidates_local "$host"
  _gh_candidates_doh "$host"
  _gh_candidates_known "$host"
  return 0
}

# Does this address really serve this host?
# The certificate is checked (no -k): that is what makes an arbitrary
# address safe to try.
_gh_probe_address() {
  local host="$1" ip="$2"
  command -v curl >/dev/null 2>&1 || return 1
  curl --connect-timeout 3 -m "${GH_DIRECT_PROBE_TIMEOUT}" -s -o /dev/null \
       --resolve "${host}:443:${ip}" "https://${host}/" >/dev/null 2>&1
}

# Probe several candidates for a host at the same time and take the first
# one that works.
#
# Usage: _gh_probe_any <host> <candidate>...
# On success _GH_PICKED_IP holds the address.
#
# The candidates are probed concurrently on purpose. Probed one after
# another, a single unreachable address costs its full timeout before the
# next one is even tried — and the address that works is often the second.
_gh_probe_any() {
  local host="$1"; shift
  local -a cands=("$@")
  [ ${#cands[@]} -gt 0 ] || return 1

  local work
  work=$(mktemp -d 2>/dev/null) || return 1

  local i pids=()
  for i in "${!cands[@]}"; do
    ( _gh_probe_address "$host" "${cands[$i]}" \
        && printf '%s' "${cands[$i]}" > "${work}/ok.${i}" 2>/dev/null ) &
    pids+=($!)
  done

  local limit="${GH_DIRECT_PROBE_TIMEOUT}"
  if _gh_deadline_hit; then
    limit=1
  fi
  local deadline=$(( SECONDS + limit ))
  local found=""
  while [ $SECONDS -lt $deadline ]; do
    local f
    for f in "${work}"/ok.*; do
      if [ -f "$f" ]; then
        found=$(cat "$f" 2>/dev/null || true)
        break
      fi
    done
    [ -n "$found" ] && break
    sleep 0.2
  done

  # Stop the probes that are still running.
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null; done

  rm -rf "$work"
  [ -n "$found" ] || return 1
  _GH_PICKED_IP="$found"
  return 0
}

# Find an address that works for a host.
# On success _GH_PICKED_IP holds the address. Returns non-zero when no
# candidate could be reached.
#
# The phases are tried in order, and each phase is a parallel probe, so the
# common case — the local resolver's answer works — costs one connection.
_gh_pick_address() {
  local host="$1"
  _GH_PICKED_IP=""

  _gh_cache_init || true

  local cached
  cached=$(_gh_cache_get "pin_${host}")
  if [ -n "$cached" ]; then
    _GH_PICKED_IP="$cached"
    return 0
  fi

  local -a cands=()
  local c
  while read -r c; do
    [ -n "$c" ] || continue
    cands+=("$c")
  done < <(_gh_candidates_local "$host")

  if [ ${#cands[@]} -gt 0 ]; then
    if _gh_probe_any "$host" "${cands[@]:0:${GH_DIRECT_MAX_CANDIDATES}}"; then
      _gh_cache_set "pin_${host}" "$_GH_PICKED_IP" || true
      echo "gh_direct: ${host} -> ${_GH_PICKED_IP} (local resolver)" >&2
      return 0
    fi
  fi

  _gh_deadline_hit && return 1

  cands=()
  while read -r c; do
    [ -n "$c" ] || continue
    cands+=("$c")
  done < <(_gh_candidates_doh "$host")

  if [ ${#cands[@]} -gt 0 ]; then
    if _gh_probe_any "$host" "${cands[@]:0:${GH_DIRECT_MAX_CANDIDATES}}"; then
      _gh_cache_set "pin_${host}" "$_GH_PICKED_IP" || true
      echo "gh_direct: ${host} -> ${_GH_PICKED_IP} (over-HTTPS resolver)" >&2
      return 0
    fi
  fi

  _gh_deadline_hit && return 1

  cands=()
  while read -r c; do
    [ -n "$c" ] || continue
    cands+=("$c")
  done < <(_gh_candidates_known "$host")

  if [ ${#cands[@]} -gt 0 ]; then
    if _gh_probe_any "$host" "${cands[@]:0:${GH_DIRECT_MAX_CANDIDATES}}"; then
      _gh_cache_set "pin_${host}" "$_GH_PICKED_IP" || true
      echo "gh_direct: ${host} -> ${_GH_PICKED_IP} (known address)" >&2
      return 0
    fi
  fi

  echo "gh_direct: no address for ${host} could be reached" >&2
  return 1
}

# Point the host the URL names at a different address, leaving the other
# hosts as they are.
_gh_set_primary_resolve() {
  local host="$1" ip="$2"
  [ -n "$ip" ] || return 1
  # The array is called "args", not "out": "out" is a plain string in the
  # download functions of this file, and shellcheck follows the sourced
  # files, so an array and a string sharing a name make it report "variable
  # was used as an array but is now assigned a string" in every file that
  # sources this one.
  local -a args=()
  local a found="no"
  for a in "${_GH_RESOLVE_ARGS[@]}"; do
    case "$a" in
      "${host}:443:"*)
        args+=( "${host}:443:${ip}" )
        found="yes"
        ;;
      *) args+=( "$a" ) ;;
    esac
  done
  [ "$found" = "yes" ] || args+=( --resolve "${host}:443:${ip}" )
  _GH_RESOLVE_ARGS=( "${args[@]}" )
  return 0
}

# The --resolve arguments for the current download.
# Fills the global array _GH_RESOLVE_ARGS.
# $1: host to pin to $2; $2: that address (empty: pick one).
#
# Only the hosts that can actually be involved are resolved: the one the URL
# names, and the one that carries the bytes after the redirect. The rest are
# pinned on demand, when a redirect points at them. Resolving a host the
# transfer never uses costs a connection — and on a mainland network, where
# some of them are unreachable, it costs seconds of silence.
gh_resolve_args() {
  local primary_host="${1:-}" primary_ip="${2:-}"
  _GH_RESOLVE_ARGS=()
  _gh_cache_init || true

  local -a hosts=()
  [ -n "$primary_host" ] && hosts+=( "$primary_host" )
  local h
  for h in "${GH_PIN_HOSTS[@]}"; do
    [ "$h" = "$primary_host" ] && continue
    hosts+=( "$h" )
  done

  # Everything below runs under one deadline.
  _GH_RESOLVE_DEADLINE=$(( $(date +%s) + GH_DIRECT_RESOLVE_BUDGET ))

  local h ip
  for h in "${hosts[@]}"; do
    if [ "$h" = "$primary_host" ] && [ -n "$primary_ip" ]; then
      ip="$primary_ip"
    else
      _gh_pick_address "$h" || continue
      ip="$_GH_PICKED_IP"
    fi
    _GH_RESOLVE_ARGS+=( --resolve "${h}:443:${ip}" )
  done

  _GH_RESOLVE_DEADLINE=0
  return 0
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
  raw=$(curl --connect-timeout 10 -m 30 -sS -L -r 0-0 -D - -o /dev/null \
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

  echo "gh_direct: measuring the pinned path..." >&2
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

# The accelerators to try, in order.
#
# GITHUB_ACCELERATOR_URL stays a single value: it is referenced by name in
# many places (install.sh, vhost.sh, backup_setup.sh, sources.conf) and all
# of them build "${GITHUB_ACCELERATOR_URL%/}/${url}". The extra fallbacks
# live in their own variable, used only by the download layer.
#
# The reason for a list at all: these services come and go, and one dead
# accelerator is a single point of failure for the mainland fallback path.
# The accelerator only carries bytes — the expected checksum is pinned in the
# repository — so a list of them costs nothing in trust terms.
gh_accelerator_list() {
  local all one
  all="${GITHUB_ACCELERATOR_URL:-} ${GITHUB_ACCELERATOR_FALLBACKS:-}"
  local -a seen=()
  for one in ${all//,/ }; do
    one="${one%/}"
    [ -n "$one" ] || continue
    local dup="no" s
    for s in "${seen[@]}"; do
      [ "$s" = "$one" ] && dup="yes" && break
    done
    [ "$dup" = "yes" ] && continue
    seen+=("$one")
    printf '%s\n' "$one"
  done
  return 0
}

# The accelerator URL for a GitHub URL, one per accelerator.
gh_accelerator_urls_for() {
  local url="$1" accel
  [[ "${url}" == "https://github.com/"* ]] || return 0
  while read -r accel; do
    [ -n "$accel" ] && printf '%s\n' "${accel}/${url}"
  done < <(gh_accelerator_list)
  return 0
}

# Is this URL served by one of the accelerators?
gh_is_accelerator_url() {
  local url="$1" accel
  while read -r accel; do
    [ -n "$accel" ] || continue
    case "$url" in
      "${accel}/"*) return 0 ;;
    esac
  done < <(gh_accelerator_list)
  return 1
}

# Measure a URL's transfer speed with a short ranged sample.
# Prints bytes/sec; prints nothing when the probe could not run.
gh_url_speed() {
  local url="$1"
  local sample_bytes="${2:-524288}"
  local max_time="${3:-8}"
  command -v curl >/dev/null 2>&1 || return 1
  local raw
  raw=$(curl --connect-timeout 5 -m "${max_time}" -sS -L -o /dev/null \
          -r "0-$((sample_bytes - 1))" -w '%{speed_download}' \
          "${url}" 2>/dev/null || true)
  [ -n "$raw" ] || return 1
  printf '%d\n' "${raw%.*}"
}

# The total size of a URL, from the Content-Range of a one-byte range
# request. Prints nothing when the server does not serve ranges.
_gh_url_size() {
  local url="$1"
  local headers size
  # A short timeout: this runs for every accelerator, and an accelerator
  # that is unreachable from here must not delay the decision by its full
  # budget.
  headers=$(curl --connect-timeout 4 -m 6 -s -D - -o /dev/null -r 0-0 \
              "$url" 2>/dev/null | tr -d '\r' || true)
  size=$(printf '%s' "$headers" | grep -ai '^content-range:' | tail -1 | grep -oE '[0-9]+$' || true)
  [ -n "$size" ] || return 1
  printf '%s\n' "$size"
}

# Measure a URL's transfer speed with several range requests at once.
#
# The same method as the pinned path uses, so that the two are comparable:
# the gate that decides between them has to compare like with like.
gh_url_speed_parallel() {
  local url="$1"
  local sample_bytes="${2:-524288}"
  local max_time="${3:-8}"
  local streams="${4:-8}"
  command -v curl >/dev/null 2>&1 || return 1

  local size
  size=$(_gh_url_size "$url") || return 1
  [ "$size" -gt "$sample_bytes" ] || sample_bytes="$size"

  local n="$streams"
  [ "$n" -lt 1 ] && n=1
  [ "$n" -gt 16 ] && n=16

  local work
  work=$(mktemp -d 2>/dev/null) || return 1

  local chunk=$(( sample_bytes / n ))
  [ "$chunk" -lt 1 ] && chunk=1
  local i start end pids=()
  local t0 t1
  t0=$(date +%s%N)
  for i in $(seq 0 $((n - 1))); do
    start=$(( i * chunk ))
    end=$(( start + chunk - 1 ))
    [ $end -ge $size ] && end=$(( size - 1 ))
    [ $start -ge $size ] && continue
    curl --connect-timeout 5 -m "${max_time}" -s -f -r "${start}-${end}" \
         -o "${work}/p.${i}" "$url" >/dev/null 2>&1 &
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

# The fastest accelerator for a URL.
#
# Prints "<accelerator>/<url>" for the fastest accelerator, and leaves its
# measured speed in _GH_FASTEST_ACCEL_SPEED so that the caller can compare
# it with what it already measured and decide whether switching is worth it.
#
# Switching to an accelerator that is slower than the path being replaced
# would make things worse, so the speed is reported rather than assumed.
# Prints "<accelerator>/<url> <speed>".
#
# The speed is part of the output on purpose. The caller captures this in a
# command substitution — a subshell — and a variable set inside a subshell is
# lost when it exits. A global carrying the speed therefore read back as
# zero in the parent, and the gate concluded that the accelerator was
# slower than the path it was replacing, when it was in fact three times
# faster. The number travels with the URL instead.
gh_fastest_accelerator() {
  local url="$1"
  local min_speed="${2:-0}"
  command -v curl >/dev/null 2>&1 || return 1

  _GH_FASTEST_ACCEL_SPEED=0

  # Every accelerator is measured at the same time. Probed one after another
  # they cost the sum of their timeouts, and an accelerator that is
  # unreachable from here (which is most of them, from most places) delays
  # the decision by its full timeout.
  local work
  work=$(mktemp -d 2>/dev/null) || return 1

  local accel i=0 pids=()
  while read -r accel; do
    [ -n "$accel" ] || continue
    local candidate="${accel}/${url}"
    (
      local speed
      speed=$(gh_url_speed_parallel "$candidate" \
                "${GH_DIRECT_SPEED_SAMPLE_BYTES:-524288}" \
                "${GH_DIRECT_SPEED_TEST_SECONDS:-8}" \
                "${GH_DIRECT_PARALLEL}" || true)
      if [ -z "$speed" ]; then
        speed=$(gh_url_speed "$candidate" \
                  "${GH_DIRECT_SPEED_SAMPLE_BYTES:-524288}" \
                  "${GH_DIRECT_SPEED_TEST_SECONDS:-8}" || true)
      fi
      [ -n "$speed" ] && printf '%s %s' "$candidate" "$speed" > "${work}/s.${i}" 2>/dev/null
    ) &
    pids+=($!)
    i=$((i + 1))
  done < <(gh_accelerator_list)

  local pid
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null; done

  local best="" best_speed=0 f u s
  for f in "${work}"/s.*; do
    [ -f "$f" ] || continue
    u=""
    s=""
    read -r u s < "$f" 2>/dev/null || true
    [ -n "$u" ] || continue
    [ -n "$s" ] || continue
    if [ -z "$best" ] || [ "$s" -gt "$best_speed" ]; then
      best="$u"
      best_speed="$s"
    fi
  done
  rm -rf "$work"

  [ -n "$best" ] || return 1
  _GH_FASTEST_ACCEL_SPEED="$best_speed"
  if [ "$best_speed" -lt "$min_speed" ]; then
    # Nothing was fast enough. Say so, and let the caller decide.
    echo "gh_accelerator: fastest was ${best} at ${best_speed} B/s, below ${min_speed} B/s" >&2
  fi
  printf '%s %s\n' "$best" "$best_speed"
  return 0
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

  # The other hosts are resolved ONCE, here. Resolving them inside the loop
  # below meant that every candidate paid for the resolution of hosts it was
  # never going to use: on a mainland network, where some of GitHub's hosts
  # are unreachable, that is several minutes of silence per download.
  gh_resolve_args "$host" ""
  if [ ${#_GH_RESOLVE_ARGS[@]} -eq 0 ]; then
    echo "gh_direct: no address could be pinned for ${host}" >&2
    return 1
  fi

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
    [ $tried -gt 4 ] && break

    # Only the host the URL names is rotated; the rest stay as resolved.
    _gh_set_primary_resolve "$host" "$cand"

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
    effective=$(curl --connect-timeout 10 -m 30 -sSIL "${_GH_RESOLVE_ARGS[@]}" \
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
