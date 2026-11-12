#!/bin/sh
# Pure merge and temporary-file journal tests. Optional before/after fixtures are read only.
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc macos/WallpaperRestore.swift tools/tests/WallpaperRestoreTests.swift -o "$test_dir/wallpaper-restore-tests"
"$test_dir/wallpaper-restore-tests" "$@"
