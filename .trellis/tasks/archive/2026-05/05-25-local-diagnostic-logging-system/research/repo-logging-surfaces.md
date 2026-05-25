# Research: Repo logging surfaces for local diagnostics MVP

- **Query**: Inspect code only. Identify existing Flutter logging sites (`debugPrint`, visible errors, startup failures), Rust logging/tracing setup and gaps for mobile, Settings navigation patterns for adding a Log/Diagnostics page, persistence/export patterns already used in Flutter, and tests that would be natural to add.
- **Scope**: internal
- **Date**: 2026-05-25

## Findings

### Files Found

| File Path | Description |
|---|---|
| `flutter_app/lib/main.dart` | App startup, FRB smoke test logging, visible FRB init failure fallback page, DB init listener logging. |
| `flutter_app/lib/core/providers.dart` | DB path/init providers and many provider-level `debugPrint` timing/error logs; disk settings load/save helpers. |
| `flutter_app/lib/features/reader/reader_page.dart` | Heaviest Flutter `debugPrint` surface: reader load/cache/timing/hardware/share failures. |
| `flutter_app/lib/features/search/search_page.dart` | Search/offline/online source failure logging and visible search errors. |
| `flutter_app/lib/features/source/source_page.dart` | Source import/export/check visible errors via `SnackBar`/dialogs; file import via `FilePicker` + `File.readAsString`. |
| `flutter_app/lib/features/settings/settings_page.dart` | Settings page `ListView` sections and `ListTile`/`context.push` pattern for tool pages. |
| `flutter_app/lib/features/settings/backup_page.dart` | Existing local export/import UX, file picker service injection, visible error SnackBars, provider invalidation after import. |
| `flutter_app/lib/core/persistence/json_store.dart` | App document/support directory resolution and JSON file/key persistence helpers. |
| `flutter_app/lib/core/services/file_picker_service.dart` | `file_picker` abstraction used for backup tests and production file/directory picking. |
| `flutter_app/lib/core/services/backup_api_client.dart` | FRB backup/export client abstraction injected via Riverpod for tests. |
| `flutter_app/lib/core/notification_service.dart` | Notification failures are caught and logged with `debugPrint`. |
| `core/core-storage/src/database.rs` | Rust database init/migration tracing via `tracing::{debug, info, warn}`. |
| `core/api-server/src/main.rs` | Only explicit Rust `tracing_subscriber` initialization found; server logs to fmt subscriber with env filter. |
| `core/bridge/src/api.rs` | Flutter Rust bridge API returns `Result<_, String>` for most errors; some warning logs via `tracing::warn!`. |
| `core/bridge/src/frb_generated.rs` | Generated FRB dispatcher logs unknown func IDs with both `tracing::error!` and `eprintln!`. |
| `core/Cargo.toml` and crate `Cargo.toml` files | Workspace tracing dependencies; most core crates depend on `tracing`, api-server/core-net also on `tracing-subscriber`. |
| `flutter_app/test/settings_page_test.dart` | Natural pattern for asserting Settings tool entries render. |
| `flutter_app/test/backup_page_test.dart` | Natural pattern for testing export/import UI with provider-injected fake services. |
| `flutter_app/test/json_store_test.dart` | Natural pattern for testing persistence helpers with temp directories. |
| `flutter_app/test/safe_setstate_test.dart` | Natural pattern for mounted/unmounted async UI state helpers used by pages. |

### Code Patterns

#### Existing Flutter logging sites

- Startup FRB smoke test logs success/warning/failure with `debugPrint`; failure path renders a visible fallback app instead of proceeding: `flutter_app/lib/main.dart:24-37` and `flutter_app/lib/main.dart:161-212`.
  ```dart
  debugPrint('[FRB smoke] ping() returned: $pong');
  debugPrint('[FRB smoke] init/ping FAILED: $e');
  runApp(_FrbInitErrorApp(error: e, stack: st));
  ```
- Main app listens to `dbInitializedProvider` and logs DB init success/error: `flutter_app/lib/main.dart:110-123`.
- DB init provider logs FRB init result, DB version, and init failures before rethrowing: `flutter_app/lib/core/providers.dart:41-52`.
- Reader page has many categorized `debugPrint` tags, including settings load, wakelock/brightness, read-time, chapter load timing, cache, replace rules, pre-cache, bookmark, retry, position save, and share failures; examples include `flutter_app/lib/features/reader/reader_page.dart:243`, `:342`, `:460-480`, `:637`, `:2817`.
- Provider-level reader chapter loading emits timing logs before/after DB readiness, DB path resolution, Rust return, and final decode: `flutter_app/lib/core/providers.dart:203-221`.
- Search page logs local/online/source-specific failures and timeouts: `flutter_app/lib/features/search/search_page.dart:356`, `:381`, `:398`, `:497`.
- Notification service catches platform/plugin failures and logs them with `[Notification]` tags: `flutter_app/lib/core/notification_service.dart:30-52`, `:61-91`.
- Other visible `debugPrint` surfaces found by search include bookshelf import/add URL failures (`flutter_app/lib/features/bookshelf/bookshelf_page.dart:726`, `:873`), bookshelf manage bulk operation failures (`flutter_app/lib/features/bookshelf/bookshelf_manage_page.dart:509`, `:549`, `:595`, `:633`), RSS WebView init failures (`flutter_app/lib/features/rss/rss_article_detail_page.dart:313`), and WebView safety decode failures (`flutter_app/lib/core/security/webview_safety.dart:229`).

