# Research: List / Scrolling Audit

- **Query**: 审计 `flutter_app/lib/features/**` 和必要的 `flutter_app/lib/core/**` 中主要列表/滚动视图实现，找出本任务应处理的明显低风险性能或布局问题；重点关注 `ListView(children:)`、重行构建、build 中重复过滤/排序/字符串处理、横向 `Row` overflow、嵌套滚动/shrinkWrap、异步搜索旧 future 覆盖、阅读器换源增量并发显示现状。
- **Scope**: internal
- **Date**: 2026-05-26

## 1) 总结

- 主要大列表多数已使用 `ListView.builder` / `GridView.builder`：书架列表与网格、搜索结果、阅读目录/书签、RSS 文章、替换规则、缓存管理、远程书、书源校验进度等均为懒构建。
- 明显仍使用 `ListView(children:)` 且数据量可能随用户导入增长的是 RSS 源管理页：`rss_source_manage_page.dart` 先分组后把所有 header/tile widget 一次性加入 `children`。
- 书源管理页 `_buildSourceList` 在每次 build 中对 `sources` 做搜索过滤、失败过滤、排序；列表行内同时包含搜索/选择状态、耗时 chip、错误图标、`Switch`、两个 `IconButton`，右侧控件密集，有窄屏 overflow 风险。
- 搜索页已有 `_searchSeq` 防旧 future 覆盖，并且先显示本地结果、后显示在线结果；远程书目录页已有 `_loadSeq` 防旧目录覆盖。
- 换源弹窗当前按 8 个书源一批 `Future.wait`，每批结束后才合并结果并刷新计数；单个书源内部会 `setState` 更新 `_currentLoadingSource`。未发现类似搜索页的 seq token；AppBar 在 `_isSearching` 时展示“刷新”按钮，可再次调用 `_startSearch`。
- 远程书目录页 `_visibleEntries` 明确在 getter/build 路径每帧复制、排序、过滤，并在注释中说明 N 通常 ≤ 数百。

## 2) 必改项

### A. RSS 源管理 `ListView(children:)` 一次性构建所有分组和源条目

- `flutter_app/lib/features/rss/rss_source_manage_page.dart:311-320`：`_buildList` 调 `_groupRecords()`，再把每个 section header 和每个 source tile 全部 push 到 `children`，最后 `return ListView(children: children);`。
- 相关代码：
  - `flutter_app/lib/features/rss/rss_source_manage_page.dart:312` `final grouped = _groupRecords();`
  - `flutter_app/lib/features/rss/rss_source_manage_page.dart:313-318` 构建 `List<Widget> children` 并逐项 add header/tile
  - `flutter_app/lib/features/rss/rss_source_manage_page.dart:320` `return ListView(children: children);`
- 数据源来自 `_records`，导入 RSS 源数量增加时，当前实现会在一次 build 中创建所有 tile widget。

### B. 书源管理列表在 build 路径重复过滤/排序，且每行右侧控件密集

- `flutter_app/lib/features/source/source_page.dart:437-447`：`_buildSourceList` 每次 build 对 `sources` 执行搜索过滤、失败过滤、`toList()`，然后 `_sortSources(filtered)`。
- `flutter_app/lib/features/source/source_page.dart:440-443`：每个 source 取 name 并 `toLowerCase()`，同时对 `_searchQuery.toLowerCase()` 逐项重复计算。
- `flutter_app/lib/features/source/source_page.dart:606-626`：`_sortSources` 在 build 路径对 filtered list 排序，支持响应时间升序和最后检查时间降序。
- `flutter_app/lib/features/source/source_page.dart:486-588`：每行主 `Row` 右侧在非选择模式下可同时包含响应时间 `Container`、错误 `Tooltip/Icon`、`Switch`、状态圆点、两个零 padding/零 constraints 的 `IconButton`。左侧文本区使用 `Expanded`，名称处有 `Flexible`，URL 有 `maxLines: 1` + ellipsis；右侧控件整体没有折叠或换行机制。

### C. 换源弹窗并发搜索结果按批次刷新，旧搜索无 seq token

