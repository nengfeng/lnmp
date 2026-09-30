# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries are curated, not exhaustive: releases group the changes that affect a
user or a contributor, and leave pure release-housekeeping (`chore(release):`,
checksum records, version bumps) out. Where a release carried a large volume of
fixes, they are grouped by area rather than listed one by one.

## [Unreleased]

### Fixed

- **Corrected the 1.7.6 release notes.** They described `sysv-rc` as an install
  blocker — "does not exist in any supported distribution" — which is false:
  the package is shipped by Debian 12 and 13 (`3.06-4`, `3.14-4`, arch `all`)
  and only ever appeared in `installDepsDebian`'s list, so it installed fine.
  The genuine blocker in that release was the OpenSSL mirror 404 with no
  official-source fallback. The GitHub Release body and the `[1.7.6]`
  CHANGELOG entry have both been corrected; two other claims were checked at
  the same standard and withdrawn (`_url_speed_curl` did not exist in v1.7.5
  at all, so nothing could call it undefined).

### Added

- **Static check #13**: `sysv-rc` must stay out of BOTH dependency lists, and
  each function's `pkgCommon` must stay where the guard reads it. v1.7.6
  removed the package but took its guard with it, and the guard that existed
  was watching the wrong variable — it asserted absence from the Ubuntu list
  while the entry sat in `installDepsDebian`'s, so it could never have fired.
  The check also fails itself when either function's `pkgCommon` is renamed or
  dropped, which is the only way it could otherwise go quietly inert (verified
  against four mutations: package reintroduced in either list, and `pkgCommon`
  renamed in either function).

## [1.7.6] - 2026-09-30

Two waves of work merged since v1.7.5. The headline is that **v1.7.5 could not
complete an install on a host using a China mirror**: the OpenSSL tarball was
requested from a mirror that does not carry upstream OpenSSL releases (that URL
404s), and `_dl` cleared `src_url_fallback`, so the 404 had nowhere to go but
`die_hard` and the `|| exit 1` that followed. Virtual-host management accounts
for 44% of the diff.

### Fixed

*Install and download, merged 2026-09-24/25:*

- **The OpenSSL download could only fail behind a China mirror.** The `_dl`
  call passed `${MIRROR_BASE_URL}/openssl/source/openssl-${openssl_ver}.tar.gz`,
  but the major China mirrors do not carry upstream OpenSSL releases — the URL
  returns HTTP 404 — and `_dl` set `src_url_fallback=""`, so there was no
  official-source retry before `die_hard` took the `|| exit 1` with it. OpenSSL
  is now official-source-only, and `_dl` records the official URL as a fallback
  so a mirror failure retries upstream instead of aborting the run.
- **The GitHub fallback path did not work from behind the GFW.** Five call
  sites fetched `raw.githubusercontent.com` / `github.com` bare, with no
  accelerator behind them: `install.sh --md5sum`'s md5 + sha256 lookups,
  `include/upgrade_script.sh`'s checksum fetch and tarball download, and
  `backup_setup.sh`'s qshell and dbxcli downloads. All five now go through
  `GITHUB_ACCELERATOR_URL` — official source first, accelerator only after it
  fails, so nothing changes for a host that can already reach GitHub.
- **Fallback downloads skipped integrity verification.** A package obtained
  from a mirror or the accelerator was unpacked and built without being
  checked, so the fallback was also the weakest link. Fallback downloads are
  verified like any other.
- **Archives fetched from GitHub unpacked into the wrong directory.** A
  GitHub auto-tag archive expands to `<repo>-<tag>`, not the release
  directory the build step expects, so a fallback-sourced source tree was
  invisible to `make`. `align_archive_top_dir()` repacks it before unpacking.
- **A mirror 404 was not treated as a failure**, so a 404 could be recorded as
  a completed download.
- **A redundant dependency was dropped**: `sysv-rc` is gone from
  `installDepsDebian`'s `pkgCommon`. It installed fine — the package exists in
  Debian 12 and 13 (`3.06-4`, `3.14-4`, arch `all`) and only ever appeared in
  the Debian list, which is the only one that ran it — so this is a cleanup,
  not a fix: `update-rc.d` already comes from `init-system-helpers`
  (`priority: required`). See the Changed entry for the guard that was
  supposed to be watching it.

