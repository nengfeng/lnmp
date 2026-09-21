#!/bin/bash
# Offline logic tests for the LNMP installer. No network, no real build.
# Stubs the external commands (wget, die_hard, fail_msg, ...) and asserts the
# shell LOGIC behaves correctly. Catches regressions in the exact bug classes
# fixed in v1.7.1 (swallowed downloads, allocator none/default, escaping, ...).
# Run: tools/test_offline.sh   (exits non-zero if any assertion fails)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
ko(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# ---- stubs / fixtures ----
current_dir="$work"
mkdir -p "$current_dir/src"
: > "$current_dir/download.log"
WGET_LOG="$work/wget.log"
CMSG=""; CEND=""; CWARNING=""; CSUCCESS=""; CFAILURE=""; CERROR=""; CYELLOW=""; CGREEN=""
# wget stub: record the call to a FILE (it runs in a pipeline subshell, so a
# global counter would be lost) and write a valid gzip to the -O target.
wget(){ echo "$*" >> "$WGET_LOG"; local out=""; while [ $# -gt 0 ]; do case "$1" in -O) out="$2";; esac; shift; done; [ -n "$out" ] && printf 'x' | gzip > "$out"; return 0; }
wget_calls(){ [ -f "$WGET_LOG" ] && wc -l < "$WGET_LOG" || echo 0; }
die_hard(){ echo "STUB die_hard: $*" >&2; exit 43; }
fail_msg(){ echo "STUB fail_msg: $*" >&2; }

# source the units under test, then re-stub the hard exitters
. "$ROOT/include/download.sh"
. "$ROOT/include/common.sh"
. "$ROOT/include/web-common.sh"
. "$ROOT/include/check_sw.sh"
die_hard(){ echo "STUB die_hard: $*" >&2; exit 43; }
fail_msg(){ echo "STUB fail_msg: $*" >&2; }

cd "$current_dir/src"

echo "== Download_src =="
printf 'x' | gzip > myfile.tar.gz
rm -f "$WGET_LOG"; src_url="http://bogus.invalid/x.tar.gz"; src_url_fallback=""; src_expected_dir=""
Download_src myfile.tar.gz >/dev/null 2>&1
[ "$(wget_calls)" -eq 0 ] && ok "valid cached file is not re-downloaded" || ko "expected no re-download (wget called $(wget_calls)x)"

rm -f "$WGET_LOG"; printf 'not a gzip' > myfile.tar.gz
Download_src myfile.tar.gz >/dev/null 2>&1
[ "$(wget_calls)" -ge 1 ] && ok "corrupt cache is re-downloaded" || ko "corrupt file did not trigger re-download"
gzip -t myfile.tar.gz >/dev/null 2>&1 && ok "re-downloaded file is a valid gzip" || ko "re-downloaded file is corrupt"

echo "== allocator (init_allocator) =="
cd "$current_dir"
unset allocator_ldflag allocator_so allocator_name allocator_option
allocator_option=1; init_allocator
[ -z "${allocator_ldflag}" ] && [ -z "${allocator_so}" ] && ok "option 1 (none) -> empty ldflag/so" || ko "none should leave flags empty"
[ "${allocator_ldflag--ljemalloc}" = "" ] && ok "none -> build flag contributes nothing" || ko "none leaked a build flag"
unset allocator_option; init_allocator
[ "$allocator_option" = "3" ] && [ "$allocator_ldflag" = "-ljemalloc" ] && ok "unset -> jemalloc default (matches options.conf)" || ko "default should be jemalloc (got opt=$allocator_option ldflag=$allocator_ldflag)"

echo "== escape_password =="
esc="$(escape_password 'a&b')"
[ "$esc" = 'a\&b' ] && ok "'&' is escaped for sed replacement" || ko "escape_password did not escape & (got [$esc])"

echo "== resolve_pkg_name / pkg_exists (t64 renames) =="
# Emulate the apt index faithfully; this is the distinction that killed the
# Ubuntu 24.04 preflight and, later, the debian:13 one. 'apt-cache show' answers
# for names the archive does not ship, and it is wrong in both directions:
#   REAL     -- the release ships it: stdout is the 'Package: <name>' stanza.
#   PROVIDED -- gone from the archive, but another package still Provides it
#               (libglib2.0-0t64 does for libglib2.0-0). Modeled as the hardest
#               false positive: the PROVIDER's stanza is printed and apt-cache
#               exits 0. (The debian:13 CI log shows the real thing is even
#               easier -- the rename to libglib2.0-0t64 fired under the old
#               exit-code test, so there no stanza is printed at all and the
#               exit is non-zero. Either way the requested name must not match.)
#   REFERRED -- gone, with no provider, only a stale dependency mention
#               (multiverse libodpic4 still Recommends libaio1). apt gets a
#               version-less placeholder, prints only an N: notice on stderr and
#               EXITS 0 -- which is how the old test passed libaio1 on Ubuntu
#               24.04 and let apt-get be the one to catch it.
# Neither the exit code nor the presence of *a* stanza decides it; only the
# requested name's own Package field does. The pre-2ee3e02 stub returned 1 for
# the last two cases, which is why every test passed while the distro run died.
REAL=" libaio1t64 libglib2.0-0t64 libncurses6 libidn-dev libaio-dev "
PROVIDED=" libglib2.0-0 "
REFERRED=" libaio1 "
apt-cache(){
  [ "$1" = "show" ] || return 1
  case " ${REAL} " in *" $2 "*) echo "Package: $2"; return 0 ;; esac
  case " ${PROVIDED} " in *" $2 "*) echo "Package: ${2}t64"; echo "Provides: $2"; return 0 ;; esac
  case " ${REFERRED} " in *" $2 "*) return 0 ;; esac   # exit 0, no stdout stanza
  return 1
}
pkg_exists libaio1t64 && ok "a package the release ships exists" || ko "real package not found"
if pkg_exists libglib2.0-0; then ko "a provider's stanza was taken for the requested package"; else ok "a provided-only name is not an existing package"; fi
if pkg_exists libaio1; then ko "a merely-referenced name was treated as an existing package"; else ok "a merely-referenced name is not an existing package"; fi
if pkg_exists absent-pkg; then ko "an absent name was treated as existing"; else ok "an absent name is not an existing package"; fi
[ "$(resolve_pkg_name libaio1)" = "libaio1t64" ] && ok "referenced-only old name resolves to its t64 name" || ko "t64 rename not resolved (got $(resolve_pkg_name libaio1))"
[ "$(resolve_pkg_name libglib2.0-0)" = "libglib2.0-0t64" ] && ok "provided-only old name resolves to its t64 name" || ko "libglib2.0-0 t64 rename not resolved"
[ "$(resolve_pkg_name libncurses6)" = "libncurses6" ] && ok "name shipped as-is is not rewritten" || ko "unchanged name was rewritten"
[ "$(resolve_pkg_name absent-pkg)" = "absent-pkg" ] && ok "unknown name is passed through so apt reports it" || ko "unknown name was rewritten"
REAL=" libaio1 libglib2.0-0 libidn-dev "
PROVIDED=""
REFERRED=""
[ "$(resolve_pkg_name libaio1)" = "libaio1" ] && ok "pre-t64 release keeps the original name" || ko "old name was rewritten on a pre-t64 release"

