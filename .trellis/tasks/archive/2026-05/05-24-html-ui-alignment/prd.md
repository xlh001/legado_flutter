# HTML设计规范对齐：全18页 UI 重构

## Goal

以 `uihtml/` 目录下 9 个 HTML 文件为设计标准，将 Flutter 项目**全部 18 个功能页面**的 UI 重构为与 HTML 一致的 MD3 风格（布局、间距、字号、颜色、交互）。

## Requirements

### 一档：有 HTML 直接对标（4页）

1. **我的页** (`my_hub_page.dart`):
   - AppBar 右侧加 `help` 图标按钮
   - 列表项: 图标 24px(primary色) + 标题 14px/w500 + 副标题 12px + 尾部操作(pill标签/开关)
   - 分组 header: 12px/w500/primary色 + letter-spacing
   - 分隔线: 0.5px, margin 0 16px

2. **搜索页** (`search_page.dart`):
   - AppBar: [arrow_back 返回] [搜索框 48px高/28px圆角/surfaceContainer底] [more_vert 菜单]
   - 搜索框内嵌: search图标 + TextField + arrow_forward_ios"下一个"小按钮
   - 菜单(PopupMenu): 精准搜索 checkbox + divider + 书源管理/多分组书源 + divider + 书源 radio list + divider + 日志
   - 历史标签: FilterChip 改为 小 Chip(12px字号/6px v-padding/16px圆角/surfaceContainer底)

3. **书源管理页** (`source_page.dart`):
   - AppBar: [arrow_back] [搜索框 28px圆角] [sort_by_alpha 排序] [filter_list 筛选] [more_vert]
   - 列表项: 20px checkbox + 图标 + 名称(14px/w500) + 副标题(12px) + Switch + 绿色圆点(8px) + open_in_new按钮 + more_vert按钮
   - 底部操作栏: 浅紫底 `#F3EEF9`/surfaceVariant, 高56px, [全选checkbox + "全选 (0/14)"] [反选 outlined按钮] [删除 outlined按钮] [more_vert]
   - 选择模式下顶部改为 "已选 N 项" + 关闭按钮

4. **阅读器控件** (`reader_page.dart` + reader/子控件):
   - **统一点击唤控模式**（暗色+亮色都用 overlay 弹出/隐藏）
   - 暗色模式: 黑色背景 `#000`, 正文 `#d0d0d0`, 18px/行高1.9, 控件层半透明黑底+blur
   - 亮色模式: MD3 绿色 surface 背景, 正文深色, 控件层同理
   - 控件层结构: 顶部栏(返回+书名+切换/刷新/下载/菜单) + 元信息行(章节+URL+来源badge) + 中间FAB(搜索/换源/设置) + 底部进度条(上章→thumb→下章) + 底部导航(目录/朗读/界面/设置)

### 二档：无 HTML 但按 MD3 风格统一（12页）

5. **RSS订阅** (5页: RssTabPage, RssFavoritesPage, RssSourceManagePage, RssArticleListPage, RssArticleDetailPage):
   - AppBar 统一: 图标按钮 48x48/圆角16px, 无 centerTitle
   - Card/ListTile 统一间距 padding:horizontal 16, vertical 12
   - 网格卡片: 圆角12px, elevation 1, aspect 2:3

6. **设置** (5页: SettingsPage, BackupPage, WebDavConfigPage, CacheManagementPage, ReadStatsPage):
   - 分组 header 统一: 12px/w500/primary色/padding(16,24,16,8)
   - SwitchListTile 统一无 track outline
   - Slider: track 4px, thumb 10px radius
   - 按钮: 圆角12px, padding(24,14)

7. **下载/远程书/替换规则/订阅源/书架管理/书信息编辑** (7页):
   - AppBar 统一风格
   - Card/ListTile 统一间距
   - FAB: 如果有, 圆角16px

### 三档：低优先级（2页）

8. **发现** (ExplorePage): 占位页适配 MD3 字体/颜色
9. **扫码导入** (QrScanPage): 扫描 overlay 边框/文字对齐

### 全局

- 默认 preset seed: `0xFF1565C0` → `0xFF006A4D`(绿)
- Dynamic color(Monet) 优先; 无动态取色时 fallback 绿色 seed
- 不改变任何业务逻辑/路由/Provider 结构
- 不破坏现有 ~421 个测试

## Acceptance Criteria

- [ ] 我的页: help 图标 + 列表项布局与 HTML 一致
- [ ] 搜索页: 返回+搜索框+菜单 布局 + 历史 Chip + 菜单内容 与 HTML 一致
- [ ] 书源管理页: 搜索框+排序/筛选/菜单 布局 + 列表项 checkbox/图标/开关/圆点/按钮 布局 + 底部操作栏 与 HTML 一致
- [ ] 阅读器: 暗色+亮色均点击唤出控件层，控件层布局与 HTML 一致
- [ ] 二档 12 页: AppBar/Card/ListTile/spacing 风格统一
- [ ] 默认 seed 改为绿色 `#006a4d`
- [ ] `flutter analyze` 0 issue
- [ ] `flutter test` 全部通过

## Out of Scope

- 书架页 UI (已对齐，不改)
- HTML 中的 JS 交互逻辑 (只对齐 UI 布局)
- 紫色主题独立实现 (全局统一用 dynamic color + 绿色 fallback)
- 阅读器常显控件模式 (统一用点击唤控)
- 功能行为变更 (只做 UI)

## Technical Notes

- 涉及 18 个文件 + 可能的 theme.dart 微调
- HTML 源: `uihtml/` 9 个文件
- 实施顺序: 我的 → 搜索 → 书源管理 → 阅读器 → RSS → 设置 → 其余
