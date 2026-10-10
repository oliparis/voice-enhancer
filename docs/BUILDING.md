# Building Voice Enhancer

## TL;DR

```sh
./scripts/build.sh            # Build engine, driver, app.
sudo ./scripts/install.sh     # Install the HAL driver.
```

## Prerequisites

- macOS 13 (Ventura) or later — we use modern Core Audio APIs.
- Xcode 15 or later.
- CMake 3.20+ (`brew install cmake`).
- A Developer ID Application certificate, if you want to ship signed builds. Local development builds run unsigned.

For contributors working on the DSP only: you can build and test `AudioEngine` on any Linux or Unix with a C++17 compiler. The driver and app are macOS-only.

## Components

The project has three independent build artifacts:

1. **`AudioEngine`** — C++17 static library (CMake). No Apple dependencies.
2. **`VirtualDriver`** — HAL plugin `.driver` bundle (CMake).
3. **`VoiceEnhancerApp`** — macOS `.app` bundle (SwiftPM for compile-check, Xcode for the shipping build).

Each has its own `CMakeLists.txt` or `Package.swift`. The top-level driver is `scripts/build.sh`, which stitches them together.

## Build: everything (recommended)

```sh
./scripts/build.sh              # Release build.
./scripts/build.sh --debug      # Debug build, symbols included.
./scripts/build.sh --engine-only
./scripts/build.sh --driver-only
```

Artifacts:

- `AudioEngine/build/libvoice_enhancer.a`
- `AudioEngine/build/voice_enhancer_tests`
- `VirtualDriver/build/VoiceEnhancer.driver`
- `VoiceEnhancerApp/build/Build/Products/Release/Voice Enhancer.app` *(when an Xcode project is present)*

## Build: AudioEngine in isolation

Fastest feedback loop for DSP work — no macOS needed:

```sh
cd AudioEngine
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
./build/voice_enhancer_tests
```

## Build: VirtualDriver

```sh
cd VirtualDriver
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
cmake --build build -j
```

Output: `VirtualDriver/build/VoiceEnhancer.driver` (a bundle directory).

## Build: VoiceEnhancerApp

Two paths:

1. **Shipping build (Xcode project required).**
   Generate the project with `cd VoiceEnhancerApp && xcodegen generate`,
   then open it and build the `VoiceEnhancer` scheme. The project is derived
   from `VoiceEnhancerApp/project.yml` and is not checked into version control.
   CI builds this linked app without signing as well as checking SwiftPM;
   the SwiftPM stub alone does not validate the shipping C/Objective-C bridge.

2. **Compile check (SwiftPM).** Works everywhere.

    ```sh
    cd VoiceEnhancerApp
    swift build
    ```

   This compiles with a stub engine — the Swift code checks for the `VoiceEnhancerEngine` module and silently falls back to a pass-through if it's absent. Useful for catching SwiftUI regressions in CI without a C++ toolchain configured.

## Audio tap regression checks

Run `cd VoiceEnhancerApp && swift run -c release TapSupportTests` to exercise
tap installation/removal exception handling without microphone permission or
physical audio devices. Both SwiftPM and the shipping app link the same native
helper. The runner covers successful operations, partial installation cleanup,
duplicate taps, missing exception reasons, removal failures and a later success.

