# Implementation status

Updated 10 October 2026. Work is pushed to the personal fork; no upstream PRs
or comments have been opened. Planning labels refer to
[UPSTREAM_DELIVERY_PLAN.md](UPSTREAM_DELIVERY_PLAN.md).

## First implementation tranche

### R1 — Recover from audio tap exceptions

- Branch: `fix/tap-exception`, based directly on upstream `19482d3`.
- Commit: `ade49db` (`Recover from audio tap exceptions`).
- [Branch and source](https://github.com/oliparis/voice-enhancer/tree/fix/tap-exception).
- Objective-C installation/removal exceptions become errors instead of
  unwinding through Swift. Cleanup attempts removal even after a partially
  failed installation; failed graphs are discarded before a later start.
- SwiftPM and Xcode use the same native helper. An Objective-C regression
  runner exercises its boundary without requesting microphone permission.
- Capture-format conversion, reconnect policy and audio-buffer processing
  remain separate work. The helper credits wondervip PR #4 as its source.

Validation: 17 native checks passed locally and in fork CI. The changed Swift
capture code type-checks against the real C ABI and Objective-C header. The
combined CI build compiles and links the actual Xcode app as well as passing
the SwiftPM build and existing DSP tests.

The native checks exercise success, argument/callback forwarding, exception
reason/name conversion, missing reason, partial-install cleanup, duplicate
installation, removal failure and later success. They test the helper using a
fake node, not physical devices or the whole Swift capture lifecycle. Hardware
format mismatch, repeated device switching and end-to-end recovery still need
manual validation before an upstream submission claims those scenarios fixed.

### P0 — Build the linked app in CI

- Branch: `ci/linked-app`, based directly on upstream `19482d3`.
- Commit: `5779a7c` (`Build the linked macOS app in CI`).
- [Branch and source](https://github.com/oliparis/voice-enhancer/tree/ci/linked-app).
- Moves the macOS runner to macOS 15 / Xcode 16.4, generates the existing
  XcodeGen project, builds without signing for the runner architecture and
  verifies the app executable. Retains the SwiftPM check and DSP/driver builds.
- This branch contains only CI and the directly relevant build documentation;
  it is independently reviewable from R1.

Independent validation: the
[CI-only run](https://github.com/oliparis/voice-enhancer/actions/runs/38087402236)
passed Linux DSP tests and the macOS DSP/driver, SwiftPM and linked Xcode app
builds at `5779a7c`.

### Combined fork build

- Branch: `integration/initial-contributions`.
- Commits: R1 plus a cherry-picked P0 (`c1e8d03`) and a fork-only integration
  push trigger (`c3cb54b`).
- [Passing CI run](https://github.com/oliparis/voice-enhancer/actions/runs/38087266350)
  at `c3cb54b`: Linux DSP tests, macOS DSP/driver build, SwiftPM app build,
  17 native checks and unsigned linked Xcode app all passed.
- This branch is a validation build, not the head of a combined upstream PR.
  The clean R1 and P0 branches retain their separate diffs.

## R5 — Native microphone format conversion

The user reported a tap format mismatch while running the first CI app with a
saved USB Audio CODEC input. This confirms that R1 reports the exception but
does not make a hardware input accept a different format. R5 was brought
forward to unblock real-device testing.

- Branch: `fix/native-input-format`, based on the R1 prerequisite.
- Commit: `a98a62f`; combined integration commit: `b887734`.
- [Source branch](https://github.com/oliparis/voice-enhancer/tree/fix/native-input-format).
- Connect the microphone using its hardware-native format to an AVAudioMixerNode.
  Configure its output to 48 kHz float32 with the same channels; take channel 1
  for the mono DSP/ring contract. This preserves the first-channel policy.
- Tap the conversion mixer, not the hardware input. Conversion state and
  resampling live in AVAudioEngine's render graph, not a per-buffer application
  resampler. Mute the downstream main mixer to avoid speaker feedback while
  leaving the captured tap signal live.
- Rebuild the capture graph on each start to negotiate the selected device's
  current format; handle graph-configuration exceptions through the native boundary.

Local validation: 213 checks passed, including the original exception checks,
offline native-rate conversion at 8/16/44.1/48/96 kHz in mono/stereo, equivalent
regular/irregular render blocks, first-channel level and stereo separation,
duration, high-frequency rejection when downsampling, and nonzero captured audio
with silent downstream playback. Swift capture code passes native-interface
type-checking. These checks use generated signals, not the user's physical mic.

[Replacement CI build](https://github.com/oliparis/voice-enhancer/actions/runs/38088866748)
passed Linux DSP tests, macOS DSP/driver, the native conversion checks, SwiftPM
and the linked Xcode app. The replacement test copy is prepared at
`VoiceEnhancerApp/build/native-format-test/Voice Enhancer.app` with a verified
local ad-hoc signature; quit the previous copy before opening it. Physical USB
input and Bluetooth route switching remain manual checks.

## Local toolchain

At implementation time, this Mac has Command Line Tools but no full Xcode or
XcodeGen. Native helper tests run successfully. Full SwiftPM app compilation
requires Xcode's asset compiler; direct whole-app type-checking also needs its
SwiftUI macro plug-ins. The fork CI run supplies those full-build checks.

For local shipping-app validation, install/open Xcode to finish its setup,
select `/Applications/Xcode.app/Contents/Developer` with `xcode-select`, and
install XcodeGen. Device validation must use the linked app, not the stub.

## Next implementation steps

1. Keep all upstream submissions on hold as requested by the user.
2. Begin P1 (`fix/dsp-control-race`) from current upstream `main`: safe updates
   for the existing DSP setters, with focused concurrency/final-value regression
   tests and CPU evidence. Do not bring in the planning or integration branches.
3. R2 (excluding virtual input) is another independently reviewable reliability
   slice; R3/R4/R5 follow their documented dependencies and device validation.
4. P2–P4 deliver complete snapshots, startup recall and named user presets
   before the larger Advanced UI.

Before eventually raising R1, use the accepted P0 CI base or explicitly state
the linked-build prerequisite. The integration run proves the combined source,
but does not make the original upstream CI runner current.
