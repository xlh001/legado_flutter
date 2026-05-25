//! # 备份 DAO (批次 10)
//!
//! Legado 兼容的本地 zip 备份 / 恢复。Schema 范围限于本端口已落地的
//! 5 张表：books / book_groups / bookmarks / replace_rules / book_sources。
//! 其它表（searchHistory / cookie / rssSource / readRecord ...）等
//! schema 补齐后再加，详见 PRD §Out of Scope。
//!
//! ## zip 文件清单（与原 Legado 兼容）
//!
//! - `bookshelf.json`   — `Vec<Book>`（Legado 字段名 camelCase）
//! - `bookGroup.json`   — `Vec<BookGroup>`
//! - `bookmark.json`    — `Vec<Bookmark>`
//! - `replaceRule.json` — `Vec<ReplaceRule>`
//! - `bookSource.json`  — `Vec<BookSource>`（与 `source_dao::export_legado_json`
//!   一致）
//!
//! **无 manifest.json**（与原 Legado 一致），按文件名硬识别。
//!
//! ## 导入顺序约定
//!
//! `bookSource.json` → `bookGroup.json` → `bookshelf.json` → `bookmark.json`
//! → `replaceRule.json`。原因见 PRD §字段映射表：books 依赖 sources
//! (origin → source_id)，bookmarks 依赖 books ((name,author) → book_id)。
//!
//! ## WAL sidecar 与备份产物的关系（BATCH-08d 审计，F-W1A-056 dismissed）
//!
//! BATCH-08c 启用 WAL 后用户 db 目录会多 `legado.db-wal` + `legado.db-shm`
//! sidecar 文件。本模块**走 SQL `SELECT` → JSON → zip 路径**，全程不接触
//! 文件系统层 db 文件本身（仓库内 0 处 `fs::copy(.db)` / `VACUUM INTO` /
//! `sqlite3_backup_init`）。WAL sidecar 对 SQL 层完全透明：已 commit 数据
//! 由 SQLite 引擎自动合并到 SELECT 结果，未 commit 数据按 ACID 隔离语义
//! 本就不属于备份范围。**因此备份前无需 `PRAGMA wal_checkpoint`**。
//!
//! 若未来新增"二进制级"备份路径（`fs::copy` db 文件 / `VACUUM INTO` /
//! `sqlite3_backup_init`），那条新路径必须在备份前 checkpoint，否则会丢失
//! 已 commit 但未 checkpoint 回主 db 的事务。详见 master report F-W1A-057
//! 占位 finding。

use crate::legado_field_map as map;
use crate::models::{Book, BookGroup, Bookmark, BookSource, ReplaceRule};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
use std::path::Path;
use tracing::{info, warn};
use zip::{write::SimpleFileOptions, ZipArchive, ZipWriter};

/// 已识别的 zip 内文件名常量集合。
///
/// 用 `pub` 暴露便于 `validate_zip` / Flutter 端 import 预览复用同一
/// 字符串集合，避免拼写错位。
pub const FILE_BOOKSHELF: &str = "bookshelf.json";
pub const FILE_BOOK_GROUP: &str = "bookGroup.json";
pub const FILE_BOOKMARK: &str = "bookmark.json";
pub const FILE_REPLACE_RULE: &str = "replaceRule.json";
pub const FILE_BOOK_SOURCE: &str = "bookSource.json";

/// 已知的 5 张表文件名（顺序无关）。其它（searchHistory.json / cookie.json
/// 等）暂不识别 → `validate_zip` 不会列入。
pub const KNOWN_FILE_NAMES: &[&str] = &[
    FILE_BOOKSHELF,
    FILE_BOOK_GROUP,
    FILE_BOOKMARK,
    FILE_REPLACE_RULE,
    FILE_BOOK_SOURCE,
];

/// 单 zip entry 解压后大小硬上限（50 MB）。超此大小认为是 zip-bomb 拒绝
/// 导入（F-W1A-012, BATCH-09）。
///
/// Legado 真实备份单文件量级一般 <几 MB（5 张表 JSON 文本）。50 MB 给
/// 高密度用户（几千本书 / 几万条书签）留 10x 余量。
pub const MAX_ZIP_ENTRY_SIZE: u64 = 50 * 1024 * 1024;

/// zip 整体识别 entry 累计解压大小硬上限（500 MB）。即便每条 entry 都
/// 卡在 50 MB 之下，5 张表加起来也有可能爆内存（恶意 5×100MB 构造）。
/// 累计 500 MB 兜底（F-W1A-012, BATCH-09）。
pub const MAX_ZIP_TOTAL_SIZE: u64 = 500 * 1024 * 1024;

/// 导入摘要（Flutter 侧 SnackBar 显示用）
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ImportSummary {
    pub books: i32,
    pub groups: i32,
    pub bookmarks: i32,
    pub replace_rules: i32,
    pub sources: i32,
    /// 单条 upsert 失败 / 字段映射 warning 收集。逐项跳过不打断
    /// 后续，方便用户至少导入大部分数据。
    pub errors: Vec<String>,
}

// ============================================================
// 导出
// ============================================================

