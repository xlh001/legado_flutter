# Research: Local Diagnostic Logging Patterns

- **Query**: Research local diagnostic logging patterns for this Flutter + Rust mobile app, including Flutter error capture, debugPrint wrapping, breadcrumbs, rotation/retention, privacy, Settings export/view/delete UX, and bridging Rust tracing/FRB failures without editing generated FRB bindings.
- **Scope**: mixed
- **Date**: 2026-05-25

## Findings

### Files Found

| File Path | Description |
|---|---|
| `flutter_app/lib/main.dart` | App startup, current FRB init smoke test, `ProviderScope` overrides, and `MaterialApp.router` setup. |
| `flutter_app/lib/core/persistence/json_store.dart` | Shared app-side persistence helper and `resolvePersistenceDir()` used for app documents/support directories. |
| `flutter_app/lib/core/router.dart` | Central `go_router` route table; Settings route and feature routes are registered here. |
| `flutter_app/lib/features/settings/settings_page.dart` | Settings UI grouped into sections; existing tool/about entries show where local log view/export/delete entry points would fit. |
| `flutter_app/lib/core/providers.dart` | Riverpod provider hub referenced by main/settings/router; `dbPathProvider`/settings providers are consumed across app code. |
| `flutter_app/lib/core/services/source_validation_service.dart` | Existing service-wrapper pattern for FRB calls; provider-injected service avoids direct `rust_api` dependencies in widget trees. |
| `flutter_app/lib/src/rust/api.dart` | Generated/committed Dart wrapper around FRB calls; generated artifacts should not be edited. |
| `core/bridge/src/api.rs` | FRB public functions return primitive `Result<_, String>`/JSON strings and map Rust errors to strings. |
| `core/api-server/src/main.rs` | Server binary configures `tracing_subscriber::fmt()` with `EnvFilter` and demonstrates token redaction in logs. |
| `core/core-storage/src/database.rs` | Example Rust library crate emitting `tracing::{debug, info, warn}` events without configuring a subscriber. |
| `.trellis/spec/flutter-app/persistence.md` | App persistence contracts: non-sensitive local files via `json_store.dart`; sensitive fields via secure storage; avoid ad-hoc file IO for normal feature persistence. |
| `.trellis/spec/flutter-app/state-and-providers.md` | Riverpod conventions and service-wrapper pattern for FRB calls. |
| `.trellis/spec/flutter-app/quality-and-anti-patterns.md` | Privacy/security constraints; production `print`/`debugPrint` guidance; credential vault rules. |
| `.trellis/spec/cross-language/frb-bridge.md` | FRB contract: primitives/JSON strings, `Result<_, String>`, generated Dart files are not hand-edited. |
| `.trellis/spec/rust-core/logging.md` | Rust logging contract: library crates emit `tracing`, binaries/FRB init install subscribers, forbidden sensitive values. |

### Code Patterns

#### Flutter startup and error-capture insertion points

- `flutter_app/lib/main.dart:15-17` starts with `Future<void> main() async { WidgetsFlutterBinding.ensureInitialized(); ... }`. There is no current `runZonedGuarded`, `FlutterError.onError`, or `PlatformDispatcher.instance.onError` setup in `main.dart`.
- `flutter_app/lib/main.dart:24-38` catches FRB initialization/smoke-test failures, logs them with `debugPrint`, then shows `_FrbInitErrorApp` rather than crashing. Lines 31-33 log `e` and `st`; lines 36-37 call `runApp(_FrbInitErrorApp(...))` and return.
- `flutter_app/lib/main.dart:67-81` wraps the app in `ProviderScope` with many persisted startup overrides. This is the existing Riverpod composition point for app-wide state.
- `flutter_app/lib/main.dart:148-155` uses `MaterialApp.router(routerConfig: router)`, so route-level navigation breadcrumbs can be mapped from the central `router` rather than scattered `Navigator` observers.

External Flutter docs state that framework-caught errors are routed to `FlutterError.onError`, and recommend calling `FlutterError.presentError(details)` from a custom handler to keep console output. Errors outside Flutter callbacks are handled through `PlatformDispatcher.instance.onError`.

