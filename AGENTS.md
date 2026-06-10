# AGENTS.md — Codex Instructions for rcj_scoreboard

## Project overview
Flutter/Dart Android app (portrait-only) that:
- Connects to up to 10 BLE robot modules simultaneously
- Sends latency-critical START/STOP commands to all robots at once
- Tracks match score, timer, match stage
- Publishes data via MQTT
- Loads match schedule from HTTP API
- All critical UI actions use **double-tap** to prevent accidental activation

**Read `docs/ai/00_CONTEXT_INDEX.md` before any non-trivial task.**

## Commands

```bash
# Analyze (read-only, safe to run):
flutter analyze

# Test (may fail due to broken widget_test.dart — see AUDIT_FINDINGS):
flutter test

# Check dependency versions:
cat pubspec.lock

# Inspect APK alignment (read-only):
python3 - <<'EOF'
import zipfile, struct
with zipfile.ZipFile('build/app/outputs/flutter-apk/app-release.apk') as z:
    for info in z.infolist():
        if info.filename.endswith('.so'):
            print(f"{info.filename}: header_offset={info.header_offset}, "
                  f"compress={info.compress_type}, extra_len={len(info.extra)}")
EOF
```

Do NOT run: `flutter build`, `flutter pub upgrade`, `adb`, `gradle assembleRelease`, or any command that modifies generated files or builds artifacts.

## Code style rules (inferred from codebase)

- Dart: standard Flutter conventions, no enforced linting beyond `flutter_lints`
- No comments unless the "why" is non-obvious
- State management: `provider` + `ChangeNotifier` — add new notifiers to existing pattern
- All new services go in `lib/services/`
- All new models go in `lib/models/`
- All new screens go in `lib/screens/`
- Settings persist via `SharedPreferences` — follow existing pattern in `MqttService`
- New `ChangeNotifier` classes must be registered in `main.dart` `MultiProvider`

## BLE rules — READ CAREFULLY

### Robot module commands (DO NOT CHANGE THESE PATHS)
- `bleSendPlayAll()` and `bleSendStopAll()` use `timeout:0` — fire-and-forget, no ACK
- They are called from `Module.playAll()` and `Module.stopAll()` WITHOUT `await`
- `Game.playAll()` calls module methods WITHOUT `await` — this launches all module sends in parallel
- **Never add `await`, synchronization, queues, or blocking logic to the robot command path**
- **Never make robot sends wait for bridge ACKs or any external confirmation**

### BLE bridge (new feature — see `docs/ai/05_BLE_BRIDGE_FEATURE_PLAN.md`)
- Must be a completely separate service class (`BleBridgeService`)
- Must use its own BLE connection, independent of Module connections
- Must never block or delay the robot command path
- Uses an async message queue with ACK/retry — opposite of robot fire-and-forget

## Android/Flutter compatibility rules
- targetSdk=35, minSdk=21
- Flutter 3.22.2 (upgrade to ≥3.27.x is planned — do not assume newer APIs exist)
- AGP 8.1.4/8.3.2 mismatch in Gradle files — do not add a third version; fix the mismatch
- NDK 25.1.8937393 — planned upgrade; do not change without explicit task instruction
- Kotlin 1.7.10 — planned upgrade; do not change without explicit task instruction
- No iOS-only changes; Android is the target platform

## UI safety rules
- All critical actions use `onDoubleTap`, NOT `onTap` — do not change to single-tap
- Long-press opens settings/config screens — do not remove this
- `PopScope(canPop: false)` prevents accidental back-press — do not remove
- No SafeArea is currently used — **an open task requires adding SafeArea** for Android 15 edge-to-edge

## Secrets / credentials
- `android/key.properties` contains signing credentials — it is gitignored — do NOT commit it
- MQTT credentials are stored in `SharedPreferences` — do not log them or expose them
- The `lib/services/mqtt.dart` file contains a default HiveMQ server address and username in source — do NOT copy these into documentation or logs

## Small-changes-only workflow
1. Read the relevant `docs/ai/` file for your task
2. Read the target source file(s) completely before editing
3. Make the smallest change that fulfills the task
4. Run `flutter analyze` after changes
5. Run the verification commands specified in the task
6. Do NOT change files listed under "Files/areas not to touch" in the task

## Warning: things Codex must never do
- Do not add blocking ACK/confirmation logic to `bleSendPlayAll()`, `bleSendStopAll()`, `bleSendPlay()`, or `bleSendStop()`
- Do not change `onDoubleTap` to `onTap` anywhere in `lib/screens/home.dart`
- Do not introduce any import of the BLE bridge service into `lib/models/module.dart` or `lib/models/game.dart`
- Do not commit `android/key.properties` or any file containing credentials
- Do not run `flutter pub upgrade` or modify `pubspec.lock` without explicit approval
- Do not change protocols or data models without updating the relevant `docs/ai/` file
- Do not remove `cancelWhenDisconnected` or connection state subscription from Module
- Do not merge BLE bridge settings into the main robot module settings flow
