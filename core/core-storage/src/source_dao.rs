//! # 书源 DAO (Data Access Object)
//!
//! 提供书源相关的数据库操作。
//! 对应原 Legado 的 BookSource 实体操作 (data/entities/BookSource.kt)

use super::models::BookSource;
use chrono::Utc;
use regex::Regex;
use rusqlite::{params, Connection, Result as SqlResult};
use serde::Deserialize;
use tracing::{debug, info};
use uuid::Uuid;

/// `book_sources` 表读取列顺序的单一来源。
///
/// 4 处 SELECT (`get_by_id` / `get_enabled` / `get_all` / `get_by_url`) +
/// `backup_dao::select_all_sources` 都基于此常量构建，避免列错位。顺序
/// 与 [`book_source_from_row`] 内 `row.get(N)` 索引必须严格一致。批次
/// 08 (BATCH-08 / F-W1A-006) 抽出常量后，新增列只需改一处。
///
/// 跨文件复用：`pub(crate)` 让 `backup_dao::select_all_sources` 直接复用
/// 同一份列定义。
pub(crate) const BOOK_SOURCE_COLUMNS: &str = "id, name, url, source_type, group_name, enabled, custom_order, weight, \
    rule_search, rule_book_info, rule_toc, rule_content, \
    login_url, login_ui, login_check_js, header, js_lib, cover_decode_js, book_url_pattern, \
    rule_explore, explore_url, enabled_explore, last_update_time, book_source_comment, \
    concurrent_rate, variable_comment, explore_screen, created_at, updated_at";

/// 单条 SQL，同时被 [`SourceDao::upsert`] 和 [`SourceDao::batch_insert`] 使用，
/// 避免两份 ON CONFLICT 列表漂移（之前 upsert 缺 login_ui / login_check_js /
/// cover_decode_js，导致单条更新时这三列永远不会同步）。
const SOURCE_UPSERT_SQL: &str = "INSERT INTO book_sources (
        id, name, url, source_type, group_name, enabled, custom_order, weight,
        rule_search, rule_book_info, rule_toc, rule_content,
        login_url, login_ui, login_check_js, header, js_lib, cover_decode_js, book_url_pattern,
        rule_explore, explore_url, enabled_explore, last_update_time, book_source_comment,
        concurrent_rate, variable_comment, explore_screen, created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        updated_at = excluded.updated_at";

/// 书源 DAO
pub struct SourceDao<'a> {
    conn: &'a mut Connection,
}

impl<'a> SourceDao<'a> {
    /// 创建新的 SourceDao
    pub fn new(conn: &'a mut Connection) -> Self {
        Self { conn }
    }

