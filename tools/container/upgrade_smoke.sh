#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Upgrade-layer entrypoint for the container test net. Runs INSIDE the same
# systemd-enabled container as tools/container/smoke.sh (repo mounted at the
# working directory), but exercises the UPGRADE chains that smoke.sh never
# touches: MariaDB dump+restore, Nginx source-recompile + USR2/QUIT hot swap,
# and the guarded extraction/build steps those chains depend on.
#
# Why a separate workflow rather than a new stage of smoke.sh:
#   - the upgrade layer recompiles Nginx and re-downloads the MariaDB
#     tarball, which would push smoke.sh's 20-40 min run past the 90-minute
#     job timeout on the slowest distro (ubuntu:26.04 Rust coreutils);
#   - smoke.sh is the install-layer proof. Mixing a 15-25 min recompile in
#     makes a green smoke harder to read as "the install chain is clean".
# Both share the systemd.Dockerfile image and the same distro rotation.
#
# Combination under test (keep it to ONE per run, depth not breadth):
#   install:  Nginx from source + MariaDB 11.8 binary tarball
#   upgrade:  MariaDB (same-series, dump+restore path)
#             Nginx (recompile + hot swap + backup-binary mv rollback path)
#   idempotent re-run of both upgrades
#   uninstall
#
# systemd is REQUIRED, same as smoke.sh: the installer starts services via
# systemctl, and _nginx_hot_swap relies on /var/run/nginx.pid + SIGUSR2.
#
# Exit status: 0 only if every stage's assertions pass.

set -uo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "upgrade-smoke must run as root inside the container" >&2
  exit 1
fi

if [ ! -f install.sh ] || [ ! -f uninstall.sh ] || [ ! -f upgrade.sh ]; then
  echo "upgrade-smoke must run from the repo root (cwd must hold install.sh/upgrade.sh/uninstall.sh)" >&2
  exit 1
fi

if [ ! -e /bin/systemctl ] || [ ! -d /run/systemd/system ]; then
  echo "this container is not running systemd (has_systemd() would be false)" >&2
  echo "build tools/container/systemd.Dockerfile and boot it as PID 1 -- see smoke.sh header" >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

# Same combination as smoke.sh where they overlap (nginx 1, mariadb 11.8),
# but PHP is deliberately NOT installed: the upgrade layer's value is the
# MariaDB dump+restore + Nginx recompile/hot-swap chains, and a PHP
# install adds 10-15 min without exercising anything the upgrades touch.
NGINX_OPTION=1
DB_OPTION=5        # MariaDB 11.8 binary tarball
DB_ROOT_PWD='LnmpUpgrade2026'

# Upgrade targets come from versions.txt (single source of truth for this
# tree): same-series MariaDB bump and the latest Nginx stable.
# shellcheck disable=SC1091
. ./versions.txt
DB_TARGET_VER="${mariadb118_ver}"

FAILED=0
PASS=0
stage() { printf '\n=== %s ===\n' "$*"; }
ok() { printf '  PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() {
  printf '  FAIL  %s\n' "$*"
  FAILED=$((FAILED + 1))
}
assert_run() {
  local desc=$1 out
  shift
  if out=$("$@" 2>&1); then
    ok "${desc}"
  else
    bad "${desc}"
    printf '%s\n' "${out}" | tail -n 5 | sed 's/^/          /'
  fi
}
assert_exists() { [ -e "$1" ] && ok "present: $1" || bad "missing: $1"; }
assert_absent() { [ -e "$1" ] && bad "still present: $1" || ok "removed: $1"; }
assert_running() {
  local desc=$1 name
  shift
  for name in "$@"; do
    if pgrep -x "${name}" >/dev/null 2>&1; then ok "${desc}"; return; fi
  done
  bad "${desc}"
}
assert_not_running() {
  local desc=$1 name
  shift
  for name in "$@"; do
    if pgrep -x "${name}" >/dev/null 2>&1; then bad "${desc}"; return; fi
  done
  ok "${desc}"
}

