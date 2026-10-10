# Upstream contribution and PR delivery plan

Proposed on 10 October 2026. Companion to [the channel-strip specification](CHANNEL_STRIP_PLAN.md). This is a contribution strategy and proposed review sequence, not maintainer approval. PR identifiers below are planning labels, not GitHub issue numbers.

The personal fork setup is now recorded in [FORK_WORKFLOW.md](FORK_WORKFLOW.md). Checkout observations and setup recommendations below preserve the context in which this plan was prepared.

Implementation progress and tested branches are recorded separately in
[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md). Upstream submissions
remain on hold at the user's request.

## Recommendation

Create a personal GitHub fork of `aheadly-tech/voice-enhancer`. Preserve the current wondervip-based branch as a reference/personal integration branch. Start upstream contributions from a clean, current upstream `main`; selectively extract useful changes with attribution and targeted regression evidence. The Advanced channel-strip work does not require merging all of wondervip's PR first.

Keep two workstreams: focused reliability contributions and the new processing/preset/UI features. Ask the maintainer about the product direction early: willingness to review audio fixes does not establish willingness to adopt a larger Advanced mode. Independently useful improvements can still land if the complete redesign remains in the personal fork.

## Evidence and current position

[PR #4](https://github.com/aheadly-tech/voice-enhancer/pull/4) remains open. In his [24 June comment](https://github.com/aheadly-tech/voice-enhancer/pull/4#issuecomment-4791672609), aheadly-tech welcomed the direction, particularly reconnect handling and the tap guard, and requested separate testable changes. His wording was “I’d rather merge this in smaller pieces so we can test each part properly.” This is a request to change the delivery shape, rather than a rejection of every feature.

Local inspection found:

- `origin` currently points to `aheadly-tech/voice-enhancer`, not a personal fork.
- Upstream base reported for PR #4 and local `origin/main` is `19482d3`.
- Current branch `work/voice-enhancer-menubar-persistence` points to `e8c93ec`, exactly PR #4's head, with wondervip's `a7c6ee8` and `e8c93ec` commits above that base.
- At the start of this review, the channel-strip plan, concept and `AGENTS.md` were untracked. There were no additional committed channel-strip implementation changes to unwind.
- The first wondervip commit mixes reconnect, persistence, Custom, menu bar, login, localization and icon work. The second mixes an Objective-C tap guard with native-format capture and a rate converter. Their existing commit boundaries are not sufficient PR boundaries.
- Upstream already keeps audio running on window close, persists input-device UID, and has some configuration-change recovery. Contributions must demonstrate the incremental improvement over this baseline.
- Current CI compile-checks Swift with the stub engine; it does not establish that the linked app or Objective-C guard works.

## Fork and branch workflow

Fork the **upstream repository** into the user's GitHub account, keeping its `main` aligned with upstream. A fork gives a place to push independently managed branches and propose changes back to upstream. [GitHub fork documentation](https://docs.github.com/en/pull-requests/reference/forks)

Recommended local remote names after setup:

- `origin`: the user's fork, where personal branches are pushed.
- `upstream`: `aheadly-tech/voice-enhancer`, fetched for accepted changes.
- Optional `wondervip`: the original contributor's fork, used for comparison and provenance.

Before reorganizing, explicitly preserve the current branch and save the planning files on a personal planning branch or equivalent durable backup. Keep `AGENTS.md` a separate deliberate decision; do not accidentally include it in an upstream feature PR. A branch pointer alone does not preserve untracked files.

Use separate worktrees for clean upstream-based work and the personal integration build. Keep `main` clean. Use one branch per reviewable behavior, such as `fix/tap-exception`, `fix/dsp-control-race` or `feat/named-presets`. The integration branch may combine pending work for daily use, but is never the head of an omnibus upstream PR.

Prefer a short queue of one or two ready PRs against upstream `main`. Once a prerequisite merges, fetch the accepted version and replay only the next change on top, especially after a squash merge. Dependent local branches may be stacked, but do not target an upstream branch that exists only in the personal fork. Fork-local PRs can show integration slices; an upstream PR against `main` still includes every unmerged prerequisite. Mark that dependency plainly and defer review until the base lands unless the maintainer explicitly prefers a stack.

Check the final three-dot diff against the intended base before every submission. It must contain only that PR's behavior, tests and directly relevant build/documentation edits. Never use “all of #4 plus my changes” as the feature branch base for upstream review.

## Coordinate before duplicating work

Propose the extraction to both aheadly-tech and wondervip in PR #4, offering to handle particular slices. Ask whether wondervip is already splitting it. Let an active author own their slices; build on the resulting accepted commits. No messages have been posted as part of writing this plan.

Retain wondervip's authorship for extracted work where practical, and reference the original PR and source commit in new descriptions. For substantially adapted work, credit the contribution and describe the adaptation. Do not present the split as a new invention or as a takeover of someone else's open PR.

Suggested discussion draft:

> I'd like to help turn #4 into focused contributions, starting with tap exception handling and reconnect recovery, with separate validation for each. @wondervip, are you already working on that split? Separately, I'd like to propose an optional Advanced channel-strip view while retaining the current preset-first experience. I can first contribute independently useful DSP control, metering and named-preset improvements. Would that direction fit the project, and which slice would you prefer first?

## Track R: extract reliability improvements from #4

These are useful early contributions, not blanket prerequisites for the DSP track. Every slice is rebased onto upstream and compared with behavior already present there.

### R1 — Recover from AVAudio tap exceptions

**Base:** upstream main. **Scope:** the Objective-C exception boundary, minimal Swift error propagation and cleanup, and required linked-app build configuration. Retain the existing format/conversion strategy for this PR. Explain that turning a process abort into a recoverable error does not by itself restore audio on every device.

**Evidence:** reproduce a tap installation failure in an isolated test process or controlled test seam; show error propagation, cleanup and subsequent successful start. Verify removal/start failures do not leave duplicate taps. Build the real Xcode app; SwiftPM excludes the Objective-C helper and cannot validate it. Include a physical-device reproduction where available; do not claim all three reported issues are fixed solely because the app builds.

### R2 — Exclude the virtual microphone from input selection

**Base:** upstream main; independent of R1. **Scope:** device selection and driver detection only. Prefer stable driver/device identity over display-name matching, and cover both the picker and a system-default input pointing to the virtual mic. Keep detection of an installed driver working after filtering it from selectable inputs.

**Evidence:** real mic retained, virtual device excluded, driver still detected, default input cannot route the virtual mic into itself, and missing physical input produces a clear state. Use device-list fixtures plus a real routing check.

### R3 — Debounce and recover from device reconfiguration

**Base:** R1 for recoverable tap failures; R2 if the chosen fallback selection requires it. **Scope:** bounded reconnect retries, cancellation, selected-device retention and overlapping event handling. Extend the existing recovery logic rather than replacing unrelated view-model/UI behavior. A manual retry action can live in existing Settings; it need not depend on a menu bar.

**Evidence:** deterministic scheduler/fake-capture tests for event bursts, late completions, cancellation on Stop, failed retry then success and exhausted retries. Manual USB/Bluetooth switching verifies recovery and routing. No launch-at-login, localization, icons or new persistence format.

### R4 — Restore capture after sleep/wake

**Base:** R3. **Scope:** wake notification lifecycle and delayed reconnect through the same coordinator.

**Evidence:** one recovery after wake, observers cleaned up, intentional stop stays stopped, repeated wake/device events do not start concurrent graphs. Record a real sleep/wake check with the selected input.

### R5 — Capture native formats with continuous conversion

**Base:** R1; test with R3/R4 once merged. **Scope:** native-format negotiation and a bounded, streaming conversion path to the 48 kHz mono contract. This is audio-path work with its own design/review; do not hide it in the exception-guard PR.

**Reason to adapt the original:** code inspection shows `copyFirstChannelToRingRate` resets source position every callback, rounds each block's output frame count separately, and clamps output to available capacity. It also uses simple linear interpolation. These are concerns about continuity, long-run rate accuracy, capacity and downsampling quality; this review has not measured audible artifacts. Select an appropriate stateful conversion strategy and verify its real-time behavior before porting it.

**Evidence:** identical input split into different block sizes produces equivalent output; duration/frame accounting over long input; impulses and sweeps across 44.1/48/96 kHz and supported low-rate Bluetooth formats; downsampling rejection; no truncation; correct maximum DSP block size and output capacity. Measure callback allocations/timing. Include format-change and unavailable-channel handling.

## What to do with the rest of #4

- **Menu bar and Dock behavior:** optional standalone PR, with lifecycle/reopen/status/quit checks. It is not a channel-strip dependency. Preserve upstream's existing background audio behavior.
- **Settings and Custom persistence:** prefer the complete-state work P3/P4 below to importing a temporary two-threshold Custom design and replacing it immediately. If wondervip independently lands persistence first, adapt the migration to its accepted format. Device UID persistence is already upstream.
- **Launch at login:** independent optional PR with login registration/status/error checks; not required for presets or Advanced mode.
- **Localization:** independent work with translation review and RTL/accessibility checks; do not make the new processor controls depend on wondervip's unmerged localization framework. Support whichever localization mechanism upstream has accepted by then.
- **Icon changes:** leave out of the functional series; propose separately if wanted.

There is no need to reimplement every feature in #4 before proceeding. Extract good code, adapt coupled code to upstream's interfaces, and redesign only the parts whose correctness or structure needs it. Avoid whole-commit cherry-picks of the two mixed commits.

## Track P: processing, presets and channel strip

This is the proposed merge order. Independent branches can be developed concurrently without being submitted together. Each PR should leave a usable app and have value or a concrete tested contract at merge time. Approximate scope, rather than a line-count quota, determines the boundary; split a listed item further if its implementation acquires a second independently reviewable behavior.

### P0 — Build the linked macOS app in CI

**Depends on:** upstream main. Generate the Xcode project using the existing configuration and compile the app with the C++ bridge linked; retain the SwiftPM compile check and existing DSP tests. Verify signing-free build requirements. Add a focused test target when the first behavior test needs one rather than introducing a large unused test framework.

**Acceptance:** a deliberate compile failure in the real bridge/Objective-C path fails the relevant job; build instructions match CI. No application behavior change. This can accompany R1's integration checks or precede it as its own focused CI PR.

### P1 — Make existing DSP control writes thread-safe

**Depends on:** upstream main; P0 provides integration coverage. Route the existing gain, threshold and preset controls through a bounded audio-owned update path. Keep the existing UI and processing order. Add the regression fixtures and producer/audio stress tests relevant to this fix in the same PR.

**Acceptance:** no unsynchronized live-DSP mutation by control threads; rapid updates deliver the final value; overload behavior is bounded; all four factory outputs remain compatible after settling. Publish measured callback cost. Do not combine this with a processor registry, FFTs or a UI redesign.

### P2 — Expose complete processing snapshots and coherent recall

**Depends on:** P1. Add versioned fixed-chain configuration/readback, complete factory expansion, atomic grouped recall and acknowledgement. Adapt existing preset/threshold controls and preview to the same snapshot so this contract has real callers. Remove duplicate Swift factory thresholds. Stable processor/parameter identities are introduced here; unrestricted runtime routing is deferred.

**Acceptance:** full round trip through C ABI/Swift; same-preset recall resets edits; configuration applies coherently; live and preview use the same settings; old ABI functions remain usable. Preserve the existing sound and order.

### P3 — Restore the last complete working state at startup

**Depends on:** P2. Persist a versioned working snapshot and source preset identity; restore before audio delivery. Keep non-sound preferences separate. Recover interrupted writes and migrate settings only where they actually exist. Migration from wondervip-only Custom keys is an optional compatibility reader with fixtures, not a dependency on his UI.

**Acceptance:** factory selection, tuned parameters and master bypass survive restart; unsaved edits remain identifiable; corrupt/missing files recover; startup emits no default-preset interval. Existing preset UI remains usable.

### P4 — Save and recall named user presets

**Depends on:** P3. Add My Presets, Save/Save As, rename/update and recall to the existing UI. Keep factory cards. Persist identity independently of names and retain unsaved working edits separately from saved presets.

**Acceptance:** create two distinct presets, restart, recall each exactly, rename without losing identity, and restore the last-used named preset plus any unsaved edits. Use persistence tests and a short UI recording. This delivers the user's preset requirement without waiting for Advanced mode.

### P5 — Preserve peaks between UI polls and add RMS

**Depends on:** upstream main for core measurement; adapt to P2 revisions if already merged. Replace last-block-only readings with bounded accumulation/telemetry and elapsed-time display ballistics. Upgrade the existing meters, keeping layout changes minimal. Include clip/peak hold semantics.

**Acceptance:** a one-sample transient between UI polls is retained; RMS matches fixtures; long UI stalls preserve maxima; reset semantics and silence work; measured overhead is documented. No spectrum analyzer or loudness-standard claim.

### P6 — Add latency-aligned individual processor bypass

**Depends on:** P2/P3. Add enabled flags, latency readback, bounded transitions and per-stage bypass to the fixed chain. Include a compact working bypass list in Settings, so the feature can be exercised before the strip exists. Extend snapshot round trips and named preset tests if P4 has landed.

**Acceptance:** each processor and trim bypasses independently; limiter bypass retains comparison delay; applied reduction reads zero; settings survive recall/restart; no transient spikes or stale state when re-enabled. Global bypass semantics are explicit. Any limiter algorithm correction discovered by tests is a separate DSP PR with sound-compatibility evidence.

### P7 — Introduce Simple/Advanced with input and high-pass controls

**Depends on:** P4–P6 and agreement on the UI direction. Add mode persistence, strip/focus layout and reusable parameter controls, with a complete usable input/HPF editor. Show other existing stages as selectable summaries/bypass controls, clearly limiting editing to supported controls until subsequent PRs. Keep the existing two threshold controls available.

**Acceptance:** switching modes makes no engine-state change; input/HPF controls work; layout is keyboard/VoiceOver accessible and usable at laptop size; saved presets and bypass behave identically in both modes. Include light/dark screenshots. Avoid speculative empty knobs or a promised processor catalog.

### P8 — Add the compressor editor and calibrated stage meters

**Depends on:** P7, P5. Expose existing compressor parameters, makeup behavior and actual transfer response, with stage input/output and reduction telemetry. Extend the shared telemetry only for the measurements this editor consumes.

**Acceptance:** threshold/ratio/knee and time controls match deterministic DSP tests; auto/manual makeup is clear; displayed applied reduction agrees with reference gains; preset recall populates every control. Include response/CPU evidence and UI checks.

### P9 — Add the four-band EQ editor

**Depends on:** P7. Expose existing band frequency/gain/Q, add per-band bypass, and render response from shared filter design code. Keep the four existing band roles. No new band types or spectrum worker in this PR.

**Acceptance:** numeric and graph edits agree; analytical response agrees with measured sweeps; band bypass/recall works; extreme parameters stay stable; keyboard access matches mouse access. Test smoothing/transition behavior for edited filters.

### P10 — Add measured pre/post spectrum analysis

**Depends on:** P9 and the telemetry boundary from P5. Add bounded sample subscriptions, worker FFT and a real pre/post overlay for EQ and HPF. Include FFT calibration and overflow handling with the user-facing analyzer, not a disconnected framework.

**Acceptance:** known tones/noise validate frequency and amplitude; pre/post windows align; hidden views stop analysis work; dropped samples cannot affect audio; measured callback/worker/render costs meet the agreed budget.

### P11 — Add the de-esser editor and detector feedback

**Depends on:** P7, P8's reusable stage meters, P10 for spectrum. Expose the current high-band controls and actual detector region/reduction. Add attack/release controls only with preserved existing defaults and new DSP tests; split that extension into P11b if it materially enlarges the review.

**Acceptance:** detector and GR match the real split-band algorithm; crossover/threshold/ratio/range recall correctly; sibilant fixtures show the measured action; bypass and input/output spectra are truthful.

### P12 — Add pre-limiter gain and limiter editors

**Depends on:** P7/P8. Expose gain, ceiling and release, with limiter applied-gain telemetry and final output meters. Clearly label pre-limiter gain and sample peak. Keep algorithm changes separate.

**Acceptance:** displayed reduction is applied reduction; ceiling behavior is characterized with transient tests; latency, bypass and snapshot recall agree. Do not imply true-peak limiting or guarantee a stricter ceiling than the tested DSP achieves.

### P13 — Add processor dynamics history

**Depends on:** P8/P11/P12. Add timestamped input/output/detector/reduction histories to the existing editors, with shared scales, bounded history and discontinuity indicators.

**Acceptance:** plots correspond to known burst timing and applied gain; overflow/stalls show gaps rather than fabricated data; display rate and hidden-window behavior are verified. No changes to detector algorithms.

### P14 — Add undoable edits and snapshot comparison

**Depends on:** P4/P7 and completed editors for release coverage. Add grouped gesture Undo/Redo and full-state A/B through the existing transaction boundary; use the same snapshots for recorded voice preview. Add detected-band audition separately if its routing needs a distinct implementation.

**Acceptance:** one undo per gesture or preset recall; order/bypass/parameters restored; A/B and global bypass remain distinct; preview does not alter the virtual microphone feed. Level matching is a later optional preview feature.

### P15 — Measure momentary and short-term loudness

**Depends on:** P5/P12. Add K-weighted loudness measurements and labelled output readouts; retain RMS distinctly. Integrated loudness can follow separately.

**Acceptance:** official measurement fixtures/tolerances, correct mono weighting and window warmup, defined reset/gap behavior, documented worker cost. No imposed conferencing loudness target.

### P16 — Measure true peak

**Depends on:** P5/P12. Add validated true-peak analysis and dBTP readout. Keep the audio-path limiter and its label unchanged.

**Acceptance:** reference true-peak fixtures pass, discontinuity/validity handling is visible, and CPU impact is measured. Treat a future true-peak limiter as a different processor/algorithm change.

### P17 — Register the existing processors in a prepared serial plan

**Depends on:** P2/P6 and the current editors. Move fixed stage coordination into the bounded instance/descriptor plan while retaining the exact fixed order and sound. Use existing stable identities and snapshots. Provide concrete headless tests of duplicate instances and a test-only processor rather than adding speculative production processors.

**Acceptance:** before/after factory equivalence, telemetry instance IDs and preset migration remain correct, no callback allocations or ownership races, capacity failures are explicit. Public UI behavior remains stable, making this refactor assessable in isolation.

### P18 — Reorder processors with safe plan transitions

**Depends on:** P17/P14. Enable moving the middle processors through drag and keyboard commands. Prepare/warm independent plans, align latency, crossfade and reclaim safely. Keep the documented anchored stages.

**Acceptance:** each order matches a headless reference; reorder retains settings/selection; Undo and named presets capture it; burst reorder commands coalesce safely; transition CPU and callback deadlines are measured; reconnect restores the saved order.

This completes the initial channel-strip scope. Additional processors, EQ shapes/band counts, slopes, external plug-ins and parallel routing each require their own focused design and PRs.

## Dependencies and independently useful stopping points

The main feature path is P1 → P2 → P3 → P4 for reliable named presets, then P6/P7 for the strip and processor-editor slices. P5 provides accurate meters and can land early independently. P10 supplies spectra after the EQ editor. P15/P16 can follow the core UI without delaying individual editor reviews. P17/P18 deliver flexible order after the fixed chain is stable.

No processing PR depends on menu-bar, icon, login or localization changes from #4. Real-device capture faults can block validation on affected hardware; fix those with the relevant R-series PR rather than importing the complete branch. Early merged work remains useful if later UI direction changes.

Do not open the whole series at once. Agree the roadmap, submit the first narrow contribution, and revise the next two or three scopes using review feedback. Maintain a living checklist of base commit, dependencies, acceptance evidence and accepted/deferred status in the personal fork.

## Review contract for every PR

Each description states the concrete failing or missing behavior, resulting behavior, exact scope and dependency, and how to reproduce/verify it. Include relevant tests with the behavior rather than one huge test PR at the end. Existing bugs need a focused regression, not broad unconnected cleanup.

For DSP, provide measured response/fixtures and CPU notes on named hardware/build/block size. For UI, provide light/dark screenshots and keyboard/VoiceOver verification. For capture, state which devices/formats were actually tested and which remain unverified. Build the real linked app for bridge/capture changes, and keep Linux DSP checks passing. A green stub compile is not end-to-end evidence.

Give each PR a meaningful rollback boundary: reverting it should remove that behavior without removing unrelated features. Dependent PRs may require reverse-order reverts; document that dependency rather than promising independence where it does not exist. Release qualification is cumulative, with a final integration run, not a substitute for per-PR evidence.

## Immediate next steps

1. Preserve the current branch and untracked planning work; create the user's fork and establish the remote naming above when the user requests that setup.
2. Coordinate ownership of the #4 split and discuss the optional Advanced direction; use the draft above after explicit authorization to post.
3. Prepare R1 (tap exception recovery) from upstream, with P0's linked-build evidence. R2 is a good small independent follow-up.
4. Start P1 from upstream without importing #4. Proceed to full snapshots and named presets once the control boundary is accepted.
5. Keep daily-use combinations in the fork's integration branch and submit only focused feature branches upstream.

No fork, remote rename, history rewrite, pushed branch, PR or public comment was created by preparing this document.
