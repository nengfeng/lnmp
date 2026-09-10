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

echo "== _extract_tar =="
cd "$current_dir/src"
rm -rf goodpkg-1.0 goodpkg-1.0.tar.gz
if _extract_tar "nonexistent-1.0.tar.gz"; then ko "missing tarball should fail"; else ok "missing tarball returns non-zero"; fi
mkdir -p goodpkg-1.0; echo hi > goodpkg-1.0/f.txt; tar czf goodpkg-1.0.tar.gz -C "$current_dir/src" goodpkg-1.0; rm -rf goodpkg-1.0
if _extract_tar "goodpkg-1.0.tar.gz"; then [ -d goodpkg-1.0 ] && ok "present tarball extracts ok" || ko "extracted dir missing"; else ko "present tarball should succeed"; fi

echo ""
echo "Offline tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