/// 把当前 DB 的 5 张表 → JSON → zip（Legado 兼容格式）
pub fn export_to_zip(conn: &Connection, out_path: &str) -> Result<(), String> {
    info!("导出备份 zip: {}", out_path);

    // 1. SELECT 5 张表
    let books = select_all_books(conn)?;
    let groups = select_all_groups(conn)?;
    let bookmarks = select_all_bookmarks(conn)?;
    let replace_rules = select_all_replace_rules(conn)?;
    let sources = select_all_sources(conn)?;

    // 2. 构造 sources_id_to_url 映射，给 books 反向 origin 字段用
    let mut sources_id_to_url: HashMap<String, String> = HashMap::new();
    for s in &sources {
        sources_id_to_url.insert(s.id.clone(), s.url.clone());
    }

    // 3. 5 个 JSON 数组
    let bookshelf_json: Vec<Value> = books
        .iter()
        .map(|b| map::storage_book_to_legado_json(b, &sources_id_to_url))
        .collect();
    let book_group_json: Vec<Value> =
        groups.iter().map(map::storage_group_to_legado_json).collect();
    let bookmark_json: Vec<Value> = bookmarks
        .iter()
        .map(map::storage_bookmark_to_legado_json)
        .collect();
    let replace_rule_json: Vec<Value> = replace_rules
        .iter()
        .map(map::storage_replace_rule_to_legado_json)
        .collect();
    let book_source_json: Vec<Value> = sources
        .iter()
        .map(map::storage_source_to_legado_json)
        .collect();

    // 4. 打 zip
    let file = File::create(out_path).map_err(|e| format!("创建 zip 文件失败: {}", e))?;
    let mut zip = ZipWriter::new(file);
    let opts = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .unix_permissions(0o644);

    // 空表也写文件（写入空数组），用户层面更直观；原 Legado 的行为
    // 是 `list.isEmpty()` 直接 skip 不写文件。我们这里走空数组写入，
    // 保证文件清单稳定，更便于 round-trip 测试。Legado 一侧导入空
    // 数组也是 no-op，所以不影响互兼容。
    write_json_to_zip(&mut zip, FILE_BOOKSHELF, &bookshelf_json, opts)?;
    write_json_to_zip(&mut zip, FILE_BOOK_GROUP, &book_group_json, opts)?;
    write_json_to_zip(&mut zip, FILE_BOOKMARK, &bookmark_json, opts)?;
    write_json_to_zip(&mut zip, FILE_REPLACE_RULE, &replace_rule_json, opts)?;
    write_json_to_zip(&mut zip, FILE_BOOK_SOURCE, &book_source_json, opts)?;

    zip.finish().map_err(|e| format!("zip 收尾失败: {}", e))?;
    Ok(())
}

fn write_json_to_zip(
    zip: &mut ZipWriter<File>,
    name: &str,
    data: &[Value],
    opts: SimpleFileOptions,
) -> Result<(), String> {
    zip.start_file(name, opts)
        .map_err(|e| format!("zip start_file({}) 失败: {}", name, e))?;
    let pretty = serde_json::to_string_pretty(data)
        .map_err(|e| format!("序列化 {} 失败: {}", name, e))?;
    zip.write_all(pretty.as_bytes())
        .map_err(|e| format!("写入 {} 失败: {}", name, e))?;
    Ok(())
}

// ============================================================
// 校验（dry-run，列文件清单）
// ============================================================

/// 列出 zip 内**已识别**的 Legado 备份文件名。
/// 不解析内容，仅快速预览；用于 Flutter UI 在确认导入前给用户看一眼。
pub fn validate_zip(zip_path: &str) -> Result<Vec<String>, String> {
    let file = File::open(zip_path).map_err(|e| format!("打开 zip 失败: {}", e))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("解析 zip 失败: {}", e))?;
    let mut found = Vec::new();
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|e| format!("读 zip 条目 {} 失败: {}", i, e))?;
        let name = entry.name().to_string();
        if KNOWN_FILE_NAMES.contains(&name.as_str()) {
            found.push(name);
        }
    }
    Ok(found)
}

// ============================================================
// 导入
// ============================================================

