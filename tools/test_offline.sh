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
  # Drop the stub so the pre-download PGP block below can use the real gpg
  # binary - a left-behind function would shadow /usr/bin/gpg and break it.
  unset -f gpg
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
UNIT_TYPE='exec';  svc_unit_is_simple probe && ok "Type=exec is gated for re-check"     || ko "exec not gated"
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

# ---- db-common / php-common / upgrade_* : previously untested units ----
# Sourced from $ROOT because upgrade_web.sh and upgrade_db.sh carry their own
# RELATIVE `. include/...` lines, which only resolve when cwd is the repo root.
pushd "$ROOT" > /dev/null || exit 97
. ./include/db-common.sh
. ./include/php-common.sh
. ./include/upgrade_web.sh     # re-pulls include/common.sh
. ./include/upgrade_php.sh
. ./include/upgrade_db.sh      # re-pulls include/db-common.sh
popd > /dev/null
# Sourcing pulled common.sh in again and redefined the hard exitters - restore
# the stubs exactly as the block at the top of this file does.
die_hard(){ echo "STUB die_hard: $*" >&2; exit 43; }
fail_msg(){ echo "STUB fail_msg: $*" >&2; }

echo "== set_ld_opt (include/upgrade_web.sh) =="
# The bug class this function exists for: rewriting --with-ld-opt with
# `sed s@--with-ld-opt=[^ ]*@...@` stops at the first space, so an ld-opt whose
# value holds several tokens (the allocator supplies exactly that) left the
# tail of the OLD value stranded in the configure string.
_ld_args='--prefix=/usr/local/nginx --with-ld-opt=-L/usr/local/lib -Wl,-u,pcre_version --with-http_ssl_module'
got=$(set_ld_opt "$_ld_args" "-Wl,-rpath,/opt/lib")
want='--prefix=/usr/local/nginx --with-ld-opt=-Wl,-rpath,/opt/lib --with-http_ssl_module'
[ "$got" = "$want" ] && ok "multi-token old value fully replaced, no orphaned tail" || ko "got [$got]"
got=$(set_ld_opt "$_ld_args" "")
want='--prefix=/usr/local/nginx --with-http_ssl_module'
[ "$got" = "$want" ] && ok "empty new value drops --with-ld-opt entirely" || ko "got [$got]"
got=$(set_ld_opt "--with-ld-opt=-old --with-http_ssl_module" "-new")
[ "$got" = "--with-ld-opt=-new --with-http_ssl_module" ] && ok "single-token value replaced" || ko "got [$got]"
# Contract: set_ld_opt only ever REMOTES/REPLACES. Appending when the flag is
# absent is the CALLER's job (upgrade_web.sh checks the result and appends), so
# a no-op here is correct - pin it so a future "helpful" append cannot silently
# double the flag next to the caller's own append.
got=$(set_ld_opt "--prefix=/opt/x --with-http_v2_module" "-L/foo")
[ "$got" = "--prefix=/opt/x --with-http_v2_module" ] && ok "absent flag is left alone (caller appends)" || ko "got [$got]"

echo "== cleanup_mysql_files / cleanup_mariadb_files (include/db-common.sh) =="
_cdir="$work/cleanup"; mkdir -p "$_cdir"; pushd "$_cdir" > /dev/null
export SYS_ARCH_M=x86_64
mkdir -p "mysql-8.4.11-linux-glibc2.28-x86_64" keepme boost_1_85_0 boost_9_9_9
cleanup_mysql_files "8.4.11" "1" >/dev/null 2>&1
[ ! -d "mysql-8.4.11-linux-glibc2.28-x86_64" ] && ok "method 1: glob'd binary tree removed" || ko "method 1 left the tree behind"
[ -d keepme ] && ok "method 1: unrelated dir untouched" || ko "method 1 removed something it should not"
# method 2 must take the boost dir THAT VERSION extracted and leave every other
# boost_* alone - the old unquoted form interpolated whatever was in the var.
cleanup_mysql_files "8.4.11" "2" "1.85.0" >/dev/null 2>&1
[ ! -d boost_1_85_0 ] && ok "method 2: matching boost dir removed" || ko "method 2 left boost_1_85_0"
[ -d boost_9_9_9 ] && ok "method 2: non-matching boost dir preserved" || ko "method 2 deleted boost_9_9_9"
# Regression guard for the empty-boost case: with boost_ver unset the guard
# must short-circuit BEFORE rm, so an unrelated boost_* is never in reach.
mkdir -p "mysql-8.4.11" boost_9_9_9
cleanup_mysql_files "8.4.11" "2" "" >/dev/null 2>&1
[ ! -d "mysql-8.4.11" ] && ok "method 2: tree removed even with empty boost_ver" || ko "empty boost_ver blocked the tree cleanup"
[ -d boost_9_9_9 ] && ok "empty boost_ver does NOT reach any boost_* dir" || ko "empty boost_ver deleted boost_9_9_9"
# NOTE the '-linux-systemd-' infix: mariadb's binary tarball layout differs
# from mysql's (mysql-<ver>-*-<arch>), so a test that omits it matches nothing
# and would pass vacuously while the real cleanup path went untested.
mkdir -p "mariadb-11.4.13-linux-systemd-x86_64"
cleanup_mariadb_files "11.4.13" "1" >/dev/null 2>&1
[ ! -d "mariadb-11.4.13-linux-systemd-x86_64" ] && ok "mariadb method 1: tree removed" || ko "mariadb method 1 left the tree"
popd > /dev/null

