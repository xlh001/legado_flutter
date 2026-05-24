# Quality and Anti-Patterns

What the Flutter app rejects and why.

## Reader 正确性边界 (BATCH-19a)

reader 模块踩过 4 个 B-正确性 finding（F-W2A-004/005/006/007），沉淀出三条契约。新代码踩到任一条直接 review 卡。

### `ReaderSettings` ==/hashCode 契约

`ReaderSettings` 是 `StateProvider` 持有的数据类，reader_page 在 `build` 内拿它做 `providerSettings != _settings` short-circuit。**没有 `==` override 时 != 永远是 true**（reference 不等），导致每帧 schedule postFrame 回写 + setState，PageView 动画期间一秒数十次空跑。

契约：

- 4 处字段集合必须一致：构造器 / `copyWith` / `toJson` / `fromJson` / `==` / `hashCode`。
- `==`：先 `identical(this, other)` 短路 → `other is! ReaderSettings` 类型检查 → 全字段比较。
- `hashCode`：`Object.hashAll([...全部字段])`。
- `List<int>` 字段（如 `tapZones`）必须用 `listEquals` 深比较 + `Object.hashAll(field)` 入外层 `hashAll`，否则 == 返回 false 但 hashCode 相等会撞键。
- 单测 `flutter_app/test/reader_settings_equality_test.dart` 用参数化 mutator 列表把每个字段轮一遍 != case + `set_dedup` size 校验。新增字段时**必须同时改**：构造器、copyWith、toJson、fromJson、==、hashCode、equality 测试 mutator 列表（共 7 处）；测试里的 `mutators.length == 31` 断言会在漏改时先红。
- 不引 freezed / build_runner——手写够用，构建链不被打扰。

### `replaceRuleGenerationProvider` 主隔离边界

`StateProvider<int>` 计数器每次 ReplaceRule CRUD 后自增，Rust 端缓存 key 是 `(db_path, generation)`。**不同 isolate 各自从 0 计数**会导致两个 isolate 都 bump 到 1 但规则集不同，缓存撞键命中错误版本。

契约：

- 所有调 `bumpReplaceRuleGeneration(ref)` 的代码路径必须在 main isolate。当前 100% 满足（`replace_rule_page.dart` UI CRUD + import flow），`download_runner` 不写规则。
- 如果以后引入 download isolate / worker isolate 写规则，必须升级为 `StateProvider<({String salt, int counter})>` 把 process-startup salt 也带进 cache key（短 hex 串足够），Rust 侧同步把 `cache_key` 拼接为 `(db_path, salt, counter)` 三元组。
- 不在 dart 端加 `assert(Isolate.current.debugName == 'main')`：`debugName` 在 release build 不可靠，依赖它做 production assertion 会引入误报。spec 文档化即可。

### `_onScroll` 防抖隔离原则

reader_page `_onScroll` 内同时挂三种独立路径，每路径节流策略不同。原版用一个 `_scrollDebounceTimer` 早 return 拦下整个函数 → 长程滚动期间章节标题不更新、append/prepend 不触发。

契约：

- **save 路径**（`_saveScrollPosition`）独占 `_scrollDebounceTimer`：500ms 节流，timer 在 fire 后置 null 让下次 `_onScroll` 重新 schedule。
- **visible chapter 更新路径**（`_updateVisibleChapter`）用 `_visibleChapterTimer ??= Timer(...)`：300ms 防抖，窗口内只 schedule 一次但**不被** save debounce 拦下。
- **反向滚动检测 + append/prepend 触发**：每帧执行，**完全不防抖**。临界滚动到边缘时立即追加下一章，否则用户滚到底等 500ms 才拼章节，体验差。
- 新加滚动路径时按"防抖窗口语义不同就独占 timer"原则拆，不要复用 `_scrollDebounceTimer`。


## Reader 性能边界 (BATCH-19b)

reader 模块踩过 2 个 C-性能 finding（F-W2A-011 / F-W2A-014），沉淀出两条契约。BATCH-19a 的正确性边界是**前置条件**——`ReaderSettings` 有 `==` / `hashCode` 后，下面的 listen 才能按字段相等性 short-circuit。

### build 顶层不 watch settings（rebuild 链路）

reader_page 的 settings 真正 source of truth 是 `_State._settings` plain field，子树都从 `_settings` 读；`readerSettingsProvider` 只是跨页面同步通道（设置页 slider、bookshelf 排序、字号长按调节回写）。

契约：

- `build` 顶层 **不** 调 `ref.watch(readerSettingsProvider)`，改用 `ref.listen<ReaderSettings>(readerSettingsProvider, (prev, next) {...})`：
  - listen 在 build phase 调用是合法的（Riverpod 文档明确支持），回调 post-build 触发，无需 `addPostFrameCallback` 包裹。
  - 回调内 `if (mounted && _readerSettingsLoaded && next != _settings) _setReaderSettings(next);` 把 provider 端变更同步到 plain field + setState 触发本组件 rebuild。
- `_setReaderSettings` 必须包 `setState(() => _settings = settings)`：listen 不会触发本组件 rebuild，需要显式 setState 推动子树看到新 `_settings`。
- 首帧值由 `initState` 的 `loadReaderSettingsFromDisk().then((s) => _setReaderSettings(s, markLoaded: true))` 兜底；listen 接管后续 provider 端变更。
- `ReaderSettings.==` 必须语义相等（BATCH-19a 已建）：listen 在稳态下因 `next != _settings` 短路，避免空跑。

为什么要这样：之前 `build` 顶层 `ref.watch(readerSettingsProvider)` 让 settings 任一字段变化都全树 rebuild ReaderPage，包括 `_buildPageBody` 的 PageViewWidget 和 `_buildContinuousBody` 的 ListView.builder——`PageViewWidget.didUpdateWidget` 自己再做字段比对决定是否重测，但 LayoutBuilder 已经被 rebuild 了一轮。改 listen 后只有真实变更（设置页 slider 调整等）才进入 `_setReaderSettings → setState` 单路径，rebuild 链路收敛。

### GlobalKey 反查保存恢复对称（paragraph index 精度）

滚动模式 paragraph index 的保存与恢复必须**走同一种算法**：cap 内 GlobalKey 反查 + cap 外估算 fallback。任一边只用估算另一边用反查会引入 ±1-2 段漂移，下次恢复 ensureVisible 落到错误位置。

契约：

- 保存路径（`_updateVisibleParagraph`）：
  1. 拿 `_listViewKey` 的 RenderBox 视口
  2. 遍历当前 visibleChapter 的前 `_kParagraphKeyCap` 个 `_paragraphKeys[_paragraphKeyId(ch.index, idx)]`，取第一个 `box.localToGlobal(Offset.zero, ancestor: listBox).dy >= 0` 的最小 idx
  3. 找不到（key 全在视口之上 / 全没 layout / 章超过 cap）→ fallback 到原标题 dy + 平均段高估算
- 恢复路径（`_restoreProgress`）已是这套（P2-13 提交时建立）：cap 内用 `Scrollable.ensureVisible(key.currentContext)`，cap 外用 `_scrollController.jumpTo(titleHeight + approxParagraphHeight * idx)`。
- `_paragraphKeyId(chapterIndex, paragraphIndex)` 返回 `'$chapterIndex|$paragraphIndex'`，构造路径（`_buildContinuousBody`）和 lookup 路径必须用同一个 helper，不要在 lookup 处手写字符串。
- GlobalKey lookup 必须先 `box?.hasSize == true` 过滤——子节点未 layout 时 `localToGlobal` 返回 dummy 值会污染查找。
- cap = 200 paragraphs 是长篇小说内存预算（每章只为前 200 段建 GlobalKey）。每次滚动 debounce 300ms 跑一次 200 key 遍历是 µs 级，可忽略。


## Reader 渲染边界 (BATCH-19c)

reader 模块踩过 2 个 C-性能 finding（F-W2A-012 子项 1 / F-W2A-013），沉淀出两条契约。BATCH-19a/b 是前置条件——`ReaderSettings.==/hashCode` + `ref.listen` 让稳态 setting 变更不进入 painter；本批进一步处理 painter 触发与 ChangeNotifier 时机问题。

### `_measureChapter` 末 phase-aware notifyListeners

`_measureChapter` 完成同步分页后必须把 `notifyListeners()` 路径根据当前 `SchedulerBinding.instance.schedulerPhase` 分流，而非一律 postFrame：

```dart
final phase = SchedulerBinding.instance.schedulerPhase;
final canNotifySync =
    phase == SchedulerPhase.idle || phase == SchedulerPhase.postFrameCallbacks;
if (canNotifySync) {
  if (!_disposed && _currentChapter?.chapterIndex == chapterIndex) {
    notifyListeners();
  }
} else {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!_disposed && _currentChapter?.chapterIndex == chapterIndex) {
      notifyListeners();
    }
  });
}
```

契约：

- **能同步则同步**：`SchedulerPhase.idle` / `postFrameCallbacks` 阶段同步 `notifyListeners` 不会 reentr build/layout/paint，直接消除"加载圆圈 → 空白章节 → 真正内容"三段闪烁——`build` 帧拿到的就是已 measure 完的 `pages` 而不是 `const []`。
- **build / layout / paint / persistentCallbacks 阶段保留 postFrame 兜底**：极少数路径会从 build 内（典型：Riverpod selector 在 build 内 read provider）触发 `loadChapter` → `_measureChapter`，此时同步 notify 会"setState during build"。postFrame 是兜底保险，不能省。
- 章节身份校验（`_currentChapter?.chapterIndex == chapterIndex` + `!_disposed`）两路径都保留：sync 路径理论上不会脏，但写法对称避免日后 refactor 漏漏；postFrame 路径用户可能在帧间已切走章节。
- 已通过 `flutter test`（baseline 523）回归验证：sync 路径在 widget test 跑 reader UI 不触发 setState during build assert。

### AnimatedBuilder Listenable 拆层评估结论（保留合并）

`page_view.dart` 的 `AnimatedBuilder(animation: Listenable.merge([controller, animController]))` 经评估**不拆**，原因：

`PageViewController.notifyListeners` 7 个调用点全部是离散低频用户/系统事件：

| 调用点 | 触发场景 | 频率 |
|---|---|---|
| `setNeighborChapter` | 外层灌入邻章后 | 跨章 1 次 |
| `commitToNextChapter` / `commitToPrevChapter` | 跨章动画完成 | 跨章 1 次 |
| `jumpToPage` | TOC / 跳页 | 用户操作 1 次 |
| `goToNextPage` / `goToPrevPage` | 章内 tap / 翻页完成 | 用户操作 1 次 |
| `_measureChapter` | 章节加载 / 设置变化 | 加载 1 次 |

并发上限 ≈ 用户连续 tap 频率（≤ 3-5 次/秒）。合并 listenable 引入的"无效 painter rebuild"——controller notify 触发 `_PageViewPainter` rebuild 但 `shouldRepaint` 多数字段相等——成本可忽略。

嵌套方案（外 anim-only `AnimatedBuilder` / 内 controller-only `AnimatedBuilder`）每帧 anim 推进时**仍**重建内层 builder + painter，只在 anim **未跑**期间收益（controller 单独 notify 不触发 painter）；考虑到非 anim 期 notify 频率本来就低，嵌套引入的可读性成本不划算。

复评触发条件：

- 若未来引入 controller 高频更新（滚动进度条同步 / 实时书签 hover 高亮 / 朗读高亮等），单 `notifyListeners` 频率超过 10 次/秒，重新拆嵌套 `AnimatedBuilder`，此时外层只听 `_animController` 驱动 anim 帧、内层只听 `controller` 处理新增高频源。
- 若 `_PageViewPainter.shouldRepaint` 比对字段大幅扩张（>20 字段）、单次比较成本上升到不可忽略，也是触发条件之一。
- 若新增 listenable（DragDelegate 单独的 ValueNotifier 等），优先用 `Listenable.merge` 加进去而不是嵌套 builder。

### `_calcPoints` 早退缓存与 LinearGradient shader 缓存评估结论（Resolved-by-Design / 不动）

`SimulationPageDelegate._calcPoints` 与 `draw` 内 4 处 `ui.Gradient.linear` 经评估**不加缓存**，原因：

仿真翻页 painter 的实际重绘路径只有 3 类：

| 路径 | currentTouch 行为 | painter `shouldRepaint` | 早退 / shader 缓存命中 |
|---|---|---|---|
| 用户 drag 期间 | 跟手指每帧变（slop 越过后） | `isRunning=true` 必返 true | `_calcPoints` guard 不命中（touch 每帧不同）；shader 缓存键也每帧 miss |
| tap 触发的 anim 期间 | 由 `_animStartTouch` → `_animTargetTouch` lerp，每帧不同 | `isRunning=true` 必返 true | 同上 |
| anim 完成后 idle | currentTouch 不再变 | `isRunning=false` + 字段相等返 false → **draw 不被调用** | guard / 缓存都触不到 |

drag / anim 是仿真翻页**唯一**的 painter 热路径；这两条路径上 `currentTouch` 每帧都不同（手指位置 / lerp 进度），早退 guard 永远 miss。idle 期 painter 的 `shouldRepaint` 已经把 `currentTouch` / `direction` / `animProgress` 加进比较，外层 `AnimatedBuilder` 触发时 `shouldRepaint` 返 false → `paint` 不会被调用 → 也不存在"draw 被多调一次需要 guard 拦掉"的问题。

LinearGradient shader 缓存的 cache key 必须包含 `(_isRtOrLb, _bs1x, _bs1y, _bc1x, _bc1y, _bc2x, _bc2y, _be1x, _be1y, _be2x, _be2y, headColor, tailColor)`——这些坐标全部由动态 `currentTouch` 派生，drag/anim 期每帧不同，**与 `_calcPoints` guard 同样的 miss 率**。同 file 注释已承认 LinearGradient shader 创建"开销可控"。

复评触发条件：

- 加上 fps 基线测试（widget benchmark 或 driver 追 frame budget），实测仿真翻页在 60Hz / 120Hz 设备上跑出 jank、且 profile 抓出热点确实落在 `_calcPoints` 的 atan2/sqrt 或 shader 创建上时，再回头评估。
- 若仿真翻页改 anim 模型（不再每帧 lerp currentTouch，而是固定帧数离散推进 + 中间帧复用同一几何），则早退 guard 命中率提升，那时再加。
- 若 `_calcPoints` 输出几何被多个 painter 共享（目前只有 simulation 一个用），缓存收益放大，也是触发点。


## Lint Bar

`flutter_app/analysis_options.yaml` enables the default flutter_lints set with project-specific tightenings. `flutter analyze` must report **0 issues** before any commit.

When you must use `// ignore:`:

- Always include the lint name (`// ignore: invalid_use_of_protected_member`).
- Always add a one-line comment explaining why.
- Reserve `// ignore_for_file:` for generated code only.

Example used by `core/widgets/safe_setstate.dart`:

```dart
// ignore: invalid_use_of_protected_member
setState(fn);
```

This is acceptable because the extension is a thin syntactic wrapper. New `// ignore` lines that don't have a similar justification will be flagged.

## Forbidden Patterns

