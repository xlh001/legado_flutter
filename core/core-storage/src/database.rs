//! # 数据库模块
//!
//! 负责 SQLite 数据库的初始化、表创建和迁移。
//! 对应原 Legado 的数据库初始化逻辑 (help/storage/)。

use rusqlite::{Connection, Result as SqlResult};
use tracing::{debug, info, warn};

/// 数据库版本（用于迁移，通过 PRAGMA user_version 持久化）
const DB_VERSION: i32 = 13;

/// 初始化数据库
/// 创建所有必要的表，如果数据库已存在则检查是否需要迁移
pub fn init_database(db_path: &str) -> SqlResult<Connection> {
    info!("初始化数据库: {}", db_path);

    // 确保目录存在
    if let Some(parent) = std::path::Path::new(db_path).parent() {
        if !parent.exists() {
            std::fs::create_dir_all(parent).map_err(|e| {
                rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
                    Some(e.to_string()),
                )
            })?;
        }
    }

    let mut conn = Connection::open(db_path)?;

    // F-W1A-055（BATCH-08c）：启用 WAL 日志模式。
    //
    // WAL 是 db 文件级持久化（写入 db header），一次设置后所有后续连接
    // （包括下方 [`get_connection`] 打开的新连接、r2d2 pool、直调
    // `Connection::open`）自动继承，无需重设。
    //
    // 启用 WAL 是下方 `synchronous = NORMAL` + `wal_autocheckpoint = 1000`
    // 真正生效的前提：rollback journal mode 下 `synchronous = NORMAL` 不
    // 安全（应是 FULL），`wal_autocheckpoint` 完全 no-op。BATCH-07b 加
    // 这两条 pragma 时漏了 journal_mode 设置，本批补齐。
    //
    // `PRAGMA journal_mode = WAL` 在 SQLite 协议里返回当前 mode 字符串行，
    // 用 `pragma_update_and_check` 一并完成 set + 取值。失败时不阻塞启动，
    // 仅 warn — 启用失败属"不应发生"路径（仅网络文件系统才不支持，
    // 项目不涉及）。
    let journal_mode: String =
        conn.pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get(0))?;
    if journal_mode.eq_ignore_ascii_case("wal") {
        info!("数据库 WAL 模式已启用");
    } else {
        warn!("WAL 启用失败，当前 journal_mode = {}", journal_mode);
    }

    // 启用外键约束
    conn.execute("PRAGMA foreign_keys = ON", [])?;

    // WAL 持久性调优（批次 69 / BATCH-07b，F-W1A-004；BATCH-08c 启用 WAL）：
    //
    // - `synchronous = NORMAL`：在 WAL 模式下被官方推荐为最佳安全 / 性能
    //   平衡点。断电仅丢失最近未 fsync 到 -wal 文件的事务，已 commit 的
    //   事务仍在 WAL 中，下次打开会自动 replay；FULL 太严格（每次 commit
    //   都同步主 db，慢但本质收益小），OFF 不安全。**注意**：该 PRAGMA
    //   是连接级（per-connection），下方的 [`get_connection`] 也设一次。
    //
    // - `wal_autocheckpoint = 1000`：每累积 1000 页（~4 MB）触发 WAL
    //   checkpoint，限制 -wal 文件无限增长。SQLite 编译期默认就是 1000，
    //   显式写出避免编译选项漂移。该 PRAGMA 也是连接级，但因每次新连接
    //   都从默认值（1000）起跳，复设也无副作用，仅 init 设一次足够。
    //
    // 不在每次 [`get_connection`] 重设 wal_autocheckpoint 是因为它的默
    // 认就是目标值；synchronous 必须每条连接都重设，否则部分 caller 会
    // 拿到默认 FULL。
    //
    // 用 `pragma_update` 而不是 `execute("PRAGMA ... = ...")` 是因为部分
    // PRAGMA 写形式在 SQLite 新版本里会返回当前值行（execute 不允许有
    // 结果集），rusqlite `pragma_update` 把 query / update 都封装好。
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "wal_autocheckpoint", 1000_i32)?;

    // 检查数据库版本（使用 PRAGMA user_version）
    let version = get_db_version(&conn)?;
    debug!("当前数据库版本: {}", version);

    // 创建或迁移表
    if version == 0 {
        create_tables(&conn)?;
        set_db_version(&conn, DB_VERSION)?;
    } else if version < DB_VERSION {
        migrate_database(&mut conn, version, DB_VERSION)?;
    } else if version > DB_VERSION {
        warn!(
            "数据库版本 {} 高于当前版本 {}，跳过迁移",
            version, DB_VERSION
        );
    }

    info!("数据库初始化完成");
    Ok(conn)
}

/// 创建所有表
pub fn create_tables(conn: &Connection) -> SqlResult<()> {
    info!("创建数据库表...");

    // 应用设置表
    conn.execute(
        "CREATE TABLE IF NOT EXISTS app_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )",
        [],
    )?;

    // 书源表 (对应原 Legado 的 BookSource 实体)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS book_sources (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            url TEXT NOT NULL UNIQUE,
            source_type INTEGER DEFAULT 0,
            group_name TEXT,
            enabled INTEGER DEFAULT 1,
            custom_order INTEGER DEFAULT 0,
            weight INTEGER DEFAULT 0,
            
            -- 规则（JSON 格式存储）
            rule_search TEXT,
            rule_book_info TEXT,
            rule_toc TEXT,
            rule_content TEXT,
            
            -- 其他配置
            login_url TEXT,
            login_ui TEXT,
            login_check_js TEXT,
            header TEXT,
            js_lib TEXT,
            cover_decode_js TEXT,
            book_url_pattern TEXT,
            rule_explore TEXT,
            explore_url TEXT,
            enabled_explore INTEGER DEFAULT 1,
            last_update_time INTEGER DEFAULT 0,
            book_source_comment TEXT,
            concurrent_rate TEXT,
            variable_comment TEXT,
            explore_screen INTEGER,
            
            -- 校验结果持久化 (v13 / 批次 check-sources)
            respond_time INTEGER DEFAULT 0,
            last_check_error TEXT,
            last_check_at INTEGER DEFAULT 0,

            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;

    // 书籍表 (对应原 Legado 的 Book 实体)
    // 批次 6 (v11): 加 5 字段对齐原 Legado Book.kt:96-102
    //   - dur_chapter_index/pos/title/time: 当前阅读章节快照（书架卡片用）
    //   - group_id: 所属分组 id（0 = 未分组）
    conn.execute(
        "CREATE TABLE IF NOT EXISTS books (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            source_name TEXT,
            name TEXT NOT NULL,
            author TEXT,
            cover_url TEXT,
            chapter_count INTEGER DEFAULT 0,
            latest_chapter_title TEXT,
            intro TEXT,
            kind TEXT,
            book_url TEXT,
            toc_url TEXT,
            last_check_time INTEGER,
            last_check_count INTEGER DEFAULT 0,
            total_word_count INTEGER DEFAULT 0,
            can_update INTEGER DEFAULT 1,
            order_time INTEGER NOT NULL,
            latest_chapter_time INTEGER,
            custom_cover_path TEXT,
            custom_info_json TEXT,
            dur_chapter_index INTEGER DEFAULT 0,
            dur_chapter_pos INTEGER DEFAULT 0,
            dur_chapter_title TEXT,
            dur_chapter_time INTEGER DEFAULT 0,
            group_id INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (source_id) REFERENCES book_sources(id)
        )",
        [],
    )?;

    // 章节表
    conn.execute(
        "CREATE TABLE IF NOT EXISTS chapters (
            id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            index_num INTEGER NOT NULL,
            title TEXT NOT NULL,
            url TEXT NOT NULL,
            content TEXT,
            is_volume INTEGER DEFAULT 0,
            is_checked INTEGER DEFAULT 0,
            start INTEGER DEFAULT 0,
            end INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
        )",
        [],
    )?;

    // 阅读进度表
    conn.execute(
        "CREATE TABLE IF NOT EXISTS book_progress (
            book_id TEXT PRIMARY KEY,
            chapter_index INTEGER DEFAULT 0,
            paragraph_index INTEGER DEFAULT 0,
            offset INTEGER DEFAULT 0,
            read_time INTEGER DEFAULT 0,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
        )",
        [],
    )?;

    // 书签表
    // 批次 6 (v11): 加 5 字段对齐原 Legado Bookmark.kt
    //   - book_name/book_author 冗余存（书删了仍保留）
    //   - chapter_pos: 章内字符级 offset
    //   - chapter_name: 章节标题
    //   - book_text: 书签所在位置文本片段（上下文预览）
    conn.execute(
        "CREATE TABLE IF NOT EXISTS bookmarks (
            id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            chapter_index INTEGER NOT NULL,
            paragraph_index INTEGER DEFAULT 0,
            content TEXT,
            book_name TEXT,
            book_author TEXT,
            chapter_pos INTEGER DEFAULT 0,
            chapter_name TEXT,
            book_text TEXT,
            created_at INTEGER NOT NULL,
            FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
        )",
        [],
    )?;

    // 替换规则表
    // R24: schema 对齐原 Legado (app/data/entities/ReplaceRule.kt)。
    // scope 是 TEXT (nullable)，子串匹配 book.name 或 book.origin；
    // scope_title / scope_content 控制作用于哪一部分；exclude_scope
    // 与 scope 同语义但反向（命中即跳过）。
    conn.execute(
        "CREATE TABLE IF NOT EXISTS replace_rules (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            pattern TEXT NOT NULL,
            replacement TEXT NOT NULL,
            enabled INTEGER DEFAULT 1,
            scope TEXT,
            scope_title INTEGER DEFAULT 0,
            scope_content INTEGER DEFAULT 1,
            exclude_scope TEXT,
            sort_number INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;

    // 下载任务表
    conn.execute(
        "CREATE TABLE IF NOT EXISTS download_tasks (
            id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            book_name TEXT NOT NULL,
            cover_url TEXT,
            total_chapters INTEGER DEFAULT 0,
            downloaded_chapters INTEGER DEFAULT 0,
            status INTEGER DEFAULT 0,
            total_size INTEGER DEFAULT 0,
            downloaded_size INTEGER DEFAULT 0,
            error_message TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
        )",
        [],
    )?;

    // 下载章节记录表
    conn.execute(
        "CREATE TABLE IF NOT EXISTS download_chapters (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            chapter_id TEXT NOT NULL,
            chapter_index INTEGER NOT NULL,
            chapter_title TEXT NOT NULL,
            status INTEGER DEFAULT 0,
            file_path TEXT,
            file_size INTEGER DEFAULT 0,
            error_message TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (task_id) REFERENCES download_tasks(id) ON DELETE CASCADE
        )",
        [],
    )?;

    // 缓存表
    conn.execute(
        "CREATE TABLE IF NOT EXISTS legacy_cache (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS sync_log (
            id TEXT PRIMARY KEY,
            sync_type TEXT NOT NULL,
            sync_data TEXT,
            status INTEGER DEFAULT 0,
            error_message TEXT,
            started_at INTEGER NOT NULL,
            completed_at INTEGER,
            created_at INTEGER NOT NULL
        )",
        [],
    )?;

    // ============================================================
    // 批次 6 (v11) 新增 4 张表 — 仅 schema，DAO 留批次 7+ 实现
    // ============================================================

    // 书架分组表（对应原 Legado BookGroup.kt，简化掉 bitmask 设计）
    // id=0 约定为"未分组"；AUTOINCREMENT 从 1 开始所以不会和 0 冲突
    conn.execute(
        "CREATE TABLE IF NOT EXISTS book_groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            sort_order INTEGER DEFAULT 0,
            cover TEXT,
            show INTEGER DEFAULT 1,
            book_sort INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;

    // 阅读时长记录表（对应原 Legado ReadRecord.kt）
    // 原版 (deviceId, bookName) 联合主键 → 改成 UUID PK + book_id FK
    conn.execute(
        "CREATE TABLE IF NOT EXISTS read_records (
            id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            book_name TEXT NOT NULL,
            read_time INTEGER NOT NULL DEFAULT 0,
            last_read_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;

    // 持久化 Cookie 表（对应原 Legado Cookie.kt）
    // (domain, key, path) 三元组 UNIQUE — path 为 NULL 时 SQLite 视为不同行，
    // DAO 层在 upsert 时需把 NULL path 当成 '/' 或自行处理（留批次实现）
    conn.execute(
        "CREATE TABLE IF NOT EXISTS cookies (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            domain TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            path TEXT,
            expires_at INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE(domain, key, path)
        )",
        [],
    )?;

    // 订阅源表（对应原 Legado RuleSub.kt）
    // sub_type: 0=书源 1=RSS 2=替换规则
    conn.execute(
        "CREATE TABLE IF NOT EXISTS rule_subs (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            url TEXT NOT NULL UNIQUE,
            sub_type INTEGER DEFAULT 0,
            custom_order INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;

    // 创建索引
    create_indices(conn)?;
    // 批次 6 (v11) 新表索引（必须在 books 含 group_id + 4 张新表创建后调用）
    create_v11_indices(conn)?;

    // ============================================================
    // 批次 16 (v12) 新增 4 张表 — RSS 源管理 schema 骨架
    // ============================================================
    create_rss_tables(conn)?;
    create_v12_indices(conn)?;

    info!("数据库表创建完成");
    Ok(())
}

/// 创建索引
fn create_indices(conn: &Connection) -> SqlResult<()> {
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_books_source_id ON books(source_id)",
        [],
    )?;
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_chapters_book_id ON chapters(book_id)",
        [],
    )?;
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_chapters_index ON chapters(book_id, index_num)",
        [],
    )?;
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_bookmarks_book_id ON bookmarks(book_id)",
        [],
    )?;
    // 注意：批次 6 (v11) 新增的 books(group_id) / book_groups(sort_order) /
    // read_records(book_id) / cookies(domain) 索引刻意 *不* 放在这里。
    // 因为 create_indices 会被旧版 migrate（v6/v8 的 schema baseline 守护
    // 调用）触发，而那时 books 表还没 group_id 列、4 张新表也未创建。
    // 这些索引只在 [`create_v11_indices`] 中按需创建，由 [`create_tables`]
    // 末尾（fresh install 路径，books 已含新列）和 [`migrate_v11`]
    // （migration 路径）分别调用。
    Ok(())
}

