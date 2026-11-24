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
echo "${conf}" | grep -q 'proxy_redirect off;' && ok "proxy_redirect disabled with rewrite" || ko "proxy_redirect missing in rewrite mode"
if ca=$(rp_ca_bundle_path); then
  echo "${conf}" | grep -q "proxy_ssl_trusted_certificate ${ca};" \
    && ok "CA bundle configured (${ca})" || ko "CA bundle missing from config"
else
  echo "  [SKIP] no system CA bundle found"
fi
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
echo "${conf_none}" | grep -q 'proxy_redirect off;' && ko "proxy_redirect off in no-rewrite mode" || ok "no-rewrite leaves nginx proxy_redirect default"

echo "== subcommand domain validation =="
if rp_command_show '../../etc/cron.d/x' >/dev/null 2>&1; then
  ko "show accepted path-traversal domain"
else
  ok "show rejected path-traversal domain"
fi
if rp_command_delete '../../etc/cron.d/x' 0 >/dev/null 2>&1; then
  ko "delete accepted path-traversal domain"
else
  ok "delete rejected path-traversal domain"
fi

echo "== update preserves unsupplied fields =="
FLOW_TMP="${TMP_DIR}/flow"
mkdir -p "${FLOW_TMP}/nginx/conf/vhost" "${FLOW_TMP}/nginx/sbin" "${FLOW_TMP}/base/conf" \
  "${FLOW_TMP}/base/lua" "${FLOW_TMP}/logs" "${FLOW_TMP}/wwwlogs"
cat >"${FLOW_TMP}/nginx/sbin/nginx" <<'EOS'
#!/bin/bash
exit 0
EOS
chmod +x "${FLOW_TMP}/nginx/sbin/nginx"
_saved_web="${web_install_dir}"; _saved_bin="${nginx_bin}"; _saved_ssl="${PATH_SSL}"
_saved_base="${RP_BASE_DIR}"; _saved_conf="${RP_CONF_DIR}"; _saved_lua="${RP_LUA_DIR}"
_saved_backup="${RP_BACKUP_DIR}"; _saved_log="${RP_LOG_FILE}"; _saved_logs="${RP_PUBLIC_LOG_DIR}"
web_install_dir="${FLOW_TMP}/nginx"
nginx_bin="${FLOW_TMP}/nginx/sbin/nginx"
PATH_SSL="${FLOW_TMP}/nginx/conf/ssl"
RP_BASE_DIR="${FLOW_TMP}/base"
RP_CONF_DIR="${FLOW_TMP}/base/conf"
RP_LUA_DIR="${FLOW_TMP}/base/lua"
RP_BACKUP_DIR="${FLOW_TMP}/base/backups"
RP_LOG_FILE="${FLOW_TMP}/base/operations.log"
RP_PUBLIC_LOG_DIR="${FLOW_TMP}/wwwlogs"
rp_nginx_reload() { "${nginx_bin}" -s reload; }
RP_HOST_HEADER_MODE=custom
RP_CUSTOM_HOST=custom.example
RP_REWRITE=0
RP_CERT_MODE=none
RP_EMAIL=keep@example
RP_DNS_API=dns_ali
RP_VERIFY_UPSTREAM=on
RP_CONNECT_TIMEOUT=10
RP_READ_TIMEOUT=60
RP_FORCE=1
rp_command_add a.example http://127.0.0.1:8080/ custom custom.example 0 none keep@example dns_ali on 10 60 1 1 1 "" "" >/dev/null 2>&1 \
  && ok "flow add succeeded" || ko "flow add failed"
rp_command_update a.example http://127.0.0.1:9090/ "" "" "" "" "" "" "" "" "" 1 1 1 "" "" >/dev/null 2>&1 \
  && ok "flow update succeeded" || ko "flow update failed"
rp_meta_load a.example
[ "$(rp_meta_get email)" = "keep@example" ] && ok "email preserved on update" || ko "email cleared on update"
[ "$(rp_meta_get dns_api)" = "dns_ali" ] && ok "dns_api preserved on update" || ko "dns_api cleared on update"
[ "$(rp_meta_get custom_host)" = "custom.example" ] && ok "custom Host preserved in metadata" || ko "custom Host lost in metadata"
grep -q 'proxy_set_header Host custom.example;' "${FLOW_TMP}/nginx/conf/vhost/a.example.conf" \
  && ok "custom Host preserved in rendered config" || ko "custom Host lost in rendered config"
