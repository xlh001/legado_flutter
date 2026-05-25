# Local Diagnostic Logging System

## Goal

Add a local diagnostic logging system that records what happened in the app, stores bounded logs on device, and gives developers/users a way to view, export, and clear logs for troubleshooting and tuning.

Implementation status: starting Implementation Task 1, the Flutter logger foundation and global capture layer. Diagnostics UI, targeted feature breadcrumbs, and Rust tracing file sink remain follow-up tasks.

## What I Already Know

* The user wants a complete local record of app situations so issues can be analyzed and behavior can be adjusted.
* The Flutter app currently logs many diagnostics with `debugPrint`, especially startup, DB init, reader timing, search, notifications, source management, and backup flows.
* The Flutter app does not currently install global `FlutterError.onError`, `PlatformDispatcher.instance.onError`, or `runZonedGuarded` handlers.
* The Rust workspace already uses `tracing`, but code search found only the standalone API server configuring a `tracing_subscriber`; no mobile persistent log sink was found.
* FRB generated Dart files must not be hand-edited. Cross-language failures currently surface as Dart exceptions from `Result<_, String>`.
* Flutter persistence should share `resolvePersistenceDir()` from `core/persistence/json_store.dart` for app-local paths.
* Settings already has a `工具` section with `ListTile` entries that navigate to tool pages.

## Research References

* [`research/local-diagnostic-logging-patterns.md`](research/local-diagnostic-logging-patterns.md) - Lightweight Flutter-first local logging can capture global errors, wrapped `debugPrint`, breadcrumbs, bounded rotation, privacy redaction, and Settings export without generated FRB edits.
* [`research/repo-logging-surfaces.md`](research/repo-logging-surfaces.md) - Repo-specific logging surfaces include startup, DB init, reader, search, source, backup, notification, Rust `tracing`, Settings routes, and existing persistence/export test patterns.

## Requirements (Evolving)

* Current implementation scope is Implementation Task 1: Flutter logger foundation and global capture.
* Store diagnostic logs locally under the app persistence directory.
* Use a structured line format suitable for analysis, likely JSONL with one event per line.
* Capture Flutter framework errors and uncaught async/root-isolate errors.
* Capture existing `debugPrint` output while preserving console behavior.
* Record key user/action breadcrumbs such as route changes and high-value Settings/source/reader/download operations, while avoiding noisy low-value taps.
* Record FRB call failures at Dart call sites or service wrappers without editing generated FRB files.
* Bound disk usage with rotation and retention.
* Provide a Settings entry for diagnostics/logs.
* Provide local view, export/share, and clear actions.
* Export logs as one merged `.jsonl` file by default for easy machine analysis and simple implementation.
* Diagnostics logging is enabled by default with bounded retention and privacy redaction, so the app can capture context before an intermittent issue is reported.
* Settings should let users disable local diagnostic logging, clear existing logs, and export logs when needed.
* Diagnostic logs are not included in normal book/app backup zip files; they are exported only from the Diagnostics page.
* Automatically write one minimal environment event on startup so exported logs identify app/build/platform/DB context without collecting detailed device identity.
* Default log level is `debug`, recording `debug`, `info`, `warn`, and `error` events unless the user lowers the level later.
* Never log passwords, tokens, cookies, authorization headers, backup passwords, WebDAV credentials, raw request/response bodies, chapter/novel content, or full source JS payloads.

## Proposed MVP Design

### Storage

* Directory: `<resolvePersistenceDir()>/logs/`.
* Active file: `app.log.jsonl`.
* Rotated files: `app.1.log.jsonl`, `app.2.log.jsonl`, etc.
* Event fields: `ts`, `level`, `source`, `category`, `message`, optional `error`, optional `stack`, optional `metadata`.
* Default bounds: keep 5 files, 1 MB each, max about 5 MB total, and delete files older than 14 days.
* Retention cleanup: run on logger init, after rotation, and before export/view.
* Default enabled state: enabled for all builds unless the user disables it in Settings.
* Persisted setting: `diagnosticLoggingEnabled` in `settings.json`, default `true`.
* Persisted setting: `diagnosticLogLevel` in `settings.json`, default `debug`.

