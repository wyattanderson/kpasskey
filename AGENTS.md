# Build tooling

Prefer Bazel rules, toolchains, configuration, and direct Bazel commands for
build setup, prerequisite handling, dependency resolution, testing, and clean
build reproduction.

Do not add Bash or other shell wrapper scripts for these tasks unless absolutely
necessary. When a script is necessary, keep it narrowly scoped and document why
Bazel's facilities cannot reasonably handle the required behavior.
