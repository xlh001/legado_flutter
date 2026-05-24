//! # 类型定义
//!
//! 提供 core-source 模块使用的核心数据结构。
//! 对应原 Legado 的 BookSource/SearchRule/BookInfoRule 等。

use serde::{Deserialize, Deserializer, Serialize};

/// Deserialize an i32 from either a number or a string (Legado format compatibility).
fn deser_i32<'de, D>(d: D) -> Result<i32, D::Error>
where
    D: Deserializer<'de>,
{
    use serde::de::{self, Unexpected};
    struct I32Visitor;
    impl<'de> de::Visitor<'de> for I32Visitor {
        type Value = i32;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("an integer or a string of digits")
        }
        fn visit_i64<E: de::Error>(self, v: i64) -> Result<i32, E> {
            Ok(v as i32)
        }
        fn visit_u64<E: de::Error>(self, v: u64) -> Result<i32, E> {
            Ok(v as i32)
        }
        fn visit_str<E: de::Error>(self, v: &str) -> Result<i32, E> {
            if v.is_empty() {
                return Ok(0);
            }
            v.parse::<i32>().map_err(|_| E::invalid_value(Unexpected::Str(v), &self))
        }
    }
    d.deserialize_any(I32Visitor)
}

/// 书源结构体（对应原 Legado 的 BookSource）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookSource {
    pub id: String,
    pub name: String,
    pub url: String,

    #[serde(default, deserialize_with = "deser_i32")]
    pub source_type: i32, // 0=小说, 1=音频, 2=图片, 3=RSS
    #[serde(default)]
    pub enabled: bool,

    #[serde(default)]
    pub group_name: Option<String>,
    #[serde(default, deserialize_with = "deser_i32")]
    pub custom_order: i32,
    #[serde(default, deserialize_with = "deser_i32")]
    pub weight: i32,

    /// 规则（JSON 格式）
    #[serde(default)]
    pub rule_search: Option<SearchRule>,
    #[serde(default)]
    pub rule_book_info: Option<BookInfoRule>,
    #[serde(default)]
    pub rule_toc: Option<TocRule>,
    #[serde(default)]
    pub rule_content: Option<ContentRule>,
    #[serde(default, alias = "ruleReview")]
    pub rule_review: Option<ReviewRule>,

    /// 其他配置
    #[serde(default)]
    pub login_url: Option<String>,
    /// Login form UI definition (JSON array of {name, type, action})
    #[serde(default, alias = "loginUi")]
    pub login_ui: Option<String>,
    /// JS to check if login is still valid (runs after each request)
    #[serde(default, alias = "loginCheckJs")]
    pub login_check_js: Option<String>,
    #[serde(default)]
    pub header: Option<String>,
    #[serde(default)]
    pub js_lib: Option<String>,
    /// JS to decrypt cover image bytes (receives `result` as bytes, `src` as URL)
    #[serde(default, alias = "coverDecodeJs")]
    pub cover_decode_js: Option<String>,
    #[serde(default)]
    pub explore_url: Option<String>,
    #[serde(default)]
    pub rule_explore: Option<SearchRule>,
    #[serde(default)]
    pub book_url_pattern: Option<String>,
    #[serde(default)]
    pub enabled_explore: bool,
    #[serde(default)]
    pub last_update_time: i64,
    #[serde(default)]
    pub book_source_comment: Option<String>,
    /// 并发率: "1000" (interval ms) or "5/1000" (count/window_ms)
    #[serde(default, alias = "concurrentRate")]
    pub concurrent_rate: Option<String>,
    /// Variable comment shown in source edit UI
    #[serde(default, alias = "variableComment")]
    pub variable_comment: Option<String>,
    /// Explore screen layout hint (0=default, 1=grid, 2=list, etc.)
    #[serde(default, alias = "exploreScreen")]
    pub explore_screen: Option<i32>,

    #[serde(default = "now_timestamp")]
    pub created_at: i64,
    #[serde(default = "now_timestamp")]
    pub updated_at: i64,
}

fn now_timestamp() -> i64 {
    chrono::Utc::now().timestamp()
}

/// 搜索规则
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SearchRule {
    #[serde(default, alias = "searchUrl")]
    pub search_url: Option<String>, // 搜索URL模板（含{{keyword}}占位符）
    #[serde(default, alias = "bookList")]
    pub book_list: Option<String>, // 搜索结果列表的选择器
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub author: Option<String>,
    #[serde(default, alias = "bookUrl")]
    pub book_url: Option<String>,
    #[serde(default, alias = "coverUrl")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default, alias = "lastChapter")]
    pub last_chapter: Option<String>,
    #[serde(default)]
    pub intro: Option<String>,
    #[serde(default, alias = "wordCount")]
    pub word_count: Option<String>,
}

/// 书籍详情规则
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct BookInfoRule {
    #[serde(default, alias = "bookInfoInit")]
    pub book_info_init: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub author: Option<String>,
    #[serde(default)]
    pub intro: Option<String>,
    #[serde(default, alias = "coverUrl")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default, alias = "wordCount")]
    pub word_count: Option<String>,
    #[serde(default, alias = "lastChapter")]
    pub last_chapter: Option<String>,
    #[serde(default, alias = "tocUrl")]
    pub toc_url: Option<String>,
    #[serde(default, alias = "canReName")]
    pub can_rename: Option<String>,
}

