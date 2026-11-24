#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
# LNMP reverse proxy manager.
#
# Usage examples:
#   ./reverse_proxy.sh add -d a.example -u https://b.example
#   ./reverse_proxy.sh add -d a.example -u https://b.example --no-rewrite --cert none
#   ./reverse_proxy.sh update -d a.example -u https://b2.example
#   ./reverse_proxy.sh show -d a.example
#   ./reverse_proxy.sh list
#   ./reverse_proxy.sh test -d a.example
#   ./reverse_proxy.sh delete -d a.example

set -e

RP_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1094
. "${RP_SELF_DIR}/include/reverse_proxy.sh"

usage() {
  cat <<'EOF'
LNMP reverse proxy manager

Commands:
  add      -d DOMAIN -u URL [options]
  update   -d DOMAIN [options]
  delete   -d DOMAIN [--purge-cert]
  list
  show     -d DOMAIN
  test     -d DOMAIN

Options:
  -d, --domain DOMAIN          Domain A (single domain)
  -u, --upstream URL           Upstream B, http(s)://host[:port]/
  --host-header MODE           upstream (default) | public | custom:HOST
  --no-rewrite                 Disable L2 header/body rewriting
  --cert MODE                  auto (default) | custom | none
  --email EMAIL                Account email for acme.sh (auto mode)
  --dns dns_xxx                acme.sh DNS API (auto mode)
  --cert-file PATH             Custom certificate file
  --key-file PATH              Custom private key file
  --verify-upstream on|off     Verify upstream TLS certificate (default on)
  --connect-timeout SECONDS    Proxy connect timeout (default 10)
  --read-timeout SECONDS       Proxy read timeout (default 60)
  --skip-upstream-check        Do not probe upstream reachability
  --allow-private-upstream     Allow private/loopback upstream addresses
  --force                      Replace an existing vhost file
  --purge-cert                 Delete the certificate when deleting the proxy
  -h, --help                   Show this help

Upstream must be an http/https URL at the site root. The MVP does not support
upstream sub-paths. Rewrite mode rewrites response headers and text bodies, but
it cannot hide every occurrence of the upstream host (see docs/reverse_proxy.md).
EOF
}

[ "$(id -u)" -eq 0 ] || { rp_die "This script must be run as root."; exit 1; }

command="${1:-}"
case "${command}" in
  -h|--help|help) usage; exit 0 ;;
esac
[ -n "${command}" ] || { usage; exit 1; }
shift || true

domain=""
upstream=""
host_header_mode="upstream"
custom_host=""
rewrite="1"
cert_mode="auto"
email=""
dns_api=""
cert_file=""
key_file=""
verify_upstream="1"
connect_timeout="10"
read_timeout="60"
skip_check="0"
allow_private="0"
force="0"
purge_cert="0"

