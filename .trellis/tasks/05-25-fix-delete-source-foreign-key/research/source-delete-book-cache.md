# Research: source delete / book cache / source switching

- **Query**: Original Legado / equivalent implementation for deleting book sources, preserving books + cached chapter data, handling missing sources, and triggering source switching for uncached content
- **Scope**: mixed
- **Date**: 2026-05-25

## Findings

### Files Found

| File Path | Description |
|---|---|
| `core/core-storage/src/database.rs` | Schema: `books.source_id` FK to `book_sources(id)`; `chapters.book_id` and `book_progress.book_id` use `ON DELETE CASCADE` |
| `core/core-storage/src/source_dao.rs` | Source insert/delete logic; URL-dedup `upsert` preserves `book->source` links; `find_for_book_url` supports source lookup by book URL |
| `core/core-storage/src/book_dao.rs` | Book persistence is separate from sources; books are upserted independently and can be queried by `source_id` |
| `core/core-storage/src/chapter_dao.rs` | Chapter replace logic preserves cached chapter body by URL; delete-by-book was intentionally removed because book delete cascades |
| `core/bridge/src/api.rs` | Bridge delete/update flows; `delete_source`, `delete_book`, `update_book_toc`, `find_book_source_for_url` |
| `core/api-server/src/routes/reader.rs` | Reader path when cached content is missing: loads book then source, returns `书源不存在` if source row is gone |
| `core/api-server/src/routes/sources.rs` | API delete-source endpoint only deletes the source row; no book cleanup here |
| `flutter_app/lib/features/reader/change_source_dialog.dart` | Manual换源 flow: search enabled sources, fetch TOC, fetch book info, return new source/book/chapters |
| `flutter_app/lib/features/reader/reader_page.dart` | Applies换源 result: replaces chapters, saves updated book source/book_url/source_name, reloads content |

### Code Patterns

- **Deleting a source does not delete books in app logic**: `SourceDao::delete` only executes `DELETE FROM book_sources WHERE id = ?` (`source_dao.rs:218-223`), and the API route mirrors that (`api.rs:203-219`, `routes/sources.rs:112-128`). No book rows are touched there.
- **But the DB schema makes source deletion fail when books still reference it**: `books.source_id TEXT NOT NULL` with `FOREIGN KEY (source_id) REFERENCES book_sources(id)` (`database.rs:165-194`). There is no `ON DELETE CASCADE` or `SET NULL` on this FK.
- **Books and cached chapters are decoupled**: deleting a book cascades chapters/progress/bookmarks because those tables point to `books(id)` with `ON DELETE CASCADE` (`database.rs:198-255`); source deletion has no equivalent cascade.
- **Chapter cache is preserved on TOC refresh /换源 by URL match**: `ChapterDao::replace_by_book_preserving_content_in_tx` snapshots existing chapter `content` by URL, deletes/reinserts chapter rows, and restores cached content when the new chapter URL matches (`chapter_dao.rs:98-150`).
- **Missing source is a hard error for uncached content paths**: `update_book_toc` loads `Book`, then `SourceDao::get_by_id(book.source_id)`, and returns `书源不存在` if absent (`api.rs:1061-1108`). The reader API does the same before fetching uncached chapter content (`routes/reader.rs:129-150`).
- **Uncached content does not auto-switch sources**: the reader path resolves `book.source_id` and fetches chapter content from that source only (`routes/reader.rs:129-167`). If source lookup fails, it errors; there is no fallback source search in this path.
- **Manual source switching is explicit UI flow**: `ChangeSourceDialog` searches enabled sources via `searchWithSourceFromDbV2`, then fetches TOC and book info from the selected source (`change_source_dialog.dart:70-260`). `reader_page.dart` then rewrites the book row and chapter list (`reader_page.dart:2563-2719`).
- **Automatic source matching exists only for URL-based add/import**: `SourceDao::find_for_book_url` matches enabled sources by base URL or `book_url_pattern` regex, exposed by `find_book_source_for_url` (`source_dao.rs:396-448`, `api.rs:1794-1820`). That is used for book discovery, not for fallback on missing cached chapter content.

### External References

- None used; this research is based on repo source and embedded Legado-alignment comments.

### Related Specs

- `.trellis/spec/rust-core/storage-and-database.md` — DAO and transaction conventions that explain the FK / cascade patterns.
- `.trellis/spec/flutter-app/persistence.md` — app-side persistence contract; relevant only for the Flutter reader’s stored state.

## Caveats / Not Found

- No code path found that automatically rebinds an existing book to another source when its current source row is missing.
- Deleting a source row with live book references appears blocked by the FK as defined; the repo’s own `update_book_toc_no_source` test documents the dangling-source case only by temporarily disabling FK checks.
