# Channel strip and advanced processing plan

Status: proposed implementation plan, 10 October 2026. This document specifies future work; the companion [interactive layout study](channel-strip-concept.html) uses illustrative data and does not process audio.

Upstream delivery is specified in the [PR-by-PR contribution plan](UPSTREAM_DELIVERY_PLAN.md), based on the maintainer's feedback on PR #4. The five phases below are product milestones, not five large PRs. Develop contributions from accepted upstream code; the full wondervip branch is not a prerequisite.

## Product direction

Build one voice channel with two presentations of the same processing state. **Simple** keeps the existing preset-led experience. **Advanced** reveals an ordered channel strip, controls for every processor, independent bypass, and measurement displays that explain what the processing is doing. Switching presentations must never change the sound.

The main interaction is: choose a starting sound, see where the signal is being changed, adjust that processor, bypass it to compare, and save the result. Preserve Natural, Broadcast, Clarity and Warm, including their identifiers and established tuning. Presets in Advanced become a compact recall menu that sets the visible controls, routing and bypass states.

Ship an extensible serial chain of built-in processors. Support reordering the voice processors in the first complete Advanced release, with input and output utilities anchored at the ends. Design for additional and repeated processor instances without initially taking on plug-in hosting, parallel buses or a general patching canvas.

## Research and design rationale

These are selected reference products, not an objective ranking of DAWs. The observations below come from official manuals; the design choices are our synthesis.