#### `debugPrint` usage and wrapper surface

- The codebase uses `debugPrint` directly in app code. Examples: FRB smoke logs in `flutter_app/lib/main.dart:27-33`, DB init logs in `flutter_app/lib/main.dart:111-123`, and many reader diagnostics in `flutter_app/lib/features/reader/reader_page.dart` (e.g. `reader_page.dart:243`, `reader_page.dart:460-480`, `reader_page.dart:637`).
- `flutter_app/lib/core/persistence/json_store.dart:119-123` logs write failures with `debugPrint('Failed to save $errorTag: $e')` when `errorTag` is present.
- There is no existing app-local `debugPrint` replacement or global wrapper found in `flutter_app/lib`.

The Flutter `debugPrint` API is a top-level mutable callback (`DebugPrintCallback debugPrint = debugPrintThrottled`) in `package:flutter/foundation.dart`; common lightweight patterns assign a wrapper that forwards to the original callback and also writes to a local sink. This avoids changing every call site, but it should preserve throttling/console behavior by delegating to the original callback.

#### User-action breadcrumbs and routing

- `flutter_app/lib/core/router.dart:31-33` defines a single global `GoRouter` with `initialLocation: '/bookshelf'`.
- Feature routes are centralized, e.g. `/settings` at `router.dart:103-106`, `/reader` at `router.dart:107-115`, `/backup` at `router.dart:129-133`, `/cache-management` at `router.dart:144-148`, `/rss-articles-detail` at `router.dart:163-170`.
- Settings actions use `context.push(...)`, e.g. `flutter_app/lib/features/settings/settings_page.dart:246-252` (`/backup`), `settings_page.dart:253-259` (`/read-stats`), `settings_page.dart:261-266` (`/cache-management`), `settings_page.dart:281-287` (`/replace-rules`).
- Existing route/pending-route logic in `flutter_app/lib/main.dart:82-100` uses the global `router.go(route)` and `applyDefaultHomePage(...)` after first frame.

For breadcrumbs, this repo already has a centralized router and Settings action list. Route transitions, Settings tool taps, FRB wrapper calls, and high-value user operations can be represented as small structured messages without dumping payloads.

#### App-local file persistence conventions

- `flutter_app/lib/core/persistence/json_store.dart:55-69` defines `resolvePersistenceDir({String? directory})`: Android uses `getApplicationDocumentsDirectory()`, other platforms use `getApplicationSupportDirectory()`.
- `json_store.dart:71-73` builds files under that directory.
- `json_store.dart:104-124` serializes `settings.json` writes through a module-level mutex; `json_store.dart:196-205` provides whole-file JSON writes for feature-owned JSON files.
- `.trellis/spec/flutter-app/persistence.md:3-5` says app-side persistence goes through `json_store.dart`, and sensitive fields must go through `core/security/secure_storage.dart`, not JSON files.
- `.trellis/spec/flutter-app/persistence.md:40` says new persistence call sites should not call `path_provider` or `File.readAsString` directly; this is a project convention for normal feature persistence. Diagnostic log files are not JSON settings, but should still share `resolvePersistenceDir()` so paths match app storage behavior.

#### Settings UX shape for view/export/delete

- `flutter_app/lib/features/settings/settings_page.dart:100-103` uses a `Scaffold` with a `ListView`.
- Settings is grouped by `_SectionHeader`, e.g. `通知` at `settings_page.dart:104`, `显示` at `settings_page.dart:129`, `工具` at `settings_page.dart:241`, `关于` at `settings_page.dart:289`.
- Tool entries are `ListTile`s with icon, title, subtitle, chevron, and `context.push(...)` (e.g. `settings_page.dart:246-287`).
- The project already depends on `share_plus` in reader code (`flutter_app/lib/features/reader/reader_page.dart:11` and a `SharePlus.share` failure log at `reader_page.dart:2817`), so export/share UX may be able to reuse an existing dependency rather than adding a heavy crash-reporting/logging SDK.

#### Rust tracing and mobile subscriber constraints

