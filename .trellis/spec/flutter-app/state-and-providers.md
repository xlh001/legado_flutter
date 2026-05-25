# State and Providers

Riverpod 2 is the only state-management library used in this app. There are no `ChangeNotifier`s, no `Bloc`s, and no global singletons (besides the FRB binding).

## Provider Shapes Used

| Shape | When | Example |
|---|---|---|
| `Provider<T>` | Pure derived value, no IO. | `lightThemeProvider` in `core/providers.dart` |
| `StateProvider<T>` | Mutable in-memory state, no persistence. | `themeModeProvider` |
| `FutureProvider<T>` | One-shot async load (DB path, initial data). | `dbDirProvider` (calls `resolvePersistenceDir`) |
| `FutureProvider.family<T, P>` | Async by parameter (book id, source id). | `bookByIdProvider`, `bookChaptersProvider` |
| `StreamProvider<T>` | Used sparingly. Only when the underlying source is a real `Stream`. | none in current codebase |
| `NotifierProvider` / `AsyncNotifierProvider` | Not used yet — the codebase predates them. New code may adopt them when state needs methods. | — |

For new state, prefer the simplest shape that fits. Most features today use `ConsumerStatefulWidget` with `setState` for local UI state and `ref.read(...)` to call into providers, rather than building a `Notifier` per page.

## Settings IO Wrappers

`core/providers.dart` contains 17 paired functions of the form:

```dart
Future<double> loadFontSizeFromDisk();
Future<void> saveFontSizeToDisk(double v);
Future<void> clearFontSizeFromDisk();   // some keys only
```

Every wrapper delegates to `core/persistence/json_store.dart`:

```dart
Future<double> loadFontSizeFromDisk() async {
  return readJsonKey<double>(
    'fontSize',
    (raw) => raw is num ? raw.toDouble().clamp(14.0, 28.0) : 18.0,
    18.0,
  );
}

Future<void> saveFontSizeToDisk(double v) async {
  await writeJsonKey('fontSize', v, errorTag: 'font size');
}
```

Rules for adding a new settings key:

1. Add load/save (and optionally clear) wrappers to `providers.dart`.
2. Pass the parser as a closure that **never throws** — fall back to a default on shape mismatch. `json_store` will fall back to default on parse exception, but explicit defaults read better in the diff.
3. Bound numeric values with `.clamp(...)` so corrupt user files never produce out-of-range values.
4. Use `errorTag` so write failures show useful debugPrint output.
5. Add at least one widget-test exercising the load path with a custom `directory:` to bypass `path_provider`.

The full list of keys is documented in `core/persistence/json_store.dart` doc-comment. Do not introduce a parallel persistence file for one-off keys; the `settings.json` shared object is intentional (BATCH-18c rationalized 17 ad-hoc files into one).

## API Client Service Providers

For pages that wrap one or more `rust_api.xxx` FRB calls, prefer wrapping the calls in a service class under `core/services/` rather than passing optional `*Override` callbacks through page constructors.

Pattern (see `core/services/backup_api_client.dart`, `core/services/source_validation_service.dart` for canonical examples — both added in BATCH-20):

```dart
class BackupApiClient {
  const BackupApiClient();

  Future<void> exportBackup({required String dbPath, required String outZipPath}) {
    return rust_api.exportBackupZip(dbPath: dbPath, outZipPath: outZipPath);
  }
  // ... methods 1:1 mirror rust_api.xxx names
}

final backupApiClientProvider = Provider<BackupApiClient>((ref) => const BackupApiClient());
```

Pages call `final api = ref.read(backupApiClientProvider); await api.exportBackup(...)`. Tests inject fakes via `ProviderScope(overrides: [backupApiClientProvider.overrideWithValue(_FakeBackupApiClient(...))])`. The fake extends (not implements) the real class so missing-override methods inherit production behavior — typically you only override the methods the test exercises.

Why this pattern over the constructor `*Override` pattern documented in [testing.md](./testing.md):

- Page constructors stay clean (no 10-field `*Override` lists like the pre-BATCH-20 `BackupPage`).
- Multiple pages can share one client without re-declaring each override.
- ProviderScope.overrides composes — multiple service overrides apply additively without constructor combinatorics.

When to use which pattern:

- **Service provider** (this section): when wrapping FRB calls grouped by feature area (backup, source validation, file picking).
- **`*Override` constructor** (still allowed, see [testing.md](./testing.md)): when a single page has 1-3 cross-cutting overrides (e.g. `dbPathOverride` for path_provider bypass that doesn't fit a service abstraction). `BackupPage::dbPathOverride` is the canonical surviving example (BATCH-20 explicitly preserved).
- **Riverpod provider override** (e.g. `dbPathProvider.overrideWith(...)`): when overriding existing provider-backed state, not adding new injection points.

Existing services in `core/services/` (as of BATCH-20):

- `backup_api_client.dart` — backup zip export/import + WebDAV upload/list/download
- `file_picker_service.dart` — file_picker wrapper (directory + zip file pick)
- `source_validation_service.dart` — `rust_api.validateSourceLive` wrapper for source liveness test

### Convention: Batch FRB wrappers live in services

**What**: When a feature needs a cross-layer batch FRB call, add a small service wrapper in `core/services/` and inject it with `ProviderScope.overrides` in tests.

**Why**: The page stays focused on UI state, and the wrapper keeps the FRB call shape in one place. This also avoids a direct `rust_api` dependency in the widget tree.

**Example**:
```dart
class SourceValidationService {
  const SourceValidationService();

  Future<String> batchCheckSources({
    required String dbPath,
    required String sourceIdsJson,
    required String configJson,
  }) {
    return rust_api.batchCheckSources(
      dbPath: dbPath,
      sourceIdsJson: sourceIdsJson,
      configJson: configJson,
    );
  }
}
```

**Related**: `source_validation_service.dart`, `source_check_progress_page.dart`.

Naming conventions:

- File: `<feature>_<role>.dart` (e.g. `backup_api_client.dart`, not `backup_client.dart`).
- Class: `XxxApiClient` for FRB wrappers, `XxxService` for cross-cutting helpers.
- Provider: `xxxClientProvider` / `xxxServiceProvider` lowercase suffix.
- Constructor: `const XxxApiClient()` — services are stateless.

## Derived State (Single Source of Truth)

`fontSizeProvider` is **not** a `StateProvider`; it is a derived `Provider` reading from `readerSettingsProvider`:

```dart
final fontSizeProvider = Provider<double>((ref) {
  final settings = ref.watch(readerSettingsProvider);
  return settings.fontSize;
});
```

Why: before BATCH-18d the same value lived in two providers. Editing one didn't update the other. The fix made `readerSettings` the source of truth and `fontSizeProvider` a thin lens.

When introducing a new piece of UI state that overlaps with an existing provider, **derive** rather than duplicate. Two writers to the same conceptual value is a recurring bug pattern (`findings-flutter-core.md::F-W2A-008`).

## Invalidation Patterns

After mutating data through a `bridge::api::*` call, invalidate the affected providers:

```dart
await rust_api.deleteBook(dbPath: dbPath, id: bookId);
ref.invalidate(allBooksProvider);
ref.invalidate(booksByGroupProvider);
ref.invalidate(bookChaptersProvider(bookId));
```

Rules:

- Always invalidate **after** the FRB call returns (await first).
- Invalidate every provider whose result depends on the mutated row, not just the most obvious one. Backups touch 5 invalidations (allBooks / booksByGroup / bookGroups / allSources / allReplaceRules) — see `features/settings/backup_page.dart` for the reference list.
- Family providers must be invalidated by exact parameter when known, otherwise by whole family. Prefer parameter-precise invalidation.

### Convention: pop result then invalidate from caller state

**What**: If a route returns from `context.push(...)`, do the provider invalidation in the caller after the returned future completes and only if the caller is still mounted.

**Why**: The route owns its own UI lifetime. The caller should not invalidate while the popped route is still active or after the caller has already unmounted.

**Example**:
```dart
final args = await showDialog<SourceCheckProgressArgs>(...);
if (args == null) return;
if (!mounted) return;
await context.push('/source-check-progress', extra: args);
if (!mounted) return;
ref.invalidate(allSourcesProvider);
```

**Related**: `source_page.dart`, `async-and-mounted.md`.

## Read vs Watch

- Inside `build` → `ref.watch(...)`. Rebuild on change.
- Inside event handlers / async callbacks → `ref.read(...)`. One-shot read.
- `ref.refresh(...)` is rare; only use when you need the new value synchronously.

The codebase has no `ref.listen` callers today. If you add one, document why in a comment.
