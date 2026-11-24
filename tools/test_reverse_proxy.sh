#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Offline unit tests for the reverse proxy manager.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1094
. "${ROOT_DIR}/include/reverse_proxy.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lnmp-rp-test.XXXXXX")
trap 'rm -rf "${TMP_DIR}"' EXIT

RP_CONF_DIR="${TMP_DIR}/meta"
RP_BACKUP_DIR="${TMP_DIR}/backup"
RP_LOG_FILE="${TMP_DIR}/operations.log"
RP_LUA_DIR="${TMP_DIR}/lua"
RP_PUBLIC_LOG_DIR="${TMP_DIR}/logs"
web_install_dir="${TMP_DIR}/nginx"
nginx_bin="${TMP_DIR}/nginx/sbin/nginx"
PATH_SSL="${web_install_dir}/conf/ssl"
mkdir -p "${RP_CONF_DIR}" "${RP_BACKUP_DIR}" "${RP_LUA_DIR}" "${RP_PUBLIC_LOG_DIR}"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
ko() { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (expected [$3], got [$2])"; fi
}
assert_rc() {
  local want="$1" got="$2" what="$3"
  if [ "${want}" = "${got}" ]; then ok "${what}"; else ko "${what} (rc ${got}, want ${want})"; fi
}

echo "== domain / upstream parsing =="
rp_validate_domain a.example && ok "valid domain accepted" || ko "valid domain rejected"
rp_validate_domain a.b.example && ok "multi-label domain accepted" || ko "multi-label domain rejected"
rp_validate_domain -bad.example && ko "leading hyphen accepted" || ok "leading hyphen rejected"
rp_validate_domain bad_example.com && ko "underscore accepted" || ok "underscore rejected"
rp_validate_domain a && ko "single label accepted" || ok "single label rejected"

if rp_parse_upstream https://b.example.com:8443/; then
  assert_eq "upstream scheme" "${RP_UPSTREAM_SCHEME}" "https"
  assert_eq "upstream host" "${RP_UPSTREAM_HOST}" "b.example.com"
  assert_eq "upstream port" "${RP_UPSTREAM_PORT}" "8443"
  assert_eq "upstream path" "${RP_UPSTREAM_PATH}" "/"
else
  ko "valid upstream rejected"
fi
rp_parse_upstream http://b.example.com && [ "${RP_UPSTREAM_PORT}" = "80" ] \
  && ok "http default port" || ko "http default port"
rp_parse_upstream https://user@b.example.com/ && ko "userinfo accepted" || ok "userinfo rejected"
rp_parse_upstream https://b.example.com/sub && ko "subpath accepted" || ok "subpath rejected"
rp_parse_upstream https://b.example.com/?q=1 && ko "query accepted" || ok "query rejected"
rp_parse_upstream ftp://b.example.com/ && ko "ftp accepted" || ok "ftp rejected"
if rp_parse_upstream 'http://[::1]:8080/'; then
  [ "${RP_UPSTREAM_HOST}" = "::1" ] && [ "${RP_UPSTREAM_PORT}" = "8080" ] \
    && ok "IPv6 literal parsed" || ko "IPv6 literal parse fields"
  [ "$(rp_upstream_url "${RP_UPSTREAM_SCHEME}" "${RP_UPSTREAM_HOST}" "${RP_UPSTREAM_PORT}")" = "http://[::1]:8080" ] \
    && ok "IPv6 URL keeps brackets" || ko "IPv6 URL lost brackets"
fi
if rp_parse_upstream https://b.example/; then
  [ "$(rp_upstream_url "${RP_UPSTREAM_SCHEME}" "${RP_UPSTREAM_HOST}" "${RP_UPSTREAM_PORT}")" = "https://b.example" ] \
    && ok "default HTTPS port omitted" || ko "default HTTPS port not omitted"
else
  ko "default HTTPS upstream rejected"
fi
if rp_parse_upstream http://b.example/; then
  [ "$(rp_upstream_url "${RP_UPSTREAM_SCHEME}" "${RP_UPSTREAM_HOST}" "${RP_UPSTREAM_PORT}")" = "http://b.example" ] \
    && ok "default HTTP port omitted" || ko "default HTTP port not omitted"
else
  ko "default HTTP upstream rejected"
fi

echo "== address classification =="
for a in 127.0.0.1 10.1.2.3 172.16.0.1 172.31.255.255 192.168.1.1 169.254.1.1 100.64.0.1 0.0.0.0; do
  if rp_address_private "${a}"; then ok "IPv4 ${a} blocked"; else ko "IPv4 ${a} not blocked"; fi