- `.trellis/spec/rust-core/logging.md:3-10` says workspace logging uses `tracing`; library crates emit events and never configure a subscriber. It also states a subscriber is installed by `api-server::main` for binary runs and by FRB initialization for the mobile app.
- In code, `core/api-server/src/main.rs:94-99` installs a subscriber with `tracing_subscriber::fmt().with_env_filter(...).init()`.
- Rust library files emit events with `tracing`, e.g. `core/core-storage/src/database.rs:7` imports `debug, info, warn`; `database.rs:15`, `49`, `82`, `91`, `97` log DB lifecycle and migration events.
- `core/bridge/src/frb_generated.rs:4647` and `4674` log unknown FRB funcIds with `tracing::error!`.
- Searches did not find a mobile-specific persistent file subscriber setup in `core/bridge/src/api.rs` or nearby mobile-facing code. Current mobile observations are consistent with `.trellis/spec/rust-core/logging.md:76`: Flutter debug builds pipe Rust logs through FRB into `print` lines visible in `flutter logs`.

#### FRB failure surfacing without generated-file edits

- `.trellis/spec/cross-language/frb-bridge.md:7-18` says every FRB-exposed function returns `Result<String, String>`, `Result<(), String>`, or `Result<i64, String>` and takes primitive parameters; `Result<_, String>` lets Rust errors reach Flutter as Dart exceptions with the message intact.
- `.trellis/spec/cross-language/frb-bridge.md:111-118` lists generated artifacts and says generated Dart files (`flutter_app/lib/src/rust/api.dart`, `frb_generated.dart`, `frb_generated.io.dart`, `frb_generated.web.dart`) must not be hand-edited.
- `core/bridge/src/api.rs:17-21` shows the pattern: `init_legado(db_path: String) -> Result<String, String>` maps Rust DB init errors to `format!("初始化失败: {}", e)`.
- `flutter_app/lib/core/services/source_validation_service.dart:5-11` documents a wrapper around a FRB call for testability. `source_validation_service.dart:41-43` exposes `sourceValidationServiceProvider = Provider<SourceValidationService>((ref) => SourceValidationService());`.
- `.trellis/spec/flutter-app/state-and-providers.md:56` says pages wrapping one or more `rust_api.xxx` FRB calls should prefer a service class under `core/services/` over optional callbacks through page constructors. Lines 93-123 define naming conventions (`XxxApiClient` for FRB wrappers, `XxxService` for cross-cutting helpers).

This means FRB failure logging can be added at Dart wrapper/service call sites (or a small cross-cutting helper used by wrappers) without modifying generated bindings.

### Log Rotation and Retention Patterns

#### Flutter-side local files without heavy dependencies

Lightweight mobile patterns use `dart:io` with append-only text/JSONL files in the app documents/support directory, plus manual rotation before/after append:

- Use a small `*.log` or JSONL format with one event per line; include timestamp, level, source (`flutter`, `rust`, `frb`, `breadcrumb`), category, and redacted message.
- Keep bounded size (for example active file plus N rotated files) and/or bounded age (for example 7-14 days). Rotation can be size-based because it is deterministic and does not need a scheduler.
- Retention cleanup can run during startup and before export/view.
- Avoid synchronous UI-thread work in hot paths; a simple queued async writer or buffered sink reduces jank.

No existing dependency for file logging was found. Existing `dart:io`, `path_provider` through `resolvePersistenceDir()`, and existing `share_plus` are enough for basic local file write/view/share/delete.

#### Rust-side rotation option

The `tracing-appender` crate provides rolling file appenders. Its docs state that `RollingFileAppender` creates a new file at a fixed frequency and supports minutely/hourly/daily/never rotation; example: `RollingFileAppender::new(Rotation::HOURLY, "/some/directory", "prefix.log")`. This is a Rust dependency path, not currently present in repo search results.

For this repo’s constraints, Flutter-owned local log storage is lower-friction because Flutter already knows the persistence directory and Settings UX, while Rust mobile persistent subscriber setup was not found. Rust `tracing` events can either continue through FRB/print in debug or be bridged explicitly with a new non-generated FRB API if maintainers choose to add one.

### Privacy Patterns

Repo specs already provide strong constraints:

