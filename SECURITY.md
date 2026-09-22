# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| 1.7.x   | ✅ latest release line |
| ≤ 1.6.x | ❌ |

Only the most recent release line receives fixes. `main` receives them first.

Because this project installs software as root, a fix for a reported issue is
normally released promptly rather than batched.

## Reporting a vulnerability

**Please do not open a public issue for a security vulnerability.**

Use GitHub's private reporting:

> **Security → Report a vulnerability** on this repository
> (`https://github.com/nengfeng/lnmp/security/advisories/new`)

If that is unavailable, open a minimal public issue saying only that you have
something to report and how to reach you, and **do not include details** — we
will make contact through a private channel first.

### What to include

- Which component and file are affected (`include/db-common.sh`, `vhost.sh`, …)
- The version or commit you tested against
- A reproduction: the command run, and what happened
- Impact — what an attacker gains, and under what preconditions
  (must the attacker already be a local user? does this require the installer
  to be mid-run?)
- Whether you have confirmed the issue on a release, or only on `main`

### What counts

In scope:

- Anything reachable from the installer's own attack surface: **command
  injection through passwords, hostnames, domain names or DNS provider
  credentials**; path traversal; unsafe `rm`/`mv` targets.
- **Supply-chain weaknesses** — a checksum or signature check that can be made
  to pass without actually verifying, a fallback mirror that skips
  verification, a stale or exposable plaintext credential file.
- Secrets or credentials written somewhere world-readable, or left behind
  after a failed run.
- Privilege escalation from the installed services.

Out of scope:

- Issues in upstream components themselves (Nginx, MySQL, PHP, …) — report
  those upstream.
- Findings that require an attacker to already have root on the host.
- The bundle of defaults we ship for convenience (default ports, sample vhost
  configuration) where they are documented as such.

## How we try to prevent these

Not a promise, but the areas that get explicit attention — useful context when
deciding whether your finding is novel:

- **Download integrity.** Every source archive is checked against `md5` and/or
  `sha256`, and where upstream publishes one, a **PGP signature** verified
  against keys bundled in the tree. A verification that cannot run is treated
  as a *failure*, not a pass — `VERIFY_CHECKSUM`, `verify_md5_with_retry` and
  the PGP path in `download_sources.sh` all exist because each once returned
  success while verifying nothing.
- **Shell injection.** `escape_password` and friends quote/escape values
  before they reach `mysql`, `sed` or a config file. `vhost.sh` validates DNS
  provider parameters against `export NAME=VALUE` and then *parses* them
  instead of `eval`'ing the line, so a loosened regular expression cannot
  become arbitrary code execution. There is intentionally no unguarded `eval`
  left in the tree.
- **Credentials at rest.** Root passwords live in `options.conf`; temporary
  plaintext from a reset is written to a file that an `EXIT` trap removes.
  (`die_hard` used to `kill -9` the shell, skipping that trap — that is fixed,
  and is the kind of interaction worth checking if you are auditing cleanup.)
- **PHP hardening.** `disable_functions` blocks command-execution functions,
  while deliberately leaving `proc_open`/`proc_get_status` enabled (Composer
  and Symfony Process cannot run without them) and `symlink`/`readlink`
  enabled (Laravel `storage:link` needs them). Probe pages such as `phpinfo`
  and `xprober` are bound to localhost.
- **Public debug tooling** is called out after an install so it can be removed
  on an internet-facing host.

## Disclosure expectations

We aim to acknowledge a report within **7 days**, and to publish a fix and
credit you (unless you prefer to remain anonymous) once it is released. If a
fix will take longer, we will tell you and agree a disclosure date before
publishing details.