| Pattern | Why | Reference |
|---|---|---|
| `if (mounted) setState(() => ...)` inside `lib/features/` | 31 sites collapsed to `safeSetState`. Reintroduction breaks the convention. | BATCH-25 sweep |
| `getApplicationDocumentsDirectory()` outside `core/persistence/` | Bypasses the resolver + test hook. | BATCH-18e |
| `File('$dir/foo.json').readAsString` for new persistence | Bypasses `_Mutex` write serialization. | BATCH-18c json_store |
| `final dynamic raw = n; return raw is int ? raw : raw.toInt() as int;` | Use `platformInt64ToInt(n)` instead. | BATCH-24 |
| Hand-rolled `_formatRelativeTime` | Use `formatRelativeTime(int sec)` from `core/util/time_format.dart`. | BATCH-24 |
| Re-implementing the import-summary label string | Use `formatImportSummaryLabel(...)`. | BATCH-24 |
| Single-line `return author.isEmpty ? '未知作者' : author;` for fallback display name when there is a richer helper | Keep small inline helpers in feature when truly local; promote when 2nd caller appears. | BATCH-24 promotion rule |
| Using `print` / `debugPrint` for production logs | Use `core/perf_monitor.dart` or `tracing` (via FRB) for telemetry. `debugPrint` is fine for dev-time hints. | n/a |
| `setState` after `await` without a mounted check | See [async-and-mounted](./async-and-mounted.md). | BATCH-25 |
| Two providers exposing the same conceptual value | Derive one from the other. | BATCH-18d (`fontSizeProvider`) |
| Writing passwords / API tokens / WebDAV credentials / 备份密码 to `settings.json` / `legado_local.json` / 任何 per-feature `*.json` | Use `core/security/secure_storage.dart` (`writeSecret/readSecret/deleteSecret`). See "凭据保险柜 (Credential Vault, BATCH-03 / BATCH-03b)" below. | BATCH-03 / BATCH-03b |
| `Map<String, String>!` accessor pattern (`cfg['url']!`) for known-shape config | Use a file-private data class with `final` fields. The config "shape" should be encoded in the type, not implied via `!`. | BATCH-03 (`_WebDavCredentials`) |
| `Uri.parse(remoteUrl)` 不经 `enforceWebViewScheme` 直接走 `loadRequest` / `dio.get` | 让 `file://` / `javascript:` / `data:` 越界 scheme 进 webview 是 SSRF / 任意代码执行入口。任何远端 URL 必经 scheme 白名单。 | BATCH-05 (`webview_safety.dart`) |
| New webview caller uses `JavaScriptMode.unrestricted` without ADR | reader is the only business-justified case; new callers default to `disabled` and must document the necessity. | BATCH-05 |
| JS 返回值 fallback `text.substring(1, text.length - 1)` 粗暴去引号 | 在 JSON-string 含转义时丢内容；用 `safeJsResultDecode(rawResult)`。 | BATCH-05 (F-W2A-010) |
| `record['x'] = newValue` 原地修改 list-of-maps 元素 | 列表上多个 caller 持原 record 引用时 mutation aliasing；用 `_records = List.of(_records)..[idx] = {...record, 'x': newValue}` immutable update。 | BATCH-21 (F-W2B-014) |
| 多 future 调用入口缺 seq token | 用户连续触发同一 async action（搜索、刷新）时旧 future 后完成会"幽灵"覆盖新结果；加 `int _xxxSeq` 自增 token + 每个 await 后 `seq == _xxxSeq` 校验 + finally 内同样校验。 | BATCH-21 (F-W2B-019) |
| TabBarView children 直接 `[for t in _tabs _buildXxx(...)]` method 返回 | 父 setState 让所有 tab 同时 rebuild + 切走的 tab 丢 scroll position；抽 `_XxxTabView` `StatefulWidget` + `AutomaticKeepAliveClientMixin`，build 内调 `super.build(context)`。 | BATCH-21 (F-W2B-013) |
| `ref.read(xxxProvider.notifier).state = value` inside `initState` (ConsumerState) | 触发 "Tried to modify a provider while the widget tree was building" 运行时异常。必须用 `Future.microtask(() => ref.read(xxxProvider.notifier).state = value)` 或在 `addPostFrameCallback` 中修改。 | BATCH-05-24 |
| `Slider` widget without `Material` ancestor in custom overlay | 导致 "No Material widget found" 红屏 + 底部 RenderFlex overflow。任何不在 Scaffold/AppBar 内的 `Slider` 必须包 `Material(type: MaterialType.transparency, child: ...)`。 | BATCH-05-24 |
| `OverlayEntry` 用 `GestureDetector(behavior: HitTestBehavior.translucent)` 做 dismiss | `translucent` 让菜单项 tap 同时触发 dismiss handler → 菜单点一下就消失且无法重开。菜单背景用 `opaque` + 菜单本体包独立 `GestureDetector(onTap: () {})` 吸收 tap。 | BATCH-05-24 |
| 阅读器控件用 `SafeArea` 包裹全屏覆盖层 | 导致控件栏无法覆盖状态栏/导航栏区域。`SafeArea` 只包阅读正文，控件覆盖层放在 Stack 同级（不受 SafeArea 限制），内部用 `MediaQuery.padding.top/bottom` 手工留空间给系统图标。 | BATCH-05-24 |
| 控件覆盖层用 `AnimatedSlide` 做滑入/滑出动画 | `AnimatedSlide` 内部用 `FractionalTranslation`，导致控件背景无法铺到屏幕边缘。仅用 `AnimatedOpacity`（淡入淡出）即可；滑入动画不值得为边缘覆盖问题买单。 | BATCH-05-24 |

## 凭据保险柜 (Credential Vault, BATCH-03 / BATCH-03b)

**敏感字段必须走 `core/security/secure_storage.dart`，不允许进 `settings.json` / per-feature `*.json` / FRB string payload**。canonical 例子：WebDAV password（BATCH-03）+ Legado 备份密码（BATCH-03b）。

凭据存储主题已闭环：F-W2B-001（webdav password）+ F-W1A-020（backup password）全部 Resolved。

### 何为「敏感字段」

- 用户密码、API token、设备私钥、OAuth refresh token、HTTP basic auth credential、WebDAV password、Legado 备份密码。
- 反例（**非敏感**，仍可走 `json_store`）：URL / username / device-name / preference flags / cache keys / search history。

### key 命名空间

| key | 引入批次 | 旧路径 |
|---|---|---|
| `webdav_password` | BATCH-03 (F-W2B-001) | webdav.json `password` 字段 |
| `webdav_password_<id>` | BATCH-27c-2 | servers.json 内每个 server 的 password；`<id>` 是 millis since epoch（`DateTime.now().millisecondsSinceEpoch`，对齐 legado `Server.id`）|
| `backup_password` | BATCH-03b (F-W1A-020) | legado_local.json `password` 字段（FRB `set/get_backup_password`） |

### IO 路径

```dart
// 写
import 'package:flutter_app/core/security/secure_storage.dart';
await writeSecret('webdav_password', controller.text);
// 顺手把非敏感字段单独走 json_store，不混在一起
await writeJsonFile('webdav.json', { 'url': url, 'user': user, 'deviceName': dev });

// 读
final pwd = await readSecret('webdav_password') ?? '';

// 删除（写 null 或空串等价）
await writeSecret('webdav_password', null);
// 或者
await deleteSecret('webdav_password');
```

后端：Android = `EncryptedSharedPreferences` (AES-256/GCM, key in Keystore，flutter_secure_storage v9 默认，与 minSdk 23+ 对齐)；iOS = Keychain；其它平台由 `flutter_secure_storage` 内置默认（不在主线优先级）。

### 测试钩子

```dart
import 'package:flutter_app/core/security/secure_storage.dart';
import '_secure_storage_fake.dart';

setUp(() {
  setSecureStorageOverrideForTest(InMemorySecureStorage());
});

tearDown(() {
  setSecureStorageOverrideForTest(null); // 恢复 production 实现
});
```

`InMemorySecureStorage` 在 `flutter_app/test/_secure_storage_fake.dart`，是共享 fake；不要在每个测试文件各自重写。

### 为什么 top-level fn override 而不是 ProviderScope

`secure_storage` 是 cross-feature 工具（凭据全局唯一），不绑业务 Provider；与 `core/persistence/json_store.dart` 一致用 top-level fn + `setXxxOverrideForTest` 钩子。这与 BATCH-20 的「features 用 service provider + ProviderScope.overrides」不矛盾——后者针对**业务领域**（FRB 调用、文件选择等），前者针对**基础设施**。

### 迁移路径模板

旧版本可能把敏感字段写在普通 JSON 里（典型：webdav.json 含 password）或通过 FRB 写入 Rust 端管理的 JSON 文件（典型：legado_local.json 中 backup password 由 `set/get_backup_password` 操作）。迁移逻辑放对应 page 的 `_loadConfig`（页面入口），首次访问触发一次性搬迁，幂等。

#### 模板 A：旧字段在 dart 直读 JSON（webdav.json 模式 / BATCH-03）

```dart
final map = await readJsonFile<Map<String, dynamic>>(...);
final legacyPwd = (map['password'] as String?) ?? '';
final securePwd = await readSecret('webdav_password');

if (legacyPwd.isNotEmpty && securePwd == null) {
  // 一次性迁移：写入保险柜 + 重写 json 去掉敏感字段
  await writeSecret('webdav_password', legacyPwd);
  await writeJsonFile('webdav.json', {
    'url': map['url'], 'user': map['user'], 'deviceName': map['deviceName'],
    // password 不再写入
  });
}
```

#### 模板 B：旧字段在 Rust 端 FRB 管理（legado_local.json 模式 / BATCH-03b）

旧路径无法 dart 直接读 JSON（字段由 Rust 端 helper 管理 + 文件可能有损坏 .bak 兜底机制）；走 FRB read → secure_storage write → FRB write 空串清理的三步迁移。

```dart
final securePwd = await readSecret('backup_password');
if (securePwd != null) {
  _backupPwdCtl.text = securePwd; // 命中直接用
} else {
  try {
    final legacyPwd = await rust_api.getBackupPassword(documentsDir: dir);
    if (legacyPwd.isNotEmpty) {
      await writeSecret('backup_password', legacyPwd);
      try {
        await rust_api.setBackupPassword(documentsDir: dir, password: '');
      } catch (_) {
        // 清理失败不阻塞迁移；下次启动 secure_storage 命中即可
      }
      _backupPwdCtl.text = legacyPwd;
    } else {
      _backupPwdCtl.text = '';
    }
  } catch (_) {
    _backupPwdCtl.text = ''; // 桥未初始化等异常退回
  }
}
```

Rust 端 FRB（`set/get_backup_password`）保留 binary contract（funcId 71/72）以备未来 backup zip 加密复用，doc 标 deprecated 注释（**不**加 `#[deprecated]` attr —— Dart 端迁移路径仍要调）。新代码读写备份密码请走 `readSecret / writeSecret('backup_password')`，不要重新调 FRB。

#### 幂等保证

第二次启动 `securePwd != null` 命中 secure_storage 短路返回；模板 A 的 `writeJsonFile` 永不再带敏感字段；模板 B 的 FRB read 拿到空串后不再触发清理路径。三种状态机均收敛到稳态。

### Forbidden 反向

- ❌ `await writeJsonFile('webdav.json', { 'password': pwd, ... })` — 把密码混进普通 JSON
- ❌ `await writeJsonKey('webdav_password', pwd)` — 写 settings.json 也不允许
- ❌ FRB API 把 password 当 String 透传 + Rust 端写普通文件（F-W1A-020 备份密码即此问题，BATCH-03b 已闭环；新增凭据字段不要再走这条路）
- ❌ 在 widget test 直接构造 `FlutterSecureStorage()` 跑——会触发 platform channel `MissingPluginException`；用 `setSecureStorageOverrideForTest(InMemorySecureStorage())`


## WebView / Untrusted-Network 边界 (BATCH-05)

**所有把远端 untrusted URL / HTML / JS 引入应用的入口必须走 `core/security/webview_safety.dart`**。canonical 例子：reader webview / RSS 文章 webview / QR 扫码 fetch。

### 何时算"untrusted 入口"

- 任意 URL 来自书源 JSON、订阅源 JSON、RSS 源、扫码二维码、用户粘贴的 deep link
- 任意 HTML / JS 字符串来自远端 HTTP 响应、书源解析结果、用户导入的文件
- 任意 dio.get / WebView.loadRequest 的目标 URL，只要 URL 不是项目 hardcoded 的 host

### IO 路径

```dart
import 'package:flutter_app/core/security/webview_safety.dart';

// 1. scheme 白名单防线 —— 任意 Uri.parse(remoteUrl) / dio.get(url) 之前必经
enforceWebViewScheme(url);  // 越界 throws WebViewSafetyException

// 2. host 风险分类 —— UI 决定是否警告 / 拒绝
final hostClass = classifyHost(url);
if (hostClass == HostClass.privateNetwork) {
  showSnackBar('⚠️ 警告：这是内网/本地地址');
}

// 3. 项目统一 UA —— 不暴露 webview-flutter 默认 UA 指纹
final headers = {'User-Agent': defaultUserAgent()};

// 4. JS 调用返回值的安全解码 —— 不再粗暴 substring(1, len-1) 去引号
final content = safeJsResultDecode(rawJsResult);
```

### JS Mode 由 caller 决定

`webview_safety.dart` **不**强制 JS mode：

| Caller | JS mode | 原因 |
|---|---|---|
| reader (`platform_webview_executor.dart`) | `unrestricted` | 业务必须 —— 远端 webJs 规则要跑（selector / DOM 改写 / cookie 读取） |
| RSS 文章 (`rss_article_detail_page.dart`) | `disabled` | 仅展示订阅文章 HTML，不需要远端 script 执行 |
| 新增 caller | 默认 `disabled` | 新 caller 必须显式 opt-in `unrestricted` 并在 ADR 里说明业务必要性 |

reader webview 保留 unrestricted JS 是 ADR 决定，文档化在 `PlatformWebViewExecutor` class doc。

### NavigationDelegate（RSS / 非 reader caller）

跨 host 导航默认拒绝，避免用户在文章 webview 内点击外链时让攻击者控制的页面进 webview：

```dart
controller.setNavigationDelegate(NavigationDelegate(
  onNavigationRequest: (req) {
    try {
      final reqHost = Uri.parse(req.url).host;
      final baseHost = Uri.parse(baseUrl).host;
      if (reqHost.isEmpty || baseHost.isEmpty || reqHost == baseHost) {
        return NavigationDecision.navigate;
      }
      return NavigationDecision.prevent;
    } catch (_) {
      return NavigationDecision.prevent;
    }
  },
));
```

外链应在后续批次用 `url_launcher` 跳系统浏览器，更安全。

### QR 扫码 host 警告

二维码扫到的 URL 在 confirm dialog 里多显示一行 host 类警告（loopback / linkLocal / privateNetwork 红字提示），让用户辨别 SSRF 攻击。`enforceWebViewScheme` 在 protocol parser 入口就拦下越界 scheme（`legado://import/...?src=file:///...` 直接当"未识别"返回 null）。

### dio body / Content-Type 边界

QR 扫码 `_fetchText` 加：

- 10 MB body cap（防恶意源推大流量）
- Content-Type allow-list（`json` / `text/plain` / `application/octet-stream` / 空）—— 防被骗下载二进制

`QrImportHandler.validateFetchedBody(body, contentType)` 是 `@visibleForTesting` 静态方法，单测验证边界。

### Forbidden 反向

- ❌ 直接 `Uri.parse(remoteUrl)` 不经 `enforceWebViewScheme` —— 让 `file://` / `javascript:` / `data:` 等越界 scheme 进入 webview
- ❌ 新增 webview caller 默认 `JavaScriptMode.unrestricted` 而无 ADR
- ❌ 把 dio 的 `.get(remoteUrl)` 当 trusted —— 不加 timeout / body 上限 / Content-Type 校验
- ❌ JS 返回值解码 fallback 写 `text.substring(1, text.length - 1)` 粗暴去引号 —— 用 `safeJsResultDecode`
- ❌ 把 reader webview 的 `unrestricted JS` 决定 copy-paste 到新 caller —— reader 是业务豁免，新 caller 默认 disabled

### 测试钩子

`webview_safety.dart` 是纯函数，无需 override 钩子；在 widget test 里直接调 `enforceWebViewScheme('https://x') / classifyHost('http://192.168.1.1')` 即可。caller-level 测试（如 `qr_scan_page_test.dart`）通过既有 `*Override` 钩子覆盖（`scanResultOverride` / `permissionDeniedOverride` 等）。

### WebView dispose 清理 + IPv6/IPv4 完整 (BATCH-05b)

**WebView caller dispose 契约**：所有 `WebViewController()` 持有方都必须 override `dispose()` 调
`controller.clearCache().catchError((_) {})` + `controller.clearLocalStorage().catchError((_) {})`
后再 `super.dispose()`。webview_flutter 4.13 起跨 Android/iOS 统一支持。
异步 Future 不 await（dispose 不能 async），失败静默。

适用 caller：

- `core/platform_webview_executor.dart::_WebViewExecutionPageState` (reader webview rule executor)
- `features/rss/rss_article_detail_page.dart::_RssArticleDetailPageState` (RSS 文章 webview)

未来新加的 caller 加进表。

**`classifyHost` 与 Rust `ssrf_guard::is_url_safe_for_fetch` 对齐**：
两边 host 分类范围必须保持一致，参考 `core/core-source/src/legado/ssrf_guard.rs:86-110`。
当前覆盖：

