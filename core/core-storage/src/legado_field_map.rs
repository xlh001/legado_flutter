//! # Legado 字段映射 (批次 10)
//!
//! 把原 Legado (Kotlin/Android) 备份 JSON 的 entity 字段映射到本端口
//! `core-storage::models` 的 struct。详见
//! `.trellis/tasks/05-19-local-backup-restore-batch10/research/legado-backup-format.md`
//! §6 字段映射表。
//!
//! 核心约定：
//! - 时间戳：原 Legado 全部毫秒，本端口存秒。新增 [`ms_to_seconds_smart`]
//!   做防御式判断（>1e10 视为毫秒，否则原样）。
//! - `BookGroup.id`：原 bitmask（1<<n）→ 本端口自增 id。取最低位 power-of-2
//!   的 log2，对应 [`legado_group_bitmask_to_id`]。
//! - 字段缺失：原 Legado 31 字段 vs 本端口 26 字段，差额（type / customTag /
//!   readConfig 等）打包成 `_legado_backup` JSON 塞 `Book.custom_info_json`。
//! - `wordCount`：原 String "5.2M" / "10万" / "120K" → i32，见
//!   [`parse_word_count`]。
//! - `origin` URL → `source_id` UUID：调用方提供 `sources_url_to_id` 映射表。

use crate::models::{Book, BookGroup, Bookmark, BookSource, ReplaceRule};
use chrono::Utc;
use serde_json::{json, Value};
use std::collections::HashMap;
use uuid::Uuid;

// ============================================================
// 基础转换 helpers
// ============================================================

/// "5.2M" / "10万" / "120K" / "8523" / "" → i32
///
/// 解析规则：
/// - 空 / None → 0
/// - 后缀 K / k → ×1_000
/// - 后缀 M / m → ×1_000_000
/// - 后缀 万 → ×10_000
/// - 后缀 亿 → ×100_000_000
/// - 纯数字 → 直接 parse
/// - 浮点（"5.2M"）→ 先 parse f64，乘后转 i32
/// - 解析失败 → 0（不抛错，备份恢复要尽量宽容）
pub fn parse_word_count(s: &str) -> i32 {
    let s = s.trim();
    if s.is_empty() {
        return 0;
    }

    // 先看末尾后缀字符（注意"万"/"亿"是中文 char，要按 char 取）
    let last_char = s.chars().last().unwrap_or(' ');
    let (num_part, multiplier): (&str, f64) = match last_char {
        'K' | 'k' => (&s[..s.len() - 1], 1_000.0),
        'M' | 'm' => (&s[..s.len() - 1], 1_000_000.0),
        '万' => (&s[..s.len() - "万".len()], 10_000.0),
        '亿' => (&s[..s.len() - "亿".len()], 100_000_000.0),
        _ => (s, 1.0),
    };

    let num_part = num_part.trim();
    if num_part.is_empty() {
        return 0;
    }

    // 先试整数，失败再试浮点
    if let Ok(n) = num_part.parse::<i64>() {
        return saturate_i32((n as f64 * multiplier) as i64);
    }
    if let Ok(f) = num_part.parse::<f64>() {
        return saturate_i32((f * multiplier) as i64);
    }
    0
}

fn saturate_i32(v: i64) -> i32 {
    if v > i32::MAX as i64 {
        i32::MAX
    } else if v < i32::MIN as i64 {
        i32::MIN
    } else {
        v as i32
    }
}

/// 取 bitmask 最低位 power-of-2 → log2 + 1
///
/// 原 Legado `BookGroup.groupId` 用 bitmask 表示一本书可在多个分组。
/// 本端口只支持单分组（`Book.group_id` i64 外键），导入时取最低位
/// power-of-2 作为目标分组 id。
///
/// 映射规则：
/// - `0` → `0`（未分组）
/// - `1` (0b001) → `1`（第一个用户分组）
/// - `2` (0b010) → `2`
/// - `4` (0b100) → `3`
/// - `8` → `4`
/// - `3` (0b011 = 1+2) → `1`（取最低位 = 1，对应分组 1）
/// - `5` (0b101 = 1+4) → `1`（取最低位 = 1）
/// - `6` (0b110 = 2+4) → `2`（取最低位 = 2）
/// - 负数（系统保留 ID 如 -100/-1/-2/-3/-4/-5/-11）→ `0`（这些是 UI
///   虚拟分组，原 Legado 备份不会写入这些值，但仍做防御）
pub fn legado_group_bitmask_to_id(bitmask: i64) -> i64 {
    if bitmask <= 0 {
        return 0;
    }
    // 取最低位（lowest set bit），等于 bitmask & -bitmask
    let lowest = bitmask & bitmask.wrapping_neg();
    // 算 log2(lowest) + 1：log2(1)=0 → id=1，log2(2)=1 → id=2，log2(4)=2 → id=3
    (lowest.trailing_zeros() as i64) + 1
}

