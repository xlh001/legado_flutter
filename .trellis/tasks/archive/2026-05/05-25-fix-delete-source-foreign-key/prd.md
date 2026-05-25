# Fix Delete Source Foreign Key

## Goal

Deleting one or more book sources must not delete or block access to existing bookshelf books. A book added to the bookshelf owns its persisted metadata, chapter list, reading progress, bookmarks, and cached chapter content independently from the source row that originally found it.

## Requirements

- Deleting a source succeeds even when books still remember that source id.
- Existing books, chapters, reading progress, bookmarks, and cached chapter content remain intact after source deletion.
- `books.source_id` remains available as remembered origin/current-source metadata, but it is a soft reference rather than a hard SQLite foreign key.
- Fresh databases and migrated existing databases must both allow books whose remembered `source_id` no longer exists in `book_sources`.
- Cached chapter reads must continue to work without a source row.
- Uncached chapter reads may fail with an actionable missing-source message when no usable source is available; users can manually switch source from the reader.
- Existing manual source switching behavior remains intact and continues to update book metadata and chapter list when the user selects a new source.

## Acceptance Criteria

- [ ] Source deletion no longer raises `FOREIGN KEY constraint failed` when books reference the deleted source.
- [ ] A regression test proves deleting a source preserves the dependent book row.
- [ ] A schema/migration test proves `books` no longer has a foreign key to `book_sources` after migration.
- [ ] Existing book/chapter DAO tests still pass.
- [ ] Rust formatting and targeted cargo tests pass.

## Definition of Done

- Storage schema updated for fresh installs.
- Migration added for existing databases.
- DAO/bridge behavior remains backward compatible at the JSON/FRB surface.
- Tests cover the bug symptom and migration behavior.
- No generated FRB Dart/Rust binding changes unless a public function signature changes.

## Technical Approach

- Rebuild the `books` table in a new DB migration to remove `FOREIGN KEY (source_id) REFERENCES book_sources(id)` while preserving all current columns and row data.
- Update the fresh `CREATE TABLE books` schema to omit the hard source FK.
- Keep `chapters/book_progress/bookmarks -> books(id) ON DELETE CASCADE` unchanged because deleting a book should still clean its owned children.
- Do not change the existing FRB function signatures.
- Keep manual source switching as the user-visible recovery path for books whose remembered source row is gone and whose uncached chapter content needs network loading.

## Decision (ADR-lite)

Context: The current schema treats `books.source_id` as a required parent reference to `book_sources(id)`. That blocks source deletion and contradicts the desired bookshelf model where a saved book keeps its own data even if sources are removed or changed.

Decision: Make `books.source_id` a soft remembered-origin field by removing the SQLite FK to `book_sources`. Preserve the text value for source display, backup/export mapping, source switching, and best-effort lookup.

Consequences: Source deletion is safe for bookshelf data. Some online refresh/content paths can still report `书源不存在` until the user switches to another source, which matches the manual recovery model and avoids adding a new FRB contract in this task.

## Out of Scope

- Full automatic re-search/rebind of every affected book at source deletion time.
- Adding new persisted origin URL columns to `books`.
- Changing FRB-generated bindings or public method signatures.
- Rebuilding the reader source-switching UI.

## Technical Notes

- Root cause: `database.rs` defines `FOREIGN KEY (source_id) REFERENCES book_sources(id)` without `ON DELETE CASCADE` or `SET NULL`, while `SourceDao::delete` only deletes `book_sources`.
- Manual source switch exists in `flutter_app/lib/features/reader/change_source_dialog.dart` and persists selected source metadata in `reader_page.dart`.
- Chapter cache is owned by `chapters.book_id` and preserved by existing reader/load paths when `content` is already present.
- Research reference: [`research/source-delete-book-cache.md`](research/source-delete-book-cache.md).
- Original Legado reference: [`research/original-legado-source-delete.md`](research/original-legado-source-delete.md) confirms `Book.origin` is not a Room FK and source deletion does not delete books.
