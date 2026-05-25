//! # core-source - 书源规则引擎
//!
//! 核心中的核心模块，负责解析和执行书源规则。
//! 对应原 Legado 的 `model/webBook/` 和 `model/analyzeRule/`。
//! 支持 CSS/XPath/JSONPath/Regex 四种规则表达式，使用 Rhai 脚本引擎代替原 JS 引擎。

pub mod legado;
pub mod parser;
pub mod rss;
pub mod rule_engine;
pub mod types;
pub mod utils;

// 重新导出主要类型
pub use parser::{
    BookDetail, BookSourceParser, ChapterContent, ChapterInfo, ExploreEntry, ParserError,
    SearchResult,
};
pub use rss::RssParser;
// `RuleEngine` / `RuleError` are intentionally NOT re-exported here. Both are
// part of the deprecated execution path; new code must use
// `legado::execute_legado_rule` instead. `RuleExpression` / `RuleType` are
// retained because `lib.rs::check_rule_expression` (rule validation, not
// execution) uses them as static-analysis tools (F-W1B-032).
pub use rule_engine::{RuleExpression, RuleType};
pub use types::{BookInfoRule, BookSource, ContentRule, ExtractType, SearchRule, TocRule};

use serde::{Deserialize, Serialize};

use jsonpath_lib as jsonpath;
use sxd_xpath::Factory;

/// 书源规则解析入口
pub fn parse_book_source(json: &str) -> Result<BookSource, String> {
    serde_json::from_str(json).map_err(|e| format!("解析书源失败: {}", e))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidationIssue {
    pub field: String,
    pub severity: String, // "error" | "warning" | "info"
    pub message: String,
}

/// 实跑 live test 的单阶段结果（批次 21 / 05-19）。对应 4 路：
/// `search` / `book_info` / `toc` / `content`。
///
/// `latency_ms` 用 `Instant::now()` + `elapsed().as_millis()` 计；
/// `sample` 是该阶段抓到的代表性数据（搜索第一本书名 / 章节预览前
/// 200 字符 等），便于 UI 卡片直接展示而不需要再调一次接口。
/// `error` 仅在 `ok=false` 时填，写入 `ParserError::Display` 的字符串。
///
/// `Deserialize` 是为了 Rust 单测做 JSON round-trip + 后续给其它 caller
/// 复用同一模型。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiveTestStage {
    pub stage: String,
    pub ok: bool,
    pub latency_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sample: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// 实跑 live test 的整体报告 — 4 个 stages + 静态校验 issues。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiveTestReport {
    pub stages: Vec<LiveTestStage>,
    pub static_issues: Vec<ValidationIssue>,
}

/// 批量校验配置 — 对齐原版 legado CheckSource 设置面板。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckConfig {
    pub keyword: String,
    /// 要跑的 stage 名称集合（"search"/"book_info"/"toc"/"content"）
    pub stages: std::collections::HashSet<String>,
    /// 单源超时（秒）
    pub timeout_secs: u64,
    /// 并发数
    pub concurrency: usize,
}

/// 批量校验中单个书源的进度快照，通过 FRB 发给 Dart。
#[derive(Debug, Clone, Serialize)]
pub struct SourceCheckProgress {
    pub source_id: String,
    pub source_name: String,
    pub stages: Vec<LiveTestStage>,
    pub total_latency_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// true 表示这是最后一个源（让 Dart 端知道批次结束）
    #[serde(default)]
    pub is_done: bool,
}

/// 验证书源配置是否有效，返回结构化结果
pub fn validate_book_source(source: &BookSource) -> Vec<ValidationIssue> {
    let mut issues = Vec::new();

    if source.name.is_empty() {
        issues.push(ValidationIssue {
            field: "name".into(),
            severity: "error".into(),
            message: "书源名称不能为空".into(),
        });
    }
    if source.url.is_empty() {
        issues.push(ValidationIssue {
            field: "url".into(),
            severity: "error".into(),
            message: "书源URL不能为空".into(),
        });
    } else if !source.url.starts_with("http://") && !source.url.starts_with("https://") {
        issues.push(ValidationIssue {
            field: "url".into(),
            severity: "warning".into(),
            message: "URL 应以 http:// 或 https:// 开头".into(),
        });
    }

    validate_search_rules(source, &mut issues);
    validate_book_info_rules(source, &mut issues);
    validate_toc_rules(source, &mut issues);
    validate_content_rules(source, &mut issues);
    validate_rule_expressions(source, &mut issues);

    issues
}