### Event Schema

Each log line is one compact JSON object. The schema should stay append-only so old logs remain readable after app upgrades.

```json
{
  "ts": "2026-05-25T12:34:56.789Z",
  "level": "warn",
  "source": "flutter",
  "category": "source.delete",
  "message": "Batch delete source failed",
  "error": "FOREIGN KEY constraint failed",
  "stack": "...optional...",
  "metadata": {
    "selected_count": 12,
    "route": "/sources"
  }
}
```

Levels:

* `debug`: timing and verbose diagnostics useful during tuning.
* `info`: lifecycle and user-action breadcrumbs.
* `warn`: recoverable failure, fallback path, partial failure.
* `error`: failed operation or uncaught exception that needs investigation.

Default threshold:

* Default: `debug`, so all four levels are stored.
* User-adjustable later: `debug`, `info`, `warn`, `error`.
* Events below the configured threshold are not enqueued or written.
* Because default `debug` can rotate faster, high-frequency debug call sites must still be selective and avoid per-frame/per-scroll/per-character logging.

Sources:

* `flutter`: Dart/UI/app lifecycle events.
* `frb`: Flutter-side bridge call failures and Rust error strings surfaced through FRB.
* `rust`: future Rust `tracing` file sink or explicit Rust diagnostics bridge.
* `user`: high-value user actions and route breadcrumbs.

### Flutter Capture

* Install logger early in `main()` after `WidgetsFlutterBinding.ensureInitialized()`.
* Wrap `debugPrint` to both forward to the original callback and append to the local log.
* Install `FlutterError.onError` and call `FlutterError.presentError(details)` before writing a log event.
* Install `PlatformDispatcher.instance.onError` for uncaught root-isolate errors.
* Run app startup inside `runZonedGuarded` to capture uncaught async errors.
* Add explicit breadcrumbs in high-value flows after initial logger scaffolding exists.

Capture matrix:

| Situation | Capture Point | Level | Notes |
|---|---|---|---|
| App startup | `main()` after logger init | `info` | Include app version/build if available, not device identifiers. |
| FRB init smoke test | Existing `RustLib.init()` / `ping()` block | `info`/`error` | Log failure before showing `_FrbInitErrorApp`. |
| DB init/version | `dbInitializedProvider` / DB init listener | `info`/`error` | Store DB version and sanitized path basename only, not full private path by default. |
| Flutter framework error | `FlutterError.onError` | `error` | Call `FlutterError.presentError(details)` first or after logging to keep console visibility. |
| Root-isolate uncaught error | `PlatformDispatcher.instance.onError` | `error` | Return `true` after recording. |
| Uncaught async error | `runZonedGuarded` | `error` | Capture errors outside Flutter callbacks. |
| Existing diagnostics | wrapped `debugPrint` | same/default `debug` | Preserve original console output. |
| Navigation | `GoRouter` observer or route wrapper | `info` | Record route path and query keys, not sensitive values. |
| Source operations | source page/service catch blocks | `info`/`warn`/`error` | Counts and source IDs/names are okay; no raw source JSON unless redacted. |
| Reader operations | reader load/cache/retry catch blocks | `debug`/`warn` | IDs, chapter index, timings; never chapter content. |
| Backup/WebDAV | backup page/API client catch blocks | `info`/`error` | Never password/token; file names okay, full path optional/redacted. |

Breadcrumb scope for MVP:

