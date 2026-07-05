# Xcode Cloud CI/CD

This app builds for iOS on **Xcode Cloud**. Android + analysis stay on GitHub
Actions (`.github/workflows/`); Xcode Cloud only owns the iOS archive / TestFlight
/ App Store path, because that needs a signed macOS build Apple runs on their
infrastructure.

## What lives in the repo

`ci_scripts/ci_post_clone.sh` — the only part of Xcode Cloud that is
repo-defined. Xcode Cloud auto-runs any `ci_scripts/ci_post_clone.sh` (and the
optional `ci_pre_xcodebuild.sh` / `ci_post_xcodebuild.sh`) it finds next to the
selected Xcode workspace. Ours installs Flutter (pinned to the same version as
GitHub CI) and generates `Generated.xcconfig` + Pods so the subsequent
`xcodebuild` succeeds — Xcode Cloud images ship Xcode + CocoaPods but **not**
Flutter.

Keep the `FLUTTER_VERSION` in the script in lockstep with the
`flutter-version:` pin in `.github/workflows/*.yml`.

## What must be configured in App Store Connect (NOT in the repo)

Xcode Cloud **workflows** (triggers, actions, environment) live server-side, in
Xcode → Report navigator → Cloud, or App Store Connect → your app → Xcode Cloud.
Create the workflow once:

1. **Product / Xcode project**: workspace `ios/Runner.xcworkspace`, scheme
   `Runner`. (Ensure the `Runner` scheme is marked *Shared* in Xcode so Xcode
   Cloud can see it — `ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme`.)
2. **Environment**: pick an Xcode version compatible with Flutter 3.44.0; leave
   "Clean" off so caching helps. macOS default is fine.
3. **Start conditions (triggers)** — suggested to mirror GitHub CI:
   - Branch changes on `dev` → Build + Test (or Analyze) for fast feedback.
   - Tag changes matching the release tags (e.g. `v*`) → Archive → TestFlight
     (internal), matching `.github/workflows/release.yml`.
4. **Actions**: Archive (iOS), and optionally Test. Post-actions: deliver to
   TestFlight / App Store as desired.
5. **Signing**: use Xcode Cloud's managed signing (recommended) or your uploaded
   certificates/profiles. The bundle id is `com.robocup.rcjScoreboard`.

## Local sanity check of the script

You cannot run Xcode Cloud locally, but you can dry-run the bootstrap logic:

```sh
CI_PRIMARY_REPOSITORY_PATH="$(git rev-parse --show-toplevel)" \
  sh ios/ci_scripts/ci_post_clone.sh
```

(That installs Flutter into `~/flutter` if missing — skip if you already manage
Flutter yourself; the script guards against re-cloning.)