    /// 插入或更新书源，返回**实际写入的 ID**（可能与 `source.id` 不同）。
    ///
    /// **silently-rewrite-id 行为（F-W1A-007）**：当传入的 `source.id`
    /// 与 DB 中已有行 id 不同、但 `source.url` 与该已有行 url 相同时，
    /// 本 fn 会把写入目标改为已有行 id（用 URL 去重避免外键
    /// `book.source_id` 失效）。调用方**必须使用返回值（`effective_id`）
    /// 而非传入的 `source.id`** 做后续查询/外键关联，否则会出现"按
    /// `source.id` 查找返回 None 但数据其实在数据库另一行"的诡异。
    ///
    /// 示例：
    /// - 传入 `source { id: "A", url: "U" }`，DB 已有 `{ id: "B", url: "U" }`
    ///   → 本 fn 走 ON CONFLICT(id=B) DO UPDATE，返回 `"B"`，调用方应据
    ///   `"B"` 关联 books.source_id；若仍用 `"A"` 会找不到任何行。
    ///
    /// 严格语义（"id 冲突直接报错让 caller 决定"）暂未提供；如未来需要，
    /// 单独补 `try_insert_strict(&self, &BookSource) -> SqlResult<()>`，
    /// 不复用本 fn 的去重逻辑。批次 69 / BATCH-07b 仅文档化此行为不变更
    /// 实现。
    pub fn upsert(&self, source: &BookSource) -> SqlResult<String> {
        debug!("插入/更新书源: {} ({})", source.name, source.url);

        // Handle URL uniqueness: if a different source already has this URL,
        // merge into that record to preserve book->source foreign keys.
        let effective_id: String = match self.conn.query_row(
            "SELECT id FROM book_sources WHERE url = ? AND id != ?",
            params![source.url, source.id],
            |row| row.get(0),
        ) {
            Ok(id) => id,
            Err(rusqlite::Error::QueryReturnedNoRows) => source.id.clone(),
            Err(e) => return Err(e),
        };

        self.conn.execute(
            SOURCE_UPSERT_SQL,
            params![
                effective_id,
                source.name,
                source.url,
                source.source_type,
                source.group_name,
                source.enabled as i32,
                source.custom_order,
                source.weight,
                source.rule_search,
                source.rule_book_info,
                source.rule_toc,
                source.rule_content,
                source.login_url,
                source.login_ui,
                source.login_check_js,
                source.header,
                source.js_lib,
                source.cover_decode_js,
                source.book_url_pattern,
                source.rule_explore,
                source.explore_url,
                source.enabled_explore as i32,
                source.last_update_time,
                source.book_source_comment,
                source.concurrent_rate,
                source.variable_comment,
                source.explore_screen,
                source.created_at,
                source.updated_at,
            ],
        )?;

        Ok(effective_id)
    }