/// 解 zip → 字段映射 → 事务 upsert。
///
/// 出错策略：
/// - 整体 IO / zip 结构错误 → `Err`，整个导入回滚（事务）
/// - 单条 JSON 解析或字段映射失败 → 收集到 `summary.errors`，跳过
///   该条继续后续记录
/// - upsert SQL 失败同上
pub fn import_from_zip(conn: &mut Connection, zip_path: &str) -> Result<ImportSummary, String> {
    info!("导入备份 zip: {}", zip_path);

    let file = File::open(zip_path).map_err(|e| format!("打开 zip 失败: {}", e))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("解析 zip 失败: {}", e))?;

    // 先一次性把每个识别到的 JSON 文件读到内存（zip 顺序不保证，得
    // 确保 sources 先读完才能给 books 用 sources_url_to_id 映射）。
    // 5 张表 JSON 全在一个 zip 里，量级一般 <几 MB，全 RAM 可接受。
    //
    // **F-W1A-012 加固（2026-05-21, BATCH-09）**：双层大小 cap 防 zip-bomb：
    // 1. `entry.size()` 预检：来自 zip central directory，攻击者可篡改；
    //    快路径快速拒绝合法构造的恶意 zip。
    // 2. `Read::take(MAX + 1)` 实读 cap：兜底 size 字段被篡改的情况，
    //    实际读出超过 MAX 字节即拒绝。两层缺一不可。
    let mut payloads: HashMap<String, String> = HashMap::new();
    let mut total_decompressed: u64 = 0;
    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("读 zip 条目 {} 失败: {}", i, e))?;
        let name = entry.name().to_string();
        if !KNOWN_FILE_NAMES.contains(&name.as_str()) {
            continue;
        }
        // 第 1 层：信 size 字段做快速拒绝
        let declared = entry.size();
        if declared > MAX_ZIP_ENTRY_SIZE {
            return Err(format!(
                "zip entry {} 声明大小 {} 字节超过单文件限制 {} 字节（疑似 zip-bomb）",
                name, declared, MAX_ZIP_ENTRY_SIZE
            ));
        }
        total_decompressed = total_decompressed.saturating_add(declared);
        if total_decompressed > MAX_ZIP_TOTAL_SIZE {
            return Err(format!(
                "zip 累计解压大小已超过总限制 {} 字节（疑似 zip-bomb）",
                MAX_ZIP_TOTAL_SIZE
            ));
        }
        // 第 2 层：take(MAX + 1) 实读 cap，兜底 size 字段被篡改
        let mut buf = String::new();
        let mut limited = (&mut entry).take(MAX_ZIP_ENTRY_SIZE + 1);
        limited
            .read_to_string(&mut buf)
            .map_err(|e| format!("读取 {} 失败: {}", name, e))?;
        if buf.len() as u64 > MAX_ZIP_ENTRY_SIZE {
            return Err(format!(
                "zip entry {} 实读字节超过单文件限制 {} 字节（声明 size 字段被篡改）",
                name, MAX_ZIP_ENTRY_SIZE
            ));
        }
        payloads.insert(name, buf);
    }

    let mut summary = ImportSummary::default();

    // 单事务跑 5 张表的 upsert，保证半失败不留下脏数据。
    let tx = conn.transaction().map_err(|e| format!("开启事务失败: {}", e))?;

    // 1. sources 先 → 同时构造 url_to_id 映射给 books 用
    let mut sources_url_to_id: HashMap<String, String> = HashMap::new();
    if let Some(text) = payloads.get(FILE_BOOK_SOURCE) {
        match serde_json::from_str::<Vec<Value>>(text) {
            Ok(arr) => {
                for legado in &arr {
                    match map::legado_source_to_storage_source(legado) {
                        Ok(s) => match upsert_source(&tx, &s) {
                            Ok(effective_id) => {
                                sources_url_to_id.insert(s.url.clone(), effective_id);
                                summary.sources += 1;
                            }
                            Err(e) => {
                                summary.errors.push(format!("source upsert 失败: {}", e));
                            }
                        },
                        Err(e) => summary.errors.push(format!("source 字段映射失败: {}", e)),
                    }
                }
            }
            Err(e) => summary
                .errors
                .push(format!("{} 解析失败: {}", FILE_BOOK_SOURCE, e)),
        }
    }
    // 加载 DB 已有 sources 也进映射表（先前用户已有的书源也算"已知"）
    {
        let mut stmt = tx
            .prepare("SELECT id, url FROM book_sources")
            .map_err(|e| format!("prepare sources 查询失败: {}", e))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
            .map_err(|e| format!("查 sources 失败: {}", e))?;
        // BATCH-23 (F-W1A-030)：原 `for r in rows.flatten()` 把 Result<T> 当
        // Iterator 处理，Ok→[t] / Err→[]，等同 .filter_map(Result::ok) 静默
        // 吞 SQL 错误。改 for-loop 显式 ? 向上传播，让 caller 能感知到
        // 损坏的 sources 行（DB 损坏场景下用户能看到具体错误而非默默错过）。
        for r in rows {
            let r = r.map_err(|e| format!("读 sources 行失败: {}", e))?;
            sources_url_to_id.entry(r.1).or_insert(r.0);
        }
    }

    // 2. groups
    if let Some(text) = payloads.get(FILE_BOOK_GROUP) {
        match serde_json::from_str::<Vec<Value>>(text) {
            Ok(arr) => {
                for legado in &arr {
                    match map::legado_group_to_storage_group(legado) {
                        Ok(g) => match upsert_group(&tx, &g) {
                            Ok(_) => summary.groups += 1,
                            Err(e) => summary.errors.push(format!("group upsert 失败: {}", e)),
                        },
                        Err(e) => {
                            // 系统保留组（id=0 / 负数）按设计跳过，不算 error
                            warn!("跳过 group: {}", e);
                        }
                    }
                }
            }
            Err(e) => summary
                .errors
                .push(format!("{} 解析失败: {}", FILE_BOOK_GROUP, e)),
        }
    }

    // 3. books → 同时构造 (name, author) → book_id 映射给 bookmarks 用
    let mut book_key_to_id: HashMap<String, String> = HashMap::new();
    if let Some(text) = payloads.get(FILE_BOOKSHELF) {
        match serde_json::from_str::<Vec<Value>>(text) {
            Ok(arr) => {
                for legado in &arr {
                    match map::legado_book_to_storage_book(legado, &sources_url_to_id) {
                        Ok(b) => match upsert_book(&tx, &b) {
                            Ok(()) => {
                                let key = format!(
                                    "{}|{}",
                                    b.name,
                                    b.author.clone().unwrap_or_default()
                                );
                                book_key_to_id.insert(key, b.id.clone());
                                summary.books += 1;
                            }
                            Err(e) => summary.errors.push(format!("book upsert 失败: {}", e)),
                        },
                        Err(e) => summary.errors.push(format!("book 字段映射失败: {}", e)),
                    }
                }
            }
            Err(e) => summary
                .errors
                .push(format!("{} 解析失败: {}", FILE_BOOKSHELF, e)),
        }
    }
    // DB 已有的书也加入映射（让 bookmark 能挂到老书上）
    {
        let mut stmt = tx
            .prepare("SELECT id, name, author FROM books")
            .map_err(|e| format!("prepare books 查询失败: {}", e))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })
            .map_err(|e| format!("查 books 失败: {}", e))?;
        // BATCH-23 (F-W1A-030)：错误传播取代 silent flatten，同上 sources 路径。
        for r in rows {
            let r = r.map_err(|e| format!("读 books 行失败: {}", e))?;
            let key = format!("{}|{}", r.1, r.2.unwrap_or_default());
            book_key_to_id.entry(key).or_insert(r.0);
        }
    }

    // 4. bookmarks
    if let Some(text) = payloads.get(FILE_BOOKMARK) {
        match serde_json::from_str::<Vec<Value>>(text) {
            Ok(arr) => {
                for legado in &arr {
                    match map::legado_bookmark_to_storage_bookmark(legado, &book_key_to_id) {
                        Ok(bm) => {
                            // book_id 空 = 找不到对应书，按设计跳过（书签悬空无意义）
                            if bm.book_id.is_empty() {
                                summary.errors.push(format!(
                                    "书签找不到对应书 (name={:?})，跳过",
                                    bm.book_name
                                ));
                                continue;
                            }
                            match upsert_bookmark(&tx, &bm) {
                                Ok(()) => summary.bookmarks += 1,
                                Err(e) => summary
                                    .errors
                                    .push(format!("bookmark upsert 失败: {}", e)),
                            }
                        }
                        Err(e) => summary.errors.push(format!("bookmark 字段映射失败: {}", e)),
                    }
                }
            }
            Err(e) => summary
                .errors
                .push(format!("{} 解析失败: {}", FILE_BOOKMARK, e)),
        }
    }

    // 5. replace_rules
    if let Some(text) = payloads.get(FILE_REPLACE_RULE) {
        match serde_json::from_str::<Vec<Value>>(text) {
            Ok(arr) => {
                for legado in &arr {
                    match map::legado_replace_rule_to_storage(legado) {
                        Ok(r) => match upsert_replace_rule(&tx, &r) {
                            Ok(()) => summary.replace_rules += 1,
                            Err(e) => summary
                                .errors
                                .push(format!("replace_rule upsert 失败: {}", e)),
                        },
                        Err(e) => summary
                            .errors
                            .push(format!("replace_rule 字段映射失败: {}", e)),
                    }
                }
            }
            Err(e) => summary
                .errors
                .push(format!("{} 解析失败: {}", FILE_REPLACE_RULE, e)),
        }
    }

    tx.commit().map_err(|e| format!("提交事务失败: {}", e))?;

    info!(
        "导入完成: books={} groups={} bookmarks={} replace_rules={} sources={} errors={}",
        summary.books,
        summary.groups,
        summary.bookmarks,
        summary.replace_rules,
        summary.sources,
        summary.errors.len()
    );
    Ok(summary)
}