echo "== _extract_tar =="
cd "$current_dir/src"
rm -rf goodpkg-1.0 goodpkg-1.0.tar.gz
if _extract_tar "nonexistent-1.0.tar.gz"; then ko "missing tarball should fail"; else ok "missing tarball returns non-zero"; fi
mkdir -p goodpkg-1.0; echo hi > goodpkg-1.0/f.txt; tar czf goodpkg-1.0.tar.gz -C "$current_dir/src" goodpkg-1.0; rm -rf goodpkg-1.0
if _extract_tar "goodpkg-1.0.tar.gz"; then [ -d goodpkg-1.0 ] && ok "present tarball extracts ok" || ko "extracted dir missing"; else ko "present tarball should succeed"; fi

echo "== apt_install_packages (apt decides, apt-cache is advisory) =="
# apt-cache has answered "no such package" for names the archive really ships
# (Debian 13: libxml2, libxml2-dev, libevent-dev, libxslt1-dev, rsync), so the
# pre-check must not be able to fail the list. It only reports what apt-cache
# missed; apt-get's exit status decides. A package apt truly cannot install
# still fails the list, with apt's own error line naming it.
REAL=" libzip-dev "
REFERRED=" libaio1 "
APTGET_LOG="$work/aptget.log"
rm -f "$APTGET_LOG"
apt-cache(){
  [ "$1" = "show" ] || return 1
  case " ${REAL} " in *" $2 "*) echo "Package: $2"; return 0 ;; esac
  case " ${REFERRED} " in *" $2 "*) return 0 ;; esac   # exit 0, no stdout stanza
  return 1
}
apt-get(){
  echo "$*" >> "$APTGET_LOG"
  case " $* " in *" ghostpkg "*) echo "E: Unable to locate package ghostpkg" >&2; return 100 ;; esac
  return 0
}
out="$(apt_install_packages libzip-dev 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "all-known list installs cleanly" || ko "known-only list failed [$out]"
case "$out" in *"apt-cache does not list"*) ko "clean list raised a false advisory [$out]" ;; *) ok "clean list raises no advisory" ;; esac
out="$(apt_install_packages libaio1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "an apt-cache miss alone cannot fail the list" || ko "apt-cache miss failed the list [$out]"
case "$out" in *libaio1*) ok "the missed name is still surfaced for the log" ;; *) ko "missed name not reported [$out]" ;; esac
out="$(apt_install_packages ghostpkg 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a package apt cannot install fails the list" || ko "apt failure was accepted"
case "$out" in *"E: Unable to locate package ghostpkg"*) ok "apt's own error names the failing package" ;; *) ko "apt error missing [$out]" ;; esac
out="$(apt_install_packages libzip-dev ghostpkg 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a mixed list still fails on the apt failure" || ko "mixed list passed despite an apt failure"

