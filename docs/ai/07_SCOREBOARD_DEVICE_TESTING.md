# Scoreboard deep-link flow — device testing runbook

How to exercise the **scoreboard referee result flow** (deep link → match-config
`GET` → full-time result `POST`) end-to-end on a real Android phone **without the
live rcj-scoreboard server**, using a local stdlib mock + `adb`. Written so a
future agent can repeat the test in minutes instead of re-deriving it.

Relevant code: `lib/services/scoreboard_result_service.dart`,
`lib/models/scoreboard_result.dart`, `lib/models/game.dart` (scoreboard parts).
Background: `[[scoreboard_integration]]`, the PR is `copilot/issue-31-final-result-api` (#15).

---

## Why this setup (the non-obvious bits)

- **Custom scheme, not the HTTPS App Link, in debug.** A debug build's HTTPS
  App Link won't auto-verify (Android domain-verification state = "not
  verified"), so it won't auto-open. Use the custom scheme `rcjrefmate://r/<token>`.
- **`base_url` query override is debug-only.** `_parseDeepLink` accepts
  `?base_url=http://127.0.0.1:8000` **only** in `kDebugMode`, and only for an
  allowlisted local host (`localhost`, `127.0.0.1`, `::1`, `10.0.2.2`, RFC-1918).
  This is how we point the app at the mock.
- **`adb reverse`, not the LAN IP.** `adb reverse tcp:8000 tcp:8000` tunnels the
  phone's `127.0.0.1:8000` to the host over USB. The Wi-Fi/LAN-IP path
  (`192.168.x.y:8000`) is unreliable — a host firewall typically blocks inbound
  from the phone. `127.0.0.1` is also in the debug allowlist, the LAN IP is not.
- **The capability token is single-use** server-side: a successful `POST`
  consumes it. The `GET` does **not**. So you can re-`GET` freely, but to test a
  *fresh* submit, restart the mock (resets its consumed flag) or use a new token.

---

## Prerequisites

- Flutter 3.44.0 toolchain on `PATH` (`flutter`, `dart`). `python3` for the mock.
- Phone connected, USB debugging authorized: `adb devices` shows `device`
  (not `unauthorized`/`offline`). If it drops: `adb kill-server && adb start-server`
  then `adb reconnect`, and physically re-plug if still missing.
- App package id: **`com.robocup.rcj_soccer`**.

---

## The mock server

`docs/ai/tools/mock_scoreboard.py` — stdlib mock of both endpoints:
`GET /api/v1/soccer/match/` and `POST /api/v1/soccer/match/result/` (exact path
match, trailing slash **required** — matches the server's `APPEND_SLASH`).

Match it serves: **Red Robots vs Blue Bots**, `home_is_left=true`, `Field 1`,
`duration_seconds=30` (short halves so a full match is ~1 min, not 20).

Env-var error injection:
| Var | Effect |
|---|---|
| `PORT` | listen port (default 8000) |
| `RESULT_STATUS` | force the `POST` status (e.g. `409`, `401`, `422`, `500`) |
| `MATCH_STATUS` | force the `GET` status (e.g. `401`, `500`) |
| `HANG` | seconds to sleep before responding (test the 15 s client timeout: `HANG=20`) |
| `TOKEN` | expected bearer token (default: accept any non-empty) |

Run it **with `-u`** (Python block-buffers stdout to a file otherwise, so the log
looks empty) and as a tracked background task (no inner `&`, which gets orphaned
on shell exit):

```bash
python3 -u docs/ai/tools/mock_scoreboard.py > /tmp/mock.log 2>&1   # run_in_background: true
# self-test from host (expect 401, no auth):
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/api/v1/soccer/match/
```

---

## Full happy-path run

```bash
# 1. Build, install, tunnel, clean state
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb reverse tcp:8000 tcp:8000
adb shell pm clear com.robocup.rcj_soccer     # cold start, wipes prior token/outbox

# 2. Start the mock (background, -u) — see above

# 3. Fire the referee deep link (token value is arbitrary for the mock)
adb shell am start -a android.intent.action.VIEW \
  -d 'rcjrefmate://r/testsel.testsecret?base_url=http://127.0.0.1:8000'
```

Then drive the UI (see coordinates + gotchas below): dismiss the OS notification
prompt → set a score → play first half → half-time dialog "No" → SKIP the break
→ play second half → full-time fires the `POST`.

Verify in `/tmp/mock.log`:
```
GET  /api/v1/soccer/match/ ... 200
POST /api/v1/soccer/match/result/ body={'home_goals': 2, 'away_goals': 1, ...} ... 200
RECORDED -> version=2  2-1
```
And on screen at full-time: **"Game Over", score preserved (NOT reset to 0-0)** —
that's the headline `gameInit()`-only-`if(!inGame)` fix.

---

## UI driving — coordinates & gotchas

> **Coordinates below are for a Pixel 10 in portrait (screenshot 1080×2400).**
> For another device/resolution, re-derive: `adb exec-out screencap -p > s.png`
> and read pixel positions, or `adb shell uiautomator dump` for a coordinate XML.

**Double-tap is the critical-action gesture** (start/stop, score, timer). Two
separate `adb shell input tap` calls are >300 ms apart (process overhead) and
register as two *single* taps — which do nothing. Put **both taps in one shell
call**:
```bash
adb shell "input tap 538 635; input tap 538 635"   # = one double-tap
```

| Target | Coord (Pixel 10 portrait) | Notes |
|---|---|---|
| Center timer button (START / STOP / SKIP / REPEAT) | `538 635` | double-tap |
| Red (left) score | `193 635` | double-tap = +1 goal |
| Blue (right) score | `885 635` | double-tap = +1 goal |
| Settings gear | `1017 245` | single tap |
| Notification permission "Allow / Povoliť" | `540 1381` | OS dialog after `pm clear`; language follows phone locale |
| Half-time "Switch Team Order" → **No** | `343 1382` | keeps order (clean home/away mapping) |
| Half-time "Switch Team Order" → **Yes** | `737 1382` | swaps sides — use to test mapping under a swap |
| Module tiles A1/B1/A2/B2 | ~`280 1000` / `800 1000` / `280 1670` / `800 1670` | **long-press** opens per-module BLE settings |

**Match stage flow:** firstHalf → (timer hits 0) → **half-time** (shows the
Switch-Team-Order dialog + a break countdown + SKIP) → secondHalf → (timer hits
0) → **fullTime** (the result `POST` fires here; button becomes REPEAT).
`REPEAT` (double-tap) resets to a fresh first half (re-applies the loaded config).

**Waiting for the timer.** A long foreground `sleep` is blocked by the harness.
Use a background bash deadline loop (one completion notification), then screenshot:
```bash
end=$(($(date +%s)+33)); while [ $(date +%s) -lt $end ]; do sleep 2; done; echo DONE
# run_in_background: true ; ~33s covers a 30s half + transition
```

**Screenshots:** `adb exec-out screencap -p > shot.png` then read the PNG.

---

## Error-injection scenarios

- **409 conflict:** start the mock with `RESULT_STATUS=409`. At full-time the app
  shows orange **"Final result requires manual review"**, keeps the link/outbox,
  and does **not** auto-clear. (To re-submit after a real 200, you must restart
  the mock — token is single-use.)
- **Client timeout:** `HANG=20` (> the 15 s request timeout). The `POST` is
  marked a retriable failure and re-attempted on the 20 s retry tick.
- **Auth reject:** `MATCH_STATUS=401` (GET) or `RESULT_STATUS=401`/`422` (POST) →
  terminal "rejected", not retried.

---

## Cleanup

```bash
pkill -f mock_scoreboard.py
adb reverse --remove tcp:8000
adb shell pm clear com.robocup.rcj_soccer   # optional: drop the test match/outbox
```

---

## Known limitations of this test path

- The scoreboard match payload carries **no module MAC addresses** (or side), so
  the deep link **cannot auto-connect robot modules** — that's a server-side gap,
  not testable here. Module BLE auto-connect is a separate manual flow
  (per-module MAC entry / QR / catigoal comment).
- Auto-clear-after-submit wipes the on-screen "submitted" confirmation + outbox
  audit trail; left as-is pending the end-of-match review/confirmation screen
  (issue #51). Don't flag it as new.
