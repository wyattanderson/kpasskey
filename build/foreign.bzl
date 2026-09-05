"""Shared policy for the arm64 macOS dependency builds."""

SDK = "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

ENV = {
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "SDKROOT": SDK,
    "PKG_CONFIG": "/usr/bin/false",
    "PKG_CONFIG_LIBDIR": "/nonexistent",
    "PKG_CONFIG_PATH": "",
    "PERL": "/usr/bin/perl",
}

CMAKE = {
    "CMAKE_BUILD_TYPE": "Release",
    "CMAKE_OSX_ARCHITECTURES": "arm64",
    "CMAKE_OSX_DEPLOYMENT_TARGET": "14.0",
    "CMAKE_OSX_SYSROOT": SDK,
    "CMAKE_INSTALL_LIBDIR": "lib",
    "CMAKE_FIND_USE_PACKAGE_REGISTRY": "OFF",
    "CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY": "OFF",
    "CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH": "OFF",
    "CMAKE_IGNORE_PREFIX_PATH": "/opt/homebrew;/usr/local",
    "CMAKE_POLICY_VERSION_MINIMUM": "3.5",
}

# Foreign install trees are relocated into Bazel runfiles now and app bundles
# later. Repair Mach-O IDs and sibling references before publishing outputs.
RELOCATE = """
kpasskey_library_name() {
    case "$$1" in
        libcrypto*.dylib) echo libcrypto.3.dylib ;;
        libssl*.dylib) echo libssl.3.dylib ;;
        libkrb5.*.dylib|libkrb5.dylib) echo libkrb5.3.3.dylib ;;
        libk5crypto*.dylib) echo libk5crypto.3.1.dylib ;;
        libcom_err*.dylib) echo libcom_err.3.0.dylib ;;
        libkrb5support*.dylib) echo libkrb5support.1.1.dylib ;;
        libgssapi_krb5*.dylib) echo libgssapi_krb5.2.2.dylib ;;
        *) echo "$$1" ;;
    esac
}
for file in $$INSTALLDIR/lib/*.dylib $$INSTALLDIR/lib/krb5/plugins/preauth/*.so; do
    [ -f "$$file" ] && [ ! -L "$$file" ] || continue
    case "$$file" in
        *.dylib) /usr/bin/install_name_tool -id "@rpath/$$(kpasskey_library_name "$$(basename "$$file")")" "$$file" ;;
    esac
    for dep in $$(/usr/bin/otool -L "$$file" | /usr/bin/awk 'NR > 1 {print $$1}'); do
        case "$$dep" in
            /System/*|/usr/lib/*) ;;
            *) /usr/bin/install_name_tool -change "$$dep" "@rpath/$$(kpasskey_library_name "$$(basename "$$dep")")" "$$file" ;;
        esac
    done
    # Configure executables need a staging rpath to run against OpenSSL.
    # It must not survive in the published libraries or plugin.
    for rpath in $$(/usr/bin/otool -l "$$file" | /usr/bin/awk '
        $$1 == "cmd" { is_rpath = ($$2 == "LC_RPATH") }
        is_rpath && $$1 == "path" { print $$2 }
    '); do
        /usr/bin/install_name_tool -delete_rpath "$$rpath" "$$file"
    done
    /usr/bin/codesign --force --sign - "$$file"
done
"""
