//! # 数据模型定义
//!
//! 定义 core-storage 使用的核心数据结构。
//! 对应原 Legado 的 data/entities/ 中的数据实体。

use chrono::Utc;
use serde::{Deserialize, Serialize};

/// 书源结构体（对应原 Legado 的 BookSource 实体）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookSource {
    pub id: String,
    pub name: String,
    pub url: String,
    pub source_type: i32, // 0=小说, 1=音频, 2=图片, 3=RSS
    pub group_name: Option<String>,
    pub enabled: bool,
    pub custom_order: i32,
    pub weight: i32,

    // 规则（JSON 格式存储）
    pub rule_search: Option<String>,
    pub rule_book_info: Option<String>,
    pub rule_toc: Option<String>,
    pub rule_content: Option<String>,

    // 其他配置
    pub login_url: Option<String>,
    #[serde(default)]
    pub login_ui: Option<String>,
    #[serde(default)]
    pub login_check_js: Option<String>,
    pub header: Option<String>,
    pub js_lib: Option<String>,
    #[serde(default)]
    pub cover_decode_js: Option<String>,
    pub book_url_pattern: Option<String>,
    #[serde(default)]
    pub rule_explore: Option<String>,
    #[serde(default)]
    pub explore_url: Option<String>,
    #[serde(default)]
    pub enabled_explore: bool,
    #[serde(default)]
    pub last_update_time: i64,
    #[serde(default)]
    pub book_source_comment: Option<String>,
    #[serde(default)]
    pub concurrent_rate: Option<String>,
    #[serde(default)]
    pub variable_comment: Option<String>,
    #[serde(default)]
    pub explore_screen: Option<i32>,

    // 批次 check-sources (v13 / 05-24): 校验结果持久化
    #[serde(default)]
    pub respond_time: i64,
    #[serde(default)]
    pub last_check_error: Option<String>,
    #[serde(default)]
    pub last_check_at: i64,

    pub created_at: i64,
    pub updated_at: i64,
}

