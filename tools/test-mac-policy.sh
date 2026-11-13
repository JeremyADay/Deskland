#!/bin/sh
# Dependency-free pause/polling regression checks; does not open the wallpaper or request access.
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc macos/HostPolicy.swift tools/tests/HostPolicyTests.swift -o "$test_dir/host-policy-tests"
"$test_dir/host-policy-tests"
