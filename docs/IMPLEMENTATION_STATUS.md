# Implementation status

Updated 11 October 2026. Work is pushed to the personal fork; no upstream PRs
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

## Duplicate capture instances and chopping investigation

- Branch: `fix/single-capture-instance`, based on `fix/capture-startup`,
  commit `2dd1a81`; integration equivalent: `10a8835`.
- A user listening test reported regular chopping. Two app instances were
  running: the earlier manually launched test copy and the user's Xcode copy.
  Both could produce into the single-producer shared ring. The earlier test
  copy was closed, preserving the Xcode instance.
- Startup now rejects another running app with the same bundle identifier
  before DSP setup or writer-generation publication. A real second-instance
  launch was observed reporting the intended error and not starting capture.
- The linked Debug app builds successfully. The driver/shared layout is
  unchanged; no driver reinstall is required for the guard.
- A read-only five-second ring-timing probe observed 240,048 produced frames,
  write batches up to 4,877 frames and a maximum batch gap of 105.5 ms. The
  source publishes at approximately the intended 48 kHz; native capture is
  batched despite the requested tap size.
- A four-second virtual-microphone probe received 192,000 frames with no
  exact-silence samples after startup warmup. A later run after the usage
  interruption received 192,000 frames with 237 zero samples; its longest
  zero run was 101 frames (2.1 ms). These probes count samples without
  recording or playback. The remaining short gaps mean we must not claim
  complete end-to-end continuity yet.
- User confirmation of the single-instance listening retest is pending. The
  exact listening application/input selection was also requested. Further
  driver buffering/clock/client timing work should be a separate measured
  fix if the problem persists; do not infer a sample-rate mismatch from the
  symptom alone.

## R2 — Exclude the own virtual microphone

- Independent branch: `fix/exclude-virtual-input`, directly from upstream main,
  commit `97762e9`; integration equivalent: `4185ec3`.
- Filter by stable device UID, not display name. A renamed own virtual device
  remains excluded; an unrelated physical mic called Voice Enhancer remains
  usable. Driver detection uses the unfiltered input inventory.
- Resolve and bind the chosen input explicitly. Reject a saved own-virtual UID
  or own-virtual system default with a clear Settings instruction; missing
  saved physical devices fall back only to a safe default. Input selection
  after failure retries capture.
- `scripts/test-device-selection.sh`: 14 fixture checks passed. `--live`: 17
  total checks passed, own virtual device excluded, installed driver detected,
  USB Audio CODEC resolved, four selectable inputs. This live check does not
  change device defaults or capture audio.

## R3 — Coalesced reconnect and bounded retries

- Branch: `fix/reconnect-recovery`, commit `0adf647`. Stacked on the existing
  startup/native-format/single-instance fixes plus R2 (`2947bac`).
- Integration equivalent: `cb9201e`.
- A main-actor coordinator owns capture intent, delayed requests, generation
  checks and retries. Retries use 250/500/1000 ms backoff; exhaustion reports
  the last error while retaining intent so later device events can recover.
- HAL listeners observe device inventory and default-input changes. Saved
  selection is retained during safe temporary fallback; returning devices can
  be preferred again. Intentionally stopped capture stays stopped.
- Settings has a Reconnect microphone action. Unrelated menu-bar, login,
  localization and preset persistence changes remain separate.
- 15 deterministic recovery checks passed: success/idempotence, retries,
  exhaustion, late device recovery, retained UID, burst coalescing, Stop during
  debounce/permission and superseded completion. A controllable scheduler
  deliberately completes cancelled waits late.

## R4 — Wake recovery

- Branch: `fix/wake-recovery`, based on R3, commit `6a988f4`.
- Integration equivalent: `4029b23`.
- Workspace wake requests a three-second delayed restart through the same
  recovery coordinator. Device events can supersede it; intentional Stop is
  respected. Observer registration is removed when its owner is released.
- Recovery suite now passes 20 checks, including synthetic wake delay,
  coalescing with device changes, stopped intent and observer teardown.
- The Mac was not put to sleep; real sleep/wake remains a manual check.

Combined validation: linked Debug Xcode build passed. The local app started
USB capture at 44.1 kHz stereo and recovered from an initial engine
reconfiguration. The native UI automation connection failed repeatedly while
opening Settings, even after resetting it. Therefore Settings-button operation,
light/dark screenshots and VoiceOver checks are not claimed complete. Real
USB/Bluetooth unplug/replug, sleep/wake and follow-up listening remain manual
acceptance checks before upstream submission.

The user confirmed the previous single-instance listening build sounded good.
The newer R2/R3/R4 build is a separate validation step. Test app instances are
closed after checking; do not leave a manually launched copy beside Xcode.

## Remaining wondervip features — implemented 11 October 2026

The user explicitly requested all remaining features, including the original
icon update. They are implemented as separate contributions, not by merging
wondervip's two omnibus commits. No upstream PRs or public comments were opened.

### P1 prerequisite — audio-owned control updates

- Branch `fix/dsp-control-race`, independent from upstream main, `745e38f`;
  integration equivalent `f4b1a64`.
