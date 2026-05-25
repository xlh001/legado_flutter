//! # bridge API - 暴露给 Dart 的接口
//!
//! 复杂类型使用 JSON 字符串传递，避免 FRB 类型解析问题。

use regex::Regex;

// ============================================================
// 核心初始化
// ============================================================

/// Smoke test — 验证桥接是否正常工作
pub fn ping() -> String {
    "pong".to_string()
}

/// 初始化函数 - 在 Flutter 应用启动时调用
pub fn init_legado(db_path: String) -> Result<String, String> {
    core_storage::database::init_database(&db_path)
        .map(|_| "初始化成功".to_string())
        .map_err(|e| format!("初始化失败: {}", e))
}

/// 获取数据库版本
pub fn get_db_version(db_path: String) -> Result<i32, String> {
    let conn =
        core_storage::database::get_connection(&db_path).map_err(|e| format!("连接失败: {}", e))?;
    Ok(conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap_or(0))
}

// ============================================================
// 书架 (Books) — 返回 JSON 字符串
// ============================================================

/// 获取书架上的所有书籍，返回 JSON 数组。
///
/// 批次 8 (2026-05): 加 `sort_order: i32` 参数（0=Default/1=Name/2=Author/
/// 3=TimeAdd/4=DurTime/5=ChapterCount，越界回 Default）。语义详见
/// [`core_storage::book_dao::BookSort::from_i32`]。Flutter 端 `bookshelfSort`
/// 设置直接透传过来。
pub fn get_all_books(db_path: String, sort_order: i32) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    let sort = core_storage::book_dao::BookSort::from_i32(sort_order);
    let books = dao
        .get_all_sorted(sort)
        .map_err(|e| format!("获取书籍列表失败: {}", e))?;
    serde_json::to_string(&books).map_err(|e| format!("序列化失败: {}", e))
}

/// 搜索书架中的书籍，返回 JSON 数组
pub fn search_books_offline(db_path: String, keyword: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    let books = dao
        .search(&keyword)
        .map_err(|e| format!("搜索失败: {}", e))?;
    serde_json::to_string(&books).map_err(|e| format!("序列化失败: {}", e))
}

/// 保存一本书到书架（book_json 为 storage::Book 的 JSON）
pub fn save_book(db_path: String, book_json: String) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let book: core_storage::models::Book =
        serde_json::from_str(&book_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    dao.upsert(&book).map_err(|e| format!("保存失败: {}", e))
}

/// 从书架删除一本书（同时级联删除该书籍的章节和阅读进度）
pub fn delete_book(db_path: String, id: String) -> Result<(), String> {
    // chapters / progress / read_records / bookmarks 表均通过 schema 的
    // ON DELETE CASCADE 自动级联删除（见 core-storage/src/database.rs
    // L162 等），无需在 bridge 层显式调用各 dao。
    let conn = open_db(&db_path)?;
    let book_dao = core_storage::book_dao::BookDao::new(&conn);
    book_dao.delete(&id).map_err(|e| format!("删除失败: {}", e))
}

// ============================================================
// 书架分组 (Book Groups) — 批次 7 / 返回 JSON 字符串
// ============================================================

/// 列出所有书架分组（按 sort_order 升序），返回 JSON 数组
pub fn list_book_groups(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let groups = core_storage::book_group_dao::BookGroupDao::list_all(&conn)
        .map_err(|e| format!("获取分组列表失败: {}", e))?;
    serde_json::to_string(&groups).map_err(|e| format!("序列化失败: {}", e))
}

/// 创建新分组，返回新分组的 JSON
pub fn create_book_group(
    db_path: String,
    name: String,
    sort_order: i32,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let group = core_storage::book_group_dao::BookGroupDao::create(&conn, &name, sort_order)
        .map_err(|e| format!("创建分组失败: {}", e))?;
    serde_json::to_string(&group).map_err(|e| format!("序列化失败: {}", e))
}

/// 更新分组的 name + sort_order
pub fn update_book_group(
    db_path: String,
    id: i64,
    name: String,
    sort_order: i32,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    core_storage::book_group_dao::BookGroupDao::update(&conn, id, &name, sort_order)
        .map_err(|e| format!("更新分组失败: {}", e))
}

/// 删除分组（同事务把组内书的 group_id 重置为 0）
pub fn delete_book_group(db_path: String, id: i64) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    core_storage::book_group_dao::BookGroupDao::delete(&mut conn, id)
        .map_err(|e| format!("删除分组失败: {}", e))
}

/// 列出某分组下的书籍。
///
/// `group_id` 语义：
/// - `-1` → 全部（等价 [`get_all_books`]）
/// - `0`  → 未分组
/// - `>= 1` → 具体某个分组
///
/// 批次 8 (2026-05): 加 `sort_order: i32`，与 [`get_all_books`] 同语义。
pub fn list_books_by_group(
    db_path: String,
    group_id: i64,
    sort_order: i32,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    let sort = core_storage::book_dao::BookSort::from_i32(sort_order);
    let books = dao
        .list_by_group_sorted(group_id, sort)
        .map_err(|e| format!("按分组获取书籍失败: {}", e))?;
    serde_json::to_string(&books).map_err(|e| format!("序列化失败: {}", e))
}

/// 把一本书移动到指定分组（`group_id = 0` 表示移回"未分组"）
pub fn set_book_group(
    db_path: String,
    book_id: String,
    group_id: i64,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    dao.set_group(&book_id, group_id)
        .map_err(|e| format!("移动书籍失败: {}", e))
}

// ============================================================
// 书源 (Book Sources) — 返回 JSON 字符串
// ============================================================

/// 获取所有书源，返回 JSON 数组
pub fn get_all_sources(db_path: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let sources = dao
        .get_all()
        .map_err(|e| format!("获取书源列表失败: {}", e))?;
    serde_json::to_string(&sources).map_err(|e| format!("序列化失败: {}", e))
}

/// 获取所有已启用的书源，返回 JSON 数组
pub fn get_enabled_sources(db_path: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let sources = dao
        .get_enabled()
        .map_err(|e| format!("获取已启用书源失败: {}", e))?;
    serde_json::to_string(&sources).map_err(|e| format!("序列化失败: {}", e))
}

/// 保存书源（source_json 为 storage::BookSource 的 JSON）
pub fn save_source(db_path: String, source_json: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let source: core_storage::models::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    dao.upsert(&source)
        .map(|_| ())
        .map_err(|e| format!("保存书源失败: {}", e))
}

/// 便捷函数：仅需 name + url 即可创建书源（自动填充 id/enabled/timestamps 等必填字段）
pub fn create_source(db_path: String, name: String, url: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let source = dao
        .create(&name, &url)
        .map_err(|e| format!("创建书源失败: {}", e))?;
    serde_json::to_string(&source).map_err(|e| format!("序列化失败: {}", e))
}

/// 删除书源
pub fn delete_source(db_path: String, id: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    dao.delete(&id).map_err(|e| format!("删除书源失败: {}", e))
}

/// 批量删除书源 (ids_json 为 JSON 字符串数组)
pub fn delete_sources_batch(db_path: String, ids_json: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let ids: Vec<String> =
        serde_json::from_str(&ids_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    // `mut`：`delete_batch` 现在内部开 transaction（需要 `&mut Connection`），所以
    // dao 持有可变借用，本地绑定也得是 `mut`。其它只读 dao 调用不受影响。
    let mut dao = core_storage::source_dao::SourceDao::new(&mut conn);
    dao.delete_batch(&ids)
        .map_err(|e| format!("批量删除书源失败: {}", e))
}

/// 启用 / 禁用书源
pub fn set_source_enabled(db_path: String, id: String, enabled: bool) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    dao.set_enabled(&id, enabled)
        .map_err(|e| format!("更新书源状态失败: {}", e))
}

/// 从 JSON 批量导入书源
pub fn import_sources_from_json(db_path: String, json: String) -> Result<i32, String> {
    let mut conn = open_db(&db_path)?;
    let mut dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let count = dao
        .import_from_json(&json)
        .map_err(|e| format!("导入书源失败: {}", e))?;
    Ok(count as i32)
}

/// 获取书源（core_source::types::BookSource 格式），用于下载
pub fn get_source_for_download(db_path: String, source_id: String) -> Result<String, String> {
    let storage_source = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id)
            .map_err(|e| format!("查询书源失败: {}", e))?
            .ok_or_else(|| format!("书源不存在: {}", source_id))?
    };
    let source = storage_to_source_book_source(&storage_source)?;
    serde_json::to_string(&source).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 章节 (Chapters) — 返回 JSON 字符串
// ============================================================

/// 获取某本书的所有章节，返回 JSON 数组
pub fn get_book_chapters(db_path: String, book_id: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
    let chapters = dao
        .get_by_book(&book_id)
        .map_err(|e| format!("获取章节列表失败: {}", e))?;
    serde_json::to_string(&chapters).map_err(|e| format!("序列化失败: {}", e))
}

/// 更新章节内容
pub fn update_chapter_content(
    db_path: String,
    chapter_id: String,
    content: String,
) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
    dao.update_content(&chapter_id, &content)
        .map_err(|e| format!("更新章节内容失败: {}", e))
}