echo "== init_mysql_data / init_mariadb_data (include/db-common.sh) =="
# These are the two callbacks that replaced the old `eval "${init_cmd}"` string
# path. They take NO arguments - every path is read from the globals - so the
# only thing worth pinning is that the binary receives exactly the basedir and
# datadir it should. A fake binary records its argv.
_idir="$work/initdb"; mkdir -p "$_idir/bin" "$_idir/scripts" "$_idir/data"
_ARGLOG="$_idir/argv"
for _fake in "$_idir/bin/mysqld" "$_idir/scripts/mysql_install_db"; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s"\nexit 0\n' "$_ARGLOG" > "$_fake"
  chmod +x "$_fake"
done
mysql_install_dir="$_idir"; mysql_data_dir="$_idir/data"
init_mysql_data >/dev/null 2>&1; _rc=$?
[ $_rc -eq 0 ] && ok "init_mysql_data exits 0" || ko "init_mysql_data rc=$_rc"
grep -qx -- "--initialize-insecure" "$_ARGLOG" && ok "mysqld got --initialize-insecure" || ko "missing --initialize-insecure"
grep -qx -- "--user=mysql" "$_ARGLOG" && ok "mysqld got --user=mysql" || ko "missing --user=mysql"
grep -qx -- "--basedir=$_idir" "$_ARGLOG" && ok "mysqld basedir = mysql_install_dir" || ko "wrong basedir: $(tr '\n' ' ' < "$_ARGLOG")"
grep -qx -- "--datadir=$_idir/data" "$_ARGLOG" && ok "mysqld datadir = mysql_data_dir" || ko "wrong datadir: $(tr '\n' ' ' < "$_ARGLOG")"
# init_mariadb_data reads mariadb_data_dir (NOT mysql_data_dir): setting only
# the mysql one leaves --datadir empty, which the assertion below catches.
mariadb_install_dir="$_idir"; mariadb_data_dir="$_idir/data"
init_mariadb_data >/dev/null 2>&1; _rc=$?
[ $_rc -eq 0 ] && ok "init_mariadb_data exits 0" || ko "init_mariadb_data rc=$_rc"
grep -qx -- "--user=mysql" "$_ARGLOG" && ok "mysql_install_db got --user=mysql" || ko "missing --user=mysql"
grep -qx -- "--basedir=$_idir" "$_ARGLOG" && ok "mysql_install_db basedir = mariadb_install_dir" || ko "wrong basedir"
grep -qx -- "--datadir=$_idir/data" "$_ARGLOG" && ok "mysql_install_db datadir = mysql_data_dir" || ko "wrong datadir"
unset mysql_install_dir mysql_data_dir mariadb_install_dir mariadb_data_dir

