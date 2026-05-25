import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/providers.dart';
import '../../core/util/platform_int64.dart';
import '../../src/rust/api.dart' as rust_api;

enum _RssSourceListEntryType { header, source }

class _RssSourceListEntry {
  final _RssSourceListEntryType type;
  final String groupName;
  final int count;
  final Map<String, dynamic>? record;

  const _RssSourceListEntry.header({
    required this.groupName,
    required this.count,
  })  : type = _RssSourceListEntryType.header,
        record = null;

  const _RssSourceListEntry.source(this.record)
      : type = _RssSourceListEntryType.source,
        groupName = '',
        count = 0;
}

/// RSS 源管理页（批次 16 / 05-19）。
///
/// 数据来源：[`rust_api.rssSourceListAll`]。每条记录是 `RssSource` 的
/// JSON map，本页主要消费 `source_url / source_name / source_group /
/// enabled` 4 个字段。
///
/// UI 风格沿袭 [CacheManagementPage]：
/// - AppBar(title: "RSS 源管理")，actions = [导入 IconButton]
/// - 按 source_group 分 Section（无分组归 "未分组"）
/// - ListTile：leading Switch / title source_name / subtitle source_url /
///   trailing PopupMenuButton([删除])
/// - 空态："暂无 RSS 源，点右上角导入"
///
/// 测试钩子（与 cache_management_page 同模式）：
/// - `dbPathOverride` 注入假 dbPath，绕过 path_provider
/// - `recordsOverride` 注入假列表 JSON，绕过 FRB
/// - `setEnabledOverride` / `deleteOverride` / `importJsonOverride`
///   注入假 FRB 调用
/// - `pickFileOverride` 注入假 file_picker 选择器
class RssSourceManagePage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假 dbPath。
  final String? dbPathOverride;

  /// 测试钩子：注入假 RssSource map 列表，绕过 FRB。
  final List<Map<String, dynamic>>? recordsOverride;

  /// 测试钩子：注入假 setEnabled FRB 调用。
  final Future<int> Function(String dbPath, String url, bool enabled)?
      setEnabledOverride;

  /// 测试钩子：注入假 delete FRB 调用。
  final Future<int> Function(String dbPath, String url)? deleteOverride;

  /// 测试钩子：注入假 importJson FRB 调用，返回 JSON 形如
  /// `{"added":N,"updated":N,"skipped":N}`。
  final Future<String> Function(String dbPath, String json)? importJsonOverride;

  /// 测试钩子：注入假的"导入"文件选择器。返回选中文件绝对路径或
  /// null（用户取消）。
  final Future<String?> Function()? pickFileOverride;

  const RssSourceManagePage({
    super.key,
    this.dbPathOverride,
    this.recordsOverride,
    this.setEnabledOverride,
    this.deleteOverride,
    this.importJsonOverride,
    this.pickFileOverride,
  });

  @override
  ConsumerState<RssSourceManagePage> createState() =>
      _RssSourceManagePageState();
}