/// 保存章节（chapter_json 为 storage::Chapter 的 JSON）
pub fn save_chapter(db_path: String, chapter_json: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let chapter: core_storage::models::Chapter =
        serde_json::from_str(&chapter_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
    dao.upsert(&chapter)
        .map_err(|e| format!("保存章节失败: {}", e))
}

/// 批量替换某本书的章节（chapters_json 为 storage::Chapter 数组 JSON），保留相同 URL 的已缓存正文
pub fn replace_book_chapters_preserving_content(
    db_path: String,
    book_id: String,
    chapters_json: String,
) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let chapters: Vec<core_storage::models::Chapter> =
        serde_json::from_str(&chapters_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let mut dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
    dao.replace_by_book_preserving_content(&book_id, &chapters)
        .map_err(|e| format!("批量保存章节失败: {}", e))
}

/// 批量替换某本书的章节（chapters_json 为 storage::Chapter 数组 JSON），不保留旧章节正文
pub fn replace_book_chapters(
    db_path: String,
    book_id: String,
    chapters_json: String,
) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let chapters: Vec<core_storage::models::Chapter> =
        serde_json::from_str(&chapters_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let mut dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
    dao.replace_by_book(&book_id, &chapters)
        .map_err(|e| format!("批量替换章节失败: {}", e))
}

/// 删除章节
pub fn delete_chapter(db_path: String, id: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
    dao.delete(&id).map_err(|e| format!("删除章节失败: {}", e))
}

// ============================================================
// 阅读进度 (Reading Progress)
// ============================================================

/// 保存阅读进度
pub fn save_reading_progress(
    db_path: String,
    book_id: String,
    chapter_index: i32,
    paragraph_index: i32,
    offset: i32,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::progress_dao::ProgressDao::new(&conn);
    dao.update_progress(&book_id, chapter_index, paragraph_index, offset)
        .map_err(|e| format!("保存阅读进度失败: {}", e))
}

/// 获取阅读进度，返回 JSON 或 null
pub fn get_reading_progress(db_path: String, book_id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::progress_dao::ProgressDao::new(&conn);
    let progress = dao
        .get_by_book(&book_id)
        .map_err(|e| format!("获取进度失败: {}", e))?;
    serde_json::to_string(&progress).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 书签 (Bookmarks) — 返回 JSON 字符串
// ============================================================

/// 获取某本书的所有书签，返回 JSON 数组
pub fn get_bookmarks(db_path: String, book_id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::progress_dao::ProgressDao::new(&conn);
    let bookmarks = dao
        .get_bookmarks(&book_id)
        .map_err(|e| format!("获取书签失败: {}", e))?;
    serde_json::to_string(&bookmarks).map_err(|e| format!("序列化失败: {}", e))
}

/// 添加书签，返回新书签的 JSON
pub fn add_bookmark(
    db_path: String,
    book_id: String,
    chapter_index: i32,
    paragraph_index: i32,
    content: Option<String>,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::progress_dao::ProgressDao::new(&conn);
    let bookmark = dao
        .create_bookmark(&book_id, chapter_index, paragraph_index, content.as_deref())
        .map_err(|e| format!("添加书签失败: {}", e))?;
    serde_json::to_string(&bookmark).map_err(|e| format!("序列化失败: {}", e))
}

/// 删除书签
pub fn delete_bookmark(db_path: String, bookmark_id: String) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::progress_dao::ProgressDao::new(&conn);
    dao.delete_bookmark(&bookmark_id)
        .map_err(|e| format!("删除书签失败: {}", e))
}

// ============================================================
// 在线搜索 & 内容获取 — 返回 JSON 字符串
// ============================================================

/// 搜索在线书籍（source_json 为 core_source::BookSource 的 JSON），返回搜索结果 JSON 数组
///
/// R82: 区分 ParserError::Empty（成功 0 结果，返回 `[]`）与其他失败（Network /
/// RuleConfig / Parse，作为 Err(String) 返回让 Dart 侧能 toast 出来）。
pub async fn search_books_online(source_json: String, keyword: String) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    match parser.search(&source, &keyword).await {
        Ok(results) => serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("[]".to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// 获取在线书籍详情，返回 JSON 或 null
pub async fn get_book_info_online(source_json: String, book_url: String) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    match parser.get_book_info(&source, &book_url).await {
        Ok(detail) => serde_json::to_string(&detail).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("null".to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// 获取在线章节列表，返回 JSON 数组
pub async fn get_chapter_list_online(
    source_json: String,
    book_url: String,
) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    match parser.get_chapters(&source, &book_url).await {
        Ok(chapters) => serde_json::to_string(&chapters).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("[]".to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// 获取在线章节内容，返回 JSON 或 null
pub async fn get_chapter_content_online(
    source_json: String,
    chapter_url: String,
) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    match parser.get_chapter_content(&source, &chapter_url).await {
        Ok(content) => serde_json::to_string(&content).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("null".to_string()),
        Err(e) => Err(e.to_string()),
    }
}

// ============================================================
// 诊断函数：导出书源原始规则用于调试
// ============================================================

/// 获取书源的原始 rule_search JSON（用于诊断），返回 JSON 或 null
pub fn get_source_rule_search_raw(
    db_path: String,
    source_id: String,
) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let source = dao
        .get_by_id(&source_id)
        .map_err(|e| format!("查询书源失败: {}", e))?
        .ok_or_else(|| format!("书源不存在: {}", source_id))?;
    serde_json::to_string(&source.rule_search).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 便捷函数：从数据库取书源后直接操作
// ============================================================

/// 从数据库加载书源并搜索（异步），返回搜索结果 JSON 数组
/// 包装结果：正常时返回 [{"ok":true,"data":[...]}]，失败时返回 [{"ok":false,"error":"..."}]
pub async fn search_with_source_from_db_v2(
    db_path: String,
    source_id: String,
    keyword: String,
) -> Result<String, String> {
    let storage_source = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id)
            .map_err(|e| format!("查询书源失败: {}", e))?
            .ok_or_else(|| format!("书源不存在: {}", source_id))?
    };

    let source = match storage_to_source_book_source(&storage_source) {
        Ok(s) => s,
        Err(e) => {
            let resp = serde_json::json!({"ok": false, "error": format!("转换书源失败: {}", e), "source_name": storage_source.name});
            return serde_json::to_string(&vec![resp]).map_err(|e| format!("序列化失败: {}", e));
        }
    };

    let parser = core_source::parser::BookSourceParser::new();
    match parser.search(&source, &keyword).await {
        Ok(results) => serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => {
            // R82: explicit "0 results" diagnostic envelope (preserves
            // the existing v2-wrapper UI contract for source-validation
            // pages that show why a search came back empty).
            let resp = serde_json::json!({
                "ok": false,
                "error": "搜索返回0结果",
                "source_name": source.name,
                "search_url": source
                    .rule_search
                    .as_ref()
                    .and_then(|r| r.search_url.as_ref().cloned())
                    .unwrap_or_default(),
            });
            serde_json::to_string(&vec![resp]).map_err(|e| format!("序列化失败: {}", e))
        }
        Err(e) => {
            // Network / RuleConfig / Parse — same envelope shape so the
            // diagnostic UI doesn't have to special-case error types.
            let resp = serde_json::json!({
                "ok": false,
                "error": e.to_string(),
                "source_name": source.name,
                "search_url": source
                    .rule_search
                    .as_ref()
                    .and_then(|r| r.search_url.as_ref().cloned())
                    .unwrap_or_default(),
            });
            serde_json::to_string(&vec![resp]).map_err(|e| format!("序列化失败: {}", e))
        }
    }
}

/// 从数据库加载书源并搜索（异步），返回搜索结果 JSON 数组
pub async fn search_with_source_from_db(
    db_path: String,
    source_id: String,
    keyword: String,
) -> Result<String, String> {
    let storage_source = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id)
            .map_err(|e| format!("查询书源失败: {}", e))?
            .ok_or_else(|| format!("书源不存在: {}", source_id))?
    };

    let source = storage_to_source_book_source(&storage_source)?;
    let parser = core_source::parser::BookSourceParser::new();
    match parser.search(&source, &keyword).await {
        Ok(results) => serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("[]".to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// 从数据库加载书源并获取章节内容（异步），返回 JSON 或 null
pub async fn get_chapter_content_with_source_from_db(
    db_path: String,
    source_id: String,
    chapter_url: String,
) -> Result<String, String> {
    let storage_source = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id)
            .map_err(|e| format!("查询书源失败: {}", e))?
            .ok_or_else(|| format!("书源不存在: {}", source_id))?
    };

    let source = storage_to_source_book_source(&storage_source)?;
    let parser = core_source::parser::BookSourceParser::new();
    match parser.get_chapter_content(&source, &chapter_url).await {
        Ok(content) => serde_json::to_string(&content).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("null".to_string()),
        Err(e) => Err(e.to_string()),
    }
}

// ============================================================
// 下载管理 (Download Management)
// ============================================================

/// 获取所有下载任务，返回 JSON 数组
pub fn get_download_tasks(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    let tasks = dao
        .get_all()
        .map_err(|e| format!("获取下载任务失败: {}", e))?;
    serde_json::to_string(&tasks).map_err(|e| format!("序列化失败: {}", e))
}

/// 根据书籍 ID 获取下载任务
pub fn get_download_task_by_book(db_path: String, book_id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    let tasks = dao
        .get_by_book(&book_id)
        .map_err(|e| format!("获取下载任务失败: {}", e))?;
    serde_json::to_string(&tasks).map_err(|e| format!("序列化失败: {}", e))
}

/// 创建下载任务（task_json 为 DownloadTask 的 JSON），返回 JSON
pub fn create_download_task(db_path: String, task_json: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let task: core_storage::models::DownloadTask =
        serde_json::from_str(&task_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.upsert(&task)
        .map_err(|e| format!("创建下载任务失败: {}", e))?;
    serde_json::to_string(&task).map_err(|e| format!("序列化失败: {}", e))
}

/// 事务性创建下载任务和章节
pub fn create_download_task_with_chapters(
    db_path: String,
    task_json: String,
    chapters_json: String,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let task: core_storage::models::DownloadTask =
        serde_json::from_str(&task_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let chapters: Vec<core_storage::models::DownloadChapter> =
        serde_json::from_str(&chapters_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.create_task_with_chapters(&task, &chapters)
        .map_err(|e| format!("创建下载任务失败: {}", e))?;
    serde_json::to_string(&task).map_err(|e| format!("序列化失败: {}", e))
}

/// 更新下载任务状态
pub fn update_download_task_status(
    db_path: String,
    task_id: String,
    status: i32,
    error_message: Option<String>,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.update_status(&task_id, status, error_message.as_deref())
        .map_err(|e| format!("更新下载状态失败: {}", e))
}

/// 更新下载进度
pub fn update_download_progress(
    db_path: String,
    task_id: String,
    downloaded_chapters: i32,
    downloaded_size: i64,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.update_progress(&task_id, downloaded_chapters, downloaded_size)
        .map_err(|e| format!("更新下载进度失败: {}", e))
}

/// 删除下载任务（同时清理已下载的文件）
pub fn delete_download_task(db_path: String, task_id: String) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    let inferred_root = std::path::Path::new(&db_path)
        .parent()
        .map(|parent| parent.join("downloads"));
    dao.delete_with_files_in_root(&task_id, inferred_root.as_deref())
        .map_err(|e| format!("删除下载任务失败: {}", e))
}

/// 获取下载章节列表，返回 JSON 数组
pub fn get_download_chapters(db_path: String, task_id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    let chapters = dao
        .get_chapters_by_task(&task_id)
        .map_err(|e| format!("获取下载章节失败: {}", e))?;
    serde_json::to_string(&chapters).map_err(|e| format!("序列化失败: {}", e))
}

/// 批量创建下载章节记录
pub fn batch_create_download_chapters(
    db_path: String,
    chapters_json: String,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let chapters: Vec<core_storage::models::DownloadChapter> =
        serde_json::from_str(&chapters_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.batch_create_chapters(&chapters)
        .map_err(|e| format!("批量创建下载章节失败: {}", e))
}

/// 更新下载章节状态
pub fn update_download_chapter_status(
    db_path: String,
    chapter_id: String,
    status: i32,
    file_path: Option<String>,
    file_size: i64,
    error_message: Option<String>,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.update_chapter_status(
        &chapter_id,
        status,
        file_path.as_deref(),
        file_size,
        error_message.as_deref(),
    )
    .map_err(|e| format!("更新下载章节状态失败: {}", e))
}

/// 下载并保存单个章节到本地文件，更新数据库状态
pub async fn download_and_save_chapter(
    db_path: String,
    task_id: String,
    download_chapter_id: String,
    source_json: String,
    chapter_url: String,
    download_dir: String,
) -> Result<String, String> {
    let download_root = resolve_download_root(&db_path, &download_dir)?;
    core_storage::download_dao::set_download_root(&download_root.to_string_lossy());
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    let content = parser.get_chapter_content(&source, &chapter_url).await;

    // R82: differentiate "got chapter but body empty / parse failed" from
    // "network or rule error". The former gets logged as "章节内容为空"
    // (matches legacy behaviour), the latter surfaces the real reason
    // so the download UI can show what went wrong.
    let text = match &content {
        Ok(c) => c.content.clone(),
        Err(core_source::ParserError::Empty) => {
            mark_chapter_failed(&db_path, &task_id, &download_chapter_id, "章节内容为空")?;
            return Err("章节内容为空".to_string());
        }
        Err(e) => {
            let msg = e.to_string();
            let short = if msg.len() > 200 { &msg[..200] } else { &msg };
            mark_chapter_failed(&db_path, &task_id, &download_chapter_id, short)?;
            return Err(msg);
        }
    };

    let file_name = safe_download_file_name(&download_chapter_id)?;
    let file_path = download_root.join(file_name);
    let parent = file_path
        .parent()
        .ok_or_else(|| "下载文件路径无效".to_string())?;
    std::fs::create_dir_all(parent).map_err(|e| format!("创建目录失败: {}", e))?;
    let root_canonical = download_root
        .canonicalize()
        .map_err(|e| format!("下载目录无效: {}", e))?;
    let parent_canonical = parent
        .canonicalize()
        .map_err(|e| format!("下载目录无效: {}", e))?;
    if !parent_canonical.starts_with(&root_canonical) {
        return Err("下载文件路径越界".to_string());
    }
    if std::fs::symlink_metadata(&file_path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err("下载文件不能是符号链接".to_string());
    }
    std::fs::write(&file_path, &text).map_err(|e| format!("写入文件失败: {}", e))?;
    let file_size = std::fs::metadata(&file_path)
        .map(|m| m.len() as i64)
        .unwrap_or(0);
    let file_path = file_path.to_string_lossy().to_string();

    // 批次 69 (BATCH-07b)：把"成功路径写章节状态 + 重算任务进度"两步
    // SQL 包进单事务。之前两步独立 commit，中间 panic 时章节标 status=2
    // 但任务整体进度未刷新，留下脏数据。with_transaction Drop-rollback
    // 兜底任意 `?` 早返。
    crate::transaction::with_transaction(&db_path, |tx| {
        core_storage::download_dao::DownloadDao::update_chapter_status_in_tx(
            tx,
            &download_chapter_id,
            2,
            Some(&file_path),
            file_size,
            None,
        )
        .map_err(|e| format!("更新章节状态失败: {}", e))?;
        recompute_download_task_status_in_tx(tx, &task_id)
            .map_err(|e| format!("更新任务状态失败: {}", e))?;
        Ok(())
    })?;

    Ok(file_path)
}

fn recompute_download_task_status(
    dao: &core_storage::download_dao::DownloadDao<'_>,
    task_id: &str,
) -> rusqlite::Result<()> {
    let chapters = dao.get_chapters_by_task(task_id)?;
    let completed_count = chapters.iter().filter(|c| c.status == 2).count() as i32;
    let failed_count = chapters.iter().filter(|c| c.status == 3).count() as i32;
    let total_count = chapters.len() as i32;
    let total_size: i64 = chapters.iter().map(|c| c.file_size).sum();

    dao.update_progress(task_id, completed_count, total_size)?;

    if completed_count + failed_count >= total_count {
        if failed_count > 0 {
            dao.update_status(
                task_id,
                4,
                Some(&format!(
                    "部分章节下载失败 (成功: {}, 失败: {})",
                    completed_count, failed_count
                )),
            )?;
        } else {
            dao.update_status(task_id, 3, None)?;
        }
    }
    Ok(())
}

/// `&Transaction` 版的 [`recompute_download_task_status`]：让 caller 在
/// 外层事务内调用，与 `update_chapter_status_in_tx` 配对跑单事务（批次
/// 69 / BATCH-07b）。
///
/// 实现上利用 `rusqlite::Transaction: Deref<Target=Connection>`：
/// `DownloadDao::new(tx)` 通过 deref coercion 把 `&Transaction` 当
/// `&Connection` 用，所有 `dao.execute(...)` / `dao.query_row(...)`
/// 都在 caller 提供的事务内执行（SQLite 事务状态是连接级），无需再写
/// 一份并行的 SQL。
fn recompute_download_task_status_in_tx(
    tx: &rusqlite::Transaction<'_>,
    task_id: &str,
) -> rusqlite::Result<()> {
    let dao = core_storage::download_dao::DownloadDao::new(tx);
    recompute_download_task_status(&dao, task_id)
}

fn resolve_download_root(db_path: &str, download_dir: &str) -> Result<std::path::PathBuf, String> {
    let expected = std::path::Path::new(db_path)
        .parent()
        .ok_or_else(|| "数据库路径无效".to_string())?
        .join("downloads");
    std::fs::create_dir_all(&expected).map_err(|e| format!("创建下载目录失败: {}", e))?;
    let expected_canonical = expected
        .canonicalize()
        .map_err(|e| format!("下载目录无效: {}", e))?;
    let requested = std::path::Path::new(download_dir);
    let requested_canonical = requested
        .canonicalize()
        .map_err(|e| format!("下载目录无效: {}", e))?;
    if requested_canonical != expected_canonical {
        return Err("下载目录必须位于数据库目录下的 downloads".to_string());
    }
    Ok(expected_canonical)
}

fn safe_download_file_name(download_chapter_id: &str) -> Result<String, String> {
    let id = download_chapter_id.trim();
    if id.is_empty()
        || id == "."
        || id == ".."
        || id.contains('/')
        || id.contains('\\')
        || id.contains(std::path::MAIN_SEPARATOR)
    {
        return Err("下载章节 ID 不能作为安全文件名".to_string());
    }
    Ok(format!("{id}.txt"))
}

/// 验证书源规则（source_json 为 core_source::types::BookSource 的 JSON），返回 JSON 数组
pub fn validate_source_rules(source_json: String) -> Result<String, String> {
    core_source::validate_source_json(&source_json).map_err(|e| format!("验证书源规则失败: {}", e))
}

/// 验证数据库中的书源规则，返回 JSON 数组 [{field, severity, message}]
pub fn validate_source_from_db(db_path: String, source_id: String) -> Result<String, String> {
    let storage_source = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id)
            .map_err(|e| format!("查询书源失败: {}", e))?
            .ok_or_else(|| format!("书源不存在: {}", source_id))?
    };
    let source = storage_to_source_book_source(&storage_source)?;
    let issues = core_source::validate_book_source(&source);
    serde_json::to_string(&issues).map_err(|e| format!("序列化失败: {}", e))
}

/// 实跑 live test — 在静态校验之上 顺序跑 search / book_info / toc / content
/// 4 路 (批次 21 / 05-19, funcId 109)。
///
/// 返回 [`core_source::LiveTestReport`] 的 JSON 字符串。任一阶段失败不
/// 短路，4 个 stages 一定都会出现在结果里 — 失败的 stage 用 `error` 字段
/// 标明原因（[`ParserError::Display`] 字符串）。
///
/// `keyword` 由 UI 端传入，建议默认 `"测试"` / `"test"`。
pub async fn validate_source_live(
    db_path: String,
    source_id: String,
    keyword: String,
) -> Result<String, String> {
    let storage_source = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id)
            .map_err(|e| format!("查询书源失败: {}", e))?
            .ok_or_else(|| format!("书源不存在: {}", source_id))?
    };
    let source = storage_to_source_book_source(&storage_source)?;
    let report = core_source::run_live_test(&source, &keyword).await;
    serde_json::to_string(&report).map_err(|e| format!("序列化失败: {}", e))
}

/// 批量书源实跑校验（批次 check-sources / PR2, funcId 119）。
///
/// `source_ids_json` 是 JSON 字符串数组，例如 `["id1","id2"]`。
/// `config_json` 是 [`core_source::CheckConfig`] 的 JSON 字符串。
/// 返回 JSON 数组 `Vec<SourceCheckProgress>` — 每个元素是一个源的校验
/// 结果（stages + latency + error）。最后一个元素 `is_done = true`。
///
/// 每个源跑完后同时写回 `book_sources` 表的 `respond_time` /
/// `last_check_error` / `last_check_at`。
///
/// 并发受 config.concurrency 控制（默认 8）；单源超时 config.timeout_secs
/// （默认 180s）。
pub async fn batch_check_sources(
    db_path: String,
    source_ids_json: String,
    config_json: String,
) -> Result<String, String> {
    let source_ids: Vec<String> = serde_json::from_str(&source_ids_json)
        .map_err(|e| format!("解析 source_ids JSON 失败: {}", e))?;
    let config: core_source::CheckConfig = serde_json::from_str(&config_json)
        .map_err(|e| format!("解析 CheckConfig JSON 失败: {}", e))?;

    // Load all sources from DB
    let storage_sources: Vec<core_storage::models::BookSource> = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        source_ids
            .iter()
            .filter_map(|id| dao.get_by_id(id).ok().flatten())
            .collect()
    };

    if storage_sources.is_empty() {
        return Err("没有找到任何书源".to_string());
    }

    // Convert to core_source types
    let mut sources: Vec<core_source::types::BookSource> =
        Vec::with_capacity(storage_sources.len());
    let mut results: Vec<core_source::SourceCheckProgress> =
        Vec::with_capacity(storage_sources.len());

    for s in &storage_sources {
        match storage_to_source_book_source(s) {
            Ok(src) => sources.push(src),
            Err(e) => {
                results.push(core_source::SourceCheckProgress {
                    source_id: s.id.clone(),
                    source_name: s.name.clone(),
                    stages: vec![],
                    total_latency_ms: 0,
                    error: Some(e),
                    is_done: false,
                });
            }
        }
    }

    if sources.is_empty() {
        // All sources failed conversion; return what we have (errors only)
        if let Some(last) = results.last_mut() {
            last.is_done = true;
        }
        return serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e));
    }

    let db_path_clone = db_path.clone();
    let results_arc = std::sync::Arc::new(std::sync::Mutex::new(results));
    let results_for_closure = results_arc.clone();

    core_source::batch_run_live_test(
        sources,
        &config,
        std::sync::Arc::new(move |progress| {
            // Write back to DB (best effort, failure does not interrupt the batch)
            let respond_time = if progress
                .stages
                .iter()
                .all(|s| s.ok)
            {
                progress.total_latency_ms
            } else {
                0
            };
            let error = progress.error.as_deref();
            if let Ok(conn) = core_storage::database::get_connection(&db_path_clone) {
                let now = chrono::Utc::now().timestamp();
                let _ = conn.execute(
                    "UPDATE book_sources SET respond_time = ?, last_check_error = ?, \
                     last_check_at = ?, updated_at = ? WHERE id = ?",
                    rusqlite::params![respond_time, error, now, now, progress.source_id],
                );
            }
            // Push into shared vec
            if let Ok(mut guard) = results_for_closure.lock() {
                guard.push(progress);
            }
        }),
    )
    .await;

    // Unwrap the Arc<Mutex<Vec>> back to Vec
    let results = std::sync::Arc::into_inner(results_arc)
        .expect("Arc should have exactly one reference")
        .into_inner()
        .expect("Mutex should not be poisoned");
    serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e))
}

