#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Layer 2 (smoke) entrypoint. Runs INSIDE a systemd-enabled container as root,
# with the repo mounted at the working directory.
#
# L1 (preflight.sh) stops once the apt dependency stage succeeds. This goes all
# the way: a real install of Nginx + PHP + MariaDB, a vhost lifecycle
# (self-signed add -> serve -> delete), a backup roundtrip (real DB and site
# archived, then restored from the archives and compared), composer
# install/uninstall through addons.sh, then the exact same install command a
# second time to prove the install is idempotent, then
# `uninstall.sh --quiet --yes --all` to prove it leaves nothing behind. That is
# 20-40 minutes of downloading and compiling, which is why it runs weekly and
# on demand rather than on every push.
#
# systemd is REQUIRED, unlike L1. The installer starts services through
# systemctl/service and treats a failed php-fpm or mysqld start as fatal
# (setup_php_fpm_service returns the rc of svc_start; db-common.sh propagates it
# the same way), and the repo ships only systemd units -- no SysV init scripts.
# L1 gets away without systemd because it stops before any service is started.
#
# Usage (on a machine with a container runtime, repo mounted at /work). The
# image has to be built first -- systemd must be in place before the container
# starts, because PID 1 cannot be replaced afterwards:
#   docker build -t lnmp-smoke-systemd -f tools/container/systemd.Dockerfile tools/container
#   docker run -d --name lnmp-smoke --privileged --cgroupns=host \
#     --tmpfs /run --tmpfs /run/lock \
#     -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v "$PWD:/work" -w /work \
#     lnmp-smoke-systemd
#   docker exec -w /work lnmp-smoke bash tools/container/smoke.sh
#
# .github/workflows/container-smoke.yml runs exactly this, plus a readiness
# poll on `systemctl is-system-running`.
#
# Exit status: 0 only if install, idempotent re-run and uninstall all pass.

set -uo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "smoke must run as root inside the container" >&2
  exit 1
fi

if [ ! -f install.sh ] || [ ! -f uninstall.sh ]; then
  echo "smoke must run from the repo root (cwd must hold install.sh/uninstall.sh)" >&2
  exit 1
fi

# The container has to be running systemd, and this is the one thing that would
# otherwise fail *silently*: has_systemd() would return false, the installer
# would fall back to SysV `service`, every start would fail, and yet the run
# would still report PASS because the assertions only look at the tree
# afterwards. Refuse to run rather than produce that result. Same predicate as
# include/common.sh:has_systemd.
if [ ! -e /bin/systemctl ] || [ ! -d /run/systemd/system ]; then
  echo "this container is not running systemd (has_systemd() would be false)" >&2
  echo "build tools/container/systemd.Dockerfile and boot it as PID 1 -- see the header" >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

# The combination under test, in one place so the script reads as one sentence:
# Nginx 1.x from source, PHP 8.5 from source, MariaDB 11.8 from the prebuilt
# systemd tarball. Change these to widen coverage later (e.g. MySQL 8.4 via
# DB_OPTION=2) -- but keep it to one combination per run, the value of this
# layer is depth, not breadth.
NGINX_OPTION=1      # 1 = Nginx, 2 = Tengine, 3 = OpenResty
PHP_OPTION=3        # 1 = 8.3, 2 = 8.4, 3 = 8.5
DB_OPTION=5         # 1..7 = MySQL/MariaDB (5 = MariaDB 11.8), 8 = PostgreSQL
PHP_CACHE_OPTION=1  # 1 = Zend OPcache
DB_ROOT_PWD='LnmpSmoke2026'

FAILED=0
INSTALL_CMD=(./install.sh
  --nginx_option "${NGINX_OPTION}"
  --php_option "${PHP_OPTION}"
  --db_option "${DB_OPTION}"
  --phpcache_option "${PHP_CACHE_OPTION}"
  --dbrootpwd "${DB_ROOT_PWD}")