* Navigation route changes: target route and sanitized query keys.
* Source management: add/edit/delete/batch delete/import/export/live validate/batch check, with counts and source IDs/names where safe.
* Search: query length, enabled source count, result counts, timeout/error summaries; do not log raw query if it may contain private text unless explicitly considered safe later.
* Reader: open book, chapter index load, chapter cache hit/miss, change source start/result, retry, save progress failure, share failure; never log content text.
* Backup/restore: local export/import start/result, recognized item counts, WebDAV upload/list/download/restore result; never log credentials.
* Downloads: task create/start/pause/resume/cancel/complete/error and chapter counts.
* Settings: diagnostics logging enabled/disabled, clear/export logs, and major persisted setting changes only when useful for debugging.

Do not log in MVP:

* Every tap, scroll, text-field edit, slider movement, or list refresh.
* Reader page-turn per gesture unless it is tied to an error or performance investigation.
* Per-frame/per-animation timing.
* Full search keyword, chapter title/body, source JSON, raw URLs with query tokens, or file contents.

### Rust / FRB Capture

* MVP logs FRB failures from Flutter wrappers and catch blocks, because generated FRB files must not be edited.
* Rust `tracing` events remain available in console/debug output, and wrapped `debugPrint` may capture messages piped through Flutter logs where applicable.
* Deeper Rust file-subscriber support is deferred unless we decide Rust internals must be first-class in local exports.

Rust phase boundary:

* Phase 1 keeps Rust unchanged.
* Phase 2 may add a non-generated FRB API such as `init_diagnostics(log_dir: String, level: String) -> Result<(), String>` if exported logs need Rust internals.
* Rust library crates must continue to emit `tracing` only; subscriber setup belongs in bridge/mobile init or binaries.
* Use `try_init()` or guarded subscriber installation, not `init()`, to avoid panic if another subscriber exists.

### UI

* Add `/diagnostics` route.
* Add Settings `工具` entry: `诊断日志`.
* Diagnostics page shows latest log lines with reverse chronological loading or a capped recent window.
* Actions: refresh, share/export, clear.
* Export bundles current/rotated logs into a shareable text or zip artifact using existing dependencies where possible.

UI details:

* Settings entry: `诊断日志`, subtitle `查看、导出或清空本地诊断记录`.
* Page title: `诊断日志`.
* Top switch: `启用诊断日志`, default on.
* Optional level selector: `日志等级`, default `Debug`.
* Header card shows log directory, retained file count, total size, and newest timestamp.
* Recent view loads a capped tail window, for example latest 500 lines across rotated files.
* Each row shows time, level, category, and message; tap expands metadata/error/stack.
* No search/filter/copy controls in MVP; prioritize reliable recording, recent viewing, export, and clear.
* Actions:
  * `刷新`: reload recent lines and stats.
  * `导出`: create one timestamped merged JSONL file and open system share sheet.
  * `清空`: confirm in dialog, delete log files, then show SnackBar.
* If log read fails, show visible error and attempt to log the read failure only to console to avoid recursion.
* When logging is disabled, the page still allows viewing/exporting/clearing existing logs, but new events are not written except a one-time `diagnostics.disabled` event before the switch is persisted.

Export behavior:

* Default format: `.jsonl` single file.
* File name: `legado_diagnostics_<yyyyMMdd-HHmmss>.jsonl`.
* Export content: merge active and rotated logs into chronological order, oldest first.
* Export destination: temporary/cache file created by the app, shared through the system share sheet.
* No ZIP in MVP; no human-formatted `.txt` in MVP.
* Each exported line remains the original event JSON after redaction; do not rehydrate forbidden payloads during export.

### Minimal Environment Event

Write one `app.environment` event per app start after logger init and after DB version is available when possible. If DB version is not available yet, write it later as a separate `db.version` event.

Allowed fields:

* App version and build number if available.
* Build mode: debug/profile/release if available.
* Platform: Android/iOS/Linux/macOS/Windows/web.
* OS version string if available through Flutter platform APIs without extra device-identity plugins.
* Flutter/Dart version only if readily available without fragile shell/runtime hacks.
* Database schema version from `rust_api.getDbVersion`.
* Diagnostic config: enabled, max file count, max bytes per file.
* Diagnostic level: configured minimum level, default `debug`.
* Retention config: max total files and max age days.