echo "== check_download.sh PGP diagnostics (verify_pgp_signature) =="
# The install path now ships PGP keys in keys/ and imports them before
# checkDownload, so a gpg exit >= 2 (signer key not in keyring) is abnormal
# and must FAIL the component, not silently skip. On both failure paths the
# diagnostic lines gpg emits must reach the log - without them a friend's
# install dies with no explanation. The real verify_pgp_signature code path
# is driven offline with gpg stubbed; each stub emits the exact lines real
# gpg would for that outcome, keeping "tail -n 3" under test.
pgp_fix="$work/pgpfix"
mkdir -p "$pgp_fix/src"
printf 'payload\n' > "$pgp_fix/src/artifact.tar.gz"
: > "$pgp_fix/src/artifact.tar.gz.asc"
if command -v gpg >/dev/null 2>&1; then
  # The real function from the file under test
  . "$ROOT/include/check_download.sh" >/dev/null 2>&1
  # verify_pgp_signature no-ops unless VERIFY_CHECKSUM=yes - arm it for the
  # whole block, restore after.
  _pgp_verify_saved="${VERIFY_CHECKSUM-}"
  VERIFY_CHECKSUM=yes
  # Case 1: verified signature -> rc 0, no diagnostic emitted
  gpg(){ echo "gpg: Signature from LNMP PGP Fixture <pgpfix@test.invalid>"; echo "gpg: Good signature"; return 0; }
  out=$(cd "$pgp_fix/src" && verify_pgp_signature artifact.tar.gz "https://example.invalid/sig.asc" "pgpfix" 2>&1); rc=$?
  [ $rc -eq 0 ] && ok "good signature verifies (rc 0)" || ko "good signature failed: $out"
  # Case 2: BAD signature -> rc 1, gpg's diagnostic lines are shown
  gpg(){ echo "gpg: Signature made ..."; echo "gpg: Checking trust..."; echo "gpg: There is no assurance the signature is genuine"; return 1; }
  out=$(cd "$pgp_fix/src" && verify_pgp_signature artifact.tar.gz "https://example.invalid/sig.asc" "pgpfix" 2>&1); rc=$?
  [ $rc -ne 0 ] && ok "BAD signature fails the component" || ko "BAD signature accepted"
  case "$out" in *"There is no assurance"*) ok "BAD-signature failure shows gpg diagnostic" ;; *) ko "BAD-signature failure lost the gpg diagnostic: $out" ;; esac
  # Case 3: signer key not in keyring (gpg exit 2) -> rc 1, diagnostic shown
  gpg(){ echo "gpg: Can't check signature: No public key"; return 2; }
  out=$(cd "$pgp_fix/src" && verify_pgp_signature artifact.tar.gz "https://example.invalid/sig.asc" "pgpfix" 2>&1); rc=$?
  [ $rc -ne 0 ] && ok "unverifiable signature (gpg exit 2) fails, not skips" || ko "gpg exit 2 was skipped"
  case "$out" in *"No public key"*) ok "exit-2 failure shows gpg diagnostic (keyring gate is visible)" ;; *) ko "exit-2 failure lost the gpg diagnostic: $out" ;; esac
  VERIFY_CHECKSUM="${_pgp_verify_saved}"
  unset _pgp_verify_saved
