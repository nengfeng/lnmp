#!/bin/bash
# Author:  LNMP project
# SPDX-License-Identifier: Apache-2.0
# Description: Pure bash IP detection functions (replaces proprietary ois binary)
#
# Usage: source this file, then call:
#   ip_local          - Get local network IP address
#   ip_state          - Get country code of external IP (e.g., "CN", "US", "SG")
#   conn_port --host HOST --port PORT - Test TCP connectivity (echo "true"/"false")

# Get local IP address
# Prefers default route interface, falls back to hostname -I
ip_local() {
  local ip=""

  # Method 1: ip route (most reliable)
  if command -v ip >/dev/null 2>&1; then
    ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1)
  fi

  # Method 2: hostname -I
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi

  # Method 3: ifconfig fallback
  if [ -z "$ip" ] && command -v ifconfig >/dev/null 2>&1; then
    ip=$(ifconfig 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '^127\.' | head -1)
  fi

  echo "${ip:-127.0.0.1}"
}

# Get external IP location (country code)
# Returns 2-letter ISO country code (CN, US, SG, etc.)
# Uses multiple APIs for reliability, order: fastest → most reliable
ip_state() {
  local country=""

  # API 1: Cloudflare trace (fastest, no rate limit, raw text)
  if command -v curl >/dev/null 2>&1; then
    country=$(curl -s --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "^loc=" | cut -d= -f2)
  fi

  # API 2: ip.sb/geoip (reliable, JSON grep)
  if [[ ! "$country" =~ ^[A-Z]{2}$ ]]; then
    if command -v curl >/dev/null 2>&1; then
      country=$(curl -s --connect-timeout 5 --max-time 10 https://api.ip.sb/geoip 2>/dev/null | grep -o '"country_code":"[^"]*"' | cut -d'"' -f4)
    fi
  fi

  # API 3: ifconfig.co/country (returns full name, convert to ISO code)
  if [[ ! "$country" =~ ^[A-Z]{2}$ ]]; then
    if command -v curl >/dev/null 2>&1; then
      local fullname=$(curl -s --connect-timeout 5 --max-time 10 https://ifconfig.co/country 2>/dev/null | tr -d '[:space:]')
      case "$fullname" in
        China) country="CN" ;; Singapore) country="SG" ;; "United States") country="US" ;;
        Japan) country="JP" ;; "South Korea") country="KR" ;; Germany) country="DE" ;;
        "United Kingdom") country="GB" ;; France) country="FR" ;; Canada) country="CA" ;;
        Australia) country="AU" ;; India) country="IN" ;; Brazil) country="BR" ;;
        Russia) country="RU" ;; Netherlands) country="NL" ;;
        *) [ -n "$fullname" ] && country="$fullname" ;;
      esac
    fi
  fi

  # API 4: ipinfo.io (may rate limit, last resort)
  if [[ ! "$country" =~ ^[A-Z]{2}$ ]]; then
    if command -v curl >/dev/null 2>&1; then
      country=$(curl -s --connect-timeout 5 --max-time 10 https://ipinfo.io/country 2>/dev/null | grep -oE '^[A-Z]{2}$')
    fi
  fi

  # Validate: exactly 2 uppercase letters
  if [[ "$country" =~ ^[A-Z]{2}$ ]]; then
    echo "$country"
  else
    echo "unknown"
  fi
}

# Test TCP port connectivity
# Usage: conn_port --host HOST --port PORT
# Returns: "true" or "false"
conn_port() {
  local host=""
  local port=""

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) host="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [ -z "$host" ] || [ -z "$port" ] && { echo "false"; return; }

  # Method 1: curl
  if command -v curl >/dev/null 2>&1; then
    if curl -s --connect-timeout 3 --max-time 5 "telnet://${host}:${port}" >/dev/null 2>&1; then
      echo "true"
    else
      echo "false"
    fi
    return
  fi

  # Method 2: nc (netcat)
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w 3 "$host" "$port" 2>/dev/null; then
      echo "true"
    else
      echo "false"
    fi
    return
  fi

  # Method 3: bash /dev/tcp
  if (echo >/dev/tcp/"${host}"/"${port}") 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}