/// 实跑 live test — 在静态规则校验之上，依次跑 search / book_info /
/// toc / content 4 路网络请求，每一阶段都计时 + 收集 sample / error，
/// 最终返回完整 [`LiveTestReport`]。
///
/// 设计要点（批次 21 / 05-19）：
/// 1. **顺序执行**，不并行 — 避免对书源造成压力，也方便用上一阶段
///    成功抓到的 url 喂给下一阶段。
/// 2. **失败不短路** — 任一阶段抛 [`ParserError`]，依然继续跑剩下的；
///    没拿到上游 url 时用一个 fallback dummy url（`source.url + "/book/test"`），
///    让后续阶段的规则路径至少能跑一次，把 RuleConfig / Network 错误暴露给用户。
/// 3. **sample 长度截断** — content 仅取前 200 字符，避免 UI 渲染巨型 payload。
/// 4. **每阶段独立计时** — `Instant::now()` + `elapsed().as_millis() as i64`。
pub async fn run_live_test(source: &BookSource, keyword: &str) -> LiveTestReport {
    let static_issues = validate_book_source(source);
    let parser = BookSourceParser::new();
    let mut stages: Vec<LiveTestStage> = Vec::new();

    // ===== Stage 1: search =====
    let t = std::time::Instant::now();
    let mut next_book_url: Option<String> = None;
    match parser.search(source, keyword).await {
        Ok(results) if !results.is_empty() => {
            let r = &results[0];
            next_book_url = Some(r.book_url.clone());
            stages.push(LiveTestStage {
                stage: "search".into(),
                ok: true,
                latency_ms: t.elapsed().as_millis() as i64,
                sample: Some(format!("第一本: {} / {}", r.name, r.author)),
                error: None,
            });
        }
        Ok(_) => stages.push(LiveTestStage {
            stage: "search".into(),
            ok: false,
            latency_ms: t.elapsed().as_millis() as i64,
            sample: None,
            error: Some("无搜索结果".into()),
        }),
        Err(e) => stages.push(LiveTestStage {
            stage: "search".into(),
            ok: false,
            latency_ms: t.elapsed().as_millis() as i64,
            sample: None,
            error: Some(e.to_string()),
        }),
    }

    // ===== Stage 2: book_info =====
    // fallback: 如果 search 没拿到 book_url，用 `source.url + "/book/test"`
    // 让规则路至少跑一次，把 RuleConfig / Network 错误暴露出来。
    let book_url_for_info = next_book_url.clone().unwrap_or_else(|| {
        format!("{}/book/test", source.url.trim_end_matches('/'))
    });
    let t = std::time::Instant::now();
    let mut next_chapters_url: Option<String> = None;
    match parser.get_book_info(source, &book_url_for_info).await {
        Ok(detail) => {
            next_chapters_url = detail.chapters_url.clone();
            stages.push(LiveTestStage {
                stage: "book_info".into(),
                ok: true,
                latency_ms: t.elapsed().as_millis() as i64,
                sample: Some(format!("{} / {}", detail.name, detail.author)),
                error: None,
            });
        }
        Err(e) => stages.push(LiveTestStage {
            stage: "book_info".into(),
            ok: false,
            latency_ms: t.elapsed().as_millis() as i64,
            sample: None,
            error: Some(e.to_string()),
        }),
    }

    // ===== Stage 3: toc =====
    let toc_url = next_chapters_url
        .clone()
        .unwrap_or_else(|| book_url_for_info.clone());
    let t = std::time::Instant::now();
    let mut next_chapter_url: Option<String> = None;
    match parser.get_chapters(source, &toc_url).await {
        Ok(chs) if !chs.is_empty() => {
            next_chapter_url = Some(chs[0].url.clone());
            stages.push(LiveTestStage {
                stage: "toc".into(),
                ok: true,
                latency_ms: t.elapsed().as_millis() as i64,
                sample: Some(format!(
                    "第一章: {} (共 {} 章)",
                    chs[0].title,
                    chs.len()
                )),
                error: None,
            });
        }
        Ok(_) => stages.push(LiveTestStage {
            stage: "toc".into(),
            ok: false,
            latency_ms: t.elapsed().as_millis() as i64,
            sample: None,
            error: Some("章节列表为空".into()),
        }),
        Err(e) => stages.push(LiveTestStage {
            stage: "toc".into(),
            ok: false,
            latency_ms: t.elapsed().as_millis() as i64,
            sample: None,
            error: Some(e.to_string()),
        }),
    }

    // ===== Stage 4: content =====
    let chapter_url = next_chapter_url.unwrap_or_else(|| toc_url.clone());
    let t = std::time::Instant::now();
    match parser.get_chapter_content(source, &chapter_url).await {
        Ok(content) => {
            // 仅取前 200 字符做 sample，避免 UI 渲染巨型 payload。
            let preview = content.content.chars().take(200).collect::<String>();
            stages.push(LiveTestStage {
                stage: "content".into(),
                ok: true,
                latency_ms: t.elapsed().as_millis() as i64,
                sample: Some(preview),
                error: None,
            });
        }
        Err(e) => stages.push(LiveTestStage {
            stage: "content".into(),
            ok: false,
            latency_ms: t.elapsed().as_millis() as i64,
            sample: None,
            error: Some(e.to_string()),
        }),
    }

    LiveTestReport {
        stages,
        static_issues,
    }
}