/// 导出所有书源为 Legado 兼容 JSON 数组（camelCase 格式）
pub fn export_all_sources(db_path: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    dao.export_legado_json()
        .map_err(|e| format!("导出失败: {}", e))
}

/// BATCH-27a: 导出书架为 JSON 数组。对齐原版
/// `BookshelfViewModel.kt:102-128 exportBookshelf` —— 仅写
/// `name` / `author` / `intro` 三字段（Legado 备份/分享格式），
/// 2-space pretty 缩进。空书架返回 `"[]"`。
///
/// 返回 JSON 字符串而不是文件，由 Dart 端写入 documents_dir/books.json，
/// 与 [`export_all_sources`] 同模式。
pub fn export_bookshelf_json(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    let books = dao
        .get_all()
        .map_err(|e| format!("查询书架失败: {}", e))?;
    let entries: Vec<serde_json::Value> = books
        .iter()
        .map(|b| {
            serde_json::json!({
                "name": b.name,
                "author": b.author.as_deref().unwrap_or(""),
                "intro": b.intro.as_deref().unwrap_or(""),
            })
        })
        .collect();
    serde_json::to_string_pretty(&entries).map_err(|e| format!("序列化失败: {}", e))
}

/// BATCH-27b: 单本书目录刷新（"更新目录"批量任务的 leaf FRB）。
///
/// 对齐原 legado `MainViewModel.kt:159 updateToc(bookUrl)`：
///
/// 1. `BookDao::get_by_id(book_id)` → 拿到 Book；找不到返错
/// 2. `SourceDao::get_by_id(book.source_id)` → 拿到 BookSource；
///    找不到返错（local book 应在 Dart 端 filter，不会进到这里）
/// 3. `parser.get_chapters(&source, &toc_url_or_book_url)` → 拉远端 toc
/// 4. `ChapterDao::replace_by_book_preserving_content_in_tx`
///    保章节 content cache，与原版 `delByBook + insert` 等价
/// 5. `BookDao::upsert_in_tx`：更新 `last_check_time = now` +
///    `chapter_count = chapters.len()`，对齐原版 `book.totalChapterNum`
/// 6. 返回新章节数（i32）
///
/// 步骤 4-5 走单事务（与 [`download_and_save_chapter`] / `import_local_book`
/// 同款 `with_transaction` helper），中间 panic 时整批 rollback 不留脏
/// 数据。FK / 外键由 `replace_by_book_preserving_content_in_tx` 保证：
/// 必须先 BookDao::upsert（chapter.book_id 是外键），再写章节；这里反过
/// 来——书在第 1 步已 get_by_id 拿到，先 replace 章节再 upsert book 元数
/// 据是合法的（books.id 已存在）。
///
/// 错误信息含中文 context 对齐 `.trellis/spec/rust-core/error-handling.md`。
pub async fn update_book_toc(db_path: String, book_id: String) -> Result<i32, String> {
    // 1+2: 同一 Connection 内拿 Book + Source，避免两次 open_db
    let (book, storage_source, toc_url) = {
        let mut conn = open_db(&db_path)?;
        let book = {
            let dao = core_storage::book_dao::BookDao::new(&conn);
            dao.get_by_id(&book_id)
                .map_err(|e| format!("查询书 {} 失败: {}", book_id, e))?
                .ok_or_else(|| format!("书不存在: {}", book_id))?
        };
        if book.source_id.trim().is_empty() {
            return Err(format!("书 {} 缺少书源 ID（本地书无法刷新目录）", book_id));
        }
        let toc_url = book
            .toc_url
            .clone()
            .filter(|t| !t.trim().is_empty())
            .or_else(|| book.book_url.clone())
            .filter(|u| !u.trim().is_empty())
            .ok_or_else(|| format!("书 {} 缺少 book_url / toc_url", book_id))?;
        let source_dao = core_storage::source_dao::SourceDao::new(&mut conn);
        let storage_source = source_dao
            .get_by_id(&book.source_id)
            .map_err(|e| format!("查询书源 {} 失败: {}", book.source_id, e))?
            .ok_or_else(|| format!("书源不存在: {}", book.source_id))?;
        (book, storage_source, toc_url)
    };

    // 3: 转 storage::BookSource → core_source::types::BookSource 后跑 parser
    let source = storage_to_source_book_source(&storage_source)?;
    let parser = core_source::parser::BookSourceParser::new();
    let chapter_infos = match parser.get_chapters(&source, &toc_url).await {
        Ok(c) => c,
        Err(core_source::ParserError::Empty) => {
            return Err(format!("书 {} 章节列表为空（书源规则未匹配）", book_id));
        }
        Err(e) => {
            return Err(format!("书 {} 章节列表抓取失败: {}", book_id, e));
        }
    };

    let now = chrono::Utc::now().timestamp();
    let total_count = chapter_infos.len() as i32;
    let book_id_owned = book_id.clone();
    let storage_chapters: Vec<core_storage::models::Chapter> = chapter_infos
        .iter()
        .map(|ch| core_storage::models::Chapter {
            id: uuid::Uuid::new_v4().to_string(),
            book_id: book_id_owned.clone(),
            index_num: ch.index,
            title: ch.title.clone(),
            url: ch.url.clone(),
            content: None, // preserve 路径会从已有章节拷回
            is_volume: ch.is_volume,
            is_checked: false,
            start: 0,
            end: 0,
            created_at: now,
            updated_at: now,
        })
        .collect();

    // 4+5: 单事务：替换章节（保留 content cache）+ 更新书元数据
    crate::transaction::with_transaction(&db_path, |tx| {
        core_storage::chapter_dao::ChapterDao::replace_by_book_preserving_content_in_tx(
            tx,
            &book_id_owned,
            &storage_chapters,
        )
        .map_err(|e| format!("替换章节失败: {}", e))?;
        let mut updated = book.clone();
        updated.chapter_count = total_count;
        updated.last_check_time = Some(now);
        updated.updated_at = now;
        core_storage::book_dao::BookDao::upsert_in_tx(tx, &updated)
            .map_err(|e| format!("更新书元数据失败: {}", e))?;
        Ok(())
    })?;

    Ok(total_count)
}

// ============================================================
// 替换规则 (Replace Rules) — 返回 JSON 字符串
// ============================================================

/// 获取所有替换规则，返回 JSON 数组
pub fn get_replace_rules(db_path: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
    let rules = dao
        .get_all()
        .map_err(|e| format!("获取替换规则列表失败: {}", e))?;
    serde_json::to_string(&rules).map_err(|e| format!("序列化失败: {}", e))
}

/// 保存替换规则（rule_json 为 storage::ReplaceRule 的 JSON），upsert 语义
pub fn save_replace_rule(db_path: String, rule_json: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let rule: core_storage::models::ReplaceRule =
        serde_json::from_str(&rule_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
    dao.upsert(&rule)
        .map_err(|e| format!("保存替换规则失败: {}", e))
}

/// 删除替换规则
pub fn delete_replace_rule(db_path: String, id: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
    dao.delete(&id)
        .map_err(|e| format!("删除替换规则失败: {}", e))
}

/// 启用 / 禁用替换规则
pub fn set_replace_rule_enabled(db_path: String, id: String, enabled: bool) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
    dao.set_enabled(&id, enabled)
        .map_err(|e| format!("更新替换规则状态失败: {}", e))
}

/// 对内容应用所有已启用的替换规则。
///
/// 这是 P1-7 的修复：之前 Dart 端在每次切章节时通过 FRB 拉一次规则列表，
/// 然后在主 isolate 里循环 `RegExp(...).replaceAll`，长正文 + 多条规则会
/// 阻塞 UI。现在统一下沉到 Rust 单次调用：
///
///   - 编译失败的规则只 warn 一次（避免每章都 spam 日志）
///   - 整个循环在 Rust 端跑，不占 Dart 主 isolate
///   - 调用方只需把 db_path + 原始内容传过来
///
/// 同时 Dart 侧的 ReplaceRule 缓存也可以复用：参数加 `cache_generation`，
/// Rust 端用 OnceLock + RwLock 保存上次拉取的规则；调用方在 ReplaceRule
/// CRUD 后递增 generation 即可让缓存失效，不必每次走 DAO。
///
/// **R24**: scope 现在按 Legado 原版语义匹配。`book_name` 与
/// `book_origin` 由 caller 提供（reader_page 持有），filter 逻辑见
/// [`matches_scope`]。`apply_to_title=true` 表示本次跑作用于标题
/// 的规则；false 表示作用于正文。
pub fn apply_replace_rules(
    db_path: String,
    content: String,
    cache_generation: i64,
    book_name: Option<String>,
    book_origin: Option<String>,
    apply_to_title: bool,
) -> Result<String, String> {
    apply_replace_rules_impl(
        &db_path,
        &content,
        cache_generation,
        book_name.as_deref().unwrap_or(""),
        book_origin.as_deref().unwrap_or(""),
        apply_to_title,
    )
}

fn apply_replace_rules_impl(
    db_path: &str,
    content: &str,
    cache_generation: i64,
    book_name: &str,
    book_origin: &str,
    apply_to_title: bool,
) -> Result<String, String> {
    // R123: rule list cache + compiled regex cache live under a SINGLE
    // mutex (`REPLACE_RULES_CACHE`). Previously the two caches each had
    // their own lock, so two concurrent callers with different
    // generations could interleave such that one's `ensure_generation`
    // wiped the other's freshly-built regex entries — leaving callers
    // with regexes from the wrong generation. Unified lock guarantees
    // that within a single critical section both halves of the cache
    // are observed at the same generation.
    //
    // R12: compiled regexes are cloned out of the cache (cheap — Regex
    // is internally Arc-based) before releasing the lock. `replace_all`
    // runs over arbitrary user-supplied content WITHOUT holding the
    // lock, so concurrent callers don't serialise on regex evaluation.
    //
    // R27/R47: regex cache is tagged with `cache_generation`. When the
    // caller bumps the generation (rule CRUD), the regex entries are
    // dropped — guaranteeing a freshly-edited pattern actually takes
    // effect, and bounding memory to the current generation's enabled
    // rule count.
    //
    // R24: filter by scope (book_name / book_origin substring match) +
    // scope_title vs scope_content before compiling, so unrelated rules
    // don't even hit the regex cache.
    //
    // **F-W1A-019 加固（2026-05-21, BATCH-09）**：cache miss 时的 SQL
    // 调用（`open_db` + `dao.get_enabled`）从 mutex 内移出，改为两阶段：
    // 1. Phase 1 (lock)：probe cache，命中即 Some(Arc)；未命中 drop lock
    // 2. Phase 2 (lock-free)：跑 SQL 加载规则
    // 3. Phase 3 (lock)：double-check（其它线程可能在 SQL 期间已填好
    //    cache）→ 用别人的或存自己的；同时 ensure_regex_generation +
    //    compile regexes
    //
    // 这把 SQL（典型几十 ms 冷启动）从全局锁里移出来，章节切换 burst
    // 时不再串行化 reader 主线程。double-check 保持 generation 隔离不
    // 变量（`unified_cache_keeps_generations_isolated` 仍过）。
    let compiled: Vec<(Regex, String)> = {
        // Phase 1: probe cache 是否已命中（仅持锁很短一瞬）
        let cached_rules: Option<std::sync::Arc<Vec<core_storage::models::ReplaceRule>>> = {
            let cache = REPLACE_RULES_CACHE
                .lock()
                .map_err(|e| format!("replace rules cache lock poisoned: {e}"))?;
            cache.try_get_rules(db_path, cache_generation)
        }; // lock 在此释放，下面跑 SQL 不持锁

        // Phase 2: 不持锁跑 SQL（仅 cache miss 时；命中走 None 分支）
        let freshly_loaded: Option<std::sync::Arc<Vec<core_storage::models::ReplaceRule>>> =
            if cached_rules.is_some() {
                None
            } else {
                let mut conn = open_db(db_path)?;
                let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
                let fresh = dao
                    .get_enabled()
                    .map_err(|e| format!("加载替换规则失败: {}", e))?;
                Some(std::sync::Arc::new(fresh))
            };

        // Phase 3: 重新加锁，double-check，写入或采用别人的，编译 regex
        let mut cache = REPLACE_RULES_CACHE
            .lock()
            .map_err(|e| format!("replace rules cache lock poisoned: {e}"))?;
        let rules = match cached_rules {
            Some(arc) => arc,
            None => {
                // 别的线程可能在我们跑 SQL 时已填好 cache（同 generation 同 db_path）。
                // 优先用它的 — 两份 generation 一致，业务上等价；少一次写入降抖。
                if let Some(other) = cache.try_get_rules(db_path, cache_generation) {
                    other
                } else {
                    let arc = freshly_loaded.expect("freshly_loaded must be Some on cache miss");
                    cache.store_rules(db_path, cache_generation, arc.clone());
                    arc
                }
            }
        };
        cache.ensure_regex_generation(cache_generation);

        // `rules` is an Arc — clone bumps the refcount only, but the
        // borrow checker also needs us to detach the iteration source
        // from `cache` so we can take `&mut cache` for `get_or_compile_regex`
        // inside the filter_map closure.
        let rules_for_iter = rules.clone();
        rules_for_iter
            .iter()
            .filter(|r| !r.pattern.is_empty())
            .filter(|r| {
                if apply_to_title {
                    r.scope_title
                } else {
                    r.scope_content
                }
            })
            .filter(|r| matches_scope(r, book_name, book_origin))
            .filter_map(|rule| {
                cache
                    .get_or_compile_regex(&rule.id, &rule.pattern)
                    .map(|re| (re.clone(), rule.replacement.clone()))
            })
            .collect()
    }; // lock released here — `replace_all` runs lock-free below.

    let mut out = content.to_string();
    for (re, replacement) in compiled.iter() {
        out = re.replace_all(&out, replacement.as_str()).into_owned();
    }
    Ok(out)
}