/// 批次 6 (v11) 新增表的索引。
/// fresh install 走 create_tables → 调一次；migration 走 migrate_v11 → 调一次。
///
/// 防御：被 `create_tables` 调用时可能正处于 v6/v8 的"schema baseline
/// guard"路径（migrate_v6/v8 会调 create_tables 兜底），那时 books 还
/// 没 group_id 列、4 张新表也未创建。所以每个索引前都检查依赖项。
fn create_v11_indices(conn: &Connection) -> SqlResult<()> {
    let books_has_group_id: bool = conn.query_row(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('books') WHERE name = 'group_id'",
        [],
        |row| row.get(0),
    )?;
    if books_has_group_id {
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_books_group_id ON books(group_id)",
            [],
        )?;
    }
    if table_exists(conn, "book_groups")? {
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_book_groups_sort_order ON book_groups(sort_order)",
            [],
        )?;
    }
    if table_exists(conn, "read_records")? {
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_read_records_book_id ON read_records(book_id)",
            [],
        )?;
    }
    if table_exists(conn, "cookies")? {
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_cookies_domain ON cookies(domain)",
            [],
        )?;
    }
    Ok(())
}

/// 获取数据库版本（通过 PRAGMA user_version）
fn get_db_version(conn: &Connection) -> SqlResult<i32> {
    conn.pragma_query_value(None, "user_version", |row| row.get(0))
}

/// 设置数据库版本（通过 PRAGMA user_version）
fn set_db_version(conn: &Connection, version: i32) -> SqlResult<()> {
    conn.pragma_update(None, "user_version", version)?;
    Ok(())
}

/// 数据库迁移 — 按版本逐步迁移，包装在事务中
///
/// 用 [`Connection::transaction`] 的 RAII guard：迁移过程中任何 `?` 早返
/// 都会让 `tx` 在 Drop 时自动 rollback；只有走到 `tx.commit()` 才落盘，比
/// 之前手写 `BEGIN/COMMIT/ROLLBACK` 的两段式更可靠（panic 安全 + 不可能漏
/// rollback）。
fn migrate_database(conn: &mut Connection, from_version: i32, to_version: i32) -> SqlResult<()> {
    info!("数据库迁移: {} -> {}", from_version, to_version);
    let tx = conn.transaction()?;
    for v in (from_version + 1)..=to_version {
        debug!("执行版本 {} 迁移", v);
        match v {
            1 => migrate_v1(&tx)?,
            2 => migrate_v2(&tx)?,
            3 => migrate_v3(&tx)?,
            4 => migrate_v4(&tx)?,
            5 => migrate_v5(&tx)?,
            6 => migrate_v6(&tx)?,
            7 => migrate_v7(&tx)?,
            8 => migrate_v8(&tx)?,
            9 => migrate_v9(&tx)?,
            10 => migrate_v10(&tx)?,
            11 => migrate_v11(&tx)?,
            12 => migrate_v12(&tx)?,
            13 => migrate_v13(&tx)?,
            _ => {
                return Err(rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_ERROR),
                    Some(format!("未知的数据库版本: {}", v)),
                ));
            }
        }
    }
    set_db_version(&tx, to_version)?;
    tx.commit()?;
    info!("数据库迁移完成");
    Ok(())
}

/// 版本 1 迁移：创建初始表结构
fn migrate_v1(conn: &Connection) -> SqlResult<()> {
    create_tables(conn)?;
    Ok(())
}

/// 版本 2 迁移：示例增量迁移（添加 sync_log 表用于同步日志）
fn migrate_v2(conn: &Connection) -> SqlResult<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS sync_log (
            id TEXT PRIMARY KEY,
            sync_type TEXT NOT NULL,
            sync_data TEXT,
            status INTEGER DEFAULT 0,
            error_message TEXT,
            started_at INTEGER NOT NULL,
            completed_at INTEGER,
            created_at INTEGER NOT NULL
        )",
        [],
    )?;
    Ok(())
}

/// 版本 4 迁移：添加 book_url 列
fn migrate_v4(conn: &Connection) -> SqlResult<()> {
    let has_book_url: bool = conn.query_row(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('books') WHERE name = 'book_url'",
        [],
        |row| row.get(0),
    )?;
    if has_book_url {
        return Ok(());
    }
    conn.execute("ALTER TABLE books ADD COLUMN book_url TEXT", [])?;
    Ok(())
}

/// 版本 3 迁移：添加下载任务表
fn migrate_v3(conn: &Connection) -> SqlResult<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS download_tasks (
            id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            book_name TEXT NOT NULL,
            cover_url TEXT,
            total_chapters INTEGER DEFAULT 0,
            downloaded_chapters INTEGER DEFAULT 0,
            status INTEGER DEFAULT 0,
            total_size INTEGER DEFAULT 0,
            downloaded_size INTEGER DEFAULT 0,
            error_message TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
        )",
        [],
    )?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS download_chapters (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            chapter_id TEXT NOT NULL,
            chapter_index INTEGER NOT NULL,
            chapter_title TEXT NOT NULL,
            status INTEGER DEFAULT 0,
            file_path TEXT,
            file_size INTEGER DEFAULT 0,
            error_message TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (task_id) REFERENCES download_tasks(id) ON DELETE CASCADE
        )",
        [],
    )?;
    Ok(())
}

/// 版本 5 迁移：添加缓存表
fn migrate_v5(conn: &Connection) -> SqlResult<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS legacy_cache (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;
    Ok(())
}

