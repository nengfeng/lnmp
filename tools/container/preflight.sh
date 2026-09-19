#!/bin/bash
# Distro preflight: runs INSIDE a target distro container as root, driven by
# .github/workflows/container.yml. It asserts that the installer can resolve
# and install its dependency packages on this distro -- no download, no
# compile. This is the class of regression (package renames/removals across
# Debian/Ubuntu releases) that a plain lint run can never catch.
#
# Usage (from the repo root, on a machine with a container runtime):
#   docker run --rm -v "$PWD:/work" -w /work debian:12 \
#     bash tools/container/preflight.sh
#
# Exit status: 0 only if install.sh --preflight succeeded.
set -uo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "preflight must run as root inside the container" >&2
  exit 1
fi

echo "=== target distro ==="
# shellcheck disable=SC1091
. /etc/os-release
echo "${PRETTY_NAME:-unknown}"

# Keep the transcript on the mounted workspace so it can be uploaded as a
# build artifact; install.sh also tees each step into install.log.
log="${PWD}/preflight-install.log"
: > "${log}"

echo "=== install.sh --preflight ==="
./install.sh --preflight \
  --nginx_option 1 \
  --db_option 6 \
  --php_option 2 \
  --dbrootpwd 'CiPreflight2026' 2>&1 | tee "${log}"
rc=${PIPESTATUS[0]}

if [ "${rc}" -ne 0 ]; then
  echo
  echo "=== PREFLIGHT FAILED (install.sh exit ${rc}) ==="
  # Surface the reason here instead of forcing a trip through the artifact
  # download: the failing package/step is in the tail of the step log.
  if [ -s install.log ]; then
    echo "--- tail of install.log ---"
    tail -n 40 install.log
  fi
  echo "--- end of tail; full logs: install.log, ${log} ---"
  exit 1
fi

echo "=== preflight OK: dependencies resolved on ${PRETTY_NAME:-this distro} ==="
exit 0