// ============================================================
// SELECT helpers（避免依赖 BookDao，因为 BookDao 持有 &Connection 可能
// 与事务嵌套冲突）
// ============================================================

fn select_all_books(conn: &Connection) -> Result<Vec<Book>, String> {
    let dao = crate::book_dao::BookDao::new(conn);
    dao.get_all().map_err(|e| format!("查 books 失败: {}", e))
}

fn select_all_groups(conn: &Connection) -> Result<Vec<BookGroup>, String> {
    crate::book_group_dao::BookGroupDao::list_all(conn)
        .map_err(|e| format!("查 book_groups 失败: {}", e))
}

fn select_all_bookmarks(conn: &Connection) -> Result<Vec<Bookmark>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT id, book_id, chapter_index, paragraph_index, content,
                    book_name, book_author, chapter_pos, chapter_name, book_text,
                    created_at
             FROM bookmarks",
        )
        .map_err(|e| format!("prepare bookmarks 失败: {}", e))?;
    let rows = stmt
        .query_map([], |row| {
            Ok(Bookmark {
                id: row.get(0)?,
                book_id: row.get(1)?,
                chapter_index: row.get(2)?,
                paragraph_index: row.get(3)?,
                content: row.get(4)?,
                book_name: row.get(5)?,
                book_author: row.get(6)?,
                chapter_pos: row.get(7)?,
                chapter_name: row.get(8)?,
                book_text: row.get(9)?,
                created_at: row.get(10)?,
            })
        })
        .map_err(|e| format!("查 bookmarks 失败: {}", e))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("聚合 bookmarks 失败: {}", e))
}

fn select_all_replace_rules(conn: &Connection) -> Result<Vec<ReplaceRule>, String> {
    let dao = crate::replace_rule_dao::ReplaceRuleDao::new(conn);
    dao.get_all()
        .map_err(|e| format!("查 replace_rules 失败: {}", e))
}

