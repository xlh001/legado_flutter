//! Build-time guard for the hand-edited `frb_generated.rs`.
//!
//! `flutter_rust_bridge_codegen generate` has timed out repeatedly on this
//! repo (300s/600s, see CURRENT_STATUS.md FRB patch chapter), so a number of
//! wire functions were added by hand. If a future contributor re-runs the
//! codegen they will silently overwrite those patches and the runtime
//! dispatcher will hit `unreachable!()` when Dart calls one of the missing
//! funcIds.
//!
//! This script runs at compile time and fails the build if any of the
//! known-manual wire impls disappears from `src/frb_generated.rs`. It is
//! intentionally string-matching (not a real Rust parser) so it stays cheap
//! and survives codegen-format churn.
//!
//! **R3** (commit 15): the script also cross-checks the Rust dispatcher's
//! funcId table against the Dart side (`flutter_app/lib/src/rust/frb_generated.dart`).
//! If Dart calls a funcId that Rust doesn't dispatch, the build fails (the
//! runtime would otherwise hit `unreachable!()` mid-request and surface as
//! an unresponsive Flutter call). Rust having extra funcIds that Dart
//! never calls only triggers a warning — that pattern fits "wire fn
//! added but caller not yet wired up".

use std::fs;
use std::path::PathBuf;

