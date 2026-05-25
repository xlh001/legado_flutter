# Optimize List Scrolling And Source Switching

## Goal

优化 Flutter 端列表滚动流畅度，范围扩大到检查现有主要列表页面并处理明显问题；同时把阅读器换源搜索改成并发搜索、单条结果完成后立即展示，降低等待感。同步处理用户日志里暴露的明显 UI/启动异常，避免诊断日志持续刷错误。

## What I Already Know

- 用户反馈：设置列表、书源列表滑动有卡顿；希望顺带检查其他列表问题。
- 用户需求：阅读器换源时可以并发搜索，搜到一条显示一条。
- 日志显示 `/diagnostics` 页面反复出现 `RenderFlex overflowed by 1.5 pixels on the right`。
- 日志显示启动时出现 `Zone mismatch`，栈在 `main.dart` 的 `runApp` 附近。
- `settings_page.dart` 当前使用普通 `ListView(children: [...])`，全部 children 一次性构建。
- `source_page.dart` 使用 `ListView.builder`，但每次 build 内同步过滤、排序、构建较重行；行内包含 `Switch`、多个 `IconButton`、`Tooltip`、多个 `Container`。
- `change_source_dialog.dart` 当前每批 8 个并发搜索，但 `await Future.wait(batch)` 后才合并结果，所以单个源提前完成也要等整批结束才显示。
- `diagnostics_page.dart` 的控制按钮使用固定 `Row`，窄屏容易溢出。
- 列表审计研究显示：多数大列表已经使用 `ListView.builder` / `GridView.builder`；明确必改集中在 RSS 源管理 `ListView(children:)`、书源管理 build 中过滤/排序与右侧控件密集、换源弹窗批次刷新且无 seq token。

## Requirements

- 设置列表应减少无意义重建和重布局，保留现有功能与视觉结构。
- 书源列表应降低滚动时每帧 build 压力，尤其是过滤/排序与行内重组件。
- 检查现有主要列表页面，处理会导致卡顿、一次性构建过多 children、横向溢出、搜索期间旧结果覆盖等明显问题。
- 重点优化用户点名的设置列表、书源列表、阅读器换源结果列表；允许对多个列表页面做结构性拆分/重组，但不做无关 UI 重设计。
- 阅读器换源搜索应保持并发，但结果完成一条就追加展示一条，不等整批结束。
- 换源搜索需要避免旧搜索结果覆盖新搜索结果或弹窗关闭后继续 setState。
- 诊断页按钮区域不能再触发窄屏横向 overflow。
- 启动 `Zone mismatch` 需要修复或至少纳入本任务明确处理范围。

## Acceptance Criteria

- [ ] 设置页滚动保持原行为，列表构建更懒加载或更稳定。
- [ ] 书源页搜索、筛选、排序、选择模式、启用开关行为不回归。
- [ ] 主要列表页面完成检查；发现的明显列表问题已修复或记录为后续任务。
- [ ] 换源弹窗打开后并发搜索启用书源，任一源返回匹配结果后立即显示。
- [ ] 换源重复刷新或关闭弹窗不会出现旧结果覆盖、新结果重复、`setState after dispose`。
- [ ] `/diagnostics` 页面在 361dp 宽度附近不再有按钮 Row overflow。
- [ ] 启动日志不再出现 Flutter `Zone mismatch`。
- [ ] `flutter analyze` 通过。
- [ ] 相关 widget/unit 测试通过；如无法跑全量测试，记录原因并至少跑受影响测试。

## Definition Of Done

- 遵守 `.trellis/spec/flutter-app` 中的 mounted、provider、质量约束。
- 不引入新依赖，除非实现中证明 Flutter 内建能力不足。
- 不改变用户可见功能语义，只优化性能、并发展示和已知错误。
- 如果发现更大范围架构问题，记录为后续任务，不在本任务无限扩 scope。

## Out Of Scope

- 不重做整套 UI 设计。
- 不把所有列表统一重构成新框架；结构性重构限于本任务识别出的列表性能/布局热点。
- 不做完整性能 profiling 工具链或基准测试平台；以代码层明显瓶颈、日志错误和测试验证为主。
- 不改 Rust 搜索规则语义，除非换源并发展示必须触碰。
- 不处理 APK 构建内存问题。

## Technical Approach

- 设置页：优先用 `ListView.builder` / 小型 item model / const 子树拆分，让列表懒构建并减少整页重建成本。
- 书源页：缓存过滤/排序派生结果并把重行拆为小 widget；避免 build 中重复 `toLowerCase()` 和排序全量列表；保留 `ListView.builder`。
- 换源弹窗：用搜索序号 token + 并发池；每个 `_searchSource` future 完成后按 token/mounted 校验并增量插入 `_results`；维护进度计数和去重集合。
- 诊断页：把按钮 `Row` 改为 `Wrap` 或响应式布局，窄屏自动换行。
- Zone mismatch：检查 `main.dart` 中 `WidgetsFlutterBinding.ensureInitialized()` 和 `runApp()` 所在 zone，保证二者在同一 zone 中执行。
- 其他列表：按文件审查，处理 `ListView(children: largeList)`、嵌套 shrinkWrap、横向 Row overflow、搜索/刷新旧 future 覆盖、新建大量非 const 静态子树等问题；允许必要的结构性拆分。

## Research References

- [`research/list-audit.md`](research/list-audit.md) — 主要列表/滚动视图审计，确认必改项为 RSS 源管理、书源管理、换源弹窗，其他列表多为可选或后续项。

## Prioritized Scope

- P0：修复换源弹窗并发增量显示和旧搜索防护。
- P0：修复启动 `Zone mismatch` 与诊断页窄屏 overflow。
- P1：结构性优化书源管理列表派生数据与行组件拆分，降低滚动卡顿和 overflow 风险。
- P1：结构性优化 RSS 源管理页，避免随导入数量增长一次性构建所有条目。
- P2：书源校验进度 `values.elementAt(index)` 等低风险局部优化。
- P2/后续：远程书、搜索、替换规则、RSS 文章等已是 builder 的行内字符串处理，除非实现中发现明显问题，否则记录为后续。

## Open Questions

- 无。

## Decisions

- 用户选择 MVP 方案 3：更大范围检查所有主要列表并一起优化；接受改动更大、测试更多。
- 用户选择全局列表检查后的修复边界为“更大结构性重构”：允许对多个页面做更彻底拆分/重组，以换取更稳定的列表性能和布局，但仍避免无关 UI 重做。

## Technical Notes

- 相关代码：`flutter_app/lib/features/settings/settings_page.dart`。
- 相关代码：`flutter_app/lib/features/source/source_page.dart`。
- 相关代码：`flutter_app/lib/features/reader/change_source_dialog.dart`。
- 相关代码：`flutter_app/lib/features/settings/diagnostics_page.dart`。
- 相关代码：`flutter_app/lib/main.dart`。
- 相关规范：`.trellis/spec/flutter-app/async-and-mounted.md`。
- 相关规范：`.trellis/spec/flutter-app/state-and-providers.md`。
- 相关规范：`.trellis/spec/flutter-app/quality-and-anti-patterns.md`。