fn select_all_sources(conn: &Connection) -> Result<Vec<BookSource>, String> {
    // SourceDao 需要 &mut Connection；这里直接手写 SELECT 避免转换。
    // 列定义复用 [`source_dao::BOOK_SOURCE_COLUMNS`]（批次 08 / F-W1A-006）
    // —— 单一来源避免 schema 加列时这一处漂移。
    let sql = format!(
        "SELECT {} FROM book_sources ORDER BY custom_order ASC, weight DESC",
        crate::source_dao::BOOK_SOURCE_COLUMNS
    );
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| format!("prepare sources 失败: {}", e))?;
    let rows = stmt
        .query_map([], |row| {
            Ok(BookSource {
                id: row.get(0)?,
                name: row.get(1)?,
                url: row.get(2)?,
                source_type: row.get(3)?,
                group_name: row.get(4)?,
                enabled: row.get::<_, i32>(5)? != 0,
                custom_order: row.get(6)?,
                weight: row.get(7)?,
                rule_search: row.get(8)?,
                rule_book_info: row.get(9)?,
                rule_toc: row.get(10)?,
                rule_content: row.get(11)?,
                login_url: row.get(12)?,
                login_ui: row.get(13)?,
                login_check_js: row.get(14)?,
                header: row.get(15)?,
                js_lib: row.get(16)?,
                cover_decode_js: row.get(17)?,
                book_url_pattern: row.get(18)?,
                rule_explore: row.get(19)?,
                explore_url: row.get(20)?,
                enabled_explore: row.get::<_, i32>(21)? != 0,
                last_update_time: row.get(22)?,
                book_source_comment: row.get(23)?,
                concurrent_rate: row.get(24)?,
                variable_comment: row.get(25)?,
                explore_screen: row.get(26)?,
                respond_time: row.get(27)?,
                last_check_error: row.get(28)?,
                last_check_at: row.get(29)?,
                created_at: row.get(30)?,
                updated_at: row.get(31)?,
            })
        })
        .map_err(|e| format!("查 sources 失败: {}", e))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("聚合 sources 失败: {}", e))
}

// ============================================================
// 事务内 upsert helpers
// ============================================================

fn upsert_source(tx: &rusqlite::Transaction, s: &BookSource) -> Result<String, String> {
    use rusqlite::params;
    // URL 唯一，已存在则取它的 id 返回（保留外键不破）
    let effective_id: String = match tx.query_row(
        "SELECT id FROM book_sources WHERE url = ?",
        params![s.url],
        |row| row.get(0),
    ) {
        Ok(id) => id,
        Err(rusqlite::Error::QueryReturnedNoRows) => s.id.clone(),
        Err(e) => return Err(format!("查 source url 失败: {}", e)),
    };

    tx.execute(
        "INSERT INTO book_sources (
            id, name, url, source_type, group_name, enabled, custom_order, weight,
            rule_search, rule_book_info, rule_toc, rule_content,
            login_url, login_ui, login_check_js, header, js_lib, cover_decode_js, book_url_pattern,
            rule_explore, explore_url, enabled_explore, last_update_time, book_source_comment,
            concurrent_rate, variable_comment, explore_screen,
            respond_time, last_check_error, last_check_at,
            created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            url = excluded.url,
            source_type = excluded.source_type,
            group_name = excluded.group_name,
            enabled = excluded.enabled,
            custom_order = excluded.custom_order,
            weight = excluded.weight,
            rule_search = excluded.rule_search,
            rule_book_info = excluded.rule_book_info,
            rule_toc = excluded.rule_toc,
            rule_content = excluded.rule_content,
            login_url = excluded.login_url,
            login_ui = excluded.login_ui,
            login_check_js = excluded.login_check_js,
            header = excluded.header,
            js_lib = excluded.js_lib,
            cover_decode_js = excluded.cover_decode_js,
            book_url_pattern = excluded.book_url_pattern,
            rule_explore = excluded.rule_explore,
            explore_url = excluded.explore_url,
            enabled_explore = excluded.enabled_explore,
            last_update_time = excluded.last_update_time,
            book_source_comment = excluded.book_source_comment,
            concurrent_rate = excluded.concurrent_rate,
            variable_comment = excluded.variable_comment,
            explore_screen = excluded.explore_screen,
            respond_time = excluded.respond_time,
            last_check_error = excluded.last_check_error,
            last_check_at = excluded.last_check_at,
            updated_at = excluded.updated_at",
        params![
            effective_id,
            s.name,
            s.url,
            s.source_type,
            s.group_name,
            s.enabled as i32,
            s.custom_order,
            s.weight,
            s.rule_search,
            s.rule_book_info,
            s.rule_toc,
            s.rule_content,
            s.login_url,
            s.login_ui,
            s.login_check_js,
            s.header,
            s.js_lib,
            s.cover_decode_js,
            s.book_url_pattern,
            s.rule_explore,
            s.explore_url,
            s.enabled_explore as i32,
            s.last_update_time,
            s.book_source_comment,
            s.concurrent_rate,
            s.variable_comment,
            s.explore_screen,
            s.respond_time,
            s.last_check_error,
            s.last_check_at,
            s.created_at,
            s.updated_at,
        ],
    )
    .map_err(|e| format!("source upsert SQL 失败: {}", e))?;
    Ok(effective_id)
}