| 分类 | IPv4 | IPv6 |
|------|------|------|
| loopback | 127.0.0.0/8, 0.0.0.0/8, localhost | ::1, ::ffff:127.x.x.x |
| linkLocal | 169.254.0.0/16 | fe80::/10 |
| privateNetwork | 10/8, 172.16/12, 192.168/16, 100.64/10 (CGNAT), 224.0.0.0/4 (multicast) | fc00::/7 (ULA), ff00::/8 (multicast), ::ffff:RFC1918 (mapped) |

IPv4-mapped IPv6 (`::ffff:host`) 走 IPv4 重分类，避免攻击者用 `::ffff:127.0.0.1` 绕过 IPv4 检查。


## 列表 reactivity 模式 (BATCH-21)

**TabBarView 多 tab 列表、list-of-maps 局部 update、长 async 链路下的旧 future 防护**三个高频场景在 RSS / search 主题集中出现。BATCH-21 把它们的最小防御模板沉淀下来。

### KeepAlive vs StateProvider.family 选择

| 场景 | 推荐方案 |
|---|---|
| TabBarView children 直接 method 返回 widget，setState 重建 → 多 tab 同时 build + scroll position 丢 | 抽 `_XxxTabView extends StatefulWidget` + `AutomaticKeepAliveClientMixin`（退而求其次） |
| 同上 + 单 tab 数据需要细粒度订阅 / 跨页面共享 | `StateProvider.family((sort))` per-tab（最优，但侵入大） |

`AutomaticKeepAliveClientMixin` 模板：

```dart
class _XxxTabView extends StatefulWidget {
  final String sortName;
  final List<Map<String, dynamic>>? articles;
  // ... callbacks ...
  const _XxxTabView({super.key, ...});

  @override
  State<_XxxTabView> createState() => _XxxTabViewState();
}

class _XxxTabViewState extends State<_XxxTabView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // KeepAlive 必须，否则 mixin 不生效
    // ... build body
  }
}
```

TabBarView children 用 ValueKey 锁 tab 名，让 tab 列表重排时正确复用：

```dart
TabBarView(
  controller: _tabController,
  children: [
    for (final t in _tabs)
      _XxxTabView(
        key: ValueKey('xxx_tab_${t.name}'),
        sortName: t.name,
        // ...
      ),
  ],
)
```

KeepAlive 让切走的 tab 保留 ListView state + scroll position。父组件 setState 重建 TabBarView 时，未激活 tab 不参与 build。

### Immutable update 模板

list-of-maps 局部更新单个元素：

```dart
// ❌ 反模式：原地修改 record map
setState(() {
  record['enabled'] = newValue;
});

// ✅ 推荐：immutable update
final idx = _records.indexOf(record);
if (idx < 0) return; // record 已不在列表（被另一 codepath 替换）
setState(() {
  _records = List.of(_records)
    ..[idx] = {...record, 'enabled': newValue};
});
```

`List.of(_records)` 复制顶层 list；`{...record, 'enabled': newValue}` 复制目标 record map。旧 `_records` / 旧 record 引用都不变 —— 多个 caller 持引用时拿到原值，不会被原地改写造成 mutation aliasing。

`indexOf` 用 reference equality（Map 没 override `==`），符合"找到 record 自身"语义；找不到 idx = -1 早返回不抛错。

### Future seq token 模板

用户连续触发同一 async action（搜索 / 刷新 / 加载下一页）时，旧 future 仍在跑（FRB 无 cancel API），后完成时会"幽灵"覆盖新结果。模板：

```dart
class _XxxState extends State<XxxPage> {
  int _xxxSeq = 0;

  Future<void> _doXxx() async {
    // ...入口校验 + 同步赋值...
    final seq = ++_xxxSeq;
    setState(() => _loading = true);
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      if (!mounted || seq != _xxxSeq) return;
      final data = await rust_api.fetchSomething(dbPath: dbPath);
      if (!mounted || seq != _xxxSeq) return;
      // ...处理结果，写 _data...
    } catch (e) {
      if (!mounted || seq != _xxxSeq) return;
      // ...处理错误...
    } finally {
      if (mounted && seq == _xxxSeq) {
        setState(() => _loading = false);
      }
    }
  }
}
```

每个 await 后判 `seq == _xxxSeq` 拦截旧 future；finally 内同样校验避免旧 future 把 _loading 改回 false。建议加 `@visibleForTesting int get debugXxxSeq => _xxxSeq;` 让 widget test 验证 seq 自增 + 旧值不被覆盖。

### 测试钩子（BATCH-21 范本）

- `rss_article_list_page_test.dart::BATCH-21 (F-W2B-013): KeepAlive` — 30 篇文章滚到中段 → 切 tab → 切回，验"标题 0"仍不可见（如 KeepAlive 失效会回到顶）
- `rss_source_manage_page_test.dart::BATCH-21 (F-W2B-014): immutable update` — 持原 record 引用，toggle 后断言原引用未被原地改写
- `search_page_test.dart::BATCH-21 (F-W2B-019): seq token` — 用 hanging dbInitializedProvider future 让两次 `_doSearch` 都悬停，验 `debugSearchSeq` 从 1 自增到 2，`debugLastSearchKeyword` 不被旧 future 覆盖


## 跨页通信模式 (BATCH-21c)

GoRouter `context.push<T>(...).then((result) { ... })` 是项目跨页通信首选模式。**不**为简单的"detail → list 状态回传"引入 Riverpod 跨页 `StateProvider` / `StateProvider.family`，避免无谓的状态管理复杂度。

### MarkReadResult 模式（detail → list 三态回传）

适用场景：detail 页有 optimistic state 需要 rollback / commit 决策；list 端按结果分支处理。BATCH-21c 用此模式收尾 F-W2B-012 — RSS list optimistic read_time 在 detail mark_read **失败**时主动 rollback。

```dart
// detail 端：top-level enum + state field 跟踪三种结果
enum MarkReadResult {
  success,  // 真正写库成功（含原本已读跳过的情况）
  failed,   // 写库抛异常（FRB / 网络 / db lock）
  skipped,  // 未走到写库（早返回 / 入参缺 / 状态已是目标值）
}

class _XxxDetailState extends ConsumerState<XxxDetail> {
  MarkReadResult _result = MarkReadResult.skipped; // 默认兜底

  Future<void> _bootstrap() async {
    // ...拉数据...
    if (条件) {
      try {
        await rust_api.markRead(...);
        _result = MarkReadResult.success;
      } catch (_) {
        _result = MarkReadResult.failed;
      }
    }
    // 不进 if 分支保持默认 skipped
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        appBar: AppBar(
          // 替换默认 leading 让 AppBar back 携带 result
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.pop(_result),
          ),
          // ...
        ),
      ),
    );
  }
}

// list 端：await context.push + 仅 failed 时 rollback
final result = await context.push<MarkReadResult>('/detail?...');
if (!mounted) return;
if (result == MarkReadResult.failed) {
  setState(() {
    article['read_time'] = 0; // rollback optimistic
  });
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('已读状态同步失败，下次刷新会重试')),
  );
}
// success / skipped / null（OS back）→ 保留 optimistic
```

### OS back 限制（已知 trade-off）

`PopScope.onPopInvokedWithResult` 在 OS back / 手势返回 / iOS swipe back 时 `didPop=true` 表示 pop 已发生，**无法**再携带 result。这条路径上 list 收到的 `result` 是 `null`，必须走 fall-back 软一致策略：保留 optimistic state，等下次刷新自然修正。

仅 **AppBar leading IconButton / 主动 `context.pop(result)`** 路径携带 result。

不适合扩展到"任何 detail 修改都要回传 list rollback"——detail 修改的 state 已是单一 source of truth（无 optimistic）时不需要这条通道。

### 三态 vs 两态

为什么 `success / failed / skipped` 而非 `bool`：
- `failed` 要 rollback；`success` 不要 rollback；`skipped` **也不要** rollback（db 状态未变）
- `bool` 表达不出 success vs skipped 的区别 —— skipped 路径 (article 原本已读 / link 空 / _error 早返回) 让默认 `false` 会被误判为 failed 触发 rollback
- enum 让 detail 端「未进 mark_read 分支」与「mark_read 抛错」语义分离

### 显式类型参数

GoRouter `context.push<T>(...)` 必须显式声明类型参数。无类型参数时返回 `Future<Object?>`，强转风险大；显式 `context.push<MarkReadResult>(...)` 让 Dart 直接推断为 `Future<MarkReadResult?>`（null 兜 OS back 路径）。

### 测试钩子（BATCH-21c 范本）

- `rss_article_detail_page_test.dart::BATCH-21c (F-W2B-012)` × 3 — markRead success / throws / skipped (already read) 三路径分别走 `MaterialApp.router(GoRouter(...))` push detail → tap leading back → 验 `Future<MarkReadResult?>` 落到对应枚举值
- `rss_article_list_page_test.dart::BATCH-21c (F-W2B-012)` × 3 — 把 `/rss-articles-detail` 路由 stub 成 `_DetailStubPage` 在 postFrame 立刻 `context.pop(returns)`，验 list 端在 failed → setState rollback + SnackBar；success / null → 保留 optimistic 不弹 SnackBar


## 页面布局对齐 (BATCH-26)

flutter_app 的顶层导航 + 二级页面入口位置以原 legado/ Android 项目为锚（仓内对照源码：`/root/data/workspaces/doro_FriendMessage_641981595/legado/`）。新增页面时优先按原版位置摆，避免重新出现 5/6 tab 蔓延或入口埋深。

### 4 tab destination 锚（对齐 `legado/main_bnv.xml`）

| index | path | builder | label | icon | selectedIcon |
|---|---|---|---|---|---|
| 0 | /bookshelf | BookshelfPage | 书架 | library_books_outlined | library_books |
| 1 | /explore | ExplorePage | 发现 | explore_outlined | explore |
| 2 | /rss | RssTabPage | 订阅 | rss_feed_outlined | rss_feed |
| 3 | /my | MyHubPage | 我的 | person_outline | person |

`StatefulShellRoute.indexedStack`，`initialLocation: '/bookshelf'`。任何想加第 5 个底栏 tab 的需求都先评估**能否归入「我的」hub 或现有 tab 顶部 menu**。

### My hub 14 项 + 3 分组（对齐 `legado/pref_main.xml`）

`flutter_app/lib/features/my/my_hub_page.dart` 是 `StatelessWidget`（不引 ViewModel/Provider），Body `ListView` 严格按下表 3 分组顺序：

**第一组（无 header）**：

| pref key | title | flutter 状态 | onTap |
|---|---|---|---|
| bookSourceManage | 书源管理 | ✓ | → /sources |
| txtTocRuleManage | TXT 目录规则 | ✗ 灰 | null |
| replaceManage | 替换净化 | ✓ | → /replace-rules |
| dictRuleManage | 字典规则 | ✗ 灰 | null |
| themeMode | 主题模式 | ✗ 灰（settings 内有真功能） | null |
| webService | Web 服务 | ✗ 灰 SwitchListTile（value:false / onChanged:null） | n/a |

**「设置」分组**：

| pref key | title | flutter 状态 | onTap |
|---|---|---|---|
| web_dav_setting | 备份与恢复 | ✓ | → /backup |
| theme_setting | 主题设置 | ✗ 灰 | null |
| setting | 其他设置 | ✓ | → /settings |

**「其它」分组**：

| pref key | title | flutter 状态 | onTap |
|---|---|---|---|
| bookmark | 书签 | ✗ 灰 | null |
| readRecord | 阅读记录 | ✓ | → /read-stats |
| fileManage | 文件管理 | ✗ 灰 | null |
| about | 关于 | ✗ 灰 | null |
| exit | 退出 | ✗ 灰（Flutter app 一般不需要） | null |

### 占位策略

未实现项**全部**走 `ListTile(enabled: false)` + onTap 不写（不弹 SnackBar，不显示「待实现」字样 — 灰显本身就是信号）。Web 服务保留 SwitchListTile 形态以视觉对齐原版「这是个 toggle」语义。

新功能落地时**只需把灰显项的 enabled / onTap 替换**，标题 + icon + 分组位置不要动 — 用户心智 = 原 legado。

### 不进 hub 的迁移项

按 R4 决策**不**进 hub，避免与 pref_main.xml 1:1 锚错位：

- 缓存/导出 → 书架 PopupMenu（对齐原 `main_bookshelf.xml` line 44-47 `menu_download` / `@string/cache_export`）
- RSS 源管理 / RSS 收藏 → RSS tab AppBar 顶部 IconButton（对齐 `main_rss.xml` 6/12/22 收藏 / 分组 / 设置三 always icon）
- 订阅源（RuleSub） / 二维码扫码 → 暂留 settings_page 工具段（属 BATCH-18f 重组）

### 过渡性双入口（spec 临时态）

BATCH-18f 在 settings_page line 183-229 加的「工具」段 6 项（备份/恢复 / 阅读统计 / 缓存管理 / RSS 收藏 / 订阅源 / 替换规则）与 26b 加的 hub 入口**双入口共存**。临时态 acceptable，让用户从两个习惯路径都能到达。

收敛节奏：等用户体感稳定后再开 26c/follow-up 删 settings 工具段，单入口由 hub 提供。在 26c 前**不要**单方面删 settings 工具段。

新加的管理类入口默认归入 hub，**不再**往 settings_page 工具段加新项。

### 测试钩子（BATCH-26b 范本）

- `my_hub_page_test.dart::BATCH-26b: hub 显示 14 项 + 3 分组结构` — `scrollUntilVisible` 验 14 项标题全可见 + 「设置」/「其它」section header
- `my_hub_page_test.dart::BATCH-26b: 灰显项 enabled false / SwitchListTile onChanged null` — viewport 800x2400 一帧构建后循环 8 项 ListTile + Switch 验
- `my_hub_page_test.dart::BATCH-26b: 已实现项 onTap` × 3 — 书源管理 / 替换净化 / 阅读记录；用 `routerDelegate.currentConfiguration.matches.last.matchedLocation` 验路由（go_router 14 的 `uri` 字段在 `imperative push` 下不更新）

### 底栏 tab 显隐 toggle (BATCH-26c)

对齐原 legado `pref_config_other.xml` 中 `showDiscovery` / `showRss` SwitchPreference + `MainActivity.kt:364-381` BottomNavigationView 重建逻辑，让用户在 `/settings`（即 hub「其他设置」）的「主页」分组中按需关闭「发现」/「订阅」tab。

**实现契约**：

- `flutter_app/lib/core/providers.dart` 提供 `showDiscoveryProvider` / `showRssProvider` 两个 `StateProvider<bool>`（default true，对齐原 `android:defaultValue="true"`）+ `loadShowDiscoveryFromDisk` / `saveShowDiscoveryToDisk` / `loadShowRssFromDisk` / `saveShowRssToDisk`（与 `searchPrecision` 同款 `readJsonKey<bool>` / `writeJsonKey` 模式）。
- `flutter_app/lib/main.dart` 在 startup `await loadXxxFromDisk()` + `ProviderScope.overrides` 注入，与 `themeMode` / `readerSettings` 同模式 wire。
- `flutter_app/lib/core/router.dart` 的 `_AppShell` 是 `ConsumerWidget`，**4 ShellBranch + initialLocation 完全不动**；动态部分仅在 `NavigationBar` 层：
  - `visibleBranchIndices` 用 `[0, if (showDiscovery) 1, if (showRss) 2, 3]` 派生
  - `selectedIndex` = `visibleBranchIndices.indexOf(navigationShell.currentIndex)`，未命中（用户当前在被隐藏 tab）→ clamp 到 0 兜住 NavigationBar 的负索引断言
  - `onDestinationSelected(viewIndex)` 调 `goBranch(visibleBranchIndices[viewIndex])` 走 view→branch 反查
  - `ref.listen(showDiscoveryProvider, (_, next) { if (!next && navigationShell.currentIndex == 1) WidgetsBinding.instance.addPostFrameCallback((_) => navigationShell.goBranch(0)); });` 同理 showRss → currentIndex == 2
- `WidgetsBinding.instance.addPostFrameCallback` 必须包：`goBranch` 触发 `StatefulNavigationShell` 的 `ChangeNotifier`，build 期间同步调会触发 setState during build；延一帧规避。
- `/explore` `/rss` 两个 GoRoute 路径**不删**——路由仍可直接 URL 访问（API server / deep link 兼容）；底栏 NavigationDestination 不展示而已，与原 legado `findItem.isVisible = showXxx` 语义对齐。

**测试钩子（BATCH-26c 范本）**：

