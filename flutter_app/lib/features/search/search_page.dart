import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/cover_cache.dart';
import '../../core/providers.dart';
import '../../core/widgets/safe_setstate.dart';
import '../../src/rust/api.dart' as rust_api;

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();

  /// 精确模式过滤 + 三档排序：
  /// 1. `name == keyword` 的条目（最高优先级）
  /// 2. `author == keyword` 的条目
  /// 3. `name.contains(keyword) || author.contains(keyword)` 的条目
  ///
  /// 既不等也不包含的条目被丢弃。这与 Legado MD3
  /// `SearchModel.startSearch` + `mergeItems` 的 equalData/containsData
  /// 排序对齐，差异是排序在客户端而不是抓取层（Rust 端零改动）。
  ///
  /// keyword 为空时认为没有过滤意义，原样返回（避免吞掉所有结果）。
  @visibleForTesting
  static List<Map<String, dynamic>> applyPrecisionFilter(
    List<Map<String, dynamic>> results,
    String keyword,
  ) {
    if (keyword.isEmpty) return List<Map<String, dynamic>>.from(results);
    final equalName = <Map<String, dynamic>>[];
    final equalAuthor = <Map<String, dynamic>>[];
    final contains = <Map<String, dynamic>>[];
    for (final r in results) {
      final name = r['name'] as String? ?? '';
      final author = r['author'] as String? ?? '';
      if (name == keyword) {
        equalName.add(r);
      } else if (author == keyword) {
        equalAuthor.add(r);
      } else if (name.contains(keyword) || author.contains(keyword)) {
        contains.add(r);
      }
      // 不匹配的条目被丢弃
    }
    return [...equalName, ...equalAuthor, ...contains];
  }
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _searchCtrl = TextEditingController();
  bool _loading = false;
  bool _precisionMode = false;
  List<String> _searchHistory = [];

  /// 本地书架搜索结果。
  List<Map<String, dynamic>> _localResults = [];
  /// 在线书源搜索结果。
  List<Map<String, dynamic>> _onlineResults = [];

  /// Task X3 (Bug A) — 记忆上一次搜索的 keyword。
  ///
  /// `_togglePrecisionMode` 在用户已经清空 TextField 的情况下也要能用上次
  /// 关键字重过滤已经展示的结果，否则 toggle 切换看不见效果。
  /// 只在 [_doSearch] 入口（trim 后、空校验通过后）写入此字段。
  String _lastSearchKeyword = '';

  /// BATCH-21 (F-W2B-019): 自增 seq token，用于丢弃旧 future 的回写。
  ///
  /// 用户连续输入两次关键词（如 "剑来" → "凡人"）时，旧的 future 仍在
  /// FRB 后台执行，没有 cancel API。`_doSearch` 入口记录 `seq = ++_searchSeq`，
  /// 每个 await 后判 `seq == _searchSeq` 才继续；不等于说明有更新的
  /// `_doSearch` 调用启动了，本次结果直接丢弃。
  int _searchSeq = 0;

  /// 测试用：让 widget test 能验证 toggle 后 keyword 已记忆。
  @visibleForTesting
  String get debugLastSearchKeyword => _lastSearchKeyword;

  /// BATCH-21 (F-W2B-019) 测试用：让 widget test 能验证连续两次 _doSearch
  /// 调用后 seq 已自增，旧 future 在 await 后会被 seq 校验过滤掉。
  @visibleForTesting
  int get debugSearchSeq => _searchSeq;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadPrecisionMode();
  }

  Future<void> _loadHistory() async {
    final history = await loadSearchHistoryFromDisk();
    safeSetState(() => _searchHistory = history);
  }

  Future<void> _loadPrecisionMode() async {
    final v = await loadSearchPrecisionFromDisk();
    safeSetState(() => _precisionMode = v);
  }

  void _togglePrecisionMode() {
    setState(() => _precisionMode = !_precisionMode);
    if (_precisionMode) {
      // Apply precision filter to existing results without re-searching
      if (_localResults.isNotEmpty && _lastSearchKeyword.isNotEmpty) {
        _localResults = SearchPage.applyPrecisionFilter(
            List<Map<String, dynamic>>.from(_localResults), _lastSearchKeyword);
      }
      if (_onlineResults.isNotEmpty && _lastSearchKeyword.isNotEmpty) {
        _onlineResults = SearchPage.applyPrecisionFilter(
            List<Map<String, dynamic>>.from(_onlineResults), _lastSearchKeyword);
      }
    }
    unawaited(saveSearchPrecisionToDisk(_precisionMode));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_precisionMode ? '已切换到精确搜索' : '已切换到模糊搜索'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
    if (_lastSearchKeyword.isNotEmpty) {
      if (_searchCtrl.text != _lastSearchKeyword) {
        _searchCtrl.text = _lastSearchKeyword;
      }
      _doSearch();
    }
  }

  void _showPrecisionEmptyDialog() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('精确搜索无结果'),
        content: const Text('当前精确搜索模式无匹配结果，是否切换到模糊搜索？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('保持精确'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _togglePrecisionMode();
            },
            child: const Text('切换到模糊'),
          ),
        ],
      ),
    );
  }

  Future<void> _addToHistory(String keyword) async {
    _searchHistory.remove(keyword);
    _searchHistory.insert(0, keyword);
    if (_searchHistory.length > 20) {
      _searchHistory = _searchHistory.sublist(0, 20);
    }
    await saveSearchHistoryToDisk(_searchHistory);
    safeSetState(() {});
  }

  Future<void> _clearHistory() async {
    _searchHistory = [];
    await saveSearchHistoryToDisk([]);
    safeSetState(() {});
  }

  Future<void> _saveResultToBookshelf(Map<String, dynamic> result) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final bookUrl = result['book_url'] as String?;
    final sourceId = result['source_id'] as String?;

    // P1-3 / R18: Rust parser emits a stable id (sha256 of
    // `source_id|book_url|name|author`, base64url no-padding) for every
    // SearchResult, including the all-empty fallback. Just trust it.
    //
    // We used to keep a Dart-side re-hash here for a "rare empty id" edge
    // case, but the Dart fallback (`name|millis`) didn't match the Rust
    // fallback (`unknown|secs`) byte-for-byte, so the two algorithms could
    // produce different ids for the same result. Removing the Dart branch
    // eliminates that drift; if a result ever does arrive without an id we
    // refuse to insert it (snackbar lets the user try again).
    final rawId = (result['id'] as String?)?.trim();
    if (rawId == null || rawId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('搜索结果缺少 id，无法加入书架')),
        );
      }
      return;
    }
    final String bookId = rawId;
    final bookData = <String, dynamic>{
      'id': bookId,
      'source_id': sourceId ?? '',
      'source_name': result['source_name'],
      'name': result['name'] ?? '未知',
      'author': result['author'],
      'cover_url': result['cover_url'],
      'chapter_count': result['chapter_count'] ?? 0,
      'latest_chapter_title': result['latest_chapter_title'],
      'intro': result['intro'],
      'kind': result['kind'],
      'book_url': result['book_url'],
      'toc_url': result['toc_url'] ?? result['book_url'],
      'last_check_time': result['last_check_time'],
      'last_check_count': result['last_check_count'] ?? 0,
      'total_word_count': result['total_word_count'] ?? 0,
      'can_update': result['can_update'] ?? true,
      'order_time': result['order_time'] ?? now,
      'latest_chapter_time': result['latest_chapter_time'],
      'custom_cover_path': result['custom_cover_path'],
      'custom_info_json': result['custom_info_json'],
      'created_at': result['created_at'] ?? now,
      'updated_at': now,
    };
    var savedBook = false;
    var savedChapterCount = 0;
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      if (!mounted) return;
      await rust_api.saveBook(dbPath: dbPath, bookJson: jsonEncode(bookData));
      if (!mounted) return;
      savedBook = true;
      final coverUrl = result['cover_url'] as String?;
      if (coverUrl != null && coverUrl.isNotEmpty) {
        unawaited(CoverCache.downloadAndCache(coverUrl).then((localPath) async {
          if (localPath != null) {
            bookData['custom_cover_path'] = localPath;
            try {
              await rust_api.saveBook(
                  dbPath: dbPath, bookJson: jsonEncode(bookData));
            } catch (e) {
              debugPrint('[Search] update cover path failed: $e');
            }
          }
        }));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加失败: $e')),
        );
      }
      return;
    }

    if (bookUrl != null &&
        bookUrl.isNotEmpty &&
        sourceId != null &&
        sourceId.isNotEmpty) {
      // Fetch chapters online as fallback
      try {
        final dbPath = await ref.read(dbPathProvider.future);
        if (!mounted) return;
        final sourceJson = await rust_api.getSourceForDownload(
          dbPath: dbPath,
          sourceId: result['source_id'] as String,
        );
        if (!mounted) return;
        final chaptersJson = await rust_api.getChapterListOnline(
          sourceJson: sourceJson,
          bookUrl: bookUrl,
        );
        if (!mounted) return;
        final List<dynamic> chapters = jsonDecode(chaptersJson);
        final chapterRecords = <Map<String, dynamic>>[];
        for (var i = 0; i < chapters.length; i++) {
          final ch = chapters[i] as Map<String, dynamic>;
          final chapterKey = '${bookData['id']}|$i|${ch['url'] ?? ''}';
          final chapterId = base64Url
              .encode(sha256.convert(utf8.encode(chapterKey)).bytes)
              .replaceAll('=', '');
          chapterRecords.add({
            'id': chapterId,
            'book_id': bookData['id'],
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
          });
        }
        if (chapterRecords.isNotEmpty) {
          await rust_api.replaceBookChaptersPreservingContent(
            dbPath: dbPath,
            bookId: bookId,
            chaptersJson: jsonEncode(chapterRecords),
          );
          savedChapterCount = chapterRecords.length;
          bookData['chapter_count'] = savedChapterCount;
          if (chapters.isNotEmpty) {
            bookData['latest_chapter_title'] =
                (chapters.last as Map<String, dynamic>)['title'];
          }
          await rust_api.saveBook(
              dbPath: dbPath, bookJson: jsonEncode(bookData));
        }
      } catch (e) {
        debugPrint('拉取章节失败: $e');
      }
    }

    if (!mounted || !savedBook) return;
    ref.invalidate(allBooksProvider);
    ref.invalidate(booksByGroupProvider);
    if (savedChapterCount > 0) {
      ref.invalidate(bookChaptersProvider(bookId));
    }
    final String snackMsg;
    if (savedChapterCount > 0) {
      snackMsg = '已添加: ${bookData['name']} ($savedChapterCount章)';
    } else if (bookUrl != null && bookUrl.isNotEmpty) {
      if (sourceId != null && sourceId.isNotEmpty) {
        snackMsg = '已添加: ${bookData['name']}（章节加载失败或目录为空）';
      } else {
        snackMsg = '已添加: ${bookData['name']}（无有效书源，未能加载章节）';
      }
    } else {
      snackMsg = '已添加: ${bookData['name']}';
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(snackMsg)));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 本地书架搜索（返回原始结果，precision 过滤由 [_doSearch] 统一处理）。
  Future<List<Map<String, dynamic>>> _searchLocal(String keyword) async {
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final offlineJson =
          await rust_api.searchBooksOffline(dbPath: dbPath, keyword: keyword);
      final List<dynamic> offlineList = jsonDecode(offlineJson);
      return offlineList.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('[Search] local search failed: $e');
      return <Map<String, dynamic>>[];
    }
  }

  /// Search online using enabled sources.
  Future<List<Map<String, dynamic>>> _searchOnline(String keyword) async {
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final sourcesJson = await rust_api.getEnabledSources(dbPath: dbPath);
      final List<dynamic> sources = jsonDecode(sourcesJson);
      if (sources.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有启用的书源，请先在书源管理中启用书源')),
          );
        }
        return <Map<String, dynamic>>[];
      }
      final futures = <Future<List<Map<String, dynamic>>>>[];
      for (final source in sources) {
        if (source == null) continue;
        futures.add(
          _searchWithSource(dbPath, source, keyword)
            .timeout(const Duration(seconds: 15), onTimeout: () {
              debugPrint('书源 ${source['name']} 搜索超时');
              return <Map<String, dynamic>>[];
            }),
        );
      }
      final allResults = await Future.wait(futures);
      final flatResults = allResults.expand((r) => r).toList();
      final seen = <String>{};
      final deduped = <Map<String, dynamic>>[];
      for (final r in flatResults) {
        final key = '${r['name']}_${r['author']}';
        if (seen.add(key)) {
          deduped.add(r);
        }
      }
      return deduped;
    } catch (e) {
      debugPrint('[Search] online search failed: $e');
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _doSearch() async {
    final keyword = _searchCtrl.text.trim();
    if (keyword.isEmpty) return;
    // BATCH-21 (F-W2B-019): 自增 seq；每个 await 后判 seq == _searchSeq，
    // 不等于则丢弃本次结果（说明 user 已发起新搜索，旧 future 不能覆盖
    // 新结果 / 改 _loading）。
    final seq = ++_searchSeq;
    _lastSearchKeyword = keyword;
    setState(() {
      _loading = true;
    });

    // Always search both local AND online concurrently
    await ref.read(dbInitializedProvider.future);
    if (!mounted || seq != _searchSeq) {
      if (mounted) safeSetState(() => _loading = false);
      return;
    }

    // Fire local search (always)
    final localFuture = _searchLocal(keyword);

    // Fire online search (always)
    final onlineFuture = _searchOnline(keyword);

    // Await local first (typically faster), show partial results
    int rawLocalCount = 0;
    try {
      final rawLocal = await localFuture;
      rawLocalCount = rawLocal.length;
      if (mounted && seq == _searchSeq) {
        final filteredLocal = _precisionMode
            ? SearchPage.applyPrecisionFilter(rawLocal, keyword)
            : rawLocal;
        setState(() => _localResults = filteredLocal);
      }
    } catch (_) {}

    int rawOnlineCount = 0;
    try {
      final rawOnline = await onlineFuture;
      rawOnlineCount = rawOnline.length;
      if (mounted && seq == _searchSeq) {
        final filteredOnline = _precisionMode
            ? SearchPage.applyPrecisionFilter(rawOnline, keyword)
            : rawOnline;
        setState(() => _onlineResults = filteredOnline);
      }
    } catch (_) {}

    if (mounted && seq == _searchSeq) {
      setState(() => _loading = false);
      if (_precisionMode && _localResults.isEmpty && _onlineResults.isEmpty &&
          (rawLocalCount > 0 || rawOnlineCount > 0)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && seq == _searchSeq) {
            _showPrecisionEmptyDialog();
          }
        });
      }
      _addToHistory(keyword);
    }
  }

  Future<List<Map<String, dynamic>>> _searchWithSource(
      String dbPath, dynamic source, String keyword) async {
    // We used to fetch the HTML with Dio in Dart and feed it to the Rust
    // `searchParseHtml` parser, on the (incorrect) assumption that Android's
    // DNS stack was unreliable for the Rust HTTP layer. That detour also
    // missed every URL feature Legado relies on — JS templates, page-number
    // expressions, URL-option `{"method":"POST","charset":"gbk",...}`,
    // shared cookie jar, etc.
    //
    // The single-call `searchWithSourceFromDb` routes through `LegadoHttpClient`
    // which handles all of that correctly.
    try {
      final sourceId = source['id'] as String;
      final sourceName = source['name'] as String? ?? '未知书源';
      final json = await rust_api.searchWithSourceFromDb(
        dbPath: dbPath,
        sourceId: sourceId,
        keyword: keyword,
      );
      final List<dynamic> results = jsonDecode(json);
      return results.map<Map<String, dynamic>>((r) {
        final m = Map<String, dynamic>.from(r as Map);
        // Rust side already populates source_name/source_id but be defensive:
        // if the parser returned an [ERR] entry without a source name, patch
        // it back so the UI can still display the source label.
        m['source_name'] ??= sourceName;
        m['source_id'] ??= sourceId;
        return m;
      }).toList();
    } catch (e) {
      debugPrint('搜索书源 ${source['id']} 失败: $e');
      return <Map<String, dynamic>>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        titleSpacing: 0,
        title: Container(
          height: 44,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(28),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(Icons.search,
                  size: 18, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  style: TextStyle(fontSize: 15, color: colorScheme.onSurface),
                  decoration: InputDecoration(
                    hintText: '搜索书名、作者',
                    hintStyle: TextStyle(
                      fontSize: 15,
                      color: colorScheme.onSurfaceVariant.withAlpha(0x99),
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onSubmitted: (_) => _doSearch(),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      icon: const Icon(Icons.arrow_forward_ios),
                      onPressed: () {},
                      tooltip: '下一个',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          Builder(
            builder: (ctx) => PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: '更多',
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              elevation: 8,
              color: colorScheme.surfaceContainerHigh,
              onSelected: (value) => _onMenuSelected(value, ctx),
              itemBuilder: (_) => _buildMenuItems(ctx, colorScheme),
            ),
          ),
        ],
      ),
      body: _loading && _localResults.isEmpty && _onlineResults.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _localResults.isEmpty && _onlineResults.isEmpty && !_loading
              ? _buildSearchHistory()
              : _buildResultsList(),
    );
  }

  void _onMenuSelected(String value, BuildContext ctx) {
    switch (value) {
      case 'toggle_precision':
        _togglePrecisionMode();
      case 'clear_history':
        _clearHistory();
      case 'source_manage':
        ctx.push('/sources');
      case 'multi_group':
        // placeholder — 多分组/书源
        break;
      case _:
        if (value.startsWith('source_')) {
          // radio source selection handled in itemBuilder
        }
        break;
    }
  }

  List<PopupMenuEntry<String>> _buildMenuItems(
      BuildContext ctx, ColorScheme cs) {
    final enabledSources = ref.read(allSourcesProvider).valueOrNull ?? [];
    final items = <PopupMenuEntry<String>>[];

    // 精准搜索 checkbox-style menu item
    items.add(
      PopupMenuItem(
        value: 'toggle_precision',
        child: _MenuCheckboxItem(
          label: '精准搜索',
          checked: _precisionMode,
        ),
      ),
    );
    items.add(const PopupMenuDivider());

    // 书源管理 / 多分组书源
    items.add(
      PopupMenuItem(
        value: 'source_manage',
        child: _MenuTextItem(label: '书源管理'),
      ),
    );
    items.add(
      const PopupMenuItem(
        value: 'multi_group',
        enabled: false,
        child: _MenuTextItem(label: '多分组/书源'),
      ),
    );
    items.add(const PopupMenuDivider());

    // 已启用书源 radio list
    for (final s in enabledSources) {
      final name = s['name'] as String? ?? '';
      if (name.isEmpty) continue;
      items.add(
        PopupMenuItem(
          value: 'source_${s['id'] ?? ''}',
          child: _MenuRadioItem(
            label: name,
            // always unselected for now — radio selection is UX placeholder
            selected: false,
          ),
        ),
      );
    }
    items.add(const PopupMenuDivider());

    // 清空历史 + 日志
    items.add(
      PopupMenuItem(
        value: 'clear_history',
        child: _MenuTextItem(label: '清空历史'),
      ),
    );
    items.add(
      const PopupMenuItem(
        value: 'log',
        enabled: false,
        child: _MenuTextItem(label: '日志'),
      ),
    );

    return items;
  }

  /// 双 Section 结果列表 — 本地书架 + 在线书源。
  Widget _buildResultsList() {
    final hasLocal = _localResults.isNotEmpty;
    final hasOnline = _onlineResults.isNotEmpty;
    if (!hasLocal && !hasOnline) {
      return const SizedBox.shrink();
    }

    // Section layout: [local header, local items..., online header, online items...]
    final localSectionTotal = hasLocal ? 1 + _localResults.length : 0;
    final totalCount =
        localSectionTotal + (hasOnline ? 1 + _onlineResults.length : 0);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: totalCount,
      itemBuilder: (context, index) {
        if (index < localSectionTotal) {
          if (index == 0) {
            return _buildSectionHeader('本地书架', _localResults.length);
          }
          return _buildBookCard(_localResults[index - 1]);
        }
        final onlineIndex = index - localSectionTotal;
        if (onlineIndex == 0) {
          return _buildSectionHeader('书源搜索', _onlineResults.length);
        }
        return _buildBookCard(_onlineResults[onlineIndex - 1]);
      },
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4, left: 4),
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count 条',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.al.textSecondary,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookCard(Map<String, dynamic> book) {
    final coverUrl = book['cover_url'] as String?;
    final name = book['name'] as String? ?? '未知';
    final author = book['author'] as String? ?? '';
    final kind = book['kind'] as String?;
    final intro = book['intro'] as String?;
    final sourceName = book['source_name'] as String?;
    final chapterCount = book['chapter_count'] as int?;
    final latestChapter = book['last_chapter'] as String? ??
        book['latest_chapter_title'] as String?;

    final subtitleParts = <String>[
      if (author.isNotEmpty) author,
      if (kind != null && kind.isNotEmpty) kind,
      if (chapterCount != null && chapterCount > 0) '目录 $chapterCount 章',
      if (latestChapter != null && latestChapter.isNotEmpty) latestChapter,
      if (sourceName != null && sourceName.isNotEmpty) '来源: $sourceName',
    ];

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showBookDetail(context, book),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCover(coverUrl),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (subtitleParts.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitleParts.join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: context.al.onSurface),
                      ),
                    ],
                    if (intro != null && intro.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        intro,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: context.al.textSecondary, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                color: Theme.of(context).colorScheme.primary,
                tooltip: '加入书架',
                onPressed: () => _saveResultToBookshelf(book),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchHistory() {
    final colorScheme = Theme.of(context).colorScheme;
    if (_searchHistory.isEmpty) {
      return const Center(child: Text('输入关键词搜索书籍'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Row(
              children: [
                Text(
                  '搜索历史',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _clearHistory,
                  child: Text(
                    '清除',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _searchHistory.map((term) {
              return Material(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    _searchCtrl.text = term;
                    _doSearch();
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Text(
                      term,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildCover(String? coverUrl) {
    const double w = 56;
    const double h = 78;
    if (coverUrl == null || coverUrl.isEmpty) {
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(Icons.book, size: 28, color: context.al.outline),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: CachedNetworkImage(
        imageUrl: coverUrl,
        width: w,
        height: h,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(
          width: w,
          height: h,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        errorWidget: (_, __, ___) => Container(
          width: w,
          height: h,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child:
              Icon(Icons.broken_image, size: 24, color: context.al.outline),
        ),
      ),
    );
  }

  void _showBookDetail(BuildContext context, Map<String, dynamic> book) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        expand: false,
        builder: (ctx, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 80,
                        height: 108,
                        child: _buildCover(book['cover_url'] as String?),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            book['name'] as String? ?? '未知',
                            style:
                                Theme.of(ctx).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                          ),
                          const SizedBox(height: 4),
                          if (book['author'] != null)
                            Text('作者: ${book['author']}',
                                style: Theme.of(ctx).textTheme.bodySmall),
                          if (book['kind'] != null)
                            Text('分类: ${book['kind']}',
                                style: Theme.of(ctx).textTheme.bodySmall),
                          if (book['last_chapter'] != null)
                            Text('最新章节: ${book['last_chapter']}',
                                style: Theme.of(ctx).textTheme.bodySmall),
                          if (book['source_name'] != null)
                            Text('来源: ${book['source_name']}',
                                style:
                                    Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                          color: ctx.al.textSecondary,
                                        )),
                        ],
                      ),
                    ),
                  ],
                ),
                if (book['intro'] != null) ...[
                  const SizedBox(height: 14),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text('简介', style: Theme.of(ctx).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  Text(
                    book['intro'] as String? ?? '',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          color: ctx.al.onSurface,
                          height: 1.5,
                        ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _saveResultToBookshelf(book);
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('加入书架'),
                  ),
                ),
                SizedBox(height: MediaQuery.of(ctx).padding.bottom + 60),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// MD3-style menu checkbox item matching HTML search menu.
class _MenuCheckboxItem extends StatelessWidget {
  final String label;
  final bool checked;

  const _MenuCheckboxItem({required this.label, required this.checked});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: checked ? cs.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: checked ? cs.primary : cs.onSurfaceVariant,
              width: 2,
            ),
          ),
          child: checked
              ? Icon(Icons.check, size: 14, color: cs.onPrimary)
              : null,
        ),
      ],
    );
  }
}

/// MD3-style menu text-only item.
class _MenuTextItem extends StatelessWidget {
  final String label;

  const _MenuTextItem({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(label, style: const TextStyle(fontSize: 13));
  }
}

/// MD3-style menu radio item.
class _MenuRadioItem extends StatelessWidget {
  final String label;
  final bool selected;

  const _MenuRadioItem({required this.label, required this.selected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? cs.primary : cs.onSurfaceVariant,
              width: 2,
            ),
          ),
          child: selected
              ? Center(
                  child: Icon(Icons.check,
                      size: 12, color: cs.primary),
                )
              : null,
        ),
      ],
    );
  }
}
