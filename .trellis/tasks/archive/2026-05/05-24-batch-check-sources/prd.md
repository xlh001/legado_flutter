# batch-check-sources — 批量校验书源

## Goal

实现原版 legado `CheckSource` 同等能力的批量书源校验：选中多个源 → 配置 5 个 stage 开关 → 后台跑 → 实时进度 → 结果持久化到 DB → 列表按延迟排序/仅看失败。

## What I already know

### 原版 legado CheckSource 契约
* `CheckSource.kt`: keyword="我的", timeout=180000ms, 5 stage (search/discovery/info/category/content)
* Android Foreground Service 跑 (`CheckSourceService`), 可 stop / resume
* 结果写 `respondTime` / `lastError` (bookSourceComment) 到 SQLite
* 通知栏实时进度 + 跑完汇总

### 本仓现状 (via sub-agent exploration)

**DB schema** (`core-storage/src/database.rs:116-153`):
* `book_sources` 表 29 列, DB_VERSION=12
* 已有完整 migration 系统 (v1→v12), 用 `pragma_table_info` guard + `ALTER TABLE`
* v6/v8/v9 已有 3 次 ALTER TABLE book_sources 先例 — 加 v13 模式清晰
* 无 `respond_time` / `last_check_error` / `last_check_at` 列

**Rust struct** (`core-storage/src/models.rs:10-57`):
* `BookSource` 29 字段, 直接 map SQL 列
* DAO 层 `BOOK_SOURCE_COLUMNS` / `SOURCE_UPSERT_SQL` / `book_source_from_row()` 需同步更新

**run_live_test** (`core-source/src/lib.rs:119-248`):
* 4 stage 顺序执行: search → book_info → toc → content
* 失败不短路, 用 fallback URL: `{source.url}/book/test`
* `content` sample 截断前 200 字符
* parser.explore() 已存在 (`parser.rs:664`) 但未接入 live test
* BookSource 已有 `explore_url`, `rule_explore`, `enabled_explore` 字段

**FRB bridge** (`core/bridge/src/api.rs:901-916`):
* 现有: `validate_source_live(db_path, source_id, keyword) -> Result<String, String>` — 返回 JSON string, 非 Stream
* 需新增 batch 版 API

**Flutter UI** (`source_page.dart`):
* 状态: `_selectMode: bool`, `_selectedIds: Set<String>`, `_searchQuery: String`
* 进入选择: 长按 → `_enterSelectMode(id)`, 退出: AppBar close(X) → `_exitSelectMode()`
* 底栏 (line 165-253): [全选 toggle] [反选: **空 onPressed**] [删除: _deleteSelected] [⋮: **空 onPressed**]
* ⋮ more_vert 是 batch 操作的天然入口
* 单源校验: `_showSourceActions` → `_showValidateDialog` (静态) → `_showLiveTestDialog` (4-stage 实跑)
* `allSourcesProvider` 返回 `List<Map<String, dynamic>>`, JSON key 用 snake_case 对齐 Rust
* `deleteSourcesBatch` FRB API 已存在但 UI 未用 — batch 模式先例

**JS runtime**: rquickjs feature `js-quickjs` 默认开, `@js:` / `<js>` / `java.ajax` 均支持
**WebView 规则**: Rust 层抛 `PlatformRequest::WebViewContent`, 批量场景无法测试
**Android**: NDK 26 + jniLibs + ARM64 已通

## Assumptions (validated)

* `book_sources` 表结构易扩展 ✓ — migration system 成熟, v6/v8/v9 先例
* FRB v2 支持 Stream ✓ — `StreamSink` 可用
* 不需要 Foreground Service for MVP — Flutter isolate + Stream 足够
* Discovery stage: `parser.explore()` 已存在, 只需对第一个 ExploreEntry 调用

## Decision (ADR-lite)