/// 时间戳防御式 ms → s 转换。
///
/// 原 Legado 毫秒，本端口秒。但备份恢复路径有可能拿到已经是秒的字段
/// （如本端口先导出再导入），所以做启发式判断：
/// - 0 → 0
/// - 绝对值 >1e10 → 视为毫秒 / 1000
/// - 否则原样返回
///
/// 1e10 秒 ≈ 公元 2286 年；1e10 毫秒 ≈ 1970 年的 0.3 年位置。
/// 两个量级差 1000 倍，安全分界。
pub fn ms_to_seconds_smart(value: i64) -> i64 {
    if value == 0 {
        return 0;
    }
    if value.abs() > 10_000_000_000 {
        value / 1000
    } else {
        value
    }
}

// ============================================================
// Book 映射
// ============================================================

/// Legado `Book` JSON → `models::Book`
///
/// `sources_url_to_id`：调用方先把所有 BookSource 入库后构造的
/// `(book_source_url → source_id UUID)` 映射表。当原 Legado 的
/// `origin` URL 在表中找不到时（比如用户备份带的书源在本端口没装），
/// 仍保留原 URL 作为 `source_id` 字符串（Legado 兼容字段，导入后用户
/// 重装书源仍可关联回去）。
pub fn legado_book_to_storage_book(
    legado: &Value,
    sources_url_to_id: &HashMap<String, String>,
) -> Result<Book, String> {
    let now = Utc::now().timestamp();

    let book_url = legado.get("bookUrl").and_then(|v| v.as_str()).map(String::from);
    let toc_url = legado.get("tocUrl").and_then(|v| v.as_str()).map(String::from);
    let origin = legado
        .get("origin")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let origin_name = legado
        .get("originName")
        .and_then(|v| v.as_str())
        .map(String::from);
    let name = legado
        .get("name")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Legado Book 缺少 name 字段".to_string())?
        .to_string();
    let author = legado.get("author").and_then(|v| v.as_str()).map(String::from);
    let kind = legado.get("kind").and_then(|v| v.as_str()).map(String::from);
    let cover_url = legado.get("coverUrl").and_then(|v| v.as_str()).map(String::from);
    let custom_cover_url = legado
        .get("customCoverUrl")
        .and_then(|v| v.as_str())
        .map(String::from);
    let intro = legado.get("intro").and_then(|v| v.as_str()).map(String::from);
    let latest_chapter_title = legado
        .get("latestChapterTitle")
        .and_then(|v| v.as_str())
        .map(String::from);

    let latest_chapter_time =
        legado.get("latestChapterTime").and_then(|v| v.as_i64()).unwrap_or(0);
    let last_check_time = legado.get("lastCheckTime").and_then(|v| v.as_i64()).unwrap_or(0);
    let last_check_count = legado
        .get("lastCheckCount")
        .and_then(|v| v.as_i64())
        .unwrap_or(0) as i32;
    let total_chapter_num = legado
        .get("totalChapterNum")
        .and_then(|v| v.as_i64())
        .unwrap_or(0) as i32;

    let dur_chapter_index = legado
        .get("durChapterIndex")
        .and_then(|v| v.as_i64())
        .unwrap_or(0) as i32;
    let dur_chapter_pos = legado
        .get("durChapterPos")
        .and_then(|v| v.as_i64())
        .unwrap_or(0) as i32;
    let dur_chapter_title = legado
        .get("durChapterTitle")
        .and_then(|v| v.as_str())
        .map(String::from);
    let dur_chapter_time = legado.get("durChapterTime").and_then(|v| v.as_i64()).unwrap_or(0);

    // wordCount: 原 String → i32
    let word_count_str = legado
        .get("wordCount")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let total_word_count = parse_word_count(word_count_str);

    let can_update = legado
        .get("canUpdate")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);

    // group bitmask → group_id
    let group_bitmask = legado.get("group").and_then(|v| v.as_i64()).unwrap_or(0);
    let group_id = legado_group_bitmask_to_id(group_bitmask);

    // origin URL → source_id UUID（lookup；找不到保留原 URL）
    let source_id = sources_url_to_id
        .get(&origin)
        .cloned()
        .unwrap_or_else(|| origin.clone());

    // 缺失字段打包到 custom_info_json
    let mut leftover = json!({});
    let leftover_obj = leftover.as_object_mut().unwrap();
    for key in [
        "type",
        "customTag",
        "customIntro",
        "charset",
        "originOrder",
        "variable",
        "readConfig",
        "syncTime",
    ] {
        if let Some(v) = legado.get(key) {
            leftover_obj.insert(key.to_string(), v.clone());
        }
    }
    if group_bitmask != 0 {
        leftover_obj.insert("originalGroupBitmask".to_string(), json!(group_bitmask));
    }
    let custom_info_json = if leftover_obj.is_empty() {
        None
    } else {
        Some(json!({"_legado_backup": leftover}).to_string())
    };

    Ok(Book {
        id: Uuid::new_v4().to_string(),
        source_id,
        source_name: origin_name,
        name,
        author,
        cover_url,
        chapter_count: total_chapter_num,
        latest_chapter_title,
        intro,
        kind,
        book_url,
        toc_url,
        last_check_time: if last_check_time == 0 {
            None
        } else {
            Some(ms_to_seconds_smart(last_check_time))
        },
        last_check_count,
        total_word_count,
        can_update,
        order_time: ms_to_seconds_smart(
            legado.get("order").and_then(|v| v.as_i64()).unwrap_or(now),
        ),
        latest_chapter_time: if latest_chapter_time == 0 {
            None
        } else {
            Some(ms_to_seconds_smart(latest_chapter_time))
        },
        custom_cover_path: custom_cover_url,
        custom_info_json,
        dur_chapter_index,
        dur_chapter_pos,
        dur_chapter_title,
        dur_chapter_time: ms_to_seconds_smart(dur_chapter_time),
        group_id,
        created_at: now,
        updated_at: now,
    })
}

