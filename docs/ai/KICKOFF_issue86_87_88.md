# Kickoff — Issues #86 + #87 + #88: bridge "Cancel" parity, end-of-match bridge/MQTT teardown, MQTT working defaults + auto-connect

> You are starting fresh. Read this, then **study the sources listed below before writing any code or plan.** Do not assume prior context — everything you need is referenced here.
> One session implements ALL THREE — they touch the same surfaces (`ble_bridge_service.dart`, `mqtt.dart`, the Scoreboard/MQTT sections of `settings.dart`, the fullTime block + config-apply in `game.dart`) and together they make the per-field lifecycle self-managing: **auto-connect MQTT at deep-link load (#88) → play → auto-disconnect bridge+MQTT at full time (#87)**, with a cancellable bridge connect (#86). Prefer one branch + one PR covering all three (separate commits per issue).

## The tasks
Read all three issues in full first: `gh issue view 86`, `gh issue view 87`, `gh issue view 88`.

### #86 — allow cancelling a stuck BLE-bridge "Connecting…"
The robot-module flow has a tri-state button — `Disconnect / Cancel / Connect` (`module_settings.dart:408`); **Cancel** calls `bleDisconnect()` which clears `_connectIntent` and stops the OS autoConnect retry. The bridge never got this:
- `settings.dart` (~471–487, "Bridge connection" `SettingButton`): only two-state. While `BridgeConnectionState.connecting` it shows **"Connect"**, whose handler calls `BLEBridgeService.connect()` — which **early-returns when already connecting** (`ble_bridge_service.dart` ~line 71). A stuck bridge connect is uncancellable from the UI.
- The service side already supports cancel: `disconnect()` clears `_connectIntent` (~92–103) and settles the state.

Fix: tri-state button mirroring the module pattern (`connected → Disconnect`, `connecting → Cancel`, else `Connect`; Cancel → `bleBridgeService.disconnect()`). While there, audit the bridge connect lifecycle against the module/PR #42 learnings: status text covers all four `BridgeConnectionState`s (incl. `error`), no "Disconnected" flash mid-retry, repeated Connect taps can't stack listeners/GATT clients (single `connect(autoConnect:true)` — invariant #5 applies to the bridge link too).

### #87 — disconnect BLE bridge + MQTT at the end of EVERY match
Referees rotate phones per field. After full time the old phone keeps holding the bridge (single central → next phone can't connect) and the MQTT session. Today only modules are torn down: `disconnectInactiveModules()` in the `secondHalf → fullTime` block (`game.dart` ~line 823). Fix, in that same block, for manual AND deep-link matches:
- **After the final full-time state has been broadcast**: drain the bridge's dedup queue (`queueDepthNotifier`, drain-or-timeout of a few seconds — mirror `gameOverAll()`'s 1 s delay pattern) → `bleBridgeService.disconnect()`; and `mqttService.disconnect()` after the final publishes.
- **Unawaited / fire-and-forget** on the transition path (invariant #1 — never delay the robot path).
- Only disconnect what was connected; no-op otherwise.
- Placing it in the shared block means the **#84 "End match now"** path (which reuses this block) inherits it for free — coordinate if #84 lands first/concurrently (see `docs/ai/KICKOFF_issue84.md`).

Decisions flagged in the issue (confirm with the owner if in doubt): REPEAT leaves transports disconnected (manual reconnect via Settings); MQTT `auto_connect` pref (applied at app launch, `mqtt.dart:49`) must not undo the teardown mid-session; no auto-reconnect on cold-resume at fullTime (RAVF003 restore).

### #88 — MQTT working defaults + auto-connect on deep-link match load
Today every referee phone needs manual MQTT setup: **Secure connection** defaults to `false` (`mqtt.dart:48`) and the shipped default password is a **hint** — `S_p-@P2_rL7ZFv9XYZ` (`mqtt.dart:54`, commit 5750ca5); the real password is that minus the literal trailing `XYZ`. Owner decision: ship it working.
- Defaults: `mqtt_secure_connection` → `true`; default password → the real one, `S_p-@P2_rL7ZFv9` (accepted trade-off — the broker account is restricted to the single scoreboard topic). Optional one-shot migration: a stored password equal to the old hint string verbatim → migrate to the real default.
- Auto-connect: when a scoreboard config is applied (`Game._applyScoreboardMatchConfig` — where the venue → `field_N` MQTT topic is already derived, #50), if MQTT is **enabled** and **not connected**, connect automatically with the stored settings. **Unawaited** off the config-apply path (broker outage must not delay match load); status label reports the outcome; never auto-connect when MQTT is disabled; never clobber custom referee creds.
- Interplay with #87 (important): auto-connect fires on match **LOAD** only — it must NOT re-fire after the same match's full-time teardown (loading the NEXT match connects again; that's the desired handover loop).

## Required reading (study before acting)
- `gh issue view 86`, `gh issue view 87`, `gh issue view 88` (+ referenced PR #42 discussion for the module reconnect learnings).
- `CLAUDE.md` (repo root) — **critical invariants** (#1 START/STOP latency — no awaits/serialization on robot paths; #5 autoConnect-only reconnect, NO app-level loop — the #42 GATT-client-leak history; portrait-only; no new packages) + the **mock-launch pkill gotcha** at the bottom.
- Memory index: `/home/mato/.claude-rc/projects/-home-mato-StudioProjects-rcj-scoreboard/memory/MEMORY.md` — read `ble_bridge_design.md`, `ble_reconnect_unbounded_in_match.md`, `ble_pixel_limit.md`, `git_housekeeping_caution.md`, `device_test_before_push.md`, `codex_sandbox_flag_usage.md`, `review_anvil_format_gotcha.md`, `prepared_issues_84_85.md`.
- `docs/ai/02_RUNTIME_ARCHITECTURE.md` ("Auto-reconnect policy") and `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md` — bridge design/protocol.
- `docs/ai/07_SCOREBOARD_DEVICE_TESTING.md` — device-test runbook basics (adb, coords, double-tap gotcha, mock deep link).

## Code you'll touch (study these)
- `lib/services/ble_bridge_service.dart` — `BridgeConnectionState` (line 10), `_connectIntent` (31), `connect()` early-return (~71), `disconnect()` (~92–103), disconnect-event state settle (~158), `queueDepthNotifier` + `_processQueue` (dedup queue, pops-before-await).
- `lib/services/mqtt.dart` — defaults (48–54: `mqtt_secure_connection ?? false`, hint password), `disconnect()` (~281), `connect`, `isEnabled`, `_autoConnect` pref (~28/49/137), `connectionStateNotifier`.
- `lib/screens/settings.dart` — Scoreboard/bridge `SettingsSection` (~413–490): status label mapping and the "Bridge connection" `SettingButton` (~471); MQTT section right below (~492+; secure-connection toggle + password field).
- `lib/screens/module_settings.dart` — line ~408: the tri-state button to mirror; its Cancel semantics.
- `lib/models/game.dart` — the `secondHalf → fullTime` block (~810–825: `stopAll`, `gameOverAll()`, `_enterFullTimeResultReview`, `disconnectInactiveModules()`, `_persistOrClearAtFullTime`); `gameOverAll()` (1 s delayed BLE fan-out — the delay pattern to mirror for queue drain); `_applyScoreboardMatchConfig` (~1360+; field-number derivation ~1457 — where #88's auto-connect hooks in, watch the dedupe/re-apply paths so a refresh doesn't re-trigger connects); the `_broadcast*` helpers that fan out to MQTT + bridge.
- Tests: `test/bridge_message_test.dart` (bridge queue tests), `test/game_recovery_test.dart` (harness for fullTime-transition + config-apply tests). Add: tri-state mapping unit test; teardown-ordering test (final publish/queue drain before disconnect); no-op when never connected; REPEAT leaves transports down; #88 defaults test (fresh prefs → secure true + real password), auto-connect-on-apply test (enabled+disconnected → connect called once; disabled → never; same-config refresh → not re-fired), hint-password migration test if implemented.

## What's already in `dev` (don't rebuild it)
- Bridge iteration 1 (MQTT-over-BLE, dedup queue, `_connectIntent` mirroring, iOS UUID handling #65/#67). Module Cancel + "Connecting…" status (0.9.8, PR #42). `disconnectInactiveModules()` at fullTime. Venue → `field_N` topic derivation (#50). #84/#85 are specced (kickoff docs in `docs/ai/`) and may land concurrently — #84 touches the same fullTime block; coordinate/rebase.

## Workflow (the standard way of working here)
1. Branch off **`dev`** (e.g. `feat/issue-86-87-88-transport-lifecycle`).
2. Write a **Codex task spec**, then have Codex implement (`codex exec --dangerously-bypass-approvals-and-sandbox` — bwrap sandbox is broken in this env; owner pre-authorized). Separate commits: #86 (button/lifecycle), #87 (teardown), #88 (defaults + auto-connect).
3. **review-anvil** (claude + codex reviewers, multiple rounds) → apply fixes. Only format edited files.
4. Full test suite + `flutter analyze`.
5. **Device-test on the real phone** — `device_test_before_push.md`: desk-green ≠ done; owner go-ahead before commit/push.
   - **#86**: set the bridge MAC to a powered-off/nonexistent device → Settings shows "Connecting…" → button must read **Cancel** → tap → "Disconnected" immediately, and the device must NOT connect later when powered on. Then a normal connect/disconnect cycle against the real scoreboard bridge.
   - **#87**: with the real bridge (and MQTT) connected, play a short match (Settings → 10 s halves) to full time → scoreboard shows the FINAL score, then both transports read disconnected within a few seconds; verify a second phone (or re-connecting the same phone) can take the bridge. Repeat via the manual (non-deep-link) path, and via #84's early-end if it has landed.
   - **#88**: `pm clear` (fresh prefs) → fire a deep-link match (mock or real) → MQTT connects by itself with secure=on and the real default password, publishes land on the fixture's `field_N` topic (verify with a broker-side subscriber or the mock/HiveMQ web client). Then: MQTT disabled → no attempt; full match → #87 disconnects → load the NEXT match → auto-connect fires again.
6. Open a well-documented PR (base `dev`), closing all three issues; commits end with the Co-Authored-By line; PR body ends with the generated-with line.
7. **Commit this kickoff doc (`docs/ai/KICKOFF_issue86_87_88.md`) as part of your PR** — it is intentionally untracked until then; the owner wants each issue's doc to land with its implementing PR.

## Constraints / gotchas
- No new packages. Android + iOS (bridge identifiers are UUIDs on iOS).
- Owner dislikes git churn — confirm before creating/closing anything beyond the PR branch.
- The bridge/MQTT are **fully separate from robot control** — nothing here may touch module connect/send paths or add awaits near `bleSendPlayAll`/`bleSendStopAll` (invariant #1). The teardown must not race `gameOverAll()`'s delayed module fan-out; the auto-connect must not delay `_applyScoreboardMatchConfig`.
- Do NOT add any app-level reconnect loop to the bridge while auditing (invariant #5 — the #42 GATT-client leak was device-proven).
- The bridge queue drain must be bounded (timeout) — a dead bridge with a non-draining queue must not block the teardown forever.
- Keep the teardown one-shot/idempotent (e.g. #84's early end reaching fullTime twice → no-op), and keep #88's auto-connect load-only (config **refresh/dedupe** paths in `_applyScoreboardMatchConfig` must not re-trigger it — study `_lastAppliedScoreboardSignature`).
- The real password lands in the repo/app by explicit owner decision (single-topic broker account) — don't "fix" that in review; do keep it out of logs.

## First moves
1. `gh issue view 86` + `87` + `88`; read `CLAUDE.md`, the memory files, `ble_bridge_service.dart`, `mqtt.dart`, the settings bridge/MQTT sections, and `game.dart` ~800–830 + `_applyScoreboardMatchConfig`.
2. Check whether #84 has landed (it reuses the fullTime block) and rebase/coordinate accordingly.
3. Draft the Codex task spec for review, then implement per the workflow above.