const REQUIRED_WIRE_FN_FRAGMENTS: &[&str] = &[
    // funcId 42 — validate_source_rules
    "wire__crate__api__validate_source_rules_impl",
    // funcId 43 — validate_source_from_db
    "wire__crate__api__validate_source_from_db_impl",
    // funcId 44 — export_all_sources
    "wire__crate__api__export_all_sources_impl",
    // funcId 45 — get_replace_rules
    "wire__crate__api__get_replace_rules_impl",
    // funcId 46 — save_replace_rule
    "wire__crate__api__save_replace_rule_impl",
    // funcId 47 — delete_replace_rule
    "wire__crate__api__delete_replace_rule_impl",
    // funcId 48 — set_replace_rule_enabled
    "wire__crate__api__set_replace_rule_enabled_impl",
    // funcId 49 — replace_book_chapters_preserving_content
    "wire__crate__api__replace_book_chapters_preserving_content_impl",
    // funcId 50 — replace_book_chapters
    "wire__crate__api__replace_book_chapters_impl",
    // funcId 51 — diagnostic for raw rule_search JSON
    "wire__crate__api__get_source_rule_search_raw_impl",
    // funcId 52 — search_with_source_from_db v2 wrapper
    "wire__crate__api__search_with_source_from_db_v2_impl",
    // funcId 54 — batch source deletion
    "wire__crate__api__delete_sources_batch_impl",
    // funcIds 55 / 56 (originally explore entries / page fetch) — DELETED in
    // BATCH-07a. The two wire fns and their dispatcher arms were removed
    // along with the underlying `pub fn explore` / `get_explore_entries` in
    // bridge/src/api.rs (zero Flutter-side consumers, see batch PRD). Do
    // not re-introduce these guards.
    // funcId 57 — apply_replace_rules (P1-7)
    "wire__crate__api__apply_replace_rules_impl",
    // 批次 10 — funcId 63 — export_backup_zip
    "wire__crate__api__export_backup_zip_impl",
    // 批次 10 — funcId 64 — import_backup_zip
    "wire__crate__api__import_backup_zip_impl",
    // 批次 10 — funcId 65 — validate_backup_zip
    "wire__crate__api__validate_backup_zip_impl",
    // 批次 11 — funcId 66 — webdav_check
    "wire__crate__api__webdav_check_impl",
    // 批次 11 — funcId 67 — webdav_list_backups
    "wire__crate__api__webdav_list_backups_impl",
    // 批次 11 — funcId 68 — webdav_upload_backup
    "wire__crate__api__webdav_upload_backup_impl",
    // 批次 11 — funcId 69 — webdav_download_backup
    "wire__crate__api__webdav_download_backup_impl",
    // 批次 11 — funcId 70 — webdav_delete_backup
    "wire__crate__api__webdav_delete_backup_impl",
    // 批次 12 — funcId 71 — set_backup_password
    "wire__crate__api__set_backup_password_impl",
    // 批次 12 — funcId 72 — get_backup_password
    "wire__crate__api__get_backup_password_impl",
    // 批次 13 — funcId 73 — import_local_book
    "wire__crate__api__import_local_book_impl",
    // 批次 14 — funcId 74 — add_read_time
    "wire__crate__api__add_read_time_impl",
    // 批次 14 — funcId 75 — get_read_record
    "wire__crate__api__get_read_record_impl",
    // 批次 14 — funcId 76 — list_read_records
    "wire__crate__api__list_read_records_impl",
    // 批次 14 — funcId 77 — get_total_read_time
    "wire__crate__api__get_total_read_time_impl",
    // 批次 15 — funcId 78 — count_cached_chapters_for_book
    "wire__crate__api__count_cached_chapters_for_book_impl",
    // 批次 15 — funcId 79 — list_books_with_cache_stats
    "wire__crate__api__list_books_with_cache_stats_impl",
    // 批次 15 — funcId 80 — clear_book_cache
    "wire__crate__api__clear_book_cache_impl",
    // 批次 15 — funcId 81 — clear_all_cache
    "wire__crate__api__clear_all_cache_impl",
    // 批次 16 (RSS 源管理 schema v12) — 9 个 wire fn (funcId 82-90)
    "wire__crate__api__rss_source_list_all_impl",
    "wire__crate__api__rss_source_list_enabled_impl",
    "wire__crate__api__rss_source_list_by_group_impl",
    "wire__crate__api__rss_source_list_groups_impl",
    "wire__crate__api__rss_source_get_impl",
    "wire__crate__api__rss_source_upsert_impl",
    "wire__crate__api__rss_source_set_enabled_impl",
    "wire__crate__api__rss_source_delete_impl",
    "wire__crate__api__rss_source_import_json_impl",
    // 批次 17 (RSS 拉取 + 文章列表) — 6 个 wire fn (funcId 91-96)
    "wire__crate__api__rss_get_articles_impl",
    "wire__crate__api__rss_list_articles_impl",
    "wire__crate__api__rss_mark_read_impl",
    "wire__crate__api__rss_count_unread_impl",
    "wire__crate__api__rss_delete_articles_by_source_impl",
    "wire__crate__api__rss_get_sort_tabs_impl",
    // 批次 18 (RSS 详情 + 收藏) — 5 个 wire fn (funcId 97-101)
    "wire__crate__api__rss_fetch_article_content_impl",
    "wire__crate__api__rss_star_add_impl",
    "wire__crate__api__rss_star_remove_impl",
    "wire__crate__api__rss_star_is_starred_impl",
    "wire__crate__api__rss_star_list_impl",
    // 批次 19 (订阅源 RuleSub MVP) — 7 个 wire fn (funcId 102-108)
    "wire__crate__api__rule_sub_list_all_impl",
    "wire__crate__api__rule_sub_create_impl",
    "wire__crate__api__rule_sub_update_impl",
    "wire__crate__api__rule_sub_delete_impl",
    "wire__crate__api__rule_sub_refresh_impl",
    "wire__crate__api__rule_sub_refresh_all_impl",
    "wire__crate__api__rule_sub_get_impl",
    // 批次 21 (书源实跑验证 LiveTest) — 1 个 wire fn (funcId 109)
    "wire__crate__api__validate_source_live_impl",
    // 批次 22 (RSS detail FRB 桥) — 1 个 wire fn (funcId 110)
    "wire__crate__api__rss_article_get_by_origin_link_impl",
    // BATCH-27a (bookshelf 导出 JSON) — 1 个 wire fn (funcId 111)
    "wire__crate__api__export_bookshelf_json_impl",
    // BATCH-27b (单本目录刷新) — 1 个 wire fn (funcId 112)
    "wire__crate__api__update_book_toc_impl",
    // BATCH-27c (webdav 通用 list_dir / download_file) — 2 个 wire fn (funcId 113-114)
    "wire__crate__api__webdav_list_dir_impl",
    "wire__crate__api__webdav_download_file_impl",
    // BATCH-27d (书架批量编辑) — 2 个 wire fn (funcId 115, 117)；clear cache
    // 复用 26a funcId 80 的 clear_book_cache。
    "wire__crate__api__set_book_can_update_impl",
    "wire__crate__api__delete_book_with_file_impl",
    // BATCH-27e (add_url URL→源 pattern matching) — 1 个 wire fn (funcId 118)
    "wire__crate__api__find_book_source_for_url_impl",
    // 批次 check-sources (05-24) — 1 个 wire fn (funcId 119)
    "wire__crate__api__batch_check_sources_impl",
];