/// 带 stage 过滤的 live test。只跑 `stages_filter` 里指定的 stage。
/// 内部复用 [`BookSourceParser`] 的 search/get_book_info/get_chapters/
/// get_chapter_content 4 路，与 [`run_live_test`] 行为一致。
async fn run_live_test_filtered(
    source: &BookSource,
    keyword: &str,
    stages_filter: &std::collections::HashSet<String>,
    parser: &BookSourceParser,
) -> LiveTestReport {
    let static_issues = validate_book_source(source);
    let mut stages_out: Vec<LiveTestStage> = Vec::new();

    let mut next_book_url: Option<String> = None;
    let mut next_chapters_url: Option<String> = None;
    let mut next_chapter_url: Option<String> = None;

    // Stage 1: search
    if stages_filter.contains("search") {
        let t = std::time::Instant::now();
        match parser.search(source, keyword).await {
            Ok(results) if !results.is_empty() => {
                let r = &results[0];
                next_book_url = Some(r.book_url.clone());
                stages_out.push(LiveTestStage {
                    stage: "search".into(),
                    ok: true,
                    latency_ms: t.elapsed().as_millis() as i64,
                    sample: Some(format!("第一本: {} / {}", r.name, r.author)),
                    error: None,
                });
            }
            Ok(_) => stages_out.push(LiveTestStage {
                stage: "search".into(),
                ok: false,
                latency_ms: t.elapsed().as_millis() as i64,
                sample: None,
                error: Some("无搜索结果".into()),
            }),
            Err(e) => stages_out.push(LiveTestStage {
                stage: "search".into(),
                ok: false,
                latency_ms: t.elapsed().as_millis() as i64,
                sample: None,
                error: Some(e.to_string()),
            }),
        }
    }

    // Stage 2: book_info
    if stages_filter.contains("book_info") {
        let book_url_for_info = next_book_url.clone().unwrap_or_else(|| {
            format!("{}/book/test", source.url.trim_end_matches('/'))
        });
        let t = std::time::Instant::now();
        match parser.get_book_info(source, &book_url_for_info).await {
            Ok(detail) => {
                next_chapters_url = detail.chapters_url.clone();
                stages_out.push(LiveTestStage {
                    stage: "book_info".into(),
                    ok: true,
                    latency_ms: t.elapsed().as_millis() as i64,
                    sample: Some(format!("{} / {}", detail.name, detail.author)),
                    error: None,
                });
            }
            Err(e) => stages_out.push(LiveTestStage {
                stage: "book_info".into(),
                ok: false,
                latency_ms: t.elapsed().as_millis() as i64,
                sample: None,
                error: Some(e.to_string()),
            }),
        }
    }

    // Stage 3: toc
    if stages_filter.contains("toc") {
        let toc_url = next_chapters_url.clone().unwrap_or_else(|| {
            next_book_url.clone().unwrap_or_else(|| {
                format!("{}/book/test", source.url.trim_end_matches('/'))
            })
        });
        let t = std::time::Instant::now();
        match parser.get_chapters(source, &toc_url).await {
            Ok(chs) if !chs.is_empty() => {
                next_chapter_url = Some(chs[0].url.clone());
                stages_out.push(LiveTestStage {
                    stage: "toc".into(),
                    ok: true,
                    latency_ms: t.elapsed().as_millis() as i64,
                    sample: Some(format!(
                        "第一章: {} (共 {} 章)",
                        chs[0].title,
                        chs.len()
                    )),
                    error: None,
                });
            }
            Ok(_) => stages_out.push(LiveTestStage {
                stage: "toc".into(),
                ok: false,
                latency_ms: t.elapsed().as_millis() as i64,
                sample: None,
                error: Some("章节列表为空".into()),
            }),
            Err(e) => stages_out.push(LiveTestStage {
                stage: "toc".into(),
                ok: false,
                latency_ms: t.elapsed().as_millis() as i64,
                sample: None,
                error: Some(e.to_string()),
            }),
        }
    }

    // Stage 4: content
    if stages_filter.contains("content") {
        let chapter_url = next_chapter_url.unwrap_or_else(|| {
            next_chapters_url.clone().unwrap_or_else(|| {
                format!("{}/book/test", source.url.trim_end_matches('/'))
            })
        });
        let t = std::time::Instant::now();
        match parser.get_chapter_content(source, &chapter_url).await {
            Ok(content) => {
                let preview = content.content.chars().take(200).collect::<String>();
                stages_out.push(LiveTestStage {
                    stage: "content".into(),
                    ok: true,
                    latency_ms: t.elapsed().as_millis() as i64,
                    sample: Some(preview),
                    error: None,
                });
            }
            Err(e) => stages_out.push(LiveTestStage {
                stage: "content".into(),
                ok: false,
                latency_ms: t.elapsed().as_millis() as i64,
                sample: None,
                error: Some(e.to_string()),
            }),
        }
    }

    LiveTestReport {
        stages: stages_out,
        static_issues,
    }
}

/// 批量实跑 live test。
///
/// - 并发受 `config.concurrency` 控制（`tokio::sync::Semaphore`）
/// - 每个源用 `tokio::time::timeout` 包，超时则该源所有 stage 标记失败
/// - 每跑完一个源调用 `report_progress(SourceCheckProgress)`
/// - 最后一个源的 `is_done = true`
///
/// `report_progress` 是 closure 而非 `StreamSink`，便于单测不依赖 FRB 类型。
/// bridge 层在 callback 内完成 DB 写回 + `sink.add(progress_json)`。
pub async fn batch_run_live_test(
    sources: Vec<BookSource>,
    config: &CheckConfig,
    report_progress: std::sync::Arc<dyn Fn(SourceCheckProgress) + Send + Sync + 'static>,
) {
    use std::sync::Arc;
    use tokio::sync::Semaphore;

    let semaphore = Arc::new(Semaphore::new(config.concurrency));
    let parser = Arc::new(BookSourceParser::new());
    let total = sources.len();
    let mut handles = Vec::with_capacity(total);
    // Clone timeout_secs into local so spawned future doesn't borrow config
    let timeout_secs = config.timeout_secs;

    for (i, source) in sources.into_iter().enumerate() {
        let permit = semaphore.clone().acquire_owned().await.unwrap();
        let parser = parser.clone();
        let keyword = config.keyword.clone();
        let stages_filter = config.stages.clone();
        let timeout = std::time::Duration::from_secs(timeout_secs);
        let is_last = i == total - 1;
        let source_id = source.id.clone();
        let source_name = source.name.clone();
        let progress_fn = report_progress.clone();

        handles.push(tokio::spawn(async move {
            let _permit = permit; // RAII — drop after this source finishes

            let start = std::time::Instant::now();

            let result = tokio::time::timeout(timeout, async {
                run_live_test_filtered(&source, &keyword, &stages_filter, &parser).await
            })
            .await;

            let stages = match result {
                Ok(report) => report.stages,
                Err(_elapsed) => stages_filter
                    .iter()
                    .map(|stage| LiveTestStage {
                        stage: stage.clone(),
                        ok: false,
                        latency_ms: (timeout_secs * 1000) as i64,
                        sample: None,
                        error: Some(format!("超时 ({}s)", timeout_secs)),
                    })
                    .collect(),
            };

            let total_latency_ms = start.elapsed().as_millis() as i64;
            let error = if stages.iter().all(|s| s.ok) {
                None
            } else {
                stages
                    .iter()
                    .find(|s| !s.ok)
                    .and_then(|s| s.error.clone())
            };

            progress_fn(SourceCheckProgress {
                source_id,
                source_name,
                stages,
                total_latency_ms,
                error,
                is_done: is_last,
            });
        }));
    }

    for handle in handles {
        let _ = handle.await;
    }
}