fn upsert_group(tx: &rusqlite::Transaction, g: &BookGroup) -> Result<(), String> {
    use rusqlite::params;
    // groups 表用整数自增 id，导入时尽量保留原 id 不冲突。先 try
    // INSERT (rowid 显式带 id)；失败 fallback UPDATE。
    let exists: i64 = tx
        .query_row(
            "SELECT COUNT(*) FROM book_groups WHERE id = ?",
            params![g.id],
            |row| row.get(0),
        )
        .map_err(|e| format!("查 group 失败: {}", e))?;
    if exists == 0 {
        tx.execute(
            "INSERT INTO book_groups (id, name, sort_order, cover, show, book_sort, created_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            params![g.id, g.name, g.sort_order, g.cover, g.show as i32, g.book_sort, g.created_at, g.updated_at],
        )
        .map_err(|e| format!("group INSERT 失败: {}", e))?;
    } else {
        tx.execute(
            "UPDATE book_groups SET name=?, sort_order=?, cover=?, show=?, book_sort=?, updated_at=? \
             WHERE id=?",
            params![g.name, g.sort_order, g.cover, g.show as i32, g.book_sort, g.updated_at, g.id],
        )
        .map_err(|e| format!("group UPDATE 失败: {}", e))?;
    }
    Ok(())
}

fn upsert_book(tx: &rusqlite::Transaction, b: &Book) -> Result<(), String> {
    // 批次 08 (BATCH-08 / F-W1A-011)：复用 [`book_dao::BOOK_UPSERT_SQL`] +
    // [`book_dao::book_upsert_params!`]，避免本文件再维护一份完整 27 列
    // INSERT。schema 加列时只改 book_dao 一处。
    use crate::book_dao::book_upsert_params;
    tx.execute(crate::book_dao::BOOK_UPSERT_SQL, book_upsert_params!(b))
        .map_err(|e| format!("book upsert SQL 失败: {}", e))?;
    Ok(())
}

fn upsert_bookmark(tx: &rusqlite::Transaction, bm: &Bookmark) -> Result<(), String> {
    // 批次 08 (BATCH-08 / F-W1A-010): 复用 [`progress_dao::BOOKMARK_UPSERT_SQL`]
    // + [`progress_dao::bookmark_upsert_params!`]，与主路径
    // [`ProgressDao::add_bookmark`] 共享 SQL，避免风格漂移。
    use crate::progress_dao::bookmark_upsert_params;
    tx.execute(
        crate::progress_dao::BOOKMARK_UPSERT_SQL,
        bookmark_upsert_params!(bm),
    )
    .map_err(|e| format!("bookmark upsert SQL 失败: {}", e))?;
    Ok(())
}

fn upsert_replace_rule(tx: &rusqlite::Transaction, r: &ReplaceRule) -> Result<(), String> {
    use rusqlite::params;
    tx.execute(
        "INSERT INTO replace_rules (
            id, name, pattern, replacement, enabled,
            scope, scope_title, scope_content, exclude_scope,
            sort_number, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            pattern = excluded.pattern,
            replacement = excluded.replacement,
            enabled = excluded.enabled,
            scope = excluded.scope,
            scope_title = excluded.scope_title,
            scope_content = excluded.scope_content,
            exclude_scope = excluded.exclude_scope,
            sort_number = excluded.sort_number,
            updated_at = excluded.updated_at",
        params![
            r.id,
            r.name,
            r.pattern,
            r.replacement,
            r.enabled as i32,
            r.scope,
            r.scope_title as i32,
            r.scope_content as i32,
            r.exclude_scope,
            r.sort_number,
            r.created_at,
            r.updated_at,
        ],
    )
    .map_err(|e| format!("replace_rule upsert SQL 失败: {}", e))?;
    Ok(())
}

// 静默 unused 警告（zip_path 参数检查可能扩展用）
#[allow(dead_code)]
fn _path_to_string(p: &Path) -> String {
    p.to_string_lossy().to_string()
}