const REQUIRED_DISPATCHER_FRAGMENTS: &[&str] = &[
    // R35: leading whitespace makes the token unique against future
    // higher-numbered funcIds (e.g. without it, `"42 =>"` would also
    // match `"1042 =>"`). Today this is theoretical — max funcId is 57
    // — but the precise pattern costs us nothing.
    "        42 =>",
    "        43 =>",
    "        44 =>",
    "        45 =>",
    "        46 =>",
    "        47 =>",
    "        48 =>",
    "        49 =>",
    "        50 =>",
    "        51 =>",
    "        52 =>",
    "        54 =>",
    "        55 =>",
    "        56 =>",
    "        57 =>",
    // 批次 10 (本地备份/恢复) 手动 dispatch 注册
    "        63 =>",
    "        64 =>",
    "        65 =>",
    // 批次 11 (WebDAV 同步) 手动 dispatch 注册
    "        66 =>",
    "        67 =>",
    "        68 =>",
    "        69 =>",
    "        70 =>",
    // 批次 12 (加密备份 AES Legado 兼容) 手动 dispatch 注册
    "        71 =>",
    "        72 =>",
    // 批次 13 (本地书导入 MVP) 手动 dispatch 注册
    "        73 =>",
    // 批次 14 (阅读时长统计 ReadRecord) 手动 dispatch 注册
    "        74 =>",
    "        75 =>",
    "        76 =>",
    "        77 =>",
    // 批次 15 (缓存管理 CacheStats) 手动 dispatch 注册
    "        78 =>",
    "        79 =>",
    "        80 =>",
    "        81 =>",
    // 批次 16 (RSS 源管理 schema v12) 手动 dispatch 注册
    "        82 =>",
    "        83 =>",
    "        84 =>",
    "        85 =>",
    "        86 =>",
    "        87 =>",
    "        88 =>",
    "        89 =>",
    "        90 =>",
    // 批次 17 (RSS 拉取 + 文章列表) 手动 dispatch 注册
    "        91 =>",
    "        92 =>",
    "        93 =>",
    "        94 =>",
    "        95 =>",
    "        96 =>",
    // 批次 18 (RSS 详情 + 收藏) 手动 dispatch 注册
    "        97 =>",
    "        98 =>",
    "        99 =>",
    "        100 =>",
    "        101 =>",
    // 批次 19 (订阅源 RuleSub MVP) 手动 dispatch 注册
    "        102 =>",
    "        103 =>",
    "        104 =>",
    "        105 =>",
    "        106 =>",
    "        107 =>",
    "        108 =>",
    // 批次 21 (书源实跑验证 LiveTest) 手动 dispatch 注册
    "        109 =>",
    // 批次 22 (RSS detail FRB 桥) 手动 dispatch 注册
    "        110 =>",
    // BATCH-27a (bookshelf 导出 JSON) 手动 dispatch 注册
    "        111 =>",
    // BATCH-27b (单本目录刷新) 手动 dispatch 注册
    "        112 =>",
    // BATCH-27c (webdav 通用 list_dir / download_file) 手动 dispatch 注册
    "        113 =>",
    "        114 =>",
    // BATCH-27d (书架批量编辑) 手动 dispatch 注册（clear cache 复用 26a 80）
    "        115 =>",
    "        117 =>",
    "        118 =>",
    "        119 =>",
];

