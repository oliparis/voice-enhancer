# Fork workspace and next steps

Workspace setup: 10 October 2026.

## Repositories

- Personal fork (`origin`): https://github.com/oliparis/voice-enhancer
- Upstream (`upstream`): https://github.com/aheadly-tech/voice-enhancer
- Default push remote: `origin`.

Keep the fork's `main` aligned with accepted upstream changes. Specify `--repo aheadly-tech/voice-enhancer` explicitly when preparing an upstream PR; use `--repo oliparis/voice-enhancer` for work within the fork.

## Preserved branches

- `reference/wondervip-pr4`: the original PR #4 head, `e8c93ec`, with wondervip's authorship intact. This is a reference and a usable starting point for a personal integration build; it is not the base for new upstream contributions.
- `planning/channel-strip`: based on clean upstream `main` at `19482d3`, containing the planning documents, interactive concept and repository instructions. This branch is for personal planning, not an omnibus upstream PR.
- The existing local `voice-enhancer-menubar-persistence` and `work/voice-enhancer-menubar-persistence` branches are retained.

## Planning artifacts

- [Channel-strip specification](CHANNEL_STRIP_PLAN.md): Simple/Advanced modes, complete state, named presets, startup restoration, processor controls, bypass, analysis, future processors and acceptance criteria.
- [Interactive layout concept](channel-strip-concept.html): illustrative HTML prototype. JavaScript syntax and local links were checked; browser visual verification was blocked by local-file URL policy. It does not process audio.
- [Upstream delivery plan](UPSTREAM_DELIVERY_PLAN.md): maintainer feedback, proposed reliability extraction, and individual feature PRs with dependencies and tests. Its original checkout observations describe the state before this fork setup.
- [Repository instructions](../AGENTS.md): development conventions retained for future sessions.

## Continue from here

The first implementation tranche is recorded in
[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md). R1 and P0 now exist on
separate upstream-based branches, with a passing combined fork CI run. Keep
upstream submissions on hold; the next processing slice is P1.

1. Coordinate the proposed PR #4 split with wondervip and aheadly-tech, and discuss whether optional Advanced mode fits upstream. The delivery document contains a draft; it has not been posted.
2. Finish manual device validation of R1 before an eventual upstream submission. The original resampling changes belong in their own reviewed slice.
3. Start P1, safe DSP control updates, independently from accepted upstream code. Named presets and startup recall follow through P2–P4 without depending on menu-bar, localization, icons or login changes.

Use one branch per focused PR. Create these branches from `upstream/main` or their explicit accepted prerequisite, never from the planning or reference branches. Keep the planning documents out of an unrelated bug-fix diff. Update this planning branch as decisions change. Use a separate integration branch when combining pending work for personal use.

Before submitting, compare the branch with its intended base and verify that the diff contains only that behavior, relevant tests and necessary build/documentation changes. Push personal branches to `origin`; target `aheadly-tech:main` only when intentionally opening an upstream PR.