// ============================================================
// BookGroup 映射
// ============================================================

/// Legado `BookGroup` JSON → `models::BookGroup`
///
/// 注意：`groupId` 是 bitmask，转换后的 id 直接复用 [`legado_group_bitmask_to_id`]
/// 的结果。这样原 Legado 的 `Book.group` bitmask 通过同一函数映射后，
/// 和这里产出的 BookGroup.id 能对得上。
pub fn legado_group_to_storage_group(legado: &Value) -> Result<BookGroup, String> {
    let now = Utc::now().timestamp();
    let group_id_bitmask = legado.get("groupId").and_then(|v| v.as_i64()).unwrap_or(0);
    let id = legado_group_bitmask_to_id(group_id_bitmask);
    if id == 0 {
        return Err(format!(
            "无效或系统保留的 groupId: {} (跳过)",
            group_id_bitmask
        ));
    }
    let name = legado
        .get("groupName")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Legado BookGroup 缺少 groupName".to_string())?
        .to_string();
    let cover = legado.get("cover").and_then(|v| v.as_str()).map(String::from);
    let order = legado.get("order").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
    let show = legado.get("show").and_then(|v| v.as_bool()).unwrap_or(true);
    let book_sort = legado.get("bookSort").and_then(|v| v.as_i64()).unwrap_or(0) as i32;

    Ok(BookGroup {
        id,
        name,
        sort_order: order,
        cover,
        show,
        book_sort,
        created_at: now,
        updated_at: now,
    })
}

// ============================================================
// Bookmark 映射
// ============================================================

/// Legado `Bookmark` JSON → `models::Bookmark`
///
/// 原 Legado 主键 = `time`（毫秒）；本端口主键 = UUID。
/// `book_id` 通过 `(bookName, bookAuthor)` 在 `books_url_to_id` 中查
/// 找；找不到时仍生成 Bookmark（书签悬空）但记 warning 给 caller。
///
/// `books_url_to_id` 这里用 "name|author" 拼字符串作 key（区分大小
/// 写）。bookmark `bookText` / `chapterPos` 等字段已经在批次 6 schema 加好。
pub fn legado_bookmark_to_storage_bookmark(
    legado: &Value,
    books_name_author_to_id: &HashMap<String, String>,
) -> Result<Bookmark, String> {
    let now = Utc::now().timestamp();
    let book_name = legado
        .get("bookName")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Legado Bookmark 缺少 bookName".to_string())?
        .to_string();
    let book_author = legado
        .get("bookAuthor")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let key = format!("{}|{}", book_name, book_author);
    // 找不到对应的书 → 用空 book_id 占位（原 Legado 的书签也是软关联）
    let book_id = books_name_author_to_id
        .get(&key)
        .cloned()
        .unwrap_or_default();

    let chapter_index = legado
        .get("chapterIndex")
        .and_then(|v| v.as_i64())
        .unwrap_or(0) as i32;
    let chapter_pos = legado
        .get("chapterPos")
        .and_then(|v| v.as_i64())
        .unwrap_or(0) as i32;
    let chapter_name = legado
        .get("chapterName")
        .and_then(|v| v.as_str())
        .map(String::from);
    let book_text = legado
        .get("bookText")
        .and_then(|v| v.as_str())
        .map(String::from);
    let content = legado
        .get("content")
        .and_then(|v| v.as_str())
        .map(String::from);
    let time = legado.get("time").and_then(|v| v.as_i64()).unwrap_or(now * 1000);
    let created_at = ms_to_seconds_smart(time);

    Ok(Bookmark {
        id: Uuid::new_v4().to_string(),
        book_id,
        chapter_index,
        // 原 Legado bookmark 没有 paragraph_index 字段，本端口用 0 占位。
        paragraph_index: 0,
        content,
        book_name: Some(book_name),
        book_author: if book_author.is_empty() {
            None
        } else {
            Some(book_author)
        },
        chapter_pos,
        chapter_name,
        book_text,
        created_at,
    })
}

