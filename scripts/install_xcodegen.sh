#!/bin/bash
# Reproducible XcodeGen bootstrap for CI. Both the source commit and the
# downloaded archive bytes are pinned; a moved tag or changed archive fails.
set -euo pipefail

version="2.44.1"
commit="21ac9944b0ab546a07422dbed86f33dd2ebd76f8"
checksum="fd67eb6341db179b77932179fcb7cb2b905f46538dbf9869374df6de7afffe33"
task_temp="${RUNNER_TEMP:?RUNNER_TEMP is required}"
archive="$task_temp/xcodegen-$commit.tar.gz"
source_dir="$task_temp/xcodegen-$commit"
bin_dir="$task_temp/xcodegen-bin"

curl --fail --location --silent --show-error \
  --output "$archive" \
  "https://github.com/yonaskolb/XcodeGen/archive/$commit.tar.gz"
echo "$checksum  $archive" | shasum -a 256 --check

mkdir -p "$source_dir" "$bin_dir"
tar -xzf "$archive" -C "$source_dir" --strip-components=1
swift build --configuration release --package-path "$source_dir"
cp "$source_dir/.build/release/xcodegen" "$bin_dir/xcodegen"
test "$("$bin_dir/xcodegen" --version)" = "Version: $version"
echo "$bin_dir" >> "${GITHUB_PATH:?GITHUB_PATH is required}"
