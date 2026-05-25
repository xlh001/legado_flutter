# Diagnostics Breadcrumbs

## Goal

Add targeted business breadcrumbs to key app flows so diagnostic logs can reconstruct what led to a failure, without logging every tap/scroll.

This is Implementation Task 3 of the logging system, building on Task 1's `DiagnosticLog` and Task 2's viewer page.

## What I Already Know

- Task 1 delivered: `DiagnosticLog.info/warn/error/breadcrumb()` static API.
- Task 2 delivered: `/diagnostics` page to view exported logs.
- Breadcrumbs already recorded: startup environment, FRB smoke, DB init/version, global errors.
- `main.dart` already uses `DiagnosticLog.info('db.init', ...)` pattern.

## Requirements

Add safe breadcrumbs to these flows (per phased implementation plan):

**Startup / DB** (already done in Task 1):
- App environment, FRB smoke, DB init/version — already recorded

**Source management**:
- Source add/edit/delete/batch delete result (count + source IDs/names, no raw JSON)
- Source import/export result
- Source live validation / batch check completion

**Reader**:
- Book open
- Chapter load timing/cache hit/miss
- Change source result
- Chapter content retry/failure
- Never log chapter content text

**Backup/WebDAV**:
- Local export/import start/result + item counts
- WebDAV upload/list/download result
- Never log credentials/passwords

**Download tasks**:
- Task create/start/pause/resume/cancel/complete/error

**Navigation**:
- Route change breadcrumbs via GoRouter `NavigatorObserver` in `router.dart`
- Record target route path only (not query values) — automatic, zero page-code changes

## Acceptance Criteria

- [ ] Source CRUD operations log info/warn breadcrumbs with safe metadata
- [ ] Reader open/chapter load/change source log debug/info breadcrumbs
- [ ] Backup/WebDAV operations log info/error breadcrumbs (no credentials)
- [ ] Download task transitions log info/error breadcrumbs
- [ ] Navigation route changes log info breadcrumbs
- [ ] No chapter content, passwords, tokens, or raw JSON in breadcrumbs
- [ ] No per-frame/per-scroll/per-character logging
- [ ] Existing tests still pass; `flutter analyze` clean
- [ ] No generated FRB files edited

## Out of Scope

- Per-tap, per-scroll, per-text-edit logging
- Reader page-turn per gesture (unless tied to error)
- Full search keyword logging (only lengths/counts)
- Rust tracing file sink

## Definition of Done

- Breadcrumbs added to all target flows above.
- `flutter analyze` passes.
- No generated FRB edits.

## Technical Notes

- Logger API: `DiagnosticLog.info('source.import', 'Imported sources', metadata: {'count': n})`
- Service wrappers in `core/services/` and catch blocks in feature pages
- `go_router` observer for navigation breadcrumbs in `router.dart`
- Redaction is already handled by `DiagnosticRedactor` in the event creation pipeline