/// 书籍结构体（对应原 Legado 的 Book 实体）
///
/// **批次 6 (v11)**: 加 5 字段对齐原 Legado `Book.kt:96-102`：
/// - `dur_chapter_index` / `dur_chapter_pos` — 当前章节 + 章内字符 offset
///   （书架"上次阅读"显示 + 排序）。`book_progress` 表已经存有这些
///   信息，但原 Legado 是把"上次阅读"快照写在 books 表里方便
///   书架直接 SELECT；保留两份做兼容。
/// - `dur_chapter_title` — 上次阅读章节标题，书架卡片副标题用。
/// - `dur_chapter_time` — 上次阅读时间戳，书架按"最近读"排序用。
/// - `group_id` — 所属分组 id（0 = 未分组），FK 到 `book_groups.id`。
///
/// 全部带 `#[serde(default)]`，老 JSON 反序列化兼容（远端 / 备份恢复
/// 不会因新字段缺失而失败）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Book {
    pub id: String,
    pub source_id: String,
    pub source_name: Option<String>,
    pub name: String,
    pub author: Option<String>,
    pub cover_url: Option<String>,
    pub chapter_count: i32,
    pub latest_chapter_title: Option<String>,
    pub intro: Option<String>,
    pub kind: Option<String>,
    pub book_url: Option<String>,
    pub toc_url: Option<String>,
    pub last_check_time: Option<i64>,
    pub last_check_count: i32,
    pub total_word_count: i32,
    pub can_update: bool,
    pub order_time: i64,
    pub latest_chapter_time: Option<i64>,
    pub custom_cover_path: Option<String>,
    pub custom_info_json: Option<String>,
    /// 当前阅读章节索引（书架"上次读"显示用）。批次 6 新增。
    #[serde(default)]
    pub dur_chapter_index: i32,
    /// 当前阅读章节内字符 offset。批次 6 新增。
    #[serde(default)]
    pub dur_chapter_pos: i32,
    /// 当前阅读章节标题（书架卡片副标题）。批次 6 新增。
    #[serde(default)]
    pub dur_chapter_title: Option<String>,
    /// 上次阅读时间戳（秒），书架按"最近读"排序用。批次 6 新增。
    #[serde(default)]
    pub dur_chapter_time: i64,
    /// 所属分组 id；0 = 未分组，AUTOINCREMENT 从 1 开始。批次 6 新增。
    #[serde(default)]
    pub group_id: i64,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 章节结构体（对应原 Legado 的 Chapter 实体）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Chapter {
    pub id: String,
    pub book_id: String,
    pub index_num: i32,
    pub title: String,
    pub url: String,
    pub content: Option<String>,
    pub is_volume: bool,
    pub is_checked: bool,
    pub start: i32,
    pub end: i32,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 阅读进度结构体
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookProgress {
    pub book_id: String,
    pub chapter_index: i32,
    pub paragraph_index: i32,
    pub offset: i32,
    pub read_time: i64, // 累计阅读时长（毫秒）
    pub updated_at: i64,
}

/// 书签结构体
///
/// **批次 6 (v11)**: 加 5 字段对齐原 Legado `Bookmark.kt`：
/// - `book_name` / `book_author` — 跨书全书签清单页要显示书名作者，
///   书删了书签仍保留这些冗余信息。
/// - `chapter_pos` — 章内字符级 offset（不是段落 index，不是字符串）。
/// - `chapter_name` — 章节标题，全书签清单页副标题用。
/// - `book_text` — 书签所在位置的文本片段（上下文预览）。
///
/// 全部带 `#[serde(default)]`，老 JSON 兼容。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Bookmark {
    pub id: String,
    pub book_id: String,
    pub chapter_index: i32,
    pub paragraph_index: i32,
    pub content: Option<String>,
    /// 冗余存的书名（跨书全书签清单页用）。批次 6 新增。
    #[serde(default)]
    pub book_name: Option<String>,
    /// 冗余存的作者。批次 6 新增。
    #[serde(default)]
    pub book_author: Option<String>,
    /// 章内字符级 offset。批次 6 新增。
    #[serde(default)]
    pub chapter_pos: i32,
    /// 章节标题（清单页副标题）。批次 6 新增。
    #[serde(default)]
    pub chapter_name: Option<String>,
    /// 书签上下文文本片段。批次 6 新增。
    #[serde(default)]
    pub book_text: Option<String>,
    pub created_at: i64,
}

