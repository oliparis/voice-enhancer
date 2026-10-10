#!/usr/bin/env bash
set -euo pipefail
VE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ve-device-tests.XXXXXX")"
trap 'rm -rf "$VE_TEST_DIR"' EXIT
swiftc -parse-as-library \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Sources/Models/AudioDevice.swift" \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Sources/Audio/AudioDeviceEnumerator.swift" \
    "$VE_REPO_ROOT/VoiceEnhancerApp/Tests/DeviceSelectionTests/main.swift" \
    -o "$VE_TEST_DIR/DeviceSelectionTests"
"$VE_TEST_DIR/DeviceSelectionTests" "$@"