echo "== config_my_cnf_memory (include/db-common.sh) =="
_mkcnf(){ printf 'innodb_buffer_pool_size = 8G\nmax_connections = 999\n' > "$1"; }
_grepval(){ grep -E "^$2" "$1" | head -1; }
_mkcnf "$work/c.cnf"; config_my_cnf_memory "$work/c.cnf" 512 >/dev/null 2>&1
[ "$(_grepval "$work/c.cnf" innodb_buffer_pool_size)" = "innodb_buffer_pool_size = 128M" ] && ok "512M box -> buffer pool 128M" || ko "got [$(_grepval "$work/c.cnf" innodb_buffer_pool_size)]"
[ "$(_grepval "$work/c.cnf" max_connections)" = "max_connections = 20" ] && ok "512M box -> max_connections 20" || ko "got [$(_grepval "$work/c.cnf" max_connections)]"
_mkcnf "$work/c.cnf"; config_my_cnf_memory "$work/c.cnf" 1024 >/dev/null 2>&1
[ "$(_grepval "$work/c.cnf" max_connections)" = "max_connections = 20" ] && ok "boundary 1024 still uses the low-memory branch (-le)" || ko "got [$(_grepval "$work/c.cnf" max_connections)]"
_mkcnf "$work/c.cnf"; config_my_cnf_memory "$work/c.cnf" 1025 >/dev/null 2>&1
[ "$(_grepval "$work/c.cnf" innodb_buffer_pool_size)" = "innodb_buffer_pool_size = 512M" ] && ok "1025M steps up to the 1-2G branch" || ko "got [$(_grepval "$work/c.cnf" innodb_buffer_pool_size)]"
_mkcnf "$work/c.cnf"; config_my_cnf_memory "$work/c.cnf" 2048 >/dev/null 2>&1
[ "$(_grepval "$work/c.cnf" max_connections)" = "max_connections = 50" ] && ok "boundary 2048 still in the 1-2G branch" || ko "got [$(_grepval "$work/c.cnf" max_connections)]"
_mkcnf "$work/c.cnf"; config_my_cnf_memory "$work/c.cnf" 8192 >/dev/null 2>&1
[ "$(_grepval "$work/c.cnf" innodb_buffer_pool_size)" = "innodb_buffer_pool_size = 8G" ] && ok "8G box: no override (branches are <=2G only)" || ko "8G box was rewritten to [$(_grepval "$work/c.cnf" innodb_buffer_pool_size)]"

echo "== config_php_fpm_pool (include/php-common.sh) =="
_mkfpm(){ mkdir -p "$1/etc"; { echo "pm.max_children = 1"; echo "pm.start_servers = 1"; echo "pm.min_spare_servers = 1"; echo "pm.max_spare_servers = 1"; echo "rlimit_files = 1024"; } > "$1/etc/php-fpm.conf"; }
_fpmval(){ grep -E "^$2" "$1/etc/php-fpm.conf" | head -1; }
# VPS tier: the <=1024 / <=2048 / <=3000 thresholds and the arithmetic branch
_mkfpm "$work/f1"; config_php_fpm_pool "$work/f1" 1024 vps >/dev/null 2>&1
[ "$(_fpmval "$work/f1" pm.max_children)" = "pm.max_children = 5" ] && ok "vps 1G -> max_children 5" || ko "got [$(_fpmval "$work/f1" pm.max_children)]"
[ "$(_fpmval "$work/f1" rlimit_files)" = "rlimit_files = 1024" ] && ok "vps tier does not touch rlimit_files" || ko "vps tier rewrote rlimit_files"
_mkfpm "$work/f2"; config_php_fpm_pool "$work/f2" 2048 vps >/dev/null 2>&1
[ "$(_fpmval "$work/f2" pm.max_children)" = "pm.max_children = 10" ] && ok "vps 2G -> max_children 10" || ko "got [$(_fpmval "$work/f2" pm.max_children)]"
_mkfpm "$work/f3"; config_php_fpm_pool "$work/f3" 3000 vps >/dev/null 2>&1
# 3000/3/20 = 50
[ "$(_fpmval "$work/f3" pm.max_children)" = "pm.max_children = 50" ] && ok "vps 3000M -> arithmetic branch yields 50" || ko "got [$(_fpmval "$work/f3" pm.max_children)]"
# Dedicated tier: separate thresholds, and it DOES raise rlimit_files
_mkfpm "$work/f4"; config_php_fpm_pool "$work/f4" 4000 dedicated >/dev/null 2>&1
[ "$(_fpmval "$work/f4" pm.max_children)" = "pm.max_children = 80" ] && ok "dedicated 4G -> max_children 80" || ko "got [$(_fpmval "$work/f4" pm.max_children)]"
[ "$(_fpmval "$work/f4" rlimit_files)" = "rlimit_files = 65535" ] && ok "dedicated tier raises rlimit_files to 65535" || ko "got [$(_fpmval "$work/f4" rlimit_files)]"
_mkfpm "$work/f5"; config_php_fpm_pool "$work/f5" 8000 dedicated >/dev/null 2>&1
[ "$(_fpmval "$work/f5" pm.max_children)" = "pm.max_children = 120" ] && ok "dedicated boundary 8000 -> 120 (-le)" || ko "got [$(_fpmval "$work/f5" pm.max_children)]"
_mkfpm "$work/f6"; config_php_fpm_pool "$work/f6" 17000 dedicated >/dev/null 2>&1
[ "$(_fpmval "$work/f6" pm.max_children)" = "pm.max_children = 300" ] && ok "dedicated 17G -> max_children 300" || ko "got [$(_fpmval "$work/f6" pm.max_children)]"
_mkfpm "$work/f7"; config_php_fpm_pool "$work/f7" 2048 >/dev/null 2>&1
[ "$(_fpmval "$work/f7" pm.max_children)" = "pm.max_children = 10" ] && ok "scenario defaults to vps when omitted" || ko "got [$(_fpmval "$work/f7" pm.max_children)]"

