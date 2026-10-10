# Repository Guidelines

## Project Structure & Module Organization

- `AudioEngine/`: portable C++17 DSP library. Public headers live in `include/voice_enhancer/`, implementations in `src/`, Swift interop in `bridge/`, and tests in `tests/`.
- `VirtualDriver/src/`: macOS Core Audio HAL plugin exposing the virtual microphone.
- `VoiceEnhancerApp/Sources/`: SwiftUI app organized into `App/`, `Audio/`, `Models/`, `ViewModels/`, `Views/`, and `Resources/` (including assets).
- `shared/RingBuffer.h`: shared-memory audio contract between app and driver.
- `scripts/`: build, install, uninstall, and notarization helpers. Read `docs/ARCHITECTURE.md`, `docs/BUILDING.md`, and `docs/CONTRIBUTING.md` before cross-component changes.

## Build, Test, and Development Commands

Full development requires macOS 13+, Xcode 15+, and CMake 3.20+. DSP-only work also supports Linux.

- `./scripts/build.sh`: build engine, run tests, and build driver/app. Install XcodeGen for the full app build from `VoiceEnhancerApp/project.yml`; otherwise the script can fall back to SwiftPM.
- `./scripts/build.sh --debug`: build with debug symbols.
- `./scripts/build.sh --engine-only`: build and test only the DSP engine.
- `ctest --test-dir AudioEngine/build --output-on-failure`: rerun configured engine tests.
- `cd VoiceEnhancerApp && swift build`: compile-check Swift using the stub engine.

Run the generated app through Xcode for local UI/audio testing. `sudo ./scripts/install.sh` installs the driver and restarts `coreaudiod`.

## Coding Style & Naming Conventions

Use four-space indentation and same-line opening braces. No formatter or linter is currently enforced; match surrounding code.

C++ uses C++17, `PascalCase` types, `snake_case` functions, `m_` members, header guards, and `noexcept` DSP functions. Swift uses Swift 5.9+, one view per file, and `ObservableObject` view models for shared logic.

Never allocate, lock, block, or log in audio processing callbacks. Keep C ABI changes additive and factory preset identifiers synchronized across C++, C, and Swift.

## Testing Guidelines

`AudioEngine/tests/test_engine.cpp` uses a custom assertion runner, registered with CTest. Name functions `test_<behavior>` and register them in `main()`. Add deterministic tests for new DSP stages and regressions. No numeric coverage threshold is configured. Manually verify driver routing and app behavior; CI compile-checks Swift.

## Commit & Pull Request Guidelines

Use short imperative commit subjects, matching history: `Guard AVAudio tap installation`. Keep PRs focused; describe behavior, rationale, validation, and related issues. DSP changes need measured evidence and CPU-impact notes. UI changes need screenshots or recordings, light/dark checks, and VoiceOver validation.