// ============================================================
// ReplaceRule 映射
// ============================================================

/// Legado `ReplaceRule` JSON → `models::ReplaceRule`
///
/// 字段名差异：
/// - `isEnabled` → `enabled`
/// - `order` → `sort_number`
/// - `isRegex` 在本端口缺失（默认全部当正则；非正则字符串会被当
///   regex 字面量处理，多数情况兼容）
/// - `timeoutMillisecond` 在本端口缺失，丢弃
pub fn legado_replace_rule_to_storage(legado: &Value) -> Result<ReplaceRule, String> {
    let now = Utc::now().timestamp();
    let name = legado
        .get("name")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Legado ReplaceRule 缺少 name".to_string())?
        .to_string();
    let pattern = legado
        .get("pattern")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let replacement = legado
        .get("replacement")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let enabled = legado
        .get("isEnabled")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);
    let scope = legado.get("scope").and_then(|v| v.as_str()).map(String::from);
    let scope_title = legado
        .get("scopeTitle")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let scope_content = legado
        .get("scopeContent")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);
    let exclude_scope = legado
        .get("excludeScope")
        .and_then(|v| v.as_str())
        .map(String::from);
    let sort_number = legado.get("order").and_then(|v| v.as_i64()).unwrap_or(0) as i32;

    Ok(ReplaceRule {
        id: Uuid::new_v4().to_string(),
        name,
        pattern,
        replacement,
        enabled,
        scope,
        scope_title,
        scope_content,
        exclude_scope,
        sort_number,
        created_at: now,
        updated_at: now,
    })
}

// ============================================================
// BookSource 映射（最小子集，复用 source_dao 的 import_from_json 逻辑）
// ============================================================

/// Legado `BookSource` JSON → `models::BookSource`
///
/// **复用约定**：本函数负责"独立 1 条 Legado JSON Object → BookSource"
/// 转换。`source_dao::import_from_json` 现有的 LegadoBookSource 反序列化器
/// 已经覆盖了 26+ 字段映射 + 嵌套规则 normalize_rule_keys。这里改成
/// 把单条 Object 包成 1 元素数组，复用 `import_from_json`?
/// — 不行，import_from_json 直接写 DB，无法拿到 BookSource struct。
///
/// 于是：本函数走最小字段映射（id/name/url/source_type/group_name/
/// enabled/custom_order/weight/header/login_url/login_ui/login_check_js/
/// js_lib/cover_decode_js/explore_url/book_url_pattern/enabled_explore/
/// last_update_time/book_source_comment/concurrent_rate/variable_comment/
/// explore_screen + 5 个 rule_xxx 嵌套对象 stringify），剩下的依赖
/// `import_from_json` 路径（导入 zip 时另起 DAO 调用）。这里只是为
/// `validate_zip` 之类的 dry-run 提供一个 pure 转换。
pub fn legado_source_to_storage_source(legado: &Value) -> Result<BookSource, String> {
    let now = Utc::now().timestamp();
    let url = legado
        .get("bookSourceUrl")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Legado BookSource 缺少 bookSourceUrl".to_string())?
        .to_string();
    let name = legado
        .get("bookSourceName")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let source_type = legado
        .get("bookSourceType")
        .and_then(|v| v.as_i64())
        .unwrap_or(0) as i32;
    let group_name = legado
        .get("bookSourceGroup")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(String::from);
    let enabled = legado.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
    let custom_order = legado
        .get("customOrder")
        .and_then(|v| v.as_i64())
        .unwrap_or(0) as i32;
    let weight = legado.get("weight").and_then(|v| v.as_i64()).unwrap_or(0) as i32;

    // 5 个 rule 嵌套对象 → JSON 字符串（如果是字符串就直接用；如果是 Object 就 to_string）
    let stringify_rule = |key: &str| -> Option<String> {
        legado.get(key).and_then(|v| match v {
            Value::Null => None,
            Value::String(s) if s.is_empty() => None,
            Value::String(s) => Some(s.clone()),
            other => Some(other.to_string()),
        })
    };

    let rule_search = stringify_rule("ruleSearch");
    let rule_book_info = stringify_rule("ruleBookInfo");
    let rule_toc = stringify_rule("ruleToc");
    let rule_content = stringify_rule("ruleContent");
    let rule_explore = stringify_rule("ruleExplore");

    let header = legado.get("header").and_then(|v| match v {
        Value::String(s) => Some(s.clone()),
        Value::Null => None,
        other => Some(other.to_string()),
    });

    Ok(BookSource {
        id: Uuid::new_v4().to_string(),
        name,
        url,
        source_type,
        group_name,
        enabled,
        custom_order,
        weight,
        rule_search,
        rule_book_info,
        rule_toc,
        rule_content,
        login_url: legado
            .get("loginUrl")
            .and_then(|v| v.as_str())
            .map(String::from),
        login_ui: legado
            .get("loginUi")
            .and_then(|v| v.as_str())
            .map(String::from),
        login_check_js: legado
            .get("loginCheckJs")
            .and_then(|v| v.as_str())
            .map(String::from),
        header,
        js_lib: legado.get("jsLib").and_then(|v| v.as_str()).map(String::from),
        cover_decode_js: legado
            .get("coverDecodeJs")
            .and_then(|v| v.as_str())
            .map(String::from),
        book_url_pattern: legado
            .get("bookUrlPattern")
            .and_then(|v| v.as_str())
            .map(String::from),
        rule_explore,
        explore_url: legado
            .get("exploreUrl")
            .and_then(|v| v.as_str())
            .map(String::from),
        enabled_explore: legado
            .get("enabledExplore")
            .and_then(|v| v.as_bool())
            .unwrap_or(true),
        last_update_time: legado
            .get("lastUpdateTime")
            .and_then(|v| v.as_i64())
            .unwrap_or(0),
        book_source_comment: legado
            .get("bookSourceComment")
            .and_then(|v| v.as_str())
            .map(String::from),
        concurrent_rate: legado
            .get("concurrentRate")
            .and_then(|v| v.as_str())
            .map(String::from),
        variable_comment: legado
            .get("variableComment")
            .and_then(|v| v.as_str())
            .map(String::from),
        explore_screen: legado
            .get("exploreScreen")
            .and_then(|v| v.as_i64())
            .map(|n| n as i32),
        respond_time: 0,
        last_check_error: None,
        last_check_at: 0,
        created_at: now,
        updated_at: now,
    })
}

