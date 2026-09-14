# Base image for the L2 smoke run (see .github/workflows/container-smoke.yml).
#
# The official debian/ubuntu images ship no init system: their rootfs carries
# the libsystemd0 *library* and init-system-helpers, but not systemctl. So the
# installer's has_systemd() -- [ -e /bin/systemctl ] && [ -d /run/systemd/system ]
# in include/common.sh -- returns false, it falls back to SysV `service`, and
# this repo ships no SysV init scripts at all (only systemd units). PHP-FPM and
# MariaDB would then fail to start, which the installer treats as fatal.
#
# Hence a purpose-built image that can boot systemd as PID 1. Installing
# systemd into a *running* container is not an option -- PID 1 cannot be
# swapped after the fact -- so it has to happen at build time. The run flags
# systemd needs (--privileged, --cgroupns=host, a writable /sys/fs/cgroup) are
# in the workflow, not here.

FROM debian:12

# Recommends are kept: they pull in the pieces systemd expects in a container
# (dbus and friends), and a base image that boots cleanly matters far more here
# than a few megabytes.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y \
      systemd \
      systemd-sysv \
      dbus \
 && rm -rf /var/lib/apt/lists/*

# A container image ships no machine ID and systemd wants one at boot. Generate
# it here, best effort: || true so an unexpected failure cannot take the whole
# build down, because a missing/empty machine-id still boots (systemd falls back
# to a transient ID) whereas a failed build costs a full CI round.
RUN systemd-machine-id-setup || true

# systemd-sysv provides /sbin/init.
CMD ["/sbin/init"]