- `flutter_app/lib/features/reader/change_source_dialog.dart:70-145`：`_startSearch` 清空状态后读取启用书源，并按批次搜索。
- `flutter_app/lib/features/reader/change_source_dialog.dart:96-110`：`maxConcurrent = 8`，每批 `Future.wait(futures)`；只有整批返回后才进入合并逻辑。
- `flutter_app/lib/features/reader/change_source_dialog.dart:113-130`：批结果合并到 `_results` 后 `setState(() => _resultCount = _results.length)`，因此结果列表按批次增量出现，而不是单个 source 完成即出现。
- `flutter_app/lib/features/reader/change_source_dialog.dart:119-125`：去重 key 为 `${source_name}_${source_id}`，即同一书源只保留一个结果。
- `flutter_app/lib/features/reader/change_source_dialog.dart:133-135`：全部批次结束后 `_isSearching = false`；如果 `_results` 为空再设置错误。
- `flutter_app/lib/features/reader/change_source_dialog.dart:285-289`：`_isSearching` 时 AppBar 显示刷新按钮，`onPressed: _startSearch`。
- 未发现 `_searchSeq` / run id 一类 token；如果搜索进行中再次触发 `_startSearch`，旧批次 future 的回写路径仍引用同一 `_results` / `_searchedCount` / `_isSearching` 状态。

## 3) 可选项/后续项

### D. 远程书目录每次 build 派生排序/过滤，并在行内格式化文件大小/时间

- `flutter_app/lib/features/remote_books/remote_books_page.dart:207-233`：`_visibleEntries` getter 每次调用都会复制 `_entries`、排序，并在有 query 时过滤；注释注明“不缓存（每帧 build 重算）：N 通常 ≤ 数百”。
- `flutter_app/lib/features/remote_books/remote_books_page.dart:1130-1139`：`_buildBody` 中 `final view = _visibleEntries;`，列表使用派生结果。
- `flutter_app/lib/features/remote_books/remote_books_page.dart:1145-1166`：行构建为 `ListTile`，subtitle 对文件调用 `_subtitleFor(e)`。
- `flutter_app/lib/features/remote_books/remote_books_page.dart:1171-1190`：`_subtitleFor` 每行组合 `_formatBytes` 和 `formatRelativeTime` 字符串。
- 同文件 `flutter_app/lib/features/remote_books/remote_books_page.dart:168-171` 和 `518-544` 已有 `_loadSeq`，用于路径快速切换时阻止旧 future 覆盖新目录结果。

### E. 搜索结果行内组装 subtitle 字符串；异步搜索已有旧 future 防护

- `flutter_app/lib/features/search/search_page.dart:403-464`：`_doSearch` 用 `seq = ++_searchSeq`，在 `dbInitializedProvider`、本地结果、在线结果、最后收尾处均检查 `seq == _searchSeq`。
- `flutter_app/lib/features/search/search_page.dart:422-449`：本地和在线搜索同时启动，先 await 本地并显示局部结果，再 await 在线并更新在线结果。
- `flutter_app/lib/features/search/search_page.dart:361-396`：在线搜索对所有启用书源创建 futures，统一 `Future.wait`，再 flatten + 按 `name_author` 去重。
- `flutter_app/lib/features/search/search_page.dart:725-743`：每个结果卡 build 时读取字段并构造 `subtitleParts`。
- `flutter_app/lib/features/search/search_page.dart:760-790`：title/subtitle/intro 都有限制行数和 ellipsis。
- `flutter_app/lib/features/search/search_page.dart:810-875`：搜索历史页使用 `SingleChildScrollView` + `Column` + `Wrap`，历史长度在 `162-167` 限制为 20。

### F. 书源校验进度列表用 `elementAt(index)` 访问 map values

- `flutter_app/lib/features/source/source_check_progress_page.dart:159-165`：`_completedCount` 每次 build 对 `_rowsById.values.where(...).length` 计数。
- `flutter_app/lib/features/source/source_check_progress_page.dart:208-212`：`ListView.builder` 的 itemBuilder 中用 `_rowsById.values.elementAt(index)` 取行。`_rowsById.values` 是 iterable，逐 index 访问可能随行数增长产生额外遍历。
- `flutter_app/lib/features/source/source_check_progress_page.dart:231-281`：每行 subtitle 内 `Wrap` 固定渲染 `_allStages` 的阶段 chip，属于每行固定小集合。

### G. 替换规则列表行内字符串截断/拼接

- `flutter_app/lib/features/replace_rule/replace_rule_page.dart:85-128`：使用 `ListView.builder`。
- `flutter_app/lib/features/replace_rule/replace_rule_page.dart:91-106`：每行 build 对 scope/exclude scope trim、truncate，并组合 target/exclude label。
- `flutter_app/lib/features/replace_rule/replace_rule_page.dart:113-118`：subtitle 拼接 pattern/replacement 与 scope 信息，`isThreeLine: true`。

### H. RSS 文章列表行内描述截断/缩略图

- `flutter_app/lib/features/rss/rss_article_list_page.dart:435-441`：文章列表使用 `ListView.builder`。
- `flutter_app/lib/features/rss/rss_article_list_page.dart:451-463`：每行 build 时 trim description、截断 50 字并 join subtitle。
- `flutter_app/lib/features/rss/rss_article_list_page.dart:467-497`：title 使用 `Row`，未读圆点 + `Expanded Text`，有 ellipsis。