- `show_tab_toggles_test.dart::BATCH-26c: default true → 4 destinations` — `tester.widget<NavigationBar>().destinations.length == 4` + 4 label findsOneWidget
- `show_tab_toggles_test.dart::BATCH-26c: showDiscovery=false → 3 destinations 且无「发现」`
- `show_tab_toggles_test.dart::BATCH-26c: showRss=false → 3 destinations 且无「订阅」`
- `show_tab_toggles_test.dart::BATCH-26c: 同时关 → 2 destinations 仅书架+我的`
- `show_tab_toggles_test.dart::BATCH-26c: 当前在 /explore 关 showDiscovery → 自动跳书架` — `routerDelegate.currentConfiguration.matches.last.matchedLocation == '/bookshelf'`，与 BATCH-26b `matchedLocation` 验法一致
- 测试用 `_TestAppShell` 复刻 `_AppShell` 逻辑（私有类不能跨文件复用）+ `ProviderScope.overrides` 注入初值 + `UncontrolledProviderScope + ProviderContainer.read(...notifier).state =` 触发 listen 路径，全程不依赖真实 router / path_provider / FRB

### 启动默认页 (BATCH-26d)

对齐原 legado `pref_config_other.xml:46-54` `defaultHomePage` NameListPreference + `MainActivity.kt:385-398` `upHomePage()`，让用户在 `/settings`「主页」分组里挑启动默认 tab（书架 / 发现 / 订阅 / 我的，4 选 1，default = 书架）。

**实现契约**：

- `flutter_app/lib/core/providers.dart:340` `enum DefaultHomePage { bookshelf, explore, rss, my }` + `extension DefaultHomePageX on DefaultHomePage { String get key, String get label, String get routePath, static DefaultHomePage fromKey(String) }`：
  - `key` 走 String 字面量（'bookshelf'/'explore'/'rss'/'my'）持久化，对齐原 SharedPreferences 字面量；不用 int index——加新 home page 时不会错位（与 BATCH-21c `MarkReadResult` 选 enum 而非 bool 同款理由）
  - `label` 中文（书架/发现/订阅/我的），对齐 `arrays.xml default_home_page` 显示文案
  - `routePath` 走 `/bookshelf` `/explore` `/rss` `/my`，与 router 4 ShellBranch 路径一致
  - `fromKey` 未知 / 空串兜底回 `bookshelf`，避免 settings.json 损坏导致启动崩
- `defaultHomePageProvider` 是 `StateProvider<DefaultHomePage>`，default `bookshelf`；`loadDefaultHomePageFromDisk` / `saveDefaultHomePageToDisk` 与 26c showDiscovery 同模式 `readJsonKey<DefaultHomePage>` / `writeJsonKey('defaultHomePage', v.key)`。
- `applyDefaultHomePage(GoRouter router, DefaultHomePage page, {bool showDiscovery, bool showRss})` 抽成 pure helper（providers.dart:431），便于单测；行为表对齐 `MainActivity.upHomePage()`：

  | enum | 行为 |
  |---|---|
  | `bookshelf` | 永远不跳（router default `/bookshelf`，原生 `"bookshelf" -> {}`） |
  | `explore` | 仅当 `showDiscovery == true` `router.go('/explore')`，否则保留 bookshelf 兜底（原生 `if (AppConfig.showDiscovery)`） |
  | `rss` | 仅当 `showRss == true` `router.go('/rss')`，否则同上（原生 `if (AppConfig.showRSS)`） |
  | `my` | 总是 `router.go('/my')`（my tab 永久可见，原生无条件 `setCurrentItem`） |

- `flutter_app/lib/main.dart:52-83` 启动 wire：
  - `await loadDefaultHomePageFromDisk()` + `defaultHomePageProvider.overrideWith(...)` 与 26c showDiscovery / 26b readerSettings 同模式（在 `ProviderScope.overrides` 列表末尾）
  - `addPostFrameCallback` 内**先** pendingRoute 兜底：命中 → `router.go(...)` + `clearPendingRoute()` + 提前 `return`，避免双跳
  - 无 pendingRoute 才走 `applyDefaultHomePage(router, defaultHomePage, showDiscovery: ..., showRss: ...)`
- `flutter_app/lib/features/settings/settings_page.dart:209` 「主页」分组下作为**第 3 项**（在 26c 2 SwitchListTile 下方）：`ListTile` + title「启动默认页」+ subtitle 显示当前 `ref.watch(defaultHomePageProvider).label` + onTap 弹 `_showDefaultHomePageDialog`。
  - 对话框模式：`SimpleDialog` + 4 个 `ListTile`（trailing `Icon(Icons.check)` 标当前选中），与 BATCH-19a `_showSortDialog` / 19a 决策一致（不用 deprecated 的 `RadioListTile.groupValue`）
  - 选完写 provider + `saveDefaultHomePageToDisk` + SnackBar「下次启动生效」，因为切换不立即跳（要重启）；选当前值 `if (picked == null || picked == current) return;` 早返回不弹 SnackBar
- 启动跳转用顶级 `router.go('/explore')` 而非 `navigationShell.goBranch(1)` —— startup postFrame 时 `_AppShell` 的 `navigationShell` 已 mount，但跨 ShellBranch 跳用 `router.go(path)` 由 GoRouter 自己定位 branch 更直接（且 `applyDefaultHomePage` 是 pure helper，无 widget tree 依赖便于单测）。

**测试钩子（BATCH-26d 范本）**：

- `default_home_page_test.dart::BATCH-26d: enum key 与 fromKey` × 3 — round-trip / 未知 String / 空串都兜回 `bookshelf`
- `default_home_page_test.dart::BATCH-26d: disk persistence round-trip` × 2 — `saveDefaultHomePageToDisk` 后 `loadDefaultHomePageFromDisk` 等价；空目录默认 `bookshelf`
- `default_home_page_test.dart::BATCH-26d: applyDefaultHomePage 行为表` × 6 — `bookshelf×4 toggle nest` / `my×4 toggle nest` 验「永远不跳 / 永远跳」，外加 `explore×{showD=T,showD=F}` / `rss×{showR=T,showR=F}` 验临界 → 共覆盖原版 4 分支契约（PRD §4 期望 16 组合粗概；nest loop 已覆盖 bookshelf/my 各 4，加 explore/rss 各 2 临界，对契约饱和）
- `default_home_page_test.dart::BATCH-26d: SettingsPage UI` × 4 — 默认 subtitle = 书架 / 点击弹 4 选对话框 / 选「发现」后 `provider.state == DefaultHomePage.explore` + SnackBar「下次启动生效」/ 选当前值不弹 SnackBar
- 测试用 `ProviderScope.overrides + UncontrolledProviderScope + ProviderContainer` 注入初值 + 真 `MockGoRouter`（仅记录 `go(path)` 调用栈），全程不依赖真实 router / path_provider / FRB
- 文件顶部 7 行注释说明 disk vs UI test 顺序约束：disk test 用 fire-and-forget save 在 fake-async zone 挂起会污染 module-level `_writeLock`；UI test 排在 disk group 之后规避

### Forbidden 反向

- ❌ 加第 5 个底栏 tab — 任何 hub 能容纳的内容都不该提为 tab
- ❌ 在新页面里复刻 settings_page 「工具段」式的 6 项二次入口 — 现有过渡态已饱和
- ❌ 灰显项加 onTap 弹 SnackBar — 灰显本身就是信号，多弹一层是噪声
- ❌ MyHubPage / ExplorePage / RssTabPage 引入 Provider — hub 当前是纯 StatelessWidget，未来加状态时先评估「真要 hub 自己持有 state，还是子页 state」
- ❌ 删除 `/explore` `/rss` ShellBranch 或顶级 GoRoute — toggle 关闭只动 NavigationBar 视图层，不动路由表（保留 API server / deep link / 直接 URL 访问能力，对齐原 legado MainActivity setVisible 语义）
- ❌ 在 `_AppShell` build 期间同步调 `goBranch` — 必经 `addPostFrameCallback` 延一帧，避免 setState during build
- ❌ 把 `defaultHomePage` 持久化为 int index — 必须走 String key（'bookshelf'/'explore'/'rss'/'my'）对齐原 SharedPreferences 字面量；加新 home page 时不会错位
- ❌ pendingRoute 与 defaultHomePage 双跳 — pendingRoute 命中后必须 `return` 提前，否则同一帧双 `router.go(...)` 行为未定义
- ❌ 在 `_AppShell` 内调 `applyDefaultHomePage(navigationShell.goBranch, ...)` —`applyDefaultHomePage` 是 pure helper（仅依赖 GoRouter），不应耦合 `StatefulNavigationShell`；保持启动跳转走顶级 `router.go(path)`

### bookshelf 顶部 menu (BATCH-27a)

对齐原 legado `app/src/main/res/menu/main_bookshelf.xml` 12 项 menu 定义 + `BaseBookshelfFragment.kt:96-121` handler 映射 + `BookshelfViewModel.kt:102-128` exportBookshelf 实现。

**13 项 PopupMenu 顺序（`bookshelf_page.dart` AppBar.actions）**：

| # | 中文 | flutter value | 处理 | onTap |
|---|---|---|---|---|
| 1 | 搜索 | — | AppBar IconButton（不进 menu） | `context.push('/search')` |
| 2 | 更新目录 | `update_toc` | 已实现（BATCH-27b，singleton runner + queue + 4 worker 并发 + AppBar transient badge） | `_onUpdateToc` |
| 3 | 添加本地书 | `import_local` | 已实现（batch-13） | `_onImportLocalBook` |
| 4 | 添加远程书 | `add_remote` | 已实现（BATCH-27c-1 单 server / 27c-2 多 server 切换 + CRUD / 27c-3 加多选批量下载 / 27c-4 加排序+搜索） | `context.push('/remote-books')` |
| 5 | 添加网络URL | `add_url` | 已实现（BATCH-27e，find_book_source_for_url funcId 118 → getBookInfoOnline + saveBook） | `_onAddUrl` |
| 6 | 扫码导入 | `qr_scan` | flutter 自加保留（与本地书 / 远程书同位） | `context.push('/qr-scan')` |
| 7 | 书架管理 | `bookshelf_manage` | 已实现（BATCH-27d 选择模式 + 4 actionbar 批量删除/允许更新/禁用更新/移到分组/清缓存；27d-followup 加分组 chips 筛选 + 峰胸长按区间选 + openReader toggle） | `context.push('/bookshelf-manage')` |
| 8 | 缓存/导出 | `cache_export` | 已实现（BATCH-26a） | `context.push('/downloads')` |
| 9 | 分组管理 | `manage_groups` | 已实现（保留 key 名 backward compat） | `GroupManageDialog` |
| 10 | 书架布局 | `bookshelf_layout` | 真功能 | `_showLayoutDialog` |
| 11 | 导出书架 | `export_bookshelf` | 真功能 | `_onExportBookshelf` |
| 12 | 导入书架 | `import_bookshelf` | 已实现（BATCH-27e，二选一粘贴/文件 JSON → searchWithSourceFromDb 多源循环 → saveBook） | `_onImportBookshelf` |
| 13 | 日志 | `log` | 灰显（无统一日志收集机制） | 不写 |

**灰显项判断准则**：

依赖未实现 FRB API（如 batch update_toc / search / WebBook）→ 灰显
依赖未实现页面（如远程书浏览 / 批量编辑）→ 灰显
依赖未引入的基础设施（如统一日志收集机制）→ 灰显

灰显项一律 `enabled: false` + **不写 onTap**（对齐 BATCH-26b 决策，灰显本身就是信号，不弹 SnackBar / 不显示「待实现」文案）。`PopupMenuItem.enabled: false` + 内嵌 `ListTile.enabled: false` 双重灰显，确保点击区域整体不响应。

**真功能契约**：

`_showLayoutDialog` — SimpleDialog + 2 ListTile（列表 / 网格）+ check trailing 单选模式，对齐 BATCH-19a `_showSortDialog` 同款（不用 deprecated `RadioListTile.groupValue/onChanged`）。选完写回 `_isGridView` plain field + setState + 持久化 `saveBookshelfGridViewToDisk(_isGridView)`，与现 AppBar `Icons.list/Icons.grid_view` IconButton 切换路径完全等价。选当前已选项早返回（`if (picked == null || picked == _isGridView) return;`）不重设状态。

`_onExportBookshelf` — 调 FRB `exportBookshelfJson(dbPath: ...)` 返回 JSON Array 字符串。空书架（pretty 序列化对空数组只输出 `[]`）→ SnackBar「书架为空」+ 早返回不写文件；非空 → 写入 `<documents_dir>/books.json` + SnackBar「已导出到 [path]」。`documents_dir` 优先 `widget.exportDocumentsDirectoryOverride` → `widget.documentsDirOverride` → `await resolvePersistenceDir()`。失败 catch + SnackBar「导出失败: [err]」，不向上抛打断书架页。

**FRB 端**（`core/bridge/src/api.rs:927`）：

```rust
pub fn export_bookshelf_json(db_path: String) -> Result<String, String>
```

参考 `export_all_sources` 同模式：`open_db` → `BookDao::get_all` → 序列化为 `[{name, author, intro}]`（缺失字段落回空串而不是 `null`，对齐原版 `BookshelfViewModel.kt:113-117 hashMapOf<String, String?>`）→ `serde_json::to_string_pretty`。空书架返回 `"[]"`（无换行）。

funcId 111，手编 `frb_generated.rs` wire impl + 4153/4291 后续 dispatcher arm。`build.rs` 的 `REQUIRED_WIRE_FN_FRAGMENTS` / `REQUIRED_DISPATCHER_FRAGMENTS` 已加 `wire__crate__api__export_bookshelf_json_impl` / `"        111 =>"` 守卫，避免下次 codegen 跑掉。

**测试钩子**：

`BookshelfPage` 新增两个测试 override 字段（与 batch-13 `pickFileForLocalImportOverride` / `importLocalBookOverride` 同款）：

- `Future<String> Function({required String dbPath})? exportBookshelfJsonOverride` — 注入假 FRB
- `String? exportDocumentsDirectoryOverride` — 注入假 documents 目录

**测试钩子（BATCH-27a 范本）**：

- `bookshelf_menu_test.dart::BATCH-27a: PopupMenu 13 items in original order` — 开 menu，遍历 12 项中文文案按原版顺序断言（搜索是 IconButton 不进 menu）
- `bookshelf_menu_test.dart::BATCH-27a: 6 disabled placeholder items have enabled=false` — `tester.widget<PopupMenuItem<String>>(find.byWidgetPredicate(...))` 验 6 项灰显 `.enabled == false` + 6 项真功能 `.enabled == true` 对照
- `bookshelf_menu_test.dart::BATCH-27a: layout dialog defaults to list with check` — 默认 `_isGridView=false` → 列表项 trailing `Icon(Icons.check)` + 网格项 trailing null
- `bookshelf_menu_test.dart::BATCH-27a: layout dialog selecting grid flips _isGridView` — 选「网格」→ AppBar IconButton 切到 `Icons.view_list`（视图状态切换）
- `bookshelf_menu_test.dart::BATCH-27a: layout dialog selecting current value is no-op` — 选当前已选项 → 不 setState，IconButton 仍是 `Icons.grid_view`
- `bookshelf_menu_test.dart::BATCH-27a: export empty bookshelf shows 书架为空 SnackBar` — `exportBookshelfJsonOverride: async => '[]'` → SnackBar「书架为空」+ 不写文件
- `bookshelf_menu_test.dart::BATCH-27a: export with books writes file + SnackBar shows path` — `exportBookshelfJsonOverride: async => fakeJson` → file.writeAsString 异步走 disk I/O，需 `tester.pump + tester.runAsync` 配合（fake-async zone 推 microtask + real-time wait disk）。SnackBar 验「已导出到 [path]」+ 文件内容字节级一致
- `bookshelf_menu_test.dart::BATCH-27a: export failure shows error SnackBar` — exportFn throw → catch 后 SnackBar「导出失败:」开头

测试目录用 `Directory.systemTemp.createTempSync('legado_flutter_test_export_27a_')` 而不是 `Directory.systemTemp.createTemp(...)` 异步版：后者在 widget test 里会让 `pumpAndSettle()` 莫名卡住（疑似 zone-microtask 与 widget tester 的 FakeAsync 冲突），同步版走 syscall 不进 zone-microtask 链路；同步建临时目录又能拿到唯一路径，避免 hardcoded `/tmp/...` 路径并发跑冲突 + 跨平台写权限差异。`addTearDown(() { if (dir.existsSync()) dir.deleteSync(recursive: true); })` 兜底清理。

