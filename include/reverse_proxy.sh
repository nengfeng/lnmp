#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
# Core functions for the LNMP reverse proxy manager.
#
# The CLI entry point is reverse_proxy.sh; this file only defines functions so
# it can also be sourced by tools/test_reverse_proxy.sh.

RP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RP_ROOT_DIR="$(cd "${RP_LIB_DIR}/.." && pwd)"

if [ -f "${RP_ROOT_DIR}/include/color.sh" ]; then
  . "${RP_ROOT_DIR}/include/color.sh"
else
  CEND=""; CGREEN=""; CRED=""; CYELLOW=""; CCYAN=""
  CSUCCESS="${CGREEN}"; CFAILURE="${CRED}"; CWARNING="${CYELLOW}"; CMSG="${CCYAN}"
fi

RP_BASE_DIR="/data/lnmp/reverse_proxy"
RP_CONF_DIR="${RP_BASE_DIR}/conf"
RP_LUA_DIR="${RP_BASE_DIR}/lua"
RP_BACKUP_DIR="${RP_BASE_DIR}/backups"
RP_LOG_FILE="${RP_BASE_DIR}/operations.log"
RP_LOCK_FILE="${RP_BASE_DIR}/.lock"

RP_MANAGED_MARK="LNMP reverse proxy managed by reverse_proxy.sh - DO NOT EDIT"
RP_TEMPLATE="${RP_ROOT_DIR}/config/reverse_proxy/nginx.conf.template"
RP_HEADER_LUA="${RP_ROOT_DIR}/config/reverse_proxy/rp_header.lua"
RP_BODY_LUA="${RP_ROOT_DIR}/config/reverse_proxy/rp_body.lua"
RP_REWRITE_LUA="${RP_ROOT_DIR}/config/reverse_proxy/rp_rewrite.lua"

# Populated by rp_init().
web_install_dir=""
nginx_bin=""
PATH_SSL=""
run_user="www"
run_group="www"
RP_PUBLIC_LOG_DIR="/data/wwwlogs"
RP_REWRITE_WATERMARK="1048576"
RP_REWRITE_MAX_BYTES="8388608"
RP_REWRITE_MIN_OVERLAP="64"
RP_ACME_WEBROOT_BASE="/data/wwwroot/acme"

# Populated by rp_lua_probe() when a dynamic module is used.
RP_LUA_MODULE=""

declare -gA RP_META=()

rp_log() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  mkdir -p "${RP_BASE_DIR}" 2>/dev/null || true
  printf '[%s] [%s] %s\n' "${ts}" "${level}" "${msg}" >>"${RP_LOG_FILE}" 2>/dev/null || true
  case "${level}" in
    ERROR) printf '%s\n' "${CFAILURE}[ERROR] ${msg}${CEND}" ;;
    WARN)  printf '%s\n' "${CWARNING}[WARN] ${msg}${CEND}" ;;
    OK)    printf '%s\n' "${CGREEN}[OK] ${msg}${CEND}" ;;
    *)     printf '%s\n' "${CMSG}[${level}] ${msg}${CEND}" ;;
  esac
}

rp_die() {
  rp_log ERROR "$*"
  return 1
}

rp_init() {
  if [ -f "${RP_ROOT_DIR}/options.conf" ]; then
    . "${RP_ROOT_DIR}/options.conf"
  fi
  if [ -f "${RP_ROOT_DIR}/include/check_dir.sh" ]; then
    . "${RP_ROOT_DIR}/include/check_dir.sh"
  fi
  if [ -f "${RP_ROOT_DIR}/include/gh_direct.sh" ]; then
    . "${RP_ROOT_DIR}/include/gh_direct.sh"
  fi
  web_install_dir="${web_install_dir:-${nginx_install_dir:-}}"
  nginx_bin="${web_install_dir}/sbin/nginx"
  PATH_SSL="${web_install_dir}/conf/ssl"
  run_user="${run_user:-www}"
  run_group="${run_group:-www}"
  RP_PUBLIC_LOG_DIR="${wwwlogs_dir:-/data/wwwlogs}"
  RP_ACME_WEBROOT_BASE="${wwwroot_dir:-/data/wwwroot}/acme"

  if [ -z "${web_install_dir}" ] || [ ! -x "${nginx_bin}" ]; then
    rp_die "No installed Nginx/Tengine/OpenResty found (looked for ${nginx_bin})."
    return 1
  fi
  if [ ! -f "${web_install_dir}/conf/nginx.conf" ]; then
    rp_die "Missing ${web_install_dir}/conf/nginx.conf"
    return 1
  fi
  if [ ! -f "${RP_TEMPLATE}" ]; then
    rp_die "Missing reverse proxy template: ${RP_TEMPLATE}"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- validation

rp_validate_domain() {
  local d="$1"
  [ -n "${d}" ] || return 1
  [ "${#d}" -le 253 ] || return 1
  [[ "${d}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# Parse an upstream URL into RP_UPSTREAM_SCHEME/HOST/PORT/PATH.
# Returns non-zero for anything other than http(s)://host[:port]/ .
rp_verify_on() {
  case "$1" in
    1|on|yes|true) return 0 ;;
    *) return 1 ;;
  esac
}

rp_verify_nginx() {
  if rp_verify_on "$1"; then
    printf 'on\n'
  else
    printf 'off\n'
  fi
}

rp_valid_timeout() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# Shell value used for probing / curl (not the nginx config token).
rp_host_header_value() {
  local mode="$1" custom="$2" upstream_host="$3" domain="$4"
  case "${mode}" in
    custom) printf '%s' "${custom}" ;;
    public) printf '%s' "${domain}" ;;
    *) printf '%s' "${upstream_host}" ;;
  esac
}

