# Kickoff — Issue #82: auto "MAC loading" not working on iOS (connection-id vs hardware-MAC split)

> You are starting fresh. Read this, then **study the sources listed below before writing any code or plan.** Do not assume prior context — everything you need is referenced here.
> The **full design is already written and owner-approved**: `docs/ai/DESIGN_issue82_ios_mac_split.md`. Read it first — this kickoff is the orientation; that doc is the spec (problem, design, decided iOS auto-connect mechanism, touch points, implementation starting points, testing).

## The task (issue #82)
**"Bug: auto 'MAC loading' not working on iOS."** A deep-linked match carries the robots' MAC addresses (`home_module_macs`/`away_module_macs`, #70) and the app auto-pairs them onto module slots. This works on Android but **silently fails on iOS**, and the same root cause makes issue #85's end-of-match `actual_modules` report post a useless value on iPhone.

Read the issue in full first: `gh issue view 82`.

## Why it fails (the root cause — read the design doc §1–2 for the full version)
`Module.macAddress` conflates **two** things: (1) the BLE *connection identity* passed to `BluetoothDevice.fromId(...)`, and (2) the *hardware MAC* the scoreboard knows. On **Android** they're the same string, so it works. On **iOS** Apple hides the hardware MAC — a peripheral is addressed by a **per-phone CoreBluetooth UUID** you can only learn by *scanning and seeing the device advertise*. So `fromId(MAC)` can't connect on iOS (that's #82), and reporting `macAddress` posts a UUID the server can't reconcile (that's #85/RAVF001). The rescue: the firmware advertises the real MAC in the device **name** (`RCJs-m_<MAC>`), so iOS *can* recover it.

## The design, decided WITH the owner (do not re-litigate these)
1. **Store both.** A module keeps its `connectionId` (UUID on iOS / MAC on Android) **and** a separate `hardwareMac` (the real MAC, reported to the scoreboard). See §3. **Lower-risk first cut (§8a):** keep `Module.macAddress` as the connection identity and just ADD `hardwareMac`, rather than a repo-wide rename — smaller, reviewable, Android-safe diff.
2. **Populate `hardwareMac` on iOS** from the QR-scanned MAC (currently discarded in `handleIosResult`) and/or by parsing the advertised name; on Android it equals the connection id.
3. **iOS auto-connect mechanism (§3a, DECIDED):** one **batch scan at match load** → MAC→UUID map → connect present modules by UUID with `autoConnect:true`; **cache** MAC→UUID for reload/cold-resume; **power-cycles need no rescan** (OS-owned autoConnect once seen — invariant #5 holds); an **absent-at-load** module gets a **bounded rescan while the clock is stopped / until kickoff** (per-tile `Searching…` → `Not found — tap to scan`, manual QR/scan fallback anytime); **never scan during a running half** (invariant #1 latency).
4. **No server/#72 change needed** — iOS just starts sending a real MAC in the existing `actual_modules.mac` field.

## Required reading (study before acting)
- **`docs/ai/DESIGN_issue82_ios_mac_split.md`** — the spec. §8a "Implementation starting points" has the exact file/line anchors.
- `gh issue view 82` — the bug report.
- `CLAUDE.md` (repo root) — **critical invariants you must not violate**: **#1** START/STOP latency (no awaits/queues/scans on the robot path; a BLE scan competes with the radio — never scan during a running half); **#5** OS-owned autoConnect, **NO app-level reconnect loop** (the #42 GATT-client-leak history — the resolve-rescan targets ONLY never-yet-resolved MACs, never disconnect-driven reconnection); portrait-only; **no new packages**.
- Memory index: `/home/mato/.claude-rc/projects/-home-mato-StudioProjects-rcj-scoreboard/memory/MEMORY.md` — read `ble_reconnect_unbounded_in_match.md`, `ble_pixel_limit.md`, `scoreboard_integration.md`, `git_housekeeping_caution.md`, `device_test_before_push.md`, `review_anvil_format_gotcha.md`, `codex_sandbox_flag_usage.md`.
- `docs/ai/02_RUNTIME_ARCHITECTURE.md` ("Auto-reconnect policy") and `docs/ai/07_SCOREBOARD_DEVICE_TESTING.md` + `docs/ai/tools/mock_scoreboard.py` (the mock serves `home/away_module_macs` and logs `actual_modules`).

## Code you'll touch (see design §4 + §8a for line anchors)
- `lib/models/module.dart` — add `hardwareMac`; populate in `setBleDevice` / on the connected event; rework `applyPresetConfig` so iOS resolves MAC→UUID before connecting.
- `lib/utils/ble_address.dart` — add a pure `macFromAdvertisedName(...)`; generalize `resolveIosDeviceUuid` to a batch map. ⚠️ Confirm the real advertised-name prefix vs firmware (`RCJs-m_` in code vs a stale `RCJ-soccer_module-` comment).
- `lib/screens/module_settings.dart` — QR flow keeps the scanned MAC; per-tile status; auto-pair uses the resolver.
- `lib/models/game.dart` — batch resolve + bounded-rescan controller gated on `_isGameRunning`/`currentStage`; and (after #85 lands) `_actualModulesForTeamId` reports `hardwareMac`.
- `lib/services/match_state_store.dart` — `ModuleSnapshot` gains `hardwareMac` (back-compat default on read).

## Dependency on #85 (important)
The report site `Game._actualModulesForTeamId` lives on the **#85 branch (PR #91), not on `dev` yet**. This #82 branch is based on `dev`, so that function isn't here. Once #85 merges, rebase on `dev` and switch that line to `hardwareMac` (removing the RAVF001 known-limitation comment #85 added). Or stack this branch on `feat/issue-85` to do it in one pass.

## Workflow (the standard way of working here)
1. Branch is `feat/issue-82-ios-mac-split` (off `dev`); this doc + the design doc land with the PR.
2. TDD the pure/Android-verifiable parts (name parser, resolver map, snapshot round-trip, report). **iPhone device test** the auto-connect + bounded rescan + cold-resume — the crux; it CANNOT be verified on the Linux dev box. Android regression via the mock flow.
3. Offline gradle build trick for this env if needed (see `issue51_referee_lifecycle` memory). review-anvil for hardening (codex needs `--dangerously-bypass...` here — ask the owner; see `codex_sandbox_flag_usage`).
4. **Owner rules (memory):** no commit/push without his go-ahead **and** real on-device testing; minimal git churn — don't create/close issues or branches beyond this one without asking.
