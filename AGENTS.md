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