- Existing gain/threshold setters publish lock-free scalars. DSP stage state
  changes on the audio owner; prepare restores working overrides after factory
  setup. Same-factory recall deliberately resets tuning. Factory IDs/ABI stay
  unchanged. Whole grouped configuration transactions remain P2 work.
- Needed for persistence: baseline prepare discarded edited thresholds, and
  direct UI threshold/gain setters mutated live DSP state unsafely.
- Engine tests pass, including 10,000 concurrent control sequences and final
  waveform comparison. All four factory outputs compared byte-for-byte equal
  to baseline `19482d3` for generated mixed-tone fixtures (131,072 samples total).
- Release microbenchmark: 128 frames 5.71 us/block vs baseline 6.11; 512 frames
  20.49 vs 20.72; roughly 0.2% real time. These noisy single-run numbers do not
  establish a speedup or measure whole-app CPU. Formal allocation/TSan profiling
  remains a release-readiness check. Xcode's incremental engine build now runs
  every build to avoid linking stale native code.

### Menu-bar and Dock behavior

- Branch `feat/menu-bar`, independent from upstream main; commits `9c069d3`,
  `f4d0782`, `d49969b`. Standalone linked app build passed.
- Menu status, Open, bypass, reconnect and Quit; close/minimize hides the Dock
  entry while capture continues; reopening returns it. Capture errors badge
  the Dock entry. Window identifier/title fallback avoids secondary sheets
  owning capture. Adapted from wondervip's AppDelegate/MenuBarExtra direction.
- Integration uses its existing tested reconnect entry point, rather than
  duplicating the standalone branch's minimal retry implementation.

### Current-control persistence and Custom

- Branch `feat/settings-persistence`, based only on P1, `0d1fb1c`; integration
  equivalent `6ac1f8e`.
- Versioned working document remembers factory/Custom, its factory base, the
  two exposed thresholds, and global processing bypass. Restored before audio.
- Threshold edits promote Custom; factory recall resets edits but keeps the
  last Custom available. Preview uses the same retained factory base. Custom
  is never passed to the factory DSP ABI. Recall preserves global bypass.
- Debounced writes and quit flush; prior valid state and rejected bytes kept.
  Legacy wondervip keys preserved. Legacy Custom has no recoverable base:
  use Natural with a visible, localized recovery notice rather than guessing.
- 11 isolated round-trip/migration/corruption/version checks pass. This v1 stores
  today's editable controls, not the future named presets or Advanced chain.
  P2/P3 must explicitly migrate it to complete snapshots; P4 adds named presets.

### Launch at login

- Branch `feat/launch-at-login`, independent from upstream main, `a0b22a7`;
  integration equivalent `b4af32c`.
- Settings controller reflects actual SMAppService status, including pending
  approval/errors/external revocation. A user action registers/unregisters;
  startup reads status only. Nine service-state checks pass using an injected
  fake; tests did not enable or disable the real login item.
- Validate registration/approval on an installed signed app before release.

### Localization

- Branch `feat/localization`, stacked on clean reliability/P1/menu/persistence/
  login prerequisites; feature commits `045d524` and `354c575`.
- English, Simplified Chinese, Hindi, Spanish, Arabic, French, Bengali,
  Portuguese, Russian and Japanese; persisted selection and Arabic RTL.
- Retains wondervip's language data, fills missing login strings in seven
  original tables, and adds translated recovery/approval UI. System error
  details retain macOS's supplied language. Presets are actual keyboard-
  accessible buttons; settings/sliders have localized accessibility labels.
- 1,404 coverage/placeholder/formatting/fallback/RTL checks pass. These checks
  do not establish translation quality, native-language or VoiceOver review.

### Icon assets

- Branch `feat/wondervip-icon`, independent from upstream main, `dbfb1bc`;
  integration equivalent `8ee2bbe`.
- Existing wondervip PR #4 PNG assets are copied without pixel changes. App icon
  updates are separate from functional contributions. Menu status uses SF Symbols.

All feature branches are pushed to the user's fork. The integration branch
combines them for testing; do not submit its entire diff upstream. Dependent
branches must be replayed onto accepted prerequisites before individual PRs.
The standalone menu and current-control persistence app builds passed, as did
the localized and combined linked builds. Native UI automation has repeatedly
failed with a closed-pipe error, so menu reopen/Quit, login approval, language
layout, light/dark screenshots and real VoiceOver validation remain manual.
Do not claim these release checks complete solely from compilation/tests.

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

1. Keep upstream submissions on hold as requested. Prepare focused diffs after
   each prerequisite is accepted; coordinate wondervip attribution/ownership.
2. Finish manual UI/hardware/release acceptance for the reliability and remaining
   original-PR features. Login registration is opt-in; test a signed installed
   app. Do not leave a manually launched test copy alongside Xcode.
3. P1 is implemented. P2 now adds full coherent engine snapshots/readback; P3
   migrates the current v1 working document; P4 adds named user presets before
   the larger Advanced UI. Current Custom is not a named-preset library.
4. Continue accurate metering, bypass and editor work per the delivery plan.