stage() { printf '\n=== %s ===\n' "$*"; }
ok() { printf '  PASS  %s\n' "$*"; }

bad() {
  printf '  FAIL  %s\n' "$*"
  FAILED=$((FAILED + 1))
}

# Run a command; on failure show its last lines so the log explains itself.
# assert_run "<description>" <command...>
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

# assert_any_exists "<description>" <path...>   (any one match wins)
assert_any_exists() {
  local desc=$1 p
  shift
  for p in "$@"; do
    if [ -e "${p}" ]; then ok "${desc} (${p})"; return; fi
  done
  bad "${desc} (none of: $*)"
}

# assert_running "<description>" <process-name...>   (any one match wins)
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

echo "=== target distro ==="
echo "${PRETTY_NAME:-unknown}"
echo "=== combination: nginx=${NGINX_OPTION} php=${PHP_OPTION} db=${DB_OPTION} ==="

# ---------------------------------------------------------------- 1/4 install
stage "1/4 install"
"${INSTALL_CMD[@]}" 2>&1 | tee smoke-install.log
rc=${PIPESTATUS[0]}
if [ "${rc}" -eq 0 ]; then
  ok "install.sh exited 0"
else
  bad "install.sh exited ${rc}"
  echo "--- tail of smoke-install.log ---"
  tail -n 40 smoke-install.log
  echo
  echo "=== SMOKE FAILED during install ==="
  exit 1
fi

# --------------------------------------------------- 2/4 the installed tree
stage "2/4 assert the installed tree"
assert_exists /usr/local/nginx/sbin/nginx
assert_run "nginx -t accepts the generated config" /usr/local/nginx/sbin/nginx -t
assert_running "nginx is running" nginx
assert_run "nginx answers on 127.0.0.1:80" curl -sS --max-time 10 -o /dev/null http://127.0.0.1/

assert_exists /usr/local/php/bin/php
assert_run "php -v works" /usr/local/php/bin/php -v
assert_run "php-fpm -t accepts the generated config" /usr/local/php/sbin/php-fpm -t
assert_running "php-fpm is running" php-fpm

assert_any_exists "mariadb client present" /usr/local/mariadb/bin/mariadb /usr/local/mariadb/bin/mysql
assert_any_exists "mariadb-admin present" /usr/local/mariadb/bin/mariadb-admin /usr/local/mariadb/bin/mysqladmin
assert_running "mariadb is running" mariadbd mysqld
assert_run "mysqladmin ping answers with the installed root password" \
  env MYSQL_PWD="${DB_ROOT_PWD}" \
  "$(command -v /usr/local/mariadb/bin/mariadb-admin || echo /usr/local/mariadb/bin/mysqladmin)" \
  -uroot ping

assert_exists /data/wwwroot

# ------------------------------------------- 2b/4 svc_start liveness regression
# systemd reports a Type=simple unit as started the moment the process is forked,
# so `systemctl start` returning 0 does not prove the service stayed up. That
# blind spot is what let a php-fpm which could not load libsodium.so.26 pass as
# installed. svc_start now settles and re-checks Type=simple units, so prove both
# directions with two throwaway units and then clean them up. This is the only
# place the real systemd behaviour can be exercised.
stage "2b/4 svc_start liveness on Type=simple units"

# svc_start lives in include/common.sh, which only defines functions at load time
# (it has no side effects and shares no helper names with this script).
# shellcheck source=/dev/null
. ./include/color.sh
# shellcheck source=/dev/null
. ./include/common.sh

probe_unit() {  # probe_unit <name> <exec-start>
  cat > "/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=LNMP smoke probe ($1)

[Service]
Type=simple
ExecStart=$2

[Install]
WantedBy=multi-user.target
EOF
}

drop_probe() {  # drop_probe <name>
  systemctl stop "$1" >/dev/null 2>&1
  systemctl reset-failed "$1" >/dev/null 2>&1
  rm -f "/etc/systemd/system/$1.service"
}

