#!/usr/bin/env bash
set -euo pipefail
VE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ve-language-tests.XXXXXX")"
trap 'rm -rf "$VE_TEST_DIR"' EXIT
swiftc -parse-as-library \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Sources/Models/AppLanguage.swift" \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Sources/Models/LocalizedStrings.swift" \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Tests/LocalizationTests/main.swift" \
    -o "$VE_TEST_DIR/LocalizationTests"
"$VE_TEST_DIR/LocalizationTests"