*Virtual host management, 14 commits merged 2026-09-26 (+325/-114, 44% of
this release's diff):*

- **Let's Encrypt had four consecutive defects on the failure path.** The
  pre-flight check only warned and let the run continue; the post-failure
  cleanup covered some intermediate steps but not all, so a failed issuance
  left partial state behind; and the install-cert guards were broken at
  runtime. All three are fixed — a failed pre-flight now stops the run instead
  of warning past it.
- **A failed or deleted vhost could take down unrelated sites.** The shared
  rewrite templates under `conf/rewrite/` were removed along with the vhost,
  so every other site referencing that template started returning 500. They
  are no longer deleted on failure or on delete.
- **`ssl_stapling` was enabled unconditionally**, including for certificates
  with no OCSP responder of their own, where it slows the handshake and can
  fail it. It is now gated on the certificate's own responder.
- **A stale `https-redirect` block broke SSL vhost creation** — it referenced
  state that no longer existed at that point in the generated config. Dropped.
- **`acme-challenge` was caught by the HTTPS redirect**, so certificate
  renewal was blocked by the site's own 301. Exempted.
- **VeryNginx's injection was incomplete for proxied vhosts** — the
  `$vn_proxy_*` variables and the `@vn_proxy` location were missing, so a
  reverse-proxied site under WAF could not route. Both are now emitted.
- **Proxied vhost configs carried duplicate redirect and anti-hotlinking
  blocks.** Removed.
- **The magento2 rewrite branch used positional `sed` insertions** that broke
  when anything above them shifted. It now anchors on template markers.
- `https_flag` redirect insertions are now verified to have landed instead of
  being assumed to have.
- Domain extraction accepts arbitrary indentation, quotes and trailing
  comments; `Del_NGX_Vhost` reports the canonical path; proxied vhost deletion
  and its domain list were fixed.
- **CRLF line endings silently broke version loading.** A `download_sources.sh`
  or `vhost.sh` carrying CRLF made `load_versions` parse to empty values, so
  version numbers resolved to nothing. Line endings are normalised to LF, a
  static guard rejects a regression, and `.gitattributes` now pins
  `*.sh text eol=lf` so the editor cannot reintroduce it.

*Install, upgrade and backup correctness, merged earlier in this cycle:*

- **README documented the wrong database options in three places** — the
  component list was missing MySQL 9.7 and MariaDB 12.3, the `db_option`
  mapping had drifted from the actual menu, and the troubleshooting examples
  sent `--db_option 1` to MySQL 8.4 when the menu puts MySQL 9.7 there (and
  `--db_option 7` to MariaDB 10.11 under a MariaDB 8.0 label). All three are
  now derived from `install.sh`, and a new static check fails the build if
  they ever drift again.
- **`die_hard` killed the shell with `kill -9 $$`**, which aborted before any
  `EXIT` trap could run — so a failed install left its temporary directory and
  its decrypted-plaintext-password file behind. It now `exit 1`, preserving
  the caller's traps.
- **`trap ... EXIT` handlers built with SC2064 double quotes** expanded the
  paths at registration time rather than at exit, so a changed working
  directory sent the cleanup to the wrong place (3 sites in `backup_setup.sh`).
- **Unquoted `rm -rf` on the boost source directory** in the MySQL/MariaDB
  source-build path — now quoted both ways, with a guard so an empty boost
  version can never degrade into a bare `rm -rf boost_`.
- **`pkill -f` with a substring pattern** in the fail2ban teardown could match
  unrelated processes; switched to `pkill -x`.
- **`check_installed` was defined twice with opposite argument orders** — once
  in `include/common.sh`, once in `upgrade.sh`. Which one ran depended purely
  on which file was sourced last. The `upgrade.sh` copy is now
  `upgrade_target_installed`.
- **Dead `gcc < 5 -> redis_ver=6.2.14` branch** in `check_os.sh`: unreachable,
  since the OS gate only admits Debian 12/13 and Ubuntu 24.04/26.04 (gcc
  12/14/13/15), and it was a second, silently-diverging source of truth for a
  version `versions.txt` owns. Removed along with its `gcc` probe.
- **Four `eval`s removed** where plain assignment or a function call suffices:
  `update_versions.sh` (4 sites — variable reads now use `${!varname}`, and the
  sort command is chosen from a `case` whitelist), `install_db_common`'s
  `init_cmd` (now a real function callback, matching the two other callbacks in
  its own signature), and `vhost.sh`'s DNS API parameters (parsed and exported
  as one quoted word instead of `eval`'d).
- **Entrypoint scripts exited non-zero on success** where a bare `trap`/`popd`
  was the last statement.
- **PostgreSQL databases were never backed up.** `tools/db_bk.sh` only ever
  asked MySQL, and `db_install_dir` is never assigned on a PostgreSQL-only
  host (`include/check_dir.sh` derives it from the MySQL/MariaDB tree alone),
  so the existence probe ran against `/bin/mysql`, logged `[dbname] not exist`
  and set `backup_failed=1` — every scheduled run failed while backing up
  nothing. The engine is now chosen by a `detect_backup_engine` helper, and
  PostgreSQL is dumped with `pg_dump` over `127.0.0.1`, because `pg_hba.conf`
  runs both `local` and host lines in md5 mode and this script is root rather
  than the `postgres` role. The `-- Dump completed` truncation guard remains
  MySQL/MariaDB-only by design: `pg_dump` emits no footer, but its non-zero
  exit already rejects a full disk or a killed run. Adds 8 offline tests for
  the probe (123 → 131).
- **`upgrade.sh --db` claimed no database was installed on a PostgreSQL host.**
  `Upgrade_DB` probed `${db_install_dir}/bin/mysql`, which is never assigned on
  such a host, so a perfectly working PostgreSQL reported "MySQL/MariaDB is not
  installed on your system!" — indistinguishable from a box with nothing
  installed, and with no hint that PostgreSQL had been found but is
  unsupported. It now detects PostgreSQL first, names the running version, and
  points at `pg_dumpall` plus `pg_upgrade` / `pg_upgradecluster`. The upgrade
  itself is not implemented and is recorded under the README's roadmap. Adds 4
  offline tests (131 → 135).
- **Offline pre-downloads missed several installable database versions.**
  `sources.conf` carried `mariadb123`/`mariadb118` but nothing for MariaDB 11.4
  or 10.11, `mysql-src` was pinned to 9.7, and a single `postgresql` key
  resolved to `pgsql18_ver` — so `--db_option 6/7`, a source build of MySQL
  8.4/8.0 (`--dbinstallmethod 2`), and `--pgsql_ver` 17/16 all had nothing to
  pre-download and an offline install died on a missing source.
  `sources.conf` and `get_version` now agree on every version `install.sh` can
  choose, guarded by an 18-case matrix test (135 → 153).
- **`upgrade.sh` never validated the database or phpMyAdmin version it was
  given.** Each option's parser test is a *prefix* match
  (`^[0-9]+\.[0-9]+\.[0-9]+`, no trailing anchor), so `--db 8.4.3.1` is
  accepted by the parser and only `validate_version`'s anchored pattern can
  reject it — but `NEW_db_ver` and `NEW_phpmyadmin_ver` were never passed to
  it, while the other six parsed versions were. A malformed database version
  therefore reached the upgrade untouched (`--nginx 1.28.2.1` was correctly
  refused by the same layer). Both are now validated, and an 8-case guard
  asserts the invariant for every variable the parser fills from `$2`,
  leaving the two literal `=latest` assignments correctly exempt
  (153 → 161).
- **`download_common` contained no database.** `--common` is what
  `include/download.sh` tells you to run when a download fails, and it is
  advertised as "commonly used components", yet it held 22 web-side entries
  and not one database — so following that hint after a failed database
  download still left you unable to install the M in LNMP. It now carries the
  installer's default (`mysql97`, `db_option 1`); every other version stays a
  named download away. Two offline tests assert that the list resolves
  against `sources.conf` and that a database is present (161 → 163).
- **`install.sh --help` advertised a value the parser would refuse.**
  `--mphp_ver` rendered as `[83~5]`: the echo interpolated `PHP_MINOR_MIN`
  and `PHP_MINOR_MAX` with no second leading `8`, so the range read 83~5
  instead of 83~85 — and the parser's own rejection message repeated the
  typo ("Please only input number 83~5") while it accepts 83/84/85 (the
  test is `^8[3-5]$`, and `mphp_ver` is the install-dir suffix, e.g.
  `php84`). The help text also omitted `-V` and `-h|--help`, both accepted
  by the parser, so the help flag could not be discovered from `--help`
  itself.

### Changed

- **The `sysv-rc` static guard was removed along with the package, and it had
  been checking the wrong list.** The guard asserted the package was absent
  from `ubuntu_pkgs`; the entry it was written to police actually lived in
  `installDepsDebian`'s `pkgCommon`, so the guard could not have fired on it.
  The package is now gone from the tree, which left the guard with nothing to
  assert, so it was dropped rather than re-pointed. Nothing currently prevents
  `sysv-rc` being re-added — harmless while it stays in the Debian list, but a
  guard that watches the wrong variable is the actual defect here and is
  tracked separately.
- **shellcheck `warning` level is now a CI gate**, not advisory (28 findings →
  0). `info` level (252 findings) remains advisory so it can be burned down
  without blocking releases. The gate runs at `-S warning`.
- **`tools/mabs.sh`'s `eval set -- "$TEMP"` is kept and documented** — it is
  GNU getopt's own documented idiom, and the only way to get long options into
  positional parameters in bash. The quoting getopt emits is what makes it
  safe; a comment now records why it is the last `eval` in the tree.

### Added

- **Four GitHub-accelerator knobs in `options.conf`**:
  `GITHUB_ACCELERATOR_URL` (the fallback itself), plus
  `GITHUB_SPEED_MIN_KBPS`, `GITHUB_SPEED_TEST_SECONDS` and
  `GITHUB_SPEED_SAMPLE_BYTES` governing a new speed probe
  (`_url_speed_curl` in `download_sources.sh`, introduced together with its
  two call sites) that decides whether the accelerator is worth switching to.
  None of the four is documented in the README's mirror section yet.
- **Static check #12**: README's database documentation (component list,
  `db_option` mapping, example-command comments) must match the `install.sh`
  menu. Verified against four mutations of the historical bugs.
