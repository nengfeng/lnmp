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
# TWO THINGS THAT MATTER, LEARNED THE HARD WAY
# ----------------------------------------------
# 1. The address that works from a mainland network is GitHub's ASIA anycast
#    (20.205.243.166 and friends), not the 140.82.x range. A first version
#    only trusted 140.82.x / 185.199.x / 192.30.x and therefore DISCARDED
#    the one address that would have worked — the pinned path failed on every
#    mainland run and the installer silently fell back to wget.
#
# 2. One address is not enough. A resolver hands out a single address and any
#    one of GitHub's addresses may be unreachable or throttled from a given
#    network, so several candidates are tried in turn and the first one that
#    actually transfers wins.
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

# Address blocks GitHub is known to use, tried when no resolver answers.
#
# The 20.x entries are the ASIA anycast range (20.205.243.166 and friends),
# which is what a mainland network can actually reach; the 140.82.x and
# 192.30.x entries are the US ranges. The 185.199.x entries are Fastly, which
# is what serves the release assets themselves.
#
# Only the first address of each block is tried: they are all anycast, so one
# reachable address is enough, and the probe that follows is what decides.
GH_KNOWN_PREFIXES=(
  "20.205.243." "20.27.177." "20.200.245." "20.201.28." "20.207.73." "20.248.137."
  "140.82.112." "140.82.113." "140.82.114." "140.82.121."
  "185.199.108." "185.199.109." "185.199.110." "185.199.111."
)

# How many chunks to fetch at once.
# A single stream to GitHub's CDN from a mainland network is rate limited to
# roughly 17 KB/s; the same file over several parallel range requests is
# several times faster, because the limit is per stream and not per transfer.
GH_DIRECT_PARALLEL="${GH_DIRECT_PARALLEL:-8}"

# Cache of resolved addresses, so one download does not re-resolve every host.
declare -A _GH_RESOLVED=()

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
_gh_addr_looks_sane() {
  local ip="$1"
  case "$ip" in
    127.*|0.*|10.*|192.168.*|169.254.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-9].*|172.1[6-9].*|172.2*|172.3[01].*|224.*|240.*) return 1 ;;
    *) return 0 ;;
  esac
}