/// R24: scope 子串匹配 + exclude 优先。模仿原 Legado
/// `ReplaceRuleDao.findEnabledByContentScope` 的 SQL LIKE 语义：
///
/// - `scope` 为 `None` 或空字符串 → 全局，对所有书生效
/// - 否则 `scope` 字符串里**包含** `book_name` 或 `book_origin` 即匹配
/// - `exclude_scope` 同语义但反向：命中即跳过该规则
/// - 当 `book_name` / `book_origin` 自身为空时，不参与子串匹配（防御
///   `"".contains("") == true` 的边界 case），相当于"我们不知道这本
///   书是什么"，scope 非空的规则就会被跳过
fn matches_scope(rule: &core_storage::models::ReplaceRule, book_name: &str, book_origin: &str) -> bool {
    let scope = rule.scope.as_deref().unwrap_or("");
    if scope.is_empty() {
        // Even with global scope, an excluded book name/origin still skips.
        if let Some(ref exclude) = rule.exclude_scope {
            if !exclude.is_empty() {
                let name_excluded = !book_name.is_empty() && exclude.contains(book_name);
                let origin_excluded =
                    !book_origin.is_empty() && exclude.contains(book_origin);
                if name_excluded || origin_excluded {
                    return false;
                }
            }
        }
        return true;
    }
    let name_match = !book_name.is_empty() && scope.contains(book_name);
    let origin_match = !book_origin.is_empty() && scope.contains(book_origin);
    if !(name_match || origin_match) {
        return false;
    }
    if let Some(ref exclude) = rule.exclude_scope {
        if !exclude.is_empty() {
            let name_excluded = !book_name.is_empty() && exclude.contains(book_name);
            let origin_excluded =
                !book_origin.is_empty() && exclude.contains(book_origin);
            if name_excluded || origin_excluded {
                return false;
            }
        }
    }
    true
}

/// R123: unified cache for both the enabled-rule list and the
/// compiled regexes. Both halves are tagged with the caller's
/// `cache_generation` and can only be observed inside the single
/// `Mutex` below — so concurrent callers with different generations
/// can't interleave such that one wipes the other's freshly-built
/// state. See [`apply_replace_rules_impl`] for the full rationale.
///
/// Compile failures are remembered as `None` within a single
/// generation so we don't re-warn on every chapter; advancing the
/// generation clears them too, which is the right thing if the user
/// fixed the bad pattern.
///
/// R48: the rule-list cache key includes `db_path` so a multi-DB
/// workflow (test fixtures, profile switching, two isolates pointed
/// at different files) doesn't get a hit from another DB's rule set.
struct ReplaceRulesCache {
    /// Rule list cached by `(db_path, generation)`. `None` until
    /// the first cache miss populates it.
    rule_list: Option<(String, i64, std::sync::Arc<Vec<core_storage::models::ReplaceRule>>)>,
    /// Generation tag for the regex entries below; advancing it clears
    /// all entries. `None` on first use (cache empty).
    regex_generation: Option<i64>,
    /// Compiled regex by `(rule_id, pattern)`. A `None` value remembers
    /// a compile failure within the current generation.
    regex_entries: std::collections::HashMap<(String, String), Option<regex::Regex>>,
}

impl ReplaceRulesCache {
    fn new() -> Self {
        Self {
            rule_list: None,
            regex_generation: None,
            regex_entries: std::collections::HashMap::new(),
        }
    }

    /// Returns the cached rule list when `(db_path, generation)` matches;
    /// otherwise loads via the closure and stores. The caller is responsible
    /// for calling [`Self::ensure_regex_generation`] right after — this
    /// method intentionally does NOT touch the regex side so that callers
    /// observe both halves in a single critical section.
    ///
    /// **保留供 cache_concurrency_tests 等单测复用**。生产路径
    /// `apply_replace_rules_impl` 已迁移到 [`Self::try_get_rules`] +
    /// [`Self::store_rules`] 两阶段 API（F-W1A-019, BATCH-09）—— SQL 移出
    /// 全局锁，章节切换 burst 时不再串行化 reader 主线程。
    #[cfg(test)]
    fn get_or_load_rules<F>(
        &mut self,
        db_path: &str,
        generation: i64,
        load: F,
    ) -> Result<std::sync::Arc<Vec<core_storage::models::ReplaceRule>>, String>
    where
        F: FnOnce() -> Result<Vec<core_storage::models::ReplaceRule>, String>,
    {
        if let Some((ref cached_path, gen, ref rules)) = self.rule_list {
            if gen == generation && cached_path == db_path {
                return Ok(rules.clone());
            }
        }
        let fresh = load()?;
        let arc = std::sync::Arc::new(fresh);
        self.rule_list = Some((db_path.to_string(), generation, arc.clone()));
        Ok(arc)
    }

    /// **F-W1A-019 阶段 1（probe-only）**：只读检查 `(db_path, generation)`
    /// 是否命中；命中返回 `Some(Arc)`，未命中返回 `None`。caller 拿到 None
    /// 后应该 drop lock 后跑 SQL，再用 [`Self::store_rules`] 写回。
    ///
    /// 关键：本方法不跑 SQL、不分配、不写 cache，只读 — 适合在 lock 内
    /// 跑亚毫秒级检查。
    fn try_get_rules(
        &self,
        db_path: &str,
        generation: i64,
    ) -> Option<std::sync::Arc<Vec<core_storage::models::ReplaceRule>>> {
        if let Some((ref cached_path, gen, ref rules)) = self.rule_list {
            if gen == generation && cached_path == db_path {
                return Some(rules.clone());
            }
        }
        None
    }

    /// **F-W1A-019 阶段 3（store-only）**：写入 SQL 加载好的 fresh rules。
    /// 调用 caller 在 lock-free 跑完 SQL 后重新加锁 + double-check 后调本
    /// 方法。覆盖任何已有的不同 `(db_path, generation)` 组合 — generation
    /// 单调推进语义不变。
    fn store_rules(
        &mut self,
        db_path: &str,
        generation: i64,
        rules: std::sync::Arc<Vec<core_storage::models::ReplaceRule>>,
    ) {
        self.rule_list = Some((db_path.to_string(), generation, rules));
    }

    /// Drop cached regex entries when the caller's generation changes.
    /// Cheap when generation matches (no allocation, no work).
    fn ensure_regex_generation(&mut self, generation: i64) {
        if self.regex_generation == Some(generation) {
            return;
        }
        self.regex_entries.clear();
        self.regex_generation = Some(generation);
    }

    /// Get-or-compile a regex within the current generation. Returns
    /// `None` if the pattern fails to compile (and remembers the failure
    /// so we don't re-warn on every chapter).
    fn get_or_compile_regex(&mut self, id: &str, pattern: &str) -> Option<&regex::Regex> {
        // R50: single hash via `entry` instead of contains_key + insert + get.
        let key = (id.to_string(), pattern.to_string());
        self.regex_entries
            .entry(key)
            .or_insert_with(|| {
                let compiled = regex::Regex::new(pattern);
                if let Err(ref e) = compiled {
                    tracing::warn!("ReplaceRule {} regex 编译失败: {}", id, e);
                }
                compiled.ok()
            })
            .as_ref()
    }
}

static REPLACE_RULES_CACHE: std::sync::LazyLock<std::sync::Mutex<ReplaceRulesCache>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(ReplaceRulesCache::new()));

// ============================================================
// 本地备份 / 恢复 (批次 10)
// ============================================================

/// 把当前 DB 5 张表（books / book_groups / bookmarks / replace_rules /
/// book_sources）导出成 Legado 兼容的 zip 备份。文件名由 caller 指定。
pub fn export_backup_zip(db_path: String, out_zip_path: String) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    core_storage::backup_dao::export_to_zip(&conn, &out_zip_path)
}

/// 解压 zip → 字段映射 → upsert 入库。返回 `ImportSummary` 的 JSON 字符串
/// （`{books, groups, bookmarks, replace_rules, sources, errors}`）。
pub fn import_backup_zip(db_path: String, zip_path: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let summary = core_storage::backup_dao::import_from_zip(&mut conn, &zip_path)?;
    serde_json::to_string(&summary).map_err(|e| format!("序列化 ImportSummary 失败: {}", e))
}