# Read one value out of options.conf without sourcing it (same rationale as
# smoke.sh: keep this script's global namespace independent of the install's).
opt() { sed -n "s/^$1=//p" options.conf | tail -n 1; }

echo "=== target distro ==="
echo "${PRETTY_NAME:-unknown}"
echo "=== combination: nginx=${NGINX_OPTION} db=${DB_OPTION} upgrade-target db=${DB_TARGET_VER} ==="

# ---------------------------------------------------------------- 1/5 install
stage "1/5 install (Nginx + MariaDB ${DB_TARGET_VER})"
./install.sh \
  --nginx_option "${NGINX_OPTION}" \
  --db_option "${DB_OPTION}" \
  --dbrootpwd "${DB_ROOT_PWD}" \
  > smoke-upgrade-install.log 2>&1
rc=$?
if [ "${rc}" -eq 0 ]; then
  ok "install.sh exited 0"
else
  bad "install.sh exited ${rc}"
  tail -n 40 smoke-upgrade-install.log
  echo "=== UPGRADE SMOKE FAILED during install ==="
  exit 1
fi

MARIADB_CLI="$(command -v /usr/local/mariadb/bin/mariadb || echo /usr/local/mariadb/bin/mysql)"

# Seed a database + marker row that the upgrade must preserve.
UPG_SITE=upgradesite
if env MYSQL_PWD="${DB_ROOT_PWD}" "${MARIADB_CLI}" -uroot -e \
     "CREATE DATABASE IF NOT EXISTS ${UPG_SITE};
      CREATE TABLE IF NOT EXISTS ${UPG_SITE}.marker (id INT PRIMARY KEY, v VARCHAR(64));
      REPLACE INTO ${UPG_SITE}.marker VALUES (1, 'upgrade-marker-1');"; then
  ok "seed database ${UPG_SITE} created with marker row"
else
  bad "could not create seed database ${UPG_SITE}"
fi

assert_running "nginx is running after install" nginx
assert_running "mariadb is running after install" mariadbd mysqld
OLD_DB_VER="$(env MYSQL_PWD="${DB_ROOT_PWD}" "${MARIADB_CLI}" -uroot -N -B -e 'select version();' 2>/dev/null)"
echo "  installed DB version: ${OLD_DB_VER:-unknown}"

# ------------------------------------------------------------- 2/5 upgrade DB
stage "2/5 upgrade.sh --db ${DB_TARGET_VER} (dump+restore)"
./upgrade.sh --db "${DB_TARGET_VER}" > smoke-upgrade-db.log 2>&1
rc=$?
if [ "${rc}" -eq 0 ]; then
  ok "upgrade.sh --db exited 0"
else
  bad "upgrade.sh --db exited ${rc}"
  tail -n 40 smoke-upgrade-db.log
fi

assert_running "mariadb is running after upgrade" mariadbd mysqld
NEW_DB_VER="$(env MYSQL_PWD="${DB_ROOT_PWD}" "${MARIADB_CLI}" -uroot -N -B -e 'select version();' 2>/dev/null)"
echo "  upgraded DB version: ${NEW_DB_VER:-unknown}"
if [ -n "${NEW_DB_VER}" ]; then
  ok "DB version query answered after upgrade (${NEW_DB_VER})"
else
  bad "DB version query failed after upgrade"
fi
if env MYSQL_PWD="${DB_ROOT_PWD}" "${MARIADB_CLI}" -uroot -N -B -e \
     "SELECT v FROM ${UPG_SITE}.marker WHERE id=1;" 2>/dev/null | grep -q 'upgrade-marker-1'; then
  ok "marker row survived the dump+restore upgrade"
else
  bad "marker row was lost during the DB upgrade"
fi