/// 替换规则结构体
///
/// **R24**: schema 对齐原 Legado 设计 (`app/data/entities/ReplaceRule.kt`)。
/// 之前用 `scope: i32` enum (0=全局, 1=书源, 2=书籍) 但 schema 没有
/// 配套的 target 字段，导致所有 enabled 规则不分作用范围一律生效。
/// v10 schema 把 `scope` 改成 `Option<String>`，子串包含 `book.name`
/// 或 `book.origin` 即匹配；并补齐 scope_title / scope_content /
/// exclude_scope 等原项目里就有的辅助字段。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplaceRule {
    pub id: String,
    pub name: String,
    pub pattern: String,
    pub replacement: String,
    pub enabled: bool,
    /// 作用范围。`None` 或空字符串表示全局；否则按子串包含
    /// `book.name` 或 `book.origin` (书源 URL) 来匹配。
    pub scope: Option<String>,
    /// 是否作用于章节标题。原 Legado 默认 false。
    pub scope_title: bool,
    /// 是否作用于正文。原 Legado 默认 true。
    pub scope_content: bool,
    /// 排除范围。子串语义同 [`scope`]，命中即跳过该规则。
    pub exclude_scope: Option<String>,
    pub sort_number: i32,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 下载任务结构体
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadTask {
    pub id: String,
    pub book_id: String,
    pub book_name: String,
    pub cover_url: Option<String>,
    pub total_chapters: i32,
    pub downloaded_chapters: i32,
    pub status: i32, // 0=等待, 1=下载中, 2=暂停, 3=完成, 4=失败
    pub total_size: i64,
    pub downloaded_size: i64,
    pub error_message: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 下载章节记录结构体
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadChapter {
    pub id: String,
    pub task_id: String,
    pub chapter_id: String,
    pub chapter_index: i32,
    pub chapter_title: String,
    pub status: i32, // 0=等待, 1=下载中, 2=完成, 3=失败
    pub file_path: Option<String>,
    pub file_size: i64,
    pub error_message: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 生成新的 UUID
pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// 获取当前时间戳（秒）
pub fn now_timestamp() -> i64 {
    Utc::now().timestamp()
}

// ============================================================
// 批次 6 (v11) 新增 schema：仅 struct 定义，DAO 留依赖批次再加
// ============================================================

/// 书籍分组（书架分组功能用）
///
/// 对应原 Legado `BookGroup.kt`，但简化掉了原版的 bitmask 设计 ——
/// 改成自增 ID 普通表，`Book.group_id` 直接存外键。
/// `id = 0` 约定表示"未分组"，AUTOINCREMENT 从 1 开始所以不会冲突。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookGroup {
    pub id: i64,
    pub name: String,
    /// 分组在书架顶栏 Tab 上的显示顺序。
    pub sort_order: i32,
    /// 分组封面图（本地路径或 URL，nullable）。
    pub cover: Option<String>,
    /// 是否在书架上显示（false = 隐藏分组）。
    pub show: bool,
    /// 分组内的排序模式（0=默认 / 1=名称 / 2=作者 / 3=最近读 ...）。
    /// 具体取值定义留后续批次实现 sort UI 时再约束。
    pub book_sort: i32,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 阅读时长记录
///
/// 对应原 Legado `ReadRecord.kt`。原版用 `(deviceId, bookName)` 做联合主键，
/// 这里改成自增 UUID + book_id 外键 + 冗余 book_name。
/// `book_name` 冗余存便于"书删了仍能跨书统计阅读时长"。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadRecord {
    pub id: String,
    pub book_id: String,
    /// 冗余存书名，便于跨书统计 / 书删后仍可查询历史阅读。
    pub book_name: String,
    /// 累计阅读时长（秒）。
    pub read_time: i64,
    /// 上次阅读时间戳（秒）。
    pub last_read_at: i64,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 持久化 Cookie
///
/// 对应原 Legado `Cookie.kt`，用于书源登录态保活。
/// `(domain, key, path)` 三元组唯一（schema 上加 UNIQUE 约束）。
/// 当前 `core-net/cookie.rs` 是内存版本，本批次只先加 schema +
/// struct，DAO 实现留批次 7+ 做"书源登录"时再补。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Cookie {
    pub id: i64,
    pub domain: String,
    pub key: String,
    pub value: String,
    pub path: Option<String>,
    /// 过期时间戳（秒）；session cookie 为 None。
    pub expires_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 订阅源（书源 / RSS / 替换规则的远端订阅源）
///
/// 对应原 Legado `RuleSub.kt`。一个 URL 周期性拉取最新规则 JSON 列表
/// 合并入库。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleSub {
    pub id: String,
    pub name: String,
    pub url: String,
    /// 0 = 书源订阅，1 = RSS 源订阅，2 = 替换规则订阅。
    pub sub_type: i32,
    pub custom_order: i32,
    pub created_at: i64,
    pub updated_at: i64,
}

// ============================================================
// 批次 16 (v12) 新增：RSS 源管理 schema
// ============================================================

/// RSS 源（对应原 Legado `RssSource.kt`）。
///
/// 原 Legado 共 31 字段，本 struct 保留 23 个核心 SQL 列；剩余 13 个高
/// 级字段（jsLib / loginUrl / loginUi / loginCheckJs / coverDecodeJs /
/// contentWhitelist / contentBlacklist / shouldOverrideUrlLoading /
/// style / injectJs / concurrentRate / enabledCookieJar / variableComment）
/// 序列化进 [`custom_info_json`] 字符串收纳，导入时不丢信息但 UI 不展示
/// （MVP）。
///
/// 字段语义见 PRD `.trellis/tasks/05-19-rss-source-mgr-batch16/prd.md`。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RssSource {
    /// 主键，对应原 Legado `sourceUrl`。
    pub source_url: String,
    pub source_name: String,
    pub source_icon: Option<String>,
    pub source_group: Option<String>,
    pub source_comment: Option<String>,
    pub enabled: bool,
    /// 0 = 多分类（按 sort_url 解析），1 = 单 URL 模式。
    pub single_url: bool,
    /// 多分类时 `sortName::sortUrl` 对，多个用 `\n` 分隔。
    pub sort_url: Option<String>,
    /// 0 / 1 / 2 三种文章列表 layout。
    pub article_style: i32,
    pub rule_articles: Option<String>,
    pub rule_next_page: Option<String>,
    pub rule_title: Option<String>,
    pub rule_pub_date: Option<String>,
    pub rule_description: Option<String>,
    pub rule_image: Option<String>,
    pub rule_link: Option<String>,
    pub rule_content: Option<String>,
    pub last_update_time: i64,
    pub custom_order: i32,
    pub enable_js: bool,
    pub load_with_base_url: bool,
    pub header: Option<String>,
    /// 高级字段总收纳：JSON 对象字符串，13 个字段塞这里。
    pub custom_info_json: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

impl RssSource {
    /// 把原 Legado 31 字段 JSON 适配到端口 23 字段 + custom_info_json。
    ///
    /// 字段映射策略：
    /// - 23 个 SQL 列直接读 `sourceUrl` / `sourceName` 等驼峰 key
    /// - 13 个高级字段（见 struct 注释）合并成一个 JSON object 写入
    ///   `custom_info_json`；空对象时为 None
    /// - 缺失字段用 struct 默认值（空 / 0 / true / Some / None）
    /// - 时间戳直接读 `lastUpdateTime`（毫秒），保留毫秒不转秒
    ///   （与原 Legado 保持一致）
    pub fn from_legado_json(v: &serde_json::Value) -> Self {
        let now = Utc::now().timestamp();
        let s = |k: &str| {
            v.get(k)
                .and_then(|x| x.as_str())
                .map(|x| x.to_string())
                .filter(|x| !x.is_empty())
        };
        let s_or_default = |k: &str| s(k).unwrap_or_default();
        let b = |k: &str, default: bool| v.get(k).and_then(|x| x.as_bool()).unwrap_or(default);
        let i = |k: &str, default: i64| v.get(k).and_then(|x| x.as_i64()).unwrap_or(default);

        // 13 个高级字段塞 custom_info_json
        let mut extras = serde_json::Map::new();
        for key in [
            "jsLib",
            "loginUrl",
            "loginUi",
            "loginCheckJs",
            "coverDecodeJs",
            "contentWhitelist",
            "contentBlacklist",
            "shouldOverrideUrlLoading",
            "style",
            "injectJs",
            "concurrentRate",
            "enabledCookieJar",
            "variableComment",
        ] {
            if let Some(val) = v.get(key) {
                if !val.is_null() {
                    extras.insert(key.to_string(), val.clone());
                }
            }
        }
        let custom_info_json = if extras.is_empty() {
            None
        } else {
            serde_json::to_string(&serde_json::Value::Object(extras)).ok()
        };

        // sortUrl: 既支持原 Legado 的 `sortUrl` 字符串（多个 sortName::url
        // 用 \n 分隔），也兼容 array of {title,url} 的备份格式。
        let sort_url = match v.get("sortUrl") {
            Some(serde_json::Value::String(s)) if !s.is_empty() => Some(s.clone()),
            Some(serde_json::Value::Array(arr)) if !arr.is_empty() => {
                let parts: Vec<String> = arr
                    .iter()
                    .filter_map(|item| {
                        let title = item.get("title").and_then(|x| x.as_str()).unwrap_or("");
                        let url = item.get("url").and_then(|x| x.as_str()).unwrap_or("");
                        if title.is_empty() && url.is_empty() {
                            None
                        } else {
                            Some(format!("{}::{}", title, url))
                        }
                    })
                    .collect();
                if parts.is_empty() {
                    None
                } else {
                    Some(parts.join("\n"))
                }
            }
            _ => None,
        };

        Self {
            source_url: s_or_default("sourceUrl"),
            source_name: s_or_default("sourceName"),
            source_icon: s("sourceIcon"),
            source_group: s("sourceGroup"),
            source_comment: s("sourceComment"),
            enabled: b("enabled", true),
            single_url: b("singleUrl", false),
            sort_url,
            article_style: i("articleStyle", 0) as i32,
            rule_articles: s("ruleArticles"),
            rule_next_page: s("ruleNextPage"),
            rule_title: s("ruleTitle"),
            rule_pub_date: s("rulePubDate"),
            rule_description: s("ruleDescription"),
            rule_image: s("ruleImage"),
            rule_link: s("ruleLink"),
            rule_content: s("ruleContent"),
            last_update_time: i("lastUpdateTime", 0),
            custom_order: i("customOrder", 0) as i32,
            enable_js: b("enableJs", true),
            load_with_base_url: b("loadWithBaseUrl", true),
            header: s("header"),
            custom_info_json,
            created_at: now,
            updated_at: now,
        }
    }
}

/// RSS 源导入摘要（与 [`crate::backup_dao::ImportSummary`] 不同：那个是
/// 备份 zip 的 5 表合一，本结构仅用于 `RssSourceDao::import_from_json`）。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RssImportSummary {
    pub added: i32,
    pub updated: i32,
    pub skipped: i32,
}