echo "== generate_php_ini / generate_opcache_ini (include/php-common.sh) =="
_pdir="$work/php"; mkdir -p "$_pdir/etc/php.d"
{ echo "memory_limit = 128M"; echo "output_buffering = 4096"; echo "short_open_tag = Off"; echo "expose_php = On"; echo "request_order = GP"; echo ";date.timezone ="; echo "post_max_size = 8M"; echo "upload_max_filesize = 2M"; echo "max_execution_time = 30"; echo ";realpath_cache_size = 4K"; echo "disable_functions ="; } > "$_pdir/etc/php.ini"
Memory_limit=256; timezone=Asia/Shanghai; with_old_openssl_flag=n
generate_php_ini "$_pdir" >/dev/null 2>&1
grep -q '^memory_limit = 256M' "$_pdir/etc/php.ini" && ok "memory_limit follows Memory_limit" || ko "got [$(grep '^memory_limit' "$_pdir/etc/php.ini")]"
grep -q '^date.timezone = Asia/Shanghai' "$_pdir/etc/php.ini" && ok "date.timezone follows timezone" || ko "got [$(grep 'date.timezone' "$_pdir/etc/php.ini")]"
grep -q '^expose_php = Off' "$_pdir/etc/php.ini" && ok "expose_php hardened to Off" || ko "expose_php not hardened"
# proc_open / symlink must NOT be in disable_functions: Symfony Process and
# Laravel storage:link both die without them (that was a real breakage).
grep -q '^disable_functions = .*proc_open' "$_pdir/etc/php.ini" && ko "proc_open must stay ENABLED (Composer/Symfony Process dies without it)" || ok "proc_open absent from disable_functions (Composer works)"
grep -q '^disable_functions = .*pcntl_fork' "$_pdir/etc/php.ini" && ok "pcntl_* still disabled" || ko "pcntl_* no longer disabled"
grep -q '^disable_functions = .*symlink' "$_pdir/etc/php.ini" && ko "symlink must stay ENABLED (Laravel storage:link)" || ok "symlink absent from disable_functions"
# opcache: option 1 writes, anything else writes nothing
rm -f "$_pdir/etc/php.d/02-opcache.ini"
phpcache_option=1; Memory_limit=256
generate_opcache_ini "$_pdir" >/dev/null 2>&1
[ -f "$_pdir/etc/php.d/02-opcache.ini" ] && ok "phpcache_option=1 writes 02-opcache.ini" || ko "opcache ini not written"
grep -q '^opcache.memory_consumption=256' "$_pdir/etc/php.d/02-opcache.ini" && ok "opcache memory_consumption follows Memory_limit" || ko "got [$(grep memory_consumption "$_pdir/etc/php.d/02-opcache.ini" 2>/dev/null)]"
grep -q '^zend_extension=opcache.so' "$_pdir/etc/php.d/02-opcache.ini" && ok "default zend_extension is opcache.so" || ko "wrong zend_extension"
rm -f "$_pdir/etc/php.d/02-opcache.ini"
phpcache_option=2
generate_opcache_ini "$_pdir" >/dev/null 2>&1
[ ! -f "$_pdir/etc/php.d/02-opcache.ini" ] && ok "phpcache_option=2 writes nothing" || ko "option 2 wrote an opcache ini"
# an explicitly supplied zend_extension must win over the default opcache.so
phpcache_option=1; rm -f "$_pdir/etc/php.d/02-opcache.ini"; generate_opcache_ini "$_pdir" "opcache.ext.so" >/dev/null 2>&1
grep -q '^zend_extension=opcache.ext.so' "$_pdir/etc/php.d/02-opcache.ini" && ok "explicit zend_extension argument wins" || ko "explicit zend_extension ignored"
unset phpcache_option

