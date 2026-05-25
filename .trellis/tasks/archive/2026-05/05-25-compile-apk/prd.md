# compile-apk

## Goal

Build a debug Android APK for the Flutter app and leave the artifact ready for handoff.

## Requirements

* Build the debug APK flavor.
* Use the repository's existing Android build/toolchain conventions.
* Produce the APK artifact only; do not require device installation.

## Acceptance Criteria

* [x] Debug APK builds successfully.
* [x] APK output path is known and reproducible.
* [x] Build uses the repo's pinned Android/NDK/Flutter toolchain.

## Definition of Done

* APK artifact exists.
* Build command and output path are recorded.
* Any build blockers are surfaced clearly.

## Result

* APK: `flutter_app/build/app/outputs/flutter-apk/app-debug.apk`
* Artifact hash: `fd17140cda3acb00008ff5156950fd37030daeb81f00fa60f9ce63f20b2e5d7e`
* Build path: `bash build_android_debug.sh` with PATH fixed to include `/root/.cargo/bin`, `/root/flutter/bin`, and Android platform tools.

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