1. **Discovery stage → P2**: MVP keep 4 stages (search/book_info/toc/content), aligned with existing `run_live_test`.
2. **MVP only, no generalization**: 批量 engine 写死 4 stage 不抽象化；不 checkpoint（被杀就重跑）；进度页不内嵌单源详情。

3. **FRB Stream API**: Rust 端 `batch_check_sources(db_path, source_ids, config_json, sink: StreamSink<String>)`, 用 `tokio::sync::Semaphore(8)` 控制并发, 每源跑完 `sink.add(progress_json)` + 写 DB。Dart 端 `api.batchCheckSources(...).listen(...)`。需重新 `flutter_rust_bridge_codegen generate`。
4. **Config dialog 完整版**: keyword 输入框（默认"我的"）+ 4 stage checkbox（默认全选）+ timeout slider（5s–300s，默认 180s）+ 并发数 slider（1–16，默认 8）。对齐原版 CheckSource 设置面板。
6. **Progress page: 全量列表实时更新** (对齐原版) — 所有源一直在列表里，每行: 源名 + 4 stage 状态图标 + 耗时。跑完一个从灰色"等待中"→ 绿色 ✓ / 红色 ✗。顶栏 current/N + 进度条。跑完不弹窗，留在页面可滚动回顾。
7. **Fix "反选" button**: 顺手修掉 line 221 的 dead `onPressed`，逻辑: 遍历所有 source，toggle 每个 id 在 `_selectedIds` 中的存在。5 行代码，同一文件同一底栏，不单独建任务。

## Requirements

### Config Dialog
* keyword 输入框（默认"我的"）+ 4 stage checkbox（search/book_info/toc/content，默认全选）
* timeout slider: 5s–300s（默认 180s）
* 并发数 slider: 1–16（默认 8）
* "开始校验" 按钮 → 跳转进度页

### Progress Page (`SourceCheckProgressPage`)
* 顶栏: "校验书源 (3/50)" + 线性进度条
* 列表: 每行 source name + 4 stage 状态图标 (pending: 灰色圆圈, running: spinner, ok: 绿色 ✓, fail: 红色 ✗) + 总耗时
* 全部源始终可见, 实时更新（对齐原版 legado）
* 取消按钮: 用 `CancelToken` 停止批量任务
* 跑完不弹窗, 留在页面可滚动回顾

### Source Page Enhancements
* 选择模式底栏 ⋮ more_vert → 新增 "批量校验" 入口 → 弹出 Config Dialog
* Fix "反选" button dead `onPressed`
* AppBar 排序菜单: 默认 / 按 respondTime 升序 / 按最后校验时间降序
* AppBar 筛选: 全部 / 仅看失败 (`last_check_error IS NOT NULL`)
* 失败源 ListTile 右侧红色 error 图标 + tooltip 显示 `last_check_error`
* 列表项可选显示 respondTime 徽章

### DB Schema v13
* `ALTER TABLE book_sources ADD COLUMN respond_time INTEGER DEFAULT 0`
* `ALTER TABLE book_sources ADD COLUMN last_check_error TEXT`
* `ALTER TABLE book_sources ADD COLUMN last_check_at INTEGER DEFAULT 0`

### Rust Batch Engine
* `CheckConfig { keyword, stages: HashSet<String>, timeout_secs: u64, concurrency: usize }`
* `batch_run_live_test(sources, config, sink)` — 内部 `Semaphore(concurrency)`, `tokio::time::timeout` 包每个源
* 每源跑完: `sink.add(SourceCheckProgress { source_id, name, stages: Vec<StageResult>, total_latency_ms, error? })` + UPDATE book_sources
* FRB: `batch_check_sources(db_path, source_ids_json, config_json, sink: StreamSink<String>)`

## Acceptance Criteria (evolving)

