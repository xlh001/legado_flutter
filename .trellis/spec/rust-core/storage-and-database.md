# Storage and Database

Conventions for SQLite access in `core-storage` and the cross-DAO transaction helper in `bridge`.

## Database Lifecycle

- Every DB call starts from `core_storage::database::get_connection(db_path)` which opens a fresh `Connection`. There is **no shared pool**.
- `core_storage::database::init_database(db_path)` creates tables if missing and runs migrations up to the constant `DB_VERSION` (currently 14). Migrations are stored as plain SQL inside `database.rs` and are tracked through `PRAGMA user_version`.
- WAL is enabled at every `init_database` call via `pragma_update_and_check(None, "journal_mode", "WAL", ...)` and verified by 2 dedicated DB-level tests (BATCH-08c). Treat WAL as production behaviour — backup_dao goes through SQL `SELECT` so WAL sidecars are transparent (see [backup-aes guide](../guides/backup-aes-thinking-guide.md) and `findings-rust-data.md::F-W1A-056`).

When you write new SQL elsewhere, never call `Connection::open` directly. Always go through `database::get_connection` so PRAGMAs (foreign keys, WAL, busy timeout) stay consistent.

## DAO Pattern

DAO files live next to `database.rs` (`book_dao.rs`, `chapter_dao.rs`, ...). Each DAO follows the same shape, demonstrated by `core-storage/src/book_dao.rs`:

```rust
pub struct BookDao<'a> { conn: &'a Connection }

impl<'a> BookDao<'a> {
    pub fn new(conn: &'a Connection) -> Self { ... }

    /// Single-call write. Opens its own savepoint if it must run multi-statement.
    pub fn upsert(&self, book: &Book) -> SqlResult<()> { ... }

    /// Same write but bound to an external Transaction — the variant the
    /// `bridge::transaction::with_transaction` helper consumes.
    pub fn upsert_in_tx(tx: &rusqlite::Transaction<'_>, book: &Book) -> SqlResult<()> { ... }
}
```

Rules for new DAOs:

1. **Column-list constants.** Every DAO that touches more than 3 columns must declare a `const X_COLUMNS: &str = "id, source_id, ..."` near the top, and the SELECT/INSERT/UPDATE statements must read from that constant. The matching `from_row(row)` indices follow the same column order. See `book_dao.rs:18` (`BOOK_COLUMNS`) and `replace_rule_dao.rs` for the canonical example. BATCH-08 introduced this rule after column drift bugs.
2. **`upsert_in_tx` variant.** Whenever a DAO supports `upsert`, also expose a `pub fn upsert_in_tx(tx: &Transaction, ...)`. `bridge` uses these variants to compose multi-DAO atomic writes.
3. **Return `SqlResult<T>` (`rusqlite::Result`) inside `core-storage`.** Conversion to `Result<T, String>` happens at the `bridge` boundary, not inside the DAO.
4. **No tracing inside hot read paths.** `dao.get_*` runs on every chapter switch; `info!` / `debug!` belong in mutating writes only. See [logging.md](./logging.md).

## Cross-DAO Transactions

When a single `bridge::api::*` function writes through more than one DAO, wrap it in `bridge::transaction::with_transaction`:

```rust
// core/bridge/src/api.rs (excerpt, see import_local_book / download_and_save_chapter)
crate::transaction::with_transaction(&db_path, |tx| {
    BookDao::upsert_in_tx(tx, &book).map_err(|e| format!("upsert book: {e}"))?;
    for ch in chapters {
        ChapterDao::upsert_in_tx(tx, &ch).map_err(|e| format!("upsert chapter: {e}"))?;
    }
    Ok(())
})
```

Why this matters:

- The helper opens the connection, begins the transaction, runs the closure, commits on `Ok`, and **lets `Drop` rollback on any `?` early-return**. RAII safety is part of the contract; do not call `tx.rollback()` manually.
- Closure errors are `String` so they line up with the `bridge` outer signature. `rusqlite::Error` must be mapped (`format!("upsert book: {e}")`) at the call site.
- Read-only methods on a DAO accept `&Connection`. Because `rusqlite::Transaction: Deref<Target=Connection>`, you can pass `&*tx` (or just rely on auto-deref) into a DAO that only reads — see `transaction.rs:11-17` doc-comment.

The companion async helper in `api-server` is `db_transaction` and follows the same shape with `tokio::spawn_blocking`. Keep both in sync if you change the contract.

## Models and Field Mapping