#### Existing visible errors and user-facing failure surfaces

- FRB startup failure page shows copyable `Error:` and `Stack:` with common causes: `flutter_app/lib/main.dart:161-212`.
- Source page uses `AsyncValue.error` visible text for initial load failure: `flutter_app/lib/features/source/source_page.dart:88`.
- Source actions catch errors and show `SnackBar` messages such as `操作失败`, `添加失败`, `导入失败`, `校验失败`, `数据库未就绪`, `删除失败`, `导出失败`, `文件导入失败`, and `批量删除失败`: e.g. `flutter_app/lib/features/source/source_page.dart:634-640`, `:734-740`, `:860-880`, `:908-931`, `:972-976`, `:1050-1053`.
- Source check UI displays stage-level `error` text from Rust validation results and uses error icons/colors: `flutter_app/lib/features/source/source_check_progress_page.dart:123`, `:156`, `:248-251`, `:298`.
- Backup page shows user-facing errors for export, zip parsing, import, WebDAV upload/restore/list flows: `flutter_app/lib/features/settings/backup_page.dart:230-234`, `:263-267`, `:328-332`, `:472-476`.

#### Existing Rust logging/tracing setup and mobile gaps

- Workspace tracing dependencies are declared in `core/Cargo.toml:24-25`; crate-level dependencies include `tracing` in `core-storage`, `core-source`, `core-parser`, `core-net`, `bridge`, and `api-server`, with `tracing-subscriber` in `api-server` and `core-net` Cargo manifests.
- The only explicit subscriber initialization found in code search is the API server: `core/api-server/src/main.rs:94-99`.
  ```rust
  tracing_subscriber::fmt()
      .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
      .init();
  ```
- API server logs startup/security info with `tracing::warn!`/`tracing::info!` and sends the full ephemeral token to stderr via `eprintln!`: `core/api-server/src/main.rs:115-128`, `:132-137`, `:164-169`.
- Database init/migration emits `info!`, `warn!`, and `debug!` events for init path, WAL mode, version, table creation, and migrations: `core/core-storage/src/database.rs:7`, `:15`, `:49-52`, `:82`, `:91-97`, `:509-565`.
- Bridge API mostly converts Rust errors into `Result<_, String>` for Dart callers rather than logging; examples include `init_legado` mapping init errors to `初始化失败: ...`: `core/bridge/src/api.rs:16-21`, and many public functions returning `Result<String, String>`/`Result<(), String>` starting at `core/bridge/src/api.rs:42`.
- Bridge has a few direct `tracing::warn!` calls, including regex compile failures and cache/task paths: `core/bridge/src/api.rs:1520`, `:1897`, `:1902`, `:1926`.
- Generated FRB dispatcher logs unknown function IDs to both tracing and stderr: `core/bridge/src/frb_generated.rs:4647-4648`, `:4674-4675`.
- No mobile/Flutter-side Rust tracing subscriber initialization was found in `core/bridge/src/api.rs`, `core/bridge/src/lib.rs`, or `flutter_app/lib/main.dart`; mobile startup calls `RustLib.init()` then `rust_api.ping()` from Dart (`flutter_app/lib/main.dart:24-27`) and DB init through FRB (`flutter_app/lib/core/providers.dart:41-52`).

#### Settings navigation patterns for adding a Log/Diagnostics page