# A unit that keeps running: must be accepted, otherwise every install would abort.
probe_unit lnmp-smoke-alive "/bin/sh -c 'while true; do sleep 1; done'"
# A unit that dies shortly AFTER the fork, i.e. once systemctl start has already
# returned 0 -- deliberately not /bin/false, which can lose the race and fail the
# start job itself, which would test the pre-existing branch instead of the new one.
probe_unit lnmp-smoke-dies "/bin/sh -c 'sleep 0.5; exit 1'"
systemctl daemon-reload

if svc_start lnmp-smoke-alive >/dev/null 2>&1; then
  ok "live Type=simple unit is accepted"
else
  bad "live Type=simple unit was rejected"
fi

if svc_start lnmp-smoke-dies >/dev/null 2>&1; then
  bad "Type=simple unit that dies right after start was accepted"
else
  ok "Type=simple unit that dies right after start is rejected"
fi

drop_probe lnmp-smoke-alive
drop_probe lnmp-smoke-dies
systemctl daemon-reload

# ------------------------------------------------- 2c/4 vhost add + delete
# vhost.sh is interactive; drive it with prompt-TEXT matching (expect), not a
# positional answer sequence: a piped answer list breaks silently when
# vhost.sh adds, removes or reorders a prompt, and an exhausted stdin inside
# a y/n validation loop hangs forever (read on EOF returns empty, the loop
# never matches). vhost_smoke.exp names the missing prompt instead.
# --selfsigned needs no external dependency (no acme.sh, no real DNS).
# This is the layer that let the acme.sh reloadcmd bug live for years:
# vhost.sh had zero end-to-end coverage before this stage existed.
stage "2c/4 vhost lifecycle (self-signed add -> serve -> delete)"
VHOST_DOMAIN=smoke.test
if ! command -v expect > /dev/null 2>&1; then
  bad "expect is not installed - the installer's dependency stage should provide it"
else
  if expect tools/container/vhost_smoke.exp add "${VHOST_DOMAIN}" > smoke-vhost-add.log 2>&1; then
    ok "vhost.sh --add exited 0"
  else
    bad "vhost.sh --add failed (transcript in smoke-vhost-add.log)"
    tail -n 25 smoke-vhost-add.log
  fi
  assert_exists /usr/local/nginx/conf/vhost/${VHOST_DOMAIN}.conf
  assert_exists /usr/local/nginx/conf/ssl/${VHOST_DOMAIN}.crt
  assert_exists /usr/local/nginx/conf/ssl/${VHOST_DOMAIN}.key

  # The vhost docroot starts empty (403); deploy a page like an operator
  # would, then prove both listeners actually serve this vhost, not just
  # the default site.
  echo '<h1>smoke vhost</h1>' > /data/wwwroot/${VHOST_DOMAIN}/index.html
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --resolve ${VHOST_DOMAIN}:80:127.0.0.1 http://${VHOST_DOMAIN}/ 2>/dev/null || true)
  [ "${http_code}" = "200" ] && ok "vhost answers HTTP 200" || bad "vhost HTTP returned '${http_code:-none}'"
  https_code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve ${VHOST_DOMAIN}:443:127.0.0.1 https://${VHOST_DOMAIN}/ 2>/dev/null || true)
  [ "${https_code}" = "200" ] && ok "vhost answers HTTPS 200 (self-signed)" || bad "vhost HTTPS returned '${https_code:-none}'"

  if expect tools/container/vhost_smoke.exp delete "${VHOST_DOMAIN}" > smoke-vhost-del.log 2>&1; then
    ok "vhost.sh --delete exited 0"
  else
    bad "vhost.sh --delete failed (transcript in smoke-vhost-del.log)"
    tail -n 25 smoke-vhost-del.log
  fi
  assert_absent /usr/local/nginx/conf/vhost/${VHOST_DOMAIN}.conf
  assert_absent /usr/local/nginx/conf/ssl/${VHOST_DOMAIN}.crt
  assert_absent /data/wwwroot/${VHOST_DOMAIN}
  assert_run "nginx config still valid after vhost delete" /usr/local/nginx/sbin/nginx -t
