import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/dto.dart';
import '../../core/colors.dart';
import '../../core/download_runner.dart';
import '../../core/platform_webview_executor.dart';
import '../../core/providers.dart';
import '../../core/widgets/safe_setstate.dart';
import '../../src/rust/api.dart' as rust_api;
import 'page/page_view.dart';
import 'page/page_view_controller.dart';
import 'change_source_dialog.dart';
import 'services/reader_tts_manager.dart';
import 'services/reader_auto_scroller.dart';
import 'services/reader_progress_service.dart';
import 'services/reader_bookmark_service.dart';
import 'services/reader_key_handler.dart';
import 'services/tap_zone_resolver.dart';
import 'services/long_press_action_handler.dart';
import 'state/reader_search_controller.dart' as rsc;
import 'widgets/reader_settings_sheet.dart';
import 'widgets/reader_search_bar.dart';
import 'widgets/reader_tts_bar.dart';
import 'widgets/reader_control_overlay.dart';
import 'widgets/long_press_action_sheet.dart';

class _LoadedChapter {
  final int index;
  final String title;
  final String content;
  late final List<String> paragraphs;

  _LoadedChapter(this.index, this.title, this.content) {
    paragraphs = content
        .split(RegExp(r'\n+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
  }
}

class _ContinuousItem {
  final int chapterIndex;
  final bool isTitle;
  final bool isDivider;
  final int? paragraphIndex;
  const _ContinuousItem({
    required this.chapterIndex,
    this.isTitle = false,
    this.isDivider = false,
    this.paragraphIndex,
  });
}

class ReaderPage extends ConsumerStatefulWidget {
  final String bookId;
  final int chapterIndex;

  const ReaderPage({
    super.key,
    required this.bookId,
    this.chapterIndex = 0,
  });

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();

  /// Subtask B — 计算 [currentIndex] 邻章对应的 [ChapterWindow]，作为
  /// [PageViewController.setNeighborChapter] 的入参。抽成 static + 暴露
  /// `@visibleForTesting` 便于单测覆盖（不需要构造完整 ReaderPage widget）。
  ///
  /// 安全语义：
  /// - `chapters == null` 或 0 → 返回 (null, null)
  /// - 边界 `currentIndex == 0` → prev=null
  /// - 边界 `currentIndex == chapters.length - 1` → next=null
  /// - 邻章 `content` 为 null/empty → 对应方向 ChapterWindow=null（不灌空内容
  ///   让 controller 测出 0 页）
  ///
  /// **不**在这里做 settings / scrollMode 检查 — 这些是调用方
  /// `_measureAdjacentChapters` 的职责，让本函数纯计算便于测试。
  @visibleForTesting
  static (ChapterWindow?, ChapterWindow?) computeAdjacentWindows(
      int currentIndex, List<Map<String, dynamic>>? chapters) {
    if (chapters == null || chapters.isEmpty) return (null, null);
    if (currentIndex < 0 || currentIndex >= chapters.length) {
      return (null, null);
    }
    ChapterWindow? prev;
    if (currentIndex > 0) {
      final m = chapters[currentIndex - 1];
      final c = m['content'] as String?;
      if (c != null && c.isNotEmpty) {
        prev = ChapterWindow(
          chapterIndex: currentIndex - 1,
          title: m['title'] as String? ?? '',
          content: c,
        );
      }
    }
    ChapterWindow? next;
    if (currentIndex < chapters.length - 1) {
      final m = chapters[currentIndex + 1];
      final c = m['content'] as String?;
      if (c != null && c.isNotEmpty) {
        next = ChapterWindow(
          chapterIndex: currentIndex + 1,
          title: m['title'] as String? ?? '',
          content: c,
        );
      }
    }
    return (prev, next);
  }
}

class _ReaderPageState extends ConsumerState<ReaderPage>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  int _visibleChapterIndex = 0;

  /// Bug 6: 连续滚动模式下，最近一次 _onScroll debounce 触发时识别到的
  /// 段落 index（相对当前 _visibleChapterIndex 那一章）。仅保存进度时使用，
  /// 不影响渲染。
  int _visibleParagraphIndex = 0;
  String _chapterContent = '';
  bool _isLoadingContent = false;
  List<Map<String, dynamic>>? _cachedChapters;
  int _chapterRequestId = 0;
  /// R44: ensure the "替换规则执行失败" snackbar appears at most once per
  /// reader session. Without this guard a chapter that triggers a regex
  /// engine error would spam the user every time they paginate.
  bool _replaceRuleErrorShown = false;
  final ScrollController _scrollController = ScrollController();
  bool _progressRestored = false;

  /// T1 (05-18): saved 章内字符 offset，等首章 [PageViewController.loadChapter]
  /// 完成 typeset 后由 [_openChapter] 通过 postFrameCallback 消费一次：
  /// 调 [PageViewController.getPageIndexByCharOffset] 反算页索引并 jumpToPage。
  /// 跨章 / 后续章节加载不消费（重置为 null 后保持 null）。
  int? _restoreCharOffset;
  Timer? _scrollDebounceTimer;
  Timer? _visibleChapterTimer;
  double _accumulatedOverscroll = 0;
  DateTime? _lastAutoChapterTime;
  bool _controlsVisible = false;
  ReaderSettings _settings = const ReaderSettings();
  bool _readerSettingsLoaded = false;
  List<_LoadedChapter> _loadedChapters = [];
  final GlobalKey _listViewKey = GlobalKey();
  final Map<int, GlobalKey> _chapterTitleKeys = {};
  /// P2-13: GlobalKey for paragraph items in continuous mode, used by
  /// `_restoreProgress` to scroll back to the saved paragraph precisely
  /// (instead of the platform-DPI-dependent average-height estimate).
  ///
  /// Memory budget: only the first [_kParagraphKeyCap] paragraphs of the
  /// current chapter are keyed. Long novels with thousands of paragraphs
  /// fall back to the estimator. The map is keyed by global chapter index
  /// + paragraph index (`(chIndex << 32) | paragraphIndex`) so multiple
  /// loaded chapters don't collide.
  final Map<String, GlobalKey> _paragraphKeys = {};
  static const int _kParagraphKeyCap = 200;
  double _lastScrollOffset = 0;
  bool _isScrollingBackward = false;
  String _bookName = '';
  String _sourceName = '';
  String _sourceUrl = '';
  String _sourceId = '';
  String _chapterUrl = '';
  List<_ContinuousItem>? _cachedContinuousItems;
  bool _isAppendingChapter = false;
  bool _isPrependingChapter = false;
  List<Map<String, dynamic>> _bookmarks = [];
  bool _hasBookmarkForChapter = false;
  double? _sliderValue;
  final ValueNotifier<DateTime> _nowNotifier = ValueNotifier(DateTime.now());
  Timer? _clockTimer;

  /// Bug 3: MD3 isCompleted 门控 — 当前章排版完成前阻断手势。
  /// 在 [_openChapter] 内 loadChapter 后通过 postFrameCallback 翻为 true；
  /// [PageViewWidget] 用此 flag 决定是否 IgnorePointer。
  bool _isPageLayoutReady = false;

  /// 批次 14 (05-19): 阅读时长统计 ticker。每 60s 调
  /// [`rust_api.addReadTime`] 累加 60 秒。后台 / 前台切换通过
  /// [didChangeAppLifecycleState] 把 [_isReadTimePaused] 翻成 true / false
  /// — timer 仍在跑但 callback 早 return，避免重启 timer 导致漂移。
  Timer? _readTimeTicker;
  bool _isReadTimePaused = false;
  bool get _isSearching => _search.isActive;
  TextEditingController get _searchController => _search.textController;
  late final rsc.ReaderSearchController _search =
      rsc.ReaderSearchController(onChanged: () {
    safeSetState(() {});
  });
  bool get _isAutoScrolling => _autoScroller.isRunning;
  late final ReaderAutoScroller _autoScroller = ReaderAutoScroller(
    controller: () => _scrollController,
    onChanged: () {
      safeSetState(() {});
    },
    // 批次 4 (05-18): 分页模式 tick 回调 — 每 pageIntervalMs 触发一次
    // 翻下一页（走与 tap-next 相同的 delegate 动画路径，复用批次 3
    // 的 _doTapNext helper）。pvc 为 null 或到底时 helper 早返回。
    onPageTick: () {
      if (!mounted) return;
      _doTapNext();
    },
    pixelsPerStep: _settings.autoScrollSpeed.toDouble(),
    pageIntervalMs: _settings.autoPageIntervalSeconds * 1000,
  );
  final ReaderProgressService _progressService = ReaderProgressService();
  final ReaderBookmarkService _bookmarkService = ReaderBookmarkService();
  final ReaderTtsManager _tts = ReaderTtsManager();
  PageViewController? _pageViewController;

  /// 批次 2 (05-18): reader 渲染区的 [FocusNode]。让 [Focus.onKeyEvent] 在
  /// reader Activity 前台时拿到物理按键事件（音量键 / PageUp / PageDown /
  /// Space / 方向键），转化为翻页。autofocus 保证打开 reader 立即获焦，
  /// 不需要用户先点屏幕才能用按键翻页。
  final FocusNode _readerFocusNode = FocusNode(debugLabel: 'ReaderPage');

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.chapterIndex;
    _scrollController.addListener(_onScroll);
    loadReaderSettingsFromDisk().then((s) {
      if (mounted) {
        _setReaderSettings(s, markLoaded: true);
      }
    }).catchError((Object e) {
      // T1 followup #2：磁盘读失败也要置 _readerSettingsLoaded=true，
      // 避免 build() 永远卡在 loading 不触发 _restoreProgress。
      debugPrint('[Reader] loadReaderSettingsFromDisk failed: $e');
      if (mounted) {
        setState(() {
          _readerSettingsLoaded = true;
        });
        // 批次 1 (05-18): 即使磁盘读失败也要应用默认硬件设置（默认开常亮）。
        _applyHardwareSettings(_settings);
      }
    });
    _loadBookmarks();
    _tts.init(
      rate: _settings.ttsSpeed,
      onStateChanged: () {
        safeSetState(() {});
      },
      onChapterEndReached: () async {
        // Advance to next chapter and continue speaking with new content.
        _goToNextChapter();
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          _tts.setChapterContent(_chapterContent);
          await _tts.resumeAfterChapterAdvance();
        });
      },
    );
    _fetchBookName();
    _pageViewController = PageViewController(
      settings: _settings,
      initialChapterIndex: widget.chapterIndex,
    );
    _pageViewController!.addListener(_onPageChanged);
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _nowNotifier.value = DateTime.now();
    });
    // 批次 14 (05-19): 阅读时长 ticker + 生命周期监听。
    WidgetsBinding.instance.addObserver(this);
    _readTimeTicker = Timer.periodic(const Duration(seconds: 60), (_) {
      _onReadTimeTick();
    });
  }

  @override
  void dispose() {
    // 批次 1 (05-18): 关键 — reader 退出必复位 wakelock + 应用级亮度，
    // 避免回到书架后系统仍保持常亮 / 亮度被 reader 设置污染。两个 plugin
    // 调用都包 try-catch：plugin 在 desktop / 单测环境可能不可用，但不应
    // 让正常的 super.dispose() 资源释放被打断。
    try {
      WakelockPlus.disable();
    } catch (e) {
      debugPrint('[Reader] dispose wakelock disable failed: $e');
    }
    try {
      ScreenBrightness().resetApplicationScreenBrightness();
    } catch (e) {
      debugPrint('[Reader] dispose reset screen brightness failed: $e');
    }
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _scrollDebounceTimer?.cancel();
    _visibleChapterTimer?.cancel();
    _clockTimer?.cancel();
    // 批次 14 (05-19): 关 ticker + 解除生命周期监听。
    _readTimeTicker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _autoScroller.dispose();
    _search.dispose();
    _tts.dispose();
    _nowNotifier.dispose();
    if (_pageViewController != null) {
      try {
        _pageViewController!.removeListener(_onPageChanged);
        _pageViewController!.dispose();
      } catch (e) {
        debugPrint('[Reader] dispose pageViewController failed: $e');
      }
    }
    _readerFocusNode.dispose();
    super.dispose();
  }

  /// 批次 1 (05-18): 把 [ReaderSettings.screenBrightness] /
  /// [ReaderSettings.keepScreenOn] 同步到原生 plugin。
  ///
  /// - `keepScreenOn`：true → [WakelockPlus.enable]，false → disable。
  /// - `screenBrightness`：>= 0 → [ScreenBrightness.setApplicationScreenBrightness]
  ///   （应用级亮度，仅在前台时影响显示，退出 reader 由 [dispose] 调
  ///   [ScreenBrightness.resetApplicationScreenBrightness] 复位）；
  ///   < 0（哨兵值 -1.0）→ 主动 reset，让系统亮度接管。
  ///
  /// 整个方法包 try-catch：在 Linux / 单测环境 plugin 没有 native impl，
  /// 调用会抛 [MissingPluginException]，但 reader 不应因此崩溃。
  Future<void> _applyHardwareSettings(ReaderSettings s) async {
    try {
      if (s.keepScreenOn) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (e) {
      debugPrint('[Reader] wakelock toggle failed: $e');
    }
    try {
      if (s.screenBrightness >= 0) {
        // 钳到 [0, 1]：UI Slider 给的是 0..100 整数除 100，已经在范围内；
        // 多一道防御避免错误持久化把异常值推到 plugin 引发 RangeError。
        final v = s.screenBrightness.clamp(0.0, 1.0);
        await ScreenBrightness().setApplicationScreenBrightness(v);
      } else {
        await ScreenBrightness().resetApplicationScreenBrightness();
      }
    } catch (e) {
      debugPrint('[Reader] screen brightness apply failed: $e');
    }
  }

  /// 批次 14 (05-19): 阅读时长 ticker 回调。每 60s 触发一次，调
  /// [`rust_api.addReadTime`] 把 60s 累加到该书的 `read_records` 行。
  /// fire-and-forget；DB IO 在 Rust 端 spawn_blocking 跑，不阻塞 UI。
  Future<void> _onReadTimeTick() async {
    if (_isReadTimePaused) return;
    final bookId = widget.bookId;
    if (bookId.isEmpty) return;
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      await rust_api.addReadTime(
        dbPath: dbPath,
        bookId: bookId,
        bookName: _bookName,
        deltaSeconds: 60,
      );
    } catch (e) {
      debugPrint('[Reader] addReadTime failed: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 批次 14 (05-19): 后台暂停 ticker 累加，前台恢复。注意 timer 本身
    // 不停只是 callback 早 return，避免重启 timer 导致 60s 周期漂移。
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _isReadTimePaused = true;
        break;
      case AppLifecycleState.resumed:
        _isReadTimePaused = false;
        break;
    }
  }

  @override
  void didUpdateWidget(ReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId) {
      // R66: wrap the reset in setState so the UI flips to the loading
      // state immediately. Without setState, build() still runs (the
      // widget rebuilt because props changed) and reads _chapterContent,
      // but if the framework decides to skip the rebuild — e.g. when
      // didUpdateWidget is the only change source — we'd render the old
      // chapter until _loadBookmarks completes asynchronously.
      setState(() {
        _chapterRequestId++;
        _cachedChapters = null;
        _chapterContent = '';
        _loadedChapters = [];
        _currentIndex = widget.chapterIndex;
        _isLoadingContent = false;
        _bookmarks = [];
        _hasBookmarkForChapter = false;
        _replaceRuleErrorShown = false;
      });
      _loadBookmarks();
    }
  }

  Future<void> _fetchBookName() async {
    try {
      final book = await ref.read(bookByIdProvider(widget.bookId).future);
      if (book != null && mounted) {
        setState(() => _bookName = book['name'] as String? ?? '');
      }
    } catch (e) {
      debugPrint('[Reader] fetchBookName failed: $e');
    }
  }

  Future<void> _fetchSourceInfo() async {
    try {
      final book = await ref.read(bookByIdProvider(widget.bookId).future);
      if (book != null && mounted) {
        // BATCH-19a (F-W2A-007): 4 个赋值移进 setState callback。原版在
        // setState 外赋值再调 setState(() {})，是反模式：本次 build 已经
        // 读过旧值，赋值需要由 setState 标脏才会被下一帧拾起。
        setState(() {
          _sourceName = book['source_name'] as String? ?? '';
          _sourceUrl = book['source_url'] as String? ?? '';
          if (_sourceId.isEmpty) {
            _sourceId = book['source_id'] as String? ?? '';
          }
          if (_cachedChapters != null &&
              _currentIndex < _cachedChapters!.length) {
            _chapterUrl =
                _cachedChapters![_currentIndex]['url'] as String? ?? '';
          }
        });
      }
    } catch (e) {
      debugPrint('[Reader] fetchSourceInfo failed: $e');
    }
  }

  Future<String> _loadChapterContent(
      int index, List<Map<String, dynamic>> chapters) async {
    final stopwatch = Stopwatch()..start();
    debugPrint('[Reader.timing] _loadChapterContent ch=$index START');
    final chContent = chapters[index]['content'] as String?;
    if (chContent != null && chContent.isNotEmpty) {
      debugPrint(
          '[Reader.timing] _loadChapterContent ch=$index cache HIT, len=${chContent.length} t=${stopwatch.elapsedMilliseconds}ms');
      final dbPath2 = await ref.read(dbPathProvider.future);
      debugPrint(
          '[Reader.timing] _loadChapterContent ch=$index dbPath ready t=${stopwatch.elapsedMilliseconds}ms');
      final content = await _applyReplaceRulesViaRust(dbPath2, chContent);
      debugPrint(
          '[Reader.timing] _loadChapterContent ch=$index applyReplaceRules done t=${stopwatch.elapsedMilliseconds}ms');
      final cleaned = _cleanHtml(content);
      debugPrint(
          '[Reader.timing] _loadChapterContent ch=$index cleanHtml done TOTAL=${stopwatch.elapsedMilliseconds}ms');
      return cleaned;
    }
    debugPrint(
        '[Reader.timing] _loadChapterContent ch=$index cache MISS, going to fetch');
    final book = await ref.read(bookByIdProvider(widget.bookId).future);
    final dbPath = await ref.read(dbPathProvider.future);
    debugPrint(
        '[Reader.timing] _loadChapterContent ch=$index book+dbPath ready t=${stopwatch.elapsedMilliseconds}ms');
    // Always use book's source_id when state is empty (fresh open)
    if (_sourceId.isEmpty && book != null) {
      _sourceId = book['source_id'] as String? ?? '';
      _sourceName = book['source_name'] as String? ?? '';
      _sourceUrl = book['source_url'] as String? ?? '';
    }
    final sourceId = _sourceId.isNotEmpty
        ? _sourceId
        : (book?['source_id'] as String? ?? '');
    final chapterUrl = chapters[index]['url'] as String? ?? '';

    String content = '无法获取章节内容（缺少书源或章节链接）';
    if (sourceId.isNotEmpty && chapterUrl.isNotEmpty) {
      final json = await rust_api.getChapterContentWithSourceFromDb(
        dbPath: dbPath,
        sourceId: sourceId,
        chapterUrl: chapterUrl,
      ).timeout(const Duration(seconds: 5));
      if (json.isNotEmpty && json != 'null') {
        try {
          final data = jsonDecode(json);
          if (data is Map<String, dynamic>) {
            final platformRequest = data['platform_request'];
            if (platformRequest is Map) {
              content = await _executePlatformRequest(
                PlatformRequest.fromJson(
                    Map<String, dynamic>.from(platformRequest)),
              );
              if (_isCacheablePlatformContent(content)) {
                try {
                  await rust_api.updateChapterContent(
                    dbPath: dbPath,
                    chapterId: chapters[index]['id'] as String? ?? '',
                    content: content,
                  );
                  chapters[index]['content'] = content;
                } catch (e) {
                  debugPrint('[Reader] cache platform content failed: $e');
                }
              }
            } else {
              content = data['content'] as String? ?? '（无内容）';
              // T3 (05-18) 修复：普通解析路径下 Rust 端 get_chapter_content
              // _with_source_from_db 只 fetch 不写库，导致每次重开 app 都
              // 要重新跑 BookSourceParser 跨网络拉一次（用户感知 2-3s 卡顿）。
              // 这里在拿到内容后立即 updateChapterContent + chapters[i]['content']
              // = content 把缓存灌进 DB，下次重开同书 cache HIT 直接秒开。
              if (content.isNotEmpty && content != '（无内容）') {
                try {
                  await rust_api.updateChapterContent(
                    dbPath: dbPath,
                    chapterId: chapters[index]['id'] as String? ?? '',
                    content: content,
                  );
                  chapters[index]['content'] = content;
                } catch (e) {
                  debugPrint('[Reader] cache plain content failed: $e');
                }
              }
            }
          } else {
            content = data.toString();
          }
        } catch (e) {
          debugPrint('[Reader] decode chapter response failed: $e');
          content = json;
        }
      }
    }

    content = await _applyReplaceRulesViaRust(dbPath, content);

    return _cleanHtml(content);
  }

  /// P1-7: 单次 FRB 调用代替之前 Dart 主 isolate 的 RegExp 循环。
  /// 失败时记录日志、提示一次 toast、然后退回原始内容（向后兼容，
  /// 优先保证用户能继续读，但不再让规则失效悄无声息）。
  ///
  /// R24: 把 [_bookName] 与 [_sourceUrl] 传给 Rust，让 scope 子串
  /// 匹配能正确判断这条规则是否对当前书生效。`_sourceUrl` 对应原
  /// Legado `book.origin` 字段（书源 URL，不是 source.id）。
  ///
  /// R105: `_fetchBookName` / `_fetchSourceInfo` 是 async，与第一章
  /// `_loadChapter` 并发；如果章节加载先完成，本方法看到的
  /// `_bookName` / `_sourceUrl` 会是空串，scope 限定的规则就会被
  /// Rust 端 R24 过滤逻辑当成 "empty caller context" 跳过，导致用户
  /// 看到第一章规则没生效但第二章生效。这里用 `bookByIdProvider`
  /// 兜底把 metadata 同步加载好再调 Rust。该 provider 是 FutureProvider
  /// 已做缓存，重复 await 同一 future 不会重复查询数据库。
  ///
  /// R115: 回填用 setState 是因为 `_bookName` / `_sourceUrl` 也被
  /// AppBar 标题、change-source 对话框等读取，需要立即触发 rebuild
  /// 而不是等下一次自然 setState；否则用户在并发 race 命中时会看到
  /// AppBar 暂时显示空标题。
  Future<String> _applyReplaceRulesViaRust(
      String dbPath, String content) async {
    if (content.isEmpty) return content;
    final stopwatch = Stopwatch()..start();
    debugPrint(
        '[Reader.timing] applyReplaceRules START, content.len=${content.length} bookName=${_bookName.isEmpty ? "<empty>" : _bookName} sourceUrl=${_sourceUrl.isEmpty ? "<empty>" : "${_sourceUrl.substring(0, _sourceUrl.length.clamp(0, 40))}..."}');
    if (_bookName.isEmpty || _sourceUrl.isEmpty) {
      debugPrint(
          '[Reader.timing] applyReplaceRules R105 backfill needed');
      try {
        final book =
            await ref.read(bookByIdProvider(widget.bookId).future);
        debugPrint(
            '[Reader.timing] applyReplaceRules bookByIdProvider done t=${stopwatch.elapsedMilliseconds}ms');
        if (book != null && mounted) {
          // R115: setState 让 AppBar 标题 / change-source 对话框等
          // 读取这两个字段的 widget 立即 rebuild。
          setState(() {
            if (_bookName.isEmpty) {
              _bookName = book['name'] as String? ?? '';
            }
            if (_sourceUrl.isEmpty) {
              _sourceUrl = book['source_url'] as String? ?? '';
            }
          });
        }
      } catch (e) {
        debugPrint('[Reader] R105 backfill book metadata failed: $e');
        // R116: 永久性 DB 错误会导致 scope 限定规则始终不生效却没有
        // 任何 UI 反馈。复用 `_replaceRuleErrorShown` 单次守卫，避免
        // 与下面 applyReplaceRules 失败 toast 双重弹窗。
        if (mounted && !_replaceRuleErrorShown) {
          _replaceRuleErrorShown = true;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('无法读取书籍信息，替换规则可能未按作用范围生效'),
              duration: Duration(seconds: 4),
            ),
          );
        }
        // Fall through — the rule call will still proceed with whatever
        // is populated (possibly empty), matching pre-R105 behaviour.
      }
    }
    try {
      final generation = ref.read(replaceRuleGenerationProvider);
      debugPrint(
          '[Reader.timing] applyReplaceRules calling Rust applyReplaceRules t=${stopwatch.elapsedMilliseconds}ms');
      final result = await rust_api.applyReplaceRules(
        dbPath: dbPath,
        content: content,
        cacheGeneration: generation,
        bookName: _bookName.isNotEmpty ? _bookName : null,
        bookOrigin: _sourceUrl.isNotEmpty ? _sourceUrl : null,
        applyToTitle: false,
      );
      debugPrint(
          '[Reader.timing] applyReplaceRules Rust returned len=${result.length} TOTAL=${stopwatch.elapsedMilliseconds}ms');
      return result;
    } catch (e) {
      debugPrint('[Reader] applyReplaceRules failed: $e');
      // R44: surface the failure once so the user knows their replace
      // rules aren't being applied (e.g. catastrophic-backtracking
      // regex, panic in core-source, FRB transport error). Subsequent
      // failures within the same session stay silent to avoid spam.
      if (mounted && !_replaceRuleErrorShown) {
        _replaceRuleErrorShown = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('替换规则执行失败，已显示原始章节内容'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      return content;
    }
  }

  String _cleanHtml(String text) {
    return text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'<[^>]+>'), '');
  }

  Future<void> _openChapter(
      int index, List<Map<String, dynamic>> chapters) async {
    if (chapters.isEmpty) {
      if (mounted) {
        setState(() {
          _chapterContent = '暂无章节';
          _isLoadingContent = false;
          _currentIndex = 0;
        });
      }
      return;
    }
    if (index < 0 || index >= chapters.length) {
      if (mounted) {
        setState(() {
          _chapterContent = '章节索引越界';
          _isLoadingContent = false;
          _currentIndex = index.clamp(0, chapters.length - 1);
        });
      }
      return;
    }
    _cachedChapters = chapters;
    final requestId = ++_chapterRequestId;
    setState(() {
      _isLoadingContent = true;
      _currentIndex = index;
    });
    try {
      final content = await _loadChapterContent(index, chapters);
      if (!mounted || requestId != _chapterRequestId) return;
      // T1 (05-18) 修复：删除原来此处的 rust_api.saveReadingProgress(offset:0)
      // 强写。该写入会**覆盖** _restoreProgress 刚 load 出来的 saved offset，
      // 让 _consumeRestoreCharOffsetIfNeeded 内存里 jumpToPage 到正确页之前
      // DB 已经被回写成 offset=0；如果 jumpToPage 后的 _onPageChanged save
      // 没成功跑（用户立刻 kill / listener 顺序异常），重开就只能恢复到章首页。
      // 进度保存改为完全由 _onPageChanged → _saveCurrentPagePosition 驱动：
      // 用户首次翻页 / jumpToPage 触发的 page changed listener 会自然写入。
      // 首次开书未翻页就退出 → DB 无记录，下次仍走 widget.chapterIndex fallback，
      // 行为等价。
      final title = index < chapters.length
          ? (chapters[index]['title'] as String? ?? '')
          : '';
      setState(() {
        _chapterContent = content;
        _isLoadingContent = false;
        if (_settings.isScrollMode) {
          _loadedChapters = [_LoadedChapter(index, title, content)];
          _cachedContinuousItems = null;
        } else {
          _pageViewController?.updateSettings(_settings);
          _pageViewController?.loadChapter(index, title, content);
          _isPageLayoutReady = false;
        }
      });
      // T1 (05-18): page-mode 启动恢复链路最后一步 — measure 完后通过
      // postFrameCallback 反算 saved char offset 对应页并 jumpToPage。
      // 只在首章加载时消费一次（_restoreProgress 把 offset 写进
      // _restoreCharOffset），后续跨章 / 跳章 _restoreCharOffset 已是 null
      // 直接跳过。
      _consumeRestoreCharOffsetIfNeeded();
      await _ensureAdjacentChaptersReady(index, chapters);
      _measureAdjacentChapters(index);
      if (mounted) safeSetState(() => _isPageLayoutReady = true);
      _fetchSourceInfo();
      _preCacheNextChapter(index, chapters);
      _preCachePrevChapter(index, chapters);
    } catch (e) {
      if (!mounted || requestId != _chapterRequestId) return;
      // Bug 2: TimeoutException → show retryable error message
      final errorMsg = e is TimeoutException ? '正文加载失败' : '加载失败: $e';
      setState(() {
        _chapterContent = errorMsg;
        _isLoadingContent = false;
      });
    }
  }

  void _setReaderSettings(ReaderSettings settings,
      {bool persist = false, bool markLoaded = false}) {
    final wasScroll = _settings.isScrollMode;
    final isNowScroll = settings.isScrollMode;
    // 批次 1 (05-18): 比对硬件相关字段的旧/新值，只有变化时（或首次
    // markLoaded 灌盘上设置时）才调 plugin，避免每次字号微调都重复 enable
    // wakelock。
    final hardwareChanged =
        _settings.screenBrightness != settings.screenBrightness ||
            _settings.keepScreenOn != settings.keepScreenOn;
    setState(() {
      if (markLoaded) {
        _readerSettingsLoaded = true;
      }
      _settings = settings;
      if (!wasScroll && isNowScroll) {
        _ensureCurrentChapterInContinuous();
      } else if (wasScroll && !isNowScroll && _chapterContent.isNotEmpty) {
        final title =
            _cachedChapters != null && _currentIndex < _cachedChapters!.length
                ? (_cachedChapters![_currentIndex]['title'] as String? ?? '')
                : '';
        _pageViewController?.loadChapter(_currentIndex, title, _chapterContent);
      }
    });
    ref.read(readerSettingsProvider.notifier).state = settings;
    _pageViewController?.updateSettings(settings);
    // Subtask B.6: 排版字段变化时 PageViewController.updateSettings 已自动清三章
    // pages，但邻章 paragraphs 也整个清掉了（见 controller 注释 A.4），需要外
    // 层重新灌一次邻章；再走一次 measure 让 boundaryNextPage / boundaryPrevPage
    // 在新字号 / 行距下重新就位。滚动模式跳过（_measureAdjacentChapters 内部已
    // 处理）。
    if (!settings.isScrollMode) {
      _measureAdjacentChapters(_currentIndex);
    }
    if (persist) {
      saveReaderSettingsToDisk(settings);
    }
    // 批次 1 (05-18): markLoaded 时一定要 apply（即便与 default 相同——
    // 用户期望默认进 reader 即开常亮）；后续 setting 变化只在硬件字段
    // 变化时 apply。
    if (hardwareChanged || markLoaded) {
      _applyHardwareSettings(settings);
    }
    // 批次 4 (05-18): 自动翻页速度 / 间隔运行时同步给 ReaderAutoScroller，
    // 用户从设置里改完滑杆下次启动 / 当前正在跑的任务都用最新参数。
    _autoScroller.pixelsPerStep = settings.autoScrollSpeed.toDouble();
    _autoScroller.pageIntervalMs = settings.autoPageIntervalSeconds * 1000;
  }

  void _ensureCurrentChapterInContinuous() {
    if (_chapterContent.isEmpty) return;
    final currentLoaded = _loadedChapters.length == 1 &&
        _loadedChapters.first.index == _currentIndex &&
        _loadedChapters.first.content == _chapterContent;
    if (currentLoaded) return;
    final title =
        _cachedChapters != null && _currentIndex < _cachedChapters!.length
            ? (_cachedChapters![_currentIndex]['title'] as String? ?? '')
            : '';
    _loadedChapters = [_LoadedChapter(_currentIndex, title, _chapterContent)];
    _visibleChapterIndex = _currentIndex;
    _cachedContinuousItems = null;
    _chapterTitleKeys.clear();
    _paragraphKeys.clear();
  }

  /// P2-13 helper: combine global chapter index + paragraph index into a
  /// `Map` key that's collision-free across chapters.
  ///
  /// R45: previously this packed both indices into a single 64-bit int
  /// via `chapterIndex << 32 | paragraphIndex`. That works on the
  /// Dart VM (native ints) but breaks on dart2js / dart2wasm where Dart
  /// `int` is a JS double: shifts are taken modulo 32, so for any
  /// `chapterIndex >= 1` the high bits are silently truncated and
  /// `(2 << 32) | 0` collapses to `2 | 0 == 2`. Using a string key
  /// sidesteps the entire 53-bit-mantissa hazard at the cost of one
  /// allocation per lookup, which is fine here — these keys are only
  /// minted while building the visible chunk of the scroll view.
  String _paragraphKeyId(int chapterIndex, int paragraphIndex) {
    return '$chapterIndex|$paragraphIndex';
  }

  Future<void> _appendNextChapter() async {
    if (_cachedChapters == null || _isAppendingChapter || _isLoadingContent)
      return;
    final chapters = _cachedChapters!;
    final lastLoaded =
        _loadedChapters.isNotEmpty ? _loadedChapters.last.index : _currentIndex;
    final nextIndex = lastLoaded + 1;
    if (nextIndex >= chapters.length) return;
    _isAppendingChapter = true;
    setState(() {});
    try {
      final content = await _loadChapterContent(nextIndex, chapters);
      if (!mounted) return;
      final title = chapters[nextIndex]['title'] as String? ?? '';
      setState(() {
        _loadedChapters.add(_LoadedChapter(nextIndex, title, content));
        _visibleChapterIndex = nextIndex;
        _cachedContinuousItems = null;
        _isAppendingChapter = false;
      });
      _preCacheNextChapter(nextIndex, chapters);
    } catch (e) {
      debugPrint('[Reader] appendNextChapter failed: $e');
      safeSetState(() => _isAppendingChapter = false);
    }
  }

  Future<void> _prependPrevChapter() async {
    if (_cachedChapters == null || _isPrependingChapter || _isLoadingContent)
      return;
    final chapters = _cachedChapters!;
    final firstLoaded = _loadedChapters.isNotEmpty
        ? _loadedChapters.first.index
        : _currentIndex;
    final prevIndex = firstLoaded - 1;
    if (prevIndex < 0) return;
    _isPrependingChapter = true;
    setState(() {});
    try {
      final content = await _loadChapterContent(prevIndex, chapters);
      if (!mounted) return;
      final title = chapters[prevIndex]['title'] as String? ?? '';
      final prevChapter = _LoadedChapter(prevIndex, title, content);
      final oldExtent = _scrollController.hasClients
          ? _scrollController.position.maxScrollExtent
          : 0.0;
      final oldOffset =
          _scrollController.hasClients ? _scrollController.offset : 0.0;
      setState(() {
        _loadedChapters.insert(0, prevChapter);
        _visibleChapterIndex = prevIndex;
        _cachedContinuousItems = null;
        _isPrependingChapter = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          final newExtent = _scrollController.position.maxScrollExtent;
          final addedHeight = newExtent - oldExtent;
          if (addedHeight > 0) {
            _scrollController.jumpTo(oldOffset + addedHeight);
          }
        }
      });
    } catch (e) {
      debugPrint('[Reader] prependPrevChapter failed: $e');
      safeSetState(() => _isPrependingChapter = false);
    }
  }

  Future<void> _resetContinuousStream(int index) async {
    if (_cachedChapters == null) return;
    await _openChapter(index, _cachedChapters!);
  }

  Future<String> _executePlatformRequest(PlatformRequest request) async {
    if (request.type == 'web_view_content') {
      try {
        final result =
            await PlatformWebViewExecutor().execute(context, request);
        if (result.sourceRegexRequired) {
          if (result.sourceRegexMatched && result.resourceUrl != null) {
            return result.resourceUrl!;
          }
          return result.content.isEmpty
              ? 'WebView 已执行，但未嗅探到匹配 sourceRegex 的资源。'
              : '${result.content}\n\n（提示：该书源配置了 sourceRegex，但未嗅探到匹配资源，结果可能不完整。）';
        }
        return result.content.isEmpty
            ? _platformRequestMessage(request)
            : result.content;
      } catch (e) {
        return '${_platformRequestMessage(request)}\n\n执行失败: $e';
      }
    }
    return _platformRequestMessage(request);
  }

  String _platformRequestMessage(PlatformRequest request) {
    if (request.type == 'web_view_content') {
      return '本章需要 Android WebView 执行后才能解析。\n\n'
          'URL: ${request.url ?? ''}\n\n'
          '当前版本已接入 Android 原生 WebView 执行器，原生不可用时会回退到 Flutter WebView。';
    }
    return '本章需要平台能力执行: ${request.type}';
  }

  bool _isCacheablePlatformContent(String content) {
    if (content.isEmpty) return false;
    return !content.startsWith('本章需要') &&
        !content.startsWith('WebView 已执行') &&
        !content.startsWith('WEBVIEW_JS_ERROR:');
  }

  void _goToNextChapter() {
    if (_cachedChapters == null) return;
    final chapters = _cachedChapters!;
    if (_currentIndex < chapters.length - 1) {
      final target = _currentIndex + 1;
      _visibleChapterIndex = target;
      if (_settings.isScrollMode) {
        _resetContinuousStream(target);
      } else {
        _openChapter(target, chapters);
      }
    }
  }

  void _goToPrevChapter() {
    if (_cachedChapters == null) return;
    final chapters = _cachedChapters!;
    if (_currentIndex > 0) {
      final target = _currentIndex - 1;
      _visibleChapterIndex = target;
      if (_settings.isScrollMode) {
        _resetContinuousStream(target);
      } else {
        _openChapter(target, chapters);
      }
    }
  }

  bool _onOverscroll(OverscrollNotification notification) {
    if (_isLoadingContent) return false;
    final chapters = _cachedChapters;
    if (chapters == null || _currentIndex >= chapters.length - 1) return false;
    final now = DateTime.now();
    if (_lastAutoChapterTime != null &&
        now.difference(_lastAutoChapterTime!).inMilliseconds < 1000) {
      return false;
    }
    _accumulatedOverscroll += notification.overscroll;
    if (_accumulatedOverscroll > 80) {
      _lastAutoChapterTime = now;
      _accumulatedOverscroll = 0;
      _goToNextChapter();
    }
    return false;
  }

  Future<void> _startDownload(BuildContext context) async {
    try {
      final book = await ref.read(bookByIdProvider(widget.bookId).future);
      if (book == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未找到书籍信息')),
          );
        }
        return;
      }

      final sourceId = book['source_id'] as String? ?? '';
      if (sourceId.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该书未关联书源，无法缓存')),
          );
        }
        return;
      }

      final chapters = _cachedChapters ??
          (await ref.read(bookChaptersProvider(widget.bookId).future) ?? []);
      if (chapters.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('暂无章节可缓存')),
          );
        }
        return;
      }

      final dbPath = await ref.read(dbPathProvider.future);
      final downloadDir = await ref.read(downloadDirProvider.future);

      final existingJson = await rust_api.getDownloadTaskByBook(
        dbPath: dbPath,
        bookId: widget.bookId,
      );
      final List<dynamic> existingTasks = jsonDecode(existingJson);
      if (existingTasks.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该书已有缓存任务')),
          );
        }
        return;
      }

      final sourceJson = await rust_api.getSourceForDownload(
        dbPath: dbPath,
        sourceId: sourceId,
      );

      final taskId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final task = {
        'id': taskId,
        'book_id': widget.bookId,
        'book_name': book['name'] ?? '',
        'cover_url': book['cover_url'],
        'total_chapters': chapters.length,
        'downloaded_chapters': 0,
        'status': 1,
        'total_size': 0,
        'downloaded_size': 0,
        'error_message': null,
        'created_at': now,
        'updated_at': now,
      };

      final chapterRecords = <Map<String, dynamic>>[];
      for (var i = 0; i < chapters.length; i++) {
        final ch = chapters[i];
        chapterRecords.add({
          'id': '${taskId}_$i',
          'task_id': taskId,
          'chapter_id': ch['id'] ?? '',
          'chapter_index': i,
          'chapter_title': ch['title'] ?? '',
          'status': 0,
          'file_path': null,
          'file_size': 0,
          'error_message': null,
          'created_at': now,
          'updated_at': now,
        });
      }

      await rust_api.createDownloadTaskWithChapters(
        dbPath: dbPath,
        taskJson: jsonEncode(task),
        chaptersJson: jsonEncode(chapterRecords),
      );

      final bookName = book['name'] as String? ?? '';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('开始缓存 $bookName (${chapters.length}章)')),
        );
      }

      DownloadRunner().enqueue(
        taskId: taskId,
        bookName: bookName,
        chapters: chapters,
        sourceJson: sourceJson,
        downloadDir: downloadDir,
        dbPath: dbPath,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('缓存失败: $e')),
        );
      }
    }
  }

  void _onScroll() {
    // BATCH-19a (F-W2A-006): 拆分防抖路径——save 路径独占 debounce，
    // visible chapter / backward detect / append-prepend 路径不被早 return
    // 拦下。原版在 save debounce 命中时整个 _onScroll early return，
    // 长程滚动期间章节标题不更新、章节追加/前置触发完全靠运气。
    //
    // 1) 保存滚动位置：仅本路径用 _scrollDebounceTimer 防抖（500ms 节流），
    //    timer 在 fire 后置 null 让下一次 _onScroll 重新 schedule。
    if (_scrollDebounceTimer == null) {
      _scrollDebounceTimer = Timer(const Duration(milliseconds: 500), () {
        _scrollDebounceTimer = null;
        _saveScrollPosition();
      });
    }

    // 2) 可见章节更新：300ms 防抖；用 ??= 保证窗口内只 schedule 一次，
    //    不与 save debounce 互相拦截。
    _visibleChapterTimer ??=
        Timer(const Duration(milliseconds: 300), () {
      _visibleChapterTimer = null;
      _updateVisibleChapter();
    });

    // 3) 反向滚动检测——必须每帧执行，不能被 debounce 拦下，否则用户
    //    在窗口内反向滑动时 _isScrollingBackward 不更新。
    if (_scrollController.hasClients) {
      final currentOffset = _scrollController.offset;
      _isScrollingBackward = currentOffset < _lastScrollOffset;
      _lastScrollOffset = currentOffset;
    }

    // 4) 滚动模式追加 / 前置章节——临界滚动到边缘时立即触发，否则
    //    debounce 期间用户滚到底也不会拼下一章。
    if (_settings.isScrollMode &&
        _scrollController.hasClients &&
        !_isAppendingChapter &&
        !_isPrependingChapter) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.position.pixels;
      if (maxScroll - currentScroll < 300) {
        _appendNextChapter();
      } else if (currentScroll < 300) {
        _prependPrevChapter();
      }
    }
  }

  void _updateVisibleChapter() {
    if (!_scrollController.hasClients) return;
    if (_loadedChapters.isEmpty) return;
    if (!_settings.isScrollMode) return;
    final listBox =
        _listViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (listBox == null || !listBox.hasSize) return;
    final listTop = listBox.localToGlobal(Offset.zero).dy;
    final viewportHeight = _scrollController.position.viewportDimension;
    final threshold = viewportHeight / 3;

    int? inZoneChapter;
    for (final ch in _loadedChapters) {
      final key = _chapterTitleKeys[ch.index];
      if (key == null) continue;
      final ctx = key.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final titleTop = box.localToGlobal(Offset.zero).dy - listTop;
      if (titleTop >= 0 && titleTop <= threshold) {
        inZoneChapter = ch.index;
        break;
      }
    }

    if (inZoneChapter != null) {
      if (_visibleChapterIndex != inZoneChapter) {
        _switchChapter(inZoneChapter);
      }
      return;
    }

    if (_isScrollingBackward) {
      final currentIdx =
          _loadedChapters.indexWhere((ch) => ch.index == _visibleChapterIndex);
      if (currentIdx > 0) {
        _switchChapter(_loadedChapters[currentIdx - 1].index);
      }
    }

    // Bug 6: 章节定位结束后，再算一次当前段落 index 用于进度保存
    _updateVisibleParagraph();
  }

  void _switchChapter(int chapterIndex) {
    if (_visibleChapterIndex == chapterIndex) return;
    _visibleChapterIndex = chapterIndex;
    if (_cachedChapters != null && chapterIndex < _cachedChapters!.length) {
      _chapterUrl = _cachedChapters![chapterIndex]['url'] as String? ?? '';
    }
    setState(() {});
  }

  Future<void> _saveScrollPosition() async {
    if (!_scrollController.hasClients || _chapterContent.isEmpty) return;
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final isContinuous =
          _settings.isScrollMode;
      final idx = isContinuous ? _visibleChapterIndex : _currentIndex;
      // Bug 6 fix: 连续滚动模式下，全局 _scrollController.offset 不可移植
      // （ListView 是动态滑动窗口，下次 _loadedChapters 数量变了 offset 没意义）。
      // 改存当前可见 paragraph index，恢复时按平均段高估算位置。
      // 分页模式仍存 offset（PageViewWidget 内部稳定）。
      final paragraphIdx = isContinuous ? _visibleParagraphIndex : 0;
      final offset = isContinuous ? 0 : _scrollController.offset.toInt();
      await _progressService.save(
        dbPath: dbPath,
        bookId: widget.bookId,
        chapterIndex: idx,
        paragraphIndex: paragraphIdx,
        offset: offset,
      );
    } catch (e) {
      debugPrint('[Reader] saveScrollPosition failed: $e');
    }
  }

  Future<void> _restoreProgress(List<Map<String, dynamic>> chapters) async {
    if (chapters.isEmpty) return;
    final dbPath = await ref.read(dbPathProvider.future);
    final saved = await _progressService.load(
      dbPath: dbPath,
      bookId: widget.bookId,
    );
    debugPrint(
        '[Reader.T1] restoreProgress: saved=$saved bookId=${widget.bookId} settingsLoaded=$_readerSettingsLoaded pageAnim=${_settings.pageAnim} isScrollMode=${_settings.isScrollMode}');
    if (saved == null) {
      debugPrint(
          '[Reader.T1] restoreProgress: NO saved, fallback widget.chapterIndex=${widget.chapterIndex}');
      await _openChapter(widget.chapterIndex, chapters);
      return;
    }
    final savedIndex = saved.chapterIndex;
    final savedOffset = saved.offset;
    final savedParagraph = saved.paragraphIndex;
    if (savedIndex < 0 || savedIndex >= chapters.length) {
      debugPrint(
          '[Reader.T1] restoreProgress: savedIndex=$savedIndex out of bounds (chapters=${chapters.length}), bail');
      return;
    }

    final isContinuous = _settings.isScrollMode;
    // T1 (05-18): page mode 下把 savedOffset 存起来，让 _openChapter 完成
    // loadChapter 后通过 postFrameCallback 一次性消费 — controller
    // measure 完才能用 getPageIndexByCharOffset 反算页索引。续章 / 后续
    // 章节加载不消费（消费后清成 null）。
    //
    // T1 (05-18) 修复：去掉 `savedOffset > 0` 的 guard。原 guard 假设
    // page 0 的 startCharOffset 必然是 0、其它页必 > 0；但 page_measure
    // 旧 bug 让 page 1 也是 0（段内分页路径漏算 startOffset 累加），用户
    // 停在 page 1 saved offset=0 重开就被这个 guard 跳过，落回章首页。
    // 现在改为：只要 saved 非空 + chapter 合法就触发恢复路径；
    // savedOffset==0 时 _consumeRestoreCharOffsetIfNeeded 内
    // getPageIndexByCharOffset(0) 返回 0，jumpToPage(0) 是 no-op，无副作用。
    if (!isContinuous) {
      _restoreCharOffset = savedOffset;
      debugPrint(
          '[Reader.T1] restoreProgress: page mode, savedIndex=$savedIndex savedOffset=$savedOffset → _restoreCharOffset SET');
    } else {
      debugPrint(
          '[Reader.T1] restoreProgress: savedIndex=$savedIndex savedOffset=$savedOffset isContinuous=$isContinuous → no _restoreCharOffset');
    }

    await _openChapter(savedIndex, chapters);
    if (!mounted) return;

    if (isContinuous && savedParagraph > 0) {
      // P2-13: prefer ensureVisible over height estimation. Falls back to
      // the legacy estimator only when the saved paragraph is past
      // [_kParagraphKeyCap] (long-novel memory budget).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients || !mounted) return;
        if (_loadedChapters.isEmpty) return;
        final ch = _loadedChapters[0];
        if (ch.paragraphs.isEmpty) return;
        final clampedParagraph =
            savedParagraph.clamp(0, ch.paragraphs.length - 1);

        if (clampedParagraph < _kParagraphKeyCap) {
          final keyId = _paragraphKeyId(ch.index, clampedParagraph);
          final key = _paragraphKeys[keyId];
          final ctx = key?.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              alignment: 0,
              duration: Duration.zero,
            );
            _visibleParagraphIndex = clampedParagraph;
            return;
          }
        }

        // Fallback: height estimate.
        final approxLineHeight = _settings.fontSize * _settings.lineHeight;
        final approxParagraphHeight =
            approxLineHeight * 2 + _settings.paragraphSpacing;
        final titleHeight = _settings.fontSize * _settings.lineHeight * 1.7;
        final target =
            titleHeight + approxParagraphHeight * clampedParagraph;
        _scrollController.jumpTo(
          target.clamp(0.0, _scrollController.position.maxScrollExtent),
        );
        _visibleParagraphIndex = clampedParagraph;
      });
    }
    // T1 (05-18): page-mode 的 jumpToPage 由 _openChapter 内部 postFrameCallback
    // 消费 [_restoreCharOffset]（measure 完才能用 startCharOffset 反算页）。
  }

  /// Bug 6: 在 _onScroll 的 debounce 回调里调用，估算当前可见 paragraph index。
  ///
  /// BATCH-19b (F-W2A-014): 保存路径用 GlobalKey 反查（与 P2-13 已有的
  /// 恢复路径对称）：遍历当前章 cap 内的 _paragraphKeys，找第一个
  /// `localToGlobal(0, ancestor: listBox).dy >= 0` 的最小 idx。超过 cap
  /// 的章 fallback 到原 标题 dy + 平均段高估算 公式。
  ///
  /// 之前保存用估算 (`dyFromParagraphStart / approxParagraphHeight`)，
  /// 恢复用 GlobalKey 反查 → 不对称导致 paragraph index ±1-2 段漂移。
  void _updateVisibleParagraph() {
    if (!_scrollController.hasClients) return;
    if (_loadedChapters.isEmpty) return;
    if (!_settings.isScrollMode) return;
    final ch = _loadedChapters.firstWhere(
      (c) => c.index == _visibleChapterIndex,
      orElse: () => _loadedChapters.first,
    );
    if (ch.paragraphs.isEmpty) {
      _visibleParagraphIndex = 0;
      return;
    }
    final listBox =
        _listViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (listBox == null || !listBox.hasSize) return;

    // 1. cap 内 GlobalKey 反查：找视口顶部之下（dy >= 0）的最小 paragraph idx。
    final paraCount = ch.paragraphs.length;
    final lookupCount =
        paraCount < _kParagraphKeyCap ? paraCount : _kParagraphKeyCap;
    int? foundIdx;
    for (int idx = 0; idx < lookupCount; idx++) {
      final keyId = _paragraphKeyId(ch.index, idx);
      final key = _paragraphKeys[keyId];
      final ctx = key?.currentContext;
      final box = ctx?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final dy = box.localToGlobal(Offset.zero, ancestor: listBox).dy;
      if (dy >= 0) {
        foundIdx = idx;
        break;
      }
    }
    if (foundIdx != null) {
      _visibleParagraphIndex = foundIdx;
      return;
    }

    // 2. Fallback：超过 cap 的章（或所有 cap 内 key 都没 layout / 都在视口
    // 之上）走原估算公式。
    final titleKey = _chapterTitleKeys[ch.index];
    final titleCtx = titleKey?.currentContext;
    final titleBox = titleCtx?.findRenderObject() as RenderBox?;
    if (titleBox == null || !titleBox.hasSize) return;
    final titleDy =
        titleBox.localToGlobal(Offset.zero, ancestor: listBox).dy;
    final approxLineHeight = _settings.fontSize * _settings.lineHeight;
    final approxParagraphHeight =
        approxLineHeight * 2 + _settings.paragraphSpacing;
    final titleHeight = approxLineHeight * 1.7;
    // 视口顶部相对该章 paragraph 起始的偏移
    final dyFromParagraphStart = -titleDy - titleHeight;
    if (dyFromParagraphStart <= 0) {
      _visibleParagraphIndex = 0;
      return;
    }
    final est = (dyFromParagraphStart / approxParagraphHeight).floor();
    _visibleParagraphIndex = est.clamp(0, ch.paragraphs.length - 1);
  }

  Future<void> _preCacheNextChapter(
      int index, List<Map<String, dynamic>> chapters) async {
    final nextIndex = index + 1;
    if (nextIndex >= chapters.length) return;
    final chContent = chapters[nextIndex]['content'] as String?;
    if (chContent != null && chContent.isNotEmpty) return;
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final book = await ref.read(bookByIdProvider(widget.bookId).future);
      final sourceId = _sourceId.isNotEmpty
          ? _sourceId
          : (book?['source_id'] as String? ?? '');
      final chapterUrl = chapters[nextIndex]['url'] as String? ?? '';
      if (sourceId.isEmpty || chapterUrl.isEmpty) return;
      final json = await rust_api.getChapterContentWithSourceFromDb(
        dbPath: dbPath,
        sourceId: sourceId,
        chapterUrl: chapterUrl,
      );
      if (json.isEmpty || json == 'null') return;
      var content = '';
      try {
        final data = jsonDecode(json);
        if (data is Map<String, dynamic>) {
          content = data['content'] as String? ?? json;
        } else {
          content = data.toString();
        }
      } catch (e) {
        debugPrint('[Reader] preCacheNextChapter decode failed: $e');
        content = json;
      }
      if (content.isNotEmpty) {
        await rust_api.updateChapterContent(
          dbPath: dbPath,
          chapterId: chapters[nextIndex]['id'] as String? ?? '',
          content: content,
        );
      }
    } catch (e) {
      debugPrint('[Reader] preCacheNextChapter failed: $e');
    }
  }

  /// Task X2 (Bug C) — prev 跨章预拉对称化。
  ///
  /// 与 [_preCacheNextChapter] 镜像，但拉的是 `index - 1` 章的字符串。
  /// 之所以需要独立一份镜像方法，是因为 `_preCacheNextChapter` 早在
  /// `_openChapter` 完成时就被 fire-and-forget 触发；prev 方向之前只走
  /// `_preloadAdjacentContent` 内的 `_loadChapterContent` fire-chain，那条
  /// 路径在 next 章被 `_preCacheNextChapter` 抢先排队时会**晚到**，
  /// 导致用户从首页往前翻时 controller `boundaryPrevPage` 仍是 null →
  /// fallback 走 `_onPageChapterBoundary` 同步 setState 路径 → 无动画 + 卡顿。
  ///
  /// 单一职责：把 prev 章字符串补齐 + 写库（与 next 行为对齐），让下次进章
  /// 直接命中缓存。`_loadChapterContent` 已经处理了缓存命中、Rust API
  /// 调用、正文清洗等逻辑，复用比镜像 `_preCacheNextChapter` 内部 fetch
  /// 流程更简洁也更不易漂移；副作用是 `_loadChapterContent` 不会显式
  /// `updateChapterContent`，但内部走 `getChapterContentWithSourceFromDb`
  /// 已经触发了 Rust 端的写库逻辑（与 next 等价）。
  Future<void> _preCachePrevChapter(
      int index, List<Map<String, dynamic>> chapters) async {
    final prevIndex = index - 1;
    if (prevIndex < 0) return;
    if (prevIndex >= chapters.length) return;
    final prevContent = chapters[prevIndex]['content'] as String?;
    if (prevContent != null && prevContent.isNotEmpty) return;
    try {
      final content = await _loadChapterContent(prevIndex, chapters);
      if (!mounted) return;
      if (content.isNotEmpty) {
        chapters[prevIndex]['content'] = content;
        // Subtask B.4 等价：字符串到位后立即让 controller 拿到刚就绪的 prev
        // 章 picture，下次跨章动画从首页往前翻不会再 fallback。
        _measureAdjacentChapters(_currentIndex);
      }
    } catch (e) {
      debugPrint('[Reader] preCachePrevChapter failed: $e');
    }
  }

  void _preloadAdjacentContent(
      int currentIndex, List<Map<String, dynamic>> chapters) {
    final prevIndex = currentIndex - 1;
    if (prevIndex >= 0) {
      final prevContent = chapters[prevIndex]['content'] as String?;
      if (prevContent == null || prevContent.isEmpty) {
        _loadChapterContent(prevIndex, chapters).then((content) {
          if (content.isNotEmpty) {
            chapters[prevIndex]['content'] = content;
            // Subtask B.4: 字符串 fetch 成功后立即灌进 controller，让 delegate
            // 跨章动画期间能拿到刚就绪的邻章首/末页 picture。
            if (mounted) _measureAdjacentChapters(_currentIndex);
          }
        }).catchError((Object e) {
          debugPrint('[Reader] preload prev chapter failed: $e');
        });
      }
    }
    final nextIndex = currentIndex + 1;
    if (nextIndex < chapters.length) {
      final nextContent = chapters[nextIndex]['content'] as String?;
      if (nextContent == null || nextContent.isEmpty) {
        _loadChapterContent(nextIndex, chapters).then((content) {
          if (content.isNotEmpty) {
            chapters[nextIndex]['content'] = content;
            // Subtask B.4: 同上，next 方向。
            if (mounted) _measureAdjacentChapters(_currentIndex);
          }
        }).catchError((Object e) {
          debugPrint('[Reader] preload next chapter failed: $e');
        });
      }
    }
  }

  /// 确保邻章内容已加载到内存中，使 [_measureAdjacentChapters] 能拿到
  /// [ChapterWindow] 的 content 字段，从而让 [PageDelegate] 跨章动画期间
  /// 能渲染邻章首/末页 picture，避免 fallback 到无动画的
  /// [_onPageChapterBoundary] → [_loadPageModeChapter] 路径。
  ///
  /// 与 [_preloadAdjacentContent] 的区别：本方法 **await** 内容加载完成，
  /// 在 [_openChapter] 内阻塞到邻章内容就绪后才释放 [_isPageLayoutReady]，
  /// 保证用户翻页时 `boundaryNextPage` / `boundaryPrevPage` 已就位。
  Future<void> _ensureAdjacentChaptersReady(
      int index, List<Map<String, dynamic>> chapters) async {
    final nextIdx = index + 1;
    final prevIdx = index - 1;
    final futures = <Future<void>>[];
    if (nextIdx < chapters.length) {
      final nextContent = chapters[nextIdx]['content'] as String?;
      if (nextContent == null || nextContent.isEmpty) {
        futures.add(_loadChapterContent(nextIdx, chapters).then((c) {
          if (c.isNotEmpty) chapters[nextIdx]['content'] = c;
        }));
      }
    }
    if (prevIdx >= 0) {
      final prevContent = chapters[prevIdx]['content'] as String?;
      if (prevContent == null || prevContent.isEmpty) {
        futures.add(_loadChapterContent(prevIdx, chapters).then((c) {
          if (c.isNotEmpty) chapters[prevIdx]['content'] = c;
        }));
      }
    }
    await Future.wait(futures);
  }

  /// Subtask B — 把已预加载的邻章字符串内容灌进 [PageViewController]，让
  /// PageDelegate 跨章动画期间能渲染邻章首/末页 picture。
  ///
  /// 调用时机：
  ///   - [_openChapter] 完成后（进章触发）
  ///   - [_loadPageModeChapter] 完成后（章末翻页触发）
  ///   - [_preloadAdjacentContent] 完成 fetch 字符串后（异步触发）
  ///   - [_setReaderSettings] 排版字段变化后（重测触发）
  ///
  /// 安全语义：
  ///   - controller 未就绪 → 早 return
  ///   - 滚动模式 → skip（滚动模式有自己的多章节加载机制
  ///     `_ensureCurrentChapterInContinuous`，邻章窗口不适用）
  ///   - 计算逻辑全部委托给 [ReaderPage.computeAdjacentWindows] 静态函数，
  ///     便于单测；本方法只负责"调度 + 灌 controller"。
  void _measureAdjacentChapters(int currentIndex) {
    final ctrl = _pageViewController;
    if (ctrl == null) return;
    if (_settings.isScrollMode) return;
    final (prev, next) =
        ReaderPage.computeAdjacentWindows(currentIndex, _cachedChapters);
    ctrl.setNeighborChapter(prev: prev, next: next);
  }

  Future<void> _refreshChapter() async {
    if (_cachedChapters == null || _cachedChapters!.isEmpty) return;
    final index = _currentIndex;
    final chapters = _cachedChapters!;
    final chapterId = chapters[index]['id'] as String?;
    if (chapterId != null) {
      try {
        final dbPath = await ref.read(dbPathProvider.future);
        await rust_api.updateChapterContent(
          dbPath: dbPath,
          chapterId: chapterId,
          content: '',
        );
        chapters[index]['content'] = null;
      } catch (e) {
        debugPrint('[Reader] refreshChapter clear cache failed: $e');
      }
    }
    if (_settings.isScrollMode) {
      // Bug 5 fix: 必须用 setState 同步清空 _loadedChapters 与
      // _cachedContinuousItems，否则下一帧 build 会读到旧的 cached items（指向
      // 已经空掉的 _loadedChapters[0]），抛 RangeError。
      if (mounted) {
        setState(() {
          _loadedChapters = [];
          _cachedContinuousItems = null;
          _chapterTitleKeys.clear();
          _paragraphKeys.clear();
        });
      }
    }
    await _openChapter(index, chapters);
  }

  Future<void> _loadBookmarks() async {
    final dbPath = await ref.read(dbPathProvider.future);
    final list =
        await _bookmarkService.list(dbPath: dbPath, bookId: widget.bookId);
    if (!mounted || list.isEmpty) return;
    setState(() => _bookmarks = list);
    _checkBookmarkForChapter();
  }

  void _checkBookmarkForChapter() {
    _hasBookmarkForChapter =
        _bookmarks.any((b) => b['chapter_index'] == _currentIndex);
  }

  Future<void> _toggleBookmark() async {
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      if (_hasBookmarkForChapter) {
        final match = _bookmarks
            .where((b) => b['chapter_index'] == _currentIndex)
            .toList();
        for (final bm in match) {
          final bookmarkId = bm['id'] as String? ?? '';
          if (bookmarkId.isNotEmpty) {
            await _bookmarkService.remove(
                dbPath: dbPath, bookmarkId: bookmarkId);
            _bookmarks.removeWhere((b) => b['id'] == bookmarkId);
          }
        }
      } else {
        final content = _chapterContent.length > 50
            ? _chapterContent.substring(0, 50)
            : _chapterContent;
        final added = await _bookmarkService.add(
          dbPath: dbPath,
          bookId: widget.bookId,
          chapterIndex: _currentIndex,
          content: content,
        );
        if (added != null) {
          _bookmarks.add(added);
        }
      }
      if (mounted) {
        _checkBookmarkForChapter();
        setState(() {});
      }
    } catch (e) {
      debugPrint('[Reader] add bookmark failed: $e');
    }
  }

  Future<void> _deleteBookmark(
      String bookmarkId, int bookmarkListIndex, BuildContext ctx) async {
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      await _bookmarkService.remove(dbPath: dbPath, bookmarkId: bookmarkId);
      _bookmarks.removeAt(bookmarkListIndex);
      _checkBookmarkForChapter();
      if (mounted) {
        setState(() {});
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(content: Text('书签已删除')),
          );
        }
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  void _toggleNightMode() {
    final s = _settings.copyWith(nightMode: !_settings.nightMode);
    _setReaderSettings(s, persist: true);
  }

  void _navigateToChapter(int index, List<Map<String, dynamic>> chapters) {
    if (_settings.isScrollMode) {
      _resetContinuousStream(index);
    } else {
      _openChapter(index, chapters);
    }
  }

  void _showDirectorySheet() {
    _toggleControls();
    final chapters = _cachedChapters ?? [];
    final fg = Color(_settings.effectiveTextColor);
    final bg = Color(_settings.effectiveBackgroundColor);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: bg,
      builder: (ctx) => DefaultTabController(
        length: 2,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            children: [
              TabBar(
                tabs: const [
                  Tab(text: '目录'),
                  Tab(text: '书签'),
                ],
                labelColor: fg,
                unselectedLabelColor: fg.withValues(alpha: 0.5),
                indicatorColor: fg,
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildDirectoryTab(chapters, ctx),
                    _buildBookmarkTab(ctx, chapters),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDirectoryTab(
      List<Map<String, dynamic>> chapters, BuildContext ctx) {
    final fg = Color(_settings.effectiveTextColor);
    if (chapters.isEmpty) {
      return Center(
          child:
              Text('暂无目录', style: TextStyle(color: fg.withValues(alpha: 0.5))));
    }
    return ListView.builder(
      itemExtent: 48,
      itemCount: chapters.length,
      itemBuilder: (context, index) {
        final ch = chapters[index];
        final isCurrent = index == _currentIndex;
        return ListTile(
          dense: true,
          title: Text(
            ch['title'] as String? ?? '章节 ${index + 1}',
            style: TextStyle(
              color: isCurrent ? Theme.of(ctx).primaryColor : fg,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
            ),
          ),
          onTap: () {
            Navigator.of(ctx).pop();
            _navigateToChapter(index, chapters);
          },
        );
      },
    );
  }

  Widget _buildBookmarkTab(
      BuildContext ctx, List<Map<String, dynamic>> chapters) {
    final fg = Color(_settings.effectiveTextColor);
    if (_bookmarks.isEmpty) {
      return Center(
          child:
              Text('暂无书签', style: TextStyle(color: fg.withValues(alpha: 0.5))));
    }
    return ListView.builder(
      itemExtent: 64,
      itemCount: _bookmarks.length,
      itemBuilder: (context, index) {
        final bm = _bookmarks[index];
        final chapterIndex = bm['chapter_index'] as int? ?? 0;
        final chapterTitle = chapterIndex < chapters.length
            ? (chapters[chapterIndex]['title'] as String? ??
                '章节 ${chapterIndex + 1}')
            : '章节 ${chapterIndex + 1}';
        final content = bm['content'] as String? ?? '';
        return ListTile(
          dense: true,
          title: Text(chapterTitle,
              style: TextStyle(color: fg, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          subtitle: content.isNotEmpty
              ? Text(content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(color: fg.withValues(alpha: 0.5), fontSize: 12))
              : null,
          trailing: IconButton(
            icon: Icon(Icons.delete_outline,
                color: fg.withValues(alpha: 0.5), size: 20),
            onPressed: () =>
                _deleteBookmark(bm['id'] as String? ?? '', index, ctx),
          ),
          onTap: () {
            Navigator.of(ctx).pop();
            _navigateToChapter(chapterIndex, chapters);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // BATCH-19b (F-W2A-011): build 顶层不再 watch readerSettingsProvider，
    // 改为 ref.listen + State.setState 单路径。理由：
    // - 之前 `ref.watch(readerSettingsProvider)` 让 settings 任一字段变化
    //   都全树 rebuild ReaderPage，包括 PageViewWidget / 连续滚动 ListView。
    // - reader_page 的 settings 真正 source of truth 是 plain field
    //   `_settings`，子树都从 `_settings` 读；provider 只是跨页面同步通道。
    // - listen 在 build 内调用是合法的（Riverpod 文档明确支持）；回调
    //   post-build 触发，无需 addPostFrameCallback 包裹。
    // - 首帧值由 initState 的 loadReaderSettingsFromDisk → _setReaderSettings
    //   兜底，listen 接管后续 provider 端变更（设置页 slider、bookshelf
    //   排序写回等）。
    ref.listen<ReaderSettings>(readerSettingsProvider, (prev, next) {
      if (!mounted) return;
      if (_readerSettingsLoaded && next != _settings) {
        _setReaderSettings(next);
      }
    });

    if (widget.bookId.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('阅读器')),
        body: const Center(child: Text('未指定书籍')),
      );
    }

    final chaptersAsync = ref.watch(bookChaptersProvider(widget.bookId));

    return chaptersAsync.when(
      data: (chapters) {
        // T1 followup #2 (05-18 fix5)：必须等 _readerSettingsLoaded 才能
        // 触发 _restoreProgress。原因——_settings 默认是 scroll 模式
        // (ReaderPageAnim.scroll=5)，loadReaderSettingsFromDisk 是 fire-
        // and-forget；如果 chapters 比 settings 先 load 完（缓存命中常见），
        // _restoreProgress 跑时 _settings.isScrollMode 仍是 true → 走滚动
        // 分支不设 _restoreCharOffset → 恢复链路完全失效，落回章首页。
        if (chapters.isNotEmpty && !_progressRestored && _readerSettingsLoaded) {
          _progressRestored = true;
          _cachedChapters = chapters;
          Future.microtask(() => _restoreProgress(chapters));
        }
        if (chapters.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text('阅读器')),
            body: const Center(child: Text('暂无章节')),
          );
        }
        if (_isLoadingContent || _chapterContent.isNotEmpty) {
          return _buildReaderView();
        }
        // T1 followup (05-18): _restoreProgress / _openChapter 还没把
        // _chapterContent 填满之前显示 loading 占位，避免"返回书架再开"
        // 路径下首帧闪现 _buildChapterList 目录列表的视觉跳变。
        // _buildChapterList 不再被生产代码调用（仅作为兜底保留）。
        return Scaffold(
          appBar: AppBar(title: const Text('阅读器')),
          body: const Center(child: CircularProgressIndicator()),
        );
      },
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('阅读器')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('阅读器')),
        body: Center(child: Text('加载章节失败: $e')),
      ),
    );
  }

  // T1 followup (05-18): build() 改成首屏走 loading 而不是目录列表，
  // 这个 widget 不再被生产路径调用；保留作为后续"主动选目录"扩展的兜底，
  // 暂时让 dart analyzer 忽略 unused 警告。
  // ignore: unused_element
  Widget _buildChapterList(List<Map<String, dynamic>> chapters) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('目录'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: ListView.builder(
        itemExtent: 56,
        itemCount: chapters.length,
        itemBuilder: (context, index) {
          final ch = chapters[index];
          return ListTile(
            title: Text(ch['title'] as String? ?? '章节 ${index + 1}'),
            onTap: () => _openChapter(index, chapters),
          );
        },
      ),
    );
  }

  Widget _buildReaderView() {
    final chapters = _cachedChapters!;
    final hasPrev = _currentIndex > 0;
    final hasNext = _currentIndex < chapters.length - 1;
    final settings = _settings;
    // P3-5/R25: derive from the explicit enum so a future
    // `ReaderRenderMode.someThirdMode` will need to be handled here.
    final renderMode = settings.renderMode;
    final isContinuous = renderMode == ReaderRenderMode.continuous;
    final isPage = renderMode == ReaderRenderMode.paged;
    final bgColor = Color(settings.effectiveBackgroundColor);
    final contentLocked = _controlsVisible || _isSearching;

    final showInfoBars = settings.showReadingInfo;

    // 批次 2 (05-18): Focus 包住整个 reader 渲染区，让物理按键事件能被
    // [handleReaderKeyEvent] 拦截转化为翻页。autofocus = true 保证一进
    // reader 立即获焦，不需要用户先点屏幕。控件可见时（菜单 / 设置 sheet）
    // 不拦截 — 见 [handleReaderKeyEvent] 内的 controlsVisible 守卫。
    //
    // 05-24 (html-ui): 添加 PopScope 拦截 Android 系统返回键，当控件覆盖层
    // 可见时关闭覆盖层而非退出 reader。
    return PopScope(
      canPop: !_controlsVisible,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _controlsVisible) {
          _toggleControls();
        }
      },
      child: Focus(
        focusNode: _readerFocusNode,
        autofocus: true,
        onKeyEvent: (node, event) => handleReaderKeyEvent(
          event: event,
          settings: _settings,
          controlsVisible: _controlsVisible,
          ttsSpeaking: _tts.isSpeaking,
          // 批次 3 (05-18): 复用 _doTapPrev / _doTapNext，与 onTapUp / 物理键
          // 走同一条翻页 helper，避免两路 fallback 链漂移。
          onPrev: _doTapPrev,
          onNext: _doTapNext,
        ),
        child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarIconBrightness:
              _settings.nightMode ? Brightness.light : Brightness.dark,
          statusBarColor: Colors.transparent,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: bgColor,
            image: settings.backgroundImagePath != null
                ? DecorationImage(
                    image: FileImage(File(settings.backgroundImagePath!)),
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          child: Column(
            children: [
              if (showInfoBars)
                SafeArea(
                  bottom: false,
                  child: _buildReadingInfoHeader(settings),
                ),
              Expanded(
                child: Stack(
                  children: [
                    SafeArea(
                      top: !showInfoBars,
                      child: IgnorePointer(
                        ignoring: contentLocked,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) {
                            // 批次 3 (05-18): 3×3 点击区域配置。
                            // 滚动模式（!isPage）保持单一中央点击切 menu 的旧行为，
                            // 因为滚动模式下没有"翻页"语义可分派。
                            if (!isPage) {
                              _toggleControls();
                              return;
                            }
                            // 用本 GestureDetector 自身的 RenderBox 尺寸（与
                            // details.localPosition 同坐标系）；理论上不应为 null，
                            // 兜底到 MediaQuery.size 仍是合理 fallback。
                            final box = context.findRenderObject() as RenderBox?;
                            final size =
                                box?.size ?? MediaQuery.of(context).size;
                            final idx = tapZoneIndex(
                              details.localPosition.dx,
                              details.localPosition.dy,
                              size.width,
                              size.height,
                            );
                            final action =
                                resolveTapAction(_settings.tapZones, idx);
                            switch (action) {
                              case TapZoneAction.prevPage:
                                _doTapPrev();
                                break;
                              case TapZoneAction.nextPage:
                                _doTapNext();
                                break;
                              case TapZoneAction.showMenu:
                                _toggleControls();
                                break;
                              case TapZoneAction.nothing:
                                break;
                            }
                          },
                          // 批次 5 (05-18): 长按文字菜单 MVP — 整页粒度
                          // （不动 ContentPagePainter Canvas 渲染，避免破坏
                          // simulation 翻页 ui.Picture 预渲染）。控件可见时
                          // 不响应避免与设置 sheet 冲突。
                          onLongPressStart: (details) {
                            if (!_settings.enableLongPressMenu) return;
                            if (_controlsVisible) return;
                            _showLongPressActionSheet();
                          },
                          child: NotificationListener<OverscrollNotification>(
                            onNotification:
                                isContinuous ? (_) => true : _onOverscroll,
                            child: isPage
                                ? _buildPageBody(settings)
                                : _buildContinuousBody(settings),
                          ),
                        ),
                      ),
                    ),
                    // 05-24 (html-ui): 控件覆盖层 — 不在 SafeArea 内，覆盖全屏
                      // 替换原有分离的 reader_top_bar + reader_bottom_bar + contentLocked 挡板
                      // 三段式结构。采用 AnimatedOpacity 淡入淡出（250ms）匹配 HTML 过渡。
                      ReaderControlOverlay(
                        settings: settings,
                        bookName: _bookName,
                        currentChapterTitle: _currentIndex < chapters.length
                            ? (chapters[_currentIndex]['title'] as String? ?? '')
                            : '',
                        sourceName: _sourceName,
                        sourceUrl: _sourceUrl,
                        chapterUrl: _chapterUrl,
                        hasBookmark: _hasBookmarkForChapter,
                        chapterCount: chapters.length,
                        currentIndex: _currentIndex,
                        sliderValue: _sliderValue,
                        hasPrev: hasPrev,
                        hasNext: hasNext,
                        isAutoScrolling: _isAutoScrolling,
                        isNightMode: _settings.nightMode,
                        isVisible: _controlsVisible,
                        onBack: () => context.pop(),
                        onChangeSource: () {
                          _toggleControls();
                          _showChangeSourceDialog(context);
                        },
                        onRefreshChapter: _refreshChapter,
                        onStartDownload: () {
                          _toggleControls();
                          _startDownload(context);
                        },
                        onToggleBookmark: () {
                          _toggleControls();
                          _toggleBookmark();
                        },
                        onClose: _toggleControls,
                        onSliderChanged: (v) =>
                            setState(() => _sliderValue = v),
                        onSliderChangeEnd: (targetIndex) {
                          setState(() {
                            _sliderValue = null;
                            _currentIndex = targetIndex;
                          });
                          _navigateToChapter(targetIndex, chapters);
                        },
                        onPrevChapter: _goToPrevChapter,
                        onNextChapter: _goToNextChapter,
                        onStartSearch: _startSearch,
                        onToggleAutoScroll: () {
                          _toggleControls();
                          _toggleAutoScroll();
                        },
                        onToggleNightMode: _toggleNightMode,
                        onOpenReplaceRules: () {
                          _toggleControls();
                          context.push('/replace-rules');
                        },
                        onShowDirectory: _showDirectorySheet,
                        onStartTts: () {
                          _toggleControls();
                          _startTts();
                        },
                        onShowReaderSettings: _showReaderSettings,
                      ),
                      if (_isSpeaking) _buildTtsBar(),
                      if (_isSearching) _buildSearchBar(),
                    ],
                  ),
                ),
                if (showInfoBars) _buildReadingInfoFooter(chapters, settings),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<_ContinuousItem> _buildContinuousItemList() {
    if (_cachedContinuousItems != null) return _cachedContinuousItems!;
    final items = <_ContinuousItem>[];
    for (var i = 0; i < _loadedChapters.length; i++) {
      final chapter = _loadedChapters[i];
      if (chapter.title.isNotEmpty) {
        items.add(_ContinuousItem(chapterIndex: i, isTitle: true));
      }
      for (var j = 0; j < chapter.paragraphs.length; j++) {
        items.add(_ContinuousItem(chapterIndex: i, paragraphIndex: j));
      }
      if (i < _loadedChapters.length - 1) {
        items.add(_ContinuousItem(chapterIndex: i, isDivider: true));
      }
    }
    _cachedContinuousItems = items;
    return items;
  }

  Widget _buildContinuousBody(ReaderSettings settings) {
    // Bug 2: 超时/加载失败状态
    if (_chapterContent == '正文加载失败') {
      return _buildContentTimeoutView();
    }
    final textStyle = TextStyle(
      fontSize: settings.fontSize,
      fontWeight:
          FontWeight.values[((settings.fontWeight ~/ 100) - 1).clamp(0, 8)],
      fontFamily: settings.fontFamily,
      color: Color(settings.effectiveTextColor),
      letterSpacing: settings.letterSpacing,
      height: settings.lineHeight,
      decoration: TextDecoration.none,
    );
    final titleStyle = textStyle.copyWith(
      fontWeight: FontWeight.bold,
      fontSize: settings.fontSize * 1.15,
    );
    final dividerColor =
        Color(settings.effectiveTextColor).withValues(alpha: 0.15);
    final items = _buildContinuousItemList();

    return ListView.builder(
      key: _listViewKey,
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(
        horizontal: settings.horizontalPadding,
        vertical: settings.verticalPadding,
      ),
      itemCount: items.length + (_isAppendingChapter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= items.length) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        final item = items[index];
        if (item.isTitle) {
          final globalChIndex = _loadedChapters[item.chapterIndex].index;
          return Padding(
            key:
                _chapterTitleKeys.putIfAbsent(globalChIndex, () => GlobalKey()),
            padding: EdgeInsets.only(bottom: settings.verticalPadding),
            child: Text(_loadedChapters[item.chapterIndex].title,
                style: titleStyle),
          );
        }
        if (item.isDivider) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(color: dividerColor),
          );
        }
        final chapter = _loadedChapters[item.chapterIndex];
        final p = chapter.paragraphs[item.paragraphIndex!];
        // P2-13: key only the first _kParagraphKeyCap paragraphs of each
        // loaded chapter so _restoreProgress can ensureVisible accurately.
        final pIdx = item.paragraphIndex!;
        final globalKey = pIdx < _kParagraphKeyCap
            ? _paragraphKeys.putIfAbsent(
                _paragraphKeyId(chapter.index, pIdx),
                () => GlobalKey())
            : null;
        return Padding(
          key: globalKey,
          padding: EdgeInsets.only(bottom: settings.paragraphSpacing),
          child: Text('${settings.paragraphIndent}$p', style: textStyle),
        );
      },
    );
  }

  /// Bug 2: 章节内容加载超时/失败的不可操作提示。点击触发重试。
  Widget _buildContentTimeoutView() {
    final bgColor = Color(_settings.effectiveBackgroundColor);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _refreshChapter,
      child: Container(
        color: bgColor,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: context.al.textSecondary.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              Text(
                '正文加载失败',
                style: TextStyle(
                  color: Color(_settings.effectiveTextColor).withValues(alpha: 0.6),
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '点击重试',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageBody(ReaderSettings settings) {
    // Bug 2: 超时/加载失败状态 — 显示重试界面
    if (_chapterContent == '正文加载失败') {
      return _buildContentTimeoutView();
    }
    // Bug 1: 轻量修复 — spinner→内容过渡用 AnimatedOpacity 淡入
    // AnimatedOpacity 常驻树内：首次加载时 opacity 0→1 动画；后续翻章
    // （_chapterContent 已有旧内容）opacity 保持 1，旧内容不消失，无缝
    // 切换到新内容。
    final canShow = _chapterContent.isNotEmpty;
    return Stack(
      children: [
        AnimatedOpacity(
          opacity: canShow && _pageViewController != null && _isPageLayoutReady ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: _pageViewController != null
              ? PageViewWidget(
                  controller: _pageViewController!,
                  settings: settings,
                  pageAnim: settings.pageAnim,
                  onChapterBoundary: _onPageChapterBoundary,
                  onCrossChapter: _onCrossChapterCommit,
                  isPageLayoutReady: _isPageLayoutReady,
                )
              : const SizedBox.shrink(),
        ),
        if (!_isPageLayoutReady && _chapterContent.isNotEmpty)
          Center(
            child: Text(
              '加载中...',
              style: TextStyle(
                fontSize: settings.fontSize,
                color: Color(settings.effectiveTextColor).withValues(alpha: 0.5),
                decoration: TextDecoration.none,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _loadPageModeChapter(int targetIndex) async {
    if (_cachedChapters == null ||
        targetIndex < 0 ||
        targetIndex >= _cachedChapters!.length) return;
    final chapters = _cachedChapters!;
    final isPrev = targetIndex < _currentIndex;

    setState(() {
      _isLoadingContent = true;
      _currentIndex = targetIndex;
    });

    try {
      final content = await _loadChapterContent(targetIndex, chapters);
      if (!mounted) return;
      final title = chapters[targetIndex]['title'] as String? ?? '';
      // T1 (05-18) 修复：同 _openChapter — 删除强写 offset=0，进度保存交给
      // _onPageChanged → _saveCurrentPagePosition 统一路径（loadChapter +
      // jumpToLast 完成后会触发 listener 写入实际 page.startCharOffset）。
      // Bug 3 fix: controller ops + gate flag moved inside setState so that
      // the rebuild triggered here picks up _isPageLayoutReady=false and
      // activates IgnorePointer.
      setState(() {
        _chapterContent = content;
        _isLoadingContent = false;
        _pageViewController?.updateSettings(_settings);
        _pageViewController?.loadChapter(targetIndex, title, content,
            jumpToLast: isPrev);
        _isPageLayoutReady = false;
      });
      await _ensureAdjacentChaptersReady(targetIndex, chapters);
      _measureAdjacentChapters(targetIndex);
      if (mounted) safeSetState(() => _isPageLayoutReady = true);
      _preCacheNextChapter(targetIndex, chapters);
      _preCachePrevChapter(targetIndex, chapters);
      _fetchSourceInfo();
    } catch (e) {
      // Bug 2: TimeoutException → show retryable error; other errors → just
      // stop loading (keep old content visible rather than showing error).
      if (!mounted) return;
      if (e is TimeoutException) {
        setState(() {
          _chapterContent = '正文加载失败';
          _isLoadingContent = false;
        });
      } else {
        safeSetState(() => _isLoadingContent = false);
      }
    }
  }

  void _onPageChanged() {
    safeSetState(() {});
    // T1 (05-18): 章内每翻一页都立即把进度写库，对齐 MD3
    // ReadBook.moveToNextPage / moveToPrevPage 的 saveRead(true)。
    // fire-and-forget，不阻塞 UI。
    _saveCurrentPagePosition();
  }

  /// T1 (05-18): 章内翻页保存 — 把当前页 [TextPage.startCharOffset] 当成
  /// `durChapterPos` 写库。fire-and-forget；DB IO 在 Rust 端 spawn_blocking
  /// 跑。失败仅 debugPrint，不阻塞 UI。
  ///
  /// 保护窗口：当 [_restoreCharOffset] 仍未被消费时（首章 loadChapter 完成
  /// 但 postFrameCallback 还没跑到 jumpToPage 的中间帧），此时
  /// `controller.currentPageIndex == 0` / `currentPage.startCharOffset == 0`，
  /// 如果保存就把 saved offset 覆盖成 0；让 [_consumeRestoreCharOffsetIfNeeded]
  /// 之后的 jumpToPage 触发的 listener 来做第一次正确保存。
  void _saveCurrentPagePosition() {
    if (_restoreCharOffset != null) {
      // 启动恢复链路尚未完成；跳过本次保存避免覆盖 saved offset
      debugPrint(
          '[Reader.T1] saveCurrentPagePosition: SKIP (restore in flight, _restoreCharOffset=$_restoreCharOffset)');
      return;
    }
    final ctrl = _pageViewController;
    if (ctrl == null) return;
    final page = ctrl.currentPage;
    if (page == null) return;
    final chapterIndex = ctrl.currentChapterIndex;
    final offset = page.startCharOffset;
    final bookId = widget.bookId;
    debugPrint(
        '[Reader.T1] saveCurrentPagePosition: chapter=$chapterIndex pageIdx=${ctrl.currentPageIndex} offset=$offset');
    ref.read(dbPathProvider.future).then((dbPath) {
      if (!mounted) return;
      _progressService.save(
        dbPath: dbPath,
        bookId: bookId,
        chapterIndex: chapterIndex,
        offset: offset,
      );
    }).catchError((Object e) {
      debugPrint('[Reader.T1] saveCurrentPagePosition failed: $e');
    });
  }

  /// T1 (05-18): 启动恢复链路最后一步 — measure 完成后通过 postFrameCallback
  /// 反算 saved char offset 对应的页并 jumpToPage。只消费一次（[_restoreCharOffset]
  /// 在消费后清成 null），后续 [_openChapter] 调用不会再触发跳页。
  ///
  /// T1 followup（05-18 race fix）：把 `_restoreCharOffset = null` 从同步路径
  /// 移到 postFrame 内 jumpToPage 之后。原因——
  ///
  /// `loadChapter` 内部 `_measureCurrentChapterIfNeeded` 把 notifyListeners
  /// 也 deferred 到 postFrame（page_view_controller.dart R39 注释），与本方法
  /// schedule 的 postFrame 都注册到下一帧。它们按 schedule 顺序串行：
  ///
  ///   ① loadChapter postFrame: notifyListeners → _onPageChanged
  ///        → _saveCurrentPagePosition
  ///        → 看 `_restoreCharOffset != null` 跳过保存（保护窗口）
  ///   ② consumeRestoreCharOffset postFrame: jumpToPage(N) → notifyListeners
  ///        → _onPageChanged → _saveCurrentPagePosition
  ///        → `_restoreCharOffset` 仍非 null，仍跳过
  ///        → jumpToPage 完成后清 `_restoreCharOffset`（这一行）
  ///   ③ 后续用户翻页 listener 才会真正写库（offset = 实际页 startCharOffset）
  ///
  /// 旧实现把 `= null` 放在 schedule 之前，导致 ① 时保护窗口失效，把 page 0
  /// offset=0 写入 DB 覆盖刚 load 出来的 saved offset。表现：从书架二次进入
  /// 同一本书时永远落回章首页，而 kill app 后重开却正常。
  void _consumeRestoreCharOffsetIfNeeded() {
    final saved = _restoreCharOffset;
    if (saved == null) {
      debugPrint(
          '[Reader.T1] consumeRestoreCharOffset: skip (saved=null)');
      return;
    }
    if (_settings.isScrollMode) {
      // 滚动模式不走 jumpToPage 路径；直接清，避免下次 _openChapter 误用。
      _restoreCharOffset = null;
      debugPrint(
          '[Reader.T1] consumeRestoreCharOffset: skip (scroll mode), cleared');
      return;
    }
    debugPrint(
        '[Reader.T1] consumeRestoreCharOffset: schedule postFrame, saved=$saved');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _restoreCharOffset = null; // unmount 兜底防泄漏
        return;
      }
      final ctrl = _pageViewController;
      if (ctrl == null) {
        _restoreCharOffset = null; // 兜底
        return;
      }
      // measure 完成后 totalPagesInChapter > 0；若仍为 0（极端边界情形）
      // jumpToPage 自身会早 return。
      final pageIdx = ctrl.getPageIndexByCharOffset(saved);
      debugPrint(
          '[Reader.T1] consumeRestoreCharOffset postFrame: saved=$saved totalPages=${ctrl.totalPagesInChapter} pageIdx=$pageIdx → jumpToPage');
      ctrl.jumpToPage(pageIdx); // 同步置 currentPageIndex + notifyListeners
                                 // → 同步触发 _onPageChanged → _saveCurrentPagePosition
                                 // 此时 _restoreCharOffset 仍非 null → 保护窗口跳过
      _restoreCharOffset = null;  // jumpToPage 同步链跑完才清；后续用户翻页
                                   // 才会真正落库（实际页 startCharOffset）
    });
  }

  void _onPageChapterBoundary(PageDirection dir) {
    if (_cachedChapters == null) return;
    if (dir == PageDirection.next &&
        _currentIndex < _cachedChapters!.length - 1) {
      _loadPageModeChapter(_currentIndex + 1);
    } else if (dir == PageDirection.prev && _currentIndex > 0) {
      _loadPageModeChapter(_currentIndex - 1);
    }
  }

  /// 批次 3 (05-18): 触发"上一页"。
  /// 优先走 delegate 动画（`onTapPrev`），其次 controller 直跳页；都失败 →
  /// 走 [_onPageChapterBoundary] 的章节边界 fallback（无动画切上一章）。
  ///
  /// 与 [_onPageChapterBoundary] 的区别：本方法是"用户主动 tap / 物理键"
  /// 入口，会走 controller.onTapPrev 的动画路径；boundary 是动画完成后的
  /// 跨章 fallback。
  void _doTapPrev() {
    final pvc = _pageViewController;
    if (pvc == null) return;
    if (pvc.onTapPrev != null) {
      pvc.onTapPrev!();
    } else if (!pvc.goToPrevPage()) {
      _onPageChapterBoundary(PageDirection.prev);
    }
  }

  /// 批次 3 (05-18): 触发"下一页"。语义对称 [_doTapPrev]。
  void _doTapNext() {
    final pvc = _pageViewController;
    if (pvc == null) return;
    if (pvc.onTapNext != null) {
      pvc.onTapNext!();
    } else if (!pvc.goToNextPage()) {
      _onPageChapterBoundary(PageDirection.next);
    }
  }

  /// Subtask C：跨章动画完成后由 [PageDelegate] 经
  /// [PageViewWidget.onCrossChapter] 回调上来。controller 已经把邻章
  /// 提升为 currentChapter（commitToNextChapter / commitToPrevChapter），
  /// 这里只负责同步 ReaderPage 的 `_currentIndex` / 标题文案 / 保存进度 /
  /// 重新预加载新邻章。
  ///
  /// 与 [_onPageChapterBoundary] 的分工：
  ///   - _onCrossChapterCommit：邻章已就绪 → controller commit 完之后
  ///   - _onPageChapterBoundary：邻章未就绪 fallback → 旧 _loadPageModeChapter
  ///     异步加载（保留无动画切章的现状）
  void _onCrossChapterCommit(PageDirection dir) {
    if (!mounted) return;
    final ctrl = _pageViewController;
    if (ctrl == null) return;
    final newIndex = ctrl.currentChapterIndex;
    // 防御：commit 实际失败（_nextChapter / _prevChapter == null）controller
    // 没动；这里检测到 newIndex == _currentIndex 直接返回，避免空跑后面逻辑。
    if (newIndex == _currentIndex) return;
    setState(() {
      _currentIndex = newIndex;
      if (_cachedChapters != null && newIndex < _cachedChapters!.length) {
        final m = _cachedChapters![newIndex];
        final chContent = m['content'] as String?;
        if (chContent != null && chContent.isNotEmpty) {
          _chapterContent = chContent;
        }
        _chapterUrl = m['url'] as String? ?? '';
      }
    });
    // T1 (05-18): 跨章 commit 完保存当前页 startCharOffset。
    // - dir == next：controller.commitToNextChapter 把 currentPageIndex 重置 0，
    //   startCharOffset = 0（行为等价于旧 _saveProgressAsync(newIndex)）。
    // - dir == prev：controller.commitToPrevChapter 把 currentPageIndex 定位到
    //   prev 章末页，startCharOffset = 末页首字符 offset（>0），相比旧路径
    //   `_saveProgressAsync(newIndex)` 把 offset 强制写 0 是更准确的恢复点
    //   ——用户从下章翻回上一章末页，重开 app 应该回末页而不是首页。
    // 走与章内翻页统一的 _saveCurrentPagePosition 代码路径，避免两路语义漂移。
    _saveCurrentPagePosition();
    // 重新灌邻章 + 字符串预拉。controller 内部 _nextChapter / _prevChapter
    // 一边已被释放，需要外层重新 setNeighborChapter。
    _measureAdjacentChapters(newIndex);
    if (_cachedChapters != null) {
      _preloadAdjacentContent(newIndex, _cachedChapters!);
      _preCachePrevChapter(newIndex, _cachedChapters!);
    }
  }

  void _showChangeSourceDialog(BuildContext context) async {
    final dbPath = await ref.read(dbPathProvider.future);
    if (!mounted) return;
    final bookName = _bookName;
    final currentSourceId = _sourceId;
    final currentSourceName = _sourceName.isNotEmpty ? _sourceName : '书源';

    final result = await showDialog<ChangeSourceResult>(
      context: context,
      barrierDismissible: true,
      builder: (_) => ChangeSourceDialog(
        dbPath: dbPath,
        bookName: bookName,
        bookAuthor: '',
        currentSourceId: currentSourceId,
        currentSourceName: currentSourceName,
      ),
    );

    if (result != null && mounted) {
      await _replaceBookSource(result);
    }
  }

  Future<void> _replaceBookSource(ChangeSourceResult result) async {
    if (!mounted) return;
    final savedIndex = _currentIndex;
    final book = await ref.read(bookByIdProvider(widget.bookId).future);
    if (!mounted || book == null) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final dbPath = await ref.read(dbPathProvider.future);
    if (!mounted) return;

    final chapters = result.chapters;
    int savedCount = 0;
    final List<Map<String, dynamic>> cachedChaptersList = [];
    final List<Map<String, dynamic>> chapterRecords = [];
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final chapterKey = '${widget.bookId}|$i|${ch['url'] ?? ''}';
      final chapterId = base64Url
          .encode(sha256.convert(utf8.encode(chapterKey)).bytes)
          .replaceAll('=', '');
      final chapterData = {
        'id': chapterId,
        'book_id': widget.bookId,
        'index_num': i,
        'title': ch['title'] ?? '未知章节',
        'url': ch['url'] ?? '',
        'content': null,
        'is_volume': ch['is_volume'] ?? false,
        'is_checked': false,
        'start': 0,
        'end': 0,
        'created_at': now,
        'updated_at': now,
      };
      chapterRecords.add(chapterData);
      savedCount++;
      cachedChaptersList.add({
        'id': chapterId,
        'url': ch['url'] ?? '',
        'title': ch['title'] ?? '未知章节',
        'content': null,
      });
    }

    await rust_api.replaceBookChapters(
      dbPath: dbPath,
      bookId: widget.bookId,
      chaptersJson: jsonEncode(chapterRecords),
    );

    int targetIndex = savedIndex;
    if (targetIndex < 0 || targetIndex >= chapters.length) {
      targetIndex = 0;
    }

    final updatedBook = Map<String, dynamic>.from(book);
    updatedBook['source_id'] = result.sourceId;
    updatedBook['source_name'] = result.sourceName;
    updatedBook['book_url'] = result.bookUrl;
    updatedBook['chapter_count'] = savedCount;
    if (chapters.isNotEmpty) {
      updatedBook['latest_chapter_title'] = chapters.last['title'];
    }
    if (result.bookInfo != null) {
      updatedBook['cover_url'] =
          result.bookInfo!['cover_url'] ?? book['cover_url'];
      updatedBook['intro'] = result.bookInfo!['intro'] ?? book['intro'];
      updatedBook['author'] = result.bookInfo!['author'] ?? book['author'];
    }
    updatedBook['updated_at'] = now;

    await rust_api.saveBook(dbPath: dbPath, bookJson: jsonEncode(updatedBook));

    // BATCH-25 (F-W2B-021)：两个 await 后补 mounted 检查，防 setState-after-dispose。
    if (!mounted) return;

    ref.invalidate(allBooksProvider);
    ref.invalidate(bookByIdProvider(widget.bookId));
    ref.invalidate(bookChaptersProvider(widget.bookId));

    _chapterRequestId++;
    final requestId = _chapterRequestId;
    setState(() {
      _isLoadingContent = true;
      _currentIndex = targetIndex;
      _cachedChapters = cachedChaptersList;
      _sourceId = result.sourceId;
      _sourceName = result.sourceName;
      _sourceUrl = result.bookUrl;
      _chapterUrl = cachedChaptersList.isNotEmpty
          ? (cachedChaptersList[targetIndex]['url'] as String? ?? '')
          : '';
      _loadedChapters = [];
      _cachedContinuousItems = null;
    });

    try {
      final chapterUrl = chapters[targetIndex]['url'] as String? ?? '';
      final json = await rust_api.getChapterContentWithSourceFromDb(
        dbPath: dbPath,
        sourceId: result.sourceId,
        chapterUrl: chapterUrl,
      );
      if (!mounted || requestId != _chapterRequestId) return;

      var content = '';
      if (json.isNotEmpty && json != 'null') {
        try {
          final data = jsonDecode(json);
          if (data is Map<String, dynamic>) {
            final platformRequest = data['platform_request'];
            if (platformRequest is Map) {
              content = await _executePlatformRequest(
                PlatformRequest.fromJson(
                    Map<String, dynamic>.from(platformRequest)),
              );
            } else {
              content = data['content'] as String? ?? '（无内容）';
            }
          } else {
            content = data.toString();
          }
        } catch (e) {
          debugPrint('[Reader] changeSource decode failed: $e');
          content = json;
        }
      } else {
        content = '（无内容）';
      }

      content = await _applyReplaceRulesViaRust(dbPath, content);

      await rust_api.saveReadingProgress(
        dbPath: dbPath,
        bookId: widget.bookId,
        chapterIndex: targetIndex,
        paragraphIndex: 0,
        offset: 0,
      );

      final title = chapters[targetIndex]['title'] as String? ?? '';
      content = _cleanHtml(content);
      setState(() {
        _chapterContent = content;
        _isLoadingContent = false;
        if (_settings.isScrollMode) {
          _loadedChapters = [_LoadedChapter(targetIndex, title, content)];
          _cachedContinuousItems = null;
        } else {
          _pageViewController?.updateSettings(_settings);
          _pageViewController?.loadChapter(targetIndex, title, content);
        }
      });
    } catch (e) {
      if (mounted && requestId == _chapterRequestId) {
        setState(() {
          _chapterContent = '换源后加载失败: $e';
          _isLoadingContent = false;
        });
      }
    }
  }

  void _startSearch() {
    setState(() {
      _controlsVisible = false;
    });
    _search.start();
  }

  void _closeSearch() {
    _search.close();
  }

  // Adapter that wires the chapter list seen by the reader (continuous mode
  // uses _loadedChapters, page mode falls back to a single synthetic chapter).
  List<String> _paragraphsForChapterAt(int idx) {
    if (_loadedChapters.isNotEmpty) {
      return _loadedChapters[idx].paragraphs;
    }
    return _LoadedChapter(_currentIndex, _chapterContent, _chapterContent)
        .paragraphs;
  }

  int get _searchChapterCount =>
      _loadedChapters.isNotEmpty ? _loadedChapters.length : 1;

  void _performSearch(String keyword) {
    _search.onScroll = (m) => _scrollToSearchMatch(m);
    _search.perform(keyword, _searchChapterCount, _paragraphsForChapterAt);
  }

  void _goToNextSearchMatch() {
    _search.onScroll = (m) => _scrollToSearchMatch(m);
    _search.next();
  }

  void _goToPrevSearchMatch() {
    _search.onScroll = (m) => _scrollToSearchMatch(m);
    _search.prev();
  }

  void _scrollToSearchMatch(rsc.ReaderSearchMatch match) {
    if (!_scrollController.hasClients) return;
    final estimatedOffset =
        200.0 * (match.chapterIdx * 50 + match.paragraphIdx);
    _scrollController.animateTo(
      estimatedOffset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
    );
  }

  /// 批次 4 (05-18): 启停自动翻页。根据当前阅读模式分派到 ReaderAutoScroller
  /// 的滚动路径（pixelsPerStep 推进 ScrollController）或分页路径
  /// （onPageTick 触发翻页）。
  void _toggleAutoScroll() =>
      _autoScroller.toggle(scroll: _settings.isScrollMode);

  /// 批次 5 (05-18): 长按文字菜单 MVP — 弹底部 sheet 让用户选复制 /
  /// 分享 / 朗读。整页粒度，不做字符级选区（避免破坏 ContentPagePainter
  /// 的 ui.Picture 仿真翻页预渲染机制）。
  Future<void> _showLongPressActionSheet() async {
    final pageText = getCurrentPageText(_pageViewController, _settings);
    if (pageText.isEmpty) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => LongPressActionSheet(pageText: pageText),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: pageText));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已复制当前页'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        break;
      case 'share':
        try {
          await SharePlus.instance.share(
            ShareParams(
              text: pageText,
              subject: _bookName.isNotEmpty ? _bookName : '阅读分享',
            ),
          );
        } catch (e) {
          debugPrint('[Reader] SharePlus.share failed: $e');
        }
        break;
      case 'aloud':
        // 复用现有 TTS 链路：把当前页设为朗读内容，然后 start。
        // 这与从顶部菜单点"朗读"的路径一致。
        _tts.setChapterContent(pageText);
        await _tts.start();
        break;
    }
  }

  // TTS API kept as thin wrappers around [_tts] so existing UI builders
  // continue to work without churn. The actual logic lives in
  // [ReaderTtsManager].
  bool get _isSpeaking => _tts.isSpeaking;
  bool get _isPaused => _tts.isPaused;

  Future<void> _startTts() async {
    _tts.setChapterContent(_chapterContent);
    await _tts.start();
  }

  void _pauseTts() => _tts.pause();
  void _resumeTts() => _tts.resume();
  void _stopTts() => _tts.stop();
  void _ttsNextParagraph() => _tts.nextParagraph();
  void _ttsPrevParagraph() => _tts.prevParagraph();

  void _cycleTtsSpeed() {
    const speeds = [0.3, 0.5, 0.7, 0.8, 0.9, 1.0];
    final idx = speeds.indexOf(_settings.ttsSpeed);
    final next =
        speeds[(idx < 0 ? speeds.length - 1 : (idx + 1) % speeds.length)];
    final s = _settings.copyWith(ttsSpeed: next);
    _setReaderSettings(s, persist: true);
    _tts.setRate(next);
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _saveScrollPosition();
  }

  Widget _buildReadingInfoHeader(ReaderSettings settings) {
    final fg = Color(settings.effectiveTextColor);
    final infoStyle = TextStyle(
        color: fg.withValues(alpha: 0.5),
        fontSize: 12,
        decoration: TextDecoration.none);
    if (!settings.showChapterTitle) return const SizedBox.shrink();
    final chapters = _cachedChapters;
    final effIdx = _settings.isScrollMode
        ? _visibleChapterIndex
        : _currentIndex;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Text(
        chapters != null && effIdx < chapters.length
            ? (chapters[effIdx]['title'] as String? ?? '')
            : '',
        style: infoStyle,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildReadingInfoFooter(
      List<Map<String, dynamic>> chapters, ReaderSettings settings) {
    final fg = Color(settings.effectiveTextColor);
    final infoStyle = TextStyle(
        color: fg.withValues(alpha: 0.5),
        fontSize: 12,
        decoration: TextDecoration.none);
    final chapterIndex = _settings.isScrollMode
        ? _visibleChapterIndex
        : _currentIndex;
    final safeChapterIndex =
        chapters.isEmpty ? 0 : chapterIndex.clamp(0, chapters.length - 1);
    final chapterProgress = chapters.isEmpty
        ? 0
        : (((safeChapterIndex + 1) / chapters.length) * 100)
            .clamp(0, 100)
            .round();
    final pageIndex = (_pageViewController?.currentPageIndex ?? 0) + 1;
    final pageTotal = _pageViewController?.totalPagesInChapter ?? 0;
    final progressText = !_settings.isScrollMode
        ? '第 $pageIndex/$pageTotal 页 · 第 ${safeChapterIndex + 1}/${chapters.length} 章'
        : '第 ${safeChapterIndex + 1}/${chapters.length} 章 · $chapterProgress%';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
      child: Row(
        children: [
          if (settings.showProgress) ...[
            Expanded(
              child: Text(
                progressText,
                style: infoStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            const Spacer(),
          if (settings.showClock)
            ValueListenableBuilder<DateTime>(
              valueListenable: _nowNotifier,
              builder: (context, v, _) => Text(
                '${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}',
                style: infoStyle,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return ReaderSearchBar(
      settings: _settings,
      controller: _searchController,
      matchCount: _search.matches.length,
      currentIndex: _search.currentIndex,
      onChanged: (v) {
        _performSearch(v);
        setState(() {});
      },
      onPrev: _goToPrevSearchMatch,
      onNext: _goToNextSearchMatch,
      onClose: _closeSearch,
    );
  }

  Widget _buildTtsBar() {
    final paragraphs = _chapterContent
        .split(RegExp(r'\n+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
    return ReaderTtsBar(
      settings: _settings,
      isSpeaking: _isSpeaking,
      isPaused: _isPaused,
      paragraphIndex: _tts.paragraphIndex,
      paragraphTotal: paragraphs.length,
      onPrev: _ttsPrevParagraph,
      onNext: _ttsNextParagraph,
      onPause: _pauseTts,
      onResume: _resumeTts,
      onCycleSpeed: _cycleTtsSpeed,
      onShowSettings: _showReaderSettings,
      onStop: _stopTts,
    );
  }

  void _showReaderSettings() {
    _toggleControls();
    showModalBottomSheet(
      context: context,
      backgroundColor: Color(_settings.effectiveBackgroundColor),
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height / 2,
      ),
      builder: (ctx) => ReaderSettingsSheet(
        initial: _settings,
        onChanged: (s) {
          _setReaderSettings(s, persist: true);
        },
      ),
    );
  }
}