/// R3: the dispatcher default arms must surface the unknown funcId
/// instead of bare `unreachable!()`. If a codegen run reverts those to
/// the codegen template, this fragment list catches it.
const REQUIRED_PANIC_FRAGMENTS: &[&str] = &[
    "FRB primary dispatcher: unknown funcId",
    "FRB sync dispatcher: unknown funcId",
];

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let frb = manifest_dir.join("src/frb_generated.rs");

    println!("cargo:rerun-if-changed=src/frb_generated.rs");

    let content = match fs::read_to_string(&frb) {
        Ok(s) => s,
        Err(e) => {
            // Don't hard-fail on a missing file (e.g. pre-codegen skeleton).
            // Surface a warning so the next codegen run is conspicuous.
            println!(
                "cargo:warning=bridge build.rs: cannot read {}: {} (manual-patch guard skipped)",
                frb.display(),
                e
            );
            return;
        }
    };

    let mut missing = Vec::new();
    for needle in REQUIRED_WIRE_FN_FRAGMENTS {
        if !content.contains(needle) {
            missing.push(*needle);
        }
    }
    for needle in REQUIRED_DISPATCHER_FRAGMENTS {
        if !content.contains(needle) {
            missing.push(*needle);
        }
    }
    for needle in REQUIRED_PANIC_FRAGMENTS {
        if !content.contains(needle) {
            missing.push(*needle);
        }
    }

    if !missing.is_empty() {
        // Hard error: a missing wire fn means runtime calls from Dart will
        // panic with `unreachable!()`. Better to fail the build now.
        for fragment in &missing {
            println!(
                "cargo:warning=bridge build.rs: missing manual wire fragment `{}`",
                fragment
            );
        }
        panic!(
            "frb_generated.rs is missing {} hand-edited wire/dispatch fragment(s). \
             A `flutter_rust_bridge_codegen generate` run probably overwrote the manual \
             patches. This guard only covers the funcIds we know were hand-edited \
             (currently 42-52 plus 54 and 57 plus 63-65 plus 66-70 plus 71-72 plus 73 plus 74-77 plus 78-81 plus 82-90 plus 91-96 plus 97-101 plus 102-108 plus 109 plus 110 plus 111 plus 112; 53/55/56 are intentionally holes — 53 was never registered, 55/56 were deleted with `explore` / `get_explore_entries` in BATCH-07a, do not re-introduce), \
             plus the R3 informative panic in the dispatcher default arms. \
             funcIds outside that range are produced by codegen and are NOT checked here, \
             so a regression in those needs separate attention. See CURRENT_STATUS.md \
             (FRB patch chapter) for the full re-apply procedure.",
            missing.len()
        );
    }

    // R3: cross-check Rust dispatcher funcIds against Dart-side wire calls.
    // If the Dart binary calls a funcId Rust doesn't dispatch, the runtime
    // will hit the dispatcher's default arm and panic mid-request, which
    // surfaces as a hung Flutter future. Catching this at compile time
    // requires both files to be visible — for headless / CI builds that
    // only compile core, the Dart file may be absent; in that case we
    // skip with a warning rather than fail.
    let dart_path = manifest_dir.join("../../flutter_app/lib/src/rust/frb_generated.dart");
    println!(
        "cargo:rerun-if-changed={}",
        dart_path.display()
    );
    let dart_content = match fs::read_to_string(&dart_path) {
        Ok(s) => s,
        Err(_) => {
            // Don't fail; not every build environment has the Flutter
            // tree available (e.g. cargo-only CI pipelines).
            println!(
                "cargo:warning=bridge build.rs: Dart frb_generated.dart not found at {} \
                 (R3 funcId-table cross-check skipped)",
                dart_path.display()
            );
            return;
        }
    };

    let rust_ids = extract_rust_func_ids(&content);
    let dart_ids = extract_dart_func_ids(&dart_content);

    if rust_ids.is_empty() {
        println!(
            "cargo:warning=bridge build.rs: parsed 0 funcIds from Rust dispatcher \
             — parser may be out of date with codegen format"
        );
        return;
    }
    if dart_ids.is_empty() {
        println!(
            "cargo:warning=bridge build.rs: parsed 0 funcIds from Dart frb_generated.dart \
             — parser may be out of date with codegen format"
        );
        return;
    }

    let dart_only: Vec<i32> = dart_ids
        .iter()
        .copied()
        .filter(|id| !rust_ids.contains(id))
        .collect();
    let rust_only: Vec<i32> = rust_ids
        .iter()
        .copied()
        .filter(|id| !dart_ids.contains(id))
        .collect();

    if !rust_only.is_empty() {
        // R3: Rust has wire fns Dart doesn't call. Common case is a
        // hand-added wire fn pending its Dart caller — warn but don't
        // fail.
        println!(
            "cargo:warning=bridge build.rs: Rust dispatcher has funcIds Dart never \
             calls: {:?} — caller might be missing on the Dart side",
            rust_only
        );
    }

    if !dart_only.is_empty() {
        panic!(
            "Dart frb_generated.dart calls funcId(s) {:?} that the Rust dispatcher \
             does NOT route. Runtime dispatch would hit `unreachable!()` and the \
             Flutter request would hang. Re-run codegen on the side that's behind, \
             or hand-patch the missing wire fn(s) into core/bridge/src/frb_generated.rs \
             (see CURRENT_STATUS.md FRB patch chapter).",
            dart_only
        );
    }
}