else
  echo "  [SKIP] gpg unavailable, PGP diagnostics not exercised"
fi

echo "== svc_start liveness for Type=simple units =="
# The installer used to accept any unit whose `systemctl start` returned 0, but
# systemd reports a Type=simple unit as started the moment the process is forked
# -- so a service that died on the spot (missing .so, unusable config) was
# recorded as installed and the installer printed its success banner. Both
# php-fpm.service and the generated mysqld.service are Type=simple, and the
# latter sets Restart=on-failure, which parks a crashed unit in
# "activating/auto-restart" rather than "failed".
# systemd is stubbed here so the whole state table is covered deterministically
# in milliseconds; the container smoke job exercises the real thing.
sleep(){ :; }                       # the settle delay is not the logic under test
has_systemd(){ return 0; }
SVC_RC=0; IS_ACTIVE_RC=0; UNIT_TYPE=simple; UNIT_STATE=active; UNIT_SUB=running

_svc(){ return "${SVC_RC}"; }
systemctl(){
  case "$*" in
    "show -p Type --value "*)                printf '%s\n' "${UNIT_TYPE}" ;;
    "show -p ActiveState,SubState "*)        printf 'ActiveState=%s\nSubState=%s\n' "${UNIT_STATE}" "${UNIT_SUB}" ;;
    *"is-active"*)                           return "${IS_ACTIVE_RC}" ;;
    *)                                       return 0 ;;
  esac
}

UNIT_TYPE=simple;  svc_unit_is_simple probe && ok "Type=simple is gated for re-check"   || ko "simple not gated"
UNIT_TYPE=exec;    svc_unit_is_simple probe && ok "Type=exec is gated for re-check"     || ko "exec not gated"
UNIT_TYPE=notify;  svc_unit_is_simple probe && ko "notify wrongly gated"                || ok "notify is not gated"
UNIT_TYPE=forking; svc_unit_is_simple probe && ko "forking wrongly gated"               || ok "forking is not gated"
UNIT_TYPE="";      svc_unit_is_simple probe && ko "empty Type wrongly gated"            || ok "unknown Type is not gated"

# A Type=simple unit that stays up must still be accepted (a false failure here
# would abort every install).
UNIT_TYPE=simple; UNIT_STATE=active; UNIT_SUB=running; SVC_RC=0
svc_start probe >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "live Type=simple unit is accepted" || ko "live Type=simple unit rejected (rc=$rc)"

# ... one that died -> systemd leaves it failed -> must be rejected
UNIT_STATE=failed; UNIT_SUB=failed
svc_start probe >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "dead Type=simple unit is rejected" || ko "dead Type=simple unit accepted"

# ... one that is crash-looping under Restart= is parked in activating/auto-restart
UNIT_STATE=activating; UNIT_SUB=auto-restart
svc_start probe >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "unit queued for auto-restart is rejected" || ko "auto-restart unit accepted"

# ... but merely still activating (e.g. ExecStartPre) is not a death
UNIT_STATE=activating; UNIT_SUB=start
svc_start probe >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "still-activating unit is not treated as dead" || ko "activating unit rejected (rc=$rc)"

