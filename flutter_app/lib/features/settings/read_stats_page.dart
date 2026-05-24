import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/util/platform_int64.dart';
import '../../core/util/time_format.dart';
import '../../src/rust/api.dart' as rust_api;

/// 阅读统计页（批次 14 / 05-19）。
///
/// 数据来源：[`rust_api.listReadRecords`] + [`rust_api.getTotalReadTime`]。
/// UI：
/// - AppBar(title: "阅读统计")
/// - 顶部 Card：累计总阅读时长（小时 / 分）
/// - ListView：每本书一行 (book_name, read_time 格式化, last_read_at 相对时间)
///
/// 入口：bookshelf_page AppBar PopupMenu "阅读统计"。
///
/// 测试钩子：所有 FRB 桥 / path_provider 调用都通过 `*Override` 注入
/// fake 实现，让 widget test 不依赖真实平台通道。
class ReadStatsPage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假 dbPath 避免 widget test 走 path_provider。
  final String? dbPathOverride;

  /// 测试钩子：注入假 ReadRecord JSON 列表，绕过 FRB 调用。
  /// 形状：`[{"id":..., "book_id":..., "book_name":..., "read_time":..., "last_read_at":...}]`
  final List<Map<String, dynamic>>? recordsOverride;

  /// 测试钩子：注入假总阅读时长（秒）。
  final int? totalOverride;

  const ReadStatsPage({
    super.key,
    this.dbPathOverride,
    this.recordsOverride,
    this.totalOverride,
  });

  @override
  ConsumerState<ReadStatsPage> createState() => _ReadStatsPageState();
}

class _ReadStatsPageState extends ConsumerState<ReadStatsPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _records = const [];
  int _totalSeconds = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // 测试模式：override 直接用，不走 FRB。
      if (widget.recordsOverride != null && widget.totalOverride != null) {
        if (!mounted) return;
        setState(() {
          _records = widget.recordsOverride!;
          _totalSeconds = widget.totalOverride!;
          _loading = false;
        });
        return;
      }
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final json = await rust_api.listReadRecords(dbPath: dbPath);
      final List<dynamic> raw = jsonDecode(json);
      final records = raw.cast<Map<String, dynamic>>();
      final total = await rust_api.getTotalReadTime(dbPath: dbPath);
      final int totalSec = platformInt64ToInt(total);
      if (!mounted) return;
      setState(() {
        _records = records;
        _totalSeconds = totalSec;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('阅读统计')),
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
                  vertical: 18, horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '累计阅读时长',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    formatReadDuration(_totalSeconds),
                    style: Theme.of(context).textTheme.headlineSmall,
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
      return const Center(child: Text('暂无阅读记录'));
    }
    return ListView.builder(
      itemCount: _records.length,
      itemBuilder: (context, index) {
        final r = _records[index];
        final name = r['book_name'] as String? ?? '未知书名';
        final readTime =
            (r['read_time'] as num?)?.toInt() ?? 0;
        final lastReadAt =
            (r['last_read_at'] as num?)?.toInt() ?? 0;
        return ListTile(
          title: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${formatReadDuration(readTime)} · 上次读 ${formatRelativeTime(lastReadAt)}',
          ),
        );
      },
    );
  }
}

/// 把秒数格式化成 "X 小时 Y 分" 或 "Y 分"。
/// 公开供单测断言。3725 秒 → "1 小时 2 分"。
@visibleForTesting
String formatReadDuration(int sec) {
  if (sec <= 0) return '0 分';
  final h = sec ~/ 3600;
  final m = (sec % 3600) ~/ 60;
  if (h > 0) return '$h 小时 $m 分';
  return '$m 分';
}
