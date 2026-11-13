#!/bin/sh
# Bounded refresh scheduler checks; no GUI, Accessibility request, or preference change.
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc macos/InteractionRefresh.swift tools/tests/InteractionRefreshTests.swift -o "$test_dir/interaction-refresh-tests"
"$test_dir/interaction-refresh-tests"
