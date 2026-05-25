import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../src/rust/api.dart' as rust_api;

import '../../core/colors.dart';

typedef ChangeSourceGetEnabledSources = Future<String> Function(String dbPath);
typedef ChangeSourceSearchWithSource = Future<String> Function(
  String dbPath,
  String sourceId,
  String keyword,
);

class ChangeSourceResult {
  final String sourceId;
  final String sourceName;
  final String bookUrl;
  final Map<String, dynamic>? bookInfo;
  final List<Map<String, dynamic>> chapters;

  const ChangeSourceResult({
    required this.sourceId,
    required this.sourceName,
    required this.bookUrl,
    this.bookInfo,
    required this.chapters,
  });
}

class ChangeSourceDialog extends StatefulWidget {
  final String dbPath;
  final String bookName;
  final String bookAuthor;
  final String currentSourceId;
  final String currentSourceName;
  final ChangeSourceGetEnabledSources? getEnabledSourcesOverride;
  final ChangeSourceSearchWithSource? searchWithSourceOverride;

  const ChangeSourceDialog({
    super.key,
    required this.dbPath,
    required this.bookName,
    required this.bookAuthor,
    required this.currentSourceId,
    required this.currentSourceName,
    this.getEnabledSourcesOverride,
    this.searchWithSourceOverride,
  });

  @override
  State<ChangeSourceDialog> createState() => _ChangeSourceDialogState();
}