/// 目录规则
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TocRule {
    #[serde(default, alias = "chapterList")]
    pub chapter_list: Option<String>,
    #[serde(default, alias = "chapterName")]
    pub chapter_name: Option<String>,
    #[serde(default, alias = "chapterUrl")]
    pub chapter_url: Option<String>,
    #[serde(default, alias = "nextTocUrl")]
    pub next_toc_url: Option<String>,
    #[serde(default, alias = "isVip")]
    pub is_vip: Option<String>,
    #[serde(default, alias = "isPay")]
    pub is_pay: Option<String>,
    #[serde(default, alias = "isVolume")]
    pub is_volume: Option<String>,
    #[serde(default, alias = "updateTime")]
    pub update_time: Option<String>,
    #[serde(default, alias = "formatJs")]
    pub format_js: Option<String>,
    #[serde(default, alias = "preUpdateJs")]
    pub pre_update_js: Option<String>,
}

/// 内容规则
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ContentRule {
    #[serde(default)]
    pub content: Option<String>,
    #[serde(default, alias = "nextContentUrl")]
    pub next_content_url: Option<String>,
    #[serde(default, alias = "webJs")]
    pub web_js: Option<String>,
    #[serde(default, alias = "sourceRegex")]
    pub source_regex: Option<String>,
    #[serde(default, alias = "replaceRegex")]
    pub replace_regex: Option<String>,
    #[serde(default, alias = "imageStyle")]
    pub image_style: Option<String>,
    #[serde(default, alias = "imageDecode")]
    pub image_decode: Option<String>,
    #[serde(default, alias = "payAction")]
    pub pay_action: Option<String>,
    /// Rule to extract download URLs (for audio/file sources)
    #[serde(default, alias = "downloadUrls")]
    pub download_urls: Option<String>,
}

/// Extract a field from the source's `ContentRule`, treating empty / whitespace-only
/// strings as `None`.
///
/// Centralizes the convention that an empty string in any `ContentRule` field
/// means "field absent" — collapsing the three-step `source.rule_content.as_ref()
/// .and_then(f).filter(|s| !s.trim().is_empty())` chain to a single call site.
///
/// Lives here (next to `ContentRule`) rather than in `parser.rs` so that any
/// future caller wanting to read a `ContentRule` field with the same convention
/// only has one helper to import. F-W1B-035.
pub fn content_rule_field(
    source: &BookSource,
    f: impl FnOnce(&ContentRule) -> Option<String>,
) -> Option<String> {
    source
        .rule_content
        .as_ref()
        .and_then(f)
        .filter(|s| !s.trim().is_empty())
}

/// 评论/书评规则
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ReviewRule {
    #[serde(default, alias = "reviewUrl")]
    pub review_url: Option<String>,
    #[serde(default, alias = "avatarRule")]
    pub avatar_rule: Option<String>,
    #[serde(default, alias = "contentRule")]
    pub content_rule: Option<String>,
    #[serde(default, alias = "authorRule")]
    pub author_rule: Option<String>,
    #[serde(default, alias = "timeRule")]
    pub time_rule: Option<String>,
    #[serde(default, alias = "ratingRule")]
    pub rating_rule: Option<String>,
}

/// 搜索结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResultItem {
    pub name: String,
    pub author: Option<String>,
    pub cover_url: Option<String>,
    pub book_url: String,
    pub kind: Option<String>,
}

/// 提取类型后缀
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum ExtractType {
    Text,         // @text - 提取文本内容
    Html,         // @html - 提取 HTML 结构
    OwnText,      // @ownText - 仅元素自身文本
    Href,         // @href - 提取链接地址
    Src,          // @src - 提取资源地址
    TextNode,     // @textNode - 单个文本节点 / @textNodes - 所有文本节点
    Content,      // @content - 提取 content 属性 (用于 meta 标签等)
    Attr(String), // @attrName - 提取任意属性 (e.g. @title, @data-id)
    #[default]
    None, // 无后缀
}

impl ExtractType {
    /// 从规则字符串中解析提取类型
    pub fn from_rule(rule: &str) -> (&str, Self) {
        if let Some(s) = rule.strip_suffix("@textNodes") {
            (s, Self::TextNode)
        } else if let Some(s) = rule.strip_suffix("@textNode") {
            (s, Self::TextNode)
        } else if let Some(s) = rule.strip_suffix("@ownText") {
            (s, Self::OwnText)
        } else if let Some(s) = rule.strip_suffix("@content") {
            (s, Self::Content)
        } else if let Some(s) = rule.strip_suffix("@text") {
            (s, Self::Text)
        } else if let Some(s) = rule.strip_suffix("@html") {
            (s, Self::Html)
        } else if let Some(s) = rule.strip_suffix("@href") {
            (s, Self::Href)
        } else if let Some(s) = rule.strip_suffix("@src") {
            (s, Self::Src)
        } else if let Some(pos) = rule.rfind('@') {
            let attr_name = &rule[pos + 1..];
            if !attr_name.is_empty()
                && attr_name
                    .chars()
                    .all(|c| c.is_alphanumeric() || c == '_' || c == '-')
                && pos > 0
            {
                (&rule[..pos], Self::Attr(attr_name.to_string()))
            } else {
                (rule, Self::None)
            }
        } else {
            (rule, Self::None)
        }
    }

    /// Returns the attribute name if this is an Attr variant
    pub fn attribute_name(&self) -> Option<&str> {
        match self {
            Self::Attr(name) => Some(name.as_str()),
            _ => None,
        }
    }
}