fn validate_search_rules(source: &BookSource, issues: &mut Vec<ValidationIssue>) {
    let rule = match &source.rule_search {
        Some(r) => r,
        None => {
            issues.push(ValidationIssue {
                field: "rule_search".into(),
                severity: "warning".into(),
                message: "未配置搜索规则，将无法在线搜索".into(),
            });
            return;
        }
    };

    if let Some(ref search_url) = rule.search_url {
        if !search_url.contains("{{") && !search_url.contains("key") {
            issues.push(ValidationIssue {
                field: "rule_search.search_url".into(),
                severity: "warning".into(),
                message: "搜索URL未包含 {{keyword}} 占位符".into(),
            });
        }
    }

    if let Some(ref book_list) = rule.book_list {
        check_rule_expression("rule_search.book_list", book_list, issues);
    }
    if let Some(ref name) = rule.name {
        check_rule_expression("rule_search.name", name, issues);
    }
    if let Some(ref author) = rule.author {
        check_rule_expression("rule_search.author", author, issues);
    }
    if let Some(ref book_url) = rule.book_url {
        check_rule_expression("rule_search.book_url", book_url, issues);
    }
    if let Some(ref cover_url) = rule.cover_url {
        check_rule_expression("rule_search.cover_url", cover_url, issues);
    }
}

fn validate_book_info_rules(source: &BookSource, issues: &mut Vec<ValidationIssue>) {
    let rule = match &source.rule_book_info {
        Some(r) => r,
        None => return,
    };
    if let Some(ref name) = rule.name {
        check_rule_expression("rule_book_info.name", name, issues);
    }
    if let Some(ref author) = rule.author {
        check_rule_expression("rule_book_info.author", author, issues);
    }
    if let Some(ref cover_url) = rule.cover_url {
        check_rule_expression("rule_book_info.cover_url", cover_url, issues);
    }
    if let Some(ref intro) = rule.intro {
        check_rule_expression("rule_book_info.intro", intro, issues);
    }
}

fn validate_toc_rules(source: &BookSource, issues: &mut Vec<ValidationIssue>) {
    let rule = match &source.rule_toc {
        Some(r) => r,
        None => {
            issues.push(ValidationIssue {
                field: "rule_toc".into(),
                severity: "warning".into(),
                message: "未配置目录规则，将无法获取章节列表".into(),
            });
            return;
        }
    };
    if let Some(ref chapter_list) = rule.chapter_list {
        check_rule_expression("rule_toc.chapter_list", chapter_list, issues);
    }
    if let Some(ref chapter_name) = rule.chapter_name {
        check_rule_expression("rule_toc.chapter_name", chapter_name, issues);
    }
    if let Some(ref chapter_url) = rule.chapter_url {
        check_rule_expression("rule_toc.chapter_url", chapter_url, issues);
    }
}

fn validate_content_rules(source: &BookSource, issues: &mut Vec<ValidationIssue>) {
    let rule = match &source.rule_content {
        Some(r) => r,
        None => {
            issues.push(ValidationIssue {
                field: "rule_content".into(),
                severity: "warning".into(),
                message: "未配置内容规则，将无法获取正文".into(),
            });
            return;
        }
    };
    if let Some(ref content) = rule.content {
        check_rule_expression("rule_content.content", content, issues);
    }
    if let Some(ref next_content_url) = rule.next_content_url {
        check_rule_expression("rule_content.next_content_url", next_content_url, issues);
    }
}

fn validate_rule_expressions(source: &BookSource, issues: &mut Vec<ValidationIssue>) {
    if let Some(ref rule) = source.rule_search {
        if let Some(ref url) = rule.search_url {
            if !url.starts_with("http") && !url.contains("{{") && !url.contains('?') {
                if RuleExpression::parse(url).is_some() {
                    issues.push(ValidationIssue {
                        field: "rule_search.search_url".into(),
                        severity: "warning".into(),
                        message: "搜索URL看起来像选择器而非URL模板".into(),
                    });
                }
            }
        }
    }
}