# Type=forking/notify: systemd validates those itself, so no re-check may run.
# The stubbed unit is dead, yet the old contract (trust the start status) holds.
UNIT_TYPE=forking; UNIT_STATE=inactive; UNIT_SUB=dead; SVC_RC=0
svc_start probe >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "forking unit keeps its old behaviour (no re-check)" || ko "forking unit got the Type=simple re-check"

# ... the pre-existing branch must survive: start timed out but process is alive
UNIT_TYPE=forking; UNIT_STATE=active; UNIT_SUB=running; SVC_RC=1; IS_ACTIVE_RC=0
svc_start probe >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "slow forking start that is really running still succeeds" || ko "running-but-timed-out service rejected (rc=$rc)"

# Without systemd the SysV `service` status is already meaningful -> skip re-check
has_systemd(){ return 1; }
UNIT_TYPE=simple; UNIT_STATE=failed; UNIT_SUB=failed; SVC_RC=0
svc_start probe >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "no systemd -> re-check is skipped" || ko "re-check ran without systemd"

# ---- PHP option window helpers (include/common.sh) ----
# Fixed window values: this tests the DERIVATION logic, not the current window.
PHP_OPTION_MAX=3; PHP_MINOR_MIN=3; PHP_MINOR_MAX=5
php83_ver=8.3.99; php84_ver=8.4.99; php85_ver=8.5.99

[ "$(php_supported_tags)" = "83 84 85" ] && ok "supported tags derive from MIN/MAX" || ko "php_supported_tags -> '$(php_supported_tags)'"
[ "$(php_tag_for_option 1)" = "83" ] && ok "option 1 -> tag 83" || ko "option 1 -> '$(php_tag_for_option 1)'"
[ "$(php_tag_for_option 3)" = "85" ] && ok "option 3 -> tag 85" || ko "option 3 -> '$(php_tag_for_option 3)'"
php_tag_for_option 4 >/dev/null 2>&1; [ $? -ne 0 ] && ok "option past MAX is refused" || ko "option past MAX accepted"
php_tag_for_option "" >/dev/null 2>&1; [ $? -ne 0 ] && ok "empty option is refused" || ko "empty option accepted"
[ "$(php_ver_for_tag 84)" = "8.4.99" ] && ok "php_ver_for_tag resolves the version variable" || ko "php_ver_for_tag 84 -> '$(php_ver_for_tag 84)'"
php_ver_for_tag 86 >/dev/null 2>&1; [ $? -ne 0 ] && ok "tag outside the window is refused" || ko "tag 86 accepted"
php_tag_is_supported 85 >/dev/null 2>&1; [ $? -eq 0 ] && ok "tag 85 supported" || ko "tag 85 refused"
php_tag_is_supported 86 >/dev/null 2>&1; [ $? -ne 0 ] && ok "tag 86 outside window refused" || ko "tag 86 accepted"
php_tag_is_supported 90 >/dev/null 2>&1; [ $? -ne 0 ] && ok "minor overflow (90) refused" || ko "tag 90 accepted"
[ "$(php_dotted_for_tag 85)" = "8.5" ] && ok "dotted form" || ko "php_dotted_for_tag 85 -> '$(php_dotted_for_tag 85)'"
_tag_a=85; _tag_b=84
[ "$(( 10#${_tag_a#8} ))" -ge "$PHP_OPCACHE_BUILTIN_MINOR" ] && [ "$(( 10#${_tag_b#8} ))" -lt "$PHP_OPCACHE_BUILTIN_MINOR" ] && ok "opcache-built-in boundary sits between 8.4 and 8.5" || ko "opcache built-in boundary wrong"
[ "$(php_ver_ge_84 8.3.9 && echo y || echo n)" = "n" ] && [ "$(php_ver_ge_84 8.4.0 && echo y || echo n)" = "y" ] && ok "php_ver_ge_84 boundary" || ko "php_ver_ge_84 boundary wrong"