### Forbidden 反向（BATCH-27a）

承接「Forbidden 反向」9 条之后，bookshelf 顶部 menu 主题再追加 3 条：

- ❌ 灰显项写 onTap 弹 SnackBar「未实现」/「待开发」/「敬请期待」— 对齐 BATCH-26b 决策，灰显本身就是信号，弹 SnackBar 是冗余噪声
- ❌ `export_bookshelf_json` FRB 改成返回 hardcoded fixture JSON 字符串绕过查 books 表 — 必须走 `BookDao::get_all` 真查，否则空书架与有书架行为不可分；测试假数据走 dart 端 `exportBookshelfJsonOverride`
- ❌ 修改现有 PopupMenuItem value key 名（`manage_groups` / `import_local` / `cache_export` / `qr_scan` / `bookshelf_layout` / `export_bookshelf`）— 保持 backward compat，让 onSelected 分支与 widget test 不必跟 UI 文案重命名同步重写

### 批量后台任务模式 (BATCH-27b)

对齐原 legado `MainViewModel.kt:96-180 upToc/startUpTocJob/updateToc` + `BaseBookshelfFragment.kt:98 activityViewModel.upToc(books)`。BATCH-27b 把 `menu_update_toc`「更新目录」从 27a 灰显占位真正落地，并沉淀范本：「批量后台任务」类需求（download / update_toc / 未来 batch-edit 批量删 / 批量移分组）共享 singleton runner + queue + StreamController + Notification 模式。

**架构契约**：

- **Singleton runner** + 私有 ctor + factory 返同一实例（`DownloadRunner._instance` / `UpdateTocRunner._instance` 范本）。runner 横跨页面 lifecycle，page dispose 不应清 runner state；测试用 `@visibleForTesting void resetForTest()` 在 setUp 重置。
- **Queue + Set in-flight 去重**：`Queue<JobT> _queue` + `Set<String> _inFlight`。enqueue 同 bookId 在 `_queue` 或 `_inFlight` 内已存在时跳过（不重复跑）。
- **Worker pool with `Future.wait`**：`final futures = List.generate(_kConcurrency, (_) => _worker())` → `await Future.wait(futures)`。worker 内 `while (_queue.isNotEmpty)` 循环取 job + 跑 + 静默 catch + emit progress。`_kUpTocConcurrency = 4` 是 Dart 端控（不在 Rust 端 Semaphore），让原版 16 默认下调 4 — 与 reqwest 连接池 + 单源限速达成平衡。
- **StreamController.broadcast()** 推 progress：`onProgress` Stream 让 page 端 `ref.listen` 或 `StreamSubscription` 监听，runner 完全不知 UI 结构。`isDone=true` 仅在批次末尾 emit 一次。
- **静默 catch + log + 总结 SnackBar**：单本失败 `debugPrint('[Runner] book X failed: ...')` + 计数 fail++，不向上抛。整批完成 `isDone=true` 时弹一次「目录刷新完成：成 X / 失 Y」。**禁单本 SnackBar 弹** — 4 worker 并发失败会刷屏。
- **AppBar transient badge**：仅 `progress.isRunning == true` 时渲染（`if (_isUpdatingToc) IconButton(child: Stack(CircularProgressIndicator + Badge('N/M')))`），跑完 `isDone` 时 setState `_isUpdatingToc = false` 自动消失。**点击不取消**（runner 当前不支持 cancel；UX 留 follow-up）。
- **listener 在 initState 挂 + dispose cancel**：`_updateTocSub = UpdateTocRunner().onProgress.listen(...)` initState 挂；dispose `_updateTocSub?.cancel()` 避免 page unmount 后旧 setState 触发。
- **关键：listener 内 invalidate providers + hideCurrentSnackBar + showSnackBar**：批次完成时 invalidate `allBooksProvider` / `booksByGroupProvider` 让 UI 重拉书；先 `hideCurrentSnackBar()` 清掉「已开始刷新」首条 SnackBar 让位给完成消息（默认 4s dismiss timer 仍在）。
- **enqueue 立即 emit 一次 progress=0/total**：让 transient badge 在 worker 第一帧就显示，不要等首本 job FRB 抓 toc（>1s）才触发首个 emit — 用户看起来「点了菜单没反应」。

**FRB 单本契约**：

```rust
pub async fn update_book_toc(db_path: String, book_id: String) -> Result<i32, String>
```

- **单本 FRB 而非批量 FRB**：批量会让事务原子性失真（一本失败时 rollback 整批 vs 提交部分）；单本独立失败语义更清晰。
- 流程：`BookDao::get_by_id` → `SourceDao::get_by_id(book.source_id)` → `parser.get_chapters(&source, &toc_url)` → `with_transaction(|tx| { ChapterDao::replace_by_book_preserving_content_in_tx + BookDao::upsert_in_tx(updated last_check_time + chapter_count) })`。
- 错误 context 走中文 `format!("书 {} 不存在", book_id)` / `format!("书源不存在: {}", source_id)` / `format!("书 {} 章节列表抓取失败: {}", book_id, e)`，对齐 `.trellis/spec/rust-core/error-handling.md`。
- 必须用 `replace_by_book_preserving_content_in_tx`（保 content cache）而不是 `replace_by_book_in_tx`（drop content）— 用户已读过的章节正文不应因目录刷新丢失。

**Dart 端 filter 契约**：

`!isLocal && canUpdate`：

- **isLocal 判断**：`source_id == null || source_id.isEmpty || source_id == 'local'`。`'local'` 是 import_local_book 落库时的 LOCAL_SOURCE_ID 字面量（`core/bridge/src/local_book.rs`），远程书 source_id 是真实 UUID 形态不会撞。
- **canUpdate**：`book['can_update']` 字段（snake_case，对齐 storage::Book serde 输出）。`bool false` / `num 0` 都视为不可更新，缺失字段默认 true（`Book.can_update` 默认 true，仅本地书 / 用户手动关闭时 false）。
- 空批 → 早返回 + SnackBar「当前 Tab 无可刷新的书」+ 不调 FRB。

**测试钩子（BATCH-27b 范本）**：

- `update_toc_runner_test.dart` × 8 — runner 单元测试（dedup / 4 worker concurrency / single failure does not block / progress sequence / total reset / empty list no-op / `UpdateTocProgress.isRunning` 三态 / debugPrint 不抛错）。setUp `runner.resetForTest()` 让 singleton state 测试隔离；TestWidgetsFlutterBinding.ensureInitialized() 抑制 NotificationService missing-binding 噪声。
- `bookshelf_update_toc_test.dart` × 4 — widget 测试（menu enabled + onSelected 触发 enqueue / filter local books → SnackBar「当前 Tab 无可刷新的书」/ transient badge 进度中显示 + 跑完消失 / 完成 SnackBar 显示 success/fail counts）。fakeFn 加 50ms 延迟让 worker 不在同一 microtask 完成，给「已开始刷新」首条 SnackBar 留 frame 显示。
- `bookshelf_menu_test.dart` BATCH-27a：update_toc 从 disabled list 移到 enabled list（27b 后只剩 5 项灰显占位）。
- 测试用 `updateBookTocOverride` 测试钩子（`UpdateBookTocFn` typedef）注入假 FRB，runner 内部 `worker` 调用 `(overrideFn ?? rust_api.updateBookToc)(...)`。**不**用全局 mock RustLib（mock 全局会让 parallel 测试互污染）。

**Forbidden 反向（BATCH-27b 新增 4 条）**：

- ❌ 批量 FRB（`update_books_toc(book_ids: List<String>) -> Result<List<i32>, String>`）— 事务原子性失真；要么整批 commit-or-rollback（一本失败让前 N 本努力白费）要么 commit 部分（与 Result<List, String> 形态矛盾，Err 时无法回传 partial 结果）。坚持单本 FRB。
- ❌ 全屏阻塞 `showDialog` 阻断 UI — 用户应能在跑批时切换 tab / 阅读其他书 / 看进度；阻塞 dialog 让 UX 退化为同步操作。AppBar transient badge + 后台 runner 是正确模式。
- ❌ 失败时单本弹 SnackBar — 4 worker 同时失败会刷屏；只在批次完成时弹一次总结 SnackBar 即可。
- ❌ 单 worker（`_kConcurrency = 1`）— 等于全串行，对齐原 legado 默认 16 应至少 4。Rust 端 `Semaphore` 控并发是另一条路，但项目当前选 Dart 端控（`Future.wait + List.generate(N)`）—— 简单、与 download_runner 串行模式形成对比、不需要改 FRB 签名。

### 批量任务 + Notification 通道契约

NotificationService 范本：每个批量任务一个固定 notificationId（download = 99000 / update_toc = 99001）。同 id 在 FlutterLocalNotifications `show()` 会替换，让单一任务的 progress notification 一直更新而不堆积；不同任务用不同 id 避免互相覆盖。

新增批量任务时：
- 选 unused notificationId（约定 99xxx，下一个 99002 / 99003 ...）+ 对应静态方法 `showXxxProgress(progress)` 仿 `showUpdateTocProgress`。
- ongoing/autoCancel 二段：跑批中 `ongoing: true + autoCancel: false + showProgress: true`；isDone `ongoing: false + autoCancel: true + showProgress: false`。
- iOS 跑批中 `presentSound: false`（不打扰）；isDone `presentSound: true`（提醒用户）。

### 远程书浏览模式 (BATCH-27c)

对齐原 legado `RemoteBookActivity.kt` + `RemoteBookViewModel.kt:97-180`。BATCH-27c-1 落地最小可用版（单 server / 单选 / 深度栈下钻），多选 / 排序 / 搜索 / multi-server / 已上架状态包 / `book.origin = webdav://<path>` 标记全部留 27c follow-up（避免 27c-1 范围蔓延，每条 follow-up 自成 batch）。

#### pathStack 维护契约

`_RemoteBooksPageState` 用 plain field `List<String> _pathStack` 维护当前路径，**不**走 GoRouter URL queryParameter（`/remote-books?path=/foo/bar`）—— 路径栈的每次下钻都进 history 会污染浏览器后退栈 + 跨启动恢复语义混乱。State 内栈是单页 ephemeral 状态，对齐原 legado `RemoteBookViewModel.dirList` Stack 行为。

OS back 拦截走 `PopScope(canPop: _pathStack.isEmpty, onPopInvokedWithResult)`：栈非空时 `didPop=false` → handler 内 `_popPathOrPage()` 上钻一层；栈空时 `canPop=true` 让默认 pop 关闭页面。AppBar leading 自定义 `IconButton(arrow_back)` 走相同 `_popPathOrPage` —— 栈非空 pop 一层，栈空 `context.pop()` 关页。

#### webdav 凭据复用契约

凭据来源：`webdav.json` (url + user，非敏感 → `core/persistence/json_store.dart`) + secure_storage `webdav_password` (敏感 → BATCH-03 决策)。**不**在远程书页引入额外凭据存储 / 不显示登录表单 / 不让用户在此页改密码 —— 配置职责留给 `webdav_config_page`，本页只读。

凭据缺（任一字段空）→ Center column 显示「请先配置 WebDAV」 + `FilledButton(去配置 WebDAV) → context.push('/webdav-config')`。**不**用 SnackBar 提示（用户进入空状态页时 SnackBar 4s 后消失会让人困惑）；用 Center 静态文案 + 按钮锁住屏幕。

#### FRB 双新增（list_dir / download_file）

```rust
// funcId 113: 通用 PROPFIND Depth=1 列任意子路径，不过滤 backup 前缀。
pub async fn webdav_list_dir(url, user, password, path) -> Result<String, String>
// funcId 114: 通用 GET 写本地路径，返字节数。
pub async fn webdav_download_file(url, user, password, remote_path, target_local_path) -> Result<i64, String>
```

与现有 `webdav_list_backups` (funcId 67) / `webdav_download_backup` (funcId 69) 区分 —— 后者写死 backup 前缀过滤 + zip 导入 zip。新通用 FRB 把 webdav 能力解耦出 backup 主题：未来如想用 webdav 同步其它资源（书签 / 字体 / 自定义封面）也能复用。

`DirEntry` Rust struct serde 序列化为 camelCase JSON `{"name", "isDir", "size", "lastModified"}`。`size` 对目录恒为 0；`lastModified` 是 unix 秒时间戳（`getlastmodified` 解析失败时 None）。Dart 端 jsonDecode 后按 `m['isDir'] == true` / `m['size'] is num ? .toInt() : 0` 安全提取。

`webdav_list_dir` path 校验：含 `..` / 绝对路径 → Err。浅层 SSRF 防护，远端 webdav 服务器自身也应做相对路径限制；Rust 端 + Dart 端 `_pathStack.join('/')` 不会构造 `..`，违反契约说明上游有 bug。

#### 下载位置与 safe filename

下载落 `<documents_dir>/remote_books/<safe_filename>` 子目录（与 import_local_book 主目录 `local_books/` 区分），让用户从「文件管理 / 缓存」入口能区分「我从 webdav 下载的」vs「我手动选的」。

`_safeFileName` 模板：`${ts.toRadixString(16)}_${random.toRadixString(16)}_${sanitized_name}`。项目无 uuid 包（`pubspec.yaml` 无依赖），用 `DateTime.millisecondsSinceEpoch + Random.secure().nextInt(0xFFFFFF)` 拼短串避免重名。`sanitized_name` 把 `\ / : * ? " < > | \x00-\x1F` 替换为 `_`，保留中文 / 字母数字 / `. - _`。

#### Forbidden 反向

- ❌ Dart 端手写 propfind XML parser — 复用 Rust `core_net::webdav::parse_propfind_entries`。Dart 端做 XML 解析意味着双实现 + 服务器返回的非 ASCII 编码 / 命名空间前缀差异要重新覆盖。Rust 端已有完整测试覆盖（`test_parse_propfind_entries_files_and_dirs` + 命名空间 + entity decode）。
- ❌ webdav 凭据写 webdav.json 的 password 字段 — 对齐 BATCH-03 决策必经 secure_storage `webdav_password` key。RemoteBooksPage 不允许任何「让用户在此页改密码」的捷径。
- ❌ 深度路径用 URL queryParameter (`/remote-books?path=/foo/bar`) 污染 GoRouter history — 用 State 内 `_pathStack`。每个 push 都进入 history 会让 OS back 行为退化为「后退一个 URL」而非「后退一层目录」。
- ❌ 多 server / multi-server 直接在 27c-1 加 — 等 27c-2/3 follow-up（需 ServerDao + 表 + FRB 一栈，量级 = 27c-1 自身）。27c-1 写完要克制别在同 PR 加 multi-server。
- ❌ 把 `book.origin = webdav://<path>` 标记直接塞 27c-1 — 需 `update_book_origin` FRB 或 `import_local_book` 加 `origin` 入参，27c follow-up 评估接口形态。27c-1 默认导入的书 source_id='local'，与本地导入无差异（用户可手 `_moveBookToGroup` 自分组管理）。
- ❌ 在 _onTapFile 内不加 mounted check 直接调 `ScaffoldMessenger.of(context)` — 长链路 await（download → import → invalidate）跨多个 frame，每步 await 后必经 `if (!mounted) return;`，对齐 [`async-and-mounted.md`] Pattern 1。
- ❌ 列目录 / 下载入口缺 seq token — 用户连续点几个文件夹 / 频繁 back 时旧 future 后完成会「幽灵」覆盖新 path 的 entries。`_loadCurrentDir` 内 `final seq = ++_loadSeq;` + 每次 await 后 `seq != _loadSeq → return` 拦截，对齐 BATCH-21 (F-W2B-019) 防御模板。

#### 测试钩子（BATCH-27c 范本）

`RemoteBooksPage` 6 个 *Override 字段（与 BookshelfPage 27a/b 同款）：
- `dbPathOverride` / `documentsDirOverride` —— 跳过 path_provider
- `credentialsOverride` `({String url, String user, String password})?` —— 跳过 webdav.json + secure_storage 读取
- `listDirOverride` / `downloadFileOverride` / `importLocalBookOverride` —— 跳过 FRB

`remote_books_page_test.dart` 6 testWidgets：凭据缺失 / 列目录成功 / 下钻 / 上钻 / 单文件下载导入（用 hanging Completer 让「下载中」中间态可观察） / 下载失败。