web_install_dir="${_saved_web}"; nginx_bin="${_saved_bin}"; PATH_SSL="${_saved_ssl}"
RP_BASE_DIR="${_saved_base}"; RP_CONF_DIR="${_saved_conf}"; RP_LUA_DIR="${_saved_lua}"
RP_BACKUP_DIR="${_saved_backup}"; RP_LOG_FILE="${_saved_log}"; RP_PUBLIC_LOG_DIR="${_saved_logs}"
unset _saved_web _saved_bin _saved_ssl _saved_base _saved_conf _saved_lua _saved_backup _saved_log _saved_logs

 echo "== DNS-01 failure keeps the live vhost =="
DNS_TMP="${TMP_DIR}/dns"
mkdir -p "${DNS_TMP}/home/.acme.sh" "${DNS_TMP}/nginx/conf/vhost" "${DNS_TMP}/base/backups"
printf '#!/bin/bash\nexit 1\n' >"${DNS_TMP}/home/.acme.sh/acme.sh"
chmod +x "${DNS_TMP}/home/.acme.sh/acme.sh"
printf 'live-vhost-marker\n' >"${DNS_TMP}/nginx/conf/vhost/a.example.conf"
_saved_home="${HOME}"
web_install_dir="${DNS_TMP}/nginx"
PATH_SSL="${DNS_TMP}/nginx/conf/ssl"
RP_BASE_DIR="${DNS_TMP}/base"
RP_BACKUP_DIR="${DNS_TMP}/base/backups"
RP_LOG_FILE="${DNS_TMP}/base/operations.log"
HOME="${DNS_TMP}/home"
rp_cert_issue_auto a.example "" dns_ali >/dev/null 2>&1 && ko "DNS-01 failure returned success" || ok "DNS-01 failure reported"
[ "$(cat "${DNS_TMP}/nginx/conf/vhost/a.example.conf")" = "live-vhost-marker" ] \
  && ok "live vhost untouched after DNS-01 failure" || ko "live vhost deleted after DNS-01 failure"
HOME="${_saved_home}"; unset _saved_home
web_install_dir="${_saved_web:-${TMP_DIR}/nginx}"; PATH_SSL="${_saved_ssl:-${TMP_DIR}/nginx/conf/ssl}"
RP_BASE_DIR="${TMP_DIR}/meta"; RP_BACKUP_DIR="${TMP_DIR}/backup"; RP_LOG_FILE="${TMP_DIR}/operations.log"

echo "== helper normalization =="
[ "$(rp_verify_nginx 1)" = "on" ] && ok "verify 1 -> on" || ko "verify 1 not normalized"
[ "$(rp_verify_nginx 0)" = "off" ] && ok "verify 0 -> off" || ko "verify 0 not normalized"
[ "$(rp_verify_nginx on)" = "on" ] && ok "verify on -> on" || ko "verify on not normalized"
rp_valid_timeout 10 && ok "timeout 10 valid" || ko "timeout 10 invalid"
rp_valid_timeout 0 && ko "timeout 0 accepted" || ok "timeout 0 rejected"
rp_valid_timeout abc && ko "timeout abc accepted" || ok "timeout abc rejected"
[ "$(rp_host_header_value custom custom.example b.example a.example)" = "custom.example" ] \
  && ok "probe Host custom" || ko "probe Host custom wrong"
[ "$(rp_host_header_value public custom.example b.example a.example)" = "a.example" ] \
  && ok "probe Host public uses A" || ko "probe Host public wrong"
[ "$(rp_host_header_value upstream custom.example b.example a.example)" = "b.example" ] \
  && ok "probe Host upstream uses B" || ko "probe Host upstream wrong"