/// 版本 6 迁移：添加探索规则相关列
fn migrate_v6(conn: &Connection) -> SqlResult<()> {
    create_tables(conn)?;
    for (col, col_type) in [
        ("rule_explore", "TEXT"),
        ("explore_url", "TEXT"),
        ("enabled_explore", "INTEGER DEFAULT 1"),
        ("last_update_time", "INTEGER DEFAULT 0"),
        ("book_source_comment", "TEXT"),
    ] {
        let has_col: bool = conn.query_row(
            &format!(
                "SELECT COUNT(*) > 0 FROM pragma_table_info('book_sources') WHERE name = '{}'",
                col
            ),
            [],
            |row| row.get(0),
        )?;
        if !has_col {
            conn.execute(
                &format!("ALTER TABLE book_sources ADD COLUMN {} {}", col, col_type),
                [],
            )?;
        }
    }
    Ok(())
}

/// 版本 7 迁移：为 books 表添加 toc_url 列
fn migrate_v7(conn: &Connection) -> SqlResult<()> {
    let has_toc_url: bool = conn.query_row(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('books') WHERE name = 'toc_url'",
        [],
        |row| row.get(0),
    )?;
    if has_toc_url {
        return Ok(());
    }
    conn.execute("ALTER TABLE books ADD COLUMN toc_url TEXT", [])?;
    Ok(())
}

/// 版本 8 迁移：为 book_sources 表添加 book_url_pattern 列
/// 版本 8 迁移：添加 book_url_pattern 列到 book_sources。
///
/// R65: the `create_tables(conn)?` call below is intentionally retained
/// as a "schema baseline" guard — if a previous v8 run aborted partway
/// (e.g. process killed) it makes sure all tables exist before we
/// attempt the ALTER. In the normal upgrade path it's a no-op since
/// every CREATE uses `IF NOT EXISTS`.
fn migrate_v8(conn: &Connection) -> SqlResult<()> {
    create_tables(conn)?;
    let has_book_url_pattern: bool = conn.query_row(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('book_sources') WHERE name = ?1",
        rusqlite::params!["book_url_pattern"],
        |row| row.get(0),
    )?;
    if has_book_url_pattern {
        return Ok(());
    }
    conn.execute(
        "ALTER TABLE book_sources ADD COLUMN book_url_pattern TEXT",
        [],
    )?;
    Ok(())
}

/// 版本 9 迁移：添加 concurrent_rate, login_ui, login_check_js 列到 book_sources
fn migrate_v9(conn: &Connection) -> SqlResult<()> {
    let columns = [
        ("concurrent_rate", "TEXT"),
        ("login_ui", "TEXT"),
        ("login_check_js", "TEXT"),
        ("cover_decode_js", "TEXT"),
        ("variable_comment", "TEXT"),
        ("explore_screen", "INTEGER"),
    ];
    for (col, col_type) in &columns {
        // R64: parameterise the column-name lookup. The values come from
        // the hard-coded `columns` array above (no untrusted input), so
        // there's no real injection risk, but using `?1` is the form
        // future readers expect.
        let has_col: bool = conn.query_row(
            "SELECT COUNT(*) > 0 FROM pragma_table_info('book_sources') WHERE name = ?1",
            rusqlite::params![col],
            |row| row.get(0),
        )?;
        if !has_col {
            // The DDL itself can't be parameterised (sqlite forbids
            // binding identifiers); the `col` / `col_type` values are
            // hard-coded constants so format! is safe here.
            conn.execute(
                &format!("ALTER TABLE book_sources ADD COLUMN {} {}", col, col_type),
                [],
            )?;
        }
    }
    Ok(())
}

/// 版本 10 迁移：R24 — 重塑 replace_rules 表对齐原 Legado 设计。
///
/// 旧 schema：`scope INTEGER DEFAULT 0`（0/1/2 enum，但 schema 没有
/// 配套的 target 字段，导致 scope=1/2 的规则在 R24 修复前被错误地
/// 全局应用）。
///
/// 新 schema：
///   - `scope TEXT`（nullable）：子串匹配 `book.name` 或 `book.origin`
///   - `scope_title INTEGER DEFAULT 0`：是否作用于章节标题
///   - `scope_content INTEGER DEFAULT 1`：是否作用于正文
///   - `exclude_scope TEXT`（nullable）：排除范围，子串语义同 scope
///
/// 由于 SQLite 不支持 ALTER COLUMN 修改类型，使用"建新表 → 复制
/// 数据 → 删旧表 → 重命名"模式。原 scope=0/1/2 的 enum 信息全部
/// 丢弃成 NULL（全局），因为 schema 里本来就没存"具体哪个书源/书"，
/// 用户原本想限定的对象信息没办法救回。Flutter UI 在用户首次进入
/// 替换规则页面时弹一次 SnackBar 说明。
fn migrate_v10(conn: &Connection) -> SqlResult<()> {
    info!("v10: 重塑 replace_rules 表，对齐原 Legado scope String 设计");

    // 防重跑：如果 scope 列已经是 TEXT 类型，直接跳过。
    let scope_col_type: Option<String> = conn
        .query_row(
            "SELECT type FROM pragma_table_info('replace_rules') WHERE name = 'scope'",
            [],
            |row| row.get(0),
        )
        .ok();
    if scope_col_type.as_deref() == Some("TEXT") {
        debug!("v10: replace_rules.scope 已经是 TEXT，跳过重建");
        return Ok(());
    }

    // 重建表：原表数据 → 新表，scope/exclude_scope 全部 NULL，
    // scope_title=0，scope_content=1（与新建默认值一致）。
    conn.execute(
        "CREATE TABLE replace_rules_new (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            pattern TEXT NOT NULL,
            replacement TEXT NOT NULL,
            enabled INTEGER DEFAULT 1,
            scope TEXT,
            scope_title INTEGER DEFAULT 0,
            scope_content INTEGER DEFAULT 1,
            exclude_scope TEXT,
            sort_number INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;

    let migrated: i64 = conn.query_row(
        "SELECT COUNT(*) FROM replace_rules",
        [],
        |row| row.get(0),
    )?;
    conn.execute(
        "INSERT INTO replace_rules_new
            (id, name, pattern, replacement, enabled, scope,
             scope_title, scope_content, exclude_scope,
             sort_number, created_at, updated_at)
         SELECT id, name, pattern, replacement, enabled, NULL,
                0, 1, NULL,
                sort_number, created_at, updated_at
           FROM replace_rules",
        [],
    )?;
    conn.execute("DROP TABLE replace_rules", [])?;
    conn.execute(
        "ALTER TABLE replace_rules_new RENAME TO replace_rules",
        [],
    )?;
    info!("v10: 迁移 {} 条替换规则", migrated);
    Ok(())
}

/// 版本 11 迁移：补齐 books / bookmarks 字段 + 新增 4 张表
///
/// 批次 6（详见 `.trellis/tasks/05-18-db-schema-migration-batch06/prd.md`）。
///
/// 字段差异详见 `feature-gap-reader-bookshelf-source.md` §5。本批次只补
/// 最高优先级的：
/// - books +5 字段：dur_chapter_index/pos/title/time + group_id
/// - bookmarks +5 字段：book_name/book_author/chapter_pos/chapter_name/book_text
/// - 新表：book_groups / read_records / cookies / rule_subs
///
/// 故意不动 dict_rules / http_tts / txt_toc_rules / search_keywords / rss_*
/// —— 这些等后续依赖批次实现对应功能时再加，避免空表无人用。
///
/// 防御性写法：
/// 1. ALTER 前 `pragma_table_info` 检测列已存在 → 跳过（幂等）
/// 2. ALTER 前先检测表本身存在 → 不存在直接跳过；测试 fixture 里有些
///    精简 schema 没有 books/bookmarks 表（例如只测 replace_rules 迁移），
///    迁移链跑过 v11 时不能因这种缺表崩。
/// 3. CREATE TABLE 都用 `IF NOT EXISTS`
/// 4. 整个迁移由 `migrate_database` 包在 RAII transaction 中，失败回滚
fn migrate_v11(conn: &Connection) -> SqlResult<()> {
    info!("v11: 补齐 books/bookmarks 字段 + 新增 4 张表（批次 6 schema）");

    // books 加 5 列（仅当 books 表存在）
    if table_exists(conn, "books")? {
        let books_columns = [
            ("dur_chapter_index", "INTEGER DEFAULT 0"),
            ("dur_chapter_pos", "INTEGER DEFAULT 0"),
            ("dur_chapter_title", "TEXT"),
            ("dur_chapter_time", "INTEGER DEFAULT 0"),
            ("group_id", "INTEGER DEFAULT 0"),
        ];
        for (col, col_type) in &books_columns {
            let has_col: bool = conn.query_row(
                "SELECT COUNT(*) > 0 FROM pragma_table_info('books') WHERE name = ?1",
                rusqlite::params![col],
                |row| row.get(0),
            )?;
            if !has_col {
                // col / col_type 都是硬编码常量，format! 在此安全（SQLite
                // 禁止用占位符绑定 DDL 标识符）。
                conn.execute(
                    &format!("ALTER TABLE books ADD COLUMN {} {}", col, col_type),
                    [],
                )?;
            }
        }
    }

    // bookmarks 加 5 列（仅当 bookmarks 表存在）
    if table_exists(conn, "bookmarks")? {
        let bookmark_columns = [
            ("book_name", "TEXT"),
            ("book_author", "TEXT"),
            ("chapter_pos", "INTEGER DEFAULT 0"),
            ("chapter_name", "TEXT"),
            ("book_text", "TEXT"),
        ];
        for (col, col_type) in &bookmark_columns {
            let has_col: bool = conn.query_row(
                "SELECT COUNT(*) > 0 FROM pragma_table_info('bookmarks') WHERE name = ?1",
                rusqlite::params![col],
                |row| row.get(0),
            )?;
            if !has_col {
                conn.execute(
                    &format!("ALTER TABLE bookmarks ADD COLUMN {} {}", col, col_type),
                    [],
                )?;
            }
        }
    }

    // 4 张新表 — `IF NOT EXISTS` 保证幂等
    conn.execute(
        "CREATE TABLE IF NOT EXISTS book_groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            sort_order INTEGER DEFAULT 0,
            cover TEXT,
            show INTEGER DEFAULT 1,
            book_sort INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS read_records (
            id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            book_name TEXT NOT NULL,
            read_time INTEGER NOT NULL DEFAULT 0,
            last_read_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS cookies (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            domain TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            path TEXT,
            expires_at INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE(domain, key, path)
        )",
        [],
    )?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS rule_subs (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            url TEXT NOT NULL UNIQUE,
            sub_type INTEGER DEFAULT 0,
            custom_order INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;

    // v11 索引 — 必须在 books 加完 group_id + 4 张新表创建后才能跑
    if table_exists(conn, "books")? {
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_books_group_id ON books(group_id)",
            [],
        )?;
    }
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_book_groups_sort_order ON book_groups(sort_order)",
        [],
    )?;
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_read_records_book_id ON read_records(book_id)",
        [],
    )?;
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_cookies_domain ON cookies(domain)",
        [],
    )?;

    info!("v11: 迁移完成（批次 6 schema）");
    Ok(())
}