/// 列 zip 内**已识别**的 Legado 备份文件名（不解析内容，dry-run 用）。
/// 返回 JSON 字符串数组。
pub fn validate_backup_zip(zip_path: String) -> Result<String, String> {
    let names = core_storage::backup_dao::validate_zip(&zip_path)?;
    serde_json::to_string(&names).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// WebDAV 同步 (批次 11)
// ============================================================

/// 探活 — 用 PROPFIND Depth=0 验证 url + 凭据是否能访问。
/// 设置页"测试连接"按钮调用。成功返回 ()，失败返回错误描述。
pub async fn webdav_check(
    url: String,
    user: String,
    password: String,
) -> Result<(), String> {
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    client.check().await
}

/// 列远端 base_url 下的 backup*.zip 文件名（已过滤非 backup 前缀的项）。
/// 返回 JSON 字符串数组。Flutter 侧用于"从 WebDAV 恢复" 的下拉单选。
pub async fn webdav_list_backups(
    url: String,
    user: String,
    password: String,
) -> Result<String, String> {
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    let names = client.list_files().await?;
    serde_json::to_string(&names).map_err(|e| format!("序列化失败: {}", e))
}

/// 本地 export → 临时 zip → PUT 到 WebDAV。
///
/// 实现：用 [`tempfile::NamedTempFile`] 创建一次性 zip，调
/// [`core_storage::backup_dao::export_to_zip`] 写入，然后 `std::fs::read`
/// 整体读出 PUT 上去。`NamedTempFile` 会在 fn 返回时自动清理。
///
/// 不需要事先 MKCOL：调用方应自行保证 `url` 指向已存在的 collection,
/// 否则 PUT 一般会 404 / 409。如未来需要"首次同步建目录"，可在 UI 端
/// 单独调 `webdav_check` 失败时回退尝试 mkcol。
pub async fn webdav_upload_backup(
    db_path: String,
    url: String,
    user: String,
    password: String,
    file_name: String,
) -> Result<(), String> {
    // 1. export 到本地临时 zip
    let tmp = tempfile::Builder::new()
        .prefix("legado-backup-")
        .suffix(".zip")
        .tempfile()
        .map_err(|e| format!("创建临时文件失败: {}", e))?;
    let tmp_path = tmp
        .path()
        .to_str()
        .ok_or_else(|| "临时文件路径无效".to_string())?
        .to_string();
    {
        let conn = open_db(&db_path)?;
        core_storage::backup_dao::export_to_zip(&conn, &tmp_path)?;
    }
    // 2. 读 bytes
    let bytes = std::fs::read(&tmp_path).map_err(|e| format!("读取临时 zip 失败: {}", e))?;
    // 3. PUT
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    client.upload(&file_name, bytes).await?;
    // tmp 在此处 drop,自动清理
    drop(tmp);
    Ok(())
}

/// GET 远端 zip → 写到临时文件 → import → 返回 ImportSummary JSON。
///
/// 与 [`import_backup_zip`] 行为完全一致，区别是 zip 来源是远端 GET
/// 而非本地路径。失败时临时文件依然由 `NamedTempFile` 自动清理。
pub async fn webdav_download_backup(
    db_path: String,
    url: String,
    user: String,
    password: String,
    file_name: String,
) -> Result<String, String> {
    // 1. GET
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    let bytes = client.download(&file_name).await?;
    // 2. 写到临时 zip
    let tmp = tempfile::Builder::new()
        .prefix("legado-restore-")
        .suffix(".zip")
        .tempfile()
        .map_err(|e| format!("创建临时文件失败: {}", e))?;
    let tmp_path = tmp
        .path()
        .to_str()
        .ok_or_else(|| "临时文件路径无效".to_string())?
        .to_string();
    std::fs::write(&tmp_path, &bytes).map_err(|e| format!("写入临时 zip 失败: {}", e))?;
    // 3. import
    let summary = {
        let mut conn = open_db(&db_path)?;
        core_storage::backup_dao::import_from_zip(&mut conn, &tmp_path)?
    };
    drop(tmp);
    serde_json::to_string(&summary).map_err(|e| format!("序列化 ImportSummary 失败: {}", e))
}

/// 删除远端 backup zip（用户在恢复对话框里也可"清理远端旧备份"）。
pub async fn webdav_delete_backup(
    url: String,
    user: String,
    password: String,
    file_name: String,
) -> Result<(), String> {
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    client.delete(&file_name).await
}

// ============================================================
// 通用 WebDAV 列目录 / 下载 (BATCH-27c / 05-22)
// ============================================================
//
// `webdav_list_backups` / `webdav_download_backup` 写死 backup 前缀过滤
// 与 zip 导入；本节加通用版本服务 RemoteBooksPage（PRD §A）：列目录
// 不过滤 + 通用下载。返回结构 [{name, isDir, size, lastModified}]。

/// BATCH-27c: 列任意子路径下的所有 entries（不过滤 backup 前缀）。
/// `path` 相对 url，空串 = 根目录。返 JSON 数组：
/// `[{"name":"x","isDir":false,"size":1024,"lastModified":1735732496}, ...]`。
///
/// path 内 `..` / 绝对路径 → Err，浅层 SSRF 防护。
pub async fn webdav_list_dir(
    url: String,
    user: String,
    password: String,
    path: String,
) -> Result<String, String> {
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    let entries = client.list_dir(&path).await?;
    serde_json::to_string(&entries).map_err(|e| format!("序列化失败: {}", e))
}

/// BATCH-27c: 通用 GET → 写本地路径。返写入字节数。
/// `target_local_path` 父目录由 caller 创建（remote_books/ 等）；本 fn
/// 不主动 mkdir 让 caller 显式控制持久化目录决策。
pub async fn webdav_download_file(
    url: String,
    user: String,
    password: String,
    remote_path: String,
    target_local_path: String,
) -> Result<i64, String> {
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    let path = std::path::Path::new(&target_local_path);
    let bytes = client.download_to_path(&remote_path, path).await?;
    Ok(bytes as i64)
}

// ============================================================
// 书架批量编辑 (BATCH-27d) — funcId 115-117
// ============================================================

/// BATCH-27d: 切换书的「允许更新」状态（canUpdate）。
/// can_update=false 后批量目录刷新（27b update_toc）会跳过此本，对齐
/// 27b spec 「Dart 端 filter 契约」`!isLocal && canUpdate`。
pub fn set_book_can_update(
    db_path: String,
    id: String,
    can_update: bool,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    dao.set_can_update(&id, can_update)
        .map_err(|e| format!("切换书 {} canUpdate 失败: {}", id, e))
}

// 注：清缓存 FRB 复用 BATCH-26a 已有的 `clear_book_cache(db_path, book_id)
// -> Result<i64, String>` (funcId 80)，不在 27d 重新加 FRB。

/// BATCH-27d: 删除书 + 可选删除本地源文件。
///
/// `delete_file=true` 时，对本地书（source_id='local'）删
/// `<documents_dir>/local_books/<id>_*` 文件；对远程书（27c-1 下载到
/// `<documents_dir>/remote_books/...`）按 `book.local_path` 删文件；非
/// 本地非远程书（webdav 已上架但无本地缓存）忽略 file 删除。
///
/// 不破坏现有 `delete_book(funcId 47)` binary contract — 那个 FRB 仅
/// 删 db 行 + 级联删 chapters / progress（schema ON DELETE CASCADE）。
/// 27d 新加这个 FRB 让批量删除时可选「同时删本地源文件」语义对齐
/// 原 legado `LocalBook.deleteBook(it, deleteOriginal)`。
///
/// `documents_dir` 由 caller 传，避免 Rust 端再调 `path_provider`。
pub fn delete_book_with_file(
    db_path: String,
    id: String,
    delete_file: bool,
    documents_dir: String,
) -> Result<(), String> {
    // 先拿 book 拿到 source_id 和可能的 local_path —— 删了 row 后查不到
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    let book = dao
        .get_by_id(&id)
        .map_err(|e| format!("查询书 {} 失败: {}", id, e))?
        .ok_or_else(|| format!("书不存在: {}", id))?;

    // 1. 删 db 行（chapters / progress 级联删）
    dao.delete(&id)
        .map_err(|e| format!("删除书 {} 失败: {}", id, e))?;

    if !delete_file {
        return Ok(());
    }

    // 2. 删本地文件（best-effort，失败不阻塞 db 删除已成功）
    let docs = std::path::Path::new(&documents_dir);

    // 本地书：book_url = "loc_book:<absolute_path>"，对齐
    // `crate::local_book` LOC_BOOK_URL_PREFIX 约定。
    if book.source_id == "local" {
        if let Some(book_url) = book.book_url.as_ref() {
            if let Some(local_path) = book_url.strip_prefix("loc_book:") {
                let lp = std::path::Path::new(local_path);
                // 仅当文件落在 documents_dir 子树内才删（防越界 rm 项目外
                // 文件，例如用户从 Downloads 直接 import 的源文件）
                if lp.starts_with(docs) && lp.is_file() {
                    let _ = std::fs::remove_file(lp);
                }
            }
        }
    }

    // 远程书：27c-1 下载到 `<documents_dir>/remote_books/<safe_name>`
    // 后调 import_local_book 落库 → book.book_url 也被设为
    // "loc_book:<remote_books_dir/safe_name>"，与本地书路径同款，
    // 上面的 `book.source_id == "local"` 分支已经覆盖（因为 27c-1
    // import_local_book 让所有进入书架的 file 都走 source_id='local'）。

    Ok(())
}

/// BATCH-27e: 按一条「书籍 URL」找匹配的启用书源（funcId 118）。
///
/// 对齐原 Legado `BookSourceDao.getBookSourceAddBook(baseUrl)` + 遍历
/// `hasBookUrlPattern` regex 兜底（`BookshelfViewModel.addBookByUrl:53-65`
/// 双路径）。caller 拿到 source_json 后调用 `get_book_info_online`
/// + `get_chapter_list_online` 完成 add_url 流程。
///
/// 返回：
/// - 找到 → `Some(source_json_string)`，shape 与 `get_all_sources` 单
///   元素一致
/// - 找不到 / 没启用书源 / book_url 空 → `None`
/// - SQL 异常 / 序列化失败 → `Err(String)`
pub fn find_book_source_for_url(
    db_path: String,
    book_url: String,
) -> Result<Option<String>, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let matched = dao
        .find_for_book_url(&book_url)
        .map_err(|e| format!("查找书源失败: {}", e))?;
    match matched {
        None => Ok(None),
        Some(s) => serde_json::to_string(&s)
            .map(Some)
            .map_err(|e| format!("序列化书源失败: {}", e)),
    }
}

// ============================================================
// 备份密码持久化 (批次 12 / 05-19)
// ============================================================
//
// 与原 Legado `LocalConfig.password` 行为一致：明文存到 prefs 文件
// （`<documents_dir>/legado_local.json`），密码空串等价于"未设密码"。
// 真正加密生效在导出/导入 zip 时：调
// [`core_storage::legado_aes::encrypt_legado_aes`] / `decrypt_legado_aes`
// 把这个密码作为 key 派生输入。
//
// **不**加密 webdav.json 本机存储 —— 那是另一份独立配置，原 Legado 也只
// 加密**导出 zip 内的 web_dav_password 字段**，不加密本机 prefs。

const LEGADO_LOCAL_FILE: &str = "legado_local.json";

/// **DEPRECATED (BATCH-03b / F-W1A-020)**: backup 密码已迁移到 Dart 端
/// secure_storage（key `backup_password`，Android Keystore-backed
/// EncryptedSharedPreferences / iOS Keychain）。本 fn 仅保留以支持
/// 启动期一次性迁移：webdav_config_page 首次打开时若 secure_storage
/// 命中失败但 legado_local.json 仍含旧 password，会读出 → 写
/// secure_storage → 调本 fn 传空串清理。新代码不要调用。
///
/// FRB funcId 71/72 保留契约不删，方便未来 backup zip 加密功能（如真接入）
/// 直接复用；同时避免 binding regen 风险。**不**加 `#[deprecated]` attr —— Dart
/// 端迁移路径仍要调本 fn，attr 会污染编译输出。
///
/// 设置备份密码（持久化到 `<documents_dir>/legado_local.json` 的
/// `"password"` 字段）。
///
/// `password = ""` 等价于"未设密码"（与原 Legado `LocalConfig.password`
/// 默认值一致）—— 此时备份 zip 仍走 AES 加密但 key = MD5("")。
pub fn set_backup_password(documents_dir: String, password: String) -> Result<(), String> {
    let path = std::path::Path::new(&documents_dir).join(LEGADO_LOCAL_FILE);
    // BATCH-23 (F-W1A-037)：legado_local.json 解析失败时，原代码 silent
    // 用空 Map 覆盖原文件 → 用户其它配置（未来扩展字段）丢失。现在解析
    // 失败时先把损坏内容写到 `.<unix_ts>.bak` 副本保留，再用空 Map 重置，
    // 用户可手工恢复。timestamp 后缀防覆盖既存 .bak。
    let mut map: serde_json::Map<String, serde_json::Value> = match std::fs::read_to_string(&path)
    {
        Ok(text) => match serde_json::from_str::<serde_json::Value>(&text) {
            Ok(v) => v.as_object().cloned().unwrap_or_else(|| {
                // JSON 合法但顶层非 object（如数组 / scalar）— 同样写 .bak。
                _backup_corrupt_legado_local(&path, &text, "顶层非 JSON object");
                serde_json::Map::new()
            }),
            Err(e) => {
                _backup_corrupt_legado_local(&path, &text, &format!("JSON 解析失败: {}", e));
                serde_json::Map::new()
            }
        },
        Err(_) => serde_json::Map::new(),
    };
    map.insert(
        "password".to_string(),
        serde_json::Value::String(password),
    );
    let text = serde_json::to_string(&serde_json::Value::Object(map))
        .map_err(|e| format!("序列化 legado_local.json 失败: {}", e))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("创建配置目录失败: {}", e))?;
    }
    std::fs::write(&path, text).map_err(|e| format!("写入 legado_local.json 失败: {}", e))
}

/// BATCH-23 (F-W1A-037) helper：把损坏的 legado_local.json 内容写到
/// `.<unix_ts>.bak` 副本以便用户事后恢复。失败仅 log warn，不阻塞主流程。
fn _backup_corrupt_legado_local(path: &std::path::Path, content: &str, reason: &str) {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let bak_path = path.with_extension(format!("json.{}.bak", ts));
    match std::fs::write(&bak_path, content) {
        Ok(_) => tracing::warn!(
            "legado_local.json 损坏（{}）；原内容已备份到 {} ，将以空配置重置",
            reason,
            bak_path.display()
        ),
        Err(e) => tracing::warn!(
            "legado_local.json 损坏（{}）；备份到 {} 失败 ({})，将以空配置重置（原内容丢失）",
            reason,
            bak_path.display(),
            e
        ),
    }
}

/// **DEPRECATED (BATCH-03b / F-W1A-020)**: 见 [`set_backup_password`] 顶部
/// 注释。本 fn 仅保留供启动期一次性迁移路径读旧 legado_local.json 的
/// password 字段；新代码读备份密码请走 Dart 端 `readSecret('backup_password')`。
///
/// 读取当前备份密码；不存在或 JSON 解析失败时返回空串（等价"未设密码"）。
pub fn get_backup_password(documents_dir: String) -> Result<String, String> {
    let path = std::path::Path::new(&documents_dir).join(LEGADO_LOCAL_FILE);
    match std::fs::read_to_string(&path) {
        Ok(text) => {
            let v: serde_json::Value = match serde_json::from_str(&text) {
                Ok(v) => v,
                Err(e) => {
                    // BATCH-23 (F-W1A-037)：read 路径不动文件，但加 warn log
                    // 让 op 知道配置文件已损坏（set_backup_password 下一次
                    // 调用时会写 .bak 副本）。
                    tracing::warn!(
                        "legado_local.json 解析失败 ({}); 视为未设密码",
                        e
                    );
                    return Ok(String::new());
                }
            };
            Ok(v.get("password")
                .and_then(|p| p.as_str())
                .unwrap_or("")
                .to_string())
        }
        Err(_) => Ok(String::new()),
    }
}

// ============================================================
// 本地书导入 (批次 13 / 05-19)
// ============================================================

/// 导入本地书（TXT / EPUB / UMD）。返回 `{"book_id": "..."}` JSON 字符串。
///
/// 流程（对齐原 Legado `ImportBookActivity` MVP）：
/// 1. 按 `file_path` 扩展名分发 `core_parser` 三个解析器之一
/// 2. 复制源文件到 `<documents_dir>/local_books/<book_id>_<basename>`
///    防原文件移动 / 删除断链
/// 3. 确保虚拟"本地书"书源（id="local"/url="loc_book"）存在
/// 4. 构造 `Book`：name 优先取 EPUB metadata.title，fallback basename(去扩展)
///    `book_url = "loc_book:<copied_path>"`，`source_id = "local"`
/// 5. `BookDao::upsert(&book)`（books.id 是 chapters.book_id 外键，必须先写）
/// 6. 章节适配后 `ChapterDao::replace_by_book`（不保留旧章节正文）；
///    批次 69 起 5 + 6 包进单事务，避免 FK / 中间错误留脏 book 行
///
/// 不在 scope 内：mobi / pdf / cbz、TxtTocRule 自定义切分、cover 提取。
pub fn import_local_book(
    db_path: String,
    file_path: String,
    documents_dir: String,
) -> Result<String, String> {
    let path = std::path::Path::new(&file_path);
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .ok_or_else(|| "缺少文件扩展名".to_string())?;

    // basename 不带扩展，作为 Book.name 的 fallback
    let basename_no_ext = path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();

    // 1. 分发 parser
    let (chapters, epub_meta) = match ext.as_str() {
        "txt" => (
            core_parser::txt::parse_txt_file(&file_path)
                .map_err(|e| format!("TXT 解析失败: {}", e))?,
            None,
        ),
        "epub" => {
            let (meta, chs) = core_parser::epub::parse_epub_file(&file_path)
                .map_err(|e| format!("EPUB 解析失败: {}", e))?;
            (chs, Some(meta))
        }
        "umd" => (
            core_parser::umd::parse_umd_file(&file_path)
                .map_err(|e| format!("UMD 解析失败: {}", e))?,
            None,
        ),
        other => return Err(format!("不支持的文件类型: .{}", other)),
    };

    if chapters.is_empty() {
        return Err("文件解析后无任何章节".to_string());
    }

    // 2. 生成 book_id（先生成才能拼复制后的目标路径）
    let book_id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().timestamp();

    // 3. 复制源文件到 local_books
    let copied_path = crate::local_book::copy_to_local_books_dir(
        path,
        std::path::Path::new(&documents_dir),
        &book_id,
    )?;

    // 4. 打开 db + 确保虚拟 source
    //
    // ensure_local_source 只 INSERT 一行虚拟书源（幂等：先 SELECT 命中即
    // return），与下面 book + chapters 写入解耦放在独立连接里执行；即使
    // 后续 with_transaction 内的 BookDao / ChapterDao 写入失败回滚，已写
    // 入的虚拟书源也不应回滚（它是公共资源，下一次导入仍要用）。
    let source_id = {
        let mut conn = open_db(&db_path)?;
        crate::local_book::ensure_local_source(&mut conn)?
    };

    // 5. 构造 Book
    let book_url = format!(
        "{}:{}",
        crate::local_book::LOCAL_BOOK_URL_KEY,
        copied_path.display()
    );
    // EPUB metadata.title / author 优先，fallback basename
    let (name, author) = match epub_meta {
        Some(ref m) => {
            let n = m
                .title
                .clone()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| basename_no_ext.clone());
            let a = m
                .author
                .clone()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());
            (n, a)
        }
        None => (basename_no_ext.clone(), None),
    };
    let total_word_count: i32 = chapters
        .iter()
        .map(|c| c.content.chars().count() as i32)
        .sum();
    let latest_chapter_title = chapters.last().map(|c| c.title.clone());
    let book = core_storage::models::Book {
        id: book_id.clone(),
        source_id,
        source_name: Some("本地书".to_string()),
        name,
        author,
        cover_url: None,
        chapter_count: chapters.len() as i32,
        latest_chapter_title,
        intro: None,
        kind: None,
        book_url: Some(book_url),
        toc_url: None,
        last_check_time: None,
        last_check_count: 0,
        total_word_count,
        can_update: false, // 本地书不需要远端更新
        order_time: now,
        latest_chapter_time: Some(now),
        custom_cover_path: None,
        custom_info_json: None,
        dur_chapter_index: 0,
        dur_chapter_pos: 0,
        dur_chapter_title: None,
        dur_chapter_time: 0,
        group_id: 0,
        created_at: now,
        updated_at: now,
    };

    // 6. 章节适配 + 入库
    //
    // 批次 69 (BATCH-07b)：把 BookDao::upsert 与 ChapterDao::replace_by_book
    // 包进单事务，FK / 中间错误时整批回滚不留脏 book 行。之前两步独立
    // 事务，先成功 upsert book 后 chapter 写入失败时（很少见，但可能因
    // SQLite 锁竞争），book 行已 commit 留下"books 表多了一条但 chapters
    // 全空"的脏数据。
    //
    // 必须先 upsert Book（books.id 是 chapters.book_id 外键），再
    // replace_by_book 写章节，否则触发 FOREIGN KEY constraint failed。
    let storage_chapters = crate::local_book::parser_chapters_to_storage(&chapters, &book_id, now);
    crate::transaction::with_transaction(&db_path, |tx| {
        core_storage::book_dao::BookDao::upsert_in_tx(tx, &book)
            .map_err(|e| format!("写入书籍失败: {}", e))?;
        core_storage::chapter_dao::ChapterDao::replace_by_book_in_tx(
            tx,
            &book_id,
            &storage_chapters,
        )
        .map_err(|e| format!("写入章节失败: {}", e))?;
        Ok(())
    })?;

    serde_json::to_string(&serde_json::json!({ "book_id": book_id }))
        .map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 阅读时长统计 (批次 14 / 05-19) — ReadRecord