// ============================================================
// Tests
// ============================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Book;
    use chrono::Utc;
    use rusqlite::params;
    use tempfile::TempDir;

    fn setup() -> (TempDir, Connection) {
        let dir = TempDir::new().unwrap();
        let db_path = dir.path().join("test.db");
        let conn = crate::database::init_database(db_path.to_str().unwrap()).unwrap();
        (dir, conn)
    }

    fn make_book(id: &str, source_id: &str, name: &str, author: &str) -> Book {
        let now = Utc::now().timestamp();
        Book {
            id: id.into(),
            source_id: source_id.into(),
            source_name: Some("S".into()),
            name: name.into(),
            author: Some(author.into()),
            cover_url: None,
            chapter_count: 100,
            latest_chapter_title: None,
            intro: None,
            kind: None,
            book_url: Some(format!("https://example.com/book/{id}")),
            toc_url: None,
            last_check_time: None,
            last_check_count: 0,
            total_word_count: 100_000,
            can_update: true,
            order_time: now,
            latest_chapter_time: None,
            custom_cover_path: None,
            custom_info_json: None,
            dur_chapter_index: 0,
            dur_chapter_pos: 0,
            dur_chapter_title: None,
            dur_chapter_time: 0,
            group_id: 1,
            created_at: now,
            updated_at: now,
        }
    }

    #[test]
    fn test_export_then_import_books_roundtrip() {
        let (dir, mut conn) = setup();
        // 1 个 source + 3 本书 + 1 个分组
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at) \
             VALUES ('src1', 'S', 'https://example.com', 1, 1)",
            [],
        )
        .unwrap();
        crate::book_group_dao::BookGroupDao::create(&conn, "玄幻", 0).unwrap();

        let dao = crate::book_dao::BookDao::new(&conn);
        dao.upsert(&make_book("b1", "src1", "斗破苍穹", "天蚕土豆")).unwrap();
        dao.upsert(&make_book("b2", "src1", "完美世界", "辰东")).unwrap();
        dao.upsert(&make_book("b3", "src1", "三体", "刘慈欣")).unwrap();

        // 导出
        let zip_path = dir.path().join("backup.zip");
        export_to_zip(&conn, zip_path.to_str().unwrap()).unwrap();
        assert!(zip_path.exists());

        // 校验 zip 内有 5 个文件
        let names = validate_zip(zip_path.to_str().unwrap()).unwrap();
        assert_eq!(names.len(), 5);
        assert!(names.contains(&FILE_BOOKSHELF.to_string()));
        assert!(names.contains(&FILE_BOOK_GROUP.to_string()));
        assert!(names.contains(&FILE_BOOK_SOURCE.to_string()));

        // 清空 books 表（保留 source 让导入路径用 url->id 映射）
        conn.execute("DELETE FROM books", []).unwrap();
        let count_before: i64 = conn
            .query_row("SELECT COUNT(*) FROM books", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count_before, 0);

        // 导入
        let summary = import_from_zip(&mut conn, zip_path.to_str().unwrap()).unwrap();
        assert_eq!(summary.books, 3);
        assert!(summary.errors.is_empty(), "errors: {:?}", summary.errors);

        // 数量 + 字段对
        let after = crate::book_dao::BookDao::new(&conn).get_all().unwrap();
        assert_eq!(after.len(), 3);
        let names: Vec<String> = after.iter().map(|b| b.name.clone()).collect();
        assert!(names.contains(&"斗破苍穹".to_string()));
        assert!(names.contains(&"完美世界".to_string()));
        assert!(names.contains(&"三体".to_string()));
        // source_id 应该映射回 src1（因为 sources 表里 url 还存在）
        assert!(after.iter().all(|b| b.source_id == "src1"));
    }

    #[test]
    fn test_import_legado_format_book() {
        let (dir, mut conn) = setup();
        // 先放一个匹配 origin URL 的 source，让 origin → source_id 映射成功
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at) \
             VALUES ('legado-src', 'Legado源', 'https://legado.example.com', 1, 1)",
            [],
        )
        .unwrap();

        // 手写一段 Legado 备份格式的 zip（仅 bookshelf.json + bookGroup.json）
        let zip_path = dir.path().join("legado_in.zip");
        let file = File::create(&zip_path).unwrap();
        let mut zip = ZipWriter::new(file);
        let opts = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);

        let bookshelf = serde_json::json!([
            {
                "bookUrl": "https://legado.example.com/book/123",
                "tocUrl": "https://legado.example.com/book/123/toc",
                "origin": "https://legado.example.com",
                "originName": "Legado源",
                "name": "斗破苍穹",
                "author": "天蚕土豆",
                "kind": "玄幻",
                "type": 0,
                "group": 2,
                "totalChapterNum": 1641,
                "wordCount": "5.2M",
                "canUpdate": true,
                "latestChapterTime": 1_731_234_567_890_i64,
                "durChapterIndex": 99,
                "durChapterPos": 0,
                "durChapterTitle": "第100章",
                "durChapterTime": 1_731_234_567_890_i64,
            }
        ]);
        zip.start_file(FILE_BOOKSHELF, opts).unwrap();
        zip.write_all(serde_json::to_string(&bookshelf).unwrap().as_bytes())
            .unwrap();

        let groups = serde_json::json!([
            {
                "groupId": 2,
                "groupName": "玄幻",
                "order": 0,
                "show": true,
                "bookSort": -1,
            }
        ]);
        zip.start_file(FILE_BOOK_GROUP, opts).unwrap();
        zip.write_all(serde_json::to_string(&groups).unwrap().as_bytes())
            .unwrap();
        zip.finish().unwrap();

        // 导入
        let summary = import_from_zip(&mut conn, zip_path.to_str().unwrap()).unwrap();
        assert_eq!(summary.books, 1);
        assert_eq!(summary.groups, 1);
        assert!(summary.errors.is_empty(), "errors: {:?}", summary.errors);

        // 字段验证
        let books = crate::book_dao::BookDao::new(&conn).get_all().unwrap();
        assert_eq!(books.len(), 1);
        let b = &books[0];
        assert_eq!(b.name, "斗破苍穹");
        assert_eq!(b.author.as_deref(), Some("天蚕土豆"));
        assert_eq!(b.source_id, "legado-src", "origin URL 应映射到 source_id");
        assert_eq!(b.total_word_count, 5_200_000);
        assert_eq!(b.chapter_count, 1641);
        // bitmask 2 → group_id 2
        assert_eq!(b.group_id, 2);
        // ms → s
        assert_eq!(b.dur_chapter_time, 1_731_234_567);
        // 缺失字段塞 custom_info_json
        assert!(b
            .custom_info_json
            .as_ref()
            .map(|s| s.contains("_legado_backup"))
            .unwrap_or(false));

        // 分组也进了
        let groups_after =
            crate::book_group_dao::BookGroupDao::list_all(&conn).unwrap();
        assert_eq!(groups_after.len(), 1);
        assert_eq!(groups_after[0].name, "玄幻");
        assert_eq!(groups_after[0].id, 2);
    }

    #[test]
    fn test_validate_zip_lists_known_files_only() {
        let (dir, _conn) = setup();
        let zip_path = dir.path().join("mixed.zip");
        let file = File::create(&zip_path).unwrap();
        let mut zip = ZipWriter::new(file);
        let opts = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        zip.start_file(FILE_BOOKSHELF, opts).unwrap();
        zip.write_all(b"[]").unwrap();
        zip.start_file("config.xml", opts).unwrap(); // 未识别
        zip.write_all(b"<map/>").unwrap();
        zip.start_file("servers.json", opts).unwrap(); // 未识别
        zip.write_all(b"[]").unwrap();
        zip.finish().unwrap();

        let names = validate_zip(zip_path.to_str().unwrap()).unwrap();
        assert_eq!(names, vec![FILE_BOOKSHELF.to_string()]);
    }

    #[test]
    fn test_import_handles_corrupt_book_json_partial() {
        // bookshelf.json 一条好书 + 一条缺 name 字段 → 后者 skip 进 errors
        let (dir, mut conn) = setup();
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at) \
             VALUES ('src1', 'S', 'https://e.com', 1, 1)",
            [],
        )
        .unwrap();

        let zip_path = dir.path().join("partial.zip");
        let file = File::create(&zip_path).unwrap();
        let mut zip = ZipWriter::new(file);
        let opts = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        let bookshelf = serde_json::json!([
            {"name": "好书", "origin": "https://e.com"},
            {"origin": "https://e.com"}, // 缺 name
        ]);
        zip.start_file(FILE_BOOKSHELF, opts).unwrap();
        zip.write_all(serde_json::to_string(&bookshelf).unwrap().as_bytes())
            .unwrap();
        zip.finish().unwrap();

        let summary = import_from_zip(&mut conn, zip_path.to_str().unwrap()).unwrap();
        assert_eq!(summary.books, 1);
        assert_eq!(summary.errors.len(), 1);
        // 好书有进
        let after = crate::book_dao::BookDao::new(&conn).get_all().unwrap();
        assert_eq!(after.len(), 1);
        assert_eq!(after[0].name, "好书");

        // 静默 _: dir 持有 tempdir，让它活到这里
        let _ = dir;
        // params 用一下避免 unused 提示
        let _ = params![1];
    }

    /// F-W1A-012 zip-bomb 防御：单 entry 解压后超过 50MB 应被拒绝（实读 cap）。
    ///
    /// 构造法：把一个 60MB 的 bookshelf.json 写进 zip。zip 用 deflate 压缩
    /// 重复字符可压到几 KB，central directory 的 size 字段会写实际 60MB。
    /// 我们的 entry size 预检应在第 1 层（信 size 字段）就拒绝。
    #[test]
    fn test_import_zip_rejects_oversized_single_entry() {
        let (dir, mut conn) = setup();
        let zip_path = dir.path().join("oversized.zip");
        // 60 MB 重复 'a'，能高效 deflate 压缩，central size 字段写 60MB。
        let payload = "a".repeat(60 * 1024 * 1024);
        let f = File::create(&zip_path).unwrap();
        let mut zip = ZipWriter::new(f);
        zip.start_file(FILE_BOOKSHELF, SimpleFileOptions::default())
            .unwrap();
        zip.write_all(payload.as_bytes()).unwrap();
        zip.finish().unwrap();

        let result = import_from_zip(&mut conn, zip_path.to_str().unwrap());
        assert!(
            result.is_err(),
            "60MB 单 entry zip 应被拒绝，实际返回 Ok({:?})",
            result.ok()
        );
        let msg = result.unwrap_err();
        assert!(
            msg.contains("超过单文件限制") || msg.contains("zip-bomb"),
            "错误信息应说明单 entry 超限：{}",
            msg
        );

        let _ = dir;
    }

    /// F-W1A-012 zip-bomb 防御正常路径：5 个 KNOWN entry 各 1KB 累计远低于
    /// total cap 时应正常导入（验证 accumulator 不误触）。本测试是 sanity
    /// check —— 让 accumulator 走全条件路径但不触发 cap，确认 cap 机制不
    /// 把正常备份误判为攻击。
    #[test]
    fn test_import_zip_normal_size_passes_cap_check() {
        let (dir, mut conn) = setup();
        let zip_path = dir.path().join("normal.zip");
        // 5 个 KNOWN 文件名各塞一个空 JSON Array（极小，远低于 cap）。
        let f = File::create(&zip_path).unwrap();
        let mut zip = ZipWriter::new(f);
        for name in [
            FILE_BOOK_SOURCE,
            FILE_BOOK_GROUP,
            FILE_BOOKSHELF,
            FILE_BOOKMARK,
            FILE_REPLACE_RULE,
        ] {
            zip.start_file(name, SimpleFileOptions::default()).unwrap();
            zip.write_all(b"[]").unwrap();
        }
        zip.finish().unwrap();

        let result = import_from_zip(&mut conn, zip_path.to_str().unwrap());
        // 不关心导入数据正确性，只看 cap 机制不误触
        assert!(
            result.is_ok(),
            "正常大小 zip 应通过 cap 检查，实际 Err: {:?}",
            result.err()
        );

        let _ = dir;
    }
}
