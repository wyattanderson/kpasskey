#!/bin/bash
set -euo pipefail
cd "${TEST_SRCDIR}/${TEST_WORKSPACE}"
krb=$1
crypto=$2
bridge_app=$3
root="$TEST_TMPDIR/relocated build probes with spaces"
mkdir -p "$root/bin" "$root/lib" "$root/plugins"
cp tests/dependency_probe "$root/bin/probe"
cp "$bridge_app" "$root/bin/bridge_app"
for lib in libkrb5.3.3 libk5crypto.3.1 libcom_err.3.0 libkrb5support.1.1 libgssapi_krb5.2.2; do
    cp "$krb/lib/$lib.dylib" "$root/lib/"
done
cp "$crypto"/lib/lib{crypto,ssl}.3.dylib "$root/lib/"
cp "$krb/lib/krb5/plugins/preauth/pkinit.so" "$root/plugins/"
chmod u+w "$root/bin/probe"
while read -r rpath; do
    /usr/bin/install_name_tool -delete_rpath "$rpath" "$root/bin/probe"
done < <(/usr/bin/otool -l "$root/bin/probe" | /usr/bin/awk '
    $1 == "cmd" { rpath = ($2 == "LC_RPATH") }
    rpath && $1 == "path" { print $2 }
')
/usr/bin/install_name_tool -add_rpath @executable_path/../lib "$root/bin/probe"
/usr/bin/codesign --force --sign - "$root/bin/probe"
cd "$root"
# rules_apple supplies the signature and the declared relative rpath. Verify
# and run this executable without rewriting or re-signing it after relocation.
/usr/bin/codesign --verify "$root/bin/bridge_app"
/usr/bin/env -i PATH=/usr/bin:/bin "$root/bin/bridge_app"
exec /usr/bin/env -i PATH=/usr/bin:/bin "$root/bin/probe" "$root/plugins/pkinit.so"