// ============================================================
//
// 对齐原 Legado `ReadRecord.kt`。reader_page Timer 每 60s 调
// [`add_read_time`] 累加；设置页"阅读统计" UI 通过 [`list_read_records`]
// + [`get_total_read_time`] 拉数据；书架卡片需要单本时长用
// [`get_read_record`]（MVP 暂不在书架卡片显示，但 fn 留着以备扩展）。

/// 累加某本书的阅读时长（秒）。若 `book_id` 已有记录则 read_time +=
/// delta_seconds + last_read_at = now；否则 INSERT 新行。
pub fn add_read_time(
    db_path: String,
    book_id: String,
    book_name: String,
    delta_seconds: i64,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::read_record_dao::ReadRecordDao::new(&conn);
    dao.add_time(&book_id, &book_name, delta_seconds)
        .map_err(|e| format!("累加阅读时长失败: {}", e))
}

/// 取单本书的阅读记录，返回 JSON `Option<ReadRecord>`。
pub fn get_read_record(db_path: String, book_id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::read_record_dao::ReadRecordDao::new(&conn);
    let rec = dao
        .get_by_book(&book_id)
        .map_err(|e| format!("查询阅读记录失败: {}", e))?;
    serde_json::to_string(&rec).map_err(|e| format!("序列化失败: {}", e))
}