echo "== _php_rollback (include/upgrade_php.sh) =="
# The property this rollback was rewritten for: it must be REVERSIBLE. The old
# `rm -rf $php_install_dir && cp -a backup ...` destroyed the install before
# the restore was known to work, so a failed restore (disk full) left nothing.
# pidof/wait_for_db_ready ARE stubbed; svc_start/svc_stop deliberately are not.
# The two functions under test never read svc_*'s exit status (_php_rollback
# returns 0 unconditionally after the call, rollback_db_upgrade branches solely
# on wait_for_db_ready), so stubbing them would buy nothing - and a svc_start
# defined HERE is exactly what SC2218 rejects: svc_start is already called
# directly at line ~221 by the Type=simple liveness tests, which need the REAL
# common.sh implementation. Any later redefinition flags those earlier calls.
pidof(){ return 1; }
_php_install="$work/php_install"; _php_backup="$work/php_backup"
mkdir -p "$_php_install" "$_php_backup"; echo broken > "$_php_install/state"; echo good > "$_php_backup/state"
php_install_dir="$_php_install"; backup_php_dir="$_php_backup"; BACKUP_DIR="$work/bk"; CYELLOW=""; CFAILURE=""; CEND=""
_php_rollback >/dev/null 2>&1; _rc=$?
[ $_rc -eq 0 ] && ok "rollback succeeds when the backup restores" || ko "rollback rc=$_rc"
[ "$(cat "$_php_install/state" 2>/dev/null)" = "good" ] && ok "install dir now holds the backup content" || ko "install dir holds [$(cat "$_php_install/state" 2>/dev/null)]"
ls -d "$_php_install".broken_* >/dev/null 2>&1 && ok "broken install preserved for inspection (not deleted)" || ko "broken install was deleted, nothing to inspect"
# Failure path: restore fails -> the ORIGINAL must be moved back, not lost.
# Clear .broken_* first: the suffix is date +%m%d%H%M%S (one-second resolution),
# so a second rollback landing in the same second as the first would have
# /bin/mv -f move this install INTO the still-existing first broken dir, and the
# revert would then restore the wrong content. Real rollbacks are minutes apart;
# the test is not, so it must scrub the namespace itself.
rm -rf "$_php_install".broken_*
rm -rf "$_php_install"; mkdir -p "$_php_install"; echo broken2 > "$_php_install/state"
backup_php_dir="$work/does-not-exist"
_php_rollback >/dev/null 2>&1; _rc=$?
[ $_rc -ne 0 ] && ok "rollback reports failure when the backup is missing" || ko "rollback claimed success with no backup"
[ "$(cat "$_php_install/state" 2>/dev/null)" = "broken2" ] && ok "failed restore is undone: original moved back (reversible)" || ko "original content lost on failed restore: [$(cat "$_php_install/state" 2>/dev/null)]"
unset php_install_dir backup_php_dir BACKUP_DIR

