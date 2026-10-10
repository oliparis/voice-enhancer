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

- Branch: `fix/native-input-format`, based on R1.
- Current commit: `c11e0ea`; integration equivalent: `8295824`.
- Initial mixer implementation (`a98a62f` / `b887734`) passed 213 offline
  checks and CI, but failed live with `-10875`. It is superseded: binding the
  USB input-only device also binds AVAudioEngine's shared I/O unit, leaving
  zero output channels. A muted playback mixer still requires an output.
- Capture now taps native-rate/channel-count input directly and converts
  channel 1 through a persistent AudioConverter to 48 kHz mono. It opens no
  output route. Fixed 128-frame input staging retains phase/filter history;
  preallocated output blocks contain at most 1024 frames. Oversized taps are
  split without truncation; 48 kHz bypasses resampling.
- Removed callback logging/dispatch. Converter and buffers are created/warmed
  before capture. Application callback code does not allocate or lock.

Validation on 2026-10-10:

- 82 native checks passed: tap exception handling, 8/16/44.1/48/96/192 kHz,
  1–32768-frame input chunks, waveform continuity and level, output duration,
  30-second 44.1 kHz timing, anti-alias filtering and mutable-output isolation.
- An opt-in `TapSupportTests --live-input <AudioDeviceID>` test now exercises
  physical input. It counts frames without recording or playback. USB Audio
  CODEC input, stereo 44.1 kHz: 83,790 native -> 91,080 converted frames, no
  errors. It does not exercise the virtual driver or subjective audio quality.
- Local linked Debug Xcode build and Release SwiftPM build passed.

## Capture startup reliability (focused R3 prerequisite)

- Branch: `fix/capture-startup`, based on current R5, commit `6d54591`.
- Integration equivalent: `b99011e` on `integration/initial-contributions`.
- Main-actor graph mutation; generation checks invalidate pending permission
  requests after stop/newer start. Repeated view-model starts are idempotent,
  stale completions cannot overwrite current state, and cancelled recovery
  tasks do not resume anyway.
- Ignore delayed configuration notifications when the engine is still running
  and its native input format is unchanged. The USB device otherwise triggered
  a repeated successful-start/rebuild loop until the retry budget ran out.
- `CaptureLifecycleTests` passed: stop during permission, superseding device
  request, task cancellation, and retry after permission failure. Added to CI.
- The complete app was observed Running with live input/output levels using
  the physical USB microphone. Broader unplug/replug, Bluetooth, sleep/wake,
  driver routing and listening validation remain separate checks.

These branches and the integration build are pushed to the user's fork. No
upstream PRs have been opened. Keep R1, P0, R5 and the startup slice separate;
rebase onto accepted prerequisites when preparing upstream submissions.

## Local toolchain and test app

Full Xcode is now installed and selected:
`/Applications/Xcode.app/Contents/Developer`, Xcode 27.0 (27A266a). XcodeGen,
native tests, SwiftPM and linked Xcode builds run locally.

Use `integration/initial-contributions` for combined local testing. Generate
with `cd VoiceEnhancerApp && xcodegen generate`, then build/run in Xcode, or
use `VoiceEnhancerApp/build/Build/Products/Debug/Voice Enhancer.app` (locally
ad-hoc signed). The earlier `manual-test` and `native-format-test` copies and
`/Applications/Voice Enhancer.app` are older builds. Launch the explicit path
and keep one app instance running. The installed driver is unchanged.

The Debug app's whole-process CPU sample includes SwiftUI/meter rendering and
is not a converter benchmark. Formal real-time allocation/CPU profiling,
additional hardware routes and subjective listening remain upstream-readiness
checks for R5; the DSP algorithm and driver code have not changed.

## Next implementation steps

1. Keep all upstream submissions on hold as requested by the user.
2. Begin P1 (`fix/dsp-control-race`) from current upstream `main`: safe updates
   for the existing DSP setters, with focused concurrency/final-value regression
   tests and CPU evidence. Do not bring in the planning or integration branches.
3. R2 (excluding virtual input) is another independently reviewable reliability
   slice; the remaining R3/R4 work follows its documented dependencies. R5 and the
   startup prerequisite now have local USB validation as recorded above.
4. P2–P4 deliver complete snapshots, startup recall and named user presets
   before the larger Advanced UI.

Before eventually raising R1, use the accepted P0 CI base or explicitly state
the linked-build prerequisite. The integration run proves the combined source,
but does not make the original upstream CI runner current.