// ============================================================
// 导出方向：本端口 → Legado JSON
// ============================================================

/// 本端口 `Book` → Legado 备份 JSON。
/// 反向转换尽量保持原 Legado 字段齐全，缺失字段从 `custom_info_json._legado_backup`
/// 中恢复（如果当初是从 Legado 导入的）。
pub fn storage_book_to_legado_json(
    book: &Book,
    sources_id_to_url: &HashMap<String, String>,
) -> Value {
    // 读出 _legado_backup 子对象（如果有）
    let leftover: Value = book
        .custom_info_json
        .as_deref()
        .and_then(|s| serde_json::from_str::<Value>(s).ok())
        .and_then(|mut v| v.get_mut("_legado_backup").map(|x| x.take()))
        .unwrap_or(Value::Null);

    let get_leftover = |key: &str| leftover.get(key).cloned().unwrap_or(Value::Null);

    // origin: source_id UUID → URL（如果是 UUID lookup）；否则原样
    let origin = sources_id_to_url
        .get(&book.source_id)
        .cloned()
        .unwrap_or_else(|| book.source_id.clone());

    // 反向 group_id → bitmask（单分组只 set 一位）
    let group_bitmask = if book.group_id == 0 {
        // 如果备份里有原始 bitmask 就用回原始的，避免 1 本归多分组的丢失
        leftover
            .get("originalGroupBitmask")
            .and_then(|v| v.as_i64())
            .unwrap_or(0)
    } else if book.group_id >= 1 {
        1i64 << (book.group_id - 1).max(0)
    } else {
        0
    };

    json!({
        "bookUrl": book.book_url.clone().unwrap_or_default(),
        "tocUrl": book.toc_url.clone().unwrap_or_default(),
        "origin": origin,
        "originName": book.source_name.clone().unwrap_or_default(),
        "name": book.name,
        "author": book.author.clone().unwrap_or_default(),
        "kind": book.kind,
        "customTag": get_leftover("customTag"),
        "coverUrl": book.cover_url,
        "customCoverUrl": book.custom_cover_path,
        "intro": book.intro,
        "customIntro": get_leftover("customIntro"),
        "charset": get_leftover("charset"),
        "type": get_leftover("type"),
        "group": group_bitmask,
        "latestChapterTitle": book.latest_chapter_title,
        "latestChapterTime": book.latest_chapter_time.unwrap_or(0) * 1000,
        "lastCheckTime": book.last_check_time.unwrap_or(0) * 1000,
        "lastCheckCount": book.last_check_count,
        "totalChapterNum": book.chapter_count,
        "durChapterTitle": book.dur_chapter_title,
        "durChapterIndex": book.dur_chapter_index,
        "durChapterPos": book.dur_chapter_pos,
        "durChapterTime": book.dur_chapter_time * 1000,
        // 反向 i32 → "12345" 字符串（不带后缀，简化）
        "wordCount": book.total_word_count.to_string(),
        "canUpdate": book.can_update,
        "order": book.order_time,
        "originOrder": get_leftover("originOrder"),
        "variable": get_leftover("variable"),
        "readConfig": get_leftover("readConfig"),
        "syncTime": get_leftover("syncTime"),
    })
}