class _ChangeSourceDialogState extends State<ChangeSourceDialog> {
  bool _isSearching = false;
  bool _isLoadingToc = false;
  int _searchedCount = 0;
  int _totalSources = 0;
  int _resultCount = 0;
  String? _errorMessage;
  String? _currentLoadingSource;
  String? _selectedSourceId;
  late String _currentSourceId;
  final List<Map<String, dynamic>> _results = [];
  final Set<String> _resultKeys = {};
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _currentSourceId = widget.currentSourceId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _startSearch());
  }

  @override
  void dispose() {
    _searchSeq++;
    super.dispose();
  }

  Future<void> _startSearch() async {
    if (!mounted) return;
    final seq = ++_searchSeq;
    setState(() {
      _isSearching = true;
      _errorMessage = null;
      _results.clear();
      _resultKeys.clear();
      _searchedCount = 0;
      _resultCount = 0;
      _totalSources = 0;
      _currentLoadingSource = null;
    });

    try {
      final getEnabledSources = widget.getEnabledSourcesOverride ??
          (String dbPath) => rust_api.getEnabledSources(dbPath: dbPath);
      final sourcesJson = await getEnabledSources(widget.dbPath);
      if (!mounted || seq != _searchSeq) return;
      final List<dynamic> sources = jsonDecode(sourcesJson);

      if (sources.isEmpty) {
        setState(() {
          _isSearching = false;
          _errorMessage = '没有启用的书源';
        });
        return;
      }

      setState(() => _totalSources = sources.length);

      await _searchSourcesIncrementally(seq, sources);
      if (!mounted || seq != _searchSeq) return;

      setState(() {
        _isSearching = false;
        _currentLoadingSource = null;
        if (_results.isEmpty) {
          _errorMessage = '所有书源均未搜索到结果';
        }
      });
    } catch (e) {
      if (mounted && seq == _searchSeq) {
        setState(() {
          _isSearching = false;
          _errorMessage = '搜索失败: $e';
        });
      }
    }
  }

  Future<void> _searchSourcesIncrementally(
      int seq, List<dynamic> sources) async {
    const maxConcurrent = 8;
    var nextIndex = 0;
    final workerCount =
        sources.length < maxConcurrent ? sources.length : maxConcurrent;

    Future<void> worker() async {
      while (mounted && seq == _searchSeq) {
        final index = nextIndex++;
        if (index >= sources.length) return;
        final rawSource = sources[index];
        if (rawSource is! Map<String, dynamic>) {
          _markSourceSearched(seq, null, const []);
          continue;
        }

        final sourceName = rawSource['name'] as String? ?? '未知书源';
        final results = await _searchSource(rawSource);
        if (!mounted || seq != _searchSeq) return;
        _markSourceSearched(seq, sourceName, results);
      }
    }

    await Future.wait<void>(
      List.generate(workerCount, (_) => worker()),
    );
  }

  void _markSourceSearched(
    int seq,
    String? sourceName,
    List<Map<String, dynamic>> sourceResults,
  ) {
    if (!mounted || seq != _searchSeq) return;
    setState(() {
      _searchedCount++;
      _currentLoadingSource = sourceName;
      for (final r in sourceResults) {
        // Keep the legacy one-result-per-source behavior while allowing each
        // source to publish as soon as it completes.
        final dedupKey = '${r['source_name']}_${r['source_id']}';
        if (_resultKeys.add(dedupKey)) {
          _results.add(r);
        }
      }
      _resultCount = _results.length;
    });
  }

  Future<List<Map<String, dynamic>>> _searchSource(
      Map<String, dynamic> source) async {
    try {
      final searchWithSource = widget.searchWithSourceOverride ??
          (String dbPath, String sourceId, String keyword) =>
              rust_api.searchWithSourceFromDbV2(
                dbPath: dbPath,
                sourceId: sourceId,
                keyword: keyword,
              );
      final onlineJson = await searchWithSource(
        widget.dbPath,
        source['id'] as String,
        widget.bookName,
      ).timeout(const Duration(seconds: 20), onTimeout: () => '[]');
      final List<dynamic> sourceResults = jsonDecode(onlineJson);
      // v2 may return [{"ok":false,"error":...}] for empty results
      if (sourceResults.length == 1 &&
          sourceResults[0] is Map &&
          sourceResults[0]['ok'] == false) {
        return <Map<String, dynamic>>[];
      }
      return sourceResults.map<Map<String, dynamic>>((r) {
        final m = Map<String, dynamic>.from(r as Map);
        m['source_name'] = source['name'] ?? '未知书源';
        m['source_id'] = source['id'];
        return m;
      }).toList();
    } catch (e) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _selectSource(Map<String, dynamic> result) async {
    if (_isLoadingToc) return;

    final sourceId = result['source_id'] as String;
    final bookUrl = result['book_url'] as String? ?? '';

    if (bookUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该书源缺少书籍链接')),
      );
      return;
    }

    setState(() {
      _isLoadingToc = true;
      _selectedSourceId = sourceId;
    });

    try {
      final sourceJson = await rust_api.getSourceForDownload(
        dbPath: widget.dbPath,
        sourceId: sourceId,
      );
      if (!mounted) return;

      final chaptersJson = await rust_api
          .getChapterListOnline(
            sourceJson: sourceJson,
            bookUrl: bookUrl,
          )
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;

      final List<dynamic> chaptersRaw = jsonDecode(chaptersJson);
      final chapters = chaptersRaw.map<Map<String, dynamic>>((ch) {
        final c = ch as Map<String, dynamic>;
        return {
          'title': c['title'] ?? '未知章节',
          'url': c['url'] ?? '',
        };
      }).toList();

      if (chapters.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该书源无章节目录')),
          );
        }
        setState(() {
          _isLoadingToc = false;
          _selectedSourceId = null;
        });
        return;
      }

      Map<String, dynamic>? bookInfo;
      try {
        final infoJson = await rust_api
            .getBookInfoOnline(
              sourceJson: sourceJson,
              bookUrl: bookUrl,
            )
            .timeout(const Duration(seconds: 15));
        if (infoJson.isNotEmpty && infoJson != 'null') {
          final decoded = jsonDecode(infoJson);
          if (decoded is Map<String, dynamic>) {
            bookInfo = decoded;
          }
        }
      } catch (e) {
        debugPrint('[ChangeSource] fetch book info failed: $e');
      }

      if (!mounted) return;

      setState(() => _currentSourceId = sourceId);

      Navigator.of(context).pop(ChangeSourceResult(
        sourceId: sourceId,
        sourceName: result['source_name'] as String? ?? '未知书源',
        bookUrl: bookUrl,
        bookInfo: bookInfo,
        chapters: chapters,
      ));
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingToc = false;
          _selectedSourceId = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载目录失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('换源 - ${widget.bookName}'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_isSearching)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _startSearch,
              tooltip: '重新搜索',
            ),
        ],
      ),
      body: Column(
        children: [
          if (_isSearching) ...[
            LinearProgressIndicator(
              value: _totalSources > 0 ? _searchedCount / _totalSources : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _currentLoadingSource == null
                          ? '正在搜索 $_searchedCount/$_totalSources ...'
                          : '已搜索 $_searchedCount/$_totalSources，最近完成: $_currentLoadingSource',
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ] else if (_errorMessage != null) ...[
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(Icons.search_off, size: 48, color: theme.disabledColor),
                  const SizedBox(height: 12),
                  Text(_errorMessage!, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _startSearch,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新搜索'),
                  ),
                ],
              ),
            ),
          ],
          if (_results.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                '找到 $_resultCount 个匹配书源',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.disabledColor),
              ),
            ),
          ],
          Expanded(
            child: _isLoadingToc
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('正在加载目录...'),
                      ],
                    ),
                  )
                : _results.isEmpty && !_isSearching
                    ? const SizedBox.shrink()
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final result = _results[index];
                          final sourceId = result['source_id'] as String;
                          final isCurrent = sourceId == _currentSourceId;
                          final isLoading =
                              _selectedSourceId == sourceId && _isLoadingToc;

                          return ListTile(
                            leading: Icon(
                              isCurrent
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              color: isCurrent
                                  ? context.al.success
                                  : theme.disabledColor,
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    result['source_name'] as String? ?? '未知书源',
                                    style: TextStyle(
                                      fontWeight: isCurrent
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                if (isCurrent)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: context.al.success.withAlpha(30),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text('当前',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: context.al.success)),
                                  ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (result['author'] != null &&
                                    (result['author'] as String).isNotEmpty)
                                  Text('作者: ${result['author']}',
                                      style: theme.textTheme.bodySmall),
                                Text(
                                  result['book_url'] as String? ?? '',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.disabledColor,
                                    fontSize: 10,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                            trailing: isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.chevron_right),
                            enabled: !_isLoadingToc,
                            onTap:
                                isLoading ? null : () => _selectSource(result),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