# ---------------------------------------------------------- 3/5 upgrade Nginx
stage "3/5 upgrade.sh --nginx (recompile + hot swap)"
OLD_NGINX_VER="$(/usr/local/nginx/sbin/nginx -v 2>&1 | awk -F/ '{print $2}')"
echo "  installed nginx: ${OLD_NGINX_VER}"
# Give Nginx a little breathing room after the DB upgrade before we recompile.
sleep 2
./upgrade.sh --nginx > smoke-upgrade-nginx.log 2>&1
rc=$?
if [ "${rc}" -eq 0 ]; then
  ok "upgrade.sh --nginx exited 0"
else
  bad "upgrade.sh --nginx exited ${rc}"
  tail -n 60 smoke-upgrade-nginx.log
fi

NEW_NGINX_VER="$(/usr/local/nginx/sbin/nginx -v 2>&1 | awk -F/ '{print $2}')"
echo "  upgraded nginx: ${NEW_NGINX_VER}"
if [ -n "${NEW_NGINX_VER}" ] && [ "${NEW_NGINX_VER}" != "${OLD_NGINX_VER}" ]; then
  ok "nginx version changed (${OLD_NGINX_VER} -> ${NEW_NGINX_VER})"
elif [ -n "${NEW_NGINX_VER}" ]; then
  ok "nginx version stable (${NEW_NGINX_VER} == latest)"
else
  bad "nginx -v produced no version after upgrade"
fi
assert_run "nginx -t accepts the recompiled config" /usr/local/nginx/sbin/nginx -t
assert_running "nginx is running after upgrade" nginx
assert_run "nginx still answers on 127.0.0.1:80" curl -sS --max-time 10 -o /dev/null http://127.0.0.1/

# The hot-swap path moves the old binary aside; a .bak file is proof the
# rollback path was armed even on success.
NGINX_BAKS=$(command ls -1 /usr/local/nginx/sbin/nginx.bak* 2>/dev/null | head -n 1)
if [ -n "${NGINX_BAKS}" ]; then
  ok "old nginx binary preserved at ${NGINX_BAKS##*/} (rollback armed)"
else
  bad "no nginx.bak* backup binary found - the mv-aside step did not run"
fi

# --------------------------------------------------- 4/5 idempotent re-upgrade
# Re-running against the same target version must succeed: the MariaDB chain
# takes the "already at this version" path and the Nginx chain re-runs the
# extraction/build with everything already in place.
stage "4/5 idempotent re-run: upgrade.sh --db + --nginx again"
./upgrade.sh --db "${DB_TARGET_VER}" --nginx > smoke-upgrade-rerun.log 2>&1
rc=$?
if [ "${rc}" -eq 0 ]; then
  ok "second upgrade run exited 0"
else
  bad "second upgrade run exited ${rc}"
  tail -n 40 smoke-upgrade-rerun.log
fi
assert_running "nginx survived the re-run" nginx
assert_running "mariadb survived the re-run" mariadbd mysqld

# --------------------------------------------------------------- 5/5 uninstall
stage "5/5 uninstall: --quiet --yes --all"
./uninstall.sh --quiet --yes --all > smoke-upgrade-uninstall.log 2>&1
rc=$?
if [ "${rc}" -eq 0 ]; then
  ok "uninstall.sh exited 0"
else
  bad "uninstall.sh exited ${rc}"
  tail -n 40 smoke-upgrade-uninstall.log
fi
assert_absent /usr/local/nginx
assert_absent /usr/local/mariadb
assert_absent /lib/systemd/system/nginx.service
assert_not_running "no nginx process remains" nginx
assert_not_running "no mariadb process remains" mariadbd mysqld

# ------------------------------------------------------------------------ done
echo
if [ "${FAILED}" -eq 0 ]; then
  echo "=== UPGRADE SMOKE OK: ${PASS} assertion(s) passed ==="
  exit 0
fi
echo "=== UPGRADE SMOKE FAILED: ${FAILED} assertion(s) ==="
exit 1
