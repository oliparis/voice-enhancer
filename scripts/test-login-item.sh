#!/usr/bin/env bash
set -euo pipefail
VE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ve-login-tests.XXXXXX")"
trap 'rm -rf "$VE_TEST_DIR"' EXIT
swiftc -parse-as-library \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Sources/Models/LoginItemController.swift" \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Tests/LoginItemTests/main.swift" \
    -o "$VE_TEST_DIR/LoginItemTests"
"$VE_TEST_DIR/LoginItemTests"
