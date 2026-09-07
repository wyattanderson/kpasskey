#!/bin/bash
set -euo pipefail
cd "${TEST_SRCDIR}/${TEST_WORKSPACE}"
fail() { echo "$*" >&2; exit 1; }
krb=$1
crypto=$2
bridge_app=$3
plugin="$krb/lib/krb5/plugins/preauth/pkinit.so"
for artifact in "$krb"/lib/*.dylib "$crypto"/lib/*.dylib "$plugin"; do
    [ -f "$artifact" ] || fail "Missing artifact: $artifact"
    [ "$(/usr/bin/lipo -archs "$artifact")" = arm64 ] || fail "Wrong architecture: $artifact"
    /usr/bin/otool -l "$artifact" | /usr/bin/awk '
        $1 == "cmd" && $2 == "LC_BUILD_VERSION" { build = 1 }
        build && $1 == "minos" { if ($2 != "14.0") exit 1; found = 1; build = 0 }
        END { if (!found) exit 1 }
    ' || fail "Wrong minimum OS: $artifact"
    while read -r dep; do
        case "$dep" in
            @rpath/*)
                base=${dep##*/}
                [ -f "$krb/lib/$base" ] || [ -f "$crypto/lib/$base" ] || fail "Missing bundled dependency: $dep" ;;
            /System/Library/Frameworks/*|/usr/lib/*) ;;
            *) fail "Non-relocatable dependency in $artifact: $dep" ;;
        esac
    done < <(/usr/bin/otool -L "$artifact" | /usr/bin/awk 'NR > 1 {print $1}')
    # No build/staging/package-manager rpaths may survive in distributed libs.
    if /usr/bin/otool -l "$artifact" | /usr/bin/awk '
        $1 == "cmd" { rpath = ($2 == "LC_RPATH") }
        rpath && $1 == "path" { print $2 }
    ' | /usr/bin/grep -E '^(/|.*(homebrew|usr/local|execroot))'; then
        fail "Absolute or host-specific rpath: $artifact"
    fi
    /usr/bin/codesign --verify "$artifact"
done
for artifact in third_party/libfido2/lib/libfido2.a third_party/libcbor/lib/libcbor.a third_party/zlib/lib/libz.a tests/dependency_probe tests/bridge_probe "$bridge_app"; do
    [ "$(/usr/bin/lipo -archs "$artifact")" = arm64 ] || fail "Wrong artifact architecture: $artifact"
    /usr/bin/otool -l "$artifact" | /usr/bin/awk '
        $1 == "minos" { if ($2 != "14.0") exit 1; found = 1 }
        END { if (!found) exit 1 }
    ' || fail "Wrong artifact minimum OS: $artifact"
done
/usr/bin/codesign --verify "$bridge_app"
/usr/bin/nm -u "$krb/lib/libkrb5.3.3.dylib" | /usr/bin/grep '^_cc_initialize$' >/dev/null || fail 'Missing CCAPI reference'
/usr/bin/strings "$krb/lib/libkrb5.3.3.dylib" | /usr/bin/grep 'com.apple.GSSCred' >/dev/null || fail 'Missing macOS GSSCred backend'
/usr/bin/otool -L "$krb/lib/libkrb5.3.3.dylib" | /usr/bin/grep '/Kerberos.framework/' >/dev/null || fail 'Missing Kerberos framework linkage'
/usr/bin/nm -gU "$plugin" | /usr/bin/grep ' _clpreauth_pkinit_initvt$' >/dev/null || fail 'Missing PKINIT entry point'
echo 'arm64, macOS 14.0, relocatable dylibs, CCAPI backend and stock PKINIT: OK'