done
for a in 8.8.8.8 1.1.1.1 203.0.113.10; do
  if rp_address_private "${a}"; then ko "public IPv4 ${a} blocked"; else ok "public IPv4 ${a} allowed"; fi
done
for a in ::1 fd00::1 fe80::1 ::ffff:127.0.0.1 ::ffff:10.0.0.1 ::ffff:7f00:1 ::127.0.0.1 ::; do
  if rp_address_private "${a}"; then ok "IPv6 ${a} blocked"; else ko "IPv6 ${a} not blocked"; fi
done
for a in 2606:4700::1111 2001:4860:4860::8888 ::ffff:8.8.8.8; do
  if rp_address_private "${a}"; then ko "public IPv6 ${a} blocked"; else ok "public IPv6 ${a} allowed"; fi
done

echo "== SSRF check =="
if rp_check_ssrf localhost; then ko "localhost allowed"; else ok "localhost blocked"; fi
if rp_check_ssrf 127.0.0.1; then ko "127.0.0.1 allowed"; else ok "127.0.0.1 blocked"; fi
if rp_check_ssrf ::1; then ko "::1 allowed"; else ok "::1 blocked"; fi

echo "== metadata =="
RP_META=()
RP_META["domain"]="a.example"
RP_META["upstream_url"]="https://b.example/"
rp_meta_save a.example && ok "metadata saved" || ko "metadata save failed"
rp_meta_load a.example && [ "$(rp_meta_get domain)" = "a.example" ] \
  && [ "$(rp_meta_get upstream_url)" = "https://b.example/" ] \
  && ok "metadata round-trip" || ko "metadata round-trip failed"
[ -f "${RP_CONF_DIR}/a.example.conf" ] && ok "metadata file created" || ko "metadata file missing"

echo "== config rendering =="
RP_REWRITE_WATERMARK=1048576
RP_REWRITE_MAX_BYTES=8388608
RP_REWRITE_MIN_OVERLAP=64
conf=$(rp_render_conf a.example auto https://b.example.com b.example.com 10 60 on b.example.com 1)
echo "${conf}" | grep -q 'header_filter_by_lua_file' && ok "rewrite header filter present" || ko "rewrite header filter missing"
echo "${conf}" | grep -q 'body_filter_by_lua_file' && ok "rewrite body filter present" || ko "rewrite body filter missing"
echo "${conf}" | grep -q 'proxy_set_header Accept-Encoding "";' && ok "identity encoding requested" || ko "identity encoding missing"
echo "${conf}" | grep -q 'proxy_ssl_verify on;' && ok "upstream TLS verification on" || ko "upstream TLS verification missing"
echo "${conf}" | grep -q 'sub_filter' && ko "sub_filter present" || ok "no sub_filter"
echo "${conf}" | grep -q "${RP_LUA_DIR}/rp_body.lua" && ok "persistent Lua path used" || ko "repo Lua path used"
echo "${conf}" | grep -q 'server_name a.example;' && ok "server_name rendered" || ko "server_name missing"
echo "${conf}" | grep -q 'listen 80;' && ok "HTTP listener rendered" || ko "HTTP listener missing"
echo "${conf}" | grep -q 'ssl_certificate' && ok "HTTPS listener rendered" || ko "HTTPS listener missing"

conf_none=$(rp_render_conf a.example none https://b.example.com a.example 10 60 on b.example.com 0)
echo "${conf_none}" | grep -q 'ssl_certificate' && ko "cert none still has TLS" || ok "cert none omits TLS"
echo "${conf_none}" | grep -q 'well-known/acme-challenge' && ko "cert none has ACME challenge" || ok "cert none omits ACME challenge"
echo "${conf_none}" | grep -q 'header_filter_by_lua_file' && ko "no-rewrite still has Lua" || ok "no-rewrite omits Lua"
echo "${conf_none}" | grep -q 'proxy_pass https://b.example.com;' && ok "proxy_pass rendered" || ko "proxy_pass missing"

echo "== pure Lua rewriter =="
lua_bin=""
command -v luajit >/dev/null 2>&1 && lua_bin=luajit
[ -z "${lua_bin}" ] && command -v lua >/dev/null 2>&1 && lua_bin=lua
if [ -n "${lua_bin}" ]; then
  "${lua_bin}" "${ROOT_DIR}/tools/test_reverse_proxy_lua.lua"
  rc=$?
  assert_rc 0 "${rc}" "Lua rewrite unit tests"
else
  echo "  [SKIP] luajit/lua not found"
fi

echo
echo "Reverse proxy offline tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] || exit 1