# ---- PGP verification in download_sources.sh (asc branch) ----
# Real gpg with an isolated GNUPGHOME and a throwaway key, exercising the
# ACTUAL verify_checksum from download_sources.sh (sourced in a subshell; its
# main() is guarded so sourcing runs no downloads). Four outcomes are pinned:
# good signature passes, tampered file fails, missing key fails, gpg missing
# fails - the pre-download path must verify exactly as strictly as the
# install path does.
pgp_dir="$work/pgp"
mkdir -p "$pgp_dir/gnupg" "$pgp_dir/src" "$pgp_dir/keys"
chmod 700 "$pgp_dir/gnupg"
export GNUPGHOME="$pgp_dir/gnupg"
gpg --batch --passphrase '' --quick-gen-key "lnmp-offline-test <offline@test.invalid>" rsa2048 sign never >/dev/null 2>&1   && ok "throwaway gpg key generated" || ko "could not generate a throwaway gpg key"
printf 'payload-line
' > "$pgp_dir/src/artifact.tar.gz"
gpg --batch --yes --output "$pgp_dir/src/artifact.tar.gz.asc" --detach-sign "$pgp_dir/src/artifact.tar.gz" >/dev/null 2>&1   && ok "test artifact signed" || ko "could not sign the test artifact"
gpg --armor --export "offline@test.invalid" > "$pgp_dir/keys/test.asc" 2>/dev/null   && [ -s "$pgp_dir/keys/test.asc" ] && ok "public key exported for the keys/ fixture" || ko "could not export the public key"

pgp_run() {  # pgp_run <gnupghome> <keydir> -> rc of verify_checksum (asc)
  (
    set +e
    export GNUPGHOME="$1"
    cd "$ROOT" || exit 97
    . ./download_sources.sh >/dev/null 2>&1
    set +e
    LOG_FILE=/dev/null
    VERIFY_CHECKSUM=yes
    PGP_KEYS_DIR="$2"
    SRC_DIR="$pgp_dir/src"
    if [ "$2" != "nokeys" ]; then
      import_pgp_keys "$2" >/dev/null 2>&1 || exit 98
    fi
    verify_checksum "$SRC_DIR/artifact.tar.gz" "$SRC_DIR/artifact.tar.gz.asc" "asc" "artifact.tar.gz" >/dev/null 2>&1
  )
}

pgp_run "$GNUPGHOME" "$pgp_dir/keys"; pgp_rc=$?; [ "$pgp_rc" -eq 0 ]   && ok "good signature verifies (rc 0)" || ko "good signature rejected (rc=$pgp_rc)"

printf 'tampered
' >> "$pgp_dir/src/artifact.tar.gz"
pgp_run "$GNUPGHOME" "$pgp_dir/keys"; pgp_rc=$?; [ "$pgp_rc" -ne 0 ]   && ok "tampered file is rejected (BAD signature)" || ko "tampered file PASSED verification"
# restore the pristine artifact for the remaining cases
printf 'payload-line
' > "$pgp_dir/src/artifact.tar.gz"

pgp_dir_empty="$work/pgp-empty-keys"
mkdir -p "$pgp_dir_empty"
pgp_run "$GNUPGHOME" "$pgp_dir_empty"; pgp_rc=$?; [ "$pgp_rc" -ne 0 ]   && ok "missing keys/ directory fails verification" || ko "missing keys/ directory PASSED verification"

pgp_run "$work/pgp/no-such-home" "$pgp_dir/keys"; pgp_rc=$?; [ "$pgp_rc" -ne 0 ]   && ok "signer key not in keyring fails verification (gpg exit 2)" || ko "unverifiable signature PASSED"

(
  set +e
  export GNUPGHOME="$GNUPGHOME"
    cd "$ROOT" || exit 97
    . ./download_sources.sh >/dev/null 2>&1
    set +e
    LOG_FILE=/dev/null
    command(){ if [ "$1" = "-v" ] && [ "$2" = "gpg" ]; then return 1; else builtin command "$@"; fi; }
    SRC_DIR="$pgp_dir/src"
    verify_checksum "$SRC_DIR/artifact.tar.gz" "$SRC_DIR/artifact.tar.gz.asc" "asc" "artifact.tar.gz" >/dev/null 2>&1
)
pgp_rc=$?
[ "$pgp_rc" -ne 0 ] && ok "missing gpg fails verification instead of passing" || ko "missing gpg PASSED verification"
unset GNUPGHOME

echo ""
echo "Offline tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
