#!/bin/bash
# Fetch into a new output base, then compile and test without repository fetches.
set -euo pipefail
cd "$(dirname "$0")/.."
./build/check_prerequisites.sh
bazel_bin=$(command -v "${BAZEL:-bazel}")
[ -n "$bazel_bin" ] || { echo 'Install Bazel 8.8.0 or set BAZEL to its absolute path.' >&2; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
output_base=$(mktemp -d "${TMPDIR:-/tmp}/kpasskey-m1.XXXXXX")
echo "Clean output base: $output_base"
startup=(--nosystem_rc --nohome_rc "--output_base=$output_base")
"$bazel_bin" "${startup[@]}" version | /usr/bin/grep -qx 'Build label: 8.8.0'
"$bazel_bin" "${startup[@]}" fetch --lockfile_mode=error //...
"$bazel_bin" "${startup[@]}" test --nofetch --lockfile_mode=error //...
echo "Build evidence and test logs: $output_base/execroot/_main/bazel-out"
