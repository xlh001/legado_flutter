# Diagnostics UI

## Goal

Add the Diagnostics Settings entry and page so users can view, export, and clear local diagnostic logs from within the app.

This is Implementation Task 2 of the logging system, building on Task 1's `lib/core/diagnostics/` foundation.

## What I Already Know

- Task 1 delivered: JSONL logger under `<resolvePersistenceDir()>/logs/`, global error capture, debugPrint wrapping, redaction, rotation/retention, reader/export/clear helpers in `DiagnosticLogReader`.
- `DiagnosticLog.reader()` returns a `DiagnosticLogReader` that supports `tail()`, `exportMerged()`, `clear()`, `stats()`.
- Settings page has a `工具` section with `ListTile` entries that navigate to tool pages.
- Routes are centralized in `flutter_app/lib/core/router.dart`.
- Existing Settings tools entries: `备份/恢复`, `阅读统计`, `缓存管理`, `RSS 收藏`, `订阅源`, `替换规则`.

## Requirements

- Add `/diagnostics` route in `router.dart`.
- Add `诊断日志` tool entry in Settings `工具` section: title `诊断日志`, subtitle `查看、导出或清空本地诊断记录`, trailing chevron, `context.push('/diagnostics')`.
- Add Diagnostics page with:
  - Title: `诊断日志`
  - Top `SwitchListTile`: `启用诊断日志`, default on, persisted via `saveDiagnosticLoggingEnabledToDisk` (Task 1). When disabled, new events are not written but existing logs remain viewable/exportable/clearable.
  - Header card showing log stats: file count, total size, newest timestamp
  - Recent log view (latest 500 lines, each row shows time/level/category/message, tap expands metadata/error/stack)
  - Actions: `刷新`, `导出` (share JSONL), `清空` (confirm dialog then delete)
- No search/filter/copy controls in MVP.
- No ZIP export in MVP; single `.jsonl` named `legado_diagnostics_<yyyyMMdd-HHmmss>.jsonl`.
- Share via system share sheet (project already depends on `share_plus`).
- Page must handle empty state (no logs yet) gracefully.

## Acceptance Criteria

- [ ] `/diagnostics` route is registered and navigable.
- [ ] Settings `工具` section shows `诊断日志` ListTile with correct title/subtitle/icon/chevron.
- [ ] Diagnostics page has `启用诊断日志` SwitchListTile that toggles and persists via existing Task 1 wrappers.
- [ ] Diagnostics page shows header card with file count, total size, newest timestamp.
- [ ] Diagnostics page shows recent 500 log lines with tap-to-expand detail.
- [ ] `刷新` button reloads stats and recent lines.
- [ ] `导出` button creates merged JSONL and opens system share sheet.
- [ ] `清空` button shows confirm dialog, deletes logs on confirm, shows SnackBar.
- [ ] Empty state (no logs) shows appropriate message.
- [ ] Widget tests cover Settings entry visibility, page rendering, stats display, empty state, clear confirmation.
- [ ] `flutter analyze` passes; no generated FRB files edited.

## Out of Scope

- Search/filter/copy controls in log view
- ZIP export
- Human-formatted `.txt` export
- Diagnostics logging enable/disable toggle (uses existing settings wrappers from Task 1 if desired in page header)
- Business breadcrumbs (Task 3)
- Rust tracing file sink

## Definition of Done

- Code complete and tested.
- `flutter test` for diagnostics UI tests pass.
- `flutter analyze` passes.
- No generated FRB edits.
- Diagnostics page reachable from Settings and functional.

## Technical Notes

- Route: `flutter_app/lib/core/router.dart`
- Settings entry: `flutter_app/lib/features/settings/settings_page.dart`
- Logger facade: `flutter_app/lib/core/diagnostics/diagnostic_log.dart`
- Reader: `flutter_app/lib/core/diagnostics/diagnostic_log_reader.dart`
- Share: project already uses `share_plus` (see `flutter_app/lib/features/reader/reader_page.dart`)
- Export filename: `legado_diagnostics_<yyyyMMdd-HHmmss>.jsonl`
- Export path: system temp/cache directory
- Follow existing page patterns: `ConsumerStatefulWidget`, `ProviderScope.overrides` for tests