`core-storage::models` holds plain-data structs without database-specific decoration. Anything that translates between Legado JSON and local fields lives in `core-storage::legado_field_map`. Common helpers worth reusing:

- `legado_field_map::ms_to_seconds_smart` — defensive timestamp conversion (`>1e10` treated as ms, otherwise as s). All Legado backups use ms; the local schema stores s.
- `legado_field_map::legado_group_bitmask_to_id` — collapses a Legado bitmask to the lowest power-of-2 group id used locally.
- `legado_field_map::parse_word_count` — parses `"5.2M"` / `"10万"` / `"120K"` strings to `i32`.

Do not re-implement these conversions inside DAOs. If a new mapping is needed, add it to `legado_field_map.rs` with both a unit test and a doc comment explaining the source-of-truth Legado field.

## Schema Migrations

- Bump `DB_VERSION` in `database.rs:10` only when a migration block is added.
- Migrations are sequential `if old < N { run sql; old = N; }`. Add new ones in `apply_migrations` (search for existing `match user_version` blocks).
- Add a `database::tests::test_migration_from_vN_to_vN+1` covering the new step. The existing `test_migration_from_v1_to_v2` is the canonical template.

## Scenario: Books Keep Soft Source References

### 1. Scope / Trigger

- Trigger: code that creates, migrates, deletes, imports, or exports bookshelf books and book sources.
- Bookshelf books own their saved metadata, chapters, progress, bookmarks, and cached chapter content. Book sources are replaceable parser definitions.
- This follows original Legado's model where `Book.origin` / `originName` are plain stored fields and deleting a `BookSource` does not delete books.

### 2. Signatures

- Fresh schema: `books.source_id TEXT NOT NULL` is a soft metadata column, not a `FOREIGN KEY` to `book_sources(id)`.
- Preserved hard FKs: `chapters.book_id`, `book_progress.book_id`, and `bookmarks.book_id` reference `books(id) ON DELETE CASCADE`.
- Index contract: `idx_books_source_id ON books(source_id)` must still exist because source id remains queryable metadata.

### 3. Contracts

- `SourceDao::delete(id)` and `SourceDao::delete_batch(ids)` delete only `book_sources` rows.
- Deleting a source must not delete or mutate rows in `books`, `chapters`, `book_progress`, or `bookmarks`.
- A book may retain a `source_id` whose source row no longer exists. Online refresh/content paths may report missing source for uncached content until the user switches source.
- Cached chapter content is read from `chapters.content` before any online fetch; cached content must remain usable after source deletion.

### 4. Validation & Error Matrix

- Delete source with referencing books -> success; books and owned child rows remain.
- Save/import book with missing `source_id` -> success; this is allowed soft-reference state.
- Delete book -> child rows still cascade through `books(id)` FKs.
- Uncached online fetch with missing source -> bridge/reader returns a user-actionable missing-source error; caller should offer manual source switching.

### 5. Good/Base/Bad Cases

- Good: user deletes a source, opens an already cached chapter, and reads from stored content without network/source lookup.
- Base: user deletes a source, then manually switches the book to another source before loading uncached chapters.
- Bad: adding `ON DELETE CASCADE` from `books.source_id` to `book_sources(id)` or manually deleting `books` inside source deletion.

### 6. Tests Required

- Fresh DB test asserting `pragma_foreign_key_list('books')` has no `book_sources` reference.
- Regression test deleting a source referenced by a book and asserting the book row remains.
- Migration test from the last hard-FK schema version asserting row data is preserved, `idx_books_source_id` exists, and owned child FKs still cascade to `books`.

### 7. Wrong vs Correct

#### Wrong

```sql
FOREIGN KEY (source_id) REFERENCES book_sources(id) ON DELETE CASCADE
```

#### Correct

```sql
source_id TEXT NOT NULL
-- no FK to book_sources; this is remembered source metadata, not ownership
```

## Common Mistakes

- Opening `Connection::open` directly. Use `database::get_connection`.
- Forgetting `upsert_in_tx`. Without it, callers cannot batch the DAO into a cross-DAO transaction.
- SELECT/INSERT column lists copied across functions instead of using a single `*_COLUMNS` constant. This caused at least one regression captured in `findings-rust-data.md` (BATCH-08).
- Writing migrations that read user data via `dao::*`. Migrations should run **only** on raw SQL because the DAOs assume the latest schema.
- Treating book sources as owners of bookshelf books. Sources are parser definitions; book deletion owns/cascades book children, source deletion must not cascade to books.
