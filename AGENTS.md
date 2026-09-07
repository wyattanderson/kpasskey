# Programming language and testing

Swift is the primary and mandatory language for all project-owned executable
code, including the application, worker, XPC contracts, harness, library
adapters, plugin logic, tools, and tests. Use modern Swift tooling and language
features. Swift Testing is mandatory for new and migrated automated tests;
use another test framework only where a required capability is unavailable
in Swift Testing, and document that functional limitation.

C or Objective-C is permitted only when it is **absolutely and functionally
necessary**: the required API or ABI cannot be implemented using supported
Swift interoperability. An upstream C library, a C plugin ABI, or an
Objective-C-compatible framework protocol does not by itself justify writing
C or Objective-C. First use Swift's C imports and Objective-C interoperability.
Convenience, familiarity, existing examples, and missing build wiring are not
exceptions.

Keep any unavoidable C/Objective-C shim minimal, with all representable logic
in Swift. Document the exact interoperability limitation and why Swift cannot
meet it beside the shim and in the relevant design/build documentation.
Historical C/Objective-C probes are not precedent for new code.

Keep required upstream dependencies in their upstream languages; do not rewrite
MIT krb5, libfido2, or cryptographic libraries to satisfy this policy. Bazel
Starlark and declarative build/configuration files remain the required build
mechanism. Project-owned executable tooling belongs in Swift; the narrowly
scoped shell exception below is only for unavoidable build integration.

# Build tooling

Prefer Bazel rules, toolchains, configuration, and direct Bazel commands for
build setup, prerequisite handling, dependency resolution, testing, and clean
build reproduction.

Do not add Bash or other shell wrapper scripts for these tasks unless absolutely
necessary. When a script is necessary, keep it narrowly scoped and document why
Bazel's facilities cannot reasonably handle the required behavior.

# Build metadata and documentation

Do not record specific versions, hashes, build artifacts, or run statistics in
documentation unless they are absolutely necessary and relevant to the reader.
Keep required dependency and toolchain pins in the appropriate Bazel build or
configuration file (for example, BUILD.bazel, MODULE.bazel, or .bazelversion),
with any compatibility rationale beside the pin. Do not duplicate that metadata
in README files, plans, or other documentation; refer to the authoritative build
configuration instead.

Prefer toolchain discovery and supported defaults over exact host-tool or SDK
version requirements. Only add an explicit pin when the build needs it. Keep
documentation focused on setup, behavior, design decisions, and meaningful
validation so routine upgrades do not require rewriting version inventories.