- **Cubase Channel Strip:** puts distinct processing modules together, provides strip bypass and preset management, and allows modules to be dragged into a different order. Adopt a visible ordered strip and consistent module headers. [Cubase manual](https://www.steinberg.help/r/cubase-pro/15.0/en/cubase_nuendo/topics/mixconsole/mixconsole_channel_settings_channel_strip_equalizer_r.html)
- **SSL Channel Strip 2:** groups related controls into recognizable sections, has separate processing switches and gain-reduction indicators, and exposes filter/EQ/dynamics routing. Adopt the legible control grouping and explicit signal order; use larger graphs and native text entry suited to this app. This reference is SSL's documented legacy v1 interface. [SSL guide](https://support.solidstatelogic.com/hc/en-gb/articles/4408686107037-SSL-Channel-Strip-2-Plug-in-V1-0-Legacy-User-Guide)
- **Ableton Live Device View:** gives every device a consistent activation control and supports expanded device views and A/B states. Adopt a compact overview with a larger selected-processor editor, so the interface can accommodate more processors. [Live manual](https://www.ableton.com/en/live-manual/12/working-with-instruments-and-effects/)
- **FabFilter Pro-Q 4:** combines editable EQ curves with pre/post spectra, resolution controls, freeze and frequency zoom. Adopt direct curve manipulation, a clear distinction between response and measured spectrum, and an expandable frequency display. [Analyzer documentation](https://www.fabfilter.com/help/pro-q/using/analyzer), [display workflow](https://www.fabfilter.com/help/pro-q/using/eqdisplay)
- **FabFilter Pro-C 3:** relates the transfer curve to scrolling input/output levels and gain reduction, with coordinated scales and precise meters. Adopt this combination for compression and a simpler corresponding display for the limiter. [Displays and metering](https://www.fabfilter.com/help/pro-c/using/displays)

The result should feel like a compact professional channel strip: clear signal order, controls grouped by purpose, persistent input/output meters, and a large useful display. Use understated surfaces, readable ticks and numeric values, and a restrained semantic palette. Frequency curves, live audio and gain reduction need different line styles as well as colors. Avoid decorative waveform animation.

## What the repository does today

This inspection describes the local wondervip-based branch at `e8c93ec`. Its Custom persistence, localization, menu-bar and reconnect changes are unmerged. Upstream at `19482d3` already includes input UID persistence, threshold controls, voice preview, some reconnect handling and continued processing after window close, but not those complete extensions. Port the product plan onto upstream using the contribution plan; treat migration of wondervip-only state as optional compatibility rather than a dependency.

The implemented order in `AudioEngine/src/Engine.cpp` is input trim, HPF, compressor, EQ, de-esser, combined preset/user output gain, limiter, output measurement. The output gain is **before** the limiter. Preserve that distinction in the new UI.

- The C++ stages already expose considerably more tuning than the Swift UI. The bridge exposes preset selection, global bypass, input/output gain and two threshold overrides; it has no full configuration readback or individual-stage bypass.
- `Preset.cpp` holds four factory configurations. Swift duplicates their threshold defaults. Swift's fifth entry, Custom, saves only compressor/de-esser thresholds and does not persist the original factory base. Exact historical Custom reconstruction is therefore not always possible.
- `AudioViewModel` polls four atomic readings at 60 Hz and smooths them with fixed per-tick coefficients. Engine readings replace the preceding block's values, so a peak in an intervening callback can be missed. There is no RMS, spectrum, limiter reduction or per-stage level telemetry.
- Gain and threshold setters write ordinary DSP fields directly. Aligned floating-point stores do not establish C++ thread safety. The documented atomic/smoothed setter contract is ahead of the implementation. Fix the control path before exposing continuous manipulation.
- The high-pass is fixed at 24 dB/octave. EQ has four fixed roles: low shelf, two bells, high shelf. De-esser attack/release are fixed at 1/30 ms. Compressor auto makeup is enabled when applying a preset. Limiter release defaults to 50 ms and lookahead is approximately 2 ms.
- Global bypass currently retains input gain but skips downstream processing and the limiter delay. It is not a latency-aligned comparison. The limiter is sample-based; it does not implement true-peak limiting.
- Voice preview owns another DSP bridge. It must receive the same complete state as live processing. The app continues processing when its window closes; analyzer lifecycle must respect this.

The architecture/build/contribution documents were reviewed. Some comments and documents describe features more strongly than their implementation; tests and implementation take precedence during this work.

## Modes, recall and state ownership

### Simple

Keep the four named factory cards and a Custom card, the master enhancement switch, compact input/output and reduction meters, device/settings access and voice preview. Retain access to the two existing threshold adjustments as fine tuning. Default new users to Simple; remember the chosen mode and window size.

Custom represents the complete last edited chain. If the user returns from Advanced, show Custom (with optional “based on Broadcast” text) and retain every edit, reordered stage and bypass flag. Merely opening Advanced or returning to Simple sends no DSP command. Clicking a factory card deliberately recalls its complete configuration; offer Undo and keep the last custom snapshot recoverable.

### Advanced

Use a toolbar with Simple/Advanced, a compact preset menu, modified-state indicator, save/reset, Undo/Redo, A/B and the master enhancement switch. Device and virtual microphone status stay visible without taking primary space. Factory presets remain immutable; Save creates a named user preset.

Loading a preset applies one transaction containing all processor settings, enabled flags and its saved order (the original factory order for factory presets). It never changes input device, monitor volume, analyzer preferences, window state or master bypass. Recall the same factory again to restore defaults even if its name has not changed. Manual edits show “Broadcast · Modified”; exact return to its values clears the modified marker. Undo a drag as one gesture, rather than hundreds of slider events.

### Named user presets and startup recall

Users can save the complete current chain under their own name, recall it, rename it, update it, or use Save As to create another preset. Each user preset has a stable ID independent of its display name. Saving captures every processor parameter, band setting, bypass flag and processor order. Ordinary control edits update the working state; they only overwrite a named preset when the user chooses Save. Keep the factory cards prominent in Simple, with a secondary My Presets picker; Advanced lists Factory and My Presets in its compact recall menu.

Automatically restore the last-used factory or named user preset on startup, including its identity and displayed name. Also persist the complete last working snapshot: if the user quit with unsaved edits, restore those exact settings and show “Preset name · Modified” rather than silently discarding them or overwriting the saved preset. An unnamed custom chain restores as Custom. Store the preset ID/revision and working snapshot together so startup cannot pair one preset's name with another chain's settings.

Restore and validate the working state before starting audio delivery, so startup does not briefly process with a default preset. Restore the separately persisted master bypass and presentation mode as well. Debounce working-state writes off the audio thread and flush on orderly quit; after an abrupt termination, restore the last successfully persisted snapshot. If the referenced preset was removed, retain the working snapshot as Custom. If the state file is invalid, try its recoverable previous version, then Natural with a visible recovery notice while retaining the invalid file. Add startup tests for unchanged factory/user presets, modified named presets, unnamed Custom, renamed/deleted presets and recovery after interrupted writes.

A/B stores two full chain snapshots; it is independent of global bypass. Initially these are exact audio comparisons at the configured levels. Optional loudness-matched comparison belongs in recorded preview, explicitly labelled and excluded from virtual microphone output.

### Persistent document

Introduce a versioned `ChainState` with a document revision, processor instances in order, stable instance IDs, stable processor type IDs, per-processor schema version, parameters, enabled flags, EQ-band IDs/enabled flags, and optional source-preset ID/revision. Store master bypass, presentation mode, devices and analyzer preferences separately from recallable sound settings. Serialize user presets and the last custom state atomically outside the audio thread; keep a recoverable previous file.

Factory snapshots are expanded from C++ through the C ABI. Remove duplicated Swift numeric defaults. Preserve factory IDs 0–3; Custom remains an app concept rather than a new C++ factory ID.

Migration: back up the legacy defaults once. For a saved factory ID, expand that factory and overlay persisted threshold values that actually exist. For legacy Custom, recover its two saved thresholds on Natural as the documented fallback when no base is available; retain the legacy keys and mark the migrated snapshot's base as unknown. This matches the startup fallback more closely than inventing a base preset. If migration happens while a live configuration is available, capture that complete state instead. Unknown processor types/versions are preserved in serialized data and shown as unavailable, bypassed placeholders; never silently drop or substitute them. Unsupported document versions retain the original file and present a recoverable load error.

## Advanced layout and interactions

Target approximately 1180 × 780 points on a desktop, with a useful 900 × 650 compact arrangement; validate on a 13-inch screen. Preserve Simple's compact window. Remember the two sizes separately and replace the current content-size-only restriction where needed.

1. **Toolbar:** modes, preset recall and comparison commands.
2. **Strip:** anchored input section on the left, ordered processor cards in the middle, anchored output section on the right. Every card has a name, bypass control, compact meaningful visualization, primary controls and a numeric summary. Card order is processing order.
3. **Focus editor:** selecting a card opens a large graph and all of that processor's controls below. Selection does not change audio. EQ gets the largest frequency graph; compressor gets transfer/history displays. This avoids fitting every advanced parameter into a narrow card.
4. **Persistent meters:** input/output peak and RMS, peak hold and clip indicators remain visible while browsing processors. Output detail adds loudness and limiting information.
5. **Footer:** sample rate, DSP latency, routing status and analyzer status. Distinguish DSP latency from unmeasured device/IPC latency.

When the strip grows, scroll its middle section horizontally while anchoring input/output. At compact widths, use a vertical ordered overview with the editor beside or below it; keep selection and actual signal order stable. Collapse cards without changing DSP state.

Knobs support vertical dragging, fine adjustment with Shift, keyboard increments, double-click numeric entry and a labelled reset command. Values always include Hz/kHz, ms, dB, dBFS or ratio as appropriate. Frequency/time controls use useful logarithmic scaling. EQ graph dragging has an equivalent keyboard/numeric route. Drag handles and Move Earlier/Move Later commands both support reordering. All bypass states have explicit “Active”/“Bypassed” text.

Preserve localization and RTL support. Treat the audio sequence as an explicitly ordered technical diagram with direction arrows and numbered stages; keep its processing order stable while localizing surrounding layout and labels. Check VoiceOver focus after moving a stage, high contrast, reduced motion, keyboard access, and light/dark appearance. Meter announcements are opt-in summaries, not 60 spoken updates per second.

## Processor controls and feedback

All ranges below are proposed UI/validation bounds to verify against the DSP and listening tests, not claims about current supported ranges. Reject non-finite values at the API and validate frequency against the actual sample rate.

### Input trim

Gain −24 to +24 dB, unity reset and polarity inversion; bypass returns trim/polarity to unity without forgetting settings. Show raw captured peak/clip indication separately from the post-trim signal so input overload cannot be concealed by turning gain down. Digital trim does not repair clipping already present at the microphone.

### High-pass filter

Cutoff 20–500 Hz, independent bypass, and a visible 24 dB/octave slope label for the existing algorithm. Show the actual response over pre/post spectra with emphasis on the low-frequency region. A draggable cutoff handle and frequency readout control the same parameter. Additional 12/48 dB slopes are a later DSP extension with their own response tests; the initial UI must not show a nonfunctional slope selector.

### Compressor

Expose threshold (−60–0 dBFS), ratio (1:1–20:1), knee (0–24 dB), attack (0.1–100 ms), release (10–1000 ms), Auto/Manual makeup, and manual makeup (−12–24 dB). Show the computed auto gain as a read-only value. Preserve the existing peak detector and auto-makeup defaults; do not describe the heuristic auto makeup as measured loudness matching.

Feedback: input/output peak and RMS meters, gain reduction meter with current/maximum values, threshold line, actual transfer curve with a detector operating point, and 4–8 seconds of input/output/reduction history. Distinguish gain reduction from makeup so added output level does not obscure compression. Parallel mix and RMS detection can be separate later enhancements rather than controls for nonexistent DSP.

### Equalizer

Expose all four bands' frequency, gain and Q; add per-band bypass in addition to whole-EQ bypass. Initial band roles stay low shelf, bell, bell, high shelf. Proposed ranges: 20 Hz to min(20 kHz, 0.45 × sample rate), ±18 dB, Q 0.1–10 where meaningful to the actual filter design. Show shelf shape controls only when they affect the implementation.

Provide draggable nodes, individual band responses and their combined response, separate pre/post spectra, band selection and exact numeric fields. Label EQ gain and spectrum level on separate axes. The response display comes from the same coefficient/design functions as the DSP, including the existing shelf behavior. Variable band count and band type belong in the state format now; their UI and DSP expansion follow independently.

### De-esser

Expose crossover (2–12 kHz within Nyquist limits), threshold (−60–0 dBFS), ratio (1:1–20:1) and maximum reduction (0–24 dB). Add attack/release setters with existing 1/30 ms defaults, and validate proposed 0.1–20 / 5–250 ms ranges.

Show the actual high-frequency split/detection region over pre/post spectra, detector level relative to threshold, and high-band gain reduction plus history. The current algorithm compresses the high-pass-derived band above the crossover; do not draw a narrow selectable bell or label reduction as full-band compression. A detected-band/removed-signal Listen action is a recorded-preview feature first. It never replaces the signal sent to the virtual microphone.

### Output gain

Expose the effective gain before the limiter, initially −24 to +24 dB, with unity reset/bypass and a clear “Pre-limiter gain” label. Fold legacy preset gain plus user offset into one visible effective parameter during migration. Factory recall restores the existing preset gain. Show pre-limiter peak/RMS and remaining headroom. Keep this section directly before the limiter in the first release.

### Limiter and output

Expose ceiling (−12–0 dBFS), release (10–500 ms), bypass and read-only lookahead/latency. Add limiter applied-gain telemetry. Show pre/post levels, gain-reduction history, ceiling reference, clip latch and post-limiter output peak/RMS. The final output meter is after all audio-affecting processing; monitor playback volume is a separate control.

Initial limiter labels say sample peak. Add validated true-peak measurement and momentary/short-term loudness in the measurement milestone. A true-peak meter does not turn the limiter into a true-peak limiter. Integrated loudness with explicit Start/Reset can follow, especially for preview recordings; do not impose a broadcast loudness target on a conferencing microphone.

Audit isolated transients before promising a hard ceiling: current limiting releases gain while the future transient is still in its delay line, and the existing ceiling test permits a margin after settling. If corrections alter the sound, version the limiter algorithm/preset behavior and retain the legacy version for migrated snapshots until intentionally upgraded.

## Bypass, order and latency semantics

Every audio-affecting module, including trims and limiter, can be bypassed independently. Preserve its controls and position, dim its response curve, display real pass-through levels, and show zero **applied** reduction. Global bypass overlays the individual states and never changes them.

Define the new master “Enhancement” bypass as input trim followed by a latency-matched dry route to output, bypassing the processors, pre-limiter gain and limiter. This retains the existing input-trim convention. Provide raw comparison in preview when needed. Bypassing the limiter truly removes limiting; show the resulting status plainly and keep output clipping feedback active. Do not insert a hidden processor that defeats the bypass.

Use short, tested gain ramps/crossfades, initially 5–20 ms, for bypass and disruptive changes. Compensate dry paths for lookahead; use complementary linear fades for highly correlated dry/wet audio to avoid equal-power gain bumps. Keep latency constant across bypass in the initial chain (the limiter's existing delay budget). Re-enabling a stage must not expose stale filter/envelope state: keep current cheap processors running during bypass and ramp their contribution. Suspension for future expensive processors needs an explicit warm-up/tail policy.

Initially allow HPF, compressor, EQ and de-esser to move within the serial processing region. Input trim, pre-limiter gain, limiter and final measurement retain their anchored roles. Reorder is one undoable transaction. Preserve stable instance identity, selection and control values across moves. More instances and new processor types can later be inserted through an Add Processor menu backed by the registry; no empty promised processors in the shipping UI.

Structural swaps use two independently owned, preallocated processing plans, not concurrent processing through shared mutable stage objects. Warm the replacement plan from live input for a bounded transition period, align latency and crossfade, then reclaim the old plan on the control thread after audio acknowledgement. Bound this temporary CPU cost and coalesce rapid reorder requests. Future processors report latency/tails; changes exceeding the prepared latency capacity require an explicit graph reprepare. Never silently increase buffer allocations in the callback.

## Measurement architecture and acceptance targets

Measurement must reflect actual samples and applied DSP gains. UI refresh rate is independent of measurement rate.

### Level and reduction telemetry

At stage boundaries accumulate sample maximum, sum of squares, sample count, clip count, and applied gain-reduction extrema; include frame position, configuration revision and stable instance ID. Use bounded, preallocated SPSC telemetry queues. A dedicated consumer aggregates all blocks into presentation windows; preserve overflow peaks/clip counters in a bounded audio-owned accumulator for the next successful publication. If history is lost, expose a gap/discontinuity rather than fabricating continuity. Audio never waits for a reader.

Publish peak/RMS/GR at up to 60 display frames per second while visible; aggregate measurements across all contributing audio blocks. Use actual elapsed time for display decay. Initial visual targets: instantaneous displayed attack on the next frame, 1 s peak hold, approximately 20 dB/s peak fall; tune by usability testing. Numeric hold and clip latches are separate from the moving bars. Provide click-to-reset maxima and clip counts.

Store gain reduction consistently internally (document existing negative-dB compatibility); display “4.2 dB reduction” as a positive magnitude. Threshold plots use detector levels, while output level meters show the actual output. Use `−∞` for silence, retain readings over 0 dBFS internally and distinguish headroom excursions from confirmed device clipping.

Acceptance targets: generated tone/burst peak and RMS error ≤0.1 dB; measured GR within ≤0.1 dB of the applied gain reference; no lost maximum during UI stalls within or beyond queue capacity; visible meter age normally below 50 ms. These are proposed test gates, not measured current performance. Account for the DSP's fast approximate logarithms when choosing reference calculations.

### Frequency analysis

Capture pre/post samples for the selected frequency processor into a separate bounded SPSC queue. Compute FFTs on a background analysis worker, never on the render callback or SwiftUI thread. Reuse preallocated FFT plans/work buffers; make the mono C++ DSP core independent of Apple frameworks. A portable analyzer implementation or app-side Accelerate adapter can be benchmarked behind a narrow analysis interface.

Default: Hann-windowed 2048-sample FFT, 75% overlap at 48 kHz, logarithmic frequency scale, calibrated amplitude, adjustable smoothing and freeze. This gives ~23.4 Hz bin spacing and a ~42.7 ms acquisition window; a 4096-sample detail option gives ~11.7 Hz bins with a ~85.3 ms window. Neither increases audio-path latency. Render spectra at 30 Hz by default, allow 60 Hz if profiling supports it. Display resolution/speed tradeoffs in analyzer settings.

Overlay synchronized pre/post windows, aligned for any processor delay. Keep spectrum tilt (default 0 dB/oct for unambiguous calibration) separate from the filter response. A response curve is analytical; an output spectrum is measured. Never estimate output by multiplying the input spectrum by a static curve for dynamic processors. De-esser reduction shading is labelled high-band gain information, not an exact spectral subtraction.

The selected frequency processor gets full paired spectra. Other frequency cards show their correct response or cached, timestamped lower-rate summaries. Always-on meters cover all stages. If a queue overflows, drop visualization data, increment a gap counter and reset FFT continuity. When hidden or in Simple, turn off unneeded FFT subscriptions and expensive drawing while audio and essential peak/clip aggregation continue.

### Loudness and true peak

Use the specified K-weighted algorithms and validation material before labelling readings LUFS or dBTP. Momentary uses 400 ms and short-term 3 s; show a warming-up state before a complete window. RMS is explicitly labelled RMS dBFS. [EBU measurement guidance](https://tech.ebu.ch/loudness/), [ITU-R BS.1770-5](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/en)

Run loudness/true-peak analysis on a worker where feasible, with explicit gap/validity handling. Integrated measurement cannot remain certified as continuous after dropped samples. Validate mono channel weighting and independent true-peak fixtures; an oversampled analyzer is independent of audio-path limiting.

## Engine and application design

### Engine control boundary

Introduce a bounded prepared `ProcessingPlan` and a `ProcessorDescriptor` registry. Each descriptor defines stable type/parameter IDs, parameter units/ranges/defaults/scales, schema version, latency/tail capabilities and supported telemetry/editor type. Each instance owns its DSP state. Start with a fixed-capacity serial plan (proposed maximum 16 instances) rather than an unrestricted graph. Capacity exhaustion produces a recoverable validation error.

The control side owns an editable model; the audio side exclusively owns live DSP state. Send validated, immutable, fixed-size configuration transactions through a preallocated queue/mailbox with release/acquire publication and acknowledgement. Presets, recall and grouped edits commit together at block boundaries. Coalesce slider traffic on the control side; a full queue reports busy and retains the newest desired revision for retry instead of silently losing the final value. Do not use a large `std::atomic<Struct>` that may lock internally, or a double buffer that the writer can overwrite while the reader still uses it.

Precompute expensive filter designs outside the callback. Smooth continuous gain/threshold controls in bounded work; use a tested stable filter transition strategy for frequency/Q changes. Avoid arbitrary interpolation of IIR coefficients without stability tests. Declare which controls ramp and which use plan/filter crossfades. Steady-state factory output should remain compatible once transitions settle.

Additive C ABI candidates: `ve_engine_get_capabilities`, `ve_get_processor_descriptor`, `ve_get_factory_chain`, `ve_engine_submit_chain`, `ve_engine_get_applied_revision`, `ve_engine_read_telemetry`, `ve_engine_set_analysis_subscription`, and `ve_engine_get_latency_frames`. Final names follow existing naming conventions. Use version/size fields, fixed-width IDs, caller-provided storage/counts, explicit status codes and no C++ ownership crossing the boundary. Descriptor/configuration reads are control-thread APIs; processing stays `noexcept` and bounded. Retain existing setters as adapters into the same transaction path, including their documented multi-producer semantics via off-audio serialization.

### Swift boundaries

- `AudioViewModel`: lifecycle, devices, routing and top-level mode only.
- New `ChainViewModel`: editing, transaction submission, engine acknowledgement, selection, undo/redo and A/B.
- New `PresetStore`/migration service: factory readback, saved snapshots, modified detection and persistence.
- New `MeterStore`/`AnalysisStore`: immutable latest frames and histories scoped to drawing views, avoiding a full app redraw for every meter update.
- New reusable `ProcessorCard`, `ParameterControl`, `LevelMeter`, `GainReductionMeter`, `SpectrumView`, `ResponseCurveView` and `DynamicsHistoryView`; typed processor editors above the common parameter metadata.
- `AudioEngineBridge`: versioned state/configuration and telemetry mapping; update the SwiftPM stub with matching capabilities and clearly labelled preview fixtures.
- `VoicePreview`: apply the same snapshot/revision as the live engine; captured raw audio can be re-rendered through A/B states. Keep preview measurement context visibly separate from live microphone telemetry.

Use SwiftUI Canvas/Path for graphs initially; profile before adding Metal. Separate static grid/labels from changing traces. Cancel analysis work/subscriptions when the relevant view disappears, and resume with fresh timestamps when it returns. Reconnect/reprepare restores the latest acknowledged complete chain rather than just a factory ID. Existing shared-memory audio format and virtual driver need no change for this feature; telemetry stays within the app process.

## Delivery sequence

These milestones describe the finished product. For upstream, follow the smaller P-series and independent reliability R-series PRs in [UPSTREAM_DELIVERY_PLAN.md](UPSTREAM_DELIVERY_PLAN.md). In particular, named presets and accurate existing meters should become useful before the complete Advanced UI, and the processor registry refactor should land close to its concrete reordering use case.

### 1. Baseline and compatibility fixtures

Capture all four factory configs and deterministic output fixtures, actual limiter latency, existing persisted-default examples, and representative CPU/render-callback timings. Add transient ceiling probes and concurrency diagnostics before relying on current comments. Document intentional corrections separately from behavior-preserving changes.

Exit: reproducible baseline, migration examples and agreed layout/control semantics.

### 2. Safe state, recall and independent bypass

Add the versioned state/registry, validated transaction boundary, complete preset readback, gain/parameter smoothing and latency-aware bypass. Convert legacy setters, add per-band bypass and the selected de-esser controls. Preserve current factory tuning and add revision acknowledgement.

Exit: headless tests prove coherent recall, all controls, per-stage bypass, same-preset reset, bounded transitions and stable latency; no UI-thread mutation of live DSP.

### 3. Accurate telemetry and analyzer foundation

Add stage peak/RMS/GR, limiter telemetry, clip/hold counters, history and analysis subscriptions. Implement selected-stage pre/post FFT and actual response data. Establish timing/accuracy/overflow tests. Add validated loudness and true-peak measurement here or as an explicitly tracked sub-milestone before those labels appear in the UI.

Exit: telemetry agrees with reference signals; UI stalls and hidden windows cannot affect audio; CPU cost is measured.

### 4. Complete Advanced UI and unified presets

Implement mode switch, responsive strip/focus editors, all initial processor controls, bypass, preset menu, named user preset management, last-used preset/working-state startup recall, migration, Undo/Redo, A/B and snapshot-based preview. Keep Simple's cards and menu-bar workflow intact. Capture light/dark screenshots and keyboard/VoiceOver evidence.

Exit: every visible control operates on actual DSP, all graphs describe their real measurement point, and switching modes is audibly/state-transparent.

### 5. Flexible order and release qualification

Enable validated reordering of the middle processors using prepared plan swaps. Exercise rapid edits/reorders, presets, reconnects and preview concurrently. Verify graceful saturation of control/telemetry queues and unavailable processor migration. Prove the registry seam with a test-only simple processor and duplicate instances; defer extra user-facing processors until separately designed.

Exit: the complete requested Advanced release includes safe reordering, reliable recall, accurate feedback and passing real-device checks. Stages 2–4 may land incrementally behind a feature flag.

### Later processor work

Prioritize an expander/gate with threshold/range/attack/hold/release and open/closed/reduction feedback; denoising with explicit strength/artifact tradeoffs and removed-noise preview; dynamic EQ with per-band reduction; then saturation or automatic leveling if useful for speech. Each addition supplies a descriptor, DSP implementation, latency declaration, telemetry, editor, persistence migration and deterministic tests. More EQ bands/types and filter slopes fit this same extension path. External AU/VST hosting and parallel routing require separate architecture work.

## Verification and performance gates

- **DSP:** deterministic response sweeps/impulses for filters and bands; transfer curves, attack/release and makeup tests; de-esser detector versus applied reduction; limiter transient/ceiling characterization. Test extreme and invalid values, multiple sample rates and variable blocks. Register cases in the existing custom test runner.
- **State/concurrency:** atomic multi-control recall, final-value delivery under queue saturation, repeated same-preset recall, thread-sanitized control stress outside real-time benchmarking, reorder under load, gain/filter transition continuity and reported versus measured latency. Use callback allocation/lock instrumentation; test destruction/reclamation ownership.
- **Metering:** isolated one-sample bursts between display polls, silence, full-scale sine with known RMS, over-range samples, clip reset, peak hold against elapsed time, applied-gain reference and history gaps. FFT tests include bin-centered/off-bin tones, calibrated noise, window gain and pre/post alignment. Loudness/true peak use official fixtures and their prescribed tolerances.
- **Persistence:** round trips for every control/order/bypass/band, named preset save/rename/update/recall, last-used preset and unsaved-edit restoration before audio starts, deleted-preset fallback, factory/custom legacy migration, absent versus zero values, unknown processors/versions, interrupted writes and fallback recovery. Preview/live equivalence uses the same input and complete chain state.
- **UI:** every control has keyboard/numeric equivalents; graphs have textual summaries. Validate narrow/wide and separate mode sizes, light/dark, RTL, VoiceOver, reduced motion, mode switching, Undo/A/B and focus after reorder. Verify bypass versus mute and active versus unapplied/pending state labels.
- **Integration:** build engine/tests, SwiftPM compile check, then the real linked Xcode app. SwiftPM's stub is not evidence of correct DSP integration. Manually test virtual-mic routing, background/window-close processing, preview, microphone changes, sleep/wake and disconnect/reconnect.
- **Performance:** retain the repository's <1% Apple Silicon audio-engine CPU aspiration as a measured baseline, not an unverified whole-app claim. Record machine/build/block size, callback p50/p95/p99/max and deadline misses, plus separate analysis/UI CPU/GPU costs. Target callback p99 below 25% of its buffer period and zero observed deadline misses in a 30-minute stress session; test the dual-plan transition peak separately. These are proposed gates to confirm on supported hardware. Reduce spectrum subscriptions/redraw rate before reducing audio reliability or meter peak capture.

## Files and documentation affected

Engine work centers on `Engine.h/.cpp`, `Preset.h/.cpp`, `dsp/*`, and new state/registry/control/telemetry/analysis modules under the existing include/src layout. Extend `engine_c_api.h/.cpp` additively, and update `CMakeLists.txt` plus `tests/test_engine.cpp` as required.

App work centers on `ContentView`, `MeterView`, `SettingsView`, `PresetPickerView`, `AudioViewModel`, `AudioEngineBridge`, `VoicePreview`, `Preset`, localized strings and the app window configuration, plus the new focused models/services/views above. Update `project.yml`/`Package.swift` if files or dependencies require it.

Update `docs/ARCHITECTURE.md` with the actual control-thread/measurement contracts, `docs/BUILDING.md` with required checks, and `docs/CONTRIBUTING.md` with the processor registration/test recipe. Include screenshots and measured CPU notes with implementation PRs. Driver/shared-memory changes are unnecessary unless separate routing requirements emerge.

## Decisions to revisit during prototyping

The default proposal is a horizontal strip plus focus editor, four existing EQ band types, selected-stage full-resolution spectra, pinned final gain/limiter, and built-in serial processors. Validate the density at laptop size and measure whether simultaneous miniature spectra are worthwhile. A desire for unrestricted limiter placement, additional EQ shapes immediately, or live detector audition would change scope; none is required to begin the foundations.
