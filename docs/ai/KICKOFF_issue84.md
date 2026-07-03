# Kickoff — Issue #84: "End match now" → straight to result confirmation (deep-link matches only)

> You are starting fresh. Read this, then **study the sources listed below before writing any code or plan.** Do not assume prior context — everything you need is referenced here.

## The task (issue #84)
A referee sometimes needs to end a match without playing it (team no-show → forfeit/contumation win). Add a button in **Settings → "Scoreboard Result API"** that — **only when a deep-link (scoreboard) match is loaded** — ends the match immediately and jumps straight to the existing result confirmation screen, guarded by a **confirmation pop-up**. The referee then edits the score there (contumation score) and submits as usual.

> **Placement note (device-test tweak, 2026-07-02):** the button was originally specced under "Current Game" (next to the no-show controls). During on-device testing the owner moved it into the **"Scoreboard Result API"** section — it is a deep-link-only action (gated on a linked fixture), so it belongs with the other scoreboard-fixture controls (Link status / Match code / Outbox / Refresh / Retry / Clear) rather than the manual-match controls in Current Game. Other "Current Game" references below reflect the original spec.

Read the issue in full first: `gh issue view 84` — it contains the agreed design. Key points:
- Gate: linked fixture present + submittable (`scoreboardResultService.matchConfig != null`, non-empty `matchCode`, token held — see `_canSubmitScoreboardResult`). Hidden (or disabled w/ subtitle) for manual matches.
- Works from **any** stage (before kickoff, firstHalf, halfTime, secondHalf), clock running or not.
- Confirm pop-up (AlertDialog, same pattern as "Start no-show penalty goals?" in `settings.dart` ~line 137). Cancel = nothing changes.
- On confirm: **reuse the normal `secondHalf → fullTime` transition side-effects** (`game.dart` ~line 810–825): stop clock, `stopAll(true)` + `gameOverAll()`, `currentStage = fullTime`, `timerButtonText = 'REPEAT'`, `_enterFullTimeResultReview()`, `disconnectInactiveModules()`, `_persistOrClearAtFullTime()`, MQTT/bridge broadcast. Implement as a `Game.endMatchEarly()` that extracts/reuses that block — do NOT build a bespoke shortcut, or you lose the RAVF003 kill-before-submit snapshot, the unresolved-result gate, REPEAT behaviour, and module teardown.
- Settings must pop back to Home before/as the review is raised (the review route is opened by Home's `onRequestReviewScoreboardResult` callback registered in `home.dart`).

## Required reading (study before acting)
- `gh issue view 84` — the spec.
- `CLAUDE.md` (repo root) — **critical invariants you must not violate** (START/STOP latency / no awaits on robot paths; double-tap safety; provider tree; portrait-only; BLE auto-reconnect policy; no new packages) + the **mock-launch pkill gotcha** at the bottom.
- Memory index: `/home/mato/.claude-rc/projects/-home-mato-StudioProjects-rcj-scoreboard/memory/MEMORY.md` — read `issue51_referee_lifecycle.md`, `scoreboard_integration.md`, `scoreboard_resume_binding_53.md`, `git_housekeeping_caution.md`, `device_test_before_push.md`, `codex_sandbox_flag_usage.md`, `review_anvil_format_gotcha.md`.
- `docs/ai/00_CONTEXT_INDEX.md` — doc reading order.
- `docs/ai/07_SCOREBOARD_DEVICE_TESTING.md` + `docs/ai/tools/mock_scoreboard.py` — device-test runbook (adb reverse, deep link, Pixel-10 tap coords, double-tap gotcha, error injection).

## Code you'll touch (study these)
- `lib/models/game.dart` — the `secondHalf → fullTime` block in `_tickTimer` (~810–825) is the behaviour to extract/reuse; `_enterFullTimeResultReview` (+ its `hasUnresolvedResultFor` gate), `_canSubmitScoreboardResult`, `_persistOrClearAtFullTime`, `stopTimer`, `_resetNoShowPenaltyGoals` (end-early while no-show mode is running must reset it, as the normal transition does).
- `lib/screens/settings.dart` — "Current Game" `SettingsSection` (~line 335, next to the no-show controls); the no-show confirm dialog (~line 137) is the pop-up pattern to copy.
- `lib/screens/home.dart` — `onRequestReviewScoreboardResult` registration + `_openScoreboardResultReview`; understand how the review route opens so triggering from Settings works (pop Settings → call `game.endMatchEarly()` → Home's callback fires).
- `lib/screens/scoreboard_result_review.dart` — the existing review/submit screen (score edit lives here; you change nothing in it).
- `test/game_recovery_test.dart` — test harness (`debugApplyMatchConfig`, `_scoreboardConfig`, `settleLoad`) to add `endMatchEarly` tests: from each stage; gate (no fixture → no-op/hidden); snapshot persisted at fullTime; REPEAT after early end; unresolved-result gate respected.

## What's already in `dev` (don't rebuild it)
- #51 review/submit lifecycle, #53 cold-resume fixture binding, #78 per-robot inspection UI, local-kickoff line, 10+5+10 forced timing (v0.10.5 shipped). The review screen and all submission plumbing exist — this issue only adds a new *entry point* into them.

## Workflow (the standard way of working here)
1. Branch off **`dev`** (e.g. `feat/issue-84-end-match-early`).
2. Write a **Codex task spec**, then have Codex implement (`codex exec --dangerously-bypass-approvals-and-sandbox` — bwrap sandbox is broken in this env; owner pre-authorized).
3. **review-anvil** (claude + codex reviewers, multiple rounds) → apply fixes. Never `dart format` the whole tree — only edited files.
4. Full test suite + `flutter analyze`.
5. **Device-test on the real phone** (mock + adb reverse; launch mock as a background task with NO self-matching `pkill` in the same command; kill it with `pkill -f '[m]ock_scoreboard\.py'`). `device_test_before_push.md`: desk-green ≠ done; get the owner's go-ahead before commit/push.
6. Open a well-documented PR (base `dev`); commits end with the Co-Authored-By line; PR body ends with the generated-with line.
7. **Commit this kickoff doc (`docs/ai/KICKOFF_issue84.md`) as part of your PR** — it is intentionally untracked until then; the owner wants each issue's doc to land with its implementing PR.

## Constraints / gotchas
- No new packages. App is Android + iOS — the button/dialog must work on both.
- Owner dislikes git churn — confirm before creating/closing anything beyond the PR branch.
- The pop-up is the safety mechanism (Settings surface) — no `CriticalGestureDetector` needed for this button, but never weaken invariant #2 elsewhere.
- Ending early from `halfTime` must also cancel the break countdown cleanly; from `inGame == false` (loaded, never started) it must still work (score 0–0, referee edits in review).
- Do not fire `gameOverAll()`/BLE work twice if the user somehow confirms twice — make `endMatchEarly()` idempotent (no-op at `fullTime`).

## First moves
1. `gh issue view 84`; read `CLAUDE.md`, the memory files, `game.dart` (~800–830, 1570–1650), `settings.dart` (~130–150, ~330–400), `home.dart` (review callback).
2. Decide with the owner if the button label is "End match now" or similar, and hidden-vs-disabled for manual matches.
3. Draft the Codex task spec for review, then implement per the workflow above.
