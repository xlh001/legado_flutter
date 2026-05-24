# 阅读器多项修复

## Goal

修复阅读器体验相关的 5 个 bug + 1 个 UI 调整，提升打开书籍、翻页、搜索的流畅度和稳定性。

## Requirements

### Bug 1: 打开已缓存的书有卡顿
- **轻量修复**: `_openChapter` 的 `setState` spinner→内容切换加 `AnimatedOpacity` 淡入过渡，消除跳帧感
- **深度修复**: `measureChapter()` 排版挪到 `compute()` 后台 isolate，彻底避免主线程阻塞
- 影响文件: `reader_page.dart`, `page_measure.dart`, `page_view_controller.dart`

### Bug 2: 书籍内容丢失时一直转圈
- 给 `getChapterContentWithSourceFromDb()` 加 `.timeout(Duration(seconds: 10))`
- 超时后在正文区域显示 "正文加载失败" 提示文字（复用已有 `_chapterContent` 字段），点击可重试
- 影响文件: `reader_page.dart`

### Bug 3: 刚打开书就翻章卡顿 + 无动画
- 实现 MD3 的 `isCompleted` 门控：当前章排版完成前用半透明 Overlay 拦截手势
- 翻章时始终播放动画（即使邻章内容未就绪，显示标题占位页）
- 翻章后异步加载内容填充
- 影响文件: `reader_page.dart`, `page_view.dart`, `page_view_controller.dart`

### Bug 4: 仿真翻页阴影奇怪 + 跟手翻页折线异常
- 添加 MD3 的 `onTouch` MOVE touchY override 逻辑：从屏幕中间拖拽时强制 touchY=pageHeight，锚定折线到底部
- 翻页背面 ColorFilter 改为 identity matrix（去掉 0.85 暗化），对齐 MD3 视觉
- 影响文件: `simulation_page_delegate.dart`

### Bug 5: 搜索只调书源不搜索本地
- 改为同时展示：本地书架结果 Section + 在线书源结果 Section
- `_onlineMode` toggle 改为控制是否发起在线搜索（本地搜索始终执行）
- 保留代码逻辑不变，只改 UI 布局
- 影响文件: `search_page.dart`

## Acceptance Criteria

- [ ] 打开缓存书 spinner→内容切换有淡入过渡，无跳帧感
- [ ] `measureChapter()` 运行在后台 isolate，主线程不阻塞
- [ ] 章节加载 10s 超时后在正文区域显示 "正文加载失败" 提示
- [ ] 排版完成前用户无法翻页（gesture block overlay）
- [ ] 翻章时始终播放完整翻页动画
- [ ] 仿真翻页从中间拖拽折线自然锚定到底部
- [ ] 仿真翻页背面不再偏暗（对齐 MD3）
- [ ] 搜索页同时显示本地结果和在线结果两个 Section
- [ ] Lint / typecheck 通过

## Technical Approach

| Bug | 策略 | 关键改动 |
|-----|------|---------|
| 1 | 轻量+深度 | `AnimatedOpacity` 过渡 + `Isolate.run()`/`compute()` 后台排版 |
| 2 | 超时+错误UI | `.timeout(10s)` + `_buildContentErrorView()` |
| 3 | MD3 门控 | `_isPageLayoutReady` flag + gesture-block overlay |
| 4 | 对齐 MD3 | touchY override + identity ColorFilter |
| 5 | UI 双 Section | 本地 Section + 在线 Section |

## Decision (ADR-lite)

- **Context**: 阅读器多项体验问题需要修复，涉及加载、动画、搜索
- **Decisions**:
  1. Bug 1 二段式修复：先轻量过渡快速上线，再深度 isolate 彻底根治
  2. Bug 3 采用 MD3 门控方案（阻断），而非补动画方案
  3. Bug 4 对齐 MD3 原版行为，不做定制化差异
  4. Bug 5 保留离线搜索代码，仅调整 UI 展示
- **Consequences**: Bug 3 门控可能让用户在排版完成前（~100-200ms）有短暂不可操作感；Bug 1 深度修复涉及 Isolate 通信复杂度

## Out of Scope

- 彻底重写仿真翻页模块（仅修正 touchY override 和 ColorFilter）
- 删除搜索离线功能代码（保留代码，仅改 UI）
- 搜索本地+在线结果的去重合并

## Research References

- `research/md3-chapter-nav.md` — MD3 跨章翻页动画机制：isCompleted 门控 + 动画先行
- `research/md3-simulation-delegate.md` — MD3 仿真翻页阴影/拖拽对比：touchY override + ColorFilter 差异

## Technical Notes

- 阅读器主页: `flutter_app/lib/features/reader/reader_page.dart` (2867 行)
- 分页渲染: `flutter_app/lib/features/reader/page/page_view.dart` (461 行)
- 分页控制器: `flutter_app/lib/features/reader/page/page_view_controller.dart` (504 行)
- 仿真翻页: `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart` (832 行)
- 排版: `flutter_app/lib/features/reader/page/page_measure.dart` (243 行)
- 搜索: `flutter_app/lib/features/search/search_page.dart` (851 行)
- MD3 参考: `/root/data/workspaces/doro_FriendMessage_641981595/legado-with-MD3/app/src/main/java/io/legado/app/ui/book/read/page/delegate/SimulationPageDelegate.kt`