### I. 书架列表/网格当前为懒构建，行内图片已有尺寸缓存参数

- `flutter_app/lib/features/bookshelf/bookshelf_page.dart:932-941`：书架列表使用 `ListView.builder`。
- `flutter_app/lib/features/bookshelf/bookshelf_page.dart:1147-1159`：书架网格使用 `GridView.builder`。
- `flutter_app/lib/features/bookshelf/bookshelf_page.dart:1074-1111`：列表封面 `Image.file` 使用 `cacheWidth/cacheHeight: 80/120`，`CachedNetworkImage` 使用 `memCacheWidth/memCacheHeight: 80/120`。

## 4) 相关文件和行号

| File Path | Lines | Finding |
|---|---:|---|
| `flutter_app/lib/features/rss/rss_source_manage_page.dart` | 311-320 | RSS 源管理页分组后用 `ListView(children:)` 一次性构建所有 header/tile。 |
| `flutter_app/lib/features/source/source_page.dart` | 437-447 | 书源列表 build 中过滤、`toList`、排序。 |
| `flutter_app/lib/features/source/source_page.dart` | 486-588 | 书源行右侧控件密集，横向 `Row` 依赖左侧 `Expanded/Flexible` 和文本 ellipsis。 |
| `flutter_app/lib/features/source/source_page.dart` | 606-626 | 书源排序函数在 build 派生列表上执行。 |
| `flutter_app/lib/features/reader/change_source_dialog.dart` | 70-145 | 换源搜索主流程：清状态、批量并发、批次合并、完成/错误状态。 |
| `flutter_app/lib/features/reader/change_source_dialog.dart` | 96-130 | 8 并发批次 `Future.wait`，批次结束后才更新 `_results` / `_resultCount`。 |
| `flutter_app/lib/features/reader/change_source_dialog.dart` | 285-289 | 搜索中刷新按钮可再次调用 `_startSearch`。 |
| `flutter_app/lib/features/search/search_page.dart` | 74-80, 403-464 | 搜索页已有 `_searchSeq` 防旧 future 覆盖。 |
| `flutter_app/lib/features/search/search_page.dart` | 361-396 | 在线搜索对所有启用书源 `Future.wait` 后 flatten/dedup。 |
| `flutter_app/lib/features/remote_books/remote_books_page.dart` | 207-233 | 远程书目录 `_visibleEntries` 每帧复制/排序/过滤。 |
| `flutter_app/lib/features/remote_books/remote_books_page.dart` | 168-171, 518-544 | 远程书目录已有 `_loadSeq` 防旧 future 覆盖。 |
| `flutter_app/lib/features/source/source_check_progress_page.dart` | 159-165, 208-212 | 校验进度 build 中计数并用 `_rowsById.values.elementAt(index)`。 |
| `flutter_app/lib/features/replace_rule/replace_rule_page.dart` | 85-128 | 替换规则列表为 builder，但行内做 trim/truncate/拼接。 |
| `flutter_app/lib/features/rss/rss_article_list_page.dart` | 435-463 | RSS 文章 builder 行内 trim/截断/join subtitle。 |
| `flutter_app/lib/features/bookshelf/bookshelf_page.dart` | 932-941, 1147-1159 | 书架列表/网格均为 builder。 |

## 5) 建议测试

- RSS 源管理：构造多分组、多 RSS 源数据，验证分组标题、源名称/URL、开关、删除菜单、点击进入文章列表保持不变。
- 书源管理：构造大量书源并覆盖搜索、仅失败、响应时间排序、最后检查时间排序；在窄屏宽度下泵页面，检查无 overflow exception，开关和两个操作按钮仍可用。
- 换源弹窗：用可控 fake 搜索 future 覆盖“慢旧搜索 + 快新搜索”、批内部分成功/失败/超时、重复刷新，断言最终列表、计数、loading/error 状态来自预期 run。
- 搜索页：保留现有 `_searchSeq` 行为测试；覆盖本地先返回、在线后返回、旧在线结果晚于新搜索返回时不覆盖。
- 远程书目录：构造数百条文件/文件夹，覆盖按名称/时间升降序、搜索过滤、快速下钻/上钻旧 future 不覆盖。
- 书源校验进度：构造多条 progress，验证完成数、阶段 chip、错误文案、延迟展示顺序稳定。

## Caveats / Not Found

- 本次只做静态代码审计，未运行 Flutter app、widget tests 或性能 profiling。
- `flutter_app/lib/core/**` 未发现主要列表/滚动 UI；相关 core 命中主要是 provider、runner、service。
- `ListView(children:)` 在设置页、备份页、编辑页等固定小表单/设置页面也存在，但这些不是大量数据列表，未列为必改项。
