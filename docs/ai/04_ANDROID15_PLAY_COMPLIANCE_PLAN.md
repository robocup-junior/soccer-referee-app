# Android 15 / Google Play Compliance Plan

## Current configuration

| Item | Current value | Required / Notes |
|---|---|---|
| Flutter | 3.22.2 | Upgrade to ≥3.27.x for all three Play issues |
| Dart | 3.4.3 | Follows Flutter |
| AGP (settings.gradle) | 8.3.2 | Upgrade to ≥8.7+ recommended |
| AGP (build.gradle classpath) | 8.1.4 | Mismatch — must align or remove |
| Gradle wrapper | 8.7 | OK for AGP 8.7; may need bump |
| NDK | 25.1.8937393 | Upgrade to r26b or r28 for 16 kB |
| Kotlin | 1.7.10 | Upgrade to ≥1.9.x; required for some AGP versions |
| targetSdk | 35 | Correct for Play compliance |
| minSdk | 21 | OK |
| compileSdk | flutter.compileSdkVersion (=34 in Flutter 3.22.2) | Should match targetSdk=35 |

---

## Warning A — Edge-to-edge / UI hidden under system bars

### What Google Play says
"From Android 15, apps targeting SDK 35 are displayed edge-to-edge by default."

### Root cause analysis
On Android 15 (API 35), the system enforces edge-to-edge for apps with `targetSdk=35`. The app window extends under status bar and navigation bar. Without explicit inset handling, UI content can be obscured.

**Current app state:**
- `targetSdk = 35` → edge-to-edge enforcement applies
- `android/app/src/main/res/values/styles.xml` uses `@android:style/Theme.Light.NoTitleBar` — not an edge-to-edge theme
- `android/app/src/main/res/values-night/styles.xml` uses `@android:style/Theme.Black.NoTitleBar` — same issue
- No `SafeArea` widget used in any Dart screen
- No `MediaQuery.of(context).padding` usage
- `resizeToAvoidBottomInset: false` in `Home` scaffold (intentional for this control UI)

**Flutter engine behavior:** Flutter's `FlutterActivity` in newer versions handles window insets and passes them to Dart via `MediaQuery`. However, the Dart code must use `SafeArea` or `Padding(EdgeInsets.fromWindowPadding(...))` to respect them.

### Likely impact areas
- `Home` screen: AppBar may overlap status bar slightly; "START/STOP ALL ROBOTS" button at bottom may overlap navigation bar
- `SettingsScreen`: ListView bottom may be hidden behind navigation bar
- `ModuleSettingsScreen`: ListView may be partially hidden
- `BarcodeScannerSimple` QR scanner: camera overlay fully covers screen, bottom info bar may be hidden

### Fix approach
1. Upgrade Flutter to ≥3.27.x (handles many inset issues at engine level)
2. Add `SafeArea` wrapping to main `Scaffold.body` content in `Home`, `SettingsScreen`, `ModuleSettingsScreen`, and `BarcodeScannerSimple`
3. Optionally update Android theme to use `Theme.Material.Light.NoActionBar` or rely on Flutter embedding's window management
4. Test on both Android 14 and Android 15

### What NOT to change
- Do not change `resizeToAvoidBottomInset: false` in Home — this is intentional to prevent the keyboard from resizing the robot control layout
- Do not add `SafeArea` inside the robot module button area in a way that reduces touch targets

---

## Warning B — Deprecated window APIs

### What Google Play says
Deprecated APIs flagged at:
- `io.flutter.embedding.android.i.G` → uses `Window.setStatusBarColor`
- `io.flutter.plugin.platform.d.a` → uses `Window.setNavigationBarDividerColor`
- `io.flutter.plugin.platform.h.C` → uses `Window.setNavigationBarColor`

### Root cause analysis

These class names (`i.G`, `d.a`, `h.C`) are **obfuscated names inside the Flutter engine JAR**, not in the app's own Kotlin/Dart code. The `io.flutter.embedding.android` and `io.flutter.plugin.platform` packages are part of the **Flutter engine embedding**, not the app.

**Verified**: `MainActivity.kt` contains only `class MainActivity: FlutterActivity()` — no custom window API calls.

**Dart code check**: No `SystemChrome.setSystemUIOverlayStyle`, `SystemChrome.setEnabledSystemUIMode`, or `SystemUiOverlayStyle` usage found anywhere in `lib/`.

**Conclusion**: These deprecated API calls come from **Flutter 3.22.2's embedding layer**, not the app code. The app developer cannot fix them without upgrading Flutter.

### Fix: Flutter upgrade
- Flutter ≥3.27.x replaces `setStatusBarColor`/`setNavigationBarColor` calls with the new `WindowInsetsController` API introduced in Android 11 and properly handles the edge-to-edge APIs for Android 15
- No changes needed in `MainActivity.kt` or Dart code
- The custom themes in `styles.xml` may need updating to use `Theme.Material3` parent after Flutter upgrade (verify after upgrade)

### Verification after Flutter upgrade
```bash
# Check that deprecated APIs no longer appear in the compiled APK:
cd android
./gradlew assembleRelease
# Then inspect with:
python3 -c "
import zipfile
with zipfile.ZipFile('../build/app/outputs/flutter-apk/app-release.apk') as z:
    print([n for n in z.namelist() if 'flutter' in n.lower()])
"
# Upload to Google Play internal test track and verify Play Console no longer shows the warning
```

