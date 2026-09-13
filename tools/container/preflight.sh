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
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "preflight must run as root inside the container" >&2
  exit 1
fi

echo "=== target distro ==="
# shellcheck disable=SC1091
. /etc/os-release
echo "${PRETTY_NAME:-unknown}"

echo "=== install.sh --preflight ==="
./install.sh --preflight \
  --nginx_option 1 \
  --db_option 6 \
  --php_option 2 \
  --dbrootpwd 'CiPreflight2026'

echo "=== preflight OK ==="
