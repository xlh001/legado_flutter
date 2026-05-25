# Directory Structure

How the Flutter app is organized and which imports are allowed across boundaries.

## Layered Boundaries

```
features/  ──▶  core/  ──▶  src/rust/   (FRB-generated)
   │             │
   ▼             ▼
features/    pubspec deps (riverpod / go_router / dio / file_picker / ...)
```

Rules:

1. `core/` may import from `pubspec` deps and from `src/rust/` only. It must not import from any `features/` subfolder.
2. `features/<x>/` may import from `core/` and from `src/rust/`. It may import from a sibling `features/<y>/` only when one feature explicitly composes the other (e.g. `bookshelf` opens `reader` via go_router; the bookshelf widget itself does not import reader's State classes).
3. Anything in `src/rust/` is auto-generated. Treat it like a vendor folder — never hand-edit, never `import 'src/rust/foo.dart' show _Internal`.
4. `main.dart` may import everything; it is the composition root.

When a function feels like it belongs in two features at once, lift it to `core/util/` (pure helper) or `core/widgets/` (UI). The migration log in `findings-flutter-features.md` tracks each promotion (BATCH-24 promoted `_formatRelativeTime`, `platformInt64ToInt`, `formatImportSummaryLabel`; BATCH-25 promoted `safeSetState`).

## Feature Folder Shape

A feature folder owns:

- One or more `*_page.dart` files. Each is a `ConsumerStatefulWidget` with a `*PageState` next to it.
- A `widgets/` subfolder for components scoped to this feature.
- Test hooks (`*Override`) declared on the `Page`'s constructor for unit testability. See [testing.md](./testing.md).

Reference shape (`features/rule_sub/rule_sub_page.dart`):

```dart
class RuleSubPage extends ConsumerStatefulWidget {
  final String? dbPathOverride;       // path_provider bypass for tests
  final Future<int> Function(String, String)? deleteOverride;  // FRB bypass for tests
  final Future<int> Function(String, String, String, String, int)? updateOverride;
  // ...
  const RuleSubPage({super.key, this.dbPathOverride, ...});
}
```

The pattern of plumbing test overrides through page constructors keeps the production path entirely unmocked (no global mocks, no service locators).

## Where New Code Goes

| New code | Location |
|---|---|
| New SQL-backed page | `features/<area>/<thing>_page.dart` |
| New cross-feature dialog | `core/widgets/` (and reuse — do not copy widgets) |
| New time/format/parse helper used in 2+ features | `core/util/` with a unit test |
| New settings key persisted to `settings.json` | New wrapper in `core/providers.dart`, backed by `core/persistence/json_store.dart` |
| New cross-feature infrastructure (diagnostics, local logging) | `core/diagnostics/` — append-only operational data; must NOT block app flows; share `resolvePersistenceDir()` for path consistency |
| New FRB call | Add `pub fn` in `core/bridge/src/api.rs`, regenerate, then call from feature via `rust_api.fooBar(...)` |

## Anti-Patterns Rejected by History

- Importing `features/foo` from `core/`. Caught in BATCH-22 sweep.
- Per-feature `path_provider` calls. Use `core/persistence/json_store::resolvePersistenceDir()`. BATCH-18e collapsed 6 sites.
- Duplicating helper logic across features instead of promoting to `core/util/`. BATCH-24 found 3 such duplications (PlatformInt64, time format, ImportSummary).
- Inline `if (mounted) setState(() => ...)` inside features. BATCH-25 replaced 31 sites with `safeSetState(...)`. See [async-and-mounted.md](./async-and-mounted.md).