// ============================================================
// 批次 17 (05-19) — RSS 文章 / 已读记录
// ============================================================

/// RSS 文章（对应原 Legado `RssArticle.kt`）。
///
/// 复合主键 `(origin, link)`：origin = `rss_sources.source_url`，link
/// 是文章绝对 URL。pub_date 保留**原 String 格式**（不解析时间戳，
/// 避免时区 / 格式分歧；上游 RSS 各家格式不一）。
///
/// `read_time = 0` 表示未读；上层 UI 用此判定是否显示未读 dot。
/// `star = 0` 表示未收藏；批次 18 才把收藏接到 `rss_stars` 表。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RssArticle {
    /// 关联 `rss_sources.source_url`（不强加 FK，便于源删除后保留历史）。
    pub origin: String,
    /// 分类 sortName；单 URL 模式空字符串。
    pub sort: String,
    pub title: String,
    /// 原始字符串日期（不解析）。
    pub pub_date: String,
    pub link: String,
    pub image: Option<String>,
    pub description: Option<String>,
    /// 规则路解析时可塞翻页 URL 等扩展信息（MVP 仅记录，不实装翻页）。
    pub variable: Option<String>,
    /// 列表显示顺序（拉取时按 0..N 计），UI 排序按此。
    pub order_num: i32,
    /// 已读时间戳（秒）；0 = 未读。
    pub read_time: i64,
    /// 收藏标志；批次 18 启用。
    pub star: i32,
}