/// 列出所有阅读记录（按 last_read_at DESC），返回 JSON 数组。
/// 设置页"阅读统计"用。
pub fn list_read_records(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::read_record_dao::ReadRecordDao::new(&conn);
    let list = dao
        .list_all()
        .map_err(|e| format!("获取阅读记录列表失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

/// 全局总阅读时长（秒）。空表返回 0。
pub fn get_total_read_time(db_path: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::read_record_dao::ReadRecordDao::new(&conn);
    dao.total_read_time()
        .map_err(|e| format!("获取总阅读时长失败: {}", e))
}

// ============================================================
// 缓存管理 (批次 15 / 05-19) — CacheStats
// ============================================================
//
// 对齐原 Legado `CacheActivity.kt`。设置页"缓存管理" UI 通过
// [`list_books_with_cache_stats`] 拉数据；用户点单本/全局清空时分别
// 调 [`clear_book_cache`] / [`clear_all_cache`]。后者只动 chapters.content
// 字段（置 NULL），不删 chapters 行 — 章节列表与目录依旧完整，仅释放
// 已下载的正文文本。

/// 单本已缓存章节数（content IS NOT NULL 且非空串）。MVP 暂未在 UI 端
/// 直接调用（list_books_with_cache_stats 已包含），但保留便于上层扩展
/// 单本详情页。
pub fn count_cached_chapters_for_book(
    db_path: String,
    book_id: String,
) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::cache_stats_dao::CacheStatsDao::new(&conn);
    dao.count_cached_chapters_for_book(&book_id)
        .map_err(|e| format!("查询缓存章节数失败: {}", e))
}

/// 列出所有书的缓存统计（按 cached DESC），返回
/// `Vec<BookCacheStats>` 的 JSON。
pub fn list_books_with_cache_stats(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::cache_stats_dao::CacheStatsDao::new(&conn);
    let stats = dao
        .list_books_with_cache_stats()
        .map_err(|e| format!("获取缓存统计失败: {}", e))?;
    serde_json::to_string(&stats).map_err(|e| format!("序列化失败: {}", e))
}

/// 单本清空缓存：UPDATE chapters SET content=NULL WHERE book_id=?。
/// 返回受影响行数。
pub fn clear_book_cache(db_path: String, book_id: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::cache_stats_dao::CacheStatsDao::new(&conn);
    dao.clear_book_cache(&book_id)
        .map_err(|e| format!("清空书籍缓存失败: {}", e))
}

/// 全局清空缓存：UPDATE chapters SET content=NULL（无 WHERE）。
/// 返回受影响行数。
pub fn clear_all_cache(db_path: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::cache_stats_dao::CacheStatsDao::new(&conn);
    dao.clear_all_cache()
        .map_err(|e| format!("全局清空缓存失败: {}", e))
}

// ============================================================
// RSS 源管理 (批次 16 / 05-19) — RssSource
// ============================================================
//
// 对齐原 Legado RssSource CRUD。schema 在批次 16 (v12) 新增
// (`rss_sources` 表 + 4 个索引)，DAO 在 [`core_storage::rss_source_dao`]。
// 本节仅做"源管理"骨架；拉取 / 解析 / 文章列表 / 收藏 UI 留批次 17/18。

/// 列出所有 RSS 源（按 custom_order ASC, source_name ASC），返回 JSON 数组。
pub fn rss_source_list_all(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let list = dao
        .list_all()
        .map_err(|e| format!("获取 RSS 源列表失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

/// 列出已启用的 RSS 源。
pub fn rss_source_list_enabled(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let list = dao
        .list_enabled()
        .map_err(|e| format!("获取已启用 RSS 源失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

/// 列出指定分组下的 RSS 源（严格按 source_group = ? 匹配）。
pub fn rss_source_list_by_group(db_path: String, group: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let list = dao
        .list_by_group(&group)
        .map_err(|e| format!("按分组获取 RSS 源失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

/// DISTINCT 分组列表（跳过 NULL/空），返回 JSON 字符串数组。
pub fn rss_source_list_groups(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let groups = dao
        .list_groups()
        .map_err(|e| format!("获取 RSS 分组失败: {}", e))?;
    serde_json::to_string(&groups).map_err(|e| format!("序列化失败: {}", e))
}

/// 按 source_url 取单条 RSS 源，返回 JSON `Option<RssSource>`。
pub fn rss_source_get(db_path: String, url: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let s = dao
        .get_by_url(&url)
        .map_err(|e| format!("查询 RSS 源失败: {}", e))?;
    serde_json::to_string(&s).map_err(|e| format!("序列化失败: {}", e))
}

/// upsert 单条 RSS 源（source_json = `RssSource` 的 JSON），返回受影响行数。
pub fn rss_source_upsert(db_path: String, source_json: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let source: core_storage::models::RssSource =
        serde_json::from_str(&source_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    dao.upsert(&source)
        .map(|n| n as i64)
        .map_err(|e| format!("写入 RSS 源失败: {}", e))
}

/// 切换 enabled，返回受影响行数。
pub fn rss_source_set_enabled(
    db_path: String,
    url: String,
    enabled: bool,
) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    dao.set_enabled(&url, enabled)
        .map(|n| n as i64)
        .map_err(|e| format!("更新 RSS 源状态失败: {}", e))
}

/// 按 source_url 删除 RSS 源，返回受影响行数。
pub fn rss_source_delete(db_path: String, url: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    dao.delete_by_url(&url)
        .map(|n| n as i64)
        .map_err(|e| format!("删除 RSS 源失败: {}", e))
}

/// 从 JSON 批量导入 RSS 源（支持端口内部 / 原 Legado 双格式）。返回
/// [`core_storage::models::RssImportSummary`] 的 JSON 字符串
/// （`{added, updated, skipped}`）。
pub fn rss_source_import_json(db_path: String, json: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let summary = dao.import_from_json(&json)?;
    serde_json::to_string(&summary).map_err(|e| format!("序列化 RssImportSummary 失败: {}", e))
}

// ============================================================
// RSS 拉取 + 文章列表 (批次 17 / 05-19)
// ============================================================
//
// 6 个 fn (funcId 91-96) — 沿袭 RssSource CRUD（批次 16）/ webdav 异步
// (批次 11) 的格式。`rss_get_articles` 为 async：拉取 + 解析 + upsert
// 入库 + 返回排序后的列表；其它 5 个为 sync。

/// async 拉取 + 解析 + upsert + 返回入库后排序的列表。
///
/// 工作流：
/// 1. 从 DB 取 RssSource（不存在 → Err）
/// 2. 调 RssParser::get_articles 拉取 + 解析（XML 路 / 规则路自适应）
/// 3. RssArticleDao::upsert_batch（保留每条已有 read_time/star）
/// 4. RssArticleDao::list_by_origin_sort 返回 sorted Vec<RssArticle> 的 JSON
///
/// 注意：本实现**不**把 ParserError::Empty 转 `[]`，而是返回 Err 让
/// UI 层显示"暂无文章"。这里区分自 search_books_online 的处理 — RSS
/// "暂无文章"是 UI 友好提示，不是搜索结果空集。
pub async fn rss_get_articles(
    db_path: String,
    source_url: String,
    sort_name: String,
    sort_url: String,
    page: i32,
) -> Result<String, String> {
    // 1. 取 source（在 await 前结束 conn 的 lifetime）
    let source = {
        let conn = open_db(&db_path)?;
        let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
        dao.get_by_url(&source_url)
            .map_err(|e| format!("查询 RSS 源失败: {}", e))?
            .ok_or_else(|| format!("RSS 源不存在: {}", source_url))?
    };

    // 2. 拉取 + 解析
    let parser = core_source::RssParser::new();
    let mut articles = match parser
        .get_articles(&source, &sort_name, &sort_url, page)
        .await
    {
        Ok(a) => a,
        Err(core_source::ParserError::Empty) => Vec::new(),
        Err(e) => return Err(e.to_string()),
    };

    // 3. order_num 重排（确保从 0 开始）
    for (i, a) in articles.iter_mut().enumerate() {
        a.order_num = i as i32;
    }

    // 4. upsert + 重读
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
    if !articles.is_empty() {
        dao.upsert_batch(&articles)
            .map_err(|e| format!("写入 RSS 文章失败: {}", e))?;
    }
    // 重读 — 拿到 DB 已有 read_time/star 的最终结果
    let sort_filter = if sort_name.trim().is_empty() {
        None
    } else {
        Some(sort_name.as_str())
    };
    let final_list = dao
        .list_by_origin_sort(&source.source_url, sort_filter, -1, 0)
        .map_err(|e| format!("读取 RSS 文章失败: {}", e))?;
    serde_json::to_string(&final_list).map_err(|e| format!("序列化失败: {}", e))
}

/// 列出 DB 中已有的 RSS 文章（不拉取）。UI 切 sort tab 时用，避免
/// 每次切换都 round-trip 网络。
pub fn rss_list_articles(
    db_path: String,
    source_url: String,
    sort: Option<String>,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
    let sort_filter = sort.as_deref().filter(|s| !s.trim().is_empty());
    let articles = dao
        .list_by_origin_sort(&source_url, sort_filter, -1, 0)
        .map_err(|e| format!("读取 RSS 文章失败: {}", e))?;
    serde_json::to_string(&articles).map_err(|e| format!("序列化失败: {}", e))
}

/// 按 (origin, link) 取单条 RSS 文章，返回 JSON 或 "null"。
pub fn rss_article_get_by_origin_link(
    db_path: String,
    origin: String,
    link: String,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
    let article = dao
        .get_by_origin_link(&origin, &link)
        .map_err(|e| format!("查询 RSS 文章失败: {}", e))?;
    match article {
        Some(a) => serde_json::to_string(&a).map_err(|e| format!("序列化失败: {}", e)),
        None => Ok("null".into()),
    }
}

/// 标记文章已读：双写 rss_articles + rss_read_records，返回受影响行数。
pub fn rss_mark_read(db_path: String, link: String, ts: i64) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
    dao.mark_read(&link, ts)
        .map(|n| n as i64)
        .map_err(|e| format!("标记已读失败: {}", e))
}

/// 某 RSS 源的未读文章数。
pub fn rss_count_unread(db_path: String, source_url: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
    dao.count_unread_by_origin(&source_url)
        .map_err(|e| format!("统计未读失败: {}", e))
}

/// 删除某 RSS 源下的全部文章（删源时清理）。
pub fn rss_delete_articles_by_source(
    db_path: String,
    source_url: String,
) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
    dao.delete_by_origin(&source_url)
        .map(|n| n as i64)
        .map_err(|e| format!("清理 RSS 文章失败: {}", e))
}

/// 解析 source.sort_url → `[{name, url}]` JSON。空字符串 / 缺源都返回 `[]`。
///
/// `sort_url` 格式（与原 Legado 同）：`name1::url1\nname2::url2` —
/// 单 URL 模式可空。
pub fn rss_get_sort_tabs(db_path: String, source_url: String) -> Result<String, String> {
    let source = {
        let conn = open_db(&db_path)?;
        let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
        dao.get_by_url(&source_url)
            .map_err(|e| format!("查询 RSS 源失败: {}", e))?
    };
    let mut tabs: Vec<serde_json::Value> = Vec::new();
    if let Some(s) = source.as_ref().and_then(|s| s.sort_url.as_deref()) {
        for line in s.split('\n') {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            if let Some((name, url)) = line.split_once("::") {
                let name = name.trim();
                let url = url.trim();
                if name.is_empty() && url.is_empty() {
                    continue;
                }
                tabs.push(serde_json::json!({"name": name, "url": url}));
            } else {
                // 没有 :: 分隔，把整行当 name + 空 url（兼容退化格式）
                tabs.push(serde_json::json!({"name": line, "url": ""}));
            }
        }
    }
    serde_json::to_string(&tabs).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// RSS 文章详情 + 收藏 (批次 18 / 05-19)
// ============================================================
//
// 5 个 fn (funcId 97-101)。`rss_fetch_article_content` 为 async（拉取
// HTML），其它 4 个为 sync（DB 操作）。
//
// 设计要点：
// - rss_fetch_article_content 内部走 RssParser::fetch_article_content_full
//   返回 `{html, base_url}` JSON，dart 端用 WebViewController.loadHtmlString
//   渲染（base_url 让 WebView 解析相对链接）。
// - rss_star_add 接收 `article_json`（RssArticle 的 JSON 字符串）+
//   `source_name`，在 dart 端方便构造（detail 页拿到 RssArticle 直接序列化）。

/// async：读 source / article → 调 fetch_article_content_full → 返回
/// 拼装好的 `{html, base_url}` JSON。
///
/// 错误：
/// - source / article 不存在 → Err
/// - fetch 内部错误 → 透传（参考 ParserError::Display）
pub async fn rss_fetch_article_content(
    db_path: String,
    source_url: String,
    link: String,
) -> Result<String, String> {
    // 1. 取 source（async 前结束 conn lifetime）
    let (source, article) = {
        let conn = open_db(&db_path)?;
        let source = core_storage::rss_source_dao::RssSourceDao::new(&conn)
            .get_by_url(&source_url)
            .map_err(|e| format!("查询 RSS 源失败: {}", e))?
            .ok_or_else(|| format!("RSS 源不存在: {}", source_url))?;
        let article = core_storage::rss_article_dao::RssArticleDao::new(&conn)
            .get_by_origin_link(&source_url, &link)
            .map_err(|e| format!("查询 RSS 文章失败: {}", e))?
            .ok_or_else(|| format!("RSS 文章不存在: {}", link))?;
        (source, article)
    };

    // 2. 拉取
    let parser = core_source::RssParser::new();
    let fetched = parser
        .fetch_article_content_full(&source, &article)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&fetched).map_err(|e| format!("序列化失败: {}", e))
}

/// 收藏一篇文章。`article_json` 应为 [`core_storage::models::RssArticle`]
/// 的 JSON 字符串；`source_name` 来自 [`RssSource::source_name`]。
/// 重复收藏走 `INSERT OR REPLACE`，star_time 自动刷新。返回受影响行数（i64）。
pub fn rss_star_add(
    db_path: String,
    article_json: String,
    source_name: String,
) -> Result<i64, String> {
    let article: core_storage::models::RssArticle =
        serde_json::from_str(&article_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_star_dao::RssStarDao::new(&conn);
    dao.add(&article, &source_name)
        .map(|n| n as i64)
        .map_err(|e| format!("添加收藏失败: {}", e))
}

/// 取消收藏。返回受影响行数（0 表示原本就没收藏）。
pub fn rss_star_remove(
    db_path: String,
    origin: String,
    link: String,
) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_star_dao::RssStarDao::new(&conn);
    dao.remove(&origin, &link)
        .map(|n| n as i64)
        .map_err(|e| format!("取消收藏失败: {}", e))
}

/// 是否已收藏。
pub fn rss_star_is_starred(
    db_path: String,
    origin: String,
    link: String,
) -> Result<bool, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_star_dao::RssStarDao::new(&conn);
    dao.is_starred(&origin, &link)
        .map_err(|e| format!("查询收藏状态失败: {}", e))
}

/// 列出收藏（按 star_time DESC），返回 `Vec<RssStar>` JSON。
/// `limit < 0` 表示无分页（MVP 收藏页用 limit=-1）。
pub fn rss_star_list(
    db_path: String,
    limit: i64,
    offset: i64,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_star_dao::RssStarDao::new(&conn);
    let list = dao
        .list_all(limit, offset)
        .map_err(|e| format!("读取收藏失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 订阅源 RuleSub (批次 19 / 05-19)
// ============================================================
//
// 7 个 fn (funcId 102-108)。CRUD 全 sync，refresh / refresh_all 异步
// (因为要 reqwest GET)。沿袭 RssSource 源管理（批次 16）+ webdav
// 异步 (批次 11) 风格。
//
// 设计要点：
// - rule_sub_create 内部生成 UUID + now() 时间戳，dart 端只需传 name/url/sub_type
// - rule_sub_refresh 按 sub_type 路由到 SourceDao::import_from_json /
//   RssSourceDao::import_from_json；sub_type=2 (替换规则) 暂占位返回
//   `{"sub_type":2,"error":"替换规则订阅暂未实装"}`，保留批次 21+ 实装
// - rule_sub_refresh_all 遍历所有订阅，单个失败不打断其它，每条结果
//   带 ok / message，方便 UI 滚动 SnackBar 汇总

/// 列出所有订阅源（custom_order ASC, name ASC），返回 JSON 数组。
pub fn rule_sub_list_all(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
    let list = dao
        .list_all()
        .map_err(|e| format!("获取订阅源列表失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

/// 按 id 取单条订阅源，返回 JSON `Option<RuleSub>`。
pub fn rule_sub_get(db_path: String, id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
    let s = dao
        .get_by_id(&id)
        .map_err(|e| format!("查询订阅源失败: {}", e))?;
    serde_json::to_string(&s).map_err(|e| format!("序列化失败: {}", e))
}

/// 新建订阅源 — 自动生成 UUID + 时间戳。返回新 RuleSub JSON。
///
/// `sub_type`：0=书源 / 1=RSS 源 / 2=替换规则（替换规则当前刷新会
/// 返回占位错误，但条目本身可以正常建）。
pub fn rule_sub_create(
    db_path: String,
    name: String,
    url: String,
    sub_type: i32,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let now = chrono::Utc::now().timestamp();
    let sub = core_storage::models::RuleSub {
        id: uuid::Uuid::new_v4().to_string(),
        name,
        url,
        sub_type,
        custom_order: 0,
        created_at: now,
        updated_at: now,
    };
    let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
    dao.upsert(&sub)
        .map_err(|e| format!("创建订阅源失败: {}", e))?;
    serde_json::to_string(&sub).map_err(|e| format!("序列化失败: {}", e))
}

/// 更新已有订阅源（id 必须存在）。返回受影响行数。
///
/// 调用方应先 get 已有 RuleSub 取出 created_at / custom_order，
/// 但本接口为简化 UI 调用，仅接收 4 个最常改字段（name/url/sub_type）：
/// 内部先 get_by_id 取 created_at + custom_order，再 upsert。
pub fn rule_sub_update(
    db_path: String,
    id: String,
    name: String,
    url: String,
    sub_type: i32,
) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
    let mut existing = dao
        .get_by_id(&id)
        .map_err(|e| format!("查询订阅源失败: {}", e))?
        .ok_or_else(|| format!("订阅源不存在: {}", id))?;
    let now = chrono::Utc::now().timestamp();
    existing.name = name;
    existing.url = url;
    existing.sub_type = sub_type;
    existing.updated_at = now;
    dao.upsert(&existing)
        .map(|n| n as i64)
        .map_err(|e| format!("更新订阅源失败: {}", e))
}

/// 删除订阅源，返回受影响行数（0 表示原本就不存在）。
pub fn rule_sub_delete(db_path: String, id: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
    dao.delete_by_id(&id)
        .map(|n| n as i64)
        .map_err(|e| format!("删除订阅源失败: {}", e))
}

/// async：刷新单条订阅 — 拉 sub.url → 按 sub_type 路由到对应 import。
///
/// 返回 JSON：
/// - `sub_type=0`：`{"sub_type":0, "count": N}` (导入书源数)
/// - `sub_type=1`：`{"sub_type":1, "summary": {added,updated,skipped}}`
/// - `sub_type=2`：`{"sub_type":2, "error": "替换规则订阅暂未实装"}`
///   （仍属"成功响应"，仅 error 字段提示，便于 UI 区分实现差距 vs 网络错）
pub async fn rule_sub_refresh(db_path: String, id: String) -> Result<String, String> {
    // 1. 取订阅条目（async 前先结束 conn lifetime）
    let sub = {
        let conn = open_db(&db_path)?;
        let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
        dao.get_by_id(&id)
            .map_err(|e| format!("查询订阅源失败: {}", e))?
            .ok_or_else(|| format!("订阅源不存在: {}", id))?
    };

    // 2. sub_type=2 直接占位返回（不发起 HTTP）
    if sub.sub_type == 2 {
        return Ok(serde_json::json!({
            "sub_type": 2,
            "error": "替换规则订阅暂未实装",
        })
        .to_string());
    }

    // 3. 拉远端 JSON（用 core_net::HttpClient 复用 cookie/重试/超时配置）
    let body = fetch_subscription_body(&sub.url).await?;

    // 4. 按 sub_type 路由 import
    match sub.sub_type {
        0 => {
            // 书源：SourceDao::import_from_json 需要 &mut Connection
            let mut conn = open_db(&db_path)?;
            let mut dao = core_storage::source_dao::SourceDao::new(&mut conn);
            let count = dao
                .import_from_json(&body)
                .map_err(|e| format!("导入书源失败: {}", e))?;
            Ok(serde_json::json!({
                "sub_type": 0,
                "count": count as i64,
            })
            .to_string())
        }
        1 => {
            // RSS 源：RssSourceDao::import_from_json 只需 &Connection
            let conn = open_db(&db_path)?;
            let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
            let summary = dao
                .import_from_json(&body)
                .map_err(|e| format!("导入 RSS 源失败: {}", e))?;
            Ok(serde_json::json!({
                "sub_type": 1,
                "summary": summary,
            })
            .to_string())
        }
        other => Err(format!("未知 sub_type: {}", other)),
    }
}

/// async：刷新全部订阅源。每条独立处理，单个失败不打断其它。
///
/// 返回 JSON 数组：
/// `[{"id":..., "name":..., "sub_type":N, "ok":true/false, "message":"..."}]`
pub async fn rule_sub_refresh_all(db_path: String) -> Result<String, String> {
    let subs = {
        let conn = open_db(&db_path)?;
        let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
        dao.list_all()
            .map_err(|e| format!("获取订阅源列表失败: {}", e))?
    };

    let mut results: Vec<serde_json::Value> = Vec::with_capacity(subs.len());
    for sub in subs {
        // 整条 try/catch — 单条失败不抛
        let item = match rule_sub_refresh(db_path.clone(), sub.id.clone()).await {
            Ok(json) => {
                // 把 refresh 返回的内嵌字段揉进去
                let inner: serde_json::Value =
                    serde_json::from_str(&json).unwrap_or(serde_json::Value::Null);
                let message = if let Some(err) = inner.get("error").and_then(|v| v.as_str()) {
                    err.to_string()
                } else if let Some(count) = inner.get("count").and_then(|v| v.as_i64()) {
                    format!("已导入 {} 个书源", count)
                } else if let Some(summary) = inner.get("summary") {
                    let added = summary.get("added").and_then(|v| v.as_i64()).unwrap_or(0);
                    let updated = summary.get("updated").and_then(|v| v.as_i64()).unwrap_or(0);
                    let skipped = summary.get("skipped").and_then(|v| v.as_i64()).unwrap_or(0);
                    format!(
                        "新增 {}，更新 {}，跳过 {}",
                        added, updated, skipped
                    )
                } else {
                    "已刷新".to_string()
                };
                let ok = inner.get("error").is_none();
                serde_json::json!({
                    "id": sub.id,
                    "name": sub.name,
                    "sub_type": sub.sub_type,
                    "ok": ok,
                    "message": message,
                })
            }
            Err(e) => serde_json::json!({
                "id": sub.id,
                "name": sub.name,
                "sub_type": sub.sub_type,
                "ok": false,
                "message": e,
            }),
        };
        results.push(item);
    }
    serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e))
}

/// 用 core_net::HttpClient 拉订阅 URL 的 JSON 文本。
/// 复用项目统一的 cookie/重试/超时/UA 配置；失败时把 reqwest 错误转
/// 成中文描述方便 UI 直接 SnackBar。
async fn fetch_subscription_body(url: &str) -> Result<String, String> {
    let client = core_net::HttpClient::new(core_net::HttpClientConfig::default())
        .map_err(|e| format!("创建 HTTP 客户端失败: {}", e))?;
    client
        .get_text(url)
        .await
        .map_err(|e| format!("拉取订阅源失败: {}", e))
}

// ============================================================
// 内部辅助函数
// ============================================================

fn open_db(db_path: &str) -> Result<rusqlite::Connection, String> {
    core_storage::database::get_connection(db_path).map_err(|e| format!("数据库连接失败: {}", e))
}

/// 把单个下载章节标记为失败（status=3）并联动重算任务整体状态。
///
/// 之前 [`download_and_save_chapter`] 的 `Empty` 与一般 `Err` 两个失败分支
/// 各自手写 `update_chapter_status` + `recompute_download_task_status`
/// 序列，下次新增错误分支极易漏一处。抽到这里收口，两个失败分支统一调，
/// 错误信息也保持一致。成功路径（status=2）参数不同（携带 file_path /
/// file_size），不走本 helper。
///
/// 批次 69 (BATCH-07b)：内部改用 [`crate::transaction::with_transaction`]
/// 把 update + recompute 包成单事务，与成功路径同样原子。
fn mark_chapter_failed(
    db_path: &str,
    task_id: &str,
    chapter_id: &str,
    error_message: &str,
) -> Result<(), String> {
    crate::transaction::with_transaction(db_path, |tx| {
        core_storage::download_dao::DownloadDao::update_chapter_status_in_tx(
            tx,
            chapter_id,
            3,
            None,
            0,
            Some(error_message),
        )
        .map_err(|e| format!("更新章节状态失败: {}", e))?;
        recompute_download_task_status_in_tx(tx, task_id)
            .map_err(|e| format!("更新任务状态失败: {}", e))?;
        Ok(())
    })
}

fn storage_to_source_book_source(
    s: &core_storage::models::BookSource,
) -> Result<core_source::types::BookSource, String> {
    let rule_search = s
        .rule_search
        .as_deref()
        .map(|r| serde_json::from_str(r).map_err(|e| format!("解析 rule_search JSON 失败: {}", e)))
        .transpose()?;

    let rule_book_info = s
        .rule_book_info
        .as_deref()
        .map(|r| {
            serde_json::from_str(r).map_err(|e| format!("解析 rule_book_info JSON 失败: {}", e))
        })
        .transpose()?;

    let rule_toc = s
        .rule_toc
        .as_deref()
        .map(|r| serde_json::from_str(r).map_err(|e| format!("解析 rule_toc JSON 失败: {}", e)))
        .transpose()?;

    let rule_content = s
        .rule_content
        .as_deref()
        .map(|r| serde_json::from_str(r).map_err(|e| format!("解析 rule_content JSON 失败: {}", e)))
        .transpose()?;

    let rule_explore = s
        .rule_explore
        .as_deref()
        .map(|r| serde_json::from_str(r).map_err(|e| format!("解析 rule_explore JSON 失败: {}", e)))
        .transpose()?;

    Ok(core_source::types::BookSource {
        id: s.id.clone(),
        name: s.name.clone(),
        url: s.url.clone(),
        source_type: s.source_type,
        enabled: s.enabled,
        group_name: s.group_name.clone(),
        custom_order: s.custom_order,
        weight: s.weight,
        rule_search,
        rule_book_info,
        rule_toc,
        rule_content,
        rule_review: None,
        login_url: s.login_url.clone(),
        login_ui: s.login_ui.clone(),
        login_check_js: s.login_check_js.clone(),
        header: s.header.clone(),
        js_lib: s.js_lib.clone(),
        cover_decode_js: s.cover_decode_js.clone(),
        explore_url: s.explore_url.clone(),
        rule_explore,
        book_url_pattern: s.book_url_pattern.clone(),
        enabled_explore: s.enabled_explore,
        last_update_time: s.last_update_time,
        book_source_comment: s.book_source_comment.clone(),
        concurrent_rate: s.concurrent_rate.clone(),
        variable_comment: s.variable_comment.clone(),
        explore_screen: s.explore_screen,
        created_at: s.created_at,
        updated_at: s.updated_at,
    })
}

#[cfg(test)]
mod regex_cache_tests {
    use super::*;

    /// R27/R123: a freshly-edited pattern under the SAME rule id must
    /// produce a different compiled Regex once the caller bumps the
    /// generation. The previous keying-by-id-only kept the stale compile
    /// around forever.
    #[test]
    fn cache_invalidates_on_generation_bump() {
        let mut cache = ReplaceRulesCache::new();

        cache.ensure_regex_generation(1);
        let r1_addr = cache.get_or_compile_regex("rule-A", "foo").unwrap() as *const _ as usize;
        // Same pattern within the same generation should hit the cache.
        let r1_again = cache.get_or_compile_regex("rule-A", "foo").unwrap() as *const _ as usize;
        assert_eq!(r1_addr, r1_again, "same gen + pattern should reuse compile");

        // Caller edits rule "A" pattern; bumps generation.
        cache.ensure_regex_generation(2);
        let r2 = cache.get_or_compile_regex("rule-A", "bar").unwrap();
        assert!(r2.is_match("bar"));
        assert!(!r2.is_match("foo"), "old pattern must not still apply");
    }

    /// R47/R123: cache size never grows beyond the current generation's
    /// worth of (id, pattern) tuples.
    #[test]
    fn cache_drops_old_entries_on_generation_bump() {
        let mut cache = ReplaceRulesCache::new();
        cache.ensure_regex_generation(1);
        for i in 0..50 {
            let id = format!("rule-{i}");
            let pattern = format!("p{i}");
            cache.get_or_compile_regex(&id, &pattern);
        }
        assert_eq!(cache.regex_entries.len(), 50);
        cache.ensure_regex_generation(2);
        assert_eq!(
            cache.regex_entries.len(),
            0,
            "generation bump should drop all entries"
        );
        cache.get_or_compile_regex("rule-0", "p0");
        assert_eq!(cache.regex_entries.len(), 1);
    }

    /// Compile failures still get remembered within a generation but do
    /// NOT survive a generation bump (so a user fixing a bad pattern sees
    /// the fix take effect on next chapter).
    #[test]
    fn compile_failures_clear_on_generation_bump() {
        let mut cache = ReplaceRulesCache::new();
        cache.ensure_regex_generation(1);
        // Invalid pattern: unclosed bracket.
        assert!(cache.get_or_compile_regex("bad-rule", "[").is_none());
        assert_eq!(cache.regex_entries.len(), 1);
        cache.ensure_regex_generation(2);
        // Fixed pattern under same id.
        let fixed = cache.get_or_compile_regex("bad-rule", "[abc]").unwrap();
        assert!(fixed.is_match("a"));
    }
}

#[cfg(test)]
mod scope_filter_tests {
    use super::matches_scope;
    use core_storage::models::ReplaceRule;

    fn rule(scope: Option<&str>, exclude: Option<&str>) -> ReplaceRule {
        ReplaceRule {
            id: "r1".into(),
            name: "test".into(),
            pattern: "x".into(),
            replacement: "y".into(),
            enabled: true,
            scope: scope.map(|s| s.to_string()),
            scope_title: false,
            scope_content: true,
            exclude_scope: exclude.map(|s| s.to_string()),
            sort_number: 0,
            created_at: 0,
            updated_at: 0,
        }
    }

    /// R24: scope=None → 全局，对所有书生效。
    #[test]
    fn scope_none_matches_anything() {
        let r = rule(None, None);
        assert!(matches_scope(&r, "三体", "https://x.com"));
        assert!(matches_scope(&r, "", ""));
    }

    /// R24: scope="" → 同 None，全局生效。
    #[test]
    fn scope_empty_matches_anything() {
        let r = rule(Some(""), None);
        assert!(matches_scope(&r, "三体", "https://x.com"));
    }

    /// R24: scope 子串包含 book_name 即匹配。
    #[test]
    fn scope_substring_matches_book_name() {
        let r = rule(Some("三体 笔趣阁"), None);
        assert!(matches_scope(&r, "三体", "https://other.com"));
    }

    /// R24: scope 子串包含 book_origin (书源 URL) 即匹配。
    /// 注意子串方向：scope 是 haystack，origin 是 needle。所以
    /// scope 字段需要"包含"完整的 origin 字符串。
    #[test]
    fn scope_substring_matches_book_origin() {
        let r = rule(Some("https://qidian.com/book/1 起点"), None);
        assert!(matches_scope(&r, "无关书名", "https://qidian.com/book/1"));
    }

    /// R24: scope 不命中任何 → 跳过。
    #[test]
    fn scope_no_match() {
        let r = rule(Some("某本书"), None);
        assert!(!matches_scope(&r, "另一本书", "https://other.com"));
    }

    /// R24: book_name / book_origin 都为空时 scope 非空 → 不参与
    /// 子串匹配（防 "".contains("") == true 误命中所有规则）。
    #[test]
    fn empty_caller_context_does_not_match_scoped_rule() {
        let r = rule(Some("三体"), None);
        assert!(!matches_scope(&r, "", ""));
    }

    /// R24: exclude 优先于 scope 命中。
    #[test]
    fn exclude_wins_over_scope_match() {
        let r = rule(Some("三体"), Some("三体"));
        assert!(!matches_scope(&r, "三体", "https://x.com"));
    }

    /// R24: 全局规则也能被 exclude 排除掉。注意 exclude 是 haystack，
    /// 所以排除某本书需要在 exclude_scope 字段里写下完整的 book_name
    /// 或 book_origin 字符串。
    #[test]
    fn exclude_blocks_global_scope() {
        let r = rule(None, Some("三体 烂书一本"));
        assert!(!matches_scope(&r, "三体", "https://x.com"));
        assert!(matches_scope(&r, "其他书", "https://x.com"));
    }
}

#[cfg(test)]
mod cache_concurrency_tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;

    fn make_rule(id: &str, pattern: &str) -> core_storage::models::ReplaceRule {
        core_storage::models::ReplaceRule {
            id: id.into(),
            name: "t".into(),
            pattern: pattern.into(),
            replacement: "X".into(),
            enabled: true,
            scope: None,
            scope_title: false,
            scope_content: true,
            exclude_scope: None,
            sort_number: 0,
            created_at: 0,
            updated_at: 0,
        }
    }

    /// R123: simulate two concurrent threads with different generations
    /// hammering the unified cache. Each thread's per-call view of
    /// `(rules, regex)` must reflect its own generation, not the other
    /// thread's. This is the regression that proves the unified lock
    /// fixed the cross-generation interference bug — pre-fix code with
    /// two independent mutexes would intermittently fail because thread
    /// A could observe a regex compiled from generation 2's pattern
    /// while thinking it was on generation 1.
    #[test]
    fn unified_cache_keeps_generations_isolated() {
        let cache = Arc::new(std::sync::Mutex::new(ReplaceRulesCache::new()));

        let rules_v1 = Arc::new(vec![make_rule("r1", "foo")]);
        let rules_v2 = Arc::new(vec![make_rule("r1", "bar")]);

        let cache_a = cache.clone();
        let rules_v1_a = rules_v1.clone();
        let t_a = thread::spawn(move || {
            for _ in 0..200 {
                let mut c = cache_a.lock().unwrap();
                let r = c
                    .get_or_load_rules("db", 1, || Ok((*rules_v1_a).clone()))
                    .unwrap();
                c.ensure_regex_generation(1);
                let id = r[0].id.clone();
                let pattern = r[0].pattern.clone();
                let re = c.get_or_compile_regex(&id, &pattern).unwrap();
                assert!(re.is_match("foo"));
                assert!(!re.is_match("bar"));
            }
        });

        let cache_b = cache.clone();
        let rules_v2_b = rules_v2.clone();
        let t_b = thread::spawn(move || {
            for _ in 0..200 {
                let mut c = cache_b.lock().unwrap();
                let r = c
                    .get_or_load_rules("db", 2, || Ok((*rules_v2_b).clone()))
                    .unwrap();
                c.ensure_regex_generation(2);
                let id = r[0].id.clone();
                let pattern = r[0].pattern.clone();
                let re = c.get_or_compile_regex(&id, &pattern).unwrap();
                assert!(re.is_match("bar"));
                assert!(!re.is_match("foo"));
            }
        });

        t_a.join().unwrap();
        t_b.join().unwrap();
    }
}

#[cfg(test)]
mod export_bookshelf_tests {
    use super::*;
    use core_storage::models::Book;
    use tempfile::TempDir;

    fn fresh_db() -> (TempDir, String) {
        let dir = TempDir::new().unwrap();
        let db_path = dir.path().join("test.db").to_str().unwrap().to_string();
        // 必须建一个 source 行，因为 books.source_id 有外键约束
        let conn = core_storage::database::init_database(&db_path).unwrap();
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at) \
             VALUES ('s1', 'Source', 'https://e', 1, 1)",
            [],
        )
        .unwrap();
        (dir, db_path)
    }

    fn book(id: &str, name: &str, author: Option<&str>, intro: Option<&str>) -> Book {
        Book {
            id: id.to_string(),
            source_id: "s1".to_string(),
            source_name: Some("Source".to_string()),
            name: name.to_string(),
            author: author.map(|s| s.to_string()),
            cover_url: None,
            chapter_count: 0,
            latest_chapter_title: None,
            intro: intro.map(|s| s.to_string()),
            kind: None,
            book_url: None,
            toc_url: None,
            last_check_time: None,
            last_check_count: 0,
            total_word_count: 0,
            can_update: true,
            order_time: 0,
            latest_chapter_time: None,
            custom_cover_path: None,
            custom_info_json: None,
            dur_chapter_index: 0,
            dur_chapter_pos: 0,
            dur_chapter_title: None,
            dur_chapter_time: 0,
            group_id: 0,
            created_at: 1,
            updated_at: 1,
        }
    }

    /// BATCH-27a: 空书架返回 `"[]"`（去掉缩进的空数组）。pretty 序列化
    /// 对空数组也只输出 `[]`，不带换行。
    #[test]
    fn test_export_bookshelf_empty() {
        let (_dir, db_path) = fresh_db();
        let json = export_bookshelf_json(db_path).unwrap();
        assert_eq!(json, "[]");
    }

    /// BATCH-27a: 有书架时输出 name / author / intro 三字段，对齐原版
    /// `BookshelfViewModel.kt:102-128`。author / intro 缺失时落回空串。
    #[test]
    fn test_export_bookshelf_with_books() {
        let (_dir, db_path) = fresh_db();
        let conn = open_db(&db_path).unwrap();
        let dao = core_storage::book_dao::BookDao::new(&conn);
        dao.upsert(&book("b1", "三国演义", Some("罗贯中"), Some("乱世枭雄")))
            .unwrap();
        dao.upsert(&book("b2", "Anonymous", None, None)).unwrap();
        drop(conn);

        let json = export_bookshelf_json(db_path).unwrap();
        let parsed: Vec<serde_json::Value> = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.len(), 2);
        // get_all 默认 TimeAdd DESC + 两本 order_time 都是 0 时退回插入顺序
        // 不绑顺序，按 name 找
        let by_name: std::collections::HashMap<&str, &serde_json::Value> = parsed
            .iter()
            .map(|v| (v["name"].as_str().unwrap(), v))
            .collect();
        let v1 = by_name["三国演义"];
        assert_eq!(v1["name"].as_str().unwrap(), "三国演义");
        assert_eq!(v1["author"].as_str().unwrap(), "罗贯中");
        assert_eq!(v1["intro"].as_str().unwrap(), "乱世枭雄");

        let v2 = by_name["Anonymous"];
        // 缺失字段落回空串，不是 null
        assert_eq!(v2["author"].as_str().unwrap(), "");
        assert_eq!(v2["intro"].as_str().unwrap(), "");
    }

    /// BATCH-27b: 不存在的 book_id 返「书不存在」错误，不 panic / unwrap。
    #[tokio::test(flavor = "current_thread")]
    async fn test_update_book_toc_book_not_found() {
        let (_dir, db_path) = fresh_db();
        let err = update_book_toc(db_path, "no_such_book".to_string())
            .await
            .unwrap_err();
        assert!(err.contains("书不存在"), "实际错误: {}", err);
    }

    /// BATCH-27b: 书的 source_id 指向不存在的书源时返「书源不存在」错误。
    /// 这种 case 在生产里出现于：用户删了书源但没删依赖该书源的书，或
    /// 数据库恢复时 source 表被截断。Dart 端会把错信息浮到 SnackBar。
    #[tokio::test(flavor = "current_thread")]
    async fn test_update_book_toc_no_source() {
        let (_dir, db_path) = fresh_db();
        // 插一本 book，source_id 指向 fresh_db 里建的 's1'，但下面 DELETE
        // 把 's1' 删掉，造成 dangling source_id。注意 books.source_id 是
        // 外键 ON DELETE 没设 CASCADE / SET NULL（schema v11 默认），所以
        // 直接 DELETE source 在 PRAGMA foreign_keys=ON 下会失败 —— 改先
        // 关闭 FK 再插一条 dangling source_id 的 book。
        {
            let conn = open_db(&db_path).unwrap();
            conn.execute("PRAGMA foreign_keys = OFF", []).unwrap();
            // 用合规字段集插书：source_id 用一个不存在的 id
            conn.execute(
                "INSERT INTO books (id, source_id, name, chapter_count, last_check_count, total_word_count, can_update, order_time, dur_chapter_index, dur_chapter_pos, dur_chapter_time, group_id, book_url, toc_url, created_at, updated_at) \
                 VALUES ('b_dangling', 's_missing', 'Dangling', 0, 0, 0, 1, 0, 0, 0, 0, 0, 'https://e/b', 'https://e/toc', 1, 1)",
                [],
            )
            .unwrap();
            conn.execute("PRAGMA foreign_keys = ON", []).unwrap();
        }

        let err = update_book_toc(db_path, "b_dangling".to_string())
            .await
            .unwrap_err();
        assert!(err.contains("书源不存在"), "实际错误: {}", err);
    }
}