class _RssSourceManagePageState extends ConsumerState<RssSourceManagePage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _records = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (widget.recordsOverride != null) {
        if (!mounted) return;
        setState(() {
          _records = widget.recordsOverride!;
          _loading = false;
        });
        return;
      }
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final json = await rust_api.rssSourceListAll(dbPath: dbPath);
      final List<dynamic> raw = jsonDecode(json);
      final records = raw.cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _records = records;
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

  /// 按 source_group 字段分组。空 / null 全部归到"未分组"。
  /// 返回 (groupName -> List<source map>) 的有序 map：组名按字母升序，
  /// "未分组" 永远放最后。
  Map<String, List<Map<String, dynamic>>> _groupRecords() {
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final r in _records) {
      final raw = r['source_group'];
      final g = (raw is String && raw.isNotEmpty) ? raw : '';
      grouped.putIfAbsent(g, () => []).add(r);
    }
    // 排序：非空组按字母升序，"未分组"（空字符串）置最后。
    final keys = grouped.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty && b.isEmpty) return 0;
        if (a.isEmpty) return 1;
        if (b.isEmpty) return -1;
        return a.compareTo(b);
      });
    final ordered = <String, List<Map<String, dynamic>>>{};
    for (final k in keys) {
      ordered[k.isEmpty ? '未分组' : k] = grouped[k]!;
    }
    return ordered;
  }

  Future<void> _onImport() async {
    try {
      final pickFn = widget.pickFileOverride ??
          () async {
            final result = await FilePicker.pickFiles(
              type: FileType.custom,
              allowedExtensions: ['json'],
            );
            if (result == null || result.files.isEmpty) return null;
            return result.files.single.path;
          };
      final pickedPath = await pickFn();
      if (pickedPath == null || pickedPath.isEmpty) return;
      if (!mounted) return;
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      // 文件读取
      final json = await File(pickedPath).readAsString();
      final importFn = widget.importJsonOverride ??
          (String db, String j) =>
              rust_api.rssSourceImportJson(dbPath: db, json: j);
      final summaryJson = await importFn(dbPath, json);
      final Map<String, dynamic> summary =
          jsonDecode(summaryJson) as Map<String, dynamic>;
      final added = (summary['added'] as num?)?.toInt() ?? 0;
      final updated = (summary['updated'] as num?)?.toInt() ?? 0;
      final skipped = (summary['skipped'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('导入完成：新增 $added，更新 $updated，跳过 $skipped'),
        ),
      );
      setState(() => _loading = true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }

  Future<void> _onToggleEnabled(
      Map<String, dynamic> record, bool newValue) async {
    final url = record['source_url'] as String? ?? '';
    if (url.isEmpty) return;
    try {
      final fn = widget.setEnabledOverride ??
          (String db, String u, bool e) async {
            final n = await rust_api.rssSourceSetEnabled(
                dbPath: db, url: u, enabled: e);
            return platformInt64ToInt(n);
          };
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      await fn(dbPath, url, newValue);
      // BATCH-21 (F-W2B-014): immutable update —— `List.of(_records)` 复制
      // 顶层 list，`{...record, 'enabled': newValue}` 复制目标 record map，
      // 旧 _records / 旧 record 引用不变。这避免原地 `record['enabled'] =
      // newValue` 在多处 caller 持引用时的 mutation aliasing。
      if (!mounted) return;
      final idx = _records.indexOf(record);
      if (idx < 0) return; // record 已不在列表（被 import/delete 替换）
      setState(() {
        _records = List.of(_records)..[idx] = {...record, 'enabled': newValue};
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新失败: $e')),
      );
    }
  }

  Future<void> _onDelete(Map<String, dynamic> record) async {
    final url = record['source_url'] as String? ?? '';
    final name = record['source_name'] as String? ?? '未知';
    if (url.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 RSS 源'),
        content: Text('确定要删除《$name》吗？\n\n该操作不会删除已收藏的文章，仅从源列表移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                Text('确定删除', style: TextStyle(color: context.al.destructive)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    try {
      final fn = widget.deleteOverride ??
          (String db, String u) async {
            final n = await rust_api.rssSourceDelete(dbPath: db, url: u);
            return platformInt64ToInt(n);
          };
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final affected = await fn(dbPath, url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(affected > 0 ? '已删除《$name》' : '未找到 RSS 源'),
        ),
      );
      setState(() => _loading = true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RSS 源管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload),
            tooltip: '导入',
            onPressed: _onImport,
          ),
          // 批次 20 (05-19): QR 扫码导入。补充入口，原导入按钮保留。
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: '扫码导入',
            onPressed: () => context.push('/qr-scan'),
          ),
        ],
      ),
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
    if (_records.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.rss_feed,
                size: 56, color: Theme.of(context).disabledColor),
            const SizedBox(height: 12),
            const Text('暂无 RSS 源'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _onImport,
              icon: const Icon(Icons.file_upload),
              label: const Text('导入 RSS 源'),
            ),
          ],
        ),
      );
    }
    return _buildList(context);
  }

  Widget _buildList(BuildContext context) {
    final entries = _buildListEntries();
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.type == _RssSourceListEntryType.header) {
          return _buildSectionHeader(context, entry.groupName, entry.count);
        }
        return RepaintBoundary(
          child: _buildSourceTile(context, entry.record!),
        );
      },
    );
  }

  List<_RssSourceListEntry> _buildListEntries() {
    final grouped = _groupRecords();
    final entries = <_RssSourceListEntry>[];
    for (final entry in grouped.entries) {
      entries.add(_RssSourceListEntry.header(
        groupName: entry.key,
        count: entry.value.length,
      ));
      for (final record in entry.value) {
        entries.add(_RssSourceListEntry.source(record));
      }
    }
    return entries;
  }

  Widget _buildSectionHeader(BuildContext context, String name, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        '$name ($count)',
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
      ),
    );
  }

  Widget _buildSourceTile(BuildContext context, Map<String, dynamic> record) {
    final name = record['source_name'] as String? ?? '未知';
    final url = record['source_url'] as String? ?? '';
    final enabled = record['enabled'] as bool? ?? false;
    return ListTile(
      // 批次 17 (05-19): 整个 ListTile 可点击 → 进入文章列表页。
      // Switch 仍由 onChanged 处理（widget 子树的手势优先于 ListTile.onTap）。
      onTap: url.isEmpty
          ? null
          : () {
              final encoded = Uri.encodeQueryComponent(url);
              context.push('/rss-articles?sourceUrl=$encoded');
            },
      leading: Switch(
        value: enabled,
        onChanged: (v) => _onToggleEnabled(record, v),
      ),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '操作',
        onSelected: (value) {
          if (value == 'delete') {
            _onDelete(record);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading:
                  Icon(Icons.delete_outline, color: context.al.destructive),
              title:
                  Text('删除', style: TextStyle(color: context.al.destructive)),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}