- Routes are centralized in `flutter_app/lib/core/router.dart` using top-level `GoRoute` entries. Settings currently has `/settings`, while tool/detail pages such as `/backup`, `/webdav-config`, `/read-stats`, `/cache-management`, `/rule-subs`, and `/replace-rules` are separate top-level routes: `flutter_app/lib/core/router.dart:103-148`, `:178-182`.
- Settings page is a `ConsumerStatefulWidget` with `Scaffold`, `AppBar(title: Text('设置'))`, and a `ListView` grouped by `_SectionHeader`: `flutter_app/lib/features/settings/settings_page.dart:9-17`, `:95-103`, `:369-388`.
- Tool navigation entries use `ListTile` with `leading` icon, `title`, `subtitle`, trailing `Icons.chevron_right`, and `onTap: () => context.push('/route')`: `flutter_app/lib/features/settings/settings_page.dart:241-287`.
- Existing tool entries in Settings include `备份/恢复`, `阅读统计`, `缓存管理`, `RSS 收藏`, `订阅源`, and `替换规则`: `flutter_app/lib/features/settings/settings_page.dart:246-287`.
- Dialog selection pattern on Settings uses `showDialog<DefaultHomePage>`, `SimpleDialog`, `ListTile`, trailing check, and `Navigator.pop(ctx, value)`: `flutter_app/lib/features/settings/settings_page.dart:327-366`.

#### Persistence/export patterns already used in Flutter

- `json_store.dart` resolves the app persistence directory via `path_provider`; Android uses `getApplicationDocumentsDirectory()`, other platforms use `getApplicationSupportDirectory()`: `flutter_app/lib/core/persistence/json_store.dart:55-69`.
- Keyed settings persistence writes to `settings.json`, swallows read/parse errors by returning defaults, serializes writes via a module mutex, and optionally logs write failures with `debugPrint('Failed to save $errorTag: $e')`: `flutter_app/lib/core/persistence/json_store.dart:75-124`.
- Whole-file JSON persistence supports `readJsonFile`, `writeJsonFile`, and `deleteJsonFile`; `writeJsonFile` rethrows IO failures for callers to surface visible errors: `flutter_app/lib/core/persistence/json_store.dart:166-220`.
- Source export copies JSON to clipboard after `rust_api.exportAllSources`; source import picks `.json`, reads file contents with `File(...).readAsString()` or bytes, imports via Rust, invalidates provider, and shows `SnackBar`: `flutter_app/lib/features/source/source_page.dart:917-979`.
- Backup export picks a directory through `FilePickerService.pickDirectory()`, builds `legado_backup_<yyyyMMdd-HHmm>.zip`, calls `BackupApiClient.exportBackup`, and shows output path: `flutter_app/lib/features/settings/backup_page.dart:196-238`.
- Backup import picks `.zip` via injected file picker, validates via API client, confirms in an `AlertDialog`, imports, invalidates affected providers, and shows a formatted summary: `flutter_app/lib/features/settings/backup_page.dart:240-335`.
- WebDAV config loading for backup reads non-sensitive JSON from `webdav.json` and password from secure storage: `flutter_app/lib/features/settings/backup_page.dart:405-433`.
- File picker abstraction is provider-injected for tests: `flutter_app/lib/core/services/file_picker_service.dart:1-30`; backup FRB/WebDAV calls are provider-injected via `backupApiClientProvider`: `flutter_app/lib/core/services/backup_api_client.dart:7-88`.

#### Tests that would be natural to add

- `flutter_app/test/settings_page_test.dart` already verifies Settings tool `ListTile` entries and chevrons, providing a direct pattern for asserting an added diagnostics/log entry renders in the Settings tools section: `flutter_app/test/settings_page_test.dart:25-64`, `:66-85`.
- `flutter_app/test/backup_page_test.dart` shows how to test page UI with `ProviderScope.overrides` and fake service classes for file picker/API behavior: `flutter_app/test/backup_page_test.dart:23-82`, `:84-193`.
- `flutter_app/test/json_store_test.dart` covers temp-directory persistence, missing/malformed files, write/delete behavior, concurrent writes, swallowed/rethrown error behavior, and whole-file JSON semantics: `flutter_app/test/json_store_test.dart:18-139`, `:144-252`.
- `flutter_app/test/safe_setstate_test.dart` covers `safeSetState` behavior for async UI pages that call `safeSetState` in `finally` blocks after catches: `flutter_app/test/safe_setstate_test.dart:9-41`.
- Existing page-level tests near the likely navigation/persistence surfaces include `flutter_app/test/backup_page_test.dart`, `flutter_app/test/settings_page_test.dart`, `flutter_app/test/json_store_test.dart`, `flutter_app/test/source_page_test.dart`, `flutter_app/test/cache_management_page_test.dart`, and `flutter_app/test/read_stats_page_test.dart`.

### External References

- None. Code-only inspection requested.

### Related Specs

- Not inspected for this code-only task.

## Caveats / Not Found

- No code path was found that globally intercepts Flutter framework errors via `FlutterError.onError`, `PlatformDispatcher.instance.onError`, or `runZonedGuarded`.
- No mobile/FRB-side Rust tracing subscriber initialization was found; tracing is initialized in the standalone API server only.
- No existing local diagnostic log page, log persistence file, or log export abstraction was found by the inspected searches.