- `.trellis/spec/rust-core/logging.md:41-50` forbids logging WebDAV passwords, backup encryption keys, API-server debug tokens, raw cookie jars, Authorization headers, and `legado_local.json` contents. It recommends hashing credential-adjacent values with SHA-256 and logging a hex prefix if needed.
- `.trellis/spec/flutter-app/quality-and-anti-patterns.md:188-191` says production `print`/`debugPrint` should not be used for production logs and credentials must not be written to plain JSON/settings files.
- `.trellis/spec/flutter-app/quality-and-anti-patterns.md:207-214` lists sensitive fields: user passwords, API tokens, device private keys, OAuth refresh tokens, HTTP basic auth credentials, WebDAV password, Legado backup password.
- `.trellis/spec/flutter-app/persistence.md:3-5` repeats that sensitive fields go through secure storage, not JSON files.

For diagnostic logs in this app, additional payloads to avoid are request/response bodies, cookies, Authorization headers, WebDAV credentials, backup password fields, source JS that may contain secrets, and novel/chapter content dumps. Reader code currently logs timing, indices, and failures; local diagnostics should preserve that style and avoid chapter text/content strings.

### External References

- [Flutter docs: Handling errors in Flutter](https://docs.flutter.dev/testing/errors) — Framework errors go to `FlutterError.onError`; custom handlers should call `FlutterError.presentError`; errors outside Flutter callbacks use `PlatformDispatcher.instance.onError`.
- [Flutter API: PlatformDispatcher.onError](https://api.flutter.dev/flutter/dart-ui/PlatformDispatcher/onError.html) — Handles unhandled root-isolate errors, returns `true` when handled; does not cover child isolates unless forwarded.
- [Dart API: runZonedGuarded](https://api.dart.dev/stable/dart-async/runZonedGuarded.html) — Runs a body in its own error zone and handles synchronous plus asynchronous uncaught errors via `onError`.
- [Flutter foundation `debugPrint`](https://api.flutter.dev/flutter/foundation/debugPrint.html) — Top-level debug print callback; fetched URL returned 404 in this environment, but API is in `package:flutter/foundation.dart` and is commonly assignable/wrappable.
- [tracing-subscriber `SubscriberBuilder`](https://docs.rs/tracing-subscriber/latest/tracing_subscriber/fmt/struct.SubscriberBuilder.html) — Supports `.with_env_filter`, `.with_max_level`, `.with_writer`, `.try_init`, `.init`, `.json`, etc.; `.init()` panics if a global subscriber already exists, while `.try_init()` returns an error.
- [tracing-appender rolling module](https://docs.rs/tracing-appender/latest/tracing_appender/rolling/index.html) — Provides fixed-frequency rolling file appenders (`minutely`, `hourly`, `daily`, `weekly`, `never`).

### Related Specs

- `.trellis/spec/flutter-app/persistence.md` — Persistence directory and file-writing conventions; sensitive data excluded from JSON/local files.
- `.trellis/spec/flutter-app/state-and-providers.md` — Riverpod-only state management and service-wrapper pattern for FRB/cross-cutting helpers.
- `.trellis/spec/flutter-app/quality-and-anti-patterns.md` — Privacy and anti-pattern constraints for debug logging and credential storage.
- `.trellis/spec/cross-language/frb-bridge.md` — FRB generated-file constraints and primitive `Result<_, String>` API shape.
- `.trellis/spec/rust-core/logging.md` — Rust `tracing` levels, subscriber responsibilities, and forbidden sensitive log fields.

## Caveats / Not Found

- No current app-local persistent diagnostic logger was found in `flutter_app/lib`.
- No current `FlutterError.onError`, `PlatformDispatcher.instance.onError`, or `runZonedGuarded` setup was found in `flutter_app/lib/main.dart`.
- No current global `debugPrint` wrapper/replacement was found.
- No current mobile-side persistent Rust `tracing` subscriber implementation was found in searched Rust bridge/mobile-facing files; only `api-server` subscriber setup was found.
- The Flutter `debugPrint` API URL returned 404 via `webfetch`; the finding about assignability comes from Flutter SDK API behavior rather than that fetched page.