* [ ] 选择模式底栏 ⋮ → "批量校验" dialog: 5 stage checkbox + keyword 输入 + timeout slider
* [ ] 进度页: 顶栏 current/N + 进度条, 列表每行: 源名 + stage-by-stage 状态 + 总耗时
* [ ] 结果写回 DB: `respond_time`, `last_check_error`, `last_check_at`
* [ ] source_page 列表 AppBar 排序菜单: 默认/按延迟/按最后校验时间/仅看失败
* [ ] 失败源红色标记 + tooltip 显示 lastCheckError

## Definition of Done

* DB v13 migration: +3 列 (`respond_time INTEGER DEFAULT 0`, `last_check_error TEXT`, `last_check_at INTEGER DEFAULT 0`)
* FRB `batch_check_sources(db_path, source_ids, config) -> Stream<CheckProgress>`
* Rust: `tokio::sync::Semaphore(8)` + `tokio::time::timeout`
* Flutter `SourceCheckProgressPage` + sorting/filter UI
* `flutter analyze` 0 issues + `cargo test --lib core-source` 0 errors
* 用 5 个真实书源手动 verify

## Out of Scope (explicit)

* Android Foreground Service (P2)
* WebView 规则测试 (物理限制)
* 暂停/恢复 (P2)
* 单源选中后的"校验"入口不变（已有 _showValidateDialog → _showLiveTestDialog）

## Technical Notes

### Files to modify
| Layer | File | Change |
|-------|------|--------|
| Storage | `core-storage/src/database.rs` | +`migrate_v13`, bump `DB_VERSION`→13 |
| Storage | `core-storage/src/models.rs` | +`respond_time`, `last_check_error`, `last_check_at` |
| Storage | `core-storage/src/source_dao.rs` | Update COLUMNS/UPSERT/from_row |
| Source | `core-source/src/lib.rs` | +`CheckConfig`, +`batch_run_live_test`, +discovery stage in `run_live_test` |
| Bridge | `core/bridge/src/api.rs` | +`batch_check_sources` FRB (Stream) |
| Flutter | `source_page.dart` | ⋮ menu → "批量校验" dialog, sorting/filter menu, failure badge |
| Flutter | new: `source_check_progress_page.dart` | Progress page with Stream listener |
| Flutter | `api.dart` (FRB generated) | Auto-regenerated after `flutter_rust_bridge_codegen` |
| Spec | `.trellis/spec/` | Update if new patterns emerge |

### Migration v13 template (from v6/v8/v9 pattern)
```rust
fn migrate_v13(conn: &Connection) -> SqlResult<()> {
    for (col, col_type) in [("respond_time", "INTEGER DEFAULT 0"),
                            ("last_check_error", "TEXT"),
                            ("last_check_at", "INTEGER DEFAULT 0")] {
        let has: bool = conn.query_row(
            "SELECT COUNT(*) > 0 FROM pragma_table_info('book_sources') WHERE name = ?1",
            rusqlite::params![col], |r| r.get(0))?;
        if !has {
            conn.execute(&format!("ALTER TABLE book_sources ADD COLUMN {} {}", col, col_type), [])?;
        }
    }
    Ok(())
}
```

### Discovery stage design
* 取 `get_explore_entries(source)[0]` 的 url, 调 `parser.explore(source, &entry.url, 1)`
* 成功 sample: `"发现 N 本书"`, 失败 error 照常
* 若 `explore_url` 为空则标记 `skipped: true`

### FRB Stream design
```rust
pub fn batch_check_sources(
    db_path: String, source_ids: Vec<String>, config_json: String,
    sink: StreamSink<String>, // per-source progress JSON
) -> Result<(), String>
```
Dart 端 `rust_api.batchCheckSources(...).listen((json) { ... })`

## Research References

* `explore/research/db-schema.md` — book_sources 表 29 列, migration 系统 v1→v12, v13 模板已提供
* `explore/research/run-live-test-flow.md` — run_live_test 完整 4-stage 流程 + parser.explore() 接入方案
* `explore/research/source-page-ui-flow.md` — source_page 选择模式状态机 + 底栏 gaps + provider 体系
