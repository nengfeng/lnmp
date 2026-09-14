#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Layer 2 (smoke) entrypoint. Runs INSIDE a systemd-enabled container as root,
# with the repo mounted at the working directory.
#
# L1 (preflight.sh) stops once the apt dependency stage succeeds. This goes all
# the way: a real install of Nginx + PHP + MariaDB, then the exact same command
# a second time to prove the install is idempotent, then
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