echo "== version and reload probing =="
_saved_nginx_bin="${nginx_bin}"
fake_ver="${TMP_DIR}/nginx-openresty-version"
cat >"${fake_ver}" <<'EOS'
#!/bin/sh
if [ "$1" = "-v" ]; then echo "nginx version: openresty/1.27.4.1"; exit 0; fi
exit 0
EOS
chmod +x "${fake_ver}"
nginx_bin="${fake_ver}"
if rp_nginx_supports_http2_on; then ok "openresty version parsed"; else ko "openresty version not parsed"; fi
cat >"${fake_ver}" <<'EOS'
#!/bin/sh
if [ "$1" = "-v" ]; then echo "nginx version: openresty/1.21.4.1"; exit 0; fi
exit 0
EOS
if rp_nginx_supports_http2_on; then ko "old openresty accepted as http2 on"; else ok "old openresty rejected"; fi
nginx_bin="${_saved_nginx_bin}"
if awk '/^rp_nginx_reload\(\) \{/,/^\}/' include/reverse_proxy.sh | grep -q 'pgrep'; then
  ko "pgrep still used by reload"
else
  ok "no pgrep fallback in reload"
fi
unset _saved_nginx_bin

echo "== backup rotation =="
BK_TMP="${TMP_DIR}/bk"
mkdir -p "${BK_TMP}"
_saved_backup_dir="${RP_BACKUP_DIR}"; _saved_keep="${RP_BACKUP_KEEP:-}"
RP_BACKUP_DIR="${BK_TMP}"; RP_BACKUP_KEEP=2
for i in 1 2 3 4; do
  printf 'x\n' >"${TMP_DIR}/src"
  rp_backup_file "${TMP_DIR}/src" rotate.label >/dev/null || { ko "backup $i failed"; break; }
done
bk_count=$(find "${BK_TMP}" -maxdepth 1 -type f -name 'rotate.label.*' | wc -l)
[ "${bk_count}" -eq 2 ] && ok "backups pruned to 2" || ko "backup count ${bk_count}, want 2"
RP_BACKUP_DIR="${_saved_backup_dir}"; RP_BACKUP_KEEP="${_saved_keep}"
unset _saved_backup_dir _saved_keep

echo "== custom certificate key matching =="
CERT_TMP="${TMP_DIR}/certs"
mkdir -p "${CERT_TMP}"
openssl ecparam -name prime256v1 -genkey -noout -out "${CERT_TMP}/k1.pem" 2>/dev/null
openssl req -x509 -new -key "${CERT_TMP}/k1.pem" -days 1 -subj /CN=a.example -out "${CERT_TMP}/c1.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "${CERT_TMP}/k2.pem" 2>/dev/null
openssl req -x509 -new -key "${CERT_TMP}/k2.pem" -days 1 -subj /CN=a.example -out "${CERT_TMP}/c2.pem" 2>/dev/null
_saved_ssl="${PATH_SSL}"; _saved_backup_dir="${RP_BACKUP_DIR}"; _saved_log="${RP_LOG_FILE}"
PATH_SSL="${CERT_TMP}/ssl"; RP_BACKUP_DIR="${CERT_TMP}/backups"; RP_LOG_FILE="${CERT_TMP}/ops.log"
if rp_cert_custom a.example "${CERT_TMP}/c1.pem" "${CERT_TMP}/k1.pem"; then
  ok "ECDSA cert/key match accepted"
else
  ko "ECDSA cert/key match rejected"
fi
if rp_cert_custom a.example "${CERT_TMP}/c1.pem" "${CERT_TMP}/k2.pem"; then
  ko "mismatched ECDSA key accepted"
else
  ok "mismatched ECDSA key rejected"
fi
PATH_SSL="${_saved_ssl}"; RP_BACKUP_DIR="${_saved_backup_dir}"; RP_LOG_FILE="${_saved_log}"
unset _saved_ssl _saved_backup_dir _saved_log

echo "== non-interactive auto requires email =="
# Reuse the fake-nginx flow environment set up earlier; stdin is /dev/null.
if ( rp_command_add b.example http://127.0.0.1:8080/ upstream "" 0 auto "" "" on 10 60 1 1 1 "" "" ) </dev/null >/dev/null 2>&1; then
  ko "non-interactive auto accepted empty email"
else
  ok "non-interactive auto rejected empty email"
fi

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