Do not collect in MVP:

* Device model, serial number, Android ID, advertising ID, vendor ID, install ID, or any stable device identifier.
* Precise locale, timezone, IP address, network SSID, carrier, GPS/location.
* Contact/account/user profile information.
* Full app documents path unless user explicitly exports logs and the path is already visible in UI.

### Privacy

* Redact credential-like keys and headers by key name.
* Prefer metadata such as IDs, counts, durations, source names, route names, and error classes.
* Do not log chapter body text or raw HTML/JS content.
* Use explicit helper APIs like `logInfo`, `logWarn`, `logError`, and `breadcrumb` so call sites must choose safe metadata.

Redaction rules:

* Redact sensitive values by replacing the value with `[REDACTED]` while preserving the field name and event shape.
* Redact values whose key contains `password`, `passwd`, `token`, `secret`, `authorization`, `cookie`, `set-cookie`, `key`, `credential`, `refresh_token`, or `access_token`.
* Redact URLs by default to origin + path only when query parameters may contain tokens.
* Redact full local paths by default to file basename unless a path is explicitly needed for a user-facing export/import result.
* Limit string metadata length, for example 512 characters per value.
* Persist stack traces only for `warn` and `error` events by default.
* Limit stack trace length to 8 KB per event; mark truncated stacks with a suffix such as `...[truncated]`.
* Drop or replace oversized events instead of blocking UI.

Redaction behavior:

* Map values under sensitive keys become `[REDACTED]`.
* List items are recursively redacted.
* Plain message strings are not aggressively rewritten by default, except for obvious token/header patterns; call sites should avoid putting sensitive values into free-form messages.
* URL query values are replaced with `[REDACTED]`; URL scheme/host/path may remain.
* If a full field is unsafe by category, replace the value rather than dropping the key so analysts can see that data existed but was intentionally hidden.
* Do not use hashes/fingerprints for MVP; equality tracking for secrets is not needed enough to justify privacy risk.

Stack trace policy:

* `error`: include stack when available, max 8 KB.
* `warn`: include stack when available and useful, max 8 KB.
* `info` and `debug`: omit stack by default, even if a caller provides one, unless a future task adds an explicit diagnostic override.
* For `FlutterError.onError`, store `details.exceptionAsString()` and `details.stack` if present.
* For `PlatformDispatcher.instance.onError` and `runZonedGuarded`, store the supplied error and stack.
* Redaction runs before truncation so sensitive data is removed even in long traces/messages.

Forbidden payloads:

* WebDAV passwords, backup passwords, auth tokens, cookies, authorization headers.
* Raw HTTP request/response bodies.
* Raw book/chapter/novel content.
* Raw HTML pages fetched from book sources.
* Full source JS/rule payloads.
* `legado_local.json` contents.

## Runtime Design

### DiagnosticLogger API

Proposed Dart API shape:

```dart
abstract final class DiagnosticLog {
  static Future<void> init({String? directory});
  static void debug(String category, String message, {Map<String, Object?>? metadata});
  static void info(String category, String message, {Map<String, Object?>? metadata});
  static void warn(String category, String message, {Object? error, StackTrace? stack, Map<String, Object?>? metadata});
  static void error(String category, String message, {Object? error, StackTrace? stack, Map<String, Object?>? metadata});
  static void breadcrumb(String category, String message, {Map<String, Object?>? metadata});
}
```

Support services:

* `DiagnosticLogWriter`: async queued JSONL writer with rotation.
* `DiagnosticLogReader`: reads stats, tails recent lines, exports combined file, deletes logs.
* `DiagnosticRedactor`: sanitizes messages and metadata.
* `DiagnosticDebugPrint`: installs/removes `debugPrint` wrapper in tests.

### Queue and Failure Behavior