测试用 `Directory.systemTemp.createTempSync` 拿唯一临时目录 + `addTearDown` 兜底清理，对齐 BATCH-27a 同款决策（避免 hardcoded `/tmp/...` 并发跑冲突）。`/webdav-config` 路由仅 stub Scaffold —— 不引入真页面避免触发 secure_storage 平台通道。

#### 多 server 切换 + CRUD (BATCH-27c-2)

对齐原 legado `ServersDialog.kt:166` + `ServerConfigDialog.kt:131` + `Server entity (entities/Server.kt:57)` + `AppConst.DEFAULT_WEBDAV_ID = -1L` + `AppConfig.remoteServerId`。在 27c-1 单 server 基础上加 N server 列表切换，同时**完全保留** 27c-1 旧 webdav.json 单凭据路径（向后兼容）。

**持久化分层**（与「凭据保险柜 BATCH-03」契约严格分离）：

- **非敏感字段**（id / name / url / user）走 `<documentsDir>/servers.json`（file-based json_store，与 webdav.json 同 helper）
- **敏感字段**（password）走 `secure_storage` 的 `webdav_password_<id>` 命名空间（per-server 独立 key，删 server 时同步清 secret）
- **selectedRemoteServerId** 走 `settings.json` `remoteServerId: int` key（key-based json_store）

**「默认」sentinel id=-1**：等价 27c-1 旧路径 `webdav.json` + `secure_storage:webdav_password`，向后兼容旧用户 + backup_page（备份/恢复仍走单 webdav.json，**不**改多 server）。`RemoteBooksPage._bootstrap` 看到 selectedId = -1 时走 27c-1 凭据加载分支；id > 0 时从 _servers 找对应 RemoteServer + per-id secret。

**「默认」行不可 edit / delete**：UI 上 ServersBottomSheet 第一行始终是「默认」，不带 trailing edit/delete IconButton。该路径仍归 WebDavConfigPage（设置 → WebDAV）管理，避免与 backup 凭据语义混淆。

**id 生成**：`DateTime.now().millisecondsSinceEpoch`，对齐 legado `Server.id = System.currentTimeMillis()`。冲突概率：同 1ms 内连点 2 次「新建」≈ 0；用户 UX 上根本做不到。

**ServersBottomSheet UI 决策**：

- **Material `Radio` widget 弃用**：Flutter 3.32 后 Radio 的 `groupValue` / `onChanged` 已 deprecated；用 `ListTile + leading: Icon(radio_button_checked / radio_button_unchecked) + onTap` 模拟单选（与 `_showSortDialog` 同款，避免 deprecation warning）。
- **不退选择**：删除 server 后 BottomSheet **不**关闭，用户可继续选 / 新建 / 删除其它项；仅用户主动点 server 行才关闭并返回新 selectedId。
- **删当前选中 fallback 不弹 confirm**：confirm dialog 已问过「删服务器？」，再问一次「确定切回默认？」过度。直接 fallback id=-1 + SnackBar「已切回默认服务器」。

**切 server 重走 _bootstrap**：完全 reset 语义（_pathStack / _selectedPaths / _searchQuery / _entries / _credentials* 全清，跳到 loading 态再加载）。理由：进了不同 server = 进了不同世界，path 在 server A 的 `/books/小说` 在 server B 不一定存在；保留旧 path 反而会 PROPFIND 404 + 用户困惑。

**onUpdate password 的 null 语义**：编辑现有 server 时密码 TextField 留空 → caller 收到 `password = null`，**不**写 secure_storage（保留旧密码）。空串 = 明确清空 = 写空串等价 deleteSecret。这是「编辑场景密码字段」的标准 UX 范本（与 webdav_config_page 起步逻辑一致）。

**Forbidden 反向（BATCH-27c-2 新增 5 条）**：

- ❌ servers.json 写 password 字段 — 必走 secure_storage 命名空间 `webdav_password_<id>`，与「凭据保险柜 (BATCH-03)」契约一致。
- ❌ 用 `webdav_password` 一个 key 装所有 server 密码（追加 `<json>` 混合存）— 必须 per-id 独立 key 命名，删 server 时不会泄漏。
- ❌ 把多 server 模型放进 SQLite servers 表 + FRB ServerDao — 当前规模（用户量 < 100 个 server）file-based 完全够用；引入 FRB + dao + 5 个 funcId 是过度设计。
- ❌ 切 server 后保留 _pathStack / _searchQuery — 路径在不同 server 下无意义，保留只会触发 404 + 用户困惑。
- ❌ 删除 server 时不清 secure_storage — `webdav_password_<id>` 会泄漏到下一个用户（设备转手 / 备份恢复后），必须同步 `saveRemoteServerPassword(id, null)`。

**测试钩子（BATCH-27c-2 范本）**：

- 2 个 *Override 注入点（叠加 27c-1/3/4 的）：`serversOverride: List<RemoteServer>?` + `selectedRemoteServerIdOverride: int?`。`*Override` 任一非 null 时 `_loadServersAndSelectedIdThenBootstrap` 跳过 disk IO 直接走 _bootstrap（与 `credentialsOverride` 同款短路）— 测试用例不需要再为 27c-2 加 path_provider mock。
- `remote_servers_test.dart` × 6 测试（3 unit + 3 widget）：toJson/fromJson round-trip / saveLoadRoundTrip + 文件不存在 → 空 / webdavPasswordKey 命名 + load/save (id=-1 走 'webdav_password' / id>0 走 'webdav_password_<id>') / BottomSheet 渲染默认行 + 各 server + 切返回 id / 新建 EditDialog → onCreate 触发 / 删当前选中 → confirm → onDelete 触发 + 「已切回默认服务器」SnackBar。
- 走 `setSecureStorageOverrideForTest(InMemorySecureStorage())` + `Directory.systemTemp.createTempSync` + `addTearDown` 兜底清理（对齐 27c-1/27c-3/27c-4 范本）。

#### 多选批量下载 (BATCH-27c-3)

对齐原 legado `RemoteBookActivity.kt:144-156` selectAll/revertSelection/`addToBookshelf(adapter.selected)` 流程；在 27c-1 单 server 浏览页基础上加多选模式 + 批量下载 runner，复用 27b 范本（singleton + Queue + StreamController.broadcast + Notification id 通道）。**只对当前目录的文件项**支持多选批量；跨目录递归 / 多 server 选择留 27c follow-up。

**RemoteBookRunner（`flutter_app/lib/core/remote_book_runner.dart`）**：

完全套用 27b `update_toc_runner.dart` 范本 8 条契约（singleton + Queue + Set in-flight 去重 + worker pool with `Future.wait` + `StreamController.broadcast` + 静默 catch + done emit + reset `_totalEnqueued`）。差异点：

- `_kRemoteBookConcurrency = 1`（**串行** — 与 27b update_toc 的 4 worker 不同）：远程书是 MB 级文件 + WebDAV 服务端常对单连接并发限速 + Rust 端 `download_to_path` 已流式 `copy_to`，多 worker 同时拉大文件易触服务端限速 / 抖动。常量保留是为 follow-up 调高。`Future.wait + List.generate(_kRemoteBookConcurrency)` 抽象保持一致 — 改并发数不需要重构 worker 模型。
- `kNotificationId = 99002`（避开 99000 download / 99001 update_toc）。Notification id 表升级为 `99000=download / 99001=update_toc / 99002=remote_book`；新增批量任务沿用「99003 / 99004 ...」次第规则。
- 去重 key 是 `remotePath`（含路径前缀，由 page 端 `[..._pathStack, e.name].join('/')` 构造）；同 server 跨目录不会撞名（路径前缀不同），同目录同名等价拒绝重复入队。
- worker 内链路：`webdavDownloadFile`（platformInt64ToInt 转 int）→ `importLocalBook`；任一 throw → `debugPrint('[RemoteBookRunner] book X failed: ...')` + `_completedFail++` 静默；done emit 后 reset `_downloadOverride / _importOverride = null` 让下批次重新接受 override（非 singleton 全局 hijack）。
- 立即首次 `_emitProgress(total: N, success: 0, fail: 0, isDone: false)` 让 UI transient badge 在 worker 首本下载完成前就出现 — 27b 同款 UX 防御。

**RemoteBooksPage 选择模式状态机**：

- `bool _selectionMode` + `Set<String> _selectedPaths`（key=`remotePath`）+ `StreamSubscription<RemoteBookProgress> _progressSub`（initState 挂 + dispose cancel） + `RemoteBookProgress? _lastProgress`（done 后清空让 transient badge 消失）。
- 长按文件项 → 进选择模式（`_onLongPressEntry: if (e.isDir) return;`）；文件夹长按**忽略** — 跨目录批量是 27c follow-up，27c-3 范围锁单目录。
- 选择模式 AppBar：leading IconButton(close) → `_exitSelectionMode`；title 改「选择 N 项」；actions = `select_all` IconButton（只勾文件，跳过文件夹）+ `download_outlined` IconButton（disable 当 `_selectedPaths.isEmpty`，仿原 legado `menu_add_to_bookshelf`）。
- Checkbox leading 仅文件项；文件夹仍 Folder icon **不可勾**（onTap 仍下钻 — Q1 A 决策）；下钻 / 上钻**清 `_selectedPaths`** + 退选择模式（Q1 1b 决策：path 含目录前缀，跨目录的 selected 概念混乱）。
- PopScope 优先级：`canPop = _selectedPaths.isEmpty && _pathStack.isEmpty`；onPopInvokedWithResult: 选择模式非空 → `_exitSelectionMode`；否则 path 栈非空 → `_popPathOrPage`；都空 → 默认 pop 关页。
- `_onDownloadSelected`：构 `List<RemoteBookJob>`（每条 含 url/user/password/remotePath/targetLocalPath/dbPath/documentsDir）→ `runner.enqueue(jobs)` → 立即 `_exitSelectionMode` → 弹「已开始下载 N 本」start SnackBar。listener `done.isDone` 时弹「批量下载完成：成功 X / 失败 Y」总结 SnackBar + invalidate `allBooksProvider` / `booksByGroupProvider`（**单次** invalidate，非每本本 invalidate — 减 Riverpod recompute 抖动）。
- AppBar 非选择模式 + `_lastProgress?.isRunning == true` 显示 transient badge — 仿 27b bookshelf 模式；用户离开 RemoteBooksPage 时 dispose cancel subscription，runner state 跨页面持久；下次进来重挂 listener（如 runner 仍在跑）— singleton 设计天然支持。

**测试钩子（BATCH-27c-3 范本）**：

- `remote_book_runner_test.dart` × 9 单测（plain `test(...)`，无 widget tree）：dedup（同 remotePath 入两次 → debugQueueLength 不变）/ 空批早返回 / 单本失败不阻塞 / 5 本全成功 done emit / mixed 3+2 done + success=3/fail=2 / 第二批 reset _totalEnqueued / resetForTest 行为 / `RemoteBookProgress.isRunning` 三态 / debugPrint 不抛
- `remote_books_page_test.dart` × 6 新增 testWidgets（追加在 27c-1 已有 6 项后）：长按 → Checkbox / 全选只勾文件 / 取消选择 → AppBar 复原 / 下钻清 selection / 5 本批量「下载选中」+ start SnackBar + done 总结 SnackBar / 部分失败 4+1 总结
- 测试 5（5 本批量）追加 `Completer<int>` hanging gate（与 27c-1 测试 5 单本下载 hanging gate 同款）：`_kRemoteBookConcurrency=1` + 假 download 即时返回会让批次在一个 microtask flush 内全跑完，start SnackBar 还没观察到就被 done SnackBar 替换；hanging gate 让 worker 挂起 → pump 后断言 start 状态（`已开始下载 5` SnackBar + `Checkbox 消失` + `downloadCalls == 1`）→ `complete(1024)` 让批次走完 → 断言 done SnackBar
- 测试用 `RemoteBookRunner().resetForTest()` 在 setUp（singleton 状态测试隔离）+ `RemoteBooksPage.remoteBookRunnerOverride: null` 默认走 production singleton — runner 不能进 ctor，page 用 `final RemoteBookRunner runner = widget.remoteBookRunnerOverride ?? RemoteBookRunner();`

**Forbidden 反向（BATCH-27c-3 新增 4 条）**：

- ❌ 跨目录批量 — `_pathStack.push` / `pop` 时 `_selectedPaths` 不清空。跨目录的 selected 概念混乱（path 前缀不同，UI 无法表达「我在 A 目录选了 3 本，又下钻 B 目录选了 2 本，共 5 本批量」语义）。坚持 27c-3 单目录范围；跨目录批量留 follow-up。
- ❌ 文件夹长按也进选择模式 — `_onLongPressEntry` 必经 `if (e.isDir) return;`。文件夹批量是「递归子树批量」语义（导出整个 webdav 子目录），与「同目录多选 N 个文件」是两种不同 UX，混在一起让用户困惑。
- ❌ 单本失败弹 SnackBar — runner worker 内 throw 时 **必须** debugPrint 静默，不 `messenger.showSnackBar(...)` 弹错。批量 5 本同时失败会刷屏；只在 `done.isDone` 时弹一次「成功 X / 失败 Y」总结 SnackBar 即可。
- ❌ Runner 进 ctor 注入 override —— singleton 模式天然横跨 page lifecycle，ctor 注入会让 singleton 状态绑特定 page 实例（page rebuild 时重新建 runner 等价于丢队列）。Override 走 `enqueue(downloadOverride:, importOverride:)` 方法参数透传；测试用 `RemoteBookRunner().resetForTest()` + 方法 override 的组合避免污染其它测试。

#### 排序 + 搜索 (BATCH-27c-4)

对齐原 legado `RemoteBookActivity.kt:120-141` `menu_sort` 子菜单（按名称 / 按时间）+ `:207 SearchView onTextChange` + `RemoteBookViewModel.kt:71-92` 复合排序（**文件夹永远在前** + 名称 / 时间 + 升降序）。在 27c-1 + 27c-3 RemoteBooksPage 基础上加排序 + 文件名搜索（debounce 300ms），让大目录可用；服务端排序 / 搜索（webdav 协议层不支持 PROPFIND filter）+ 多关键词 / 正则搜索 / 排序按文件大小 / 跨目录搜索结果留 27c-follow-up。

**3-mode 状态机扩展（普通 / 选择 / 搜索 互斥）**：

27c-3 已落「普通 / 选择」二态切换；27c-4 引入第三态「搜索」严格互斥：

- 进选择模式（`_enterSelectionMode`）必先调 `_exitSearchModeIfActive`：清 `_searchQuery + _searchController.clear() + _searchMode=false + _searchDebounce?.cancel()`，再设 `_selectionMode=true`。
- 进搜索模式（`_enterSearchMode`）必先调 `_exitSelectionModeIfActive`：清 `_selectedPaths.clear() + _selectionMode=false`，再设 `_searchMode=true`。
- 退搜索模式（点 close / OS back）→ `_searchMode=false + 清 query`，**不**自动进选择模式（普通模式即可）。
- 退选择模式同 27c-3 决策不变。

为什么互斥而非共存：「搜索后批量下载」是 27c-follow-up（要先 PRD 确认），强行共存会让选择 state 跨筛选条件保留 → 用户「我在搜索条件 A 下选了 3 本，切到搜索条件 B 后选中数仍 3 但可见项变」语义混乱。互斥简化状态机为「单 active mode」清晰可推。

**排序契约（持久化 + 客户端排序）**：

- 持久化 key（settings.json）：`remoteBookSortKey` (String 'name'/'time'，default 'time' 对齐原 `RemoteBookSort.Default`) + `remoteBookSortAsc` (bool，default true 升序)。`remoteBookSortKey` 非法值 fallback 'time'（仅 'name' / 'time' 合法），损坏 JSON 类型 fallback default。与 27a `_isGridView` / 26d `defaultHomePage` 同款 `readJsonKey<String/bool>` / `writeJsonKey` 模式。
- 排序行为对齐原 legado `RemoteBookViewModel.kt:71-92`：**文件夹永远在前**（`compareBy { !it.isDir }` 优先比较），相同文件夹身份内按 sortKey + sortAsc 二次排序。降序模式下「文件夹永远在前」语义不翻转（仅 sortKey 内排序翻转，对齐原版 then-comparator 处理）。
- 排序在客户端处理（已加载的 `_entries`，**不重发 list_dir**）—— webdav PROPFIND 不支持服务端排序，重发等于浪费请求 + 用户感知延迟。`_visibleEntries` getter 派生：先排序再过滤（filter 不影响排序顺序）。
- **跨目录保留排序偏好**：用户在 / 选「按名称（降）」后下钻 /foo/bar，预期看到 /foo/bar 内仍按名称（降）排。这与原 legado `viewModel.sortKey` 在 ViewModel 生命周期常驻语义一致 + 是高 ROI 用户偏好。

