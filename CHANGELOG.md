# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries are curated, not exhaustive: releases group the changes that affect a
user or a contributor, and leave pure release-housekeeping (`chore(release):`,
checksum records, version bumps) out. Where a release carried a large volume of
fixes, they are grouped by area rather than listed one by one.

## [Unreleased]

Work merged after v1.7.5 and not yet cut into a release.

### Fixed

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

### Changed

- **shellcheck `warning` level is now a CI gate**, not advisory (28 findings →
  0). `info` level (252 findings) remains advisory so it can be burned down
  without blocking releases. The gate runs at `-S warning`.
- **`tools/mabs.sh`'s `eval set -- "$TEMP"` is kept and documented** — it is
  GNU getopt's own documented idiom, and the only way to get long options into
  positional parameters in bash. The quoting getopt emits is what makes it
  safe; a comment now records why it is the last `eval` in the tree.

### Added

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

[Unreleased]: https://github.com/nengfeng/lnmp/compare/v1.7.5...HEAD
[1.7.5]: https://github.com/nengfeng/lnmp/compare/v1.7.4...v1.7.5
[1.7.4]: https://github.com/nengfeng/lnmp/compare/v1.7.3...v1.7.4
[1.7.3]: https://github.com/nengfeng/lnmp/compare/v1.7.2...v1.7.3
[1.7.2]: https://github.com/nengfeng/lnmp/compare/v1.7.1...v1.7.2
[1.7.1]: https://github.com/nengfeng/lnmp/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/nengfeng/lnmp/compare/v1.6.6...v1.7.0
[1.6.6]: https://github.com/nengfeng/lnmp/compare/v1.6.5...v1.6.6
[1.6.5]: https://github.com/nengfeng/lnmp/releases/tag/v1.6.5