/// 版本 12 迁移：批次 16 — RSS 源管理 schema 骨架。
///
/// 新增 4 张表（`rss_sources` / `rss_articles` / `rss_stars` /
/// `rss_read_records`）+ 4 个索引。本批次只先建表 + RssSourceDao；拉取
/// 解析、文章列表、收藏、详情 WebView 留批次 17/18 实装。
///
/// 防御性写法：
/// - 全部 `CREATE TABLE IF NOT EXISTS`（幂等）
/// - 不依赖任何旧表存在（rss_* 是全新独立子系统，不与现有表 FK 关联）
/// - 索引 `IF NOT EXISTS`，重跑不报错
///
/// 字段 / 主键 / 索引设计详见 PRD `.trellis/tasks/05-19-rss-source-mgr-batch16/prd.md`
/// 第 "Schema v12" 段。
fn migrate_v12(conn: &Connection) -> SqlResult<()> {
    info!("v12: 新增 RSS 4 张表（批次 16 schema）");
    create_rss_tables(conn)?;
    create_v12_indices(conn)?;
    info!("v12: 迁移完成（批次 16 schema）");
    Ok(())
}

/// 版本 13 迁移：book_sources 表加 3 列（批次 check-sources / 05-24）
///
/// 对齐原 Legado `CheckSource.kt` 校验结果持久化：
/// - `respond_time INTEGER DEFAULT 0` — 最近一次校验的总耗时（ms）
/// - `last_check_error TEXT` — 最近一次校验的错误信息（成功时为 NULL）
/// - `last_check_at INTEGER DEFAULT 0` — 最近一次校验的 unix 时间戳（秒）
///
/// 防御：每列先 `pragma_table_info` 检测再 ALTER，重跑幂等。
fn migrate_v13(conn: &Connection) -> SqlResult<()> {
    info!("v13: book_sources 加 respond_time / last_check_error / last_check_at（批次 check-sources）");

    // 防御：测试 fixture 可能只有精简 schema 没有 book_sources 表
    // （如 test_migration_from_v9_rebuilds_replace_rules），跳过。
    if !table_exists(conn, "book_sources")? {
        debug!("v13: book_sources 表不存在，跳过列添加");
        return Ok(());
    }

    for (col, col_type) in [
        ("respond_time", "INTEGER DEFAULT 0"),
        ("last_check_error", "TEXT"),
        ("last_check_at", "INTEGER DEFAULT 0"),
    ] {
        let has: bool = conn.query_row(
            "SELECT COUNT(*) > 0 FROM pragma_table_info('book_sources') WHERE name = ?1",
            rusqlite::params![col],
            |r| r.get(0),
        )?;
        if !has {
            conn.execute(
                &format!("ALTER TABLE book_sources ADD COLUMN {} {}", col, col_type),
                [],
            )?;
        }
    }
    info!("v13: 迁移完成（批次 check-sources）");
    Ok(())
}

/// 批次 16 (v12) 4 张 RSS 表 — fresh install + migrate 共用。
///
/// 全 `IF NOT EXISTS`，可重复调用。表结构对齐原 Legado RssSource (31)
/// / RssArticle (11) / RssStar (9) / RssReadRecord (2)，但 RssSource 的
/// 13 个高级字段（jsLib / loginUrl / loginUi / ...）合并塞 custom_info_json，
/// MVP 仅暴露 23 个核心 SQL 列。
fn create_rss_tables(conn: &Connection) -> SqlResult<()> {
    // rss_sources — RSS 源主表（PK = source_url，对齐原 Legado）
    conn.execute(
        "CREATE TABLE IF NOT EXISTS rss_sources (
            source_url TEXT PRIMARY KEY,
            source_name TEXT NOT NULL,
            source_icon TEXT,
            source_group TEXT,
            source_comment TEXT,
            enabled INTEGER DEFAULT 1,
            single_url INTEGER DEFAULT 0,
            sort_url TEXT,
            article_style INTEGER DEFAULT 0,
            rule_articles TEXT,
            rule_next_page TEXT,
            rule_title TEXT,
            rule_pub_date TEXT,
            rule_description TEXT,
            rule_image TEXT,
            rule_link TEXT,
            rule_content TEXT,
            last_update_time INTEGER DEFAULT 0,
            custom_order INTEGER DEFAULT 0,
            enable_js INTEGER DEFAULT 1,
            load_with_base_url INTEGER DEFAULT 1,
            header TEXT,
            custom_info_json TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )",
        [],
    )?;

    // rss_articles — 文章列表 / 已读 / 收藏标记（复合 PK (origin, link)）
    // origin = rss_sources.source_url；不强加 FOREIGN KEY 是为了允许源
    // 删除后历史文章保留（与原 Legado 行为一致）。
    conn.execute(
        "CREATE TABLE IF NOT EXISTS rss_articles (
            origin TEXT NOT NULL,
            sort TEXT,
            title TEXT,
            pub_date TEXT,
            link TEXT NOT NULL,
            image TEXT,
            description TEXT,
            variable TEXT,
            order_num INTEGER DEFAULT 0,
            read_time INTEGER DEFAULT 0,
            star INTEGER DEFAULT 0,
            PRIMARY KEY (origin, link)
        )",
        [],
    )?;

    // rss_stars — 跨源持久收藏（独立于 rss_articles，因为收藏要在源
    // 删除 / 文章列表清理后依旧保留）
    conn.execute(
        "CREATE TABLE IF NOT EXISTS rss_stars (
            origin TEXT NOT NULL,
            source_name TEXT,
            sort TEXT,
            title TEXT,
            pub_date TEXT,
            image TEXT,
            link TEXT NOT NULL,
            description TEXT,
            variable TEXT,
            star_time INTEGER NOT NULL,
            PRIMARY KEY (origin, link)
        )",
        [],
    )?;

    // rss_read_records — 已读记录（按 link 主键，全局去重）
    conn.execute(
        "CREATE TABLE IF NOT EXISTS rss_read_records (
            link TEXT PRIMARY KEY,
            record_time INTEGER,
            read_time INTEGER
        )",
        [],
    )?;

    Ok(())
}

/// 批次 16 (v12) 索引 — fresh install + migrate 共用。
fn create_v12_indices(conn: &Connection) -> SqlResult<()> {
    if table_exists(conn, "rss_sources")? {
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_rss_sources_group ON rss_sources(source_group)",
            [],
        )?;
    }
    if table_exists(conn, "rss_articles")? {
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_rss_articles_origin_sort \
             ON rss_articles(origin, sort)",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_rss_articles_unread ON rss_articles(read_time)",
            [],
        )?;
    }
    if table_exists(conn, "rss_stars")? {
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_rss_stars_time ON rss_stars(star_time DESC)",
            [],
        )?;
    }
    Ok(())
}

/// 检查指定表是否存在。批次 6 v11 迁移防御性使用。
fn table_exists(conn: &Connection, table: &str) -> SqlResult<bool> {
    conn.query_row(
        "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name = ?1",
        rusqlite::params![table],
        |row| row.get(0),
    )
}

/// 获取数据库连接（便捷函数）
///
/// 与 [`init_database`] 配对：每条 fresh 连接都重设 `foreign_keys` 与
/// `synchronous`（PRAGMA 是连接级，新连接默认会回到 FULL，必须显式调到
/// NORMAL 才有 WAL 持久性收益）。`wal_autocheckpoint` 默认值就是目标
/// 1000，仅 init 设一次，这里不重设以省一次 round-trip。
pub fn get_connection(db_path: &str) -> SqlResult<Connection> {
    let conn = Connection::open(db_path)?;
    conn.execute("PRAGMA foreign_keys = ON", [])?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    Ok(conn)
}

