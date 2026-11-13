#!/bin/sh
# Geometry-only regression checks; no GUI, Accessibility request, or system preference change.
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc macos/IconVisibility.swift tools/tests/IconVisibilityTests.swift -o "$test_dir/icon-visibility-tests"
"$test_dir/icon-visibility-tests"
