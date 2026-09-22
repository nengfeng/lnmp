# Contributing to LNMP

Thanks for taking the time to contribute. This document describes how to work
on the project and what a change has to satisfy before it can land.

## Ground rules

This installer runs as **root** on someone's server. The bar is therefore not
"it looks right", it is "a regression is caught before it ships". Most of the
review comments you will see come down to one of two questions:

1. **How does this fail?** A build step, download or service start that can
   fail must be able to *say* it failed. Silently falling through and printing
   a success banner is the bug class this project has spent the most effort
   removing.
2. **How do we know?** Prefer a test, a static check, or a CI assertion over a
   comment claiming the behaviour is correct.

## Getting set up

You need `bash` and [`shellcheck`](https://www.shellcheck.net/) (the project
pins **0.10.0** in CI — `info`-level output differs between versions). Nothing
else: the offline tests stub every external command and touch no network.

```bash
git clone https://github.com/nengfeng/lnmp.git
cd lnmp
```

Note that the full install is only exercised inside a systemd-enabled
container by CI; a local machine is where you run the fast checks below.

## Before you push

These four commands are the merge gate. All must be clean.

```bash
# 1. syntax + project-specific anti-regression rules (12 checks)
bash tools/lint/static_checks.sh

# 2. offline logic tests (no network, no root needed)
bash tools/test_offline.sh

# 3. supported-OS policy gate, pinned by a decision table
bash tools/lint/os_gate_checks.sh

# 4. shellcheck, warning level and above
shellcheck -S warning $(find . -name '*.sh' -not -path './src/*')
```

The container workflows (`container-smoke`, `container-upgrade`, `lint`) run
automatically on your pull request; they build a systemd image and run a real
install, an idempotent re-run and an uninstall. They are slow (40-90 min for
smoke, up to ~140 min for upgrade) and rotate weekly across Debian 12/13 and
Ubuntu 24.04/26.04.

## Writing shell that passes

`.shellcheckrc` records *why* each disable is in place. Before adding a new
one, consider whether the underlying pattern is actually safe here — most
disables exist because the alternative (a subshell, or `find | while`) would
have broken something else.

Things this codebase is strict about:

- **Quote everything that could be empty or contain spaces**, but *not* globs
  you want expanded. `rm -rf "boost_${ver}"` is right;
  `rm -rf "mysql-${ver}-*"` silently stops matching anything.
- **No unguarded `eval`.** `tools/mabs.sh` keeps one — GNU getopt's documented
  idiom for long options — and the comment there explains why it is safe and
  why it is the last one. If you need one, expect to justify it in review.
- **Traps registered with `trap` must use the `CMD` form, not `trap "CMD" EXIT`**
  when the value should be expanded at exit rather than registration time.
- **Entry scripts must end on an explicit `exit`.** A script whose last
  statement is a `trap` or a `popd` inherits that command's exit status, which
  is how successful runs used to exit 1.
- **Don't duplicate a helper in two files.** `check_installed` existed in both
  `include/common.sh` and `upgrade.sh` with *opposite* argument orders; which
  one ran depended on sourcing order. It is now `upgrade_target_installed`.

### When you fix a bug, add the check that would have caught it

This is the part that matters most. The static checks and offline tests exist
because each corresponds to a bug that shipped. `static_checks.sh` has an
`[HARD]` section for anything that must never regress; a new rule belongs there
with a comment naming the bug it prevents, and ideally a **mutation test** in
your description showing it actually fires.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/), as used
throughout the history:

```
fix(cli): successful runs of vhost.sh exited 1
test(offline): cover the php rollback reversibility path
ci: boot systemd from a built image
chore(release): version 1.7.5
```

Types in use: `fix`, `feat`, `test`, `ci`, `docs`, `refactor`, `style`,
`chore`. The scope is optional but appreciated — `fix(php)`, `fix(upgrade_db)`,
`test(offline)` are common. Write the subject in the imperative mood, and use
the body when the *reason* is not obvious from the diff.

## Pull requests

- Keep one logical change per PR. A refactor that fixes a bug belongs in two
  commits, so the fix can be read on its own.
- Describe **how you tested it**. For changes CI cannot reach (anything
  needing a live systemd, or a distro-specific path), say what you ran and on
  what — and say plainly what you could *not* verify. An honest "untested
  because X" is fine; an unqualified "should work" is not.
- If your change makes an existing check stricter, mention how you confirmed
  the existing codebase passes it.
- Update `CHANGELOG.md` under `## [Unreleased]` for anything user-visible,
  following the grouping already used there (`Fixed` / `Changed` / `Added`).

## Project layout

```
install.sh / upgrade.sh / uninstall.sh   entry scripts (arg parsing, menus)
include/common.sh                        shared abstraction layer (svc, download, escaping)
include/db-common.sh                     MySQL + MariaDB via one install_db_common
include/php-common.sh                    PHP build/ini/fpm/service
include/upgrade_*.sh                     one upgrade chain per component
tools/lint/static_checks.sh              project-specific anti-regression rules
tools/lint/os_gate_checks.sh             supported-release policy gate
tools/test_offline.sh                    offline logic tests
tools/container/                         systemd image + smoke/upgrade harnesses
versions.txt                             single source of truth for component versions
```

`versions.txt` owns every component version. If you find a version number
hardcoded anywhere else — as `redis_ver=6.2.14` was, inside a dead `gcc` branch
— remove the copy rather than keeping both in sync.

## Reporting bugs

Use the issue templates. For anything that is a security concern rather than a
plain bug, please follow [SECURITY.md](SECURITY.md) instead of opening a public
issue.
