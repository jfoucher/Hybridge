#!/bin/bash
# Thin wrapper around the xcodebuild invocations documented in CLAUDE.md.
# Raw xcodebuild output is thousands of lines of compiler-invocation noise;
# this filters down to what actually matters (errors, warnings, build/test
# results) while preserving xcodebuild's exit code, so it's safe to use in
# scripts or CI gating, not just interactively.
#
# Usage:
#   scripts/xbuild.sh build
#   scripts/xbuild.sh test
#   scripts/xbuild.sh test HybridgeTests/ProtocolTests/testAlarmTLVFile
#   scripts/xbuild.sh test HybridgeTests/BundledFacesTests
#   scripts/xbuild.sh analyze
#
# Full untouched output always lands in /tmp/xbuild-<cmd>.log if you need
# to dig deeper than the filtered summary.

set -eu

cmd="${1:-build}"
shift || true

# Host compiler search paths must not leak into an Apple-platform build.
# In particular, a shell-level LIBRARY_PATH containing the Command Line Tools
# macOS SDK makes an iOS Simulator link select macOS libobjc/libSystem stubs.
unset LIBRARY_PATH

# Keep local and CI tests on the same simulator runtime instead of silently
# selecting whichever runtime happens to be newest on a machine. Overridable
# for a machine without this exact simulator, e.g.
# XBUILD_DESTINATION='platform=iOS Simulator,name=iPhone 16,OS=26.5'.
destination="${XBUILD_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=26.5}"
configuration="${XBUILD_CONFIGURATION:-Debug}"
project=Hybridge.xcodeproj
scheme=Hybridge
logfile="/tmp/xbuild-${cmd}-${configuration}.log"

case "$cmd" in
  build)
    set +e
    xcodebuild build -project "$project" -scheme "$scheme" -configuration "$configuration" -destination "$destination" 2>&1 | tee "$logfile" | \
      grep -E ' error:| warning:|BUILD SUCCEEDED|BUILD FAILED|^\*\* '
    status=${PIPESTATUS[0]:-$?}
    set -e
    ;;
  test)
    only=""
    if [ "${1:-}" != "" ]; then
      only="-only-testing:$1"
    fi
    set +e
    xcodebuild test -project "$project" -scheme "$scheme" -configuration "$configuration" -destination "$destination" $only 2>&1 | tee "$logfile" | \
      grep -E ' error:| warning:|BUILD SUCCEEDED|BUILD FAILED|^\*\* |Test Suite .* (started|passed|failed)|Test Case .* (passed|failed)|Executed [0-9]+ test'
    status=${PIPESTATUS[0]:-$?}
    set -e
    ;;
  analyze)
    set +e
    xcodebuild analyze -project "$project" -scheme "$scheme" -configuration "$configuration" -destination "$destination" 2>&1 | tee "$logfile" | \
      grep -E ' error:| warning:|ANALYZE SUCCEEDED|ANALYZE FAILED|^\*\* '
    status=${PIPESTATUS[0]:-$?}
    set -e
    ;;
  *)
    echo "usage: $0 {build|test|analyze} [only-testing-target]" >&2
    exit 2
    ;;
esac

echo
echo "(full output: $logfile)"
exit "$status"
