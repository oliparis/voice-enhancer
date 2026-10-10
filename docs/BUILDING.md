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