- **60 offline tests** (63 → 123) covering `db-common`, `php-common` and the
  `upgrade_*` chains — including the newly-added init callbacks, the boost
  cleanup guard, and both rollback paths' reversibility.
- **PHP and Redis upgrade chains** in the container upgrade smoke test
  (`upgrade.sh --php` / `--redis`), gated behind `UPGRADE_SMOKE_PHP` /
  `UPGRADE_SMOKE_REDIS` (default on), with the job timeout raised 120 → 240
  minutes to accommodate PHP's mandatory source recompile.
- Project governance docs: `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`
  and GitHub issue templates.
- **Complete `install.sh` parameter table in the README** — all 23 options the
  parser accepts, with their value ranges, defaults and per-option semantics
  (`--md5sum` verifies the installer script itself against upstream
  `md5sum.txt`, `--mphp_ver` takes `83`/`84`/`85`, `--dbrootpwd` feeds both
  the MySQL and the PostgreSQL superuser). The README previously showed a
  single example invocation, and 15 of those 23 options appeared nowhere in
  it — including `--help`.
- **CLI surface guard**: the `install.sh` parser, its `--help` text and the
  new README parameter table are asserted to list the same options, in both
  directions — `--help` used to omit `-V`/`-h`, and the help text advertised
  a `--mphp_ver` range the parser refuses (163 → 166).