**搜索契约（客户端 filter + debounce）**：

- 输入框立即 visual 反馈（TextField 自带，**不**人为 debounce 文本框）；filter 写入 + setState 走 debounce 300ms（与 `search_page.dart::_searchDebounceMs` 一致）。
- 空 query 立即清 filter 不走 debounce — 用户清空输入框时若再等 300ms 才看到全部 entries 体感慢，反 UX。`onChanged: (text) { _searchDebounce?.cancel(); if (text.isEmpty) { setState(() => _searchQuery = ''); return; } _searchDebounce = Timer(300ms, () { if (!mounted) return; setState(() => _searchQuery = text); }); }`。
- filter case-insensitive（lowercase + contains），仅过滤文件名（不搜索内容；原 legado 同款）；不模糊不正则。
- **下钻文件夹清空 search query**（`_onTapEntry` folder 分支）：每个目录独立搜索语境（用户搜索 'foo' 后下钻 /foo 子目录，预期看完整目录内容而非继续 filter）。
- `_searchDebounce?.cancel()` 必经 `dispose()` —— 否则 Timer 在 page unmount 后 fire 会触发 setState after dispose（对齐 [`async-and-mounted.md`](./async-and-mounted.md) Pattern 1）。

**AppBar 三态渲染**：

```dart
PreferredSizeWidget _buildAppBar(BuildContext context) {
  if (_selectionMode) return _buildSelectionAppBar(...);  // 27c-3
  if (_searchMode) return _buildSearchAppBar(...);        // 27c-4 新增
  return _buildNormalAppBar(...);  // 27c-1 + 27c-4 actions: search/sort/transient badge
}
```

普通模式 actions 顺序：搜索 IconButton（Icons.search）→ 排序 PopupMenu（Icons.sort，4 项 + trailing `Icon(Icons.check)` 标当前选中）→ transient badge（27c-3 已有，仅 `_lastProgress?.isRunning` 时渲染）。搜索模式 title 改 `TextField(autofocus: true, onChanged: _onSearchChanged)` + leading 改 `IconButton(close)` + actions 全清避免 AppBar 拥挤。

**测试钩子（BATCH-27c-4 范本）**：

- `remote_book_sort_persist_test.dart` × 10 unit-persistence 测试：sort key round-trip name/time × 2 / load 不存在 → default time / 损坏 JSON 字符串值 → 兜回 time / 损坏类型（int 非 String）→ 兜回 time / save 非法 key → fallback 写 time / sort asc round-trip true/false × 2 / load 不存在 → default true / 损坏类型（String 非 bool）→ 兜回 true。`Directory.systemTemp.createTempSync` + `addTearDown` 兜底清理。
- `remote_books_page_test.dart` 既有 12 testWidgets（27c-1 + 27c-3）不变；BATCH-27c-4-followup 追加 7 项 27c-4 widget 测试（共 19 项）；`buildPage` helper 加 `sortKey/sortAsc` 参数注入到 `RemoteBooksPage.sortKeyOverride / sortAscOverride`，避免触 path_provider。
- 27c-4 7 项 widget 覆盖（BATCH-27c-4-followup 落地）：默认 sort PopupMenu trailing check / 选「按名称（降）」→ entries 顺序变（文件夹永远在前 + 名称倒序）/ 搜索 IconButton → AppBar 切搜索模式 / debounce 300ms + 空 query 立即清 / mode 互斥（搜索模式下长按文件被忽略）/ mode 互斥（选择模式下搜索 IconButton 不可见）/ 下钻清搜索 + 保留排序。
- 测试 fixture：mixedListDir 4 项（folderA + 3 files），lastModified 时间分布让时间排序可观察。`download_outlined` icon 在 ListView file 项 trailing 与 AppBar action 同名，AppBar scope 测试**必须**用 `find.descendant(of: find.byType(AppBar), matching: find.byIcon(...))` 限定查找范围 — 否则 R5 mode 互斥测试会将 ListView 内的 file trailing icon 误判为 AppBar action 失败。

**Forbidden 反向（BATCH-27c-4 新增 4 条）**：

- ❌ 服务端排序 / 服务端搜索 — webdav 协议 PROPFIND 不支持 sort / filter；客户端内存内处理足够（远程书目录通常 <1000 项）。重发 list_dir 等于浪费请求 + 用户感知延迟。
- ❌ 排序选项每目录独立（`_pathStack.push` 时清 `_sortKey/_sortAsc`）— 应跨目录保留排序偏好（高 ROI 用户偏好）。仅 `_searchQuery` 跨目录清空（每目录独立搜索语境）。
- ❌ 搜索 / 选择 mode 共存 — 必互斥；进任一 mode 自动清对方 state。「搜索后批量下载」是 follow-up 需求，不在 27c-4 范围。
- ❌ TextField 输入框走 debounce 300ms 才显示文字 — 文本框立即跟手反馈（TextField 自带），仅 filter 写入 + setState 走 debounce。空 query 还要立即清 filter 不走 debounce（避免清空时还要等 300ms 才显示完整列表）。



### 批量编辑选择模式 (BATCH-27d)

`flutter_app/lib/features/bookshelf/bookshelf_manage_page.dart` 是「书架管理」批量编辑页（对齐 `legado/.../BookshelfManageActivity.kt`）。它沉淀「列表选择模式」范本，给后续类似页（书源管理、订阅源管理、分组管理）复用。

**选择模式状态机**（5 决策固化）：

- ❶ 进入：长按任一 ListTile（`onLongPress`）— 不要走 AppBar 的「⋮」隐藏入口；长按是 Material 列表选择的标准手势，用户预期最低。
- ❷ 退出：AppBar `close` IconButton（左 leading），或全部取消选择后**保持**选择模式（不自动退）— 让用户能继续选别的，避免误操作清空。
- ❸ 全选：AppBar `select_all` IconButton — 一键填满 `_selectedIds`；二次点击不切换为「反选」（避免跟「取消」语义模糊）；要反选请用 close + 重新长按。
- ❹ 高频 actionbar：删除 IconButton 直达（`Icons.delete_outline`，红色 errorColor）— 删除是最高频且不可逆的操作，必须一击可达 + confirm dialog 兜底。其它低频 action 收到 `⋮` overflow PopupMenu。
- ❺ Overflow PopupMenu：4 项「允许更新 / 禁用更新 / 移到分组 / 清除缓存」— 拆 2 而非 toggle 一项「允许/禁用更新」是因批量场景下选中书的 canUpdate 状态可能混合（部分允许部分禁用），单 toggle 无法表达「全部置 true」vs「全部置 false」。

**AppBar layout 标准**（选择模式）：

```
[close] [选择 N 项]      [select_all] [delete] [⋮]
 leading    title         actions[0..2]
```

非选择模式：`[back] [书架管理] [⋮(empty)]`（PopupMenu 当前为空，预留下一阶段加「按书源筛选」「按状态筛选」）。

**批量执行模型**（differ from 27b/27c-3 决策）：

- 4 actionbar 都是**本地 SQL ~ms 级 IO**（UPDATE / DELETE 单条都是同步 sqlite write），用 Dart `for ... await` 串行 forEach 即可，**不引 Runner / 不入 Notification 通道**。
- 与 27b（update_toc 网络 IO + 4-worker Runner）和 27c-3（remote_book WebDAV MB 级 + concurrency=1 Runner）的差异：批量任务的执行模型由「单任务耗时」决定，<10ms 直跑、>100ms 入 Runner、需要后台续跑入 Notification。
- 失败兜底：`try/catch` 单本捕获错误 → 累计 `successCount/failCount` → 一次 SnackBar 总结「{动作}完成：成功 X / 失败 Y」，不弹错误流（避免一次批量删 100 本失败时 SnackBar 风暴）。

**FRB 边界**（27d 的 funcId 决策）：

- `set_book_can_update(dbPath, id, canUpdate) -> ()` (funcId 115)：BookDao 加 `set_can_update` 方法（单 UPDATE 语句），FRB 薄包装。Dart 端 binding `setBookCanUpdate({dbPath, id, canUpdate})`。
- `delete_book_with_file(dbPath, id, deleteFile, documentsDir) -> ()` (funcId 117)：**不破坏**现有 `delete_book` (funcId 47) binary contract — 新建独立 funcId 走「删本地源文件」分支。`deleteFile=true` 仅当 `book.book_url` 以 `loc_book:` 前缀 + 路径在 `documentsDir` 子树内（`lp.starts_with(docs)`） → `std::fs::remove_file`。**防越界 rm**：哪怕 book_url 被改坏指向 `/etc/passwd`，路径前缀检查会拒绝。
- 清缓存：**复用** BATCH-26a `clear_book_cache` (funcId 80, CacheStatsDao)。**不**在 27d 重写 FRB — FRB 命名冲突教训：起始我新加 `clear_book_cache` 与 26a 同名 → cargo build E0428 redefined。下次新 FRB 必先 `grep -n "pub fn xxx" core/bridge/src/api.rs` 验冲突。

**`_GroupPickerDialog` vs `GroupManageDialog` 决策**：

- 27d 新建私有 `_GroupPickerDialog`（pick 语义：选一个 group 返回 id）— **不复用**已有 `GroupManageDialog`（CRUD 语义：增删改 group）。混用会让 dialog 既能「点 group 选中」又能「点编辑/删除按钮」，UX 混乱 + 测试断言难。两 dialog 共享 `groupsProvider` 数据源即可。
- 「未分组」选项 `id=0`（对齐 sqlite groups 表「0=ungrouped」约定，与 26a `manage_groups` 一致）。

**Forbidden 反向（BATCH-27d 新增 5 条）**：

- ❌ 单 toggle「允许/禁用更新」 — 批量场景选中书的 canUpdate 状态可能混合（部分允许部分禁用），toggle 语义不清。必须拆 2 actionbar「允许更新」+「禁用更新」让用户显式选目标态。
- ❌ 删除 confirm 默认勾「同时删本地源文件」 — 不可逆破坏性操作必须默认 unchecked，需用户主动勾选才删文件。
- ❌ `delete_book_with_file` 不做 `documentsDir` 前缀校验 — 哪怕 `book_url` 字段被恶意改坏指向 `/etc/passwd`，仍会执行 `fs::remove_file`。**必**校验 `lp.starts_with(docs)` 防越界 rm。
- ❌ 选择模式下点 ListTile 不切换选中态 / 选择模式下长按再触发选择菜单 — 选择模式必须改 ListTile.onTap 语义为「toggle 选中」、长按降级为 no-op（与普通模式 mode 互斥）。
- ❌ 4 个 actionbar 全部走独立 Runner — 本地 SQL ms 级 IO 不需要 Runner（仅当批量任务跨 100ms 量级或需要后台续跑才入 Runner）。Runner 模式过度引入会让 progress notification 噪音、状态机变复杂、回滚链路重。

**测试钩子（BATCH-27d 范本）**：

- 8 个 *Override 注入点：`dbPathOverride / documentsDirOverride / booksOverride / groupsOverride / deleteOverride / setCanUpdateOverride / setBookGroupOverride / clearCacheOverride`。所有 FRB / DB 调用都通过 override 旁路，避开 `RustLib.init` + path_provider。
- `bookshelf_manage_page_test.dart` × 8 testWidgets：列表渲染 + 长按进选择 + Checkbox leading / 全选 / close 退选择模式 / 删除 confirm + batch delete + 总结 SnackBar / 取消 confirm 不删 / 「允许更新」批量 setBookCanUpdate(true) / 「禁用更新」批量 setBookCanUpdate(false) / 「移到分组」 GroupPickerDialog + batch setBookGroup。`Directory.systemTemp.createTempSync` + `addTearDown` 兜底清理。
- Rust 端 `BookDao::set_can_update` × 2 unit-test：round-trip true/false。

#### 进阶：分组筛选 + 区间选 + openReader (BATCH-27d-followup)

承 27d 选择模式范本扩展三项：

**R1 列表头分组筛选** (`_filterGroupId: int?`)：

- 顶部 horizontal `SingleChildScrollView` + `ChoiceChip`：「全部」(null) / 「未分组」(0) / 各 `Group(id, group_name)` 各 1 chip。
- **单选**：点 chip 切换 `_filterGroupId`，点当前选中 chip 不取消（`onSelected: (s) { if (!s) return; ... }`）— 与 legado VM:30 `var groupId: Long = -1L` 单值 field 对齐。
- **不持久化**：每次进页 `_filterGroupId = null`（默认全部），退页丢弃；settings.json 不动。理由：与 legado Activity unsave 语义一致 + 避免「进页发现东西丢了以为 bug」（其实是上次 filter 还生效）。后续若用户反映「每次重进还要选」可加 settings.json — 单向兼容扩展。
- **选择模式 + filter mode 共存**（不互斥）：选择模式下 chips 仍可见可点切换；切 filter 不退选择模式，**不清 `_selectedIds`**（被 filter 隐藏的项仍记得已选，重切回时 Checkbox 仍勾上）。这与 27c-4 RemoteBooksPage「3-mode 互斥」（普通/选择/搜索）的不同：filter chips 是 view 视图态，与「选择模式 / 搜索模式」状态机不在同维度。
- **全选按 filter 范围**：`_selectAll` 用 `_filterBooks(raw)` 后的列表，避免「选了不可见的书」反直觉（用户预期全选 = 当前可见书全选）。
- 区间选 range 也按 `_filteredBooks` 列表索引算（同 reason）— 起点不在当前 filter 列表内时 fallback 单 toggle 该项。

**R2 区间选** (`_lastTappedId: String?`)：

- 选择模式下长按 `b` 时若 `_lastTappedId == null || == b` → fallback 单 toggle 加入 + 设 `_lastTappedId = b`。
- 否则区间 `[_lastTappedId .. b]` 按当前 `_filteredBooks` 索引计算（小到大），**全部 add 进 `_selectedIds`**（**追加，不清以前**）。这是与「先清选区再选区间」的关键区别 — Gmail/Files app 业界惯例：长按是 add 操作不是 replace。
- 普通 onTap（选择模式下）= toggle 单项 + 更新 `_lastTappedId = id`。退选择模式时 `_lastTappedId = null`。
- 起点不在当前 filter 列表内（用户切了 filter） → fallback 单 toggle 该项 + 重设起点，避免抛错。

**R3 openReader toggle**（`bookshelfManageOpenReaderProvider` + settings.json `bookshelfManageOpenReader: bool`）：

- SettingsPage 加 SwitchListTile，默认 `false`（保持 27d 现状：点书名 no-op，仅长按出菜单）。on=点书名 push '/reader?bookId=...' 直接进阅读，与主 bookshelf onTap 一致。
- **选择模式优先级最高**：选择模式下永远 toggle 选中（与 toggle 状态无关）— mode > preference 是范本通则。
- main.dart 启动加载（`loadBookshelfManageOpenReaderFromDisk`）→ ProviderScope.overrides → 第一帧拿正确值（避免「先渲染默认 false 再 listen 异步刷新」抖动），与 26d defaultHomePage 同款 wire 范本。
- Flutter 端无 BookDetailsPage，所以 toggle on push reader 不 push 详情；与 legado BookshelfManageActivity 行为不同（legado push BookInfoActivity）— 两端架构差异记入决策。

**Forbidden 反向（BATCH-27d-followup 新增 4 条）**：

- ❌ filter 选择模式下隐藏 chips — 选择模式下用户仍可能想切 filter 看「哪些书在这个组」，强制隐藏需先退选择再切再重进选择，操作链路过长。chips 与选择模式正交，应共存。
- ❌ 切 filter 时清 `_selectedIds` — 用户切 filter 是临时换 view，不是放弃选中；切回时仍应保留所有已选项。被 filter 隐藏的项 Checkbox 不可见但 state 仍在。
- ❌ 区间选清以前选中（replace 语义）— 业界（Gmail / Files）的长按区间是 **add** 不是 **replace**；用户预期长按是「再加选一组」不是「重选」。
- ❌ openReader=false 时点书名 push reader / openReader=true 时选择模式下点书名也 push — 选择模式优先级永远 > toggle 偏好；toggle 仅决定**普通模式**下点书名的行为。