* Logging must never throw into app flows.
* Appends enqueue events and drain asynchronously in order.
* If the queue grows beyond a cap, drop oldest `debug` events first and write one `warn` event about dropped logs.
* If disk write fails, disable file writes for the session and forward a short warning to original `debugPrint` only.
* Avoid logging inside logger internals except guarded one-shot console warnings, to prevent recursion.

### Rotation Algorithm

* Before append, check active file size.
* If active file exceeds `maxBytes`, rotate:
  * Delete oldest file beyond `maxFiles - 1`.
  * Rename `app.3.log.jsonl` to `app.4.log.jsonl`, etc.
  * Rename `app.log.jsonl` to `app.1.log.jsonl`.
  * Create a new `app.log.jsonl`.
* After rotation, delete log files older than 14 days based on file modification time and/or newest event timestamp.
* Use best-effort file operations; failure should not crash app startup.

### Retention Contract

Default retention is intentionally conservative because logging is enabled by default:

* `maxFiles = 5`.
* `maxBytesPerFile = 1 * 1024 * 1024`.
* `maxAgeDays = 14`.
* Effective cap is both size and age: a file can be removed because it exceeds the file-count limit or because it is older than 14 days.
* Export only includes files that are still inside retention.
* Clearing logs deletes all diagnostic files regardless of age.

## Phased Implementation Plan

Implementation should be split into separate follow-up tasks, not shipped as one large change.

### Implementation Task 1: Flutter Logger Foundation

* Add `lib/core/diagnostics/` with event model, redactor, writer, reader, and logger facade.
* Initialize logger in `main()` before FRB init.
* Install `debugPrint` wrapper and global error handlers.
* Record startup/global error/FRB smoke failure events; broader feature breadcrumbs are deferred to Implementation Task 3.
* Add unit tests for JSONL write, redaction, rotation, failed write behavior, and debugPrint forwarding.

### Implementation Task 2: Diagnostics UI

* Add `/diagnostics` route.
* Add Settings `诊断日志` tool entry.
* Add Diagnostics page with stats, recent log view, refresh, export/share, and clear.
* Add widget tests for Settings entry, route, view state, clear confirmation, and export error handling with fake service/provider.

### Implementation Task 3: Targeted Breadcrumbs

* Add safe breadcrumbs to startup, DB init, source import/delete/check, reader chapter load/retry/cache failures, backup import/export/WebDAV flows, and download task transitions.
* Prefer service wrappers or existing catch blocks; avoid noisy per-frame/per-character logs.
* Add targeted tests where breadcrumbs are part of a service/page contract.

### Optional Later Task: Rust Diagnostics Bridge

* Add bridge API to initialize Rust diagnostic logging only if Flutter-first logs are insufficient.
* Configure `tracing_subscriber` with file writer guarded by `try_init()`.
* Keep Rust library crates subscriber-free.
* Add Cargo build verification and bridge guard checks if FRB public API changes.

## Test Strategy

* Unit tests:
  * Redacts sensitive key names and known header names.
  * Bounds long metadata and stack traces.
  * Writes valid JSONL lines.
  * Rotates files when size threshold is crossed.
  * Clears log files.
  * Reads recent tail across rotated files.
  * Keeps original `debugPrint` behavior when wrapped.
* Widget tests:
  * Settings page renders `诊断日志` under tools.
  * Diagnostics page renders empty, populated, error, and clearing states.
  * Export button calls injected diagnostics service and handles failure visibly.
* Integration/manual checks:
  * Startup creates logs on Android debug build.
  * Simulated thrown error appears in exported logs and console.
  * Log export can be shared from device.

Acceptance verification for each implementation task:

* Automated tests are required for each phase before it is considered complete.
* Final manual verification should be done on an Android debug build:
  * Launch app and confirm a local log file is created.
  * Confirm startup/environment/DB events are present.
  * Trigger a controlled error or failed operation and confirm it appears in logs with stack policy applied.
  * Open Diagnostics page, view recent lines, export JSONL through share sheet, and clear logs.
  * Confirm exported JSONL contains no obvious secrets and remains valid one-JSON-object-per-line.