# Resolve a hostname through one DoH endpoint.
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
# Prints one address per line: the resolver's answers, then the known
# prefixes. The caller tries them in order, because any single one of
# GitHub's addresses may be unreachable or throttled from a given network.
_gh_candidate_list() {
  local host="$1"
  local ip endpoint

  if [ -n "${_GH_RESOLVED[$host]:-}" ]; then
    printf '%s\n' "${_GH_RESOLVED[$host]}"
  fi

  # The resolvers are asked in parallel. Asked one after another they cost the
  # sum of their timeouts, and one unreachable endpoint then delays every
  # download by its full timeout — 30 seconds before the first candidate
  # exists, on the network that needs this path most.
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
  fi

  # The resolvers answer with the same anycast address more than once, and
  # each duplicate would be tried again, so the list is deduplicated.
  local seen=" " found=0
  if [ -n "$tmp" ]; then
    for f in "${tmp}"/*.ip; do
      [ -f "$f" ] || continue
      ip=$(cat "$f" 2>/dev/null)
      if [ -n "$ip" ] && _gh_addr_looks_sane "$ip"; then
        case "$seen" in
          *" $ip "*) continue ;;
        esac
        seen="$seen$ip "
        found=$((found + 1))
        printf '%s\n' "$ip"
      fi
    done
  fi
  [ -n "$tmp" ] && rm -rf "$tmp"

  # A resolver answered: there is no reason to probe the known blocks.
  [ $found -gt 0 ] && return 0

  # No resolver answered. Probe the known blocks for an address that completes
  # a TLS handshake.
  #
  # Bounded on purpose: a full sweep of every prefix is 8 x 254 = 2032
  # connections, each up to a few seconds, which would stall the installer
  # for a long time on the very network that needs this path most. GitHub's
  # blocks are anycast, so a handful of addresses per block is enough, and the
  # probe stops at the first one that answers.
  local prefix cand probes=0
  for prefix in "${GH_KNOWN_PREFIXES[@]}"; do
    for cand in $(seq 1 4); do
      [ $probes -ge 24 ] && break 2
      cand="${prefix}${cand}"
      probes=$((probes + 1))
      if command -v curl >/dev/null 2>&1 \
         && curl --connect-timeout 3 -m 5 -sk -o /dev/null \
              --resolve "${host}:443:${cand}" "https://${host}/" 2>/dev/null; then
        printf '%s\n' "$cand"
        break
      fi
    done
  done
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

  ip=$(_gh_candidate_list "$host" | head -1)
  if [ -z "$ip" ]; then
    return 1
  fi
  _GH_RESOLVED[$host]="$ip"
  _GH_RESOLVED_IP="$ip"
  return 0
}

# Build the curl --resolve arguments for the hosts involved in a GitHub
# download. Prints one argument per line; empty when nothing could be pinned.
# The host named by $2 (when given) is pinned to the address in $3, so the
# caller can rotate the primary host through its candidate list.
gh_resolve_args() {
  local host ip pin_host="${2:-}" pin_ip="${3:-}"
  for host in "${GH_PIN_HOSTS[@]}"; do
    if [ "$host" = "$pin_host" ] && [ -n "$pin_ip" ]; then
      ip="$pin_ip"
    else
      gh_resolve_clean "$host" || continue
      ip="$_GH_RESOLVED_IP"
    fi
    printf -- '--resolve\n%s:443:%s\n' "$host" "$ip"
  done
}

# Can this URL be fetched through a pinned address?
# Probes with a small range request so the check is cheap.
gh_direct_probe() {
  local url="$1"
  command -v curl >/dev/null 2>&1 || return 1
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

# Fetch a byte range into a file.
# Usage: _gh_fetch_range <url> <start> <end> <out>
_gh_fetch_range() {
  local url="$1" start="$2" end="$3" out="$4"
  curl --connect-timeout 10 -m 1800 --retry 3 --retry-delay 2 --retry-connrefused \
       -f -r "${start}-${end}" -o "$out" "$url" >/dev/null 2>&1
}

# Download a URL in parallel chunks.
# Usage: gh_direct_download_parallel <url> <output-file> [pin-host] [pin-ip]
# Prints nothing. Returns 0 on success.
# Only usable when the server serves byte ranges; the caller falls back to a
# single stream when it does not.
gh_direct_download_parallel() {
  local url="$1" out="$2" pin_host="${3:-}" pin_ip="${4:-}"
  local -a args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=( "$line" )
  done < <(gh_resolve_args "" "$pin_host" "$pin_ip")
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
  host="${url#https://}"
  host="${host%%/*}"
  host="${host%%\?*}"

  local cand tried=0 rc
  while read -r cand; do
    [ -n "$cand" ] || continue
    tried=$((tried + 1))
    [ $tried -gt 6 ] && break

    # Parallel chunks first: a single stream to GitHub's CDN is rate limited
    # to roughly 17 KB/s from a mainland network, while several range requests
    # at once are several times faster.
    if gh_direct_download_parallel "$url" "$out" "$host" "$cand"; then
      _GH_RESOLVED[$host]="$cand"
      return 0
    fi

    local -a args=()
    while IFS= read -r line; do
      [ -n "$line" ] && args+=( "$line" )
    done < <(gh_resolve_args "" "$host" "$cand")
    [ ${#args[@]} -eq 0 ] && continue

    # The effective URL after the redirect, carrying the signed query through.
    local effective
    effective=$(curl --connect-timeout 10 -m 60 -skIL "${args[@]}" \
                  -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null)
    [ -z "$effective" ] && effective="$url"

    curl --connect-timeout 10 -m 1800 --retry 3 --retry-delay 2 --retry-connrefused \
         -C - -f "${args[@]}" -o "$out" "$effective" >/dev/null 2>&1
    rc=$?
    if [ $rc -eq 0 ]; then
      _GH_RESOLVED[$host]="$cand"
      return 0
    fi

    # 33: the server does not serve byte ranges, so a partial file cannot be
    # continued — start over. Any other failure is left to the caller's own
    # retry path, with the partial file kept for the next attempt.
    if [ $rc -eq 33 ]; then
      rm -f "$out"
      curl --connect-timeout 10 -m 1800 --retry 3 --retry-delay 2 --retry-connrefused \
           -f "${args[@]}" -o "$out" "$effective" >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        _GH_RESOLVED[$host]="$cand"
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