    /// 根据 ID 获取书源
    pub fn get_by_id(&self, id: &str) -> SqlResult<Option<BookSource>> {
        let sql = format!(
            "SELECT {} FROM book_sources WHERE id = ?",
            BOOK_SOURCE_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;

        let mut rows = stmt.query(params![id])?;

        if let Some(row) = rows.next()? {
            Ok(Some(book_source_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    /// 获取所有启用的书源
    pub fn get_enabled(&self) -> SqlResult<Vec<BookSource>> {
        let sql = format!(
            "SELECT {} FROM book_sources WHERE enabled = 1 ORDER BY custom_order ASC, weight DESC",
            BOOK_SOURCE_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;

        let rows = stmt.query_map([], book_source_from_row)?;
        rows.collect()
    }

    /// 获取所有书源
    pub fn get_all(&self) -> SqlResult<Vec<BookSource>> {
        let sql = format!(
            "SELECT {} FROM book_sources ORDER BY custom_order ASC, weight DESC",
            BOOK_SOURCE_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;

        let rows = stmt.query_map([], book_source_from_row)?;
        rows.collect()
    }

    /// 根据 URL 搜索书源
    pub fn get_by_url(&self, url: &str) -> SqlResult<Option<BookSource>> {
        let sql = format!(
            "SELECT {} FROM book_sources WHERE url = ?",
            BOOK_SOURCE_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;

        let mut rows = stmt.query(params![url])?;

        if let Some(row) = rows.next()? {
            Ok(Some(book_source_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    /// 删除书源
    pub fn delete(&self, id: &str) -> SqlResult<()> {
        info!("删除书源: {}", id);
        self.conn
            .execute("DELETE FROM book_sources WHERE id = ?", params![id])?;
        Ok(())
    }

    /// 批量删除书源
    ///
    /// 整批包在单个 transaction 内：N 条删除走一次 commit / fsync，避免
    /// 之前 for 循环逐条 `execute(DELETE)` 每次落盘的 N 次 IO（用户批量删
    /// 50 个书源时差异显著）。同时任意一条失败时整批回滚，保持原子性。
    pub fn delete_batch(&mut self, ids: &[String]) -> SqlResult<()> {
        info!("批量删除 {} 个书源", ids.len());
        let tx = self.conn.transaction()?;
        for id in ids {
            tx.execute("DELETE FROM book_sources WHERE id = ?", params![id])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// 启用/禁用书源
    pub fn set_enabled(&self, id: &str, enabled: bool) -> SqlResult<()> {
        self.conn.execute(
            "UPDATE book_sources SET enabled = ?, updated_at = ? WHERE id = ?",
            params![enabled as i32, Utc::now().timestamp(), id],
        )?;
        Ok(())
    }

    /// 更新书源排序权重
    pub fn update_order(&self, id: &str, custom_order: i32) -> SqlResult<()> {
        self.conn.execute(
            "UPDATE book_sources SET custom_order = ?, updated_at = ? WHERE id = ?",
            params![custom_order, Utc::now().timestamp(), id],
        )?;
        Ok(())
    }

    /// 批量导入书源
    pub fn batch_insert(&mut self, sources: &[BookSource]) -> SqlResult<()> {
        info!("批量导入 {} 个书源", sources.len());

        let tx = self.conn.transaction()?;

        for source in sources {
            // Handle URL uniqueness: if a different source already has this URL,
            // merge into that record to preserve book->source foreign keys.
            let effective_id: String = match tx.query_row(
                "SELECT id FROM book_sources WHERE url = ? AND id != ?",
                params![source.url, source.id],
                |row| row.get(0),
            ) {
                Ok(id) => id,
                Err(rusqlite::Error::QueryReturnedNoRows) => source.id.clone(),
                Err(e) => return Err(e),
            };

            tx.execute(
                SOURCE_UPSERT_SQL,
                params![
                    effective_id,
                    source.name,
                    source.url,
                    source.source_type,
                    source.group_name,
                    source.enabled as i32,
                    source.custom_order,
                    source.weight,
                    source.rule_search,
                    source.rule_book_info,
                    source.rule_toc,
                    source.rule_content,
                    source.login_url,
                    source.login_ui,
                    source.login_check_js,
                    source.header,
                    source.js_lib,
                    source.cover_decode_js,
                    source.book_url_pattern,
                    source.rule_explore,
                    source.explore_url,
                    source.enabled_explore as i32,
                    source.last_update_time,
                    source.book_source_comment,
                    source.concurrent_rate,
                    source.variable_comment,
                    source.explore_screen,
                    source.created_at,
                    source.updated_at,
                ],
            )?;
        }

        tx.commit()?;
        Ok(())
    }

    /// 从 JSON 字符串导入书源
    /// 支持两种格式:
    /// 1. 内部存储格式 (Vec<BookSource>)
    /// 2. Legado 书源导出格式 (字段名 camelCase, 规则为嵌套对象)
    pub fn import_from_json(&mut self, json: &str) -> Result<usize, String> {
        // Try internal storage format first
        if let Ok(sources) = serde_json::from_str::<Vec<BookSource>>(json) {
            let count = sources.len();
            self.batch_insert(&sources)
                .map_err(|e| format!("批量插入书源失败: {}", e))?;
            return Ok(count);
        }

        // Try real-world Legado export format
        let legado_sources: Vec<LegadoBookSource> =
            serde_json::from_str(json).map_err(|e| format!("解析Legado书源JSON失败: {}", e))?;

        let mut sources = Vec::with_capacity(legado_sources.len());
        for s in &legado_sources {
            sources.push(legado_to_storage(s)?);
        }

        let count = sources.len();
        self.batch_insert(&sources)
            .map_err(|e| format!("批量插入书源失败: {}", e))?;
        Ok(count)
    }

    /// 创建新书源（便捷函数）
    pub fn create(&self, name: &str, url: &str) -> SqlResult<BookSource> {
        let now = Utc::now().timestamp();
        let source = BookSource {
            id: Uuid::new_v4().to_string(),
            name: name.to_string(),
            url: url.to_string(),
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
            created_at: now,
            updated_at: now,
        };

        let effective_id = self.upsert(&source)?;
        if effective_id == source.id {
            Ok(source)
        } else {
            self.get_by_id(&effective_id)
                .map(|opt| opt.expect("source not found after dedup upsert"))
        }
    }

    /// BATCH-27e: 按一条「书籍 URL」找匹配的启用书源。对齐原 Legado
    /// `BookSourceDao.getBookSourceAddBook(baseUrl)` + 遍历
    /// `hasBookUrlPattern` regex 兜底（[`BookshelfViewModel.addBookByUrl`]
    /// 53-65 双路径）。
    ///
    /// 匹配优先级（首个匹配返回）：
    /// 1. 启用书源中 `book_url` 以 `source.url` 开头（baseUrl 等价匹配）
    /// 2. 启用书源中 `book_url_pattern` regex 匹配
    ///
    /// 失败 / 没启用书源 / 都不匹配返回 `Ok(None)`。
    /// `Err` 仅在 SQL 层异常时抛。
    ///
    /// 注：legado 对 invalid regex 的态度是 `try { ... } catch (_: Exception)`
    /// 静默跳过，本实现同（regex compile 失败 = 该源不参与 pattern 匹配）。
    pub fn find_for_book_url(&self, book_url: &str) -> SqlResult<Option<BookSource>> {
        if book_url.trim().is_empty() {
            return Ok(None);
        }
        let enabled = self.get_enabled()?;
        // 第 1 路：baseUrl 前缀匹配
        for s in &enabled {
            if !s.url.is_empty() && book_url.starts_with(&s.url) {
                debug!("[source.find_for_book_url] baseUrl match: {}", s.id);
                return Ok(Some(s.clone()));
            }
        }
        // 第 2 路：book_url_pattern regex 兜底
        for s in &enabled {
            let Some(pat) = s.book_url_pattern.as_ref() else {
                continue;
            };
            if pat.trim().is_empty() {
                continue;
            }
            match Regex::new(pat) {
                Ok(re) if re.is_match(book_url) => {
                    debug!(
                        "[source.find_for_book_url] regex match: id={} pat={}",
                        s.id, pat
                    );
                    return Ok(Some(s.clone()));
                }
                Ok(_) => {}
                Err(e) => {
                    debug!(
                        "[source.find_for_book_url] regex compile failed: id={} pat={} err={}",
                        s.id, pat, e
                    );
                }
            }
        }
        Ok(None)
    }
}

/// 从数据库行转换到 BookSource 结构体
fn book_source_from_row(row: &rusqlite::Row) -> SqlResult<BookSource> {
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
        created_at: row.get(27)?,
        updated_at: row.get(28)?,
    })
}

/// Real-world Legado book source JSON export format
#[derive(Debug, Clone, Deserialize)]
struct LegadoBookSource {
    #[serde(rename = "bookSourceUrl")]
    url: String,
    #[serde(rename = "bookSourceName")]
    name: String,
    #[serde(rename = "bookSourceGroup", default)]
    group_name: String,
    #[serde(rename = "bookSourceType", default, deserialize_with = "deser_flexible_i32")]
    source_type: i32,
    #[serde(default = "default_true")]
    enabled: bool,
    #[serde(default, deserialize_with = "deser_flexible_i32")]
    weight: i32,
    #[serde(rename = "customOrder", default, deserialize_with = "deser_flexible_i32")]
    custom_order: i32,
    #[serde(default, deserialize_with = "deser_flexible_header")]
    header: Option<String>,
    #[serde(rename = "loginUrl", default)]
    login_url: Option<String>,
    #[serde(rename = "loginUi", default)]
    login_ui: Option<String>,
    #[serde(rename = "loginCheckJs", default)]
    login_check_js: Option<String>,
    #[serde(rename = "jsLib", default)]
    js_lib: Option<String>,
    #[serde(rename = "coverDecodeJs", default)]
    cover_decode_js: Option<String>,
    #[serde(rename = "searchUrl", default)]
    search_url: Option<String>,
    #[serde(rename = "ruleSearch", default)]
    rule_search: Option<serde_json::Value>,
    #[serde(rename = "ruleBookInfo", default)]
    rule_book_info: Option<serde_json::Value>,
    #[serde(rename = "ruleToc", default)]
    rule_toc: Option<serde_json::Value>,
    #[serde(rename = "ruleContent", default)]
    rule_content: Option<serde_json::Value>,
    #[serde(rename = "ruleExplore", default)]
    rule_explore: Option<serde_json::Value>,
    #[serde(rename = "exploreUrl", default)]
    explore_url: Option<String>,
    #[serde(rename = "bookUrlPattern", default)]
    book_url_pattern: Option<String>,
    #[serde(rename = "enabledExplore", default = "default_true")]
    enabled_explore: bool,
    #[serde(
        rename = "lastUpdateTime",
        default,
        deserialize_with = "deser_flexible_i64"
    )]
    last_update_time: i64,
    #[serde(rename = "bookSourceComment", default)]
    book_source_comment: Option<String>,
    #[serde(rename = "concurrentRate", default)]
    concurrent_rate: Option<String>,
    #[serde(rename = "variableComment", default)]
    variable_comment: Option<String>,
    #[serde(rename = "exploreScreen", default, deserialize_with = "deser_option_flexible_i32")]
    explore_screen: Option<i32>,
}

fn deser_flexible_i64<'de, D>(deserializer: D) -> Result<i64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de;
    struct Visitor;
    impl<'de> de::Visitor<'de> for Visitor {
        type Value = i64;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("a number or string containing a number")
        }
        fn visit_i64<E: de::Error>(self, v: i64) -> Result<i64, E> {
            Ok(v)
        }
        fn visit_u64<E: de::Error>(self, v: u64) -> Result<i64, E> {
            Ok(v as i64)
        }
        fn visit_f64<E: de::Error>(self, v: f64) -> Result<i64, E> {
            Ok(v as i64)
        }
        fn visit_str<E: de::Error>(self, v: &str) -> Result<i64, E> {
            if v.is_empty() { return Ok(0); }
            v.parse::<i64>()
                .map_err(|_| de::Error::custom("invalid number string"))
        }
    }
    deserializer.deserialize_any(Visitor)
}

fn deser_flexible_i32<'de, D>(deserializer: D) -> Result<i32, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de;
    struct Visitor;
    impl<'de> de::Visitor<'de> for Visitor {
        type Value = i32;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("a number or string containing a number")
        }
        fn visit_i64<E: de::Error>(self, v: i64) -> Result<i32, E> {
            Ok(v as i32)
        }
        fn visit_u64<E: de::Error>(self, v: u64) -> Result<i32, E> {
            Ok(v as i32)
        }
        fn visit_f64<E: de::Error>(self, v: f64) -> Result<i32, E> {
            Ok(v as i32)
        }
        fn visit_str<E: de::Error>(self, v: &str) -> Result<i32, E> {
            if v.is_empty() { return Ok(0); }
            v.parse::<i32>()
                .map_err(|_| de::Error::custom("invalid number string"))
        }
    }
    deserializer.deserialize_any(Visitor)
}

fn deser_option_flexible_i32<'de, D>(deserializer: D) -> Result<Option<i32>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de;
    struct Visitor;
    impl<'de> de::Visitor<'de> for Visitor {
        type Value = Option<i32>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("an optional integer or string")
        }
        fn visit_none<E: de::Error>(self) -> Result<Option<i32>, E> {
            Ok(None)
        }
        fn visit_unit<E: de::Error>(self) -> Result<Option<i32>, E> {
            Ok(None)
        }
        fn visit_i64<E: de::Error>(self, v: i64) -> Result<Option<i32>, E> {
            Ok(Some(v as i32))
        }
        fn visit_u64<E: de::Error>(self, v: u64) -> Result<Option<i32>, E> {
            Ok(Some(v as i32))
        }
        fn visit_f64<E: de::Error>(self, v: f64) -> Result<Option<i32>, E> {
            Ok(Some(v as i32))
        }
        fn visit_str<E: de::Error>(self, v: &str) -> Result<Option<i32>, E> {
            if v.is_empty() { return Ok(None); }
            v.parse::<i32>()
                .map(|n| Some(n))
                .map_err(|_| de::Error::custom("invalid number string"))
        }
    }
    deserializer.deserialize_any(Visitor)
}

fn deser_flexible_header<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de;
    struct Visitor;
    impl<'de> de::Visitor<'de> for Visitor {
        type Value = Option<String>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("a string, object, array, or null")
        }
        fn visit_none<E: de::Error>(self) -> Result<Option<String>, E> {
            Ok(None)
        }
        fn visit_unit<E: de::Error>(self) -> Result<Option<String>, E> {
            Ok(None)
        }
        fn visit_str<E: de::Error>(self, v: &str) -> Result<Option<String>, E> {
            let s = v.to_string();
            if s.is_empty() {
                Ok(None)
            } else {
                Ok(Some(s))
            }
        }
        fn visit_string<E: de::Error>(self, v: String) -> Result<Option<String>, E> {
            if v.is_empty() {
                Ok(None)
            } else {
                Ok(Some(v))
            }
        }
        fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
        where
            A: de::MapAccess<'de>,
        {
            let mut s = String::new();
            while let Some((k, v)) = map.next_entry::<String, serde_json::Value>()? {
                use std::fmt::Write;
                if !s.is_empty() {
                    s.push_str(", ");
                }
                let _ = write!(s, "\"{}\":{}", k, v);
            }
            if s.is_empty() {
                Ok(None)
            } else {
                Ok(Some(s))
            }
        }
        fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
        where
            A: de::SeqAccess<'de>,
        {
            let mut s = String::new();
            while let Some(v) = seq.next_element::<serde_json::Value>()? {
                if !s.is_empty() {
                    s.push_str(", ");
                }
                use std::fmt::Write;
                let _ = write!(s, "{}", v);
            }
            if s.is_empty() {
                Ok(None)
            } else {
                Ok(Some(s))
            }
        }
    }
    deserializer.deserialize_any(Visitor)
}

fn default_true() -> bool {
    true
}

fn legado_to_storage(source: &LegadoBookSource) -> Result<BookSource, String> {
    let now = Utc::now().timestamp();
    let rule_search = normalize_rule_value(merge_search_url(
        source.rule_search.clone(),
        source.search_url.as_deref(),
    ));
    Ok(BookSource {
        id: Uuid::new_v4().to_string(),
        name: source.name.clone(),
        url: source.url.clone(),
        source_type: source.source_type,
        group_name: if source.group_name.is_empty() {
            None
        } else {
            Some(source.group_name.clone())
        },
        enabled: source.enabled,
        custom_order: source.custom_order,
        weight: source.weight,
        rule_search,
        rule_book_info: normalize_rule_value(source.rule_book_info.clone()),
        rule_toc: normalize_rule_value(source.rule_toc.clone()),
        rule_content: normalize_rule_value(source.rule_content.clone()),
        login_url: source.login_url.clone(),
        login_ui: source.login_ui.clone(),
        login_check_js: source.login_check_js.clone(),
        header: source.header.clone(),
        js_lib: source.js_lib.clone(),
        cover_decode_js: source.cover_decode_js.clone(),
        rule_explore: normalize_rule_value(source.rule_explore.clone()),
        explore_url: source.explore_url.clone(),
        book_url_pattern: source.book_url_pattern.clone(),
        enabled_explore: source.enabled_explore,
        last_update_time: source.last_update_time,
        book_source_comment: source.book_source_comment.clone(),
        concurrent_rate: source.concurrent_rate.clone(),
        variable_comment: source.variable_comment.clone(),
        explore_screen: source.explore_screen,
        created_at: now,
        updated_at: now,
    })
}

fn normalize_rule_value(value: Option<serde_json::Value>) -> Option<String> {
    match value {
        None => None,
        Some(serde_json::Value::Null) => None,
        Some(serde_json::Value::Array(ref arr)) if arr.is_empty() => None,
        Some(serde_json::Value::Object(ref obj)) if obj.is_empty() => None,
        Some(v) => Some(normalize_rule_keys(v).to_string()),
    }
}

fn normalize_rule_keys(mut value: serde_json::Value) -> serde_json::Value {
    let Some(obj) = value.as_object_mut() else {
        return value;
    };

    // Keep this list in sync with core-source `legado::import::normalize_rule_keys`.
    // Out-of-sync mappings cause silent field drops on Legado JSON import.
    for (from, to) in [
        ("bookList", "book_list"),
        ("bookUrl", "book_url"),
        ("coverUrl", "cover_url"),
        ("lastChapter", "last_chapter"),
        ("wordCount", "word_count"),
        ("chapterList", "chapter_list"),
        ("chapterName", "chapter_name"),
        ("chapterUrl", "chapter_url"),
        ("nextContentUrl", "next_content_url"),
        ("nextTocUrl", "next_toc_url"),
        ("isVip", "is_vip"),
        ("isPay", "is_pay"),
        ("isVolume", "is_volume"),
        ("updateTime", "update_time"),
        ("canReName", "can_rename"),
        ("tocUrl", "toc_url"),
        ("bookInfoInit", "book_info_init"),
        ("sourceRegex", "source_regex"),
        ("replaceRegex", "replace_regex"),
        ("imageStyle", "image_style"),
        ("imageDecode", "image_decode"),
        ("payAction", "pay_action"),
        ("webJs", "web_js"),
        ("downloadUrls", "download_urls"),
        ("searchUrl", "search_url"),
        ("checkKeyWord", "check_keyword"),
        ("formatJs", "format_js"),
        ("preUpdateJs", "pre_update_js"),
    ] {
        if !obj.contains_key(to) {
            if let Some(v) = obj.remove(from) {
                obj.insert(to.to_string(), v);
            }
        }
    }
    for value in obj.values_mut() {
        if let Some(rule) = value.as_str() {
            *value = serde_json::Value::String(normalize_legado_rule(rule));
        }
    }
    value
}

fn normalize_legado_rule(rule: &str) -> String {
    if rule.trim_start().starts_with("@js:") || rule.trim_start().starts_with("js:") {
        return rule.to_string();
    }

    let (expr, suffix) = split_rule_suffix(rule);
    let normalized = expr.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.is_empty() && !suffix.is_empty() {
        return suffix.to_string();
    }
    format!("{}{}", normalized, suffix)
}

fn split_rule_suffix(rule: &str) -> (&str, &str) {
    for suffix in [
        "@textNodes",
        "@textNode",
        "@ownText",
        "@content",
        "@text",
        "@html",
        "@href",
        "@src",
    ] {
        if let Some(expr) = rule.strip_suffix(suffix) {
            return (expr, suffix);
        }
    }
    (rule, "")
}

fn merge_search_url(
    rule_search: Option<serde_json::Value>,
    search_url: Option<&str>,
) -> Option<serde_json::Value> {
    let mut value = rule_search.unwrap_or_else(|| serde_json::json!({}));
    if let (Some(url), Some(obj)) = (search_url, value.as_object_mut()) {
        // BATCH-23 (F-W1A-040)：原 `clean_legado_url(url)` 函数仅做 trim，
        // 函数名误导（暗示更复杂的清理）。内联到此处避免 indirection。
        obj.entry("search_url".to_string())
            .or_insert_with(|| serde_json::Value::String(url.trim().to_string()));
    }
    Some(value)
}

impl<'a> SourceDao<'a> {
    pub fn export_legado_json(&self) -> SqlResult<String> {
        let sources = self.get_all()?;
        let legado_sources: Vec<serde_json::Value> = sources
            .iter()
            .map(|s| {
                serde_json::json!({
                    "bookSourceUrl": s.url,
                    "bookSourceName": s.name,
                    "bookSourceGroup": s.group_name.as_deref().unwrap_or(""),
                    "bookSourceType": s.source_type,
                    "bookSourceComment": s.book_source_comment.as_deref().unwrap_or(""),
                    "bookUrlPattern": s.book_url_pattern.as_deref().unwrap_or(""),
                    "concurrentRate": s.concurrent_rate.as_deref().unwrap_or(""),
                    "customOrder": s.custom_order,
                    "enabled": s.enabled,
                    "enabledExplore": s.enabled_explore,
                    "weight": s.weight,
                    "lastUpdateTime": s.last_update_time,
                    "header": s.header.as_deref().unwrap_or(""),
                    "loginUrl": s.login_url.as_deref().unwrap_or(""),
                    "jsLib": s.js_lib.as_deref().unwrap_or(""),
                    "searchUrl": extract_search_url(&s.rule_search),
                    "exploreUrl": s.explore_url.as_deref().unwrap_or(""),
                    "ruleSearch": parse_rule_json(&s.rule_search),
                    "ruleBookInfo": parse_rule_json(&s.rule_book_info),
                    "ruleToc": parse_rule_json(&s.rule_toc),
                    "ruleContent": parse_rule_json(&s.rule_content),
                    "ruleExplore": parse_rule_json(&s.rule_explore),
                })
            })
            .collect();
        serde_json::to_string_pretty(&legado_sources)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))
    }
}