## Risks and Mitigations

* Risk: logging too much can hurt reader performance. Mitigation: async queue, cap debug volume, avoid per-frame logs.
* Risk: sensitive data leaks into export. Mitigation: central redactor, forbidden payload policy, metadata allowlist at high-risk call sites.
* Risk: logger failures cause app failures. Mitigation: logging APIs swallow internal failures and disable file writes on repeated IO errors.
* Risk: debugPrint wrapper changes development output. Mitigation: always forward to original callback and test wrapper behavior.
* Risk: Rust subscriber conflicts. Mitigation: defer Rust sink and use `try_init()` if added later.

## Feasible Approaches

### Approach A: Flutter-First JSONL Logger (Recommended)

* Build a Dart `DiagnosticLogger` in `lib/core/diagnostics/`.
* Capture global Flutter errors, `debugPrint`, breadcrumbs, and FRB wrapper failures.
* Add Settings page for view/export/clear.
* Pros: small, testable, no generated FRB edits, no Rust dependency churn, directly supports user export.
* Cons: Rust internal `tracing` events are only indirectly captured unless exposed through Flutter paths.

### Approach B: Rust `tracing` File Sink Plus Flutter Logger

* Add Rust mobile subscriber writing to a shared log file, likely via a new FRB init API that receives a log directory.
* Keep Flutter logger for UI errors and breadcrumbs.
* Pros: better visibility into DB/migration/parser/network internals.
* Cons: more cross-language complexity, possible subscriber initialization conflicts, likely dependency/build changes.

### Approach C: Database-Backed Diagnostic Events

* Store logs in SQLite tables beside app data.
* Pros: easy querying/filtering by category/time.
* Cons: risky when DB init/migration is the failure; logs can be unavailable exactly when storage is broken.

## Recommendation

Start with Approach A. It solves the immediate debugging need, captures most app-visible failures, and avoids modifying generated FRB bindings. Add Rust file-subscriber support later only if exported logs lack enough core-level detail.

## Decision (ADR-lite)

**Context**: The logging system spans app startup, Flutter error capture, local persistence, Settings UX, FRB error handling, privacy rules, and possibly Rust `tracing`. Implementing immediately would require several scope decisions.

**Decision**: Start with Implementation Task 1 only: Flutter logger foundation and global capture. Do not implement the Diagnostics UI, targeted feature breadcrumbs, or Rust tracing file sink in this task.

**Consequences**: The first implementation stays small and testable while preserving the full design for follow-up tasks.

## Decision: Default Logging State

**Context**: Local diagnostics are most valuable when an intermittent issue has already happened; requiring users to manually enable logging after the fact loses the lead-up context.

**Decision**: Enable local diagnostic logging by default, with strict size caps, local-only storage, visible Settings controls, export-on-demand, and clear/disable options.

**Consequences**: The app captures useful pre-failure context by default. This increases responsibility to keep retention bounded and redaction conservative.

## Decision: Export Format

**Context**: Diagnostic exports should be easy to send from a phone and easy to parse by tools. The project already stores structured events as JSONL and does not need compression for the proposed 5 MB retention cap.

**Decision**: Export one merged `.jsonl` file named `legado_diagnostics_<yyyyMMdd-HHmmss>.jsonl`, ordered oldest to newest.

**Consequences**: Implementation stays simple and dependency-light. Human readability is acceptable but secondary; a formatted text export or ZIP bundle can be added later if needed.

## Decision: Environment Metadata

**Context**: Version/platform/DB context is necessary to interpret logs, but detailed device metadata increases privacy exposure and log noise.

**Decision**: Record only minimal environment information: app version/build, build mode, platform, OS version if readily available, DB schema version, and diagnostic config.

**Consequences**: Logs remain useful for version/platform/schema debugging while avoiding stable device identifiers and detailed device profiling.

## Decision: Retention Defaults

**Context**: Logs are enabled by default, so retention must be useful for intermittent bug reports but small enough to avoid surprising storage use.