echo "== rollback_db_upgrade (include/upgrade_db.sh) =="
# The invariants: a missing *_old_<ts> backup must abort with rc!=0 and say so,
# and a rollback whose old server won't come back must also fail loudly rather
# than report success over a dead database.
wait_for_db_ready(){ return 0; }
_dbi="$work/dbinstall"; _dbd="$work/dbdata"
DB=MySQL; OLD_db_ver="8.4.10"; CSUCCESS=""; CFAILURE=""; CEND=""
rm -rf "$_dbi" "$_dbd"; mkdir -p "$_dbi" "$_dbd" "${_dbi}_old_20250101" "${_dbd}_old_20250101"
rollback_db_upgrade "$_dbi" "$_dbd" "20250101" > "$work/rb1.log" 2>&1; _rc=$?
[ $_rc -eq 0 ] && ok "rollback succeeds with both backups present" || ko "rollback rc=$_rc: $(cat "$work/rb1.log")"
[ -d "$_dbi" ] && [ ! -d "${_dbi}_old_20250101" ] && ok "old install tree moved back into place" || ko "install tree not restored"
[ -d "$_dbd" ] && [ ! -d "${_dbd}_old_20250101" ] && ok "old data dir moved back into place" || ko "data dir not restored"
rm -rf "$_dbi" "$_dbd" "${_dbi}_old_"* "${_dbd}_old_"*; mkdir -p "$_dbi" "$_dbd"
rollback_db_upgrade "$_dbi" "$_dbd" "20250102" > "$work/rb2.log" 2>&1; _rc=$?
[ $_rc -ne 0 ] && ok "rollback aborts when the *_old_* install tree is absent" || ko "rollback reported success with no backup tree"
grep -q 'Rollback failed' "$work/rb2.log" && ok "missing-backup failure is reported to the user" || ko "no 'Rollback failed' message: $(cat "$work/rb2.log")"
rm -rf "$_dbi" "$_dbd" "${_dbi}_old_"* ; mkdir -p "$_dbi" "$_dbd" "${_dbi}_old_20250103"
rollback_db_upgrade "$_dbi" "$_dbd" "20250103" > "$work/rb3.log" 2>&1; _rc=$?
[ $_rc -ne 0 ] && ok "rollback aborts when the *_old_* data dir is absent" || ko "rollback reported success with no data backup"
wait_for_db_ready(){ return 1; }
rm -rf "$_dbi" "$_dbd"; mkdir -p "$_dbi" "$_dbd" "${_dbi}_old_20250104" "${_dbd}_old_20250104"
rollback_db_upgrade "$_dbi" "$_dbd" "20250104" > "$work/rb4.log" 2>&1; _rc=$?
[ $_rc -ne 0 ] && ok "rollback fails when the restored server will not start" || ko "reported success over a database that cannot start"
grep -q 'could not be restarted' "$work/rb4.log" && ok "unstartable-restore failure names the cause" || ko "message missing: $(cat "$work/rb4.log")"
grep -Fq "$_dbi" "$work/rb4.log" && grep -Fq "$_dbd" "$work/rb4.log" && ok "failure message points at the restored install and data dirs" || ko "restored data location not mentioned in: $(cat "$work/rb4.log")"
rm -rf "$_dbi" "$_dbd" "${_dbi}_old_"* "${_dbd}_old_"*
unset -f wait_for_db_ready pidof

echo "== detect_backup_engine (include/check_dir.sh) =="
# The bug this function exists for: on a PostgreSQL-only host db_install_dir
# is EMPTY (check_dir.sh only ever assigns it from a MySQL/MariaDB tree), so
# the old tools/db_bk.sh built "/bin/mysql", the existence probe never matched
# and every PostgreSQL database was reported as missing - i.e. never backed up.
pushd "$ROOT" > /dev/null || exit 97
. ./include/check_dir.sh
popd > /dev/null

_eng="$work/engine"; rm -rf "$_eng"
_mk_mysqldump(){ mkdir -p "$1/bin"; : > "$1/bin/mysqldump"; chmod +x "$1/bin/mysqldump"; }
_mk_pgsql(){ mkdir -p "$1/bin"; : > "$1/bin/pg_dump"; : > "$1/bin/psql"; chmod +x "$1/bin/pg_dump" "$1/bin/psql"; }

# The exact failing shape: no MySQL/MariaDB dir at all, so the first argument
# is the empty string a PostgreSQL-only box really passes.
_mk_pgsql "$_eng/pgsql"
got=$(detect_backup_engine "" "$_eng/pgsql"); _rc=$?
[ "$got" = "pgsql" ] && [ $_rc -eq 0 ] && ok "PostgreSQL-only host selects pgsql (db_install_dir empty)" || ko "got [$got] rc=$_rc"

# Nothing installed at all must be an explicit, non-zero answer - the caller
# turns "none" into a logged failure instead of a silent skip.
got=$(detect_backup_engine "" ""); _rc=$?
[ "$got" = "none" ] && [ $_rc -ne 0 ] && ok "no engine -> 'none' and rc!=0" || ko "got [$got] rc=$_rc"

_mk_mysqldump "$_eng/mysql8"
got=$(detect_backup_engine "$_eng/mysql8" "")
[ "$got" = "mysql" ] && ok "MySQL tree selects mysql" || ko "got [$got]"

_mk_mysqldump "$_eng/mariadb"
got=$(detect_backup_engine "$_eng/mariadb" "")
[ "$got" = "mysql" ] && ok "MariaDB tree maps to the same mysql bucket" || ko "got [$got]"