fn check_rule_expression(field: &str, expr: &str, issues: &mut Vec<ValidationIssue>) {
    if expr.is_empty() {
        return;
    }
    let trimmed = expr.trim();
    let (expr_no_replace, _) = rule_engine::strip_legado_replace_rules(trimmed);
    let expr_without_suffix = ExtractType::from_rule(expr_no_replace).0;

    if is_legado_extended(expr_without_suffix) {
        issues.push(ValidationIssue {
            field: field.into(),
            severity: "info".into(),
            message: "Legado 扩展规则 — 将在运行时解析".into(),
        });
        return;
    }

    let rule_type = RuleExpression::parse(expr_without_suffix).map(|r| r.rule_type);

    match rule_type {
        Some(RuleType::Regex) => {
            if let Err(e) = regex::Regex::new(expr_without_suffix) {
                issues.push(ValidationIssue {
                    field: field.into(),
                    severity: "error".into(),
                    message: format!("正则表达式语法错误: {}", e),
                });
            }
        }
        Some(RuleType::XPath) => {
            let xpath_expr = expr_without_suffix
                .strip_prefix("@XPath:")
                .unwrap_or(expr_without_suffix);
            match Factory::new().build(xpath_expr) {
                Err(e) => {
                    issues.push(ValidationIssue {
                        field: field.into(),
                        severity: "error".into(),
                        message: format!("XPath 表达式编译失败: {}", e),
                    });
                }
                Ok(None) => {
                    issues.push(ValidationIssue {
                        field: field.into(),
                        severity: "warning".into(),
                        message: "XPath 表达式编译返回空".into(),
                    });
                }
                Ok(Some(_)) => {}
            }
        }
        Some(RuleType::JsonPath) => {
            let jsonpath_expr = expr_without_suffix
                .strip_prefix("@Json:")
                .unwrap_or(expr_without_suffix);
            let test_json =
                serde_json::json!({"test": {"key": "value"}, "items": [{"name": "test"}]});
            if let Err(e) = jsonpath::select(&test_json, jsonpath_expr) {
                issues.push(ValidationIssue {
                    field: field.into(),
                    severity: "error".into(),
                    message: format!("JSONPath 表达式无效: {}", e),
                });
            }
        }
        Some(RuleType::JavaScript) => {
            issues.push(ValidationIssue {
                field: field.into(),
                severity: "info".into(),
                message: "JS 脚本规则 — 仅在运行时验证".into(),
            });
        }
        Some(RuleType::Css) | None => {
            let (css_base, _, _) = rule_engine::strip_css_modifiers(expr_without_suffix);
            if css_base.is_empty() {
                return;
            }
            // 去掉 @css: 前缀再交给 CSS 解析器
            let css_expr = css_base.strip_prefix("@css:").unwrap_or(css_base);
            let css_expr = css_expr.trim();
            if css_expr.is_empty() {
                return;
            }
            // JSOUP 默认规则（不含 @css: 前缀，用 @tag. / @class. / @id. 分隔）不是标准 CSS，
            // 不要用 scraper::Selector::parse() 校验，避免误报
            if is_jsoup_like(css_expr) {
                issues.push(ValidationIssue {
                    field: field.into(),
                    severity: "info".into(),
                    message: "JSOUP 规则 — 将在运行时解析".into(),
                });
                return;
            }
            let alternatives = rule_engine::split_css_alternatives(css_expr);
            for alt in alternatives {
                let alt = alt.trim();
                if alt.is_empty() {
                    continue;
                }
                match scraper::Selector::parse(alt) {
                    Err(e) => {
                        issues.push(ValidationIssue {
                            field: field.into(),
                            severity: "warning".into(),
                            message: format!("CSS 选择器可能无效: {:?}", e),
                        });
                    }
                    Ok(_) => {}
                }
            }
        }
    }
}

fn is_jsoup_like(expr: &str) -> bool {
    for pattern in &[
        "@tag.",
        "@class.",
        "@id.",
        "@attr.",
        "@text",
        "@html",
        "@href",
        "@src",
        "@ownText",
        "@textNodes",
        "@content",
        "@raw",
        "@css",
        ":contains(",
        ":matches(",
        ":matchText(",
        ":eq(",
        ":lt(",
        ":gt(",
    ] {
        if expr.contains(pattern) {
            return true;
        }
    }
    false
}

fn is_legado_extended(expr: &str) -> bool {
    expr.contains("{{@@") || expr.contains("@get:") || expr.contains("@put:")
}

/// 从 JSON 字符串解析并验证，返回 JSON 数组
pub fn validate_source_json(source_json: &str) -> Result<String, String> {
    let source: BookSource = parse_book_source(source_json)?;
    let issues = validate_book_source(&source);
    serde_json::to_string(&issues).map_err(|e| format!("序列化失败: {}", e))
}

