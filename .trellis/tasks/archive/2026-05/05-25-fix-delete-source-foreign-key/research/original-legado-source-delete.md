# Research: original-legado-source-delete

- **Query**: Verify how original Legado models bookshelf books vs book sources; source deletion; reader behavior when source is missing/cache state; manual/automatic change-source updates.
- **Scope**: mixed
- **Date**: 2026-05-25

## Findings

### Files Found

| File Path | Description |
|---|---|
| `legado/app/src/main/java/io/legado/app/data/entities/Book.kt` | Bookshelf book entity; `origin`/`originName` are plain columns, not a Room FK. |
| `legado/app/src/main/java/io/legado/app/data/entities/BookSource.kt` | Book source entity, keyed by `bookSourceUrl`. |
| `legado/app/src/main/java/io/legado/app/data/dao/BookSourceDao.kt` | Book source delete methods only remove source rows. |
| `legado/app/src/main/java/io/legado/app/help/source/SourceHelp.kt` | Source deletion orchestration; clears source cache/config, not books. |
| `legado/app/src/main/java/io/legado/app/model/ReadBook.kt` | Reader load path; cached content vs missing source behavior. |
| `legado/app/src/main/java/io/legado/app/help/book/BookHelp.kt` | Content cache lookup and fallback behavior. |
| `legado/app/src/main/java/io/legado/app/ui/book/changesource/ChangeBookSourceViewModel.kt` | Manual/automatic change-source logic and DB updates. |
| `legado/app/src/main/java/io/legado/app/ui/book/changesource/ChangeBookSourceDialog.kt` | User-facing change-source flow; triggers auto-change after source deletion. |
| `legado/app/src/main/java/io/legado/app/ui/book/read/ReadBookViewModel.kt` | Read-screen change-source path and auto-source recovery. |
| `legado/app/src/main/java/io/legado/app/ui/book/info/BookInfoViewModel.kt` | Book-info change-source/update path. |

### Code Patterns

- `Book` stores source linkage as simple fields: `origin` and `originName` are `@ColumnInfo` properties in `Book`, with no `@ForeignKey`/`foreignKeys` Room annotation on the entity (`Book.kt:34-51`).
- `BookSource` is a separate entity keyed by `bookSourceUrl` (`BookSource.kt:27-35`).
- Deleting a source only deletes rows from `book_sources` plus source-variable/config cleanup: `BookSourceDao.delete(key)` is `delete from book_sources where bookSourceUrl = :key` (`BookSourceDao.kt:267-274`), and `SourceHelp.deleteBookSourceInternal()` calls `bookSourceDao.delete(key)`, `cacheDao.deleteSourceVariables(key)`, and `SourceConfig.removeSource(key)` (`SourceHelp.kt:81-90`). No book rows are deleted there.
- Reader content load first checks disk cache: `BookHelp.getContent()` returns cached chapter text if the cache file exists; for local books it falls back to `LocalBook.getContent()`, otherwise it returns `null` for web books (`BookHelp.kt:397-421`).
- `ReadBook.loadContent()` uses cached content if available; if not, it downloads via `CacheBook.getOrCreate(bookSource, book)` when `bookSource != null`, else it shows failure text: local books get `无内容`, non-local books get `没有书源` (`ReadBook.kt:566-673`).
- `ChangeBookSourceViewModel.changeTo()` and `ReadBookViewModel.changeTo()` both migrate old state into a new `Book`, replace/insert the book row, and replace chapter rows when the book is in the bookshelf (`ChangeBookSourceViewModel.kt:283-313`, `ReadBookViewModel.kt:270-288`).
- Auto/manual change-source flows search or load from candidate sources, then update the existing book with `migrateTo(...)` / `updateTo(...)`, persist the new book, and refresh chapters/cache folders when the `bookUrl` changes (`BookInfoViewModel.kt:171-261`, `BookInfoViewModel.kt:365-380`, `BookshelfViewModel.kt:67-84`).

### External References

- Not used.

### Related Specs

- Not checked for this research task.

## Caveats / Not Found

- No Room foreign key was found between `Book.origin` and `BookSource.bookSourceUrl`.
- Source deletion does not cascade-delete books in the inspected code.
- If a non-local book loses its source, reader code falls back to cached chapter content when present; otherwise it reports missing source / no content.