/// 执行 SQL 文件（用于初始化或迁移）
pub fn execute_sql_file(conn: &Connection, sql: &str) -> SqlResult<()> {
    conn.execute_batch(sql)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// F-W1A-055（BATCH-08c）：验证 init_database 启用 WAL。
    /// SQLite 返回的 mode 字符串小写 "wal"，需 case-insensitive 比较。
    #[test]
    fn test_wal_enabled_on_fresh_init() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("wal_fresh.db")
            .to_string_lossy()
            .to_string();

        let conn = init_database(&db_path).unwrap();
        let mode: String = conn
            .pragma_query_value(None, "journal_mode", |row| row.get(0))
            .unwrap();
        assert_eq!(
            mode.to_lowercase(),
            "wal",
            "fresh init_database should enable WAL"
        );
    }

    /// F-W1A-055（BATCH-08c）：验证 WAL 是 db 文件级持久化的。
    /// init_database 调一次后，第二次直接 `Connection::open`（不走
    /// init_database，模拟 get_connection / r2d2 pool / js_runtime 直调
    /// `Connection::open` 的下游路径）拿到的连接也应是 WAL 模式。
    /// 这是"WAL 是 db-level"假设在我们代码里的间接保护测试。
    #[test]
    fn test_wal_persists_across_reopens() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("wal_persist.db")
            .to_string_lossy()
            .to_string();

        // 第一次：调 init_database 启用 WAL，drop 第一条连接
        {
            let _ = init_database(&db_path).unwrap();
        }

        // 第二次：不走 init_database，直接 Connection::open
        let conn2 = rusqlite::Connection::open(&db_path).unwrap();
        let mode: String = conn2
            .pragma_query_value(None, "journal_mode", |row| row.get(0))
            .unwrap();
        assert_eq!(
            mode.to_lowercase(),
            "wal",
            "WAL is db-file level — second open without init_database must still see WAL"
        );
    }

    #[test]
    fn test_database_init() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test.db")
            .to_string_lossy()
            .to_string();

        let conn = init_database(&db_path).unwrap();

        // 验证表是否存在（含 sync_log）
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table'",
                [],
                |row| row.get(0),
            )
            .unwrap();

        assert!(count >= 8); // 至少 8 个表（含 sync_log）

        let version = get_db_version(&conn).unwrap();
        assert_eq!(version, DB_VERSION);

        let has_book_url: bool = conn
            .query_row(
                "SELECT COUNT(*) > 0 FROM pragma_table_info('books') WHERE name = 'book_url'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(has_book_url, "fresh database should include book_url");
    }

    #[test]
    fn test_migration_from_v3_adds_book_url() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_migrate_v3.db")
            .to_string_lossy()
            .to_string();

        let conn = Connection::open(&db_path).unwrap();
        conn.execute("PRAGMA foreign_keys = ON", []).unwrap();
        conn.execute(
            "CREATE TABLE books (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                source_name TEXT,
                name TEXT NOT NULL,
                author TEXT,
                cover_url TEXT,
                chapter_count INTEGER DEFAULT 0,
                latest_chapter_title TEXT,
                intro TEXT,
                kind TEXT,
                last_check_time INTEGER,
                last_check_count INTEGER DEFAULT 0,
                total_word_count INTEGER DEFAULT 0,
                can_update INTEGER DEFAULT 1,
                order_time INTEGER NOT NULL,
                latest_chapter_time INTEGER,
                custom_cover_path TEXT,
                custom_info_json TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )",
            [],
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 3_i32).unwrap();
        drop(conn);

        let migrated = init_database(&db_path).unwrap();
        let has_book_url: bool = migrated
            .query_row(
                "SELECT COUNT(*) > 0 FROM pragma_table_info('books') WHERE name = 'book_url'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(has_book_url, "v3 migration should add book_url");

        let version = get_db_version(&migrated).unwrap();
        assert_eq!(version, DB_VERSION);
    }

    #[test]
    fn test_migration_from_v1_to_v2() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_migrate.db")
            .to_string_lossy()
            .to_string();

        // 创建 v1 数据库
        let conn = Connection::open(&db_path).unwrap();
        conn.execute("PRAGMA foreign_keys = ON", []).unwrap();
        // Simulate a v1-era schema by creating tables and then dropping sync_log
        // which was added in v2 migration.
        create_tables(&conn).unwrap();
        conn.execute("DROP TABLE IF EXISTS sync_log", []).unwrap();
        conn.pragma_update(None, "user_version", 1_i32).unwrap();
        drop(conn);

        // 重新打开，触发迁移
        let conn2 = init_database(&db_path).unwrap();

        // 验证 v2 有 sync_log 表
        let has_sync_log: bool = conn2
            .query_row(
                "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='sync_log'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(has_sync_log, "v2 should have sync_log table");

        // 验证版本号
        let version = get_db_version(&conn2).unwrap();
        assert_eq!(version, DB_VERSION);
    }

    #[test]
    fn test_book_dao_crud() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_book_dao.db")
            .to_string_lossy()
            .to_string();
        let conn = init_database(&db_path).unwrap();
        // Insert required book_source for foreign key constraint
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params!["source1", "Test Source", "https://example.com", chrono::Utc::now().timestamp(), chrono::Utc::now().timestamp()],
        ).unwrap();
        let dao = crate::book_dao::BookDao::new(&conn);

        let book = dao
            .create("source1", Some("Test Source"), "Test Book", Some("Author"))
            .unwrap();
        assert_eq!(book.name, "Test Book");
        assert_eq!(book.source_id, "source1");

        let retrieved = dao.get_by_id(&book.id).unwrap().unwrap();
        assert_eq!(retrieved.author.as_deref(), Some("Author"));

        let mut updated = book.clone();
        updated.name = "Updated Book".to_string();
        updated.author = Some("New Author".to_string());
        dao.upsert(&updated).unwrap();
        let r2 = dao.get_by_id(&book.id).unwrap().unwrap();
        assert_eq!(r2.name, "Updated Book");

        assert_eq!(dao.get_all().unwrap().len(), 1);
        assert_eq!(dao.search("Updated").unwrap().len(), 1);
        assert_eq!(dao.get_by_source("source1").unwrap().len(), 1);

        dao.delete(&book.id).unwrap();
        assert!(dao.get_by_id(&book.id).unwrap().is_none());
    }

    #[test]
    fn test_source_dao_crud() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_source_dao.db")
            .to_string_lossy()
            .to_string();
        let mut conn = init_database(&db_path).unwrap();
        let dao = crate::source_dao::SourceDao::new(&mut conn);

        let source = dao.create("Test Source", "https://example.com").unwrap();
        assert_eq!(source.name, "Test Source");

        let retrieved = dao.get_by_id(&source.id).unwrap().unwrap();
        assert_eq!(retrieved.url, "https://example.com");

        assert_eq!(dao.get_enabled().unwrap().len(), 1);

        dao.set_enabled(&source.id, false).unwrap();
        assert!(!dao.get_by_id(&source.id).unwrap().unwrap().enabled);

        dao.delete(&source.id).unwrap();
        assert!(dao.get_by_id(&source.id).unwrap().is_none());
    }

    #[test]
    fn test_source_dao_batch_insert() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_batch.db")
            .to_string_lossy()
            .to_string();
        let mut conn = init_database(&db_path).unwrap();
        let mut dao = crate::source_dao::SourceDao::new(&mut conn);
        let now = chrono::Utc::now().timestamp();
        let sources = vec![
            crate::models::BookSource {
                id: "bs1".into(),
                name: "Source 1".into(),
                url: "https://s1.com".into(),
                source_type: 0,
                group_name: None,
                enabled: true,
                custom_order: 0,
                weight: 0,
                rule_search: None,
                rule_book_info: None,
                rule_toc: None,
                rule_content: None,
                login_url: None,
                login_ui: None,
                login_check_js: None,
                header: None,
                js_lib: None,
                cover_decode_js: None,
                book_url_pattern: None,
                rule_explore: None,
                explore_url: None,
                enabled_explore: true,
                last_update_time: 0,
                book_source_comment: None,
                concurrent_rate: None,
                variable_comment: None,
                explore_screen: None,
                respond_time: 0,
                last_check_error: None,
                last_check_at: 0,
                created_at: now,
                updated_at: now,
            },
            crate::models::BookSource {
                id: "bs2".into(),
                name: "Source 2".into(),
                url: "https://s2.com".into(),
                source_type: 0,
                group_name: None,
                enabled: true,
                custom_order: 0,
                weight: 0,
                rule_search: None,
                rule_book_info: None,
                rule_toc: None,
                rule_content: None,
                login_url: None,
                login_ui: None,
                login_check_js: None,
                header: None,
                js_lib: None,
                cover_decode_js: None,
                book_url_pattern: None,
                rule_explore: None,
                explore_url: None,
                enabled_explore: true,
                last_update_time: 0,
                book_source_comment: None,
                concurrent_rate: None,
                variable_comment: None,
                explore_screen: None,
                respond_time: 0,
                last_check_error: None,
                last_check_at: 0,
                created_at: now,
                updated_at: now,
            },
        ];
        dao.batch_insert(&sources).unwrap();
        let all = dao.get_all().unwrap();
        assert_eq!(all.len(), 2);
        assert!(all.iter().any(|s| s.name == "Source 1"));
        assert!(all.iter().any(|s| s.name == "Source 2"));
    }

    #[test]
    fn test_source_dao_import_from_json() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_import.db")
            .to_string_lossy()
            .to_string();
        let mut conn = init_database(&db_path).unwrap();
        let mut dao = crate::source_dao::SourceDao::new(&mut conn);
        let json = r#"[{"id":"ij1","name":"Imported","url":"https://imp.com","source_type":0,"enabled":true,"custom_order":0,"weight":0,"rule_search":null,"rule_book_info":null,"rule_toc":null,"rule_content":null,"login_url":null,"header":null,"js_lib":null,"created_at":0,"updated_at":0}]"#;
        let count = dao.import_from_json(json).unwrap();
        assert_eq!(count, 1);
        let all = dao.get_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].name, "Imported");
    }

    #[test]
    fn test_chapter_dao_crud() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_chapter_dao.db")
            .to_string_lossy()
            .to_string();
        let mut conn = init_database(&db_path).unwrap();
        // Insert required book_source for foreign key constraint
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params!["src1", "Test", "https://example.com", chrono::Utc::now().timestamp(), chrono::Utc::now().timestamp()],
        ).unwrap();
        // Take a short-lived &conn borrow for BookDao, then drop it so we
        // can re-borrow as &mut for ChapterDao (R77: ChapterDao now needs
        // &mut Connection to open transactions internally).
        let book = {
            let book_dao = crate::book_dao::BookDao::new(&conn);
            book_dao.create("src1", None, "Book", None).unwrap()
        };

        let dao = crate::chapter_dao::ChapterDao::new(&mut conn);
        let chapter = dao
            .create(&book.id, 0, "Chapter 1", "https://example.com/ch1")
            .unwrap();
        assert_eq!(chapter.title, "Chapter 1");

        let retrieved = dao.get_by_id(&chapter.id).unwrap().unwrap();
        assert_eq!(retrieved.index_num, 0);

        dao.update_content(&chapter.id, "New content").unwrap();
        assert_eq!(
            dao.get_by_id(&chapter.id)
                .unwrap()
                .unwrap()
                .content
                .as_deref(),
            Some("New content")
        );

        assert_eq!(dao.get_by_book(&book.id).unwrap().len(), 1);

        dao.delete(&chapter.id).unwrap();
        assert!(dao.get_by_id(&chapter.id).unwrap().is_none());
    }

    #[test]
    fn test_progress_dao_crud() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_progress_dao.db")
            .to_string_lossy()
            .to_string();
        let conn = init_database(&db_path).unwrap();
        // Insert required book_source for foreign key constraint
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params!["src2", "Test", "https://example.com", chrono::Utc::now().timestamp(), chrono::Utc::now().timestamp()],
        ).unwrap();
        let book_dao = crate::book_dao::BookDao::new(&conn);
        let book = book_dao.create("src2", None, "Book", None).unwrap();

        let dao = crate::progress_dao::ProgressDao::new(&conn);
        dao.update_progress(&book.id, 3, 10, 500).unwrap();
        let progress = dao.get_by_book(&book.id).unwrap().unwrap();
        assert_eq!(progress.chapter_index, 3);
        assert_eq!(progress.paragraph_index, 10);

        let bookmark = dao.create_bookmark(&book.id, 3, 10, Some("Great")).unwrap();
        assert_eq!(dao.get_bookmarks(&book.id).unwrap().len(), 1);
        assert_eq!(
            dao.get_bookmarks(&book.id).unwrap()[0].content.as_deref(),
            Some("Great")
        );

        dao.delete_bookmark(&bookmark.id).unwrap();
        assert_eq!(dao.get_bookmarks(&book.id).unwrap().len(), 0);

        // 批次 08 (BATCH-08 / F-W1A-018): 之前调 `progress_dao.delete(book_id)`
        // 显式清进度；该 fn 因 0 caller 已删除，现在依赖 SQLite FK CASCADE
        // —— 删 book 时 `book_progress.book_id` 外键自动清理对应行。
        let book_dao = crate::book_dao::BookDao::new(&conn);
        book_dao.delete(&book.id).unwrap();
        assert!(dao.get_by_book(&book.id).unwrap().is_none());
    }

    #[test]
    fn test_replace_rule_dao_crud() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_replace_rule_dao.db")
            .to_string_lossy()
            .to_string();
        let conn = init_database(&db_path).unwrap();
        let dao = crate::replace_rule_dao::ReplaceRuleDao::new(&conn);

        let rule = dao.create("Test Rule", r"\d+", "NUM").unwrap();
        assert_eq!(rule.name, "Test Rule");
        assert!(rule.enabled);
        // R24: 默认创建是全局正文规则
        assert!(rule.scope.is_none());
        assert!(!rule.scope_title);
        assert!(rule.scope_content);

        let retrieved = dao.get_by_id(&rule.id).unwrap().unwrap();
        assert_eq!(retrieved.pattern, r"\d+");

        assert_eq!(dao.get_all().unwrap().len(), 1);
        assert_eq!(dao.get_enabled().unwrap().len(), 1);

        dao.set_enabled(&rule.id, false).unwrap();
        assert!(!dao.get_by_id(&rule.id).unwrap().unwrap().enabled);
        assert!(dao.get_enabled().unwrap().is_empty());

        dao.update_order(&rule.id, 5).unwrap();
        assert_eq!(dao.get_by_id(&rule.id).unwrap().unwrap().sort_number, 5);

        dao.delete(&rule.id).unwrap();
        assert!(dao.get_by_id(&rule.id).unwrap().is_none());
    }

    /// Regression for the upsert ON CONFLICT bug: when re-upserting an
    /// existing source the DO UPDATE SET list previously omitted login_ui /
    /// login_check_js / cover_decode_js, so changes to those columns were
    /// silently dropped. Both upsert paths now share `SOURCE_UPSERT_SQL`.
    #[test]
    fn test_source_dao_upsert_updates_all_columns() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_source_dao_upsert_all.db")
            .to_string_lossy()
            .to_string();
        let mut conn = init_database(&db_path).unwrap();
        let now = chrono::Utc::now().timestamp();
        let mut source = crate::models::BookSource {
            id: "upsert-all".into(),
            name: "Initial".into(),
            url: "https://upsert-all.example".into(),
            source_type: 0,
            group_name: None,
            enabled: true,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_content: None,
            login_url: Some("https://upsert-all.example/login".into()),
            login_ui: Some("ui v1".into()),
            login_check_js: Some("check v1".into()),
            header: None,
            js_lib: None,
            cover_decode_js: Some("cover v1".into()),
            book_url_pattern: None,
            rule_explore: None,
            explore_url: None,
            enabled_explore: true,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            respond_time: 0,
            last_check_error: None,
            last_check_at: 0,
            created_at: now,
            updated_at: now,
        };
        {
            let dao = crate::source_dao::SourceDao::new(&mut conn);
            dao.upsert(&source).unwrap();
        }

        // Re-upsert with new values; before the fix login_ui / login_check_js /
        // cover_decode_js would still hold the original v1 strings.
        source.name = "Updated".into();
        source.login_ui = Some("ui v2".into());
        source.login_check_js = Some("check v2".into());
        source.cover_decode_js = Some("cover v2".into());
        {
            let dao = crate::source_dao::SourceDao::new(&mut conn);
            dao.upsert(&source).unwrap();
        }

        let fetched = {
            let dao = crate::source_dao::SourceDao::new(&mut conn);
            dao.get_by_id("upsert-all").unwrap().unwrap()
        };
        assert_eq!(fetched.name, "Updated");
        assert_eq!(fetched.login_ui.as_deref(), Some("ui v2"));
        assert_eq!(fetched.login_check_js.as_deref(), Some("check v2"));
        assert_eq!(fetched.cover_decode_js.as_deref(), Some("cover v2"));
    }

    /// BATCH-27e: SourceDao::find_for_book_url - baseUrl 前缀匹配。
    #[test]
    fn test_source_dao_find_for_book_url_base_url_match() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_find_base.db")
            .to_string_lossy()
            .to_string();
        let mut conn = init_database(&db_path).unwrap();
        let dao = crate::source_dao::SourceDao::new(&mut conn);

        let s1 = dao.create("Site A", "https://a.example.com/").unwrap();
        let _s2 = dao.create("Site B", "https://b.example.com/").unwrap();

        let m = dao
            .find_for_book_url("https://a.example.com/book/123")
            .unwrap();
        assert!(m.is_some());
        assert_eq!(m.unwrap().id, s1.id);

        // 不匹配任何源
        let none = dao.find_for_book_url("https://other.com/x").unwrap();
        assert!(none.is_none());

        // 空 url 返回 None
        let none2 = dao.find_for_book_url("   ").unwrap();
        assert!(none2.is_none());
    }

    /// BATCH-27e: SourceDao::find_for_book_url - book_url_pattern regex 兜底。
    #[test]
    fn test_source_dao_find_for_book_url_pattern_match() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_find_pattern.db")
            .to_string_lossy()
            .to_string();
        let mut conn = init_database(&db_path).unwrap();
        let dao = crate::source_dao::SourceDao::new(&mut conn);

        // s1: 没 pattern，baseUrl https://x/ — 不匹配 https://y/abc
        let _s1 = dao.create("Site X", "https://x.example.com/").unwrap();
        // s2: 有 pattern，baseUrl https://y/ + book_url_pattern 匹配 /abc 系列
        let mut s2 = dao.create("Site Y", "https://y.example.com/").unwrap();
        s2.book_url_pattern = Some(r"^https://y\.example\.com/book/\d+$".to_string());
        dao.upsert(&s2).unwrap();
        // s3: regex 损坏，应静默跳过（不抛 error）
        let mut s3 = dao.create("Broken", "https://broken.example.com/").unwrap();
        s3.book_url_pattern = Some("[invalid(regex".to_string());
        dao.upsert(&s3).unwrap();

        let m = dao
            .find_for_book_url("https://y.example.com/book/42")
            .unwrap();
        assert!(m.is_some(), "regex pattern should match");
        assert_eq!(m.unwrap().id, s2.id);

        // 不匹配任何 baseUrl 也不匹配任何 pattern → None
        let none = dao
            .find_for_book_url("https://nowhere.com/book/1")
            .unwrap();
        assert!(none.is_none());
    }

    /// R24: v10 migration rebuilds replace_rules with `scope TEXT` (was
    /// `scope INTEGER`) and adds scope_title / scope_content /
    /// exclude_scope columns. Old scope=1/2 enum values are dropped to
    /// NULL because schema never stored what they pointed at.
    #[test]
    fn test_migration_from_v9_rebuilds_replace_rules() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_migrate_v10.db")
            .to_string_lossy()
            .to_string();

        // Build a v9-shape replace_rules table with mixed scope values.
        {
            let conn = Connection::open(&db_path).unwrap();
            conn.execute("PRAGMA foreign_keys = ON", []).unwrap();
            conn.execute(
                "CREATE TABLE replace_rules (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    pattern TEXT NOT NULL,
                    replacement TEXT NOT NULL,
                    enabled INTEGER DEFAULT 1,
                    scope INTEGER DEFAULT 0,
                    sort_number INTEGER DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )",
                [],
            )
            .unwrap();
            for (id, scope) in [("rule0", 0), ("rule1", 1), ("rule2", 2)] {
                conn.execute(
                    "INSERT INTO replace_rules
                        (id, name, pattern, replacement, enabled, scope,
                         sort_number, created_at, updated_at)
                     VALUES (?, 'test', 'x', 'y', 1, ?, 0, 0, 0)",
                    rusqlite::params![id, scope],
                )
                .unwrap();
            }
            conn.pragma_update(None, "user_version", 9_i32).unwrap();
        }

        // Run the migration.
        let migrated = init_database(&db_path).unwrap();
        let version = get_db_version(&migrated).unwrap();
        assert_eq!(version, DB_VERSION);

        // scope column should now be TEXT and all rows should have
        // scope=NULL, scope_title=0, scope_content=1, exclude_scope=NULL.
        let scope_type: String = migrated
            .query_row(
                "SELECT type FROM pragma_table_info('replace_rules') WHERE name = 'scope'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(scope_type, "TEXT");

        let count: i64 = migrated
            .query_row(
                "SELECT COUNT(*) FROM replace_rules WHERE scope IS NULL
                 AND scope_title = 0 AND scope_content = 1
                 AND exclude_scope IS NULL",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 3, "all 3 rules should be migrated to global");
    }

    // ============================================================
    // 批次 6 (v11) 迁移测试 — schema 补齐 + 4 张新表
    // ============================================================

    /// 构造一个"v10 形态"的数据库（只有 v10 schema，user_version=10）。
    /// books / bookmarks 没有批次 6 (v11) 新增的字段；book_groups /
    /// read_records / cookies / rule_subs 都不存在。
    /// 用于 v11 迁移测试。
    fn build_v10_schema(db_path: &str) {
        let conn = Connection::open(db_path).unwrap();
        conn.execute("PRAGMA foreign_keys = ON", []).unwrap();
        // app_settings + book_sources（FK 目标）+ books + bookmarks
        conn.execute(
            "CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            [],
        )
        .unwrap();
        conn.execute(
            "CREATE TABLE book_sources (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                url TEXT NOT NULL UNIQUE,
                source_type INTEGER DEFAULT 0,
                group_name TEXT,
                enabled INTEGER DEFAULT 1,
                custom_order INTEGER DEFAULT 0,
                weight INTEGER DEFAULT 0,
                rule_search TEXT,
                rule_book_info TEXT,
                rule_toc TEXT,
                rule_content TEXT,
                login_url TEXT,
                login_ui TEXT,
                login_check_js TEXT,
                header TEXT,
                js_lib TEXT,
                cover_decode_js TEXT,
                book_url_pattern TEXT,
                rule_explore TEXT,
                explore_url TEXT,
                enabled_explore INTEGER DEFAULT 1,
                last_update_time INTEGER DEFAULT 0,
                book_source_comment TEXT,
                concurrent_rate TEXT,
                variable_comment TEXT,
                explore_screen INTEGER,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )",
            [],
        )
        .unwrap();
        // books v10 schema — 没有 dur_chapter_*/group_id
        conn.execute(
            "CREATE TABLE books (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                source_name TEXT,
                name TEXT NOT NULL,
                author TEXT,
                cover_url TEXT,
                chapter_count INTEGER DEFAULT 0,
                latest_chapter_title TEXT,
                intro TEXT,
                kind TEXT,
                book_url TEXT,
                toc_url TEXT,
                last_check_time INTEGER,
                last_check_count INTEGER DEFAULT 0,
                total_word_count INTEGER DEFAULT 0,
                can_update INTEGER DEFAULT 1,
                order_time INTEGER NOT NULL,
                latest_chapter_time INTEGER,
                custom_cover_path TEXT,
                custom_info_json TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                FOREIGN KEY (source_id) REFERENCES book_sources(id)
            )",
            [],
        )
        .unwrap();
        // bookmarks v10 schema — 没有 book_name/book_author/chapter_pos/chapter_name/book_text
        conn.execute(
            "CREATE TABLE bookmarks (
                id TEXT PRIMARY KEY,
                book_id TEXT NOT NULL,
                chapter_index INTEGER NOT NULL,
                paragraph_index INTEGER DEFAULT 0,
                content TEXT,
                created_at INTEGER NOT NULL,
                FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
            )",
            [],
        )
        .unwrap();
        // 其他批次没碰的 v10 表 — 测试只关心 books/bookmarks，
        // 但要保证 init_database 走完整的 migrate 链不会因缺表崩。
        // 直接创建一个 user_version=10 的最小 schema 即可。
        conn.pragma_update(None, "user_version", 10_i32).unwrap();
    }

    /// v10 → v11 迁移：books 表加 5 列（dur_chapter_index/pos/title/time +
    /// group_id），旧数据保留，新列为默认值。
    #[test]
    fn test_migrate_v11_adds_book_columns() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_migrate_v11_books.db")
            .to_string_lossy()
            .to_string();

        build_v10_schema(&db_path);

        // 在 v10 schema 上插入 1 个书源 + 1 本书
        {
            let conn = Connection::open(&db_path).unwrap();
            conn.execute(
                "INSERT INTO book_sources (id, name, url, created_at, updated_at)
                 VALUES ('src1', 'Test', 'https://t.example', 0, 0)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO books (id, source_id, name, order_time, created_at, updated_at)
                 VALUES ('book1', 'src1', 'Old Book', 100, 0, 0)",
                [],
            )
            .unwrap();
        }

        // 跑 v11 迁移
        let migrated = init_database(&db_path).unwrap();
        assert_eq!(get_db_version(&migrated).unwrap(), DB_VERSION);

        // 5 个新列都存在
        for col in &[
            "dur_chapter_index",
            "dur_chapter_pos",
            "dur_chapter_title",
            "dur_chapter_time",
            "group_id",
        ] {
            let has_col: bool = migrated
                .query_row(
                    "SELECT COUNT(*) > 0 FROM pragma_table_info('books') WHERE name = ?1",
                    rusqlite::params![col],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(has_col, "books should have {} column after v11", col);
        }

        // 旧数据保留 + 新字段为默认值（0 / NULL）
        let (name, dur_idx, dur_pos, dur_title, dur_time, group_id): (
            String,
            i32,
            i32,
            Option<String>,
            i64,
            i64,
        ) = migrated
            .query_row(
                "SELECT name, dur_chapter_index, dur_chapter_pos, dur_chapter_title,
                        dur_chapter_time, group_id FROM books WHERE id = 'book1'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(name, "Old Book");
        assert_eq!(dur_idx, 0);
        assert_eq!(dur_pos, 0);
        assert!(dur_title.is_none());
        assert_eq!(dur_time, 0);
        assert_eq!(group_id, 0);
    }

    /// v10 → v11 迁移：bookmarks 表加 5 列。
    #[test]
    fn test_migrate_v11_adds_bookmark_columns() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_migrate_v11_bookmarks.db")
            .to_string_lossy()
            .to_string();

        build_v10_schema(&db_path);

        // 在 v10 schema 上插入 1 个书签
        {
            let conn = Connection::open(&db_path).unwrap();
            conn.execute(
                "INSERT INTO book_sources (id, name, url, created_at, updated_at)
                 VALUES ('src1', 'Test', 'https://t.example', 0, 0)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO books (id, source_id, name, order_time, created_at, updated_at)
                 VALUES ('book1', 'src1', 'Book', 0, 0, 0)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO bookmarks (id, book_id, chapter_index, content, created_at)
                 VALUES ('bm1', 'book1', 5, 'note', 0)",
                [],
            )
            .unwrap();
        }

        let migrated = init_database(&db_path).unwrap();
        assert_eq!(get_db_version(&migrated).unwrap(), DB_VERSION);

        for col in &[
            "book_name",
            "book_author",
            "chapter_pos",
            "chapter_name",
            "book_text",
        ] {
            let has_col: bool = migrated
                .query_row(
                    "SELECT COUNT(*) > 0 FROM pragma_table_info('bookmarks') WHERE name = ?1",
                    rusqlite::params![col],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(has_col, "bookmarks should have {} column after v11", col);
        }

        // 旧书签 content 保留，新字段为默认值
        let (content, chapter_pos, book_name): (Option<String>, i32, Option<String>) = migrated
            .query_row(
                "SELECT content, chapter_pos, book_name FROM bookmarks WHERE id = 'bm1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(content.as_deref(), Some("note"));
        assert_eq!(chapter_pos, 0);
        assert!(book_name.is_none());
    }

    /// v10 → v11 迁移：4 张新表必须存在且可读写。
    #[test]
    fn test_migrate_v11_creates_new_tables() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_migrate_v11_new_tables.db")
            .to_string_lossy()
            .to_string();

        build_v10_schema(&db_path);

        let migrated = init_database(&db_path).unwrap();
        assert_eq!(get_db_version(&migrated).unwrap(), DB_VERSION);

        // 4 张表都在 sqlite_master 里
        for table in &["book_groups", "read_records", "cookies", "rule_subs"] {
            let exists: bool = migrated
                .query_row(
                    "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    rusqlite::params![table],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(exists, "table {} should exist after v11", table);
        }

        // 每张表都能 INSERT + SELECT（基本 schema 完整性）
        let now = chrono::Utc::now().timestamp();
        migrated
            .execute(
                "INSERT INTO book_groups (name, sort_order, show, book_sort, created_at, updated_at)
                 VALUES ('全部', 0, 1, 0, ?1, ?1)",
                rusqlite::params![now],
            )
            .unwrap();
        let group_count: i64 = migrated
            .query_row("SELECT COUNT(*) FROM book_groups", [], |row| row.get(0))
            .unwrap();
        assert_eq!(group_count, 1);

        migrated
            .execute(
                "INSERT INTO read_records (id, book_id, book_name, read_time, last_read_at, created_at, updated_at)
                 VALUES ('r1', 'book1', 'Test', 60, ?1, ?1, ?1)",
                rusqlite::params![now],
            )
            .unwrap();
        let rr_count: i64 = migrated
            .query_row("SELECT COUNT(*) FROM read_records", [], |row| row.get(0))
            .unwrap();
        assert_eq!(rr_count, 1);

        migrated
            .execute(
                "INSERT INTO cookies (domain, key, value, path, expires_at, created_at, updated_at)
                 VALUES ('example.com', 'sid', 'abc', '/', NULL, ?1, ?1)",
                rusqlite::params![now],
            )
            .unwrap();
        let cookie_count: i64 = migrated
            .query_row("SELECT COUNT(*) FROM cookies", [], |row| row.get(0))
            .unwrap();
        assert_eq!(cookie_count, 1);

        migrated
            .execute(
                "INSERT INTO rule_subs (id, name, url, sub_type, custom_order, created_at, updated_at)
                 VALUES ('rs1', 'sub', 'https://sub.example', 0, 0, ?1, ?1)",
                rusqlite::params![now],
            )
            .unwrap();
        let rs_count: i64 = migrated
            .query_row("SELECT COUNT(*) FROM rule_subs", [], |row| row.get(0))
            .unwrap();
        assert_eq!(rs_count, 1);
    }

    /// v11 迁移幂等：重复 invoke 不报错（pragma_table_info 检测 + IF NOT EXISTS）。
    /// 模拟：先正常迁移到 v11，然后手动调用 migrate_v11 一次再确认表/列都正常。
    #[test]
    fn test_migrate_v11_idempotent() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_migrate_v11_idempotent.db")
            .to_string_lossy()
            .to_string();

        // 第一次：v10 → v11 迁移
        build_v10_schema(&db_path);
        let conn = init_database(&db_path).unwrap();
        assert_eq!(get_db_version(&conn).unwrap(), DB_VERSION);

        // 直接重跑 migrate_v11 — 不能报错，列/表都还在
        migrate_v11(&conn).unwrap();

        let has_dur_idx: bool = conn
            .query_row(
                "SELECT COUNT(*) > 0 FROM pragma_table_info('books') WHERE name = 'dur_chapter_index'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(has_dur_idx);

        let table_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN \
                 ('book_groups', 'read_records', 'cookies', 'rule_subs')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(table_count, 4);
    }

    /// 首装路径：fresh init 直接进 v11，schema 应该完整（包括 books 新字段
    /// + 4 张新表 + cookies UNIQUE 约束）。
    #[test]
    fn test_fresh_install_has_v11_schema() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_fresh_v11.db")
            .to_string_lossy()
            .to_string();

        let conn = init_database(&db_path).unwrap();
        assert_eq!(get_db_version(&conn).unwrap(), DB_VERSION);

        // books 新列
        let has_group_id: bool = conn
            .query_row(
                "SELECT COUNT(*) > 0 FROM pragma_table_info('books') WHERE name = 'group_id'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(has_group_id, "fresh v11 books should have group_id");

        // 4 张新表
        for table in &["book_groups", "read_records", "cookies", "rule_subs"] {
            let exists: bool = conn
                .query_row(
                    "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name = ?1",
                    rusqlite::params![table],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(exists, "fresh v11 should have {} table", table);
        }

        // cookies UNIQUE(domain, key, path) 约束生效
        let now = chrono::Utc::now().timestamp();
        conn.execute(
            "INSERT INTO cookies (domain, key, value, path, created_at, updated_at)
             VALUES ('a.com', 'k', 'v1', '/', ?1, ?1)",
            rusqlite::params![now],
        )
        .unwrap();
        let dup = conn.execute(
            "INSERT INTO cookies (domain, key, value, path, created_at, updated_at)
             VALUES ('a.com', 'k', 'v2', '/', ?1, ?1)",
            rusqlite::params![now],
        );
        assert!(dup.is_err(), "duplicate (domain,key,path) should fail");

        // rule_subs.url UNIQUE 约束生效
        conn.execute(
            "INSERT INTO rule_subs (id, name, url, created_at, updated_at)
             VALUES ('rs1', 'sub', 'https://s.example', ?1, ?1)",
            rusqlite::params![now],
        )
        .unwrap();
        let dup = conn.execute(
            "INSERT INTO rule_subs (id, name, url, created_at, updated_at)
             VALUES ('rs2', 'sub2', 'https://s.example', ?1, ?1)",
            rusqlite::params![now],
        );
        assert!(dup.is_err(), "duplicate rule_subs.url should fail");
    }

    /// 通过 BookDao 上层 API 验证新字段读写正常 — 防 SELECT/INSERT 列错位。
    #[test]
    fn test_book_dao_persists_v11_fields() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_book_dao_v11.db")
            .to_string_lossy()
            .to_string();
        let conn = init_database(&db_path).unwrap();
        // FK 目标
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at)
             VALUES ('src', 's', 'https://x', 0, 0)",
            [],
        )
        .unwrap();
        let dao = crate::book_dao::BookDao::new(&conn);
        let mut book = dao.create("src", None, "Book", None).unwrap();
        // 默认值
        assert_eq!(book.dur_chapter_index, 0);
        assert_eq!(book.dur_chapter_pos, 0);
        assert!(book.dur_chapter_title.is_none());
        assert_eq!(book.dur_chapter_time, 0);
        assert_eq!(book.group_id, 0);

        // 改并 upsert，再读出来
        book.dur_chapter_index = 12;
        book.dur_chapter_pos = 345;
        book.dur_chapter_title = Some("第 12 章".into());
        book.dur_chapter_time = 1_700_000_000;
        book.group_id = 7;
        dao.upsert(&book).unwrap();
        let r = dao.get_by_id(&book.id).unwrap().unwrap();
        assert_eq!(r.dur_chapter_index, 12);
        assert_eq!(r.dur_chapter_pos, 345);
        assert_eq!(r.dur_chapter_title.as_deref(), Some("第 12 章"));
        assert_eq!(r.dur_chapter_time, 1_700_000_000);
        assert_eq!(r.group_id, 7);
    }

    /// ProgressDao 写读 Bookmark 新字段 — 防 SELECT/INSERT 列错位。
    #[test]
    fn test_bookmark_dao_persists_v11_fields() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_bookmark_dao_v11.db")
            .to_string_lossy()
            .to_string();
        let conn = init_database(&db_path).unwrap();
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at)
             VALUES ('s', 's', 'https://x', 0, 0)",
            [],
        )
        .unwrap();
        let book_dao = crate::book_dao::BookDao::new(&conn);
        let book = book_dao.create("s", None, "Book", None).unwrap();
        let dao = crate::progress_dao::ProgressDao::new(&conn);

        // 通过便捷函数创建：新字段默认值
        let bm = dao.create_bookmark(&book.id, 3, 7, Some("note")).unwrap();
        assert_eq!(bm.chapter_pos, 0);
        assert!(bm.book_name.is_none());

        // 直接构造完整 Bookmark 并写入
        let now = chrono::Utc::now().timestamp();
        let full = crate::models::Bookmark {
            id: "bm-full".into(),
            book_id: book.id.clone(),
            chapter_index: 4,
            paragraph_index: 0,
            content: Some("user note".into()),
            book_name: Some("Book".into()),
            book_author: Some("Author".into()),
            chapter_pos: 1234,
            chapter_name: Some("第 4 章".into()),
            book_text: Some("片段".into()),
            created_at: now,
        };
        dao.add_bookmark(&full).unwrap();
        let all = dao.get_bookmarks(&book.id).unwrap();
        let got = all.iter().find(|b| b.id == "bm-full").unwrap();
        assert_eq!(got.chapter_pos, 1234);
        assert_eq!(got.book_name.as_deref(), Some("Book"));
        assert_eq!(got.book_author.as_deref(), Some("Author"));
        assert_eq!(got.chapter_name.as_deref(), Some("第 4 章"));
        assert_eq!(got.book_text.as_deref(), Some("片段"));
    }

    // ============================================================
    // 批次 16 (v12) 迁移测试 — RSS 4 张表 schema 骨架
    // ============================================================

    /// fresh install + v11 → v12 迁移都要建好 4 张 RSS 表 + 4 个索引。
    #[test]
    fn test_migrate_v12_creates_rss_tables() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_migrate_v12.db")
            .to_string_lossy()
            .to_string();

        let conn = init_database(&db_path).unwrap();
        assert_eq!(get_db_version(&conn).unwrap(), DB_VERSION);

        // 4 张 RSS 表存在
        for table in &[
            "rss_sources",
            "rss_articles",
            "rss_stars",
            "rss_read_records",
        ] {
            let exists: bool = conn
                .query_row(
                    "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name = ?1",
                    rusqlite::params![table],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(exists, "table {} should exist after v12", table);
        }

        // 4 个索引存在
        for idx in &[
            "idx_rss_sources_group",
            "idx_rss_articles_origin_sort",
            "idx_rss_articles_unread",
            "idx_rss_stars_time",
        ] {
            let exists: bool = conn
                .query_row(
                    "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='index' AND name = ?1",
                    rusqlite::params![idx],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(exists, "index {} should exist after v12", idx);
        }

        // 各表能基本 INSERT + SELECT
        let now = chrono::Utc::now().timestamp();
        conn.execute(
            "INSERT INTO rss_sources (source_url, source_name, created_at, updated_at) \
             VALUES ('https://r1.example/feed', '示例 RSS', ?1, ?1)",
            rusqlite::params![now],
        )
        .unwrap();
        let sources_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM rss_sources", [], |row| row.get(0))
            .unwrap();
        assert_eq!(sources_count, 1);

        conn.execute(
            "INSERT INTO rss_articles (origin, link, title) \
             VALUES ('https://r1.example/feed', 'https://r1.example/post/1', '标题')",
            [],
        )
        .unwrap();
        let articles_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM rss_articles", [], |row| row.get(0))
            .unwrap();
        assert_eq!(articles_count, 1);

        conn.execute(
            "INSERT INTO rss_stars (origin, link, star_time) \
             VALUES ('https://r1.example/feed', 'https://r1.example/post/1', ?1)",
            rusqlite::params![now],
        )
        .unwrap();
        let stars_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM rss_stars", [], |row| row.get(0))
            .unwrap();
        assert_eq!(stars_count, 1);

        conn.execute(
            "INSERT INTO rss_read_records (link, record_time, read_time) \
             VALUES ('https://r1.example/post/1', ?1, ?1)",
            rusqlite::params![now],
        )
        .unwrap();
        let records_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM rss_read_records", [], |row| row.get(0))
            .unwrap();
        assert_eq!(records_count, 1);
    }

    /// v12 迁移幂等：手动重跑 migrate_v12 不报错。
    #[test]
    fn test_migrate_v12_idempotent() {
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir
            .path()
            .join("test_migrate_v12_idempotent.db")
            .to_string_lossy()
            .to_string();

        let conn = init_database(&db_path).unwrap();
        // 第一次（fresh install 已经建过表）后再次直接调 migrate_v12
        migrate_v12(&conn).unwrap();
        // 重跑两次也不报错
        migrate_v12(&conn).unwrap();

        // 表 / 索引依旧在
        for table in &[
            "rss_sources",
            "rss_articles",
            "rss_stars",
            "rss_read_records",
        ] {
            let exists: bool = conn
                .query_row(
                    "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name = ?1",
                    rusqlite::params![table],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(exists);
        }
    }
}