## [1.7.5] - 2026-09-19

### Fixed

- Successful runs of `vhost.sh`, `uninstall.sh`, `pureftpd_vhost.sh` and
  `upgrade.sh` exited 1.
- **PGP verification was effectively a no-op** — it now matches the install
  path's behaviour. Upstream PGP keys are bundled so signature checks are real.
- `'cannot extract checksum'` was treated as a download passing.
- `disable_functions` shipped in a state that broke Composer and Laravel out of
  the box (`proc_open`, `symlink` and friends were disabled).
- `update_versions.sh`: `check_latest` defaulted to the first match rather than
  the version maximum.
- Health check reported a stale DB password as "connection failed", and failed
  on remote-only backups whose local artefact legitimately did not exist.
- Dropped `mhash` from the PHP build — emulated since PHP 7.4 and unbuildable
  under GCC 15.

### Added

- Health check: backup freshness and secret-file permission checks.
- Smoke test now covers the vhost lifecycle, backup roundtrip and Composer.

## [1.7.4] - 2026-09-18

### Fixed

- `check_system_resources` was never invoked before downloading.
- Mirror selection: `OUTIP_STATE == 'China'` was dead code, so the China mirror
  was never applied.
- MySQL/MariaDB source builds mishandled boost.
- `wget` failures in `verify_md5_with_retry` were not surfaced; archive
  integrity was only probed on cached re-entry, not first download.
- A bare `clear` with no `TERM` in all entry scripts.
- `upgrade_db` issued redundant `mysql_upgrade` calls.

### Changed

- phpMyAdmin upgrades are now reversible; `make install` errors are surfaced
  rather than swallowed.

## [1.7.3] - 2026-09-16

### Fixed

- Services are stopped before their binary is replaced, and `install`/`cp`
  failures are guarded.
- `upgrade_php`: `svc_stop` failure was unguarded and rollback was not
  reversible.
- `upgrade_web`: `ETXTBSY` when replacing a running Nginx binary.
- `update_versions.sh`: a downgrade was misreported as a major update, and rc
  builds were compared incorrectly.
- Backups were accepted as "restorable" on being merely non-empty.

