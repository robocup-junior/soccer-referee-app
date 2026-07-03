# Kickoff — Issue #85: report actually-connected module MACs in the result submission

> You are starting fresh. Read this, then **study the sources listed below before writing any code or plan.** Do not assume prior context — everything you need is referenced here.

## The task (issue #85)
A robot's comm module can break mid-match and be **replaced** (referee re-pairs a spare via QR scan or manual MAC entry). The server's `Module.mac_address` then drifts stale. Extend the **result submission** so the POST also carries, per team, the list of modules actually in use at submit time — score + confirmed flags + comment (existing) **+ connected-module list per team** — so the server can diff and update its records.

Read both specs in full first:
- `gh issue view 85` (this repo) — the client spec.
- `gh issue view 72 --repo robocup-junior/rcj-scoreboard` — the **server counterpart (already open)**; it proposes the shape:
  ```json
  "actual_modules": {
    "home": [{"robot": 1, "mac": "AA:BB:CC:DD:EE:01", "connected": true}],
    "away": [{"robot": 1, "mac": "AA:BB:CC:DD:EE:02", "connected": true}]
  }
  ```

**⚠️ First coordinate the final shape on rcj-scoreboard#72 (comment there, cc @mrshu) before implementing** — its open questions (include never-paired slots? key names? superteam case?) must be settled so the read path (#70) and write path speak the same shape. The client change is purely additive (server ignores unknown keys until #72 lands), so the app may ship first — but only after the shape is agreed.

## Design decisions already made (issue #85)
- **Capture at submit time** in `Game.submitScoreboardResult` — from live `teams[*].modules`, mapped to home/away **by team id** via `_scoreboardHomeTeamId`/`_scoreboardAwayTeamId` (NEVER positional — a half-time team-order swap must not cross sides). Capture **before any await**, exactly like homeGoals/awayGoals already do (`game.dart` ~line 1741).
- Per team: one entry per **enabled** slot (`numberOfPlayers`), `robot` = slot index + 1, `mac` = `module.macAddress` (normalize uppercase; may be empty), `connected` = `module.isConnected`. Include disconnected/unpaired enabled slots with `connected: false` (server wants them); don't report disabled slots.
- Thread through `ScoreboardResultService.enqueueFinalResult` → `ResultOutboxItem` (**new fields must survive the prefs toJson/fromJson round-trip** — the outbox persists across restarts/retries) → POST body in `_submitItem` (`scoreboard_result_service.dart` ~line 725).
- **Read-only wrt BLE**: only read `macAddress`/`isConnected`; never touch connect/send paths (invariants #1/#5).
- Update `docs/ai/tools/mock_scoreboard.py` to log/accept `actual_modules` so it's device-testable.

## Required reading (study before acting)
- `gh issue view 85` + `gh issue view 72 --repo robocup-junior/rcj-scoreboard`.
- `CLAUDE.md` (repo root) — critical invariants + the **mock-launch pkill gotcha** at the bottom.
- Memory index: `/home/mato/.claude-rc/projects/-home-mato-StudioProjects-rcj-scoreboard/memory/MEMORY.md` — read `scoreboard_integration.md`, `inspection_status_per_robot.md` (the #78 pattern: how a payload field was threaded model→service→UI with round-trip tests), `scoreboard_resume_binding_53.md`, `git_housekeeping_caution.md`, `device_test_before_push.md`, `codex_sandbox_flag_usage.md`, `review_anvil_format_gotcha.md`.
- `docs/ai/00_CONTEXT_INDEX.md`; `docs/ai/07_SCOREBOARD_DEVICE_TESTING.md` + `docs/ai/tools/mock_scoreboard.py`.

## Code you'll touch (study these)
- `lib/models/game.dart` — `submitScoreboardResult` (~1712–1760): where homeGoals/awayGoals + side mapping are captured pre-await; add the module capture here. `_autoPairScoreboardModules` (~1515) shows the slot↔robot-number mapping convention (index+1, keyed by team id).
- `lib/models/module.dart` — `macAddress` (line ~68), `_isConnected`, `isEnabled` (~670).
- `lib/services/scoreboard_result_service.dart` — `enqueueFinalResult` (~568–600), `_submitItem` POST body (~716–735), outbox persistence (`fromJson` skips malformed items — keep that property).
- `lib/models/scoreboard_result.dart` — `ResultOutboxItem` (~247): fields, `toJson`/`fromJson`; follow the existing style for the new fields (defaulted, so old persisted items still parse).
- `lib/screens/scoreboard_result_review.dart` — probably unchanged (payload-only feature); optionally note the module list in the review UI — ask the owner first.
- Tests: `test/scoreboard_result_test.dart` (outbox round-trip + POST body), `test/game_recovery_test.dart` (side mapping incl. `homeIsLeft:false` + swapped order; a mid-match MAC change reported; disconnected slot `connected:false`; kill+relaunch mid-retry still POSTs the list).

## What's already in `dev` (don't rebuild it)
- #70-app auto-pair (read path), #51 review/submit + outbox with retry/idempotency, #53 cold-resume binding, #78 per-robot inspection (a good template for threading payload fields with tests). v0.10.5 shipped.

## Workflow (the standard way of working here)
1. Coordinate the shape on rcj-scoreboard#72 (comment, cc @mrshu); wait for/obtain agreement.
2. Branch off **`dev`** (e.g. `feat/issue-85-report-actual-modules`).
3. Write a **Codex task spec**, then have Codex implement (`codex exec --dangerously-bypass-approvals-and-sandbox` — bwrap sandbox broken in this env; owner pre-authorized).
4. **review-anvil** (claude + codex reviewers, multiple rounds) → apply fixes. Only format edited files.
5. Full test suite + `flutter analyze`.
6. **Device-test on the real phone**: mock + adb reverse; scenario = load match w/ MACs → replace one module via manual MAC/QR mid-match → full time → submit → mock log shows `actual_modules` with the NEW mac. (Launch mock as a background task with NO self-matching `pkill`; kill via `pkill -f '[m]ock_scoreboard\.py'`.) Owner go-ahead before commit/push.
7. Open a well-documented PR (base `dev`); commits end with the Co-Authored-By line; PR body ends with the generated-with line.
8. **Commit this kickoff doc (`docs/ai/KICKOFF_issue85.md`) as part of your PR** — it is intentionally untracked until then; the owner wants each issue's doc to land with its implementing PR.

## Constraints / gotchas
- No new packages. Android + iOS.
- Owner dislikes git churn — confirm before creating/closing anything beyond the PR branch.
- The outbox item is persisted JSON — bump nothing, just add defaulted fields so old items still parse (mirror how existing optional fields are handled).
- A retry may fire long after submit (app relaunch) — the module list must come from the **persisted item**, never re-read live at retry time.
- Deliberately excluded from `ScoreboardMatchConfig.signature` concerns — this touches the result path only, not config identity.

## First moves
1. `gh issue view 85` + rcj-scoreboard#72; read `CLAUDE.md`, memory files, `game.dart` submit path, `scoreboard_result_service.dart`, `ResultOutboxItem`.
2. Post the shape-alignment comment on rcj-scoreboard#72 (cc @mrshu) and get the owner's OK on the final key names.
3. Draft the Codex task spec for review, then implement per the workflow above.