# Historical default pinned: when both trees exist MySQL must keep winning,
# otherwise an existing backup job would silently switch engines.
got=$(detect_backup_engine "$_eng/mysql8" "$_eng/pgsql")
[ "$got" = "mysql" ] && ok "mysql wins when both trees exist (historical default)" || ko "got [$got]"

# A MySQL dir without mysqldump must not shadow a perfectly good PostgreSQL
# install: the probe is on the binary, not on the directory.
mkdir -p "$_eng/brokenmysql"
got=$(detect_backup_engine "$_eng/brokenmysql" "$_eng/pgsql")
[ "$got" = "pgsql" ] && ok "dir without mysqldump falls through to pgsql" || ko "got [$got]"

# Half a PostgreSQL tree (pg_dump but no psql) is unusable for both the probe
# and the dump - reject it rather than start a dump we cannot verify.
mkdir -p "$_eng/partial/bin"; : > "$_eng/partial/bin/pg_dump"; chmod +x "$_eng/partial/bin/pg_dump"
got=$(detect_backup_engine "" "$_eng/partial"); _rc=$?
[ "$got" = "none" ] && [ $_rc -ne 0 ] && ok "pgsql tree missing psql is rejected" || ko "got [$got] rc=$_rc"

# -x not -e: a non-executable file present in the tree must not count.
mkdir -p "$_eng/noexec/bin"; : > "$_eng/noexec/bin/pg_dump"; : > "$_eng/noexec/bin/psql"
got=$(detect_backup_engine "" "$_eng/noexec"); _rc=$?
[ "$got" = "none" ] && [ $_rc -ne 0 ] && ok "non-executable pg binaries do not count" || ko "got [$got] rc=$_rc"

rm -rf "$_eng"

echo "== Upgrade_DB on a PostgreSQL-only host (include/upgrade_db.sh) =="
# The reporting bug: db_install_dir is empty on such a host, so the generic
# probe reported "MySQL/MariaDB is not installed" - identical to a box with no
# database at all - and never hinted that PostgreSQL was present. The upgrade
# itself stays out of scope (see the README roadmap); what has to change is
# that the script admits what it found and says what to do instead.
_pgup="$work/pgonly"; rm -rf "$_pgup"; mkdir -p "$_pgup/bin"
printf '#!/bin/bash\necho "psql (PostgreSQL) 16.4"\n' > "$_pgup/bin/psql"
chmod +x "$_pgup/bin/psql"
# check_dir.sh leaves db_install_dir unset with no MySQL/MariaDB tree present
db_install_dir=""; pgsql_install_dir="$_pgup"
( Upgrade_DB ) > "$work/pgup.log" 2>&1; _rc=$?
[ $_rc -ne 0 ] && ok "PostgreSQL-only host: Upgrade_DB exits non-zero" || ko "rc=$_rc"
grep -q 'PostgreSQL 16.4' "$work/pgup.log" && ok "message names the installed PostgreSQL version" || ko "no version in: $(cat "$work/pgup.log")"
if grep -q 'MySQL/MariaDB is not installed' "$work/pgup.log"; then
  ko "still claims MySQL/MariaDB is missing"
else
  ok "no longer claims MySQL/MariaDB is missing"
fi
grep -q 'pg_dumpall' "$work/pgup.log" && ok "message says how to back up before upgrading" || ko "no pg_dumpall guidance in: $(cat "$work/pgup.log")"
unset db_install_dir pgsql_install_dir

echo "== offline prefetch covers every installable database version =="
# The gap: sources.conf carried mariadb123/mariadb118 but nothing for 11.4 or
# 10.11, mysql-src was pinned to 9.7, and one "postgresql" key resolved to
# pgsql18_ver - so db_option 6/7, a source build of MySQL 8.4/8.0, and
# pgsql_option 2/3 left nothing to pre-download, and an offline install then
# died on a missing source. The check is two-sided on purpose: a key with no
# get_version case, or the reverse, only fails at download time.
set +e
. "$ROOT/download_sources.sh" >/dev/null 2>&1
set +e
# download_sources.sh derives VERSIONS_FILE from $0, which points at this test
# script (tools/), so point it at the real versions.txt before loading.
VERSIONS_FILE="$ROOT/versions.txt"
load_versions >/dev/null 2>&1
. "$ROOT/versions.txt"