/// 本端口 `BookGroup` → Legado JSON。`id` (1..) → bitmask `1 << (id-1)`
pub fn storage_group_to_legado_json(group: &BookGroup) -> Value {
    let bitmask = if group.id >= 1 {
        1i64 << (group.id - 1).max(0)
    } else {
        0
    };
    json!({
        "groupId": bitmask,
        "groupName": group.name,
        "cover": group.cover,
        "order": group.sort_order,
        "enableRefresh": true,
        "show": group.show,
        "bookSort": group.book_sort,
    })
}

/// 本端口 `Bookmark` → Legado JSON
pub fn storage_bookmark_to_legado_json(bm: &Bookmark) -> Value {
    json!({
        // 原 Legado 用毫秒时间戳作 PK，这里把 created_at (秒) ×1000 还原
        "time": bm.created_at * 1000,
        "bookName": bm.book_name.clone().unwrap_or_default(),
        "bookAuthor": bm.book_author.clone().unwrap_or_default(),
        "chapterIndex": bm.chapter_index,
        "chapterPos": bm.chapter_pos,
        "chapterName": bm.chapter_name.clone().unwrap_or_default(),
        "bookText": bm.book_text.clone().unwrap_or_default(),
        "content": bm.content.clone().unwrap_or_default(),
    })
}

/// 本端口 `ReplaceRule` → Legado JSON
///
/// 批次 08 (BATCH-08 / F-W1A-054)：Legado 端 `ReplaceRule.id` PK 是 i64
/// 毫秒时间戳；本端口真实主键是 `String` UUID。导出时把 `created_at *
/// 1000` 当 PK 高位，并在低 16 位塞 `id` UUID 的 hash 做抖动，避免同
/// 1ms 创建的多条规则导出后 PK 冲突 → 原 Legado 端导入触发 UNIQUE 违
/// 反。极端情况下 hash 冲突仍可能（65536 内同 ms 多条；概率极低，可接
/// 受），不影响 Round-trip 端口侧（端口侧主键仍是 UUID）。
pub fn storage_replace_rule_to_legado_json(r: &ReplaceRule) -> Value {
    let pk = r.created_at * 1000 + (hash_id_u16(&r.id) as i64);
    json!({
        "id": pk,
        "name": r.name,
        "group": "",
        "pattern": r.pattern,
        "replacement": r.replacement,
        "scope": r.scope.clone().unwrap_or_default(),
        "scopeTitle": r.scope_title,
        "scopeContent": r.scope_content,
        "excludeScope": r.exclude_scope,
        "isEnabled": r.enabled,
        "isRegex": true,
        "timeoutMillisecond": 3000,
        "order": r.sort_number,
    })
}

/// 把 UUID 字符串 hash 到 u16，作为 Legado PK 的低 16 位抖动。
/// 用 `std::collections::hash_map::DefaultHasher`（无外部 dep），最低
/// 16 bit cast 即可。
fn hash_id_u16(id: &str) -> u16 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    id.hash(&mut h);
    h.finish() as u16
}