fi

# ------------------------------------------------------ 2d/4 backup roundtrip
# The difference between a backup that exists and one that restores: run a
# real backup of a real database and site, then restore both from the
# archives and compare marker content. backup.sh must exit 0 - since
# v1.7.2 it propagates child failures (db_bk/website_bk), and the archives
# are only called success after tar -t (db_bk.sh) / footer checks.
stage "2d/4 backup roundtrip (db + web)"
BK_SITE=smokebk
MARIADB_CLI="$(command -v /usr/local/mariadb/bin/mariadb || echo /usr/local/mariadb/bin/mysql)"
if env MYSQL_PWD="${DB_ROOT_PWD}" "${MARIADB_CLI}" -uroot -e \
     "CREATE DATABASE ${BK_SITE}; \
      CREATE TABLE ${BK_SITE}.t (id INT PRIMARY KEY, marker VARCHAR(64)); \
      INSERT INTO ${BK_SITE}.t VALUES (1, 'smoke-db-marker-42');"; then
  ok "test database ${BK_SITE} created"
else
  bad "could not create test database ${BK_SITE}"
fi
mkdir -p /data/wwwroot/${BK_SITE}
echo smoke-web-marker-42 > /data/wwwroot/${BK_SITE}/marker.txt

# This script deliberately does not source options.conf (install.sh and
# backup.sh each read it in their own process), so backup_dir is NOT defined
# here -- under set -u the parent-shell expansions in the asserts below would
# abort the whole run. Read the one variable this stage needs: where
# backup.sh actually wrote the archives, not an assumed default.
backup_dir=$(sed -n 's/^backup_dir=//p' options.conf | tail -n 1)
[ -n "${backup_dir}" ] || backup_dir=/data/backup

sed -i 's@^backup_destination=.*@backup_destination=local@' options.conf
sed -i 's@^backup_content=.*@backup_content=db,web@' options.conf
sed -i "s@^db_name=.*@db_name=${BK_SITE}@" options.conf
sed -i "s@^website_name=.*@website_name=${BK_SITE}@" options.conf

if ./backup.sh > smoke-backup.log 2>&1; then
  ok "backup.sh exited 0"
else
  bad "backup.sh exited non-zero"
  tail -n 20 smoke-backup.log
fi
db_tgz=$(command ls -t ${backup_dir}/DB_${BK_SITE}_*.tgz 2>/dev/null | head -1)
web_tgz=$(command ls -t ${backup_dir}/Web_${BK_SITE}_*.tgz 2>/dev/null | head -1)
[ -n "${db_tgz}" ] && ok "DB archive created: ${db_tgz##*/}" || bad "no DB_${BK_SITE}_*.tgz in ${backup_dir}"
[ -n "${web_tgz}" ] && ok "Web archive created: ${web_tgz##*/}" || bad "no Web_${BK_SITE}_*.tgz in ${backup_dir}"

bk_restore="${PWD}/.smoke_restore"
rm -rf "${bk_restore}"; mkdir -p "${bk_restore}"
if [ -n "${db_tgz}" ] && tar -xzf "${db_tgz}" -C "${bk_restore}" 2>/dev/null \
   && grep -q 'smoke-db-marker-42' "${bk_restore}"/DB_${BK_SITE}_*.sql 2>/dev/null; then
  ok "DB archive restores and contains the inserted marker row"
else
  bad "DB archive does not restore to the marker row"
fi
if [ -n "${web_tgz}" ] && tar -xzf "${web_tgz}" -C "${bk_restore}" 2>/dev/null \
   && grep -q 'smoke-web-marker-42' "${bk_restore}/${BK_SITE}/marker.txt" 2>/dev/null; then
  ok "Web archive restores and contains the marker file"