rp_parse_upstream() {
  local url="$1"
  RP_UPSTREAM_SCHEME=""
  RP_UPSTREAM_HOST=""
  RP_UPSTREAM_PORT=""
  RP_UPSTREAM_PATH=""

  [[ "${url}" =~ ^(https?)://([^/@:?#/]+|\[[0-9A-Fa-f:.]+\])(:([0-9]{1,5}))?(/.*)?$ ]] || return 1
  RP_UPSTREAM_SCHEME="${BASH_REMATCH[1],,}"
  RP_UPSTREAM_HOST="${BASH_REMATCH[2]}"
  local port="${BASH_REMATCH[4]:-}"
  local path="${BASH_REMATCH[5]:-}"

  if [ -n "${port}" ] && [ "${port}" -gt 65535 ]; then
    return 1
  fi
  if [ "${RP_UPSTREAM_SCHEME}" = "http" ]; then
    RP_UPSTREAM_PORT="${port:-80}"
  else
    RP_UPSTREAM_PORT="${port:-443}"
  fi
  RP_UPSTREAM_PATH="${path:-/}"
  [ "${RP_UPSTREAM_PATH}" = "/" ] || return 1

  # Strip brackets around an IPv6 literal.
  if [[ "${RP_UPSTREAM_HOST}" == \[*\] ]]; then
    RP_UPSTREAM_HOST="${RP_UPSTREAM_HOST:1:-1}"
  fi
  RP_UPSTREAM_HOST="${RP_UPSTREAM_HOST,,}"
  return 0
}

rp_upstream_url() {
  local scheme="$1" host="$2" port="$3"
  local display_host="${host}"
  if [[ "${host}" == *:* ]]; then
    display_host="[${host}]"
  fi
  if { [ "${scheme}" = "http" ] && [ "${port}" = "80" ]; } \
     || { [ "${scheme}" = "https" ] && [ "${port}" = "443" ]; }; then
    printf '%s://%s' "${scheme}" "${display_host}"
  else
    printf '%s://%s:%s' "${scheme}" "${display_host}" "${port}"
  fi
}

# ------------------------------------------------------------- address checks

rp_ipv4_private() {
  local ip="$1"
  local o1 o2
  [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 2
  o1=$((10#${BASH_REMATCH[1]}))
  o2=$((10#${BASH_REMATCH[2]}))
  local o3=$((10#${BASH_REMATCH[3]}))
  local o4=$((10#${BASH_REMATCH[4]}))
  (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )) || return 2

  (( o1 == 0 || o1 == 10 || o1 == 127 )) && return 0
  (( o1 == 172 && o2 >= 16 && o2 <= 31 )) && return 0
  (( o1 == 192 && o2 == 168 )) && return 0
  (( o1 == 169 && o2 == 254 )) && return 0
  (( o1 == 100 && o2 >= 64 && o2 <= 127 )) && return 0
  return 1
}

# Fill _RP_IPV6_GROUPS with eight normalized four-digit groups.
rp_ipv6_groups() {
  local addr="${1,,}"
  local last hi lo left right missing g
  local -a lg=() rg=() norm=()
  _RP_IPV6_GROUPS=()

  [[ "${addr}" != *"%"* ]] || return 1
  last="${addr##*:}"
  if [[ "${last}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    local a b c d
    a=$((10#${BASH_REMATCH[1]}))
    b=$((10#${BASH_REMATCH[2]}))
    c=$((10#${BASH_REMATCH[3]}))
    d=$((10#${BASH_REMATCH[4]}))
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
    printf -v hi '%04x' $(( (a << 8) | b ))
    printf -v lo '%04x' $(( (c << 8) | d ))
    addr="${addr%:*}:${hi}:${lo}"
  fi

  if [[ "${addr}" == *"::"* ]]; then
    local stripped="${addr//::/}"
    local SepCount=$(( (${#addr} - ${#stripped}) / 2 ))
    (( SepCount == 1 )) || return 1
    left="${addr%%::*}"
    right="${addr#*::}"
    if [ -n "${left}" ]; then
      IFS=':' read -ra lg <<<"${left}"
    fi
    if [ -n "${right}" ]; then
      IFS=':' read -ra rg <<<"${right}"
    fi
    missing=$(( 8 - ${#lg[@]} - ${#rg[@]} ))
    (( missing >= 1 && missing <= 8 )) || return 1
    _RP_IPV6_GROUPS=("${lg[@]}")
    local i
    for (( i = 0; i < missing; i++ )); do
      _RP_IPV6_GROUPS+=( "0000" )
    done
    _RP_IPV6_GROUPS+=("${rg[@]}")
  else
    IFS=':' read -ra _RP_IPV6_GROUPS <<<"${addr}"
  fi

  (( ${#_RP_IPV6_GROUPS[@]} == 8 )) || return 1
  for g in "${_RP_IPV6_GROUPS[@]}"; do
    [[ "${g}" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    printf -v g '%04x' $((16#${g}))
    norm+=( "${g}" )
  done
  _RP_IPV6_GROUPS=( "${norm[@]}" )
  return 0
}

rp_ipv6_private() {
  rp_ipv6_groups "$1" || return $?
  local -a g=("${_RP_IPV6_GROUPS[@]}")
  local v4

  # IPv4-mapped ::ffff:a.b.c.d
  if [[ "${g[0]}" == 0000 && "${g[1]}" == 0000 && "${g[2]}" == 0000 \
      && "${g[3]}" == 0000 && "${g[4]}" == 0000 && "${g[5]}" == ffff ]]; then
    v4=$(printf '%d.%d.%d.%d' \
      "$((16#${g[6]:0:2}))" "$((16#${g[6]:2:2}))" \
      "$((16#${g[7]:0:2}))" "$((16#${g[7]:2:2}))")
    rp_ipv4_private "${v4}"
    return $?
  fi

  # Unspecified ::
  local all_zero=1
  local x
  for x in "${g[@]}"; do
    [[ "${x}" == 0000 ]] || { all_zero=0; break; }
  done
  (( all_zero )) && return 0

  # IPv4-compatible ::a.b.c.d (deprecated, but keep the bypass closed)
  if [[ "${g[0]}" == 0000 && "${g[1]}" == 0000 && "${g[2]}" == 0000 \
      && "${g[3]}" == 0000 && "${g[4]}" == 0000 && "${g[5]}" == 0000 ]]; then
    v4=$(printf '%d.%d.%d.%d' \
      "$((16#${g[6]:0:2}))" "$((16#${g[6]:2:2}))" \
      "$((16#${g[7]:0:2}))" "$((16#${g[7]:2:2}))")
    rp_ipv4_private "${v4}"
    return $?
  fi

  # Loopback ::1
  if [[ "${g[0]}" == 0000 && "${g[1]}" == 0000 && "${g[2]}" == 0000 \
      && "${g[3]}" == 0000 && "${g[4]}" == 0000 && "${g[5]}" == 0000 \
      && "${g[6]}" == 0000 && "${g[7]}" == 0001 ]]; then
    return 0
  fi

  # ULA fc00::/7
  if (( (16#${g[0]} & 0xfe00) == 0xfc00 )); then
    return 0
  fi

  # Link-local fe80::/10
  if (( (16#${g[0]} & 0xffc0) == 0xfe80 )); then
    return 0
  fi

  return 1
}

rp_address_private() {
  local addr="$1"
  if [[ "${addr}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    rp_ipv4_private "${addr}"
    return $?
  fi
  rp_ipv6_private "${addr}"
  return $?
}

rp_resolve_host() {
  local host="$1"
  local -a out=()
  local line addr

  if [[ "${host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "${host}"
    return 0
  fi
  if [[ "${host}" =~ ^[0-9A-Fa-f:]+$ && "${host}" == *":"* ]]; then
    printf '%s\n' "${host}"
    return 0
  fi

  while IFS= read -r line; do
    addr="${line%%$'\t'*}"
    addr="${addr%% *}"
    if [ -n "${addr}" ]; then out+=( "${addr}" ); fi
  done < <(getent ahostsv4 "${host}" 2>/dev/null)

  while IFS= read -r line; do
    addr="${line%%$'\t'*}"
    addr="${addr%% *}"
    if [ -n "${addr}" ]; then out+=( "${addr}" ); fi
  done < <(getent ahostsv6 "${host}" 2>/dev/null)

  if [ "${#out[@]}" -eq 0 ] && command -v dig >/dev/null 2>&1; then
    while IFS= read -r addr; do
      if [ -n "${addr}" ]; then out+=( "${addr}" ); fi
    done < <(dig +short A "${host}" 2>/dev/null)
    while IFS= read -r addr; do
      if [ -n "${addr}" ]; then out+=( "${addr}" ); fi
    done < <(dig +short AAAA "${host}" 2>/dev/null)
  fi

  if [ "${#out[@]}" -eq 0 ]; then
    return 1
  fi
  printf '%s\n' "${out[@]}"
}

rp_check_ssrf() {
  local host="$1"
  local addrs
  addrs=$(rp_resolve_host "${host}") || return 2
  local addr
  while IFS= read -r addr; do
    [ -n "${addr}" ] || continue
    if rp_address_private "${addr}"; then
      rp_log WARN "upstream resolves to a blocked address: ${addr}"
      return 1
    fi
  done <<<"${addrs}"
  return 0
}

# --------------------------------------------------------------- Lua probing

rp_lua_probe() {
  RP_LUA_MODULE=""
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lnmp-rp-lua.XXXXXX") || return 1
  local conf="${tmp}/nginx.conf"
  local header_lua="${tmp}/rp_probe_header.lua"
  local body_lua="${tmp}/rp_probe_body.lua"
  mkdir -p "${tmp}/client_body" "${tmp}/proxy" "${tmp}/fastcgi" \
    "${tmp}/uwsgi" "${tmp}/scgi"

  printf '%s\n' 'ngx.header.x_rp_probe = "1"' >"${header_lua}"
  printf '%s\n' 'if ngx.arg[2] then ngx.arg[1] = "ok" end' >"${body_lua}"

  local probe_common
  probe_common=$(cat <<EOF
worker_processes 1;
daemon off;
error_log stderr info;
pid ${tmp}/nginx.pid;
events { worker_connections 16; }
http {
  lua_package_path "/usr/local/lib/lua/5.1/?.lua;/usr/local/lib/lua/5.1/?/init.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;;";
  lua_package_cpath "/usr/local/lib/lua/5.1/?.so;;";
  access_log off;
  client_body_temp_path ${tmp}/client_body;
  proxy_temp_path ${tmp}/proxy;
  fastcgi_temp_path ${tmp}/fastcgi;
  uwsgi_temp_path ${tmp}/uwsgi;
  scgi_temp_path ${tmp}/scgi;
  server {
    listen 127.0.0.1:18080;
    server_name rp-probe;
    location /lua {
      header_filter_by_lua_file ${header_lua};
      body_filter_by_lua_file ${body_lua};
      return 200 "ok";
    }
  }
}
EOF
)

  local rc output
  printf '%s\n' "${probe_common}" >"${conf}"
  output=$("${nginx_bin}" -t -p "${tmp}" -c "${conf}" 2>&1) && rc=0 || rc=$?
  if [ "${rc}" -eq 0 ]; then
    rm -rf "${tmp}"
    return 0
  fi

  local -a candidates=()
  local module_path
  module_path=$("${nginx_bin}" -V 2>&1 | sed -n 's/.*--modules-path=\([^ ]*\).*/\1/p' | head -1)
  candidates+=( "${web_install_dir}/modules/ngx_http_lua_module.so" )
  if [ -n "${module_path}" ]; then candidates+=( "${module_path}/ngx_http_lua_module.so" ); fi
  candidates+=( "/usr/lib/nginx/modules/ngx_http_lua_module.so" )
  candidates+=( "/usr/lib64/nginx/modules/ngx_http_lua_module.so" )

  local candidate
  for candidate in "${candidates[@]}"; do
    [ -f "${candidate}" ] || continue
    {
      printf 'load_module "%s";\n' "${candidate}"
      printf '%s\n' "${probe_common}"
    } >"${conf}"
    output=$("${nginx_bin}" -t -p "${tmp}" -c "${conf}" 2>&1) && rc=0 || rc=$?
    if [ "${rc}" -eq 0 ]; then
      RP_LUA_MODULE="${candidate}"
      rm -rf "${tmp}"
      return 0
    fi
  done

  rm -rf "${tmp}"
  if [ -n "${output}" ]; then
    rp_log WARN "Lua capability probe failed: ${output##*$'\n'}"
  fi
  return 1
}

rp_conf_has_lua_load() {
  grep -Rqs "load_module.*ngx_http_lua_module" "${web_install_dir}/conf/" && return 0
  return 1
}

rp_ensure_lua_load_module() {
  [ -n "${RP_LUA_MODULE}" ] || return 0
  rp_conf_has_lua_load && return 0

  local conf="${web_install_dir}/conf/nginx.conf"
  local backup="${RP_BACKUP_DIR}/nginx.conf.$(date +%Y%m%d%H%M%S).$$"
  mkdir -p "${RP_BACKUP_DIR}" || return 1
  cp -a "${conf}" "${backup}" || return 1

  local tmp="${conf}.tmp.$$"
  {
    printf 'load_module "%s";\n' "${RP_LUA_MODULE}"
    cat "${conf}"
  } >"${tmp}" || { rm -f "${tmp}"; return 1; }

  if "${nginx_bin}" -t -p "${web_install_dir}/" -c "${tmp}" >/dev/null 2>&1; then
    mv -f "${tmp}" "${conf}"
    rp_log OK "Loaded dynamic Lua module ${RP_LUA_MODULE}"
    return 0
  fi

  rm -f "${tmp}"
  mv -f "${backup}" "${conf}"
  rp_log ERROR "Could not load ${RP_LUA_MODULE}; restored nginx.conf"
  return 1
}

# ------------------------------------------------------------------ metadata

rp_metadata_file() {
  printf '%s/%s.conf' "${RP_CONF_DIR}" "$1"
}

rp_meta_load() {
  local domain="$1"
  local file
  file=$(rp_metadata_file "${domain}")
  RP_META=()
  [ -f "${file}" ] || return 1
  local line key value
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      ''|\#*) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    RP_META["${key}"]="${value}"
  done <"${file}"
  return 0
}

rp_meta_get() {
  printf '%s' "${RP_META[$1]:-}"
}

RP_META_KEYS=(
  domain upstream_url upstream_scheme upstream_host upstream_port upstream_path
  host_header custom_host rewrite cert_mode email dns_api verify_upstream
  connect_timeout read_timeout created_at updated_at conf_path lua_module
)

rp_meta_save() {
  local domain="$1"
  local file tmp key
  file=$(rp_metadata_file "${domain}")
  mkdir -p "${RP_CONF_DIR}" || return 1
  tmp="${file}.tmp.$$"
  : >"${tmp}" || { rm -f "${tmp}"; return 1; }
  for key in "${RP_META_KEYS[@]}"; do
    printf '%s=%s\n' "${key}" "${RP_META[$key]:-}" >>"${tmp}"
  done
  mv -f "${tmp}" "${file}"
  chmod 600 "${file}"
  return 0
}

rp_backup_file() {
  local src="$1" label="$2"
  local dst keep count
  mkdir -p "${RP_BACKUP_DIR}" || return 1
  dst="${RP_BACKUP_DIR}/${label}.$(date +%Y%m%d%H%M%S).$$.${RANDOM}"
  cp -a "${src}" "${dst}" || return 1

  keep="${RP_BACKUP_KEEP:-10}"
  if [ "${keep}" -gt 0 ] 2>/dev/null; then
    count=$(find "${RP_BACKUP_DIR}" -maxdepth 1 -type f -name "${label}.*" 2>/dev/null | wc -l)
    if [ "${count}" -gt "${keep}" ]; then
      find "${RP_BACKUP_DIR}" -maxdepth 1 -type f -name "${label}.*" \
        -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | head -n $(( count - keep )) \
        | while IFS= read -r line; do
            rm -f "${line#* }"
          done
    fi
  fi

  printf '%s\n' "${dst}"
}

# -------------------------------------------------------------- nginx helpers

rp_nginx_test() {
  local output
  output=$("${nginx_bin}" -t -p "${web_install_dir}/" -c conf/nginx.conf 2>&1)
  local rc=$?
  if [ "${rc}" -ne 0 ]; then
    printf '%s\n' "${output}" >&2
  fi
  return "${rc}"
}

# Resolve the master PID from the effective configuration. Avoid pgrep -f,
# which can match unrelated shell commands that merely contain the binary path.
rp_nginx_pid_file() {
  local out pid
  out=$("${nginx_bin}" -T 2>/dev/null) || return 1
  pid=$(printf '%s\n' "${out}" \
    | sed -n 's/^[[:space:]]*pid[[:space:]]\+\([^;]*\);.*$/\1/p' \
    | head -n 1)
  [ -n "${pid}" ] || return 1
  printf '%s\n' "${pid}"
}

rp_nginx_reload() {
  local output rc pid_file
  output=$("${nginx_bin}" -s reload 2>&1)
  rc=$?
  if [ "${rc}" -ne 0 ]; then
    printf '%s\n' "${output}" >&2
    return 1
  fi
  sleep 0.3
  pid_file=$(rp_nginx_pid_file) || return 0
  [ -s "${pid_file}" ] || return 0
  kill -0 "$(cat "${pid_file}" 2>/dev/null)" 2>/dev/null
}

rp_nginx_supports_http2_on() {
  local ver major minor
  # Official nginx reports "nginx version: nginx/..." while OpenResty reports
  # "nginx version: openresty/...". Accept both so modern OpenResty uses the
  # http2 on; directive instead of the deprecated listen parameter.
  ver=$("${nginx_bin}" -v 2>&1 \
    | sed -n -e 's/.*nginx version: nginx\///p' -e 's/.*nginx version: openresty\///p' \
    | head -n 1)
  ver="${ver%% *}"
  [ -n "${ver}" ] || return 1
  major="${ver%%.*}"
  minor="${ver#*.}"; minor="${minor%%.*}"
  [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ ]] || return 1
  (( major > 1 )) && return 0
  (( major == 1 && minor >= 25 ))
}

# ------------------------------------------------------------ config rendering

rp_proxy_set_lines() {
  local upstream_host="$1" public_host="$2" public_origin="$3"
  cat <<EOF
    set \$rp_upstream_host "${upstream_host}";
    set \$rp_upstream_origin "${4}";
    set \$rp_public_host "${public_host}";
    set \$rp_public_origin "${public_origin}";
    set \$rp_public_scheme "${5}";
    set \$rp_rewrite_module "${RP_LUA_DIR}/rp_rewrite.lua";
    set \$rp_rewrite_watermark "${6}";
    set \$rp_rewrite_max_bytes "${7}";
    set \$rp_rewrite_min_overlap "${8}";
EOF
}

rp_ca_bundle_path() {
  local p
  for p in \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/pki/tls/certs/ca-bundle.crt \
    /etc/ssl/cert.pem; do
    if [ -s "${p}" ]; then
      printf '%s\n' "${p}"
      return 0
    fi
  done
  return 1
}

rp_render_proxy_location() {
  local upstream_url="$1" proxy_host="$2" connect_timeout="$3" read_timeout="$4"
  local verify_upstream="$5" rewrite="$6"
  local extra_ssl="" rewrite_block="" ca_bundle=""

  if [ "${upstream_url#https://}" != "${upstream_url}" ]; then
    if [ "${verify_upstream}" = "on" ]; then
      ca_bundle=$(rp_ca_bundle_path || true)
    fi
    local extra_ca=""
    if [ -n "${ca_bundle}" ]; then
      extra_ca=$(cat <<EOF
        proxy_ssl_trusted_certificate ${ca_bundle};
        proxy_ssl_verify_depth 2;
EOF
)
    fi
    extra_ssl=$(cat <<EOF

        proxy_ssl_server_name on;
        proxy_ssl_name ${7};
        proxy_ssl_verify ${verify_upstream};
${extra_ca}
EOF
)
  fi

  if [ "${rewrite}" = "1" ]; then
    rewrite_block=$(cat <<'EOF'

        proxy_set_header Accept-Encoding "";
        proxy_redirect off;
        header_filter_by_lua_file __RP_HEADER_LUA__;
        body_filter_by_lua_file __RP_BODY_LUA__;
EOF
)
    rewrite_block="${rewrite_block//__RP_HEADER_LUA__/${RP_LUA_DIR}/rp_header.lua}"
    rewrite_block="${rewrite_block//__RP_BODY_LUA__/${RP_LUA_DIR}/rp_body.lua}"
  fi

  cat <<EOF
    location / {
        proxy_pass ${upstream_url};

        proxy_http_version 1.1;
        proxy_set_header Host ${proxy_host};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";

        proxy_connect_timeout ${connect_timeout}s;
        proxy_send_timeout ${read_timeout}s;
        proxy_read_timeout ${read_timeout}s;
${extra_ssl}
        proxy_buffering on;
        proxy_cache off;
${rewrite_block}
    }
EOF
}

rp_render_server80() {
  local domain="$1" cert_mode="$2" upstream_url="$3" proxy_host="$4"
  local connect_timeout="$5" read_timeout="$6" verify_upstream="$7"
  local upstream_host="$8" rewrite="$9" public_scheme="${10:-http}"

  local challenge="" redirect=""
  if [ "${cert_mode}" = "auto" ]; then
    challenge=$(cat <<EOF

    location ^~ /.well-known/acme-challenge/ {
        root ${RP_ACME_WEBROOT_BASE}/${domain};
    }
EOF
)
  fi

  if [ "${cert_mode}" != "none" ]; then
    redirect=$(cat <<EOF

    location / {
        return 301 https://\$host\$request_uri;
    }
EOF
)
  fi

  if [ "${cert_mode}" = "none" ]; then
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    access_log ${RP_PUBLIC_LOG_DIR}/${domain}.proxy.access.log;
    error_log ${RP_PUBLIC_LOG_DIR}/${domain}.proxy.error.log;

$(rp_render_rewrite_sets "${upstream_host}" "${domain}" "${public_scheme}" "${upstream_url}" "${rewrite}")
$(rp_render_proxy_location "${upstream_url}" "${proxy_host}" "${connect_timeout}" "${read_timeout}" "${verify_upstream}" "${rewrite}" "${upstream_host}")
}
EOF
  else
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
${challenge}
${redirect}
}
EOF
  fi
}

rp_render_rewrite_sets() {
  local upstream_host="$1" public_host="$2" public_scheme="$3" upstream_url="$4" rewrite="$5"
  [ "${rewrite}" = "1" ] || return 0
  printf '%s\n' "$(rp_proxy_set_lines "${upstream_host}" "${public_host}" "${public_scheme}://${public_host}" "${upstream_url}" "${public_scheme}" "${RP_REWRITE_WATERMARK}" "${RP_REWRITE_MAX_BYTES}" "${RP_REWRITE_MIN_OVERLAP}")"
}

rp_render_server443() {
  local domain="$1" upstream_url="$2" proxy_host="$3" connect_timeout="$4"
  local read_timeout="$5" verify_upstream="$6" upstream_host="$7" rewrite="$8"

  local listen_lines http2_line stapling=""
  if rp_nginx_supports_http2_on; then
    listen_lines="    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;"
  else
    listen_lines="    listen 443 ssl http2;
    listen [::]:443 ssl http2;"
  fi

  local cert_file="${PATH_SSL}/${domain}.crt"
  if [ -s "${cert_file}" ] && command -v openssl >/dev/null 2>&1; then
    if openssl x509 -in "${cert_file}" -noout -text 2>/dev/null | grep -q "OCSP - URI:"; then
      stapling=$(cat <<EOF2
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate ${cert_file};
    resolver 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 valid=300s;
    resolver_timeout 5s;
EOF2
)
    fi
  fi

  cat <<EOF
server {
${listen_lines}
    server_name ${domain};

    ssl_certificate ${PATH_SSL}/${domain}.crt;
    ssl_certificate_key ${PATH_SSL}/${domain}.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve X25519:prime256v1:secp384r1:secp521r1;
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers on;
    ssl_session_timeout 10m;
    ssl_session_cache shared:SSL:10m;
    ssl_buffer_size 2k;
${stapling}
    access_log ${RP_PUBLIC_LOG_DIR}/${domain}.proxy.access.log;
    error_log ${RP_PUBLIC_LOG_DIR}/${domain}.proxy.error.log;

$(rp_render_rewrite_sets "${upstream_host}" "${domain}" "https" "${upstream_url}" "${rewrite}")
$(rp_render_proxy_location "${upstream_url}" "${proxy_host}" "${connect_timeout}" "${read_timeout}" "${verify_upstream}" "${rewrite}" "${upstream_host}")
}
EOF
}

rp_render_conf() {
  local domain="$1" cert_mode="$2" upstream_url="$3" proxy_host="$4"
  local connect_timeout="$5" read_timeout="$6" verify_upstream="$7"
  local upstream_host="$8" rewrite="${9:-1}"

  local server80="" server443="" conf
  local public_scheme="https"
  if [ "${cert_mode}" = "none" ]; then public_scheme="http"; fi
  server80=$(rp_render_server80 "${domain}" "${cert_mode}" "${upstream_url}" "${proxy_host}" "${connect_timeout}" "${read_timeout}" "${verify_upstream}" "${upstream_host}" "${rewrite}" "${public_scheme}")
  if [ "${cert_mode}" != "none" ]; then
    server443=$(rp_render_server443 "${domain}" "${upstream_url}" "${proxy_host}" "${connect_timeout}" "${read_timeout}" "${verify_upstream}" "${upstream_host}" "${rewrite}")
  fi

  conf=$(cat "${RP_TEMPLATE}")
  conf="${conf//__MANAGED_MARK__/${RP_MANAGED_MARK}}"
  conf="${conf//__SERVER80__/${server80}}"
  conf="${conf//__SERVER443__/${server443}}"
  printf '%s\n' "${conf}"
}

# ---------------------------------------------------------------- certificate

rp_cert_paths() {
  RP_CERT_FILE="${PATH_SSL}/$1.crt"
  RP_CERT_KEY="${PATH_SSL}/$1.key"
}

rp_cert_exists() {
  rp_cert_paths "$1"
  [ -s "${RP_CERT_FILE}" ] && [ -s "${RP_CERT_KEY}" ]
}

rp_cert_needs_renew() {
  rp_cert_paths "$1"
  [ -s "${RP_CERT_FILE}" ] || return 0
  [ -s "${RP_CERT_KEY}" ] || return 0
  command -v openssl >/dev/null 2>&1 || return 1
  ! openssl x509 -in "${RP_CERT_FILE}" -noout -checkend $(( 30 * 86400 )) >/dev/null 2>&1
}

rp_acme_bin() {
  printf '%s/.acme.sh/acme.sh' "${HOME}"
}

rp_acme_install() {
  local acme
  acme=$(rp_acme_bin)
  if [ -x "${acme}" ]; then return 0; fi

  command -v curl >/dev/null 2>&1 || { rp_die "curl is required to install acme.sh"; return 1; }
  mkdir -p "${RP_ROOT_DIR}/src" || return 1
  local tarball="${RP_ROOT_DIR}/src/acme.sh-master.tar.gz"
  local url="https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"
  local clurl
  clurl=$(github_codeload_url "${url}" 2>/dev/null || true)
  [ -n "${clurl}" ] || clurl="${url}"
  if ! curl -fsSL --connect-timeout 10 -m 300 -o "${tarball}" "${clurl}"; then
    rm -f "${tarball}"
    rp_die "Failed to download acme.sh; install it manually to ${HOME}/.acme.sh/"
    return 1
  fi
  local tmp
  tmp=$(mktemp -d) || return 1
  tar -xzf "${tarball}" -C "${tmp}" || { rm -rf "${tmp}"; return 1; }
  (
    cd "${tmp}/acme.sh-master" && ./acme.sh --install >/dev/null 2>&1
  )
  rm -rf "${tmp}"
  [ -x "$(rp_acme_bin)" ] || { rp_die "acme.sh installation did not produce $(rp_acme_bin)"; return 1; }
}

rp_cert_issue_auto() {
  local domain="$1" email="$2" dns_api="$3"
  local acme webroot
  acme=$(rp_acme_bin)
  rp_acme_install || return 1
  webroot="${RP_ACME_WEBROOT_BASE}/${domain}"
  mkdir -p "${webroot}" || return 1
  chmod 755 "${webroot}" 2>/dev/null || true

  local conf="${web_install_dir}/conf/vhost/${domain}.conf"
  local had_conf=0 conf_backup="" wrote_bootstrap=0

  # DNS-01 does not need a challenge vhost. In that mode the existing vhost
  # must stay untouched until the caller renders the final configuration.
  if [ -z "${dns_api}" ]; then
    if [ -f "${conf}" ]; then
      had_conf=1
      conf_backup=$(rp_backup_file "${conf}" "${domain}.acme-bootstrap") || return 1
    fi

    cat >"${conf}.tmp.$$" <<EOF
# ${RP_MANAGED_MARK} (ACME bootstrap)
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    mv -f "${conf}.tmp.$$" "${conf}"
    wrote_bootstrap=1

    if ! rp_nginx_test; then
      rm -f "${conf}"
      if [ "${had_conf}" = "1" ]; then mv -f "${conf_backup}" "${conf}"; fi
      return 1
    fi
    if ! rp_nginx_reload; then
      rm -f "${conf}"
      if [ "${had_conf}" = "1" ]; then
        mv -f "${conf_backup}" "${conf}"
        rp_nginx_reload || true
      fi
      return 1
    fi
  fi

  local args=( --force --issue -d "${domain}" -w "${webroot}" )
  if [ -n "${email}" ]; then args+=( --accountemail "${email}" ); fi
  if [ -n "${dns_api}" ]; then args=( --force --issue --dns "${dns_api}" -d "${domain}" ); fi

  if ! "${acme}" "${args[@]}" >/dev/null 2>&1; then
    if [ "${wrote_bootstrap}" = "1" ]; then
      rm -f "${conf}"
      if [ "${had_conf}" = "1" ]; then
        mv -f "${conf_backup}" "${conf}"
        rp_nginx_reload || true
      fi
    fi
    rp_die "acme.sh issuance failed for ${domain}"
    return 1
  fi

  mkdir -p "${PATH_SSL}" || return 1
  if ! "${acme}" --install-cert -d "${domain}" \
    --fullchain-file "${PATH_SSL}/${domain}.crt" \
    --key-file "${PATH_SSL}/${domain}.key" \
    --reloadcmd "${nginx_bin} -s reload" >/dev/null 2>&1; then
    rm -f "${PATH_SSL}/${domain}.crt" "${PATH_SSL}/${domain}.key"
    if [ "${wrote_bootstrap}" = "1" ]; then
      rm -f "${conf}"
      if [ "${had_conf}" = "1" ]; then
        mv -f "${conf_backup}" "${conf}"
        rp_nginx_reload || true
      fi
    fi
    rp_die "acme.sh install-cert failed for ${domain}"
    return 1
  fi

  # HTTP-01 only: remove the bootstrap so the caller can write the final vhost.
  if [ "${wrote_bootstrap}" = "1" ]; then
    rm -f "${conf}"
  fi
  return 0
}

rp_cert_custom() {
  local domain="$1" cert_file="$2" key_file="$3"
  [ -s "${cert_file}" ] || { rp_die "Certificate file not found: ${cert_file}"; return 1; }
  [ -s "${key_file}" ] || { rp_die "Private key file not found: ${key_file}"; return 1; }
  mkdir -p "${PATH_SSL}" || return 1
  local crt="${PATH_SSL}/${domain}.crt" key="${PATH_SSL}/${domain}.key"
  local backup
  if [ -s "${crt}" ]; then
    backup=$(rp_backup_file "${crt}" "${domain}.crt") || return 1
  fi
  cp -f "${cert_file}" "${crt}" || return 1
  cp -f "${key_file}" "${key}" || return 1
  chmod 600 "${key}"
  if ! openssl x509 -in "${crt}" -noout >/dev/null 2>&1; then
    if [ -n "${backup}" ]; then mv -f "${backup}" "${crt}"; fi
    rm -f "${key}"
    rp_die "Invalid certificate: ${cert_file}"
    return 1
  fi
  if ! openssl pkey -in "${key}" -noout >/dev/null 2>&1; then
    if [ -n "${backup}" ]; then mv -f "${backup}" "${crt}"; fi
    rm -f "${key}"
    rp_die "Invalid private key: ${key_file}"
    return 1
  fi
  # Compare public-key material, not just RSA modulus: ECDSA and Ed25519 keys
  # have no modulus and would otherwise skip the match check entirely.
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "${crt}" -noout -pubkey 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl md5 2>/dev/null) || true
  key_pub=$(openssl pkey -in "${key}" -pubout -outform DER 2>/dev/null \
    | openssl md5 2>/dev/null) || true
  if [ -z "${cert_pub}" ] || [ -z "${key_pub}" ]; then
    if [ -n "${backup}" ]; then mv -f "${backup}" "${crt}"; fi
    rm -f "${key}"
    rp_die "Unable to derive public key from certificate or private key"
    return 1
  fi
  if [ "${cert_pub}" != "${key_pub}" ]; then
    if [ -n "${backup}" ]; then mv -f "${backup}" "${crt}"; fi
    rm -f "${key}"
    rp_die "Certificate and private key do not match"
    return 1
  fi
  return 0
}

rp_remove_cert() {
  local domain="$1"
  rm -f "${PATH_SSL}/${domain}.crt" "${PATH_SSL}/${domain}.key" 2>/dev/null || true
  local acme
  acme=$(rp_acme_bin)
  if [ -x "${acme}" ]; then
    "${acme}" --remove -d "${domain}" >/dev/null 2>&1 || true
  fi
}

# ------------------------------------------------------------- vhost file I/O

rp_vhost_path() {
  printf '%s/conf/vhost/%s.conf' "${web_install_dir}" "$1"
}

rp_install_lua_files() {
  mkdir -p "${RP_LUA_DIR}" || return 1
  cp -f "${RP_HEADER_LUA}" "${RP_LUA_DIR}/rp_header.lua" || return 1
  cp -f "${RP_BODY_LUA}" "${RP_LUA_DIR}/rp_body.lua" || return 1
  cp -f "${RP_REWRITE_LUA}" "${RP_LUA_DIR}/rp_rewrite.lua" || return 1
  chmod 644 "${RP_LUA_DIR}/rp_header.lua" "${RP_LUA_DIR}/rp_body.lua" "${RP_LUA_DIR}/rp_rewrite.lua"
  return 0
}

rp_write_vhost_raw() {
  local domain="$1" cert_mode="$2" upstream_url="$3" proxy_host="$4"
  local connect_timeout="$5" read_timeout="$6" verify_upstream="$7"
  local upstream_host="$8" rewrite="$9" extra_webroot="${10:-}"
  local conf tmp
  conf=$(rp_vhost_path "${domain}")
  mkdir -p "${web_install_dir}/conf/vhost" "${RP_PUBLIC_LOG_DIR}" || return 1
  tmp="${conf}.tmp.$$"
  rp_render_conf "${domain}" "${cert_mode}" "${upstream_url}" "${proxy_host}" \
    "${connect_timeout}" "${read_timeout}" "${verify_upstream}" \
    "${upstream_host}" "${rewrite}" >"${tmp}" || { rm -f "${tmp}"; return 1; }
  mv -f "${tmp}" "${conf}"
  return 0
}

rp_managed_vhost() {
  local domain="$1"
  local conf
  conf=$(rp_vhost_path "${domain}")
  [ -f "${conf}" ] || return 1
  grep -qF "${RP_MANAGED_MARK}" "${conf}"
}

rp_remove_vhost() {
  local domain="$1"
  local conf backup
  conf=$(rp_vhost_path "${domain}")
  if [ -f "${conf}" ]; then
    if rp_managed_vhost "${domain}" || [ "${RP_FORCE:-0}" = "1" ]; then
      backup=$(rp_backup_file "${conf}" "${domain}.conf") || true
      rm -f "${conf}"
    else
      rp_die "Refusing to overwrite unmanaged vhost ${conf}"
      return 1
    fi
  fi
  return 0
}

# ------------------------------------------------------------------- commands

rp_resolve_proxy_host() {
  local mode="$1" custom="$2" upstream_host="$3"
  case "${mode}" in
    upstream) printf '%s' "${upstream_host}" ;;
    public)   printf '$host' ;;
    custom)   printf '%s' "${custom}" ;;
    *) printf '%s' "${upstream_host}" ;;
  esac
}

rp_save_meta_from_env() {
  local domain="$1"
  RP_META["domain"]="${domain}"
  RP_META["upstream_url"]="${RP_UPSTREAM_URL}"
  RP_META["upstream_scheme"]="${RP_UPSTREAM_SCHEME}"
  RP_META["upstream_host"]="${RP_UPSTREAM_HOST}"
  RP_META["upstream_port"]="${RP_UPSTREAM_PORT}"
  RP_META["upstream_path"]="${RP_UPSTREAM_PATH}"
  RP_META["host_header"]="${RP_HOST_HEADER_MODE}"
  RP_META["custom_host"]="${RP_CUSTOM_HOST:-}"
  RP_META["rewrite"]="${RP_REWRITE}"
  RP_META["cert_mode"]="${RP_CERT_MODE}"
  RP_META["email"]="${RP_EMAIL:-}"
  RP_META["dns_api"]="${RP_DNS_API:-}"
  RP_META["verify_upstream"]="${RP_VERIFY_UPSTREAM}"
  RP_META["connect_timeout"]="${RP_CONNECT_TIMEOUT}"
  RP_META["read_timeout"]="${RP_READ_TIMEOUT}"
  RP_META["created_at"]="${RP_CREATED_AT:-$(date '+%Y-%m-%d %H:%M:%S')}"
  RP_META["updated_at"]="$(date '+%Y-%m-%d %H:%M:%S')"
  RP_META["conf_path"]="$(rp_vhost_path "${domain}")"
  RP_META["lua_module"]="${RP_LUA_MODULE:-}"
  rp_meta_save "${domain}"
}

rp_command_add() {
  local domain="$1" upstream="$2" host_header_mode="$3" custom_host="$4"
  local rewrite="$5" cert_mode="$6" email="$7" dns_api="$8" verify="$9"
  local connect_timeout="${10}" read_timeout="${11}" force="${12}"
  local skip_check="${13}" allow_private="${14}"
  local cert_file="${15}" key_file="${16}"

  rp_validate_domain "${domain}" || { rp_die "Invalid domain: ${domain}"; return 1; }
  rp_parse_upstream "${upstream}" || { rp_die "Invalid upstream URL: ${upstream}"; return 1; }

  RP_CUSTOM_HOST="${custom_host:-}"
  case "${host_header_mode}" in
    upstream|public|custom) ;;
    *) rp_die "Invalid --host-header mode: ${host_header_mode}"; return 1 ;;
  esac
  if [ "${host_header_mode}" = "custom" ]; then
    rp_validate_domain "${RP_CUSTOM_HOST}" || { rp_die "Invalid custom Host header"; return 1; }
  fi
  case "${cert_mode}" in auto|custom|none) ;; *) rp_die "Invalid cert mode: ${cert_mode}"; return 1 ;; esac
  case "${rewrite}" in 0|1) ;; *) rp_die "rewrite must be 0 or 1"; return 1 ;; esac
  rp_valid_timeout "${connect_timeout}" && rp_valid_timeout "${read_timeout}" \
    || { rp_die "Invalid timeout (must be a positive integer)"; return 1; }

  local existing
  existing=$(rp_metadata_file "${domain}")
  if [ -f "${existing}" ]; then
    rp_die "Reverse proxy for ${domain} already exists; use update"
    return 1
  fi

  local conf
  conf=$(rp_vhost_path "${domain}")
  if [ -f "${conf}" ]; then
    if [ "${force}" != "1" ]; then
      rp_die "Vhost ${conf} already exists (use --force to replace a managed/unmanaged vhost)"
      return 1
    fi
    rp_remove_vhost "${domain}" || return 1
  fi

  if [ "${allow_private}" != "1" ]; then
    rp_check_ssrf "${RP_UPSTREAM_HOST}" || {
      rp_die "Upstream host ${RP_UPSTREAM_HOST} resolves to a blocked private/unspecified address"
      return 1
    }
  fi

  if [ "${skip_check}" != "1" ]; then
    local probe_host curl_args
    probe_host=$(rp_host_header_value "${host_header_mode}" "${RP_CUSTOM_HOST}" "${RP_UPSTREAM_HOST}" "${domain}")
    curl_args=( -fsS --connect-timeout 10 -m 20 -H "Host: ${probe_host}" )
    rp_verify_on "${verify}" || curl_args+=( -k )
    if ! curl "${curl_args[@]}" "${upstream}" >/dev/null 2>&1; then
      rp_die "Upstream connectivity check failed for ${upstream} (Host: ${probe_host}); use --skip-upstream-check to override"
      return 1
    fi
  fi

  if [ "${rewrite}" = "1" ]; then
    rp_lua_probe || { rp_die "rewrite requires a usable lua-nginx-module; use --no-rewrite or install/load it"; return 1; }
    rp_ensure_lua_load_module || return 1
  fi

  rp_install_lua_files || return 1

  case "${cert_mode}" in
    auto)
      if [ -z "${email}" ] && [ ! -t 0 ]; then
        rp_die "Non-interactive --cert auto requires --email"
        return 1
      fi
      rp_cert_issue_auto "${domain}" "${email}" "${dns_api}" || return 1
      ;;
    custom)
      [ -n "${cert_file}" ] && [ -n "${key_file}" ] || { rp_die "--cert-file and --key-file are required for custom certificates"; return 1; }
      rp_cert_custom "${domain}" "${cert_file}" "${key_file}" || return 1
      ;;
  esac

  RP_UPSTREAM_URL=$(rp_upstream_url "${RP_UPSTREAM_SCHEME}" "${RP_UPSTREAM_HOST}" "${RP_UPSTREAM_PORT}")
  RP_EMAIL="${email}"
  RP_DNS_API="${dns_api}"
  local proxy_host
  proxy_host=$(rp_resolve_proxy_host "${host_header_mode}" "${RP_CUSTOM_HOST}" "${RP_UPSTREAM_HOST}")

  rp_write_vhost_raw "${domain}" "${cert_mode}" "${RP_UPSTREAM_URL}" "${proxy_host}" \
    "${connect_timeout}" "${read_timeout}" "$(rp_verify_nginx "${verify}")" \
    "${RP_UPSTREAM_HOST}" "${rewrite}" || return 1

  if ! rp_nginx_test; then
    rm -f "${conf}"
    rp_nginx_test || rp_nginx_reload || true
    rp_die "Generated configuration failed nginx -t; vhost removed"
    return 1
  fi
  rp_nginx_reload || { rm -f "${conf}"; rp_nginx_test || true; return 1; }

  rp_save_meta_from_env "${domain}"
  rp_log OK "Added reverse proxy ${domain} -> ${upstream}"
  return 0
}

rp_command_update() {
  local domain="$1" upstream="$2" host_header_mode="$3" custom_host="$4"
  local rewrite="$5" cert_mode="$6" email="$7" dns_api="$8" verify="$9"
  local connect_timeout="${10}" read_timeout="${11}" force="${12}"
  local skip_check="${13}" allow_private="${14}"
  local cert_file="${15}" key_file="${16}"

  rp_validate_domain "${domain}" || { rp_die "Invalid domain: ${domain}"; return 1; }
  rp_meta_load "${domain}" || { rp_die "No reverse proxy metadata for ${domain}"; return 1; }
  local old_url old_scheme old_host old_port
  old_url=$(rp_meta_get upstream_url)
  old_scheme=$(rp_meta_get upstream_scheme)
  old_host=$(rp_meta_get upstream_host)
  old_port=$(rp_meta_get upstream_port)

  if [ -n "${upstream}" ]; then
    rp_parse_upstream "${upstream}" || { rp_die "Invalid upstream URL: ${upstream}"; return 1; }
    RP_UPSTREAM_URL=$(rp_upstream_url "${RP_UPSTREAM_SCHEME}" "${RP_UPSTREAM_HOST}" "${RP_UPSTREAM_PORT}")
  else
    rp_parse_upstream "${old_url}" || return 1
    RP_UPSTREAM_URL="${old_url}"
  fi

  [ -n "${host_header_mode}" ] || host_header_mode=$(rp_meta_get host_header)
  case "${host_header_mode}" in
    upstream|public|custom) ;;
    *) rp_die "Invalid --host-header mode: ${host_header_mode}"; return 1 ;;
  esac
  RP_CUSTOM_HOST="${custom_host:-}"
  if [ "${host_header_mode}" = "custom" ]; then
    [ -n "${RP_CUSTOM_HOST}" ] || RP_CUSTOM_HOST=$(rp_meta_get custom_host)
    rp_validate_domain "${RP_CUSTOM_HOST}" || { rp_die "Invalid custom Host header"; return 1; }
  fi
  [ -n "${rewrite}" ] || rewrite=$(rp_meta_get rewrite)
  [ -n "${cert_mode}" ] || cert_mode=$(rp_meta_get cert_mode)
  [ -n "${email}" ] || email=$(rp_meta_get email)
  [ -n "${dns_api}" ] || dns_api=$(rp_meta_get dns_api)
  [ -n "${verify}" ] || verify=$(rp_meta_get verify_upstream)
  [ -n "${connect_timeout}" ] || connect_timeout=$(rp_meta_get connect_timeout)
  [ -n "${read_timeout}" ] || read_timeout=$(rp_meta_get read_timeout)

  case "${cert_mode}" in auto|custom|none) ;; *) rp_die "Invalid cert mode: ${cert_mode}"; return 1 ;; esac
  case "${rewrite}" in 0|1) ;; *) rp_die "rewrite must be 0 or 1"; return 1 ;; esac
  rp_valid_timeout "${connect_timeout}" && rp_valid_timeout "${read_timeout}" \
    || { rp_die "Invalid timeout (must be a positive integer)"; return 1; }

  if [ "${allow_private}" != "1" ]; then
    rp_check_ssrf "${RP_UPSTREAM_HOST}" || { rp_die "Upstream host ${RP_UPSTREAM_HOST} resolves to a blocked address"; return 1; }
  fi

  if [ "${skip_check}" != "1" ]; then
    local probe_host curl_args
    probe_host=$(rp_host_header_value "${host_header_mode}" "${RP_CUSTOM_HOST}" "${RP_UPSTREAM_HOST}" "${domain}")
    curl_args=( -fsS --connect-timeout 10 -m 20 -H "Host: ${probe_host}" )
    rp_verify_on "${verify}" || curl_args+=( -k )
    if ! curl "${curl_args[@]}" "${RP_UPSTREAM_URL}" >/dev/null 2>&1; then
      rp_die "Upstream connectivity check failed for ${RP_UPSTREAM_URL} (Host: ${probe_host}); use --skip-upstream-check to override"
      return 1
    fi
  fi

  if [ "${rewrite}" = "1" ]; then
    rp_lua_probe || { rp_die "rewrite requires a usable lua-nginx-module; use --no-rewrite or install/load it"; return 1; }
    rp_ensure_lua_load_module || return 1
  fi
  rp_install_lua_files || return 1

  case "${cert_mode}" in
    auto)
      if ! rp_cert_exists "${domain}" || rp_cert_needs_renew "${domain}"; then
        if [ -z "${email}" ] && [ ! -t 0 ]; then
          rp_die "Non-interactive --cert auto requires --email"
          return 1
        fi
        rp_cert_issue_auto "${domain}" "${email}" "${dns_api}" || return 1
      fi
      ;;
    custom)
      [ -n "${cert_file}" ] && [ -n "${key_file}" ] || { rp_die "--cert-file and --key-file are required for custom certificates"; return 1; }
      rp_cert_custom "${domain}" "${cert_file}" "${key_file}" || return 1
      ;;
  esac

  local proxy_host
  proxy_host=$(rp_resolve_proxy_host "${host_header_mode}" "${RP_CUSTOM_HOST}" "${RP_UPSTREAM_HOST}")
  rp_write_vhost_raw "${domain}" "${cert_mode}" "${RP_UPSTREAM_URL}" "${proxy_host}" \
    "${connect_timeout}" "${read_timeout}" "$(rp_verify_nginx "${verify}")" \
    "${RP_UPSTREAM_HOST}" "${rewrite}" || return 1

  if ! rp_nginx_test; then
    local old_custom_host
    old_custom_host=$(rp_meta_get custom_host)
    rp_write_vhost_raw "${domain}" "$(rp_meta_get cert_mode)" "${old_url}" \
      "$(rp_resolve_proxy_host "$(rp_meta_get host_header)" "${old_custom_host}" "${old_host}")" \
      "$(rp_meta_get connect_timeout)" "$(rp_meta_get read_timeout)" \
      "$(rp_verify_nginx "$(rp_meta_get verify_upstream)")" "${old_host}" "$(rp_meta_get rewrite)" || true
    rp_nginx_test || true
    rp_die "Updated configuration failed nginx -t; previous configuration restored"
    return 1
  fi
  rp_nginx_reload || return 1

  RP_HOST_HEADER_MODE="${host_header_mode}"
  RP_CUSTOM_HOST="${RP_CUSTOM_HOST}"
  RP_REWRITE="${rewrite}"
  RP_CERT_MODE="${cert_mode}"
  RP_EMAIL="${email}"
  RP_DNS_API="${dns_api}"
  RP_VERIFY_UPSTREAM="${verify}"
  RP_CONNECT_TIMEOUT="${connect_timeout}"
  RP_READ_TIMEOUT="${read_timeout}"
  RP_CREATED_AT=$(rp_meta_get created_at)
  rp_save_meta_from_env "${domain}"
  rp_log OK "Updated reverse proxy ${domain} -> ${RP_UPSTREAM_URL}"
  return 0
}

rp_command_delete() {
  local domain="$1" purge_cert="$2"
  rp_validate_domain "${domain}" || { rp_die "Invalid domain: ${domain}"; return 1; }
  rp_meta_load "${domain}" || { rp_die "No reverse proxy metadata for ${domain}"; return 1; }
  local conf
  conf=$(rp_vhost_path "${domain}")
  if [ -f "${conf}" ]; then
    if ! rp_managed_vhost "${domain}"; then
      rp_die "Refusing to delete unmanaged vhost ${conf}"
      return 1
    fi
    rp_backup_file "${conf}" "${domain}.conf" >/dev/null || true
    rm -f "${conf}"
  fi
  rm -f "$(rp_metadata_file "${domain}")"
  if [ "${purge_cert}" = "1" ]; then rp_remove_cert "${domain}"; fi
  rp_nginx_test || true
  rp_nginx_reload || return 1
  rp_log OK "Deleted reverse proxy ${domain}"
  return 0
}

rp_command_list() {
  local file domain
  [ -d "${RP_CONF_DIR}" ] || return 0
  for file in "${RP_CONF_DIR}"/*.conf; do
    [ -f "${file}" ] || continue
    rp_meta_load "$(basename "${file}" .conf)" || continue
    domain=$(rp_meta_get domain)
    printf '%-32s %-42s rewrite=%s cert=%s updated=%s\n' \
      "${domain}" "$(rp_meta_get upstream_url)" "$(rp_meta_get rewrite)" \
      "$(rp_meta_get cert_mode)" "$(rp_meta_get updated_at)"
  done
}

rp_command_show() {
  local domain="$1"
  rp_validate_domain "${domain}" || { rp_die "Invalid domain: ${domain}"; return 1; }
  rp_meta_load "${domain}" || { rp_die "No reverse proxy metadata for ${domain}"; return 1; }
  local key file
  echo "== metadata =="
  for key in "${RP_META_KEYS[@]}"; do
    printf '%s=%s\n' "${key}" "${RP_META[$key]:-}"
  done
  file=$(rp_vhost_path "${domain}")
  if [ -f "${file}" ]; then
    echo
    echo "== vhost =="
    cat "${file}"
  fi
  if rp_cert_exists "${domain}"; then
    echo
    echo "== certificate =="
    openssl x509 -in "${RP_CERT_FILE}" -noout -subject -enddate 2>/dev/null || true
  fi
  return 0
}

rp_command_test() {
  local domain="$1"
  rp_validate_domain "${domain}" || { rp_die "Invalid domain: ${domain}"; return 1; }
  rp_meta_load "${domain}" || { rp_die "No reverse proxy metadata for ${domain}"; return 1; }
  local cert_mode upstream_host
  cert_mode=$(rp_meta_get cert_mode)
  upstream_host=$(rp_meta_get upstream_host)
  rp_nginx_test || return 1
  local url scheme port curl_args
  if [ "${cert_mode}" = "none" ]; then
    scheme="http"; port=80; url="http://${domain}/"
  else
    scheme="https"; port=443; url="https://${domain}/"
  fi
  curl_args=( -k -sS --max-time 20 --resolve "${domain}:${port}:127.0.0.1" )
  local headers body
  headers=$(mktemp) || return 1
  body=$(mktemp) || { rm -f "${headers}"; return 1; }
  local rc=0
  curl "${curl_args[@]}" -D "${headers}" -o "${body}" "${url}" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    rp_log WARN "Local request through ${scheme} failed (rc=${rc})"
  else
    echo "HTTP response stored in ${body}; headers in ${headers}"
    if grep -qi "${upstream_host}" "${headers}" "${body}" 2>/dev/null; then
      rp_log WARN "Upstream host ${upstream_host} still appears in headers/body (L2 rewrite may be incomplete)"
    else
      rp_log OK "No upstream host string found in headers/body"
    fi
  fi
  rm -f "${headers}" "${body}"
  return "${rc}"
}