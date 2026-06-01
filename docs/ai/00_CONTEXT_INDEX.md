# AI Context Index

This file tells future Claude/Codex agents what each documentation file contains and in which order to read them.

## Reading order

| Priority | File | Contents |
|---|---|---|
| Always first | `CLAUDE.md` | Critical invariants, key files, toolchain, what NOT to do |
| Always second | This file (`00_CONTEXT_INDEX.md`) | Topic routing |
| Before any code change | `01_PROJECT_MAP.md` | Exact file paths, symbols, entry points |
| Before architectural work | `02_RUNTIME_ARCHITECTURE.md` | State flow, BLE flow, command sequencing |
| Before bug fixing | `03_AUDIT_FINDINGS.md` | Known bugs, risks, severities |
| For Android/Play work | `04_ANDROID15_PLAY_COMPLIANCE_PLAN.md` | Edge-to-edge, deprecated APIs, 16 kB pages |
| For BLE bridge work | `05_BLE_BRIDGE_FEATURE_PLAN.md` | Full feature design and protocol proposal |
| For task execution | `06_CODEX_TASKS.md` | Specific small tasks with step-by-step instructions |
| For what actually shipped | `handoff/BRIDGE_REPORT.md`, `handoff/AUDIT-FIX-03_REPORT.md` | Codex/Claude review notes, gate results, fixes as built |

## Topic routing

### For Android Play warning work, read:
1. `CLAUDE.md` → toolchain versions section
2. `04_ANDROID15_PLAY_COMPLIANCE_PLAN.md` → full plan
3. `06_CODEX_TASKS.md` → tasks PLAY-01 through PLAY-07

### For BLE bridge work, read:
1. `CLAUDE.md` → BLE rules section
2. `02_RUNTIME_ARCHITECTURE.md` → BLE flow section
3. `05_BLE_BRIDGE_FEATURE_PLAN.md` → full design
4. `06_CODEX_TASKS.md` → tasks BRIDGE-01 through BRIDGE-12

### For general code changes, read:
1. `CLAUDE.md`
2. `01_PROJECT_MAP.md` → find the relevant files
3. `02_RUNTIME_ARCHITECTURE.md` → understand state flow
4. `03_AUDIT_FINDINGS.md` → check for related known issues
5. `06_CODEX_TASKS.md` → find the relevant task

### For bug fixing, read:
1. `03_AUDIT_FINDINGS.md` → locate the finding
2. `01_PROJECT_MAP.md` → find the file
3. `06_CODEX_TASKS.md` → check if there is already a task

## What is NOT in these files
- Production source code (use `lib/` tree)
- Git history (use `git log`)
- Build outputs (use `build/` tree — but do not modify)
- Secrets or credentials (these are never documented here)

## Release status
- **0.9.8 / versionCode 10** shipped to Google Play **Production (100%)** on
  **2026-06-01**, git tag **`v0.9.8`** (commit that built it: `5750ca5`). Includes
  the Play-compliance toolchain upgrade + BLE bridge iteration 1. Working version
  is now `0.9.9+11` (next dev cycle).
- Play App Signing is enabled; the upload key is `upload` (keystore + passwords
  backed up by the owner, outside the repo). `android/key.properties` is gitignored.

## Freshness
This documentation was first generated **2026-05-24** (Flutter 3.22.2) and last
synced **2026-06-01** for the 0.9.8 release (Flutter **3.44.0**). The 0x–0x docs
below may still describe the *pre-upgrade* world or *proposal-stage* designs — when
they conflict with `CLAUDE.md` or the `handoff/` reports, the newer file wins.
Always verify versions with `flutter --version` and `pubspec.yaml` before acting on
version-specific claims.