# update keeps existing values unless a flag is explicitly supplied.
if [ "${command}" = "update" ]; then
  host_header_mode=""
  rewrite=""
  cert_mode=""
  verify_upstream=""
  connect_timeout=""
  read_timeout=""
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    -d|--domain) domain="${2:-}"; shift 2 ;;
    -u|--upstream) upstream="${2:-}"; shift 2 ;;
    --host-header)
      case "${2:-}" in
        custom:*) host_header_mode="custom"; custom_host="${2#custom:}" ;;
        *) host_header_mode="${2:-upstream}" ;;
      esac
      shift 2 ;;
    --host-header=*)
      _hh_value="${1#--host-header=}"
      case "${_hh_value}" in
        custom:*) host_header_mode="custom"; custom_host="${_hh_value#custom:}" ;;
        *) host_header_mode="${_hh_value:-upstream}" ;;
      esac
      unset _hh_value
      shift ;;
    --custom-host) custom_host="${2:-}"; host_header_mode="custom"; shift 2 ;;
    --no-rewrite) rewrite="0"; shift ;;
    --rewrite) rewrite="1"; shift ;;
    --cert) cert_mode="${2:-}"; shift 2 ;;
    --cert=*) cert_mode="${1#--cert=}"; shift ;;
    --email) email="${2:-}"; shift 2 ;;
    --email=*) email="${1#--email=}"; shift ;;
    --dns) dns_api="${2:-}"; shift 2 ;;
    --dns=*) dns_api="${1#--dns=}"; shift ;;
    --cert-file) cert_file="${2:-}"; shift 2 ;;
    --cert-file=*) cert_file="${1#--cert-file=}"; shift ;;
    --key-file) key_file="${2:-}"; shift 2 ;;
    --key-file=*) key_file="${1#--key-file=}"; shift ;;
    --verify-upstream) verify_upstream="${2:-}"; shift 2 ;;
    --verify-upstream=*) verify_upstream="${1#--verify-upstream=}"; shift ;;
    --connect-timeout) connect_timeout="${2:-}"; shift 2 ;;
    --connect-timeout=*) connect_timeout="${1#--connect-timeout=}"; shift ;;
    --read-timeout) read_timeout="${2:-}"; shift 2 ;;
    --read-timeout=*) read_timeout="${1#--read-timeout=}"; shift ;;
    --skip-upstream-check) skip_check="1"; shift ;;
    --allow-private-upstream) allow_private="1"; shift ;;
    --force) force="1"; shift ;;
    --purge-cert) purge_cert="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [ "${command}" = "add" ] && [ "${cert_mode}" = "auto" ] && [ -z "${email}" ] && [ -t 0 ]; then
  read -erp "Email for Let's Encrypt (auto certificate): " email || true
fi

if [ -n "${verify_upstream}" ]; then
  case "${verify_upstream}" in
    1|on|yes|true) verify_upstream="1" ;;
    0|off|false) verify_upstream="0" ;;
    *) echo "Invalid --verify-upstream value: ${verify_upstream}" >&2; exit 1 ;;
  esac
fi

mkdir -p "${RP_BASE_DIR}" "${RP_CONF_DIR}" "${RP_LUA_DIR}" "${RP_BACKUP_DIR}"
exec 9>"${RP_LOCK_FILE}"
flock 9

rp_init || exit 1

export RP_HOST_HEADER_MODE="${host_header_mode}"
export RP_CUSTOM_HOST="${custom_host}"
export RP_REWRITE="${rewrite}"
export RP_CERT_MODE="${cert_mode}"
export RP_EMAIL="${email}"
export RP_DNS_API="${dns_api}"
export RP_VERIFY_UPSTREAM="${verify_upstream}"
export RP_CONNECT_TIMEOUT="${connect_timeout}"
export RP_READ_TIMEOUT="${read_timeout}"
export RP_FORCE="${force}"

case "${command}" in
  add)
    [ -n "${domain}" ] && [ -n "${upstream}" ] || { rp_die "add requires --domain and --upstream"; exit 1; }
    rp_command_add "${domain}" "${upstream}" "${host_header_mode}" "${custom_host}" \
      "${rewrite}" "${cert_mode}" "${email}" "${dns_api}" "${verify_upstream}" \
      "${connect_timeout}" "${read_timeout}" "${force}" "${skip_check}" \
      "${allow_private}" "${cert_file}" "${key_file}"
    ;;
  update)
    [ -n "${domain}" ] || { rp_die "update requires --domain"; exit 1; }
    rp_command_update "${domain}" "${upstream}" "${host_header_mode}" "${custom_host}" \
      "${rewrite}" "${cert_mode}" "${email}" "${dns_api}" "${verify_upstream}" \
      "${connect_timeout}" "${read_timeout}" "${force}" "${skip_check}" \
      "${allow_private}" "${cert_file}" "${key_file}"
    ;;
  delete)
    [ -n "${domain}" ] || { rp_die "delete requires --domain"; exit 1; }
    rp_command_delete "${domain}" "${purge_cert}"
    ;;
  list)
    rp_command_list
    ;;
  show)
    [ -n "${domain}" ] || { rp_die "show requires --domain"; exit 1; }
    rp_command_show "${domain}"
    ;;
  test)
    [ -n "${domain}" ] || { rp_die "test requires --domain"; exit 1; }
    rp_command_test "${domain}"
    ;;
  *)
    echo "Unknown command: ${command}" >&2
    usage
    exit 1
    ;;
esac

exit 0