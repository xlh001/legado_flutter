# Persistence

All app-side persistence (settings, WebDAV config, search history, pending route, ...) goes through one helper module: `flutter_app/lib/core/persistence/json_store.dart`.

> **敏感字段（密码 / token / 凭据）走 `core/security/secure_storage.dart`，不走 json_store。** 详见 [quality-and-anti-patterns.md::凭据保险柜 (BATCH-03)](./quality-and-anti-patterns.md#凭据保险柜-credential-vault-batch-03)。两条 IO 路径并行：非敏感字段（URL / user / deviceName / preferences / cache keys）走 json_store；敏感字段（password / token / refresh_token）走 secure_storage（Android Keystore-backed `EncryptedSharedPreferences` / iOS Keychain）。webdav password 是 canonical 例子。

## Two Public APIs

`json_store.dart` exposes two parallel sets of functions for two persistence shapes:

### Key-based on shared `settings.json`

Used for ~17 small settings (font size, theme mode, sort order, ...). Single shared object on disk.

```dart
Future<T> readJsonKey<T>(String key, T Function(dynamic) parse, T defaultValue, {Directory? directory});
Future<void> writeJsonKey(String key, Object? value, {String? errorTag, Directory? directory});
Future<void> deleteJsonKey(String key, {Directory? directory});
```

Storage: `<documentsDir>/settings.json` containing one JSON object with all keys.

### File-based (one file per object)

Used for larger or independent payloads (`webdav.json` is the canonical example; arbitrary feature-owned JSON files).

```dart
Future<T> readJsonFile<T>(String fileName, T Function(dynamic) parse, T defaultValue, {Directory? directory});
Future<void> writeJsonFile(String fileName, Object? value, {String? errorTag, Directory? directory});
Future<void> deleteJsonFile(String fileName, {Directory? directory});
```

Storage: `<documentsDir>/<fileName>`. The fileName must be a relative path with `.json` suffix and no directory components.

## Concurrency Model

- **Reads are lock-free.** `readJsonKey` / `readJsonFile` call `File.readAsString` directly. Dart's `writeAsString` is atomic at the FS level, so a concurrent reader either sees the previous version or the next, never a torn read.
- **Writes are serialized through a module-level `_Mutex`.** This closes the read-modify-write race for the key-based API: without it, two writers could both load the same old `settings.json`, modify their own keys, and overwrite each other's keys. The mutex makes every `writeJsonKey` see the previous writer's result.

When introducing new persistence call sites, **always** go through these helpers. Do **not** call `path_provider` or `File.readAsString` directly. The audit `findings-flutter-features.md::F-W2B-022` (resolved by BATCH-18e) collapsed 6 ad-hoc sites onto `resolvePersistenceDir()` for exactly this reason.

**Exception: Diagnostic log files** — operational troubleshooting data stored under `<resolvePersistenceDir()>/logs/` as append-only JSONL (active file `app.log.jsonl`, rotated `app.N.log.jsonl`). These are NOT feature settings and do NOT go through `json_store.dart`:
- They use direct `dart:io` file writes (append mode, async queued, rotation before write).
- They share `resolvePersistenceDir()` for path consistency but bypass the `_Mutex` because they are a single-writer append-only stream, not read-modify-write JSON.
- Tests bypass `path_provider` by passing a `tempDir` directly to the writer/logger `init()`.
- Diagnostic log files are excluded from normal backup zip files.

## Test Hooks

Helpers accept an optional `Directory? directory:` parameter. Tests pass a `tempDir` directly to bypass `path_provider` entirely:

```dart
testWidgets('persists font size on save', (tester) async {
  final tmp = await Directory.systemTemp.createTemp();
  await writeJsonKey('fontSize', 22.0, directory: tmp);
  final v = await readJsonKey<double>('fontSize', (r) => r as double, 18.0, directory: tmp);
  expect(v, 22.0);
});
```

Three resolution paths exist; helpers pick in this order:

1. Caller-passed `directory:` parameter (preferred for unit tests).
2. `PathProviderPlatform.instance` mock (some tests still use this).
3. Real `getApplicationDocumentsDirectory()` (production path).

The doc-comment in `json_store.dart` enumerates the same three paths; keep the comment in sync if the resolution changes.

## Common Mistakes

- **Don't introduce a new top-level JSON file for one key.** Use the key-based API on `settings.json`. New per-feature files are reserved for compound objects (>3 keys, version-tagged, distinct lifecycle from settings).
- **Don't bypass the `_Mutex` by writing to the file directly.** This re-introduces the race the helper was built to fix.
- **Don't forget `clamp()` on numeric reads.** A corrupt user file may have any value; bound it to the UI-acceptable range inside the parser closure.
- **Don't rethrow on read failure.** Reads should fall back to the supplied default. Writes may throw or silently log via `errorTag`; choose based on whether the user can retry.

## Migration Path

If a key outgrows `settings.json` (becomes >3 keys, gets a version field, or has its own lifecycle), promote it:

1. Pick a filename like `webdav.json`, `read_stats_cache.json`.
2. Use `readJsonFile` / `writeJsonFile` for it.
3. On first read after the migration, also `deleteJsonKey` the old key from `settings.json` to prevent drift.

The `webdav.json` migration in BATCH-18g is the canonical example.