else
  bad "Web archive does not restore to the marker file"
fi

# Cleanup: the uninstall stage asserts /data/wwwroot is gone, the idempotent
# re-run reads options.conf, and leftover fixtures would pollute later runs.
env MYSQL_PWD="${DB_ROOT_PWD}" "${MARIADB_CLI}" -uroot -e "DROP DATABASE IF EXISTS ${BK_SITE};" >/dev/null 2>&1
rm -rf /data/wwwroot/${BK_SITE} "${bk_restore}" /data/backup
sed -i 's@^backup_destination=.*@backup_destination=@' options.conf
sed -i 's@^backup_content=.*@backup_content=@' options.conf
sed -i 's@^db_name=.*@db_name=@' options.conf
sed -i 's@^website_name=.*@website_name=@' options.conf

# ------------------------------------------------------- 2e/4 addons: composer
# Exercises the addons.sh dispatch (flag parse -> install -> verify ->
# uninstall) against the real PHP; composer.org reachability is the same
# class of network dependency the rest of this script already has.
stage "2e/4 addons: composer install -> version -> uninstall"
if bash addons.sh -i --composer > smoke-composer.log 2>&1; then
  ok "addons.sh --composer install exited 0"
else
  bad "addons.sh --composer install exited non-zero"
  tail -n 20 smoke-composer.log
fi
assert_run "composer runs under the installed PHP" /usr/local/php/bin/php /usr/local/bin/composer --version
if bash addons.sh -u --composer >> smoke-composer.log 2>&1; then
  ok "addons.sh --composer uninstall exited 0"
else
  bad "addons.sh --composer uninstall exited non-zero"
  tail -n 20 smoke-composer.log
fi
assert_absent /usr/local/bin/composer

# ------------------------------------------------------- 3/4 idempotent re-run
stage "3/4 idempotency: re-run the exact same command"
"${INSTALL_CMD[@]}" 2>&1 | tee smoke-rerun.log
rc=${PIPESTATUS[0]}
if [ "${rc}" -eq 0 ]; then
  ok "second run exited 0"
else
  bad "second run exited ${rc}"
fi

# install.sh reports a failed step by name; that wording must not appear again.
if grep -qE 'failed \(exit [0-9]+\)|Aborting\.' smoke-rerun.log; then
  bad "second run reports a failing step"
  grep -nE 'failed \(exit [0-9]+\)|Aborting\.' smoke-rerun.log | head -n 5 | sed 's/^/          /'
else
  ok "second run reports no failing step"
fi

assert_running "nginx survived the re-run" nginx
assert_running "php-fpm survived the re-run" php-fpm
assert_running "mariadb survived the re-run" mariadbd mysqld

# ---------------------------------------------------------------- 4/4 uninstall
stage "4/4 uninstall: --quiet --yes --all"
./uninstall.sh --quiet --yes --all 2>&1 | tee smoke-uninstall.log
rc=${PIPESTATUS[0]}
if [ "${rc}" -eq 0 ]; then
  ok "uninstall.sh exited 0"
else
  bad "uninstall.sh exited ${rc}"
fi

assert_absent /usr/local/nginx
assert_absent /usr/local/php
assert_absent /usr/local/mariadb
assert_absent /usr/local/openssl
assert_absent /lib/systemd/system/nginx.service
assert_absent /lib/systemd/system/php-fpm.service
assert_absent /etc/init.d/mysqld
assert_absent /data/wwwroot
assert_not_running "no nginx process remains" nginx
assert_not_running "no php-fpm process remains" php-fpm
assert_not_running "no mariadb process remains" mariadbd mysqld

# ------------------------------------------------------------------------ done
echo
if [ "${FAILED}" -eq 0 ]; then
  echo "=== SMOKE OK: install, idempotent re-run and uninstall all clean ==="
  exit 0
fi
echo "=== SMOKE FAILED: ${FAILED} assertion(s) ==="
exit 1
