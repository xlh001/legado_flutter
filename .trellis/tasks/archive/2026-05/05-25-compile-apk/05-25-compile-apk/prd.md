# compile-apk

## Goal

Build a debug Android APK for the Flutter app and leave the artifact ready for handoff.

## Requirements

* Build the debug APK flavor.
* Use the repository's existing Android build/toolchain conventions.
* Produce the APK artifact only; do not require device installation.

## Acceptance Criteria

* [ ] Debug APK builds successfully.
* [ ] APK output path is known and reproducible.
* [ ] Build uses the repo's pinned Android/NDK/Flutter toolchain.

## Definition of Done

* APK artifact exists.
* Build command and output path are recorded.
* Any build blockers are surfaced clearly.

## Technical Approach

Use the existing `build_android_debug.sh` / Flutter debug build flow as the reference for toolchain and output conventions. The task is limited to producing the APK, not installation.

## Decision (ADR-lite)

**Context**: The user asked for a debug APK.

**Decision**: Build a debug APK artifact only, without forcing install to a connected device.

**Consequences**: Faster, less brittle, and avoids a hard adb dependency for the handoff.

## Out of Scope

* Release APK/signing work.
* Device installation after the build.
* Code changes unrelated to the APK build itself.

## Technical Notes

* Build script reference: `build_android_debug.sh`
* Android/NDK conventions: `.trellis/spec/build-and-release/android-build.md`
* Build-script conventions: `.trellis/spec/build-and-release/build-scripts.md`
* Flutter/Rust bridge build caveats still apply because the APK bundles `libbridge.so`.