/// R3: extract all funcIds the Rust dispatcher routes.
///
/// The dispatcher arms look like `        42 => wire__crate__api__...`,
/// generated with 8-space indent inside `match func_id { ... }`. We scan
/// for that prefix to avoid false-matching numbers that appear inside
/// function bodies or comments. Trailing `=>` is required so we don't
/// pick up other constructs.
///
/// R94: scope the scan to inside `pde_ffi_dispatcher_primary_impl` and
/// `pde_ffi_dispatcher_sync_impl` function bodies. Other parts of
/// `frb_generated.rs` may use the same 8-space `        N => ...` indent
/// for unrelated match arms (enum decoders etc.); without this scoping
/// such arms would be miscounted as funcIds and trigger spurious
/// "Rust dispatcher has funcIds Dart never calls" warnings.
fn extract_rust_func_ids(content: &str) -> Vec<i32> {
    let mut ids = Vec::new();
    let mut in_dispatcher = false;
    for line in content.lines() {
        if line.starts_with("fn pde_ffi_dispatcher_primary_impl(")
            || line.starts_with("fn pde_ffi_dispatcher_sync_impl(")
        {
            in_dispatcher = true;
            continue;
        }
        // Closing `}` at column 0 marks the end of a top-level fn body
        // in the generated file.
        if in_dispatcher && line == "}" {
            in_dispatcher = false;
            continue;
        }
        if !in_dispatcher {
            continue;
        }
        // Rust dispatcher arms are 8-space-indented: "        42 => ..."
        let stripped = match line.strip_prefix("        ") {
            Some(s) => s,
            None => continue,
        };
        // After leading 8 spaces, take ascii digits then space-then-`=>`
        let (digits, rest) = take_digits(stripped);
        if digits.is_empty() {
            continue;
        }
        let rest = rest.trim_start();
        if !rest.starts_with("=>") {
            continue;
        }
        if let Ok(id) = digits.parse::<i32>() {
            ids.push(id);
        }
    }
    ids
}

/// R3: extract all funcIds the Dart binding calls.
///
/// Dart wire fn calls look like `            funcId: 42, port: port_);`
/// inside the impl methods. We scan lines whose trimmed start is
/// `funcId:` to avoid matching `funcId` mentions in doc comments or
/// other contexts. Trailing comma is required.
fn extract_dart_func_ids(content: &str) -> Vec<i32> {
    let mut ids = Vec::new();
    for line in content.lines() {
        let trimmed = line.trim_start();
        let after_keyword = match trimmed.strip_prefix("funcId:") {
            Some(s) => s.trim_start(),
            None => continue,
        };
        let (digits, rest) = take_digits(after_keyword);
        if digits.is_empty() {
            continue;
        }
        // Must be followed by comma (i.e. an argument-list entry, not
        // a property name in some unrelated map literal).
        if !rest.trim_start().starts_with(',') {
            continue;
        }
        if let Ok(id) = digits.parse::<i32>() {
            ids.push(id);
        }
    }
    ids
}

/// Slice off leading ASCII-digit run and return (digits, rest).
fn take_digits(s: &str) -> (&str, &str) {
    let split_at = s
        .char_indices()
        .find(|(_, c)| !c.is_ascii_digit())
        .map(|(i, _)| i)
        .unwrap_or(s.len());
    s.split_at(split_at)
}