---

## Warning C — 16 kB memory page size

### What Google Play says
"Native libraries are not aligned for 16 kB page size."

### Native libraries found (from build output)

| Library | Source | 16 kB aligned? |
|---|---|---|
| `libflutter.so` | Flutter engine 3.22.2 | **No** — Flutter ≥3.27 needed |
| `libbarhopper_v3.so` | MLKit (via mobile_scanner) | **No** — depends on MLKit version |
| `libimage_processing_util_jni.so` | MLKit (via mobile_scanner) | **No** — depends on MLKit version |
| `libapp.so` | Compiled Dart code | Generated by Flutter engine — follows engine |
| `libVkLayer_khronos_validation.so` | Vulkan validation (debug only) | Debug only, not in release |

### Root cause
- **Flutter engine 3.22.2** does not support 16 kB page alignment. Support was added in Flutter 3.27 (November 2024).
- **MLKit libraries** bundled via `mobile_scanner ^6.0.10` — need to verify which MLKit version is used. MLKit ≥17.x supports 16 kB alignment.
- NDK 25.1.8937393 does not support 16 kB toolchain. NDK r26b+ is needed.

### Fix approach
1. Upgrade Flutter to ≥3.27.x — this rebuilds `libflutter.so` with 16 kB page support
2. Upgrade `mobile_scanner` to latest (≥6.1.x) which pulls a newer MLKit — verify 16 kB support
3. Upgrade NDK to ≥r26b (ideally r28) in `android/app/build.gradle`: `ndkVersion "26.3.11579264"` or latest
4. Upgrade AGP to ≥8.5+ which supports `jniLibs.useLegacyPackaging false` (keeps libraries uncompressed for proper page alignment)

### Verification commands
```bash
# Check alignment of native libraries in release APK
python3 - <<'EOF'
import zipfile, struct
with zipfile.ZipFile('build/app/outputs/flutter-apk/app-release.apk') as z:
    for info in z.infolist():
        if info.filename.endswith('.so'):
            offset = info.header_offset
            # For 16kB alignment: data offset must be aligned to 16384
            data_offset = offset + 30 + len(info.filename.encode()) + len(info.extra)
            aligned_4k = data_offset % 4096 == 0
            aligned_16k = data_offset % 16384 == 0
            print(f"{info.filename.split('/')[-1]:45s} 4k:{aligned_4k} 16k:{aligned_16k}")
EOF

# Or use zipalign (from Android SDK build-tools):
$ANDROID_SDK/build-tools/<version>/zipalign -c -v -p 16 \
  build/app/outputs/flutter-apk/app-release.apk
```

### Gradle flag for uncompressed native libs
Add to `android/app/build.gradle` `android {}` block (after AGP upgrade):
```groovy
packagingOptions {
    jniLibs {
        useLegacyPackaging = false
    }
}
```
This ensures `.so` files are stored uncompressed in the APK, which is required for 16 kB page alignment mapping.

---

## Manual test matrix

After all fixes are applied, test the following on both Android 14 and Android 15+:

| Screen | Android 14 (gesture nav) | Android 14 (3-button nav) | Android 15 (gesture nav) | Android 15 (3-button nav) |
|---|---|---|---|---|
| Home — AppBar not cut off by status bar | ✓ | ✓ | ? | ? |
| Home — "STOP ALL ROBOTS" button not behind nav bar | ✓ | ✓ | ? | ? |
| Home — Timer button not behind nav bar | ✓ | ✓ | ? | ? |
| Settings — ListView scrolls to bottom without cutoff | ✓ | ✓ | ? | ? |
| Module settings — Scan button visible | ✓ | ✓ | ? | ? |
| QR scanner — Bottom info bar visible | ✓ | ✓ | ? | ? |
| QR scanner — Camera fills screen correctly | ✓ | ✓ | ? | ? |
| Dialogs (exit, switch teams) — Buttons visible | ✓ | ✓ | ? | ? |
| Team bottom sheet — Content not hidden | ✓ | ✓ | ? | ? |
| Robot button double-tap still works (not accidentally triggered by inset change) | ✓ | ✓ | ? | ? |

---

## Acceptance criteria

- [ ] Google Play Console shows 0 warnings for deprecated window APIs
- [ ] Google Play Console shows 0 warnings for 16 kB page size
- [ ] Google Play Console shows 0 warnings for edge-to-edge
- [ ] `zipalign -c -v -p 16 app-release.apk` exits 0 (all .so files aligned)
- [ ] All manual test matrix rows pass on Android 15 device or emulator with 16 kB page size enabled
- [ ] No regression in robot START/STOP latency (test: start all robots, verify simultaneous movement)
- [ ] Flutter analyze returns 0 errors after changes

---

## Upgrade sequence (recommended order)
1. PLAY-01: Fix AGP version mismatch (lowest risk, no runtime change)
2. PLAY-02: Upgrade Kotlin to 1.9.x (required for newer AGP)
3. PLAY-03: Upgrade Flutter to 3.27.x (core change — fixes deprecated APIs + 16 kB libflutter.so)
4. PLAY-04: Upgrade NDK to r26b or r28
5. PLAY-05: Upgrade mobile_scanner and verify MLKit 16 kB support
6. PLAY-06: Add SafeArea to all screens (edge-to-edge UI fix)
7. PLAY-07: Verify zipalign + upload to Play internal track