/// RSS 已读记录（对应原 Legado `RssReadRecord.kt`）。
///
/// 表 `rss_read_records` 主键 `link`，全局去重 — 同一篇文章被多个 RSS
/// 源收录时跨源已读探测的依据。`read_time` 与 `record_time` MVP 同值。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RssReadRecord {
    pub link: String,
    pub record_time: i64,
    pub read_time: i64,
}

// ============================================================
// 批次 18 (05-19) — RSS 收藏 RssStar
// ============================================================

/// RSS 收藏记录（对应原 Legado `RssStar.kt`）。
///
/// 表 `rss_stars`（schema v12 已建，批次 16），主键 `(origin, link)` —
/// 与 `RssArticle` 同语义；不同的是 RssStar 跨源持久（删源 / 清文章
/// 都不动收藏）。重复 add 走 `INSERT OR REPLACE` 把 star_time 刷成最新。
///
/// 9 个字段加 `star_time`：
/// - `origin / source_name / sort / title / pub_date / image / link /
///   description / variable` — 都是从 RssArticle 拷过来 + source_name
/// - `star_time` 收藏时间戳（秒）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RssStar {
    pub origin: String,
    pub source_name: String,
    pub sort: String,
    pub title: String,
    pub pub_date: String,
    pub image: Option<String>,
    pub link: String,
    pub description: Option<String>,
    pub variable: Option<String>,
    pub star_time: i64,
}