The native helper uses Objective-C because Swift error handling cannot catch an
`NSException` raised by AVAudioEngine. Failed capture graphs are discarded before
a subsequent start; the sample format and DSP processing path are unchanged.
Device-specific format/reconnect recovery still requires separate fixes and
manual hardware validation. This guard is adapted from wondervip's
[PR #4](https://github.com/aheadly-tech/voice-enhancer/pull/4).

## Native microphone formats

Capture installs a native-rate/channel-count input tap and streams channel 1
through AudioConverter to 48 kHz mono float32. It never opens an output route.
This supports interfaces that expose separate input-only and output-only Core
Audio devices; a muted playback mixer still requires a valid output and fails
with `-10875` on these devices.

The converter retains phase/filter history, stages fixed 128-frame native
slices, and emits at most 1024 frames per DSP call. Large tap buffers are split,
not dropped. Buffers and converter are allocated and warmed before capture;
48 kHz bypasses resampling. No application allocation, logging or dispatch is
performed in the tap. The additional staging delay is at most 16 ms at 8 kHz,
2.9 ms at 44.1 kHz, plus the converter's filter delay.

`cd VoiceEnhancerApp && swift run -c release TapSupportTests` tests continuity
across irregular blocks (including 1 and 32768 frames), signal level, duration,
30-second fractional-rate conversion, downsampling rejection, empty buffers,
and the existing tap exception checks. These synthetic checks need no devices.

For an opt-in hardware smoke test, run:

```sh
cd VoiceEnhancerApp
swift run -c release TapSupportTests --live-input <AudioDeviceID>
```

Use a current numeric Core Audio input-device ID (not a persisted UID). This
captures for two seconds and reports frame counts/conversion errors only. It
does not save or play microphone audio, change device defaults, or use the HAL
ring. Microphone access must be allowed for the invoking application. Verify
the full app and virtual-mic routing separately.

Local validation on 2026-10-10: Xcode 27, USB Audio CODEC input-only device,
2 channels at 44.1 kHz; 83,790 native frames -> 91,080 converted frames,
no errors. 82 synthetic checks passed. DSP/driver code is unchanged.

## Capture startup and cancellation

`cd VoiceEnhancerApp && swift run -c release CaptureLifecycleTests` checks
permission completion after stop, newer starts superseding pending requests,
task cancellation, and a successful retry after permission failure. Graph
mutation runs on the main actor with no suspension once permission completes.
The view model ignores stale completions and makes repeated `start()` calls
idempotent. Configuration notifications only restart a stopped engine or one
whose hardware input format changed; delayed notifications from a healthy USB
binding must not create a restart loop.

## One capture instance

Keep one Voice Enhancer app running when testing. Xcode can launch its own copy
alongside a manually opened build. Both copies previously wrote to the same
single-producer ring, corrupting audio even though each converter ran at the
correct rate. Startup now detects another running app with the same bundle ID
and reports an error before configuring capture or bumping the writer session.
Quit the other copy and reopen the desired build. This check does not change the
shared-memory protocol or require a driver reinstall.

Local reproduction (2026-10-10): two app instances were present during a report
of periodic chopping. After closing the older test copy, the producer supplied
240,048 frames over five seconds. A separate four-second virtual-device probe
received 192,000 frames, with zero exact-silence frames after startup warmup.
Subjective confirmation from the user's listening test remains separate.

## Input selection regression checks

Run `./scripts/test-device-selection.sh` on macOS. This compiles the production
model/enumerator with fixture tests: renamed virtual device, same-named physical
microphone, missing saved input, safe fallback, virtual default, and no input.
`--live` additionally checks the installed driver and current input inventory;
it neither captures audio nor changes the system defaults.

The own virtual microphone is identified by its stable UID and excluded from
selectable inputs. Driver detection uses the unfiltered inventory. Capture binds
a resolved input explicitly; an unsafe virtual default or saved virtual UID
produces an actionable error rather than reading the app's own output. Selecting
another input after failure retries capture. Adapted from wondervip PR #4's
virtual-input filtering, extended to cover implicit default routing.

## Capture reconnect regression checks

`cd VoiceEnhancerApp && swift run -c release CaptureRecoveryTests` exercises
coalesced device events, ordered state changes, bounded retry/backoff, exhausted
retries followed by recovery, preserved selection, Stop during debounce or
permission, and stale completions. Fixtures deliberately complete cancelled
operations late; tests use a controllable scheduler, not physical devices.

The app observes input-default and device-inventory changes, retains the saved
input UID during fallback, and retries failed capture up to three times with
250/500/1000 ms backoff. Later device changes or the Settings reconnect button
can recover after exhaustion. Intentionally stopped capture stays stopped.
This adapts the reconnect direction in wondervip PR #4 without importing its
menu-bar, login, localization or settings-persistence changes. USB/Bluetooth
unplug/replug and VoiceOver/light/dark checks remain manual acceptance checks.