_pf(){  # _pf <component> <expected version>
  local comp=$1 want=$2 keys got
  keys=$(grep -c "^${comp}|" "$ROOT/sources.conf")
  got=$(get_version "$comp")
  if [ "${keys:-0}" -ge 1 ] && [ "${got}" = "${want}" ]; then
    ok "${comp} -> ${want}"
  else
    ko "${comp}: sources.conf keys=${keys}, get_version=[${got}], want=[${want}]"
  fi
}

# MySQL: binary and source (db_option 1-3, dbinstallmethod 1/2)
_pf mysql97     "${mysql97_ver}"
_pf mysql84     "${mysql84_ver}"
_pf mysql80     "${mysql80_ver}"
_pf mysql-src   "${mysql97_ver}"
_pf mysql84-src "${mysql84_ver}"
_pf mysql80-src "${mysql80_ver}"

# MariaDB: binary and source (db_option 4-7, dbinstallmethod 1/2)
_pf mariadb123      "${mariadb123_ver}"
_pf mariadb118      "${mariadb118_ver}"
_pf mariadb         "${mariadb118_ver}"
_pf mariadb114      "${mariadb114_ver}"
_pf mariadb1011     "${mariadb1011_ver}"
_pf mariadb-src     "${mariadb118_ver}"
_pf mariadb114-src  "${mariadb114_ver}"
_pf mariadb1011-src "${mariadb1011_ver}"

# PostgreSQL source builds (db_option 8, pgsqlinstallmethod 2, pgsql_option 1-3)
_pf postgresql   "${pgsql18_ver}"
_pf postgresql18 "${pgsql18_ver}"
_pf postgresql17 "${pgsql17_ver}"
_pf postgresql16 "${pgsql16_ver}"
unset -f _pf

echo "== download_common: every name resolves, and a database is included =="
# --common is what include/download.sh points at when a download fails, so it
# has to stand on its own: every component it names must reach a real
# sources.conf key with a version, and at least one must be a database. A
# "common" set with no database cannot install the M in LNMP, which is why
# following that hint used to fail a second time on the very same file.
_common_list=$(sed -n '/^download_common() {/,/^}/p' "$ROOT/download_sources.sh" | grep -oE '"[a-z0-9._-]+"' | tr -d '"')
_missing=""
_n=0
while IFS= read -r _c; do
  [ -z "${_c}" ] && continue
  _n=$((_n + 1))
  if ! grep -q "^${_c}|" "$ROOT/sources.conf"; then
    _missing="${_missing} ${_c}(no sources.conf key)"
  elif [ -z "$(get_version "${_c}")" ]; then
    _missing="${_missing} ${_c}(no version)"
  fi
done <<< "${_common_list}"
if [ -z "${_missing}" ] && [ "${_n}" -gt 0 ]; then
  ok "--common: all ${_n} components resolve to a sources.conf key and a version"
else
  ko "--common: parsed ${_n} components, problems:${_missing:- list came back empty}"
fi
if echo "${_common_list}" | grep -qE '^(mysql|mariadb|postgresql)'; then
  ok "--common includes a database component"
else
  ko "--common contains no database, so it cannot produce a working LNMP: ${_common_list}"
fi
unset _common_list _missing _n _c

echo "== upgrade.sh validates every parser-assigned version =="
# Each option's parser test is a PREFIX match (^N.N.N with no trailing
# anchor), so it accepts "8.4.3.1" and only validate_version's ANCHORED
# pattern can reject that. A variable the parser fills from $2 but the validate
# block never checks is therefore silently unvalidated - which is how --db and
# --phpmyadmin shipped: `--db 8.4.3.1` reached the upgrade untouched while
# `--nginx 1.28.2.1` was refused. Assert it per variable so a newly parsed
# flag cannot regress, and let literal assignments (NEW_*_ver=latest) exempt
# themselves by never matching the parser pattern.
_validated=$(grep -oE 'validate_version "\$\{NEW_[A-Za-z_]*\}' "$ROOT/upgrade.sh" | grep -oE 'NEW_[A-Za-z_]*' | sort -u)
while IFS= read -r _v; do
  [ -z "${_v}" ] && continue
  if grep -qx "${_v}" <<< "${_validated}"; then
    ok "${_v}: parsed from \$2 and checked by validate_version"
  else
    ko "${_v}: parsed from \$2 but never passed to validate_version"
  fi
done < <(grep -oE 'NEW_[A-Za-z_]*=\$2' "$ROOT/upgrade.sh" | sed 's/=.*//' | sort -u)
unset _validated _v

echo ""
echo "Offline tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