**测试钩子（BATCH-27d-followup 范本）**：

- 9 个 *Override 注入点（27d 8 + 加 `openReaderOverride: bool?`）。`buildPage` helper 加 `openReader: bool?` + `onReaderPush: void Function(String bookId)?` 两 hook 给 `/reader` stub 路由透出 push 时的 bookId。
- `bookshelf_manage_page_test.dart` 8 + 5 testWidgets（27d 8 不变，27d-followup 加 5）：group chips 默认「全部」 + 4 chips findsNWidgets / 选「未分组」chip 仅 group=0 可见 + 切「玄幻」过滤验证 / 区间选（已选 b1 + 长按 b3 → 选 3 项 + 4 Checkbox state 验证 + 再长按 b5 起点更新到 b3 → 选 5 项）/ openReader=true 点书名 push '/reader' + Reader Stub mounted + bookId='b1' / openReader=false 点书名 no-op + 仍在 BookshelfManagePage + onReaderPush 未触发。
- 测试 fixture `fixtureBooksWithGroup()` 5 本 + group 字段（b1=0 / b2 b3=1 / b4 b5=2），让 filter / 区间选测试可观察。
- GoRouter test scaffolding 加 `/reader` stub 路由（`onReaderPush?.call(id)` 透出 push 行为）— 这是 27d-followup 的可复用范本：测 push 路由的最简方式不是 mock router，而是建 stub GoRoute + 回调。



### 添加网络URL + 导入书架 (BATCH-27e)

对齐原 legado `BookshelfViewModel.addBookByUrl` (38-100) + `importBookshelf` (131-186)。完成 bookshelf 顶部 PopupMenu 最后 2 项灰显占位，达成 27a 表 13 项全部已实现。

**R1 add_url 流程**：

- bookshelf PopupMenu 第 5 项 `add_url` 改 enabled → `_onAddUrl(context)`。
- 弹 `_AddUrlDialog`：单行 TextField + 「添加」按钮。**单 URL**（legado 多行 split 留 27e-followup）。
- Rust 新加 `SourceDao::find_for_book_url` → FRB funcId 118 `find_book_source_for_url(db_path, book_url) -> Result<Option<String>, String>`：
  - 第 1 路：baseUrl 前缀匹配（`book_url.starts_with(&source.url)`）
  - 第 2 路：`book_url_pattern` regex 兜底（enable 源中 book_url_pattern 非空者）
  - regex 编译失败静默跳过（对齐 legado `try { ... } catch (_: Exception)`）
  - 找不到 / 没启用源 / URL 空 → `None`
- 找到源 → `getBookInfoOnline(sourceJson, bookUrl)` → `saveBook(dbPath, infoJson)` → `ref.invalidate(allBooksProvider / booksByGroupProvider)`。
- 不调用 `getChapterListOnline` + `replaceBookChapters`：章节由 reader 打开时按需加载（与 search_page 同款决策 — saveBook 即可，chapters 是惰性加载器）。
- 失败两阶段提示：source=null → 「未找到匹配书源，请先在「书源管理」中启用书源」；网络/parse 异常 → 「导入失败: $err」。
- Rust 端 `core-storage` 加 `regex` workspace dep 用于 `find_for_book_url` 的 `book_url_pattern` regex 匹配。

**R2 import_bookshelf 流程**：

- bookshelf PopupMenu 第 12 项 `import_bookshelf` 改 enabled → `_onImportBookshelf(context)`。
- 弹 SimpleDialog 二选一：「手动粘贴 JSON」/「从文件导入」（对齐 legado `importBookshelfAlert`，不含 isAbsUrl URL 抓取分支 — 留 follow-up）。
- 「手动粘贴」→ `_PasteBookshelfJsonDialog` 多行 TextField。
- 「从文件导入」→ `FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json'])` → readAsString。
- json 格式：`List<Map<String, String?>>`，**容忍读** name+author（intro 可选忽略）。
- 处理流程：
  1. parse json → List\<Map\>
  2. 预加载 `getEnabledSources(dbPath)` 拿全部启用源
  3. 对每本 `name`：遍历源列表，逐源调 `searchWithSourceFromDb(dbPath, sourceId, name)`，找到首个非空结果 → `saveBook(dbPath, jsonEncode(matched))`
  4. 累计 `success / skip / fail`（name 为空的 skip）
- 总结 SnackBar「导入完成：成功 X / 跳过 Y / 失败 Z」。**不弹 progress dialog**（100 本以内可接受；runner 模式过度设计）。

**与 27b/27c-3 Runner 模式差异**：

- add_url 是单书 IO，~300ms 内完成，不引 Runner（单 FRB 调用即可）。
- import_bookshelf 是 N 本书 N 次 FRB 调用，但每本 search 成本 ~1-3s，总时间 < 单批用户 1 次 batch-update-toc（20 本书 × 3s = 60s）。与 27b 的 `UpdateTocRunner` 和 27c-3 的 `RemoteBookRunner` 不同：import_bookshelf 不需后台续跑（用户全程等 dialog + SnackBar 即可），不引 Runner。

**Forbidden 反向（BATCH-27e 新增 3 条）**：

- ❌ add_url 传多行 URL 到单行 input — 多行增加 UI 复杂度（需进度条 + 取消逻辑），MVP 单 URL。同时避免输入框中一行 URL 带空格被误 split 为两行。
- ❌ import_bookshelf 弹 progress dialog / 入 Runner — N 本书的搜索是对源并行请求，时间 <2min 用户可接受。入 Runner 增加状态机 + Notification 碰撞 + 总结 SnackBar 位置找不到。
- ❌ `_onImportBookshelf` 用 `searchWithSourceFromDbV2` — 这个 FRB 参数 `sourceId` 是单源查，不是「全源自动分配」语义。必须循环全部启用源 — `getEnabledSources` + `searchWithSourceFromDb(sourceId)` 逐源调。

**测试钩子（BATCH-27e 范本）**：

- 复用 27a 测试的 `dbPathOverride / documentsDirOverride` + `ProviderScope` 注入模式。`_AddUrlDialog` / `_PasteBookshelfJsonDialog` 为 library-private（与 `bookshelf_page.dart` 同文件），测试走 PopupMenu onTap 间接验证。
- `bookshelf_menu_test.dart`：disabledValues 仅剩 `'log'`，enabledValues 加 `'add_url'` + `'import_bookshelf'`。
- `bookshelf_add_url_test.dart` × 2 testWidgets：PopupMenu items enabled 断言 / tap「添加网络URL」弹 AlertDialog + TextField + FilledButton 可见。
- Rust `database.rs` × 2 unit test：`find_for_book_url` baseUrl 匹配 / book_url_pattern regex 兜底（含 regex 损坏静默跳过）。



### RSS 订阅源网格 (BATCH-28)

对齐原 legado `RssFragment.kt` (RssAdapter 4 列网格 + 分组筛选)。将
`RssTabPage` 从 BATCH-26a 占位页改造为 `ConsumerStatefulWidget`，显示
enabled RSS sources 的 GridView + 未读 badge + 分组 ChoiceChip +
pull-to-refresh。

**源网格 GridView**：

- `RssTabPage`：StatelessWidget → ConsumerStatefulWidget + `dbPathOverride`
  注入 + `sourcesOverride / groupsOverride / unreadCountsOverride` 测试
  钩子。
- `initState._loadAll()`：并行加载 `rssSourceListEnabled` +
  `rssSourceListGroups` + 串行 `rssCountUnread` 逐源取未读数。
- body：`RefreshIndicator` 包 `GridView.builder`。
- 列数：`SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4)`
  — 固定 4 列对齐 legado RssAdapter。
- item：`Card(clipBehavior.antiAlias)` + Column：
  - Stack：`CachedNetworkImage` 源图标（50dp 圆角，fallback
    `Icon(Icons.rss_feed)`）+ 右上角红色数字 badge（`rssCountUnread
    > 0`， >99 显示「99+」）
  - `Text(source_name, maxLines: 2, textAlign: center)`
- 空态：centered「暂无订阅源」+ FilledButton「去添加」→ push
  `/rss-source-manage`。
- 点 source → push `/rss-articles?sourceUrl=<encoded>`（已有路由）。

**全局 pull-to-refresh**：

- RefreshIndicator 下拉 → `_refreshAll()`：逐源 `rssGetArticles`
  拉最新文章，单源失败静默跳过，完成后 `_loadUnreadCounts` 刷新 badge。
- 不逐源显示进度（与 import_bookshelf 同款策略：总结即可）。

**分组 ChoiceChip**：

- AppBar bottom 加 horizontal `SingleChildScrollView` + ChoiceChip：
  「全部」+ 各 `group` 名（调 `rssSourceListGroups` 获取）。
- 单选：点 chip 切换 `_filterGroup: String?`（null=全部，非 null =
  `source_group` 包含该组名的源）。
- **不持久化**（与 27d-followup group chips 同款：每次进页 = 全部）。
- 「分组」AppBar action 从 26a 的 disabled 改 enabled（点选备选方案：
  `_showGroupPicker` SimpleDialog）。

**AppBar actions 保持 3 项**（与 26a 占位页相同）：

- `star_outline` → push `/rss-favorites`
- `folder_outlined` → enabled → `_showGroupPicker` SimpleDialog 或
  chips 已满足
- `settings_outlined` → push `/rss-source-manage`

**Forbidden 反向（BATCH-28 新增 3 条）**：

- ❌ 源图标加载用 `Image.network` — 必须用 `CachedNetworkImage`
  （与 `cached_network_image` 是唯一 blessed image cache 规则一致）。
- ❌ 未读 badge 用 `NotificationListener` / `ValueListenableBuilder`
  — 直接用 `_unreadCounts[sourceUrl]` state map + setState（与现有
  RSS pages 同款 setState 管理，不引入 ViewModel / Provider）。
- ❌ 分组选择持久化到 settings.json — group filter 是临时视图态，与
  27d-followup group chips 同决策（每次进页 = 全部）。

**测试钩子（BATCH-28 范本）**：

- 4 个 *Override 注入点：`dbPathOverride / sourcesOverride /
  groupsOverride / unreadCountsOverride`。与 `RssSourceManagePage`
  同模式（ProviderScope wrapping + MaterialApp + Widget）。
- `rss_tab_page_test.dart` × 4 testWidgets：空态「暂无订阅源」+
  「去添加」 / GridView 渲染源名 + badge / 分组 ChoiceChip 筛选（选
  「科技」仅科技源可见 + 选「全部」恢复全部） / AppBar 3 actions 可见。
- `_loadAll` 内 `dbPath` 必须加显式 `final String dbPath` 类型注解
  （否则 Dart analyzer 将 `widget.dbPathOverride ?? await` 推断为
  `String?`，与 `rss_source_manage_page` 同款决策）。

#### 搜索 + 长按菜单 (BATCH-28-followup)

**R1 AppBar 搜索 SearchView**：

- AppBar actions 加搜索 IconButton（`Icons.search`），点击进入 `_searchMode`。
- 搜索模式 AppBar：`[back arrow] [TextField(autofocus)]` actions 清空。
  AppBar bottom chips 保留（搜索仅是 view filter，与 group filter 正交）。
- `_onSearchChanged`：debounce 300ms `Timer` → `setState(_searchQuery = text)`。
  空 query 立即取消 debounce + `_searchQuery = ''` — 与 27c-4
  RemoteBooksPage 完全同款。
- filter 逻辑：`_filteredSources` getter 先 group filter 再 search
  filter（name + URL + source_group toLowerCase contains）。
- 退出：back arrow → `_searchDebounce?.cancel()` + `_searchQuery = ''` +
  `_searchController.clear()` + `_searchMode = false`。
- `group:<name>` prefix 语法不在 MVP（留 followup）。

**R2 长按 3 项菜单**：

- `onLongPress` → `showModalBottomSheet` 3 项：
  1. **禁用/启用** toggle：`rssSourceSetEnabled(dbPath, url, !enabled)`
     → SnackBar → `_loadAll()` 刷新
  2. **删除**：confirm dialog → `rssSourceDelete(dbPath, url)` →
     SnackBar → `_loadAll()`
  3. **编辑**：push `/rss-source-manage`
- 测试钩子：`setEnabledOverride` / `deleteOverride`（`Future<void>
  Function(...)`），与 `RssSourceManagePage` 同模式。
- 「置顶」不在 MVP（需新 FRB，留 BATCH-29+）。

**Forbidden 反向（BATCH-28-followup 新增 2 条）**：

- ❌ 搜索模式下 TextField 直接过滤不 debounce — 每次都 setState 在 100+
  源 grid 下引起 UI 重绘风暴。必须用 debounce 300ms（与 27c-4 同款）。
- ❌ 长按菜单用 `showMenu` / `PopupMenuButton` 而非 `showModalBottomSheet`
  — BottomSheet 更适配 Material 3 手势关闭 + SafeArea，且不与 GridView
  item 内层级冲突（showMenu 需计算 offset relativeTo widget 且容易
  被 Card clip 裁切）。

**测试钩子（BATCH-28-followup 范本）**：

- 2 个新 *Override：`setEnabledOverride / deleteOverride`（叠加 28 的 4
  个 → 共 6 个）。
- `rss_tab_page_test.dart` 7 testWidgets（28 的 4 + 28-followup 3）：
  搜索 IconButton → AppBar 切 TextField + back arrow / 搜索输入「科技」
  → 仅科技源可见 + 清空恢复全部 / 长按 → BottomSheet 3 项可见。



### easy-win 零星收尾 (BATCH-29)

**R1 RSS responsive 列数**：`SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 120)` — 单行替换，自适应屏幕宽度。手机 ~3列、平板 ~5列。

**R2 RSS 搜索 `group:` prefix**：`_searchQuery.startsWith('group:')` → 去前缀 → 仅匹配 `source_group`。其余 query 走原逻辑（name+URL+group）。

**R3 add_url 多行批量**：`_AddUrlDialog` `maxLines: 5` / `InputBorder.outlineBorder` + `_onAddUrl` `\n` split → 逐行 add（findSource + getBookInfo + saveBook） → 总结 SnackBar「成功 X / 失败 Y」。

**R4 import_bookshelf URL 导入**：SimpleDialog 加第 3 选项「从 URL 导入」→ `_UrlImportDialog` → `HttpClient.getUrl` → `response.transform(utf8.decoder).join()` → 现有 parse 流程。

**Forbidden 反向（BATCH-29 新增 2 条）**：

- ❌ add_url 多行仍逐行独立找源 — 每行 URL 走独立的 `findBookSourceForUrl`，不要假设相邻行同源（不同 URL 可能不同域名需要不同书源）。
- ❌ import URL 导入不做超时 / redirect limit — `HttpClient` 默认 30s connect timeout，不额外设置。L2 5xx → 外层 try-catch 扔 SnackBar。



- `cached_network_image` is the only blessed image cache. Don't add a parallel `Image.network` call site.
- `ListView` should be `ListView.builder` for any list whose length depends on user data. Eager `ListView(children: [...])` is allowed only for short fixed menus (settings rows, etc.).
- Reader page is the largest file (~2900 lines) and uses `RepaintBoundary` carefully. Do not casually wrap widgets in `RepaintBoundary`; profile first.
- `safeSetState` after FRB is cheap; the FRB call itself is the expensive part. Don't aggressively `setState({})` inside reader pan/scroll callbacks.

## Code Style

- Follow `dart format` defaults (80-col wrap, trailing commas where they help diff readability).
- Class members ordered: fields → constructor → static helpers → public methods → `build`/`createState` → private methods.
- Avoid `late` for fields that can have a sensible default; reserve it for FRB-injected handles.
- Use `const` constructors where possible. Linter will flag missing ones.

## Verification Cadence

Before commit:

```bash
cd flutter_app
flutter analyze
flutter test
```

Both must be 0-issue / all-green. The repo does not currently run `flutter format --output=none --set-exit-if-changed`, but matching `dart format` style is expected.

## When You Spot a New Anti-Pattern

1. Check if it appears 2+ times in the codebase. One-off slips don't warrant a rule.
2. Either fix it in the same change set, or open a Trellis batch task that captures the audit.
3. Add the pattern to the table above with a reference to the batch.

The historical record lives in `findings-flutter-features.md` (Wave 2B) and `findings-flutter-core.md` (Wave 2A). Reading a few entries before starting a refactor calibrates what we already know is bad.
