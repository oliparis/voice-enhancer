#!/usr/bin/env bash
set -euo pipefail
VE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ve-settings-tests.XXXXXX")"
trap 'rm -rf "$VE_TEST_DIR"' EXIT
swiftc -parse-as-library \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Sources/Models/AppLanguage.swift" \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Sources/Models/LocalizedStrings.swift" \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Sources/Models/Preset.swift" \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Sources/Models/WorkingSettings.swift" \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Sources/Models/SettingsStore.swift" \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Tests/SettingsTests/main.swift" \
    -o "$VE_TEST_DIR/SettingsTests"
"$VE_TEST_DIR/SettingsTests"
