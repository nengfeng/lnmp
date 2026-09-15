#!/bin/bash
# Author:  Alpha Eva <kaneawk AT gmail.com>
# SPDX-License-Identifier: Apache-2.0

# Machine architecture token for binary tarball names ($SYS_ARCH_M / aarch64)
SYS_ARCH_M=$(uname -m)

# Purge distro MySQL/MariaDB packages that conflict with our own installs.
# Only when installing our own MySQL/MariaDB (db_option 1-7). PostgreSQL
# (db_option 8) coexists fine with the distro's MySQL/MariaDB, so it must NOT
# trigger this purge or a pre-existing DB gets wiped.
# Usage: purge_conflicting_db_packages
purge_conflicting_db_packages() {
  if [[ "${db_option}" =~ ^[1-7]$ ]]; then
    local pkgList="mysql-client mysql-server mysql-common mariadb-client mariadb-server mariadb-common"
    local Package
    for Package in ${pkgList}; do
      apt-get -y purge ${Package} > /dev/null 2>&1
    done
    # Purge residual config; -r guards against an empty list (xargs would
    # otherwise run dpkg with no arguments and error out)
    dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' | xargs -r dpkg -P
  fi
}

# Install security updates only, working with both the legacy one-line
# sources.list format and the deb822 /etc/apt/sources.list.d/*.sources
# format used by Debian 12+/Ubuntu 24.04+ (where the main sources.list is
# usually empty and a plain 'grep security' found nothing).
# Usage: install_security_updates
install_security_updates() {
  local tmp_list=/tmp/security.sources.list

  # Legacy one-line format entries
  grep -hs '^deb .*security' /etc/apt/sources.list /etc/apt/sources.list.d/*.list > ${tmp_list} 2>/dev/null

  # deb822 format: convert 'Types: deb' + 'URIs/Suites' blocks into one-line
  if [ ! -s ${tmp_list} ] && ls /etc/apt/sources.list.d/*.sources > /dev/null 2>&1; then
    awk '
      FNR == 1 {
        # flush a pending block from the previous file, then reset state:
        # without the reset, isdeb/types from file N leak into file N+1
        # and its non-security blocks get emitted too
        if (inblock && isdeb && types) print types " " uris " " suites " " comps
        inblock=0; isdeb=0; types=""; uris=""; suites=""; comps=""
      }
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { if (inblock && isdeb && types) { print types " " uris " " suites " " comps }; inblock=0; isdeb=0; types=""; uris=""; suites=""; comps=""; next }
      /^[^[:space:]]/ { inblock=1 }
      inblock {
        # keep the full value (suites/components may hold several words);
        # the value itself is the deb/deb-src keyword and must not be
        # prefixed with a second "deb" when emitting the one-line entry
        if ($1 == "Types:")      { types = $0;  sub(/^[^[:space:]]+[[:space:]]+/, "", types) }
        if ($1 == "URIs:")      { uris = $0;   sub(/^[^[:space:]]+[[:space:]]+/, "", uris) }
        if ($1 == "Suites:")    { suites = $0; sub(/^[^[:space:]]+[[:space:]]+/, "", suites) }
        if ($1 == "Components:") { comps = $0;  sub(/^[^[:space:]]+[[:space:]]+/, "", comps) }
        # "security" may live in the suite name (Debian: bookworm-security)
        # or in the URI (Ubuntu deb822: http://security.ubuntu.com/ with
        # Suites: noble-updates) — check both
        if (suites ~ /security/ || uris ~ /security/) isdeb=1
      }
      END { if (inblock && isdeb && types) print types " " uris " " suites " " comps }
    ' /etc/apt/sources.list.d/*.sources >> ${tmp_list} 2>/dev/null
  fi

  if [ -s ${tmp_list} ]; then
    apt-get -y upgrade -o Dir::Etc::SourceList=${tmp_list} -o Dir::Etc::SourceParts=/dev/null
  else
    # No security entry found at all: fall back to a normal upgrade so the
    # box is not left completely unpatched
    echo "${CWARNING}No security sources found, running full upgrade instead${CEND}"
    apt-get -y upgrade
  fi
  rm -f ${tmp_list}
}

# Install a package list.
#
# apt decides. The apt-cache pre-check is ADVISORY only: it names every package
# apt-cache could not find, so the whole list surfaces in one run instead of
# costing one CI round per name -- but it must never veto the install.
# apt-cache is a heuristic view of the index, and on Debian 13 it answered "no
# such package" for five names the archive definitely ships (libxml2,
# libxml2-dev, libevent-dev, libxslt1-dev, rsync -- each verified to carry its
# own Package: stanza in trixie/main). Believing it turned a perfectly
# installable dependency list into a red run, so only apt-get's own exit status
# fails this function now; a genuinely absent name still fails, with apt's own
# E: line naming it.
# Usage: apt_install_packages [pkg...]
apt_install_packages() {
  local Package suspect="" err failed=0
  for Package in "$@"; do
    pkg_exists "${Package}" || suspect="${suspect} ${Package}"
  done
  [ -n "${suspect}" ] && echo "${CWARNING}apt-cache does not list:${suspect} -- letting apt decide${CEND}"

  for Package in "$@"; do
    if ! err=$(apt-get --no-install-recommends -y install "${Package}" 2>&1); then
      echo "${CFAILURE}Failed to install required package: ${Package}${CEND}"
      printf '%s\n' "${err}" | grep -E '^E:' | tail -n 3 || true
      failed=1
    fi
  done

  if [ ${failed} -ne 0 ]; then
    # Only reachable when apt really could not install something: surface what
    # the index actually holds, so a broken apt-cache cannot masquerade as a
    # per-release rename. Both counts should be large on a healthy index.
    echo "${CWARNING}--- apt index ---${CEND}"
    echo "  apt-cache pkgnames: $(apt-cache pkgnames 2> /dev/null | wc -l)"
    echo "  Packages lists    : $(ls /var/lib/apt/lists/*Packages* 2> /dev/null | wc -l)"
    for Package in ${suspect}; do
      echo "  ${Package}:"
      apt-cache policy "${Package}" 2>&1 | sed -n '1,4{s/^/    /;p}'
    done
    return 1
  fi
  return 0
}

# True when the archive ships a real package named exactly like this.
#
# 'apt-cache show' answers for names the archive does not ship, so neither its
# output nor its exit code is an existence test -- and it is wrong in both
# directions:
#   - a name that only appears in some other package's dependency gets a
#     version-less placeholder entry (apt's wording: "referred to by another
#     package"). apt-cache finds no version for it, files it under virtualPkgs
#     and exits 0 with only an N: notice on stderr. Ubuntu 24.04 ships no
#     libaio1, but multiverse's libodpic4 still says "Recommends: libaio1" -- a
#     dangling reference the 64-bit time_t rename left behind -- so the old
#     exit-code test called it installable and apt aborted the dependency stage
#     with "E: Package 'libaio1' has no installation candidate".
#   - a name another package Provides may still be answerable even though no
#     package carries it: Debian 13 ships libglib2.0-0t64, which says
#     "Provides: libglib2.0-0".
# So neither the presence of output nor the exit code alone decides it: only a
# stanza whose own Package field equals the requested name proves the archive
# ships that package.
# (apt 2.7.14, what noble ships: private-show.cc:409-414 chooses Error vs
#  Notice; private-cacheset.cc:133-186 synthesises the placeholder Pkg.)
#
# Even so this is a heuristic, not a contract: apt-cache has also been observed
# answering "no such package" for names the archive definitely ships (the
# debian:13 preflight failed on five of them, each verified to carry its own
# Package: stanza in trixie/main). A miss must therefore never be the sole
# reason a run fails -- apt_install_packages reports it and lets apt-get decide.
#
# No 'grep -q' on purpose: it stops at the first match and closes the pipe while
# apt-cache is still writing, and 'set -o pipefail' (install.sh:9) would then
# surface apt-cache's SIGPIPE (141) as a *missing* package. Capture the stanzas
# first, so apt-cache never writes into a pipeline this function may abandon.
# Must run after 'apt-get update': it queries the package index.
# Usage: pkg_exists <name>
pkg_exists() {
  local stanzas
  stanzas=$(apt-cache show "$1" 2> /dev/null)
  [ -n "${stanzas}" ] || return 1
  printf '%s\n' "${stanzas}" | grep -Fx "Package: $1" > /dev/null
}

# Resolve a package name to what this release actually ships.
#
# Names drift across releases, and a single unknown name aborts the whole
# dependency stage (apt_install_packages returns 1). The big one is the
# 64-bit time_t transition, which renamed runtime libraries on Debian 13 /
# Ubuntu 24.04+ by appending "t64" -- and the old name was *removed*, not
# kept as an alias: libaio1 -> libaio1t64, libglib2.0-0 -> libglib2.0-0t64.
# The removal is invisible to 'apt-cache show': the t64 package does not always
# Provide the old name (libglib2.0-0t64 does, libaio1t64 does not), so the
# resolve cannot lean on Provides -- it tries the "t64" suffix itself, and
# pkg_exists above is what separates a real package from a lingering reference.
# Renames that do not follow this pattern (libidn12-dev -> libidn-dev) are
# handled explicitly in the per-release lists.
#
# Must run after 'apt-get update': it queries the package index.
# Usage: resolve_pkg_name <name>
resolve_pkg_name() {
  if pkg_exists "$1"; then
    echo "$1"
  elif pkg_exists "$1t64"; then
    echo "$1t64"
  else
    # Unknown under both names: hand back the original so the apt error
    # names the package that actually broke.
    echo "$1"
  fi
}

installDepsDebian() {
  echo "${CMSG}Removing the conflicting packages...${CEND}"
  purge_conflicting_db_packages

  echo "${CMSG}Installing dependencies packages...${CEND}"
  apt-get -y update || return 1
  apt-get -y autoremove > /dev/null 2>&1
  apt-get -yf install > /dev/null 2>&1
  export DEBIAN_FRONTEND=noninteractive

  install_security_updates || return 1

  # Packages common to the supported Debian releases (12/13), i.e. the last
  # two releases (see the support policy in README and the gate in check_os.sh)
  # Note: the runtime package is libxml2-dev only -- libxml2 is omitted. On
  # newer releases it has been renamed to a soname package (libxml2-16 in
  # Ubuntu 26.04, and Debian is moving the same way), while libxml2-dev keeps
  # its name everywhere and Depends on the matching runtime package, so it
  # alone pulls in the right library on every supported release.
  local pkgCommon="debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf automake libjpeg-dev libpng-dev libgd-dev libxml2-dev zlib1g zlib1g-dev libc6 libc6-dev libglib2.0-0 libglib2.0-dev bzip2 libzip-dev libbz2-1.0 libaio1 libaio-dev numactl libreadline-dev curl libcurl4-openssl-dev e2fsprogs libkrb5-3 libkrb5-dev libltdl-dev openssl net-tools libssl-dev libtool libevent-dev bison re2c libsasl2-dev libxslt1-dev libicu-dev libpsl-dev locales patch vim zip unzip tmux htop bc dc expect libexpat1-dev libonig-dev libtirpc-dev rsync git lsof lrzsz rsyslog cron logrotate chrony libsqlite3-dev psmisc wget sysv-rc apt-transport-https ca-certificates gnupg ufw libmaxminddb-dev procps"

  # Per-release additions for the supported Debian releases (12/13), which is
  # all this needs a branch for: check_os.sh refuses anything else before this
  # runs. The names below were verified against the archives.
  #   libncurses6 replaces libncurses5, libidn12 replaces libidn11
  #   libidn12-dev does not exist anywhere: the libidn dev package is the
  #     unversioned libidn-dev (libidn12 is the runtime name)
  #   software-properties-common: NOT requested -- nothing in this repo calls
  #     add-apt-repository, and Debian 13 (trixie) dropped the package, so
  #     asking for it aborted the whole list there
  #   procps: health_check.sh reads 'free'; memory.sh cannot depend on it
  #     (it runs before this stage) and parses /proc/meminfo instead
  local pkgExtra=""
  case "${Debian_ver}" in
    12|13)
      pkgExtra="libncurses6 libncurses-dev libidn12 libidn-dev"
      ;;
    *)
      # No verified package list for this release, so do not guess one.
      die_hard "Your system Debian ${Debian_ver} is not supported. Only Debian 12/13 and Ubuntu 24.04/26.04 are supported."
      ;;
  esac

  # Normalise each name for this release before installing: an unhandled
  # t64 rename would otherwise abort the whole list (see resolve_pkg_name)
  local pkg rpkg
  local resolved=()
  for pkg in ${pkgCommon} ${pkgExtra}; do
    rpkg=$(resolve_pkg_name "${pkg}")
    [ "${rpkg}" != "${pkg}" ] && echo "${CMSG}Package renamed on this release: ${pkg} -> ${rpkg}${CEND}"
    resolved+=("${rpkg}")
  done
  apt_install_packages "${resolved[@]}" || return 1

  # libaio time64 transition (Debian 13+): package installs libaio.so.1t64
  # but MySQL binaries expect libaio.so.1
  if [[ "${Debian_ver}" =~ ^1[3-9]$ ]]; then
    if [ ! -e /usr/lib/$SYS_ARCH_M-linux-gnu/libaio.so.1 ]; then
      local libaio_src=$(find /usr/lib -name 'libaio.so.1t64*' 2>/dev/null | head -1)
      if [ -n "${libaio_src}" ]; then
        ln -sf "${libaio_src}" /usr/lib/$SYS_ARCH_M-linux-gnu/libaio.so.1
        echo "${CMSG}Created libaio.so.1 symlink for Debian 13+ compatibility${CEND}"
      fi
    fi
  fi
  return 0
}

installDepsUbuntu() {
  echo "${CMSG}Removing the conflicting packages...${CEND}"
  purge_conflicting_db_packages

  echo "${CMSG}Installing dependencies packages...${CEND}"
  apt-get -y update || return 1
  apt-get -y autoremove > /dev/null 2>&1
  apt-get -yf install > /dev/null 2>&1
  export DEBIAN_FRONTEND=noninteractive

  install_security_updates || return 1

  # Packages common to the supported Ubuntu releases (24.04/26.04), i.e. the
  # last two LTS releases (see the support policy in README and the gate in
  # check_os.sh)
  # Note: libxml2 is omitted for the same reason as the Debian list -- it has
  # been renamed to libxml2-16 in 26.04, while libxml2-dev keeps its name and
  # Depends on the matching runtime package on every supported release.
  local pkgCommon="libperl-dev debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf automake libjpeg-dev libpng-dev libgd-dev libxml2-dev zlib1g zlib1g-dev libc6 libc6-dev libglib2.0-0 libglib2.0-dev bzip2 libzip-dev libbz2-1.0 libaio1 libaio-dev numactl libreadline-dev curl e2fsprogs libkrb5-3 libkrb5-dev libltdl-dev openssl net-tools libssl-dev libtool libevent-dev re2c libsasl2-dev libxslt1-dev libicu-dev libpsl-dev libsqlite3-dev bison patch vim zip unzip tmux htop bc dc expect libexpat1-dev rsyslog libonig-dev libtirpc-dev libnss3 rsync git lsof lrzsz chrony psmisc wget apt-transport-https ca-certificates gnupg ufw libmaxminddb-dev procps"

  # Per-release additions for the supported Ubuntu releases (24.04/26.04),
  # which is all this needs a branch for: check_os.sh refuses anything else
  # before this runs. The names below were verified against the archives:
  #   libncurses6 replaces libncurses5, libidn12 replaces libidn11 (the
  #     rename predates the supported set: it landed in 22.04)
  #   libidn12-dev does not exist anywhere: the libidn dev package is the
  #     unversioned libidn-dev (libidn12 is the runtime name)
  #   sysv-rc: does not exist in ANY Ubuntu release (verified against the
  #     archive); update-rc.d ships in init-system-helpers, which is
  #     priority: required and therefore always present. Do not re-add it.
  #   software-properties-common: dropped from the common list -- nothing in
  #     this repo calls add-apt-repository, and Debian 13 already removed the
  #     package, so keeping it here is pure drift risk
  #   procps: health_check.sh reads 'free'
  local pkgExtra=""
  case "${Ubuntu_ver}" in
    24|26)
      pkgExtra="libncurses6 libncurses-dev libidn12 libidn-dev libcurl4-openssl-dev"
      ;;
    *)
      # No verified package list for this release, so do not guess one.
      die_hard "Your system Ubuntu ${Ubuntu_ver} is not supported. Only Debian 12/13 and Ubuntu 24.04/26.04 are supported."
      ;;
  esac

  # Normalise each name for this release before installing: an unhandled
  # t64 rename would otherwise abort the whole list (see resolve_pkg_name)
  local pkg rpkg
  local resolved=()
  for pkg in ${pkgCommon} ${pkgExtra}; do
    rpkg=$(resolve_pkg_name "${pkg}")
    [ "${rpkg}" != "${pkg}" ] && echo "${CMSG}Package renamed on this release: ${pkg} -> ${rpkg}${CEND}"
    resolved+=("${rpkg}")
  done
  apt_install_packages "${resolved[@]}" || return 1

  # libaio time64 transition (Ubuntu 24.04+): package installs libaio.so.1t64
  # but MySQL binaries expect libaio.so.1
  if [[ "${Ubuntu_ver}" =~ ^2[4-9]$ ]]; then
    if [ ! -e /usr/lib/$SYS_ARCH_M-linux-gnu/libaio.so.1 ]; then
      local libaio_src=$(find /usr/lib -name 'libaio.so.1t64*' 2>/dev/null | head -1)
      if [ -n "${libaio_src}" ]; then
        ln -sf "${libaio_src}" /usr/lib/$SYS_ARCH_M-linux-gnu/libaio.so.1
        echo "${CMSG}Created libaio.so.1 symlink for Ubuntu 24.04+ compatibility${CEND}"
      fi
    fi
  fi
  return 0
}

installDepsBySrc() {
  # PHP intl links the distro ICU via pkg-config (icu-uc/icu-i18n). libicu-dev
  # is in the package lists above; across the support window it ships ICU 72+
  # (Debian 12) to 76+ (Debian 13), which PHP 8.3-8.5 are happy with. The old
  # source build of icu4c existed for releases outside that window and is gone
  # -- icu-config no longer ships there either, so the old probe could only
  # ever answer "build from source". Refuse here, naming the package, rather
  # than letting PHP's configure fail later with an indirect error.
  if ! pkg-config --exists icu-uc 2>/dev/null; then
    die_hard "libicu-dev is missing (PHP intl needs it; it is in the installDeps package list)"
  fi

  if command -v lsof >/dev/null 2>&1; then
    echo 'already initialize' > ~/.lnmp
  else
    # This used to report "${PM} config error parsing file failed", which sent
    # anyone who hit it looking for a broken config file. The real cause is the
    # dependency stage: lsof is in the package list, so it is missing only when
    # that stage failed.
    die_hard "dependency install failed: lsof is missing (${PM})"
  fi

  return 0
}