/// 本端口 `BookSource` → Legado JSON（最小集，与 source_dao::export_legado_json
/// 结构兼容）
pub fn storage_source_to_legado_json(s: &BookSource) -> Value {
    let parse_rule = |opt: &Option<String>| -> Value {
        opt.as_deref()
            .and_then(|t| serde_json::from_str::<Value>(t).ok())
            .unwrap_or(Value::Null)
    };
    json!({
        "bookSourceUrl": s.url,
        "bookSourceName": s.name,
        "bookSourceGroup": s.group_name.clone().unwrap_or_default(),
        "bookSourceType": s.source_type,
        "bookSourceComment": s.book_source_comment.clone().unwrap_or_default(),
        "bookUrlPattern": s.book_url_pattern.clone().unwrap_or_default(),
        "concurrentRate": s.concurrent_rate.clone().unwrap_or_default(),
        "customOrder": s.custom_order,
        "enabled": s.enabled,
        "enabledExplore": s.enabled_explore,
        "weight": s.weight,
        "lastUpdateTime": s.last_update_time,
        "header": s.header.clone().unwrap_or_default(),
        "loginUrl": s.login_url.clone().unwrap_or_default(),
        "loginUi": s.login_ui,
        "loginCheckJs": s.login_check_js,
        "jsLib": s.js_lib.clone().unwrap_or_default(),
        "coverDecodeJs": s.cover_decode_js,
        "exploreUrl": s.explore_url.clone().unwrap_or_default(),
        "ruleSearch": parse_rule(&s.rule_search),
        "ruleBookInfo": parse_rule(&s.rule_book_info),
        "ruleToc": parse_rule(&s.rule_toc),
        "ruleContent": parse_rule(&s.rule_content),
        "ruleExplore": parse_rule(&s.rule_explore),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_word_count_handles_k_m_chinese() {
        assert_eq!(parse_word_count(""), 0);
        assert_eq!(parse_word_count("8523"), 8523);
        assert_eq!(parse_word_count("120K"), 120_000);
        assert_eq!(parse_word_count("120k"), 120_000);
        assert_eq!(parse_word_count("5.2M"), 5_200_000);
        assert_eq!(parse_word_count("5.2m"), 5_200_000);
        assert_eq!(parse_word_count("10万"), 100_000);
        assert_eq!(parse_word_count("3亿"), 300_000_000);
        // 异常输入回 0，不 panic
        assert_eq!(parse_word_count("abc"), 0);
        assert_eq!(parse_word_count("M"), 0);
        assert_eq!(parse_word_count("  "), 0);
    }

    #[test]
    fn test_legado_group_bitmask_to_id() {
        // 单 bit
        assert_eq!(legado_group_bitmask_to_id(0), 0);
        assert_eq!(legado_group_bitmask_to_id(1), 1);
        assert_eq!(legado_group_bitmask_to_id(2), 2);
        assert_eq!(legado_group_bitmask_to_id(4), 3);
        assert_eq!(legado_group_bitmask_to_id(8), 4);
        assert_eq!(legado_group_bitmask_to_id(16), 5);
        // 多 bit 取最低位
        assert_eq!(legado_group_bitmask_to_id(3), 1); // 1 + 2
        assert_eq!(legado_group_bitmask_to_id(5), 1); // 1 + 4
        assert_eq!(legado_group_bitmask_to_id(6), 2); // 2 + 4
        assert_eq!(legado_group_bitmask_to_id(7), 1); // 1 + 2 + 4
        // 系统保留负数
        assert_eq!(legado_group_bitmask_to_id(-1), 0);
        assert_eq!(legado_group_bitmask_to_id(-100), 0);
    }

    #[test]
    fn test_ms_to_seconds_smart() {
        assert_eq!(ms_to_seconds_smart(0), 0);
        // 已经是秒（< 1e10），原样返回
        assert_eq!(ms_to_seconds_smart(1_700_000_000), 1_700_000_000);
        // 是毫秒（> 1e10），/ 1000
        assert_eq!(ms_to_seconds_smart(1_700_000_000_000), 1_700_000_000);
        // 边界
        assert_eq!(ms_to_seconds_smart(10_000_000_000), 10_000_000_000); // 等于阈值不转
    }

    #[test]
    fn test_legado_book_to_storage_book_basic() {
        let mut sources = HashMap::new();
        sources.insert("https://example.com".to_string(), "src-uuid-1".to_string());

        let legado = json!({
            "bookUrl": "https://example.com/book/1",
            "tocUrl": "https://example.com/book/1/toc",
            "origin": "https://example.com",
            "originName": "示例书源",
            "name": "斗破苍穹",
            "author": "天蚕土豆",
            "kind": "玄幻",
            "coverUrl": "https://example.com/cover.jpg",
            "intro": "...",
            "type": 0,
            "group": 4,  // bitmask → group_id 3
            "latestChapterTitle": "第1641章 大结局",
            "latestChapterTime": 1_731_234_567_890_i64,  // ms
            "totalChapterNum": 1641,
            "durChapterIndex": 99,
            "durChapterPos": 0,
            "durChapterTime": 1_731_234_567_890_i64,
            "wordCount": "5.2M",
            "canUpdate": true,
        });

        let book = legado_book_to_storage_book(&legado, &sources).unwrap();
        assert_eq!(book.name, "斗破苍穹");
        assert_eq!(book.author.as_deref(), Some("天蚕土豆"));
        assert_eq!(book.source_id, "src-uuid-1");
        assert_eq!(book.group_id, 3);
        assert_eq!(book.total_word_count, 5_200_000);
        assert_eq!(book.dur_chapter_index, 99);
        // 1731234567890 ms → 1731234567 s
        assert_eq!(book.latest_chapter_time, Some(1_731_234_567));
        assert_eq!(book.dur_chapter_time, 1_731_234_567);
        assert_eq!(book.chapter_count, 1641);
        // 缺失字段塞进 custom_info_json
        let cij = book.custom_info_json.unwrap();
        assert!(cij.contains("_legado_backup"));
        assert!(cij.contains("\"type\":0"));
        assert!(cij.contains("\"originalGroupBitmask\":4"));
    }

    #[test]
    fn test_legado_book_origin_url_not_in_sources_table() {
        let sources: HashMap<String, String> = HashMap::new(); // 空表
        let legado = json!({
            "name": "孤儿书",
            "origin": "https://unknown-source.com",
            "wordCount": "10万",
        });
        let book = legado_book_to_storage_book(&legado, &sources).unwrap();
        // 找不到时保留原 URL
        assert_eq!(book.source_id, "https://unknown-source.com");
        assert_eq!(book.total_word_count, 100_000);
    }

    #[test]
    fn test_legado_group_to_storage_group_basic() {
        let legado = json!({
            "groupId": 4,
            "groupName": "玄幻",
            "order": 2,
            "show": true,
            "bookSort": -1,
        });
        let g = legado_group_to_storage_group(&legado).unwrap();
        assert_eq!(g.id, 3);
        assert_eq!(g.name, "玄幻");
        assert_eq!(g.sort_order, 2);
        assert!(g.show);
    }

    #[test]
    fn test_legado_replace_rule_basic() {
        let legado = json!({
            "name": "去广告",
            "pattern": "广告.*?$",
            "replacement": "",
            "isEnabled": true,
            "scopeTitle": false,
            "scopeContent": true,
            "order": 5,
            "scope": "示例书源",
        });
        let r = legado_replace_rule_to_storage(&legado).unwrap();
        assert_eq!(r.name, "去广告");
        assert_eq!(r.sort_number, 5);
        assert!(r.enabled);
        assert!(r.scope_content);
        assert_eq!(r.scope.as_deref(), Some("示例书源"));
    }

    #[test]
    fn test_storage_book_to_legado_roundtrip_keeps_basic_fields() {
        let mut id_to_url = HashMap::new();
        id_to_url.insert("src-uuid-1".to_string(), "https://example.com".to_string());

        let book = Book {
            id: "b1".into(),
            source_id: "src-uuid-1".into(),
            source_name: Some("示例书源".into()),
            name: "斗破苍穹".into(),
            author: Some("天蚕土豆".into()),
            cover_url: None,
            chapter_count: 1641,
            latest_chapter_title: Some("第1641章".into()),
            intro: None,
            kind: Some("玄幻".into()),
            book_url: Some("https://example.com/book/1".into()),
            toc_url: None,
            last_check_time: Some(1_700_000_000),
            last_check_count: 0,
            total_word_count: 5_200_000,
            can_update: true,
            order_time: 1_700_000_000,
            latest_chapter_time: Some(1_700_000_000),
            custom_cover_path: None,
            custom_info_json: None,
            dur_chapter_index: 99,
            dur_chapter_pos: 0,
            dur_chapter_title: None,
            dur_chapter_time: 1_700_000_000,
            group_id: 3,
            created_at: 1_700_000_000,
            updated_at: 1_700_000_000,
        };
        let json = storage_book_to_legado_json(&book, &id_to_url);
        assert_eq!(json["name"], "斗破苍穹");
        assert_eq!(json["origin"], "https://example.com");
        assert_eq!(json["totalChapterNum"], 1641);
        // group_id=3 → bitmask 1<<2 = 4
        assert_eq!(json["group"], 4);
        // 时间戳应该再 ×1000 还原成 ms
        assert_eq!(json["latestChapterTime"], 1_700_000_000_000_i64);
    }

    fn make_replace_rule(id: &str, created_at: i64) -> ReplaceRule {
        ReplaceRule {
            id: id.into(),
            name: format!("rule-{id}"),
            pattern: ".*".into(),
            replacement: "".into(),
            enabled: true,
            scope: None,
            scope_title: false,
            scope_content: true,
            exclude_scope: None,
            sort_number: 0,
            created_at,
            updated_at: created_at,
        }
    }

    /// 批次 08 (BATCH-08 / F-W1A-054): 同 `created_at` 但不同 `id` 的两条
    /// 规则导出后 `id` PK 字段不能冲突 — 否则原 Legado 端导入触发 UNIQUE
    /// 违反。低 16 位用 UUID hash 抖动后，同 ms 多条概率冲突 < 1/65536。
    #[test]
    fn storage_replace_rule_to_legado_pk_jitter_avoids_same_ms_collision() {
        let r1 = make_replace_rule("aaaaaaaa-1111-2222-3333-444444444444", 1_700_000_000);
        let r2 = make_replace_rule("bbbbbbbb-5555-6666-7777-888888888888", 1_700_000_000);
        let j1 = storage_replace_rule_to_legado_json(&r1);
        let j2 = storage_replace_rule_to_legado_json(&r2);
        let id1 = j1["id"].as_i64().expect("id1 should be i64");
        let id2 = j2["id"].as_i64().expect("id2 should be i64");
        assert_ne!(id1, id2, "same created_at but different UUIDs must produce different PKs");
        // 两个 PK 都应该在 created_at*1000 附近（同一 ms 高位）
        let base = 1_700_000_000_i64 * 1000;
        assert!(id1 >= base && id1 < base + 0x1_0000);
        assert!(id2 >= base && id2 < base + 0x1_0000);
    }

    /// 同一 id 多次导出应保持 PK 稳定（纯函数性 — 不依赖随机 / 时间）。
    #[test]
    fn storage_replace_rule_to_legado_pk_is_stable_for_same_id() {
        let r = make_replace_rule("c0ffee00-cafe-1234-5678-9abcdef01234", 1_700_000_000);
        let id1 = storage_replace_rule_to_legado_json(&r)["id"]
            .as_i64()
            .unwrap();
        let id2 = storage_replace_rule_to_legado_json(&r)["id"]
            .as_i64()
            .unwrap();
        assert_eq!(id1, id2, "same input must produce same PK");
    }
}
