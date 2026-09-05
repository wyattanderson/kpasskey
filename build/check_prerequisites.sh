#!/bin/bash
set -euo pipefail
fail() { echo "$*" >&2; exit 1; }
[ "$(/usr/bin/uname -m)" = arm64 ] || fail 'KPasskey supports arm64 Macs only.'
[ "$(/usr/bin/xcode-select -p)" = /Library/Developer/CommandLineTools ] ||
    fail 'M1 baseline: select /Library/Developer/CommandLineTools (see docs/BUILD.md).'
[ "$(/usr/bin/xcrun --sdk macosx --show-sdk-version)" = 26.5 ] || fail 'Expected macOS SDK 26.5.'
/usr/sbin/pkgutil --pkg-info=com.apple.pkg.CLTools_Executables |
    /usr/bin/grep -qx 'version: 26.6.0.0.1781586589' || fail 'Unexpected Command Line Tools version.'
/usr/bin/clang --version | /usr/bin/grep -q 'clang-2100.1.1.101' || fail 'Unexpected Apple clang version.'
[ "$(/usr/bin/perl -e 'print $^V')" = v5.34.1 ] || fail 'Expected macOS Perl 5.34.1.'
echo 'arm64 / CLT 26.6.0.0.1781586589 / SDK 26.5 / Apple clang 21 / Perl 5.34.1: OK'