fn extract_search_url(rule_json: &Option<String>) -> String {
    if let Some(json_str) = rule_json {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(json_str) {
            return val
                .get("search_url")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
        }
    }
    String::new()
}

fn denormalize_rule_keys(mut value: serde_json::Value) -> serde_json::Value {
    let Some(obj) = value.as_object_mut() else {
        return value;
    };
    let renames: Vec<(&str, &str)> = vec![
        ("book_list", "bookList"),
        ("book_url", "bookUrl"),
        ("cover_url", "coverUrl"),
        ("last_chapter", "lastChapter"),
        ("word_count", "wordCount"),
        ("chapter_list", "chapterList"),
        ("chapter_name", "chapterName"),
        ("chapter_url", "chapterUrl"),
        ("next_content_url", "nextContentUrl"),
        ("next_toc_url", "nextTocUrl"),
        ("is_vip", "isVip"),
        ("is_pay", "isPay"),
        ("is_volume", "isVolume"),
        ("update_time", "updateTime"),
        ("can_rename", "canReName"),
        ("toc_url", "tocUrl"),
        ("book_info_init", "bookInfoInit"),
        ("source_regex", "sourceRegex"),
        ("replace_regex", "replaceRegex"),
        ("image_style", "imageStyle"),
        ("image_decode", "imageDecode"),
        ("pay_action", "payAction"),
        ("web_js", "webJs"),
        ("download_urls", "downloadUrls"),
        ("search_url", "searchUrl"),
        ("check_keyword", "checkKeyWord"),
        ("format_js", "formatJs"),
        ("pre_update_js", "preUpdateJs"),
    ];
    for (from, to) in renames {
        if let Some(v) = obj.remove(from) {
            obj.insert(to.to_string(), v);
        }
    }
    value
}

fn parse_rule_json(rule_json: &Option<String>) -> serde_json::Value {
    if let Some(json_str) = rule_json {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(json_str) {
            return denormalize_rule_keys(val);
        }
    }
    serde_json::Value::Null
}
