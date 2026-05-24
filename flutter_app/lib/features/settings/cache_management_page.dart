import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/providers.dart';
import '../../core/util/platform_int64.dart';
import '../../src/rust/api.dart' as rust_api;

/// 缓存管理页（批次 15 / 05-19）。
///
/// 数据来源：[`rust_api.listBooksWithCacheStats`]。每条记录包含
/// `{book_id, book_name, total_chapters, cached_chapters}`。
///
/// UI：
/// - AppBar(title: "缓存管理")
/// - 顶部 Card：总缓存章节数（sum of all books' cached_chapters / sum of total_chapters）
/// - "全局清空" 按钮（FilledButton.tonal，红色文字）→ AlertDialog 确认 →
///   调 [`rust_api.clearAllCache`] → invalidate [bookChaptersProvider] +
///   重拉本页 records
/// - ListView 每条 ListTile：(book_name, "已缓存 X / Y 章")，trailing
///   IconButton (delete_outline) → AlertDialog 确认 → [`rust_api.clearBookCache`]
///   → invalidate + 重拉
///
/// 入口：bookshelf_page AppBar PopupMenu 的"缓存管理"项（在批次 14 的
/// "阅读统计"项后）。
///
/// 测试钩子：所有 FRB / path_provider 调用都通过 `*Override` 注入 fake
/// 实现，让 widget test 不依赖真实平台通道（与 [ReadStatsPage] 模式一致）。
class CacheManagementPage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假 dbPath 避免 widget test 走 path_provider。
  final String? dbPathOverride;

  /// 测试钩子：注入假 BookCacheStats JSON 列表，绕过 FRB 调用。
  /// 形状：`[{"book_id":..., "book_name":..., "total_chapters":..., "cached_chapters":...}]`
  final List<Map<String, dynamic>>? recordsOverride;

  /// 测试钩子：注入假的"单本清空" FRB 调用，返回受影响行数。
  final Future<int> Function(String dbPath, String bookId)?
      clearBookCacheOverride;

  /// 测试钩子：注入假的"全局清空" FRB 调用，返回受影响行数。
  final Future<int> Function(String dbPath)? clearAllCacheOverride;

  const CacheManagementPage({
    super.key,
    this.dbPathOverride,
    this.recordsOverride,
    this.clearBookCacheOverride,
    this.clearAllCacheOverride,
  });

  @override
  ConsumerState<CacheManagementPage> createState() =>
      _CacheManagementPageState();
}

class _CacheManagementPageState extends ConsumerState<CacheManagementPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _records = const [];

  /// BATCH-20 (F-W2B-008)：缓存 sum('cached_chapters') / sum('total_chapters')
  /// 结果，避免 build 内每次 O(N) 遍历。`_records` 仅在 _load() 内变更，
  /// 每次刷新统一更新这两个字段。
  int _cachedTotal = 0;
  int _totalTotal = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 计算 cached / total 总和。`_records` 改值后调一次。
  void _recomputeTotals() {
    var cached = 0;
    var total = 0;
    for (final r in _records) {
      cached += ((r['cached_chapters'] as num?)?.toInt() ?? 0);
      total += ((r['total_chapters'] as num?)?.toInt() ?? 0);
    }
    _cachedTotal = cached;
    _totalTotal = total;
  }

  Future<void> _load() async {
    try {
      // 测试模式：override 直接用，不走 FRB / path_provider。
      if (widget.recordsOverride != null) {
        if (!mounted) return;
        setState(() {
          _records = widget.recordsOverride!;
          _recomputeTotals();
          _loading = false;
        });
        return;
      }
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final json = await rust_api.listBooksWithCacheStats(dbPath: dbPath);
      final List<dynamic> raw = jsonDecode(json);
      final records = raw.cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _records = records;
        _recomputeTotals();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _onClearAll() async {
    final cachedTotal = _cachedTotal;
    if (cachedTotal == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有缓存可清')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全局清空缓存'),
        content: Text('确定要清空所有书共 $cachedTotal 章已缓存的正文吗？\n\n章节列表会保留，'
            '只清正文内容；下次阅读时会重新拉取。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('确定清空', style: TextStyle(color: context.al.destructive)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    try {
      final clearFn = widget.clearAllCacheOverride ??
          (String dbPath) async {
            final n = await rust_api.clearAllCache(dbPath: dbPath);
            return platformInt64ToInt(n);
          };
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final affected = await clearFn(dbPath);
      // 让 reader 端 chapter providers 立即失效，避免显示已清空的旧 content
      ref.invalidate(bookChaptersProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清空 $affected 章缓存')),
      );
      // 重拉本页统计
      setState(() => _loading = true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清空失败: $e')),
      );
    }
  }

  Future<void> _onClearBook(Map<String, dynamic> record) async {
    final bookId = record['book_id'] as String? ?? '';
    final bookName = record['book_name'] as String? ?? '未知';
    final cached = (record['cached_chapters'] as num?)?.toInt() ?? 0;
    if (bookId.isEmpty) return;
    if (cached == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《$bookName》没有缓存可清')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空本书缓存'),
        content: Text('确定要清空《$bookName》共 $cached 章已缓存的正文吗？\n\n'
            '章节列表会保留，只清正文内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('确定清空', style: TextStyle(color: context.al.destructive)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    try {
      final clearFn = widget.clearBookCacheOverride ??
          (String dbPath, String id) async {
            final n = await rust_api.clearBookCache(dbPath: dbPath, bookId: id);
            return platformInt64ToInt(n);
          };
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final affected = await clearFn(dbPath, bookId);
      ref.invalidate(bookChaptersProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《$bookName》已清空 $affected 章缓存')),
      );
      setState(() => _loading = true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清空失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('缓存管理')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('加载失败: $_error'));
    }
    final cachedTotal = _cachedTotal;
    final totalTotal = _totalTotal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Card(
            elevation: 1,
            margin: const EdgeInsets.symmetric(vertical: 4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: 16, horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '缓存统计',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '总缓存: $cachedTotal 章 / $totalTotal 章',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonal(
                      onPressed: _onClearAll,
                      child: Text(
                        '全局清空',
                        style: TextStyle(color: context.al.destructive),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: _buildList(context)),
      ],
    );
  }

  Widget _buildList(BuildContext context) {
    if (_records.isEmpty) {
      return const Center(child: Text('暂无书架'));
    }
    return ListView.builder(
      itemCount: _records.length,
      itemBuilder: (context, index) {
        final r = _records[index];
        final name = r['book_name'] as String? ?? '未知书名';
        final cached = (r['cached_chapters'] as num?)?.toInt() ?? 0;
        final total = (r['total_chapters'] as num?)?.toInt() ?? 0;
        return ListTile(
          title: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            cached == 0 ? '暂无缓存' : '已缓存 $cached / $total 章',
          ),
          trailing: IconButton(
            icon: Icon(Icons.delete_outline, color: context.al.destructive),
            tooltip: '清空本书缓存',
            onPressed: () => _onClearBook(r),
          ),
        );
      },
    );
  }
}