**Decision**: Use both size and age limits: 5 files, 1 MB each, and 14 days maximum age.

**Consequences**: Default storage use stays around 5 MB and old diagnostics expire automatically. Long-running rare issues may require users to export logs before they age out.

## Decision: Diagnostics Page MVP

**Context**: The first version should make logs available for support without overbuilding UI analysis tools.

**Decision**: The Diagnostics page shows a capped recent-log view, default 500 latest lines, with row expansion plus refresh/export/clear actions. Search, filtering, and per-line copy are deferred.

**Consequences**: Implementation and tests stay focused on reliable capture/export. Deeper in-app analysis can be added later if exported JSONL is not enough.

## Decision: Breadcrumb Scope

**Context**: Breadcrumbs are needed to reconstruct what led to a failure, but overly detailed UI logging creates noise and privacy risk.

**Decision**: Record only key actions in MVP: route changes, source management, search summaries, reader load/change-source/cache/retry events, backup/WebDAV operations, download task transitions, and major diagnostics/settings changes.

**Consequences**: Logs should explain most failures without becoming a clickstream. Fine-grained taps, scrolls, text edits, page turns, and per-frame timings are out of scope unless a future performance task needs them.

## Decision: Stack Trace Retention

**Context**: Stack traces are essential for debugging crashes and failed operations, but storing them for every event would waste space and increase privacy exposure.

**Decision**: Persist stack traces for `warn` and `error` events only, capped at 8 KB per event after redaction.

**Consequences**: Serious failures remain diagnosable while `debug`/`info` logs stay compact. Very deep stacks may be truncated but should still include the most relevant top frames.

## Decision: Default Log Level

**Context**: `debug` logs are valuable for reader timing, cache behavior, source parsing, and intermittent failures, but verbose logging can rotate the 5 MB retention window faster.

**Decision**: Default the diagnostic log level to `debug`, recording `debug`, `info`, `warn`, and `error` events. Keep high-frequency events out of MVP and allow a future Settings level selector to lower verbosity.

**Consequences**: Logs capture richer context by default. The implementation must avoid per-frame/per-scroll/per-character debug events and rely on the 5 MB / 14 day retention cap to bound disk use.

## Decision: Redaction Strategy

**Context**: Diagnostics should preserve enough structure for debugging while ensuring secrets never appear in exports.

**Decision**: Preserve sensitive field names but replace sensitive values with `[REDACTED]`. Do not hash sensitive values in MVP.

**Consequences**: Exported logs show which field was present without exposing the value. Analysts cannot correlate whether two hidden secrets are equal, which is acceptable for MVP privacy.

## Decision: Backup Relationship

**Context**: The app already has backup/restore for user data. Diagnostic logs are operational troubleshooting data with separate privacy and retention expectations.

**Decision**: Do not include diagnostic logs in normal backup zip files. Logs are exported only through the Diagnostics page.

**Consequences**: Backups stay focused on user data and do not accidentally carry troubleshooting traces. Users must explicitly export diagnostics when reporting issues.

## Decision: Implementation Split

**Context**: The logging system touches startup, persistence, settings UI, export/share, many feature flows, and optional Rust internals. A single implementation task would be broad and harder to verify.

**Decision**: Implement in three follow-up tasks: logger foundation, diagnostics UI, then targeted breadcrumbs. Keep Rust diagnostics bridge as an optional later task.

**Consequences**: Each implementation task has a smaller diff and clearer tests. Users may get core capture before all breadcrumbs are added.

## Decision: Verification Strategy

**Context**: Local logging has file IO, global error hooks, Settings UI, and platform share behavior. Unit tests catch most logic errors, but export/share and Android storage behavior need device verification.

**Decision**: Require automated tests for each implementation phase and final Android debug manual verification for startup logging, simulated error capture, Diagnostics page behavior, JSONL export, and clear logs.