### Added

- **Auto-rollback of a failed in-place DB upgrade.**
- One-click release workflow; `--md5sum` now also verifies sha256.
- actionlint on workflow files, plus an advisory shellcheck-warning ratchet.

## [1.7.2] - 2026-09-15

### Fixed

- **Detection of WSL2 kernels** (the previous field-split only matched WSL1).
- Non-numeric `ssh_port` input was accepted.
- Probe pages (`xprober`, `ocp`, `phpinfo`, `apc`) were reachable from
  anywhere; now localhost-only.
- Nginx was built with `-march=native`, producing binaries that could crash on
  a different CPU; now a portable `Release` build.
- Node checksum mismatch was non-fatal.
- A failed rebuild deleted the existing web installation.
- `run_step` ran every step in a subshell, silently losing variable
  assignments.

### Added

- **Support-policy gate**: releases older than Debian 12 / Ubuntu 24.04 are
  refused, with a decision table pinning the behaviour.
- Weekly CI smoke rotated across the supported distros, and a weekly
  version-bump PR.
- The L2 smoke layer (install → idempotent re-run → uninstall) running under a
  booted systemd image.

## [1.7.1] - 2026-09-10

The hardening release. Source builds previously ignored failures across the
board, and several paths reported success regardless of outcome.

### Fixed

- **Source builds ignored every failure** (`tar`, `cmake`, `configure`, `make`,
  `make install`); a failed build now aborts.
- **Installs reported "Congratulations" after a component failure.**
- A `Type=simple` unit that died immediately was still reported as started.
- `run_step` lost variable assignments (subshell).
- PostgreSQL was silently skipped in non-interactive installs, and its APT
  chain was broken with a password-after-md5 deadlock.
- The extension uninstall loop started at the wrong field and was a no-op for
  12 of 13 extensions.
- `disable_functions` broke Composer and Laravel by default.
- `vhost` deletion could wipe every site under `wwwroot`.
- Password validation/escaping flaws: `escape_password` did not escape `&`,
  `--dbrootpwd` was unvalidated, `reset_db_root_password` desynced
  `options.conf`, and the root password was unquoted in every `mysql`
  invocation.
- `sort -V` ranked rc builds above stable, so the Lua group always looked
  up-to-date; RC/Preview releases masqueraded as stable (PCRE2, MariaDB).
- Backup retention matched only one exact date and failures were silent;
  `db_bk.sh` used two separate `date` calls so `.sql` and `.tgz` could get
  different names.
- `health_check` always exited 0 even when checks failed.
- `upgrade.sh --script` corrupted passwords containing `&`/`|`.
- Removing one component deleted every PATH entry.

### Added

- **CI + shellcheck + static anti-regression checks + offline logic tests** —
  the test infrastructure the project is still extended by today.

## [1.7.0] - 2026-08-15

### Added

- MySQL 9.7 and MariaDB 12.3, with the database menu rearranged.
- `lua-cjson` built alongside Nginx and tracked by `update_versions.sh`.
- GeoIP2/MaxMind DB support (`libmaxminddb-dev`).
- VeryNginx WAF auto-included in new vhosts.

### Fixed

- PGP signature verification silently bypassed on missing `gpg`, failed
  verification, or download failure.
- Checksum verification returned 0 on download failure and callers ignored it.
- `blowfish_secret` generation could produce an empty string.

## [1.6.6] - 2026-06-21

### Added

- Brotli auto-enabled in `nginx.conf` after an upgrade.

## [1.6.5] - 2026-06-20

### Changed

- Default memory allocator switched from tcmalloc to jemalloc.

[Unreleased]: https://github.com/nengfeng/lnmp/compare/v1.7.6...HEAD
[1.7.6]: https://github.com/nengfeng/lnmp/compare/v1.7.5...v1.7.6
[1.7.5]: https://github.com/nengfeng/lnmp/compare/v1.7.4...v1.7.5
[1.7.4]: https://github.com/nengfeng/lnmp/compare/v1.7.3...v1.7.4
[1.7.3]: https://github.com/nengfeng/lnmp/compare/v1.7.2...v1.7.3
[1.7.2]: https://github.com/nengfeng/lnmp/compare/v1.7.1...v1.7.2
[1.7.1]: https://github.com/nengfeng/lnmp/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/nengfeng/lnmp/compare/v1.6.6...v1.7.0
[1.6.6]: https://github.com/nengfeng/lnmp/compare/v1.6.5...v1.6.6
[1.6.5]: https://github.com/nengfeng/lnmp/releases/tag/v1.6.5