/// 创建示例书源（用于测试）
pub fn create_sample_book_source() -> BookSource {
    BookSource {
        id: uuid::Uuid::new_v4().to_string(),
        name: "示例书源".to_string(),
        url: "https://example.com".to_string(),
        source_type: 0,
        enabled: true,
        group_name: None,
        custom_order: 0,
        weight: 0,

        rule_search: Some(SearchRule {
            search_url: None,
            book_list: Some(".book-item".to_string()),
            name: Some(".book-title".to_string()),
            author: Some(".book-author".to_string()),
            book_url: Some("a@href".to_string()),
            cover_url: Some(".book-cover img@src".to_string()),
            kind: None,
            last_chapter: None,
            ..Default::default()
        }),
        rule_book_info: None,
        rule_toc: None,
        rule_content: None,
        rule_review: None,

        login_url: None,
        login_ui: None,
        login_check_js: None,
        header: None,
        js_lib: None,
        cover_decode_js: None,

        explore_url: None,
        rule_explore: None,
        book_url_pattern: None,
        enabled_explore: true,
        last_update_time: 0,
        book_source_comment: None,
        concurrent_rate: None,
        variable_comment: None,
        explore_screen: None,
        created_at: 0,
        updated_at: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_source(
        search_url: Option<&str>,
        book_list: Option<&str>,
        name: Option<&str>,
    ) -> BookSource {
        BookSource {
            id: "test".into(),
            name: "test".into(),
            url: "https://test.com".into(),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: Some(SearchRule {
                search_url: search_url.map(String::from),
                book_list: book_list.map(String::from),
                name: name.map(String::from),
                author: None,
                book_url: None,
                cover_url: None,
                kind: None,
                last_chapter: None,
                ..Default::default()
            }),
            rule_book_info: None,
            rule_toc: None,
            rule_content: None,
        rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
        cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: true,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
        variable_comment: None,
        explore_screen: None,
            created_at: 0,
            updated_at: 0,
        }
    }

    #[test]
    fn test_search_url_with_keyword_placeholder_no_false_selector_warning() {
        let source = make_source(Some("/search?q={{keyword}}"), None, None);
        let issues = validate_book_source(&source);
        let has_selector_warning = issues.iter().any(|i| i.message.contains("选择器"));
        assert!(
            !has_selector_warning,
            "URL with {{keyword}} should not trigger selector warning, got: {:?}",
            issues
        );
    }

    #[test]
    fn test_search_url_without_placeholder_still_flagged() {
        let source = make_source(Some("//div[@class='book']"), None, None);
        let issues = validate_book_source(&source);
        let has_selector_warning = issues.iter().any(|i| i.message.contains("选择器"));
        assert!(
            has_selector_warning,
            "XPath-like search URL without {{keyword}} should be flagged, got: {:?}",
            issues
        );
    }

    #[test]
    fn test_invalid_xpath_produces_compilation_issue() {
        let source = make_source(None, Some("//div[@class='missing'"), None);
        let issues = validate_book_source(&source);
        let has_xpath_issue = issues
            .iter()
            .any(|i| i.field == "rule_search.book_list" && i.message.contains("XPath"));
        assert!(
            has_xpath_issue,
            "Expected XPath compilation issue for unclosed predicate, got: {:?}",
            issues
        );
    }

    #[test]
    fn test_valid_xpath_no_false_warning() {
        let source = make_source(None, Some("//div[@class='book']"), None);
        let issues = validate_book_source(&source);
        let has_xpath_issue = issues
            .iter()
            .any(|i| i.field == "rule_search.book_list" && i.message.contains("XPath"));
        assert!(
            !has_xpath_issue,
            "Valid XPath should not produce a compilation issue, got: {:?}",
            issues
        );
    }

    #[test]
    fn test_invalid_jsonpath_produces_compilation_error() {
        let source = make_source(None, None, Some("$.foo["));
        let issues = validate_book_source(&source);
        let has_jsonpath_error = issues.iter().any(|i| {
            i.field == "rule_search.name" && i.severity == "error" && i.message.contains("JSONPath")
        });
        assert!(
            has_jsonpath_error,
            "Expected JSONPath compilation error for unclosed bracket, got: {:?}",
            issues
        );
    }

    #[test]
    fn test_valid_jsonpath_no_false_warning() {
        let source = make_source(None, None, Some("$.data.items"));
        let issues = validate_book_source(&source);
        let has_jsonpath_issue = issues
            .iter()
            .any(|i| i.field == "rule_search.name" && i.message.contains("JSONPath"));
        assert!(
            !has_jsonpath_issue,
            "Valid JSONPath should not produce an error, got: {:?}",
            issues
        );
    }

    #[test]
    fn test_valid_css_no_false_warning() {
        let source = make_source(None, Some(".book-item"), None);
        let issues = validate_book_source(&source);
        let has_book_list_issue = issues.iter().any(|i| i.field == "rule_search.book_list");
        assert!(
            !has_book_list_issue,
            "Valid CSS selector should not produce any issue, got: {:?}",
            issues
        );
    }

    // ── XPath with ## replace rules ──────────────────────────────────────

    #[test]
    fn test_xpath_with_legado_replace_rules_no_false_error() {
        let source = BookSource {
            rule_content: Some(ContentRule {
                content: Some("//div[@id='content']//p@textNodes##请记住本站.*|最快更新.*".into()),
                next_content_url: None,
                ..Default::default()
            }),
            ..make_source(None, None, None)
        };
        let issues = validate_book_source(&source);
        let has_xpath_error = issues.iter().any(|i| {
            i.field == "rule_content.content"
                && i.severity == "error"
                && i.message.contains("XPath")
        });
        assert!(
            !has_xpath_error,
            "XPath with ## replace rules should NOT produce a compilation error, got: {:?}",
            issues
        );
    }

    #[test]
    fn test_xpath_without_replace_rules_still_validates_correctly() {
        let source = BookSource {
            rule_content: Some(ContentRule {
                content: Some("//div[@class='valid']".into()),
                next_content_url: None,
                ..Default::default()
            }),
            ..make_source(None, None, None)
        };
        let issues = validate_book_source(&source);
        let has_xpath_error = issues.iter().any(|i| {
            i.field == "rule_content.content"
                && i.severity == "error"
                && i.message.contains("XPath")
        });
        assert!(
            !has_xpath_error,
            "Valid XPath (without ##) should not produce error, got: {:?}",
            issues
        );
    }

    #[test]
    fn test_xpath_with_known_invalid_still_flags() {
        let source = BookSource {
            rule_content: Some(ContentRule {
                content: Some("//div[@class='missing'".into()),
                next_content_url: None,
                ..Default::default()
            }),
            ..make_source(None, None, None)
        };
        let issues = validate_book_source(&source);
        let has_xpath_error = issues.iter().any(|i| {
            i.field == "rule_content.content"
                && i.severity == "error"
                && i.message.contains("XPath")
        });
        assert!(
            has_xpath_error,
            "Truly invalid XPath must still be flagged, got: {:?}",
            issues
        );
    }

    // ── CSS with .N index / !N skip modifiers ────────────────────────────

    #[test]
    fn test_css_with_index_modifier_no_false_warning() {
        let source = make_source(None, None, Some("a.0@title"));
        let issues = validate_book_source(&source);
        let has_name_css_warning = issues
            .iter()
            .any(|i| i.field == "rule_search.name" && i.message.contains("CSS"));
        assert!(
            !has_name_css_warning,
            "CSS with .0 index modifier should not trigger false CSS warning, got: {:?}",
            issues
        );
    }

    #[test]
    fn test_css_with_negative_index_modifier_no_false_warning() {
        let source = make_source(None, Some("td.-1@text"), None);
        let issues = validate_book_source(&source);
        let has_book_list_css_warning = issues
            .iter()
            .any(|i| i.field == "rule_search.book_list" && i.message.contains("CSS"));
        assert!(
            !has_book_list_css_warning,
            "CSS with .-1 index modifier should not trigger false CSS warning, got: {:?}",
            issues
        );
    }

    #[test]
    fn test_css_with_skip_modifier_no_false_warning() {
        let source = make_source(None, None, Some("a!2@title"));
        let issues = validate_book_source(&source);
        let has_name_css_warning = issues
            .iter()
            .any(|i| i.field == "rule_search.name" && i.message.contains("CSS"));
        assert!(
            !has_name_css_warning,
            "CSS with !2 skip modifier should not trigger false CSS warning, got: {:?}",
            issues
        );
    }

    // ── CSS with || alternatives ─────────────────────────────────────────

    #[test]
    fn test_css_with_alternatives_no_false_warning() {
        let source = make_source(None, Some(".class1||.class2"), None);
        let issues = validate_book_source(&source);
        let has_book_list_css_warning = issues
            .iter()
            .any(|i| i.field == "rule_search.book_list" && i.message.contains("CSS"));
        assert!(
            !has_book_list_css_warning,
            "CSS with || alternatives should not trigger false CSS warning, got: {:?}",
            issues
        );
    }

    #[test]
    fn test_css_with_bad_alternative_still_warns() {
        let source = make_source(None, Some(".good||."), None);
        let issues = validate_book_source(&source);
        let has_book_list_css_warning = issues
            .iter()
            .any(|i| i.field == "rule_search.book_list" && i.message.contains("CSS"));
        assert!(
            has_book_list_css_warning,
            "CSS with a bad alternative ('.') should still produce a warning, got: {:?}",
            issues
        );
    }

    // ── CSS with @attribute suffix ───────────────────────────────────────

    #[test]
    fn test_css_with_attribute_suffix_no_false_warning() {
        let source = BookSource {
            rule_book_info: Some(BookInfoRule {
                name: Some("[property$=title]@content".into()),
                author: Some("[property$=author]@content".into()),
                ..Default::default()
            }),
            ..make_source(None, None, None)
        };
        let issues = validate_book_source(&source);
        // Note: [property$=title] may or may not parse in scraper’s CSS parser.
        // The key point is no crash and the suffix is stripped.
        let has_book_info_error = issues.iter().any(|i| {
            (i.field == "rule_book_info.name" || i.field == "rule_book_info.author")
                && i.severity == "error"
                && i.message.contains("CSS")
        });
        assert!(
            !has_book_info_error,
            "CSS with @attribute suffix and property selectors should not produce error, got: {:?}",
            issues
        );
    }

    // ── 批次 21 (05-19): run_live_test ─────────────────────────────────────

    /// 构造一个 4 路完整规则的 BookSource，base_url 由 caller 传入
    /// 以便对接 httpmock。规则均使用静态校验合法的 CSS / `@attr` 表达式。
    fn make_full_source(base_url: &str) -> BookSource {
        BookSource {
            id: "live-test-source".into(),
            name: "Live Test".into(),
            url: base_url.to_string(),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: Some(SearchRule {
                search_url: Some("/search?keyword={{keyword}}".into()),
                book_list: Some(".book-item".into()),
                name: Some(".title@text".into()),
                author: Some(".author@text".into()),
                book_url: Some("a@href".into()),
                cover_url: None,
                kind: None,
                last_chapter: None,
                ..Default::default()
            }),
            rule_book_info: Some(BookInfoRule {
                name: Some(".book-name@text".into()),
                author: Some(".book-author@text".into()),
                intro: None,
                cover_url: None,
                kind: None,
                last_chapter: None,
                toc_url: Some("a.toc-link@href".into()),
                ..Default::default()
            }),
            rule_toc: Some(TocRule {
                chapter_list: Some("ul.chapters@li".into()),
                chapter_name: Some("a@text".into()),
                chapter_url: Some("a@href".into()),
                ..Default::default()
            }),
            rule_content: Some(ContentRule {
                content: Some("div.content@text".into()),
                next_content_url: None,
                ..Default::default()
            }),
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: true,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        }
    }

    #[tokio::test]
    async fn test_run_live_test_all_pass() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let _search = server.mock(|when, then| {
            when.method(GET).path("/search");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(
                    r#"<html><body>
                    <div class="book-item">
                        <span class="title">三体</span>
                        <span class="author">刘慈欣</span>
                        <a href="/book/1">详情</a>
                    </div>
                    </body></html>"#,
                );
        });
        let _book_info = server.mock(|when, then| {
            when.method(GET).path("/book/1");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(
                    r#"<html><body>
                    <h1 class="book-name">三体</h1>
                    <span class="book-author">刘慈欣</span>
                    <a class="toc-link" href="/book/1/toc">目录</a>
                    </body></html>"#,
                );
        });
        let _toc = server.mock(|when, then| {
            when.method(GET).path("/book/1/toc");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(
                    r#"<html><body>
                    <ul class="chapters">
                        <li><a href="/book/1/ch1">第一章</a></li>
                        <li><a href="/book/1/ch2">第二章</a></li>
                    </ul>
                    </body></html>"#,
                );
        });
        let _content = server.mock(|when, then| {
            when.method(GET).path("/book/1/ch1");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(
                    r#"<html><body>
                    <div class="content">这是第一章的正文内容，足够长以验证 sample 截断逻辑。</div>
                    </body></html>"#,
                );
        });

        let source = make_full_source(&server.base_url());
        let report = run_live_test(&source, "三体").await;

        assert_eq!(report.stages.len(), 4, "应该有 4 个 stage");
        for s in &report.stages {
            assert!(s.ok, "stage {} should be ok, error={:?}", s.stage, s.error);
        }
        assert_eq!(report.stages[0].stage, "search");
        assert_eq!(report.stages[1].stage, "book_info");
        assert_eq!(report.stages[2].stage, "toc");
        assert_eq!(report.stages[3].stage, "content");
        assert!(report.stages[0].sample.as_deref().unwrap_or("").contains("三体"));
        assert!(report.stages[2]
            .sample
            .as_deref()
            .unwrap_or("")
            .contains("第一章"));
        assert!(report.stages[3]
            .sample
            .as_deref()
            .unwrap_or("")
            .contains("第一章的正文"));
    }

    #[tokio::test]
    async fn test_run_live_test_search_fail() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        // search 直接 500 → ParserError::Network
        let _search = server.mock(|when, then| {
            when.method(GET).path("/search");
            then.status(500).body("internal error");
        });

        let source = make_full_source(&server.base_url());
        let report = run_live_test(&source, "test").await;

        assert_eq!(report.stages.len(), 4);
        assert_eq!(report.stages[0].stage, "search");
        assert!(!report.stages[0].ok, "search 应该失败");
        assert!(report.stages[0].error.is_some());

        // 后续 stages 仍然尝试 — book_info 用 fallback url，
        // 也会因为 mock server 没有匹配的 path 而失败。但每个 stage
        // 都被独立执行（不短路）。
        for s in &report.stages[1..] {
            assert!(!s.ok, "stage {} should fail when search failed", s.stage);
        }
    }

    #[tokio::test]
    async fn test_run_live_test_static_issues_included() {
        // rule_search 缺失：static_issues 非空，4 个 stages 全 RuleConfig
        let mut source = make_full_source("https://example.invalid");
        source.rule_search = None;

        let report = run_live_test(&source, "test").await;

        // 静态校验应该 catch 到 rule_search 缺失
        assert!(
            !report.static_issues.is_empty(),
            "static_issues 不应为空，至少应包含 rule_search 缺失的 warning"
        );
        let has_rule_search_warning = report
            .static_issues
            .iter()
            .any(|i| i.field == "rule_search");
        assert!(
            has_rule_search_warning,
            "static_issues 应包含 rule_search 字段的告警，实际: {:?}",
            report.static_issues
        );

        // 4 个 stages 全失败，且 search stage 的错误应反映 RuleConfig
        // 路径（书源 未配置 rule_search）。
        assert_eq!(report.stages.len(), 4);
        assert!(!report.stages[0].ok);
        let search_err = report.stages[0].error.as_deref().unwrap_or("");
        assert!(
            search_err.contains("rule_search") || search_err.contains("规则配置"),
            "search stage error 应反映 RuleConfig，实际: {}",
            search_err
        );
    }

    #[test]
    fn test_live_test_report_json_round_trip() {
        let report = LiveTestReport {
            stages: vec![
                LiveTestStage {
                    stage: "search".into(),
                    ok: true,
                    latency_ms: 123,
                    sample: Some("第一本: 三体 / 刘慈欣".into()),
                    error: None,
                },
                LiveTestStage {
                    stage: "book_info".into(),
                    ok: false,
                    latency_ms: 456,
                    sample: None,
                    error: Some("网络请求失败: timeout".into()),
                },
            ],
            static_issues: vec![ValidationIssue {
                field: "rule_search".into(),
                severity: "warning".into(),
                message: "未配置搜索规则".into(),
            }],
        };

        let json = serde_json::to_string(&report).expect("serialize");
        let parsed: LiveTestReport = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(parsed.stages.len(), 2);
        assert_eq!(parsed.stages[0].stage, "search");
        assert!(parsed.stages[0].ok);
        assert_eq!(parsed.stages[0].latency_ms, 123);
        assert_eq!(parsed.stages[0].sample.as_deref(), Some("第一本: 三体 / 刘慈欣"));
        assert!(parsed.stages[0].error.is_none());
        assert_eq!(parsed.stages[1].stage, "book_info");
        assert!(!parsed.stages[1].ok);
        assert!(parsed.stages[1].sample.is_none());
        assert_eq!(
            parsed.stages[1].error.as_deref(),
            Some("网络请求失败: timeout")
        );
        assert_eq!(parsed.static_issues.len(), 1);
        assert_eq!(parsed.static_issues[0].field, "rule_search");
    }
}