**Consequences**: Implementation takes longer than manual-only validation but reduces risk of shipping a logger that fails silently or cannot export useful files.

## Acceptance Criteria (Evolving)

* [ ] Logger writes JSONL events under `<resolvePersistenceDir()>/logs/` with active and rotated files.
* [ ] Default settings are enabled logging, `debug` level, 5 files, 1 MB each, 14 day retention.
* [ ] Redaction replaces sensitive values with `[REDACTED]` while preserving event shape.
* [ ] Stack traces are persisted only for `warn`/`error`, capped at 8 KB after redaction.
* [ ] `debugPrint` output is forwarded to the original callback and captured locally.
* [ ] `FlutterError.onError`, `PlatformDispatcher.instance.onError`, and `runZonedGuarded` paths write error events without breaking normal error presentation.
* [ ] App startup initializes diagnostics before FRB init and records startup/global failure events.
* [ ] Unit tests cover write, rotation, retention cleanup, redaction, stack truncation, debugPrint forwarding, and log read/export helpers where implemented.
* [ ] Diagnostics UI, explicit Settings entry, export/share UI, targeted business breadcrumbs, and Rust tracing file sink are not implemented in this first task.

## Definition of Done

* Implementation Task 1 code is complete and tested.
* Targeted Flutter tests for diagnostics pass.
* `flutter analyze` passes or any pre-existing unrelated analyzer issues are clearly reported.
* No generated FRB files are edited.
* Follow-up tasks remain documented for Diagnostics UI, targeted breadcrumbs, and optional Rust bridge.

## Out of Scope (Initial)

* Uploading logs to a server.
* Third-party crash analytics SDKs.
* Including diagnostic logs in normal app/book backup archives.
* Recording raw HTTP bodies, cookies, auth headers, source JS, or chapter content.
* Editing generated FRB Dart files.
* Full Rust `tracing` file subscriber, unless explicitly included in MVP.
* Diagnostics Settings page, recent-log UI, share/export UI, and clear UI in Implementation Task 1.
* Targeted feature breadcrumbs beyond startup/global capture in Implementation Task 1.
* Advanced log search/filter UI beyond a recent-log view.
* Per-line copy controls in the Diagnostics page MVP.
* Full clickstream analytics or fine-grained UI interaction tracking.

## Technical Notes

* Flutter routes are centralized in `flutter_app/lib/core/router.dart`.
* Settings tool entries live in `flutter_app/lib/features/settings/settings_page.dart`.
* Existing persistence directory helper is `flutter_app/lib/core/persistence/json_store.dart::resolvePersistenceDir`.
* Existing service-provider pattern is documented in `.trellis/spec/flutter-app/state-and-providers.md`.
* Rust logging rules and sensitive-value bans are documented in `.trellis/spec/rust-core/logging.md`.
* FRB generated-file constraints are documented in `.trellis/spec/cross-language/frb-bridge.md`.

## Open Questions

* None for Implementation Task 1. Later phases may discover code-level details during execution.

## Final Design Summary

* Default-on local diagnostic logging.
* Default level `debug`, with strict avoidance of high-frequency clickstream/per-frame events.
* JSONL event format, one event per line.
* Storage under `<resolvePersistenceDir()>/logs/`.
* Retention: 5 files, 1 MB each, 14 days max age.
* Export: one merged chronological `legado_diagnostics_<yyyyMMdd-HHmmss>.jsonl` file.
* UI: Settings `诊断日志` page with enable switch, recent 500-line view, expand details, refresh, export, clear.
* Privacy: sensitive values replaced with `[REDACTED]`; no secret hashing in MVP.
* Environment: minimal app/platform/DB/log-config event, no stable device/user identifiers.
* Breadcrumbs: key actions only, not full clickstream.
* Stack traces: `warn`/`error` only, 8 KB cap after redaction.
* Backups: diagnostics excluded from normal backup zip.
* Implementation split: logger foundation, diagnostics UI, targeted breadcrumbs; Rust bridge optional later.
