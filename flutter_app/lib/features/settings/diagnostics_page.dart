import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/diagnostics/diagnostic_log.dart';
import '../../core/diagnostics/diagnostic_log_reader.dart';
import '../../core/providers.dart';
import '../../core/widgets/safe_setstate.dart';

class DiagnosticsPage extends ConsumerStatefulWidget {
  /// Optional [DiagnosticLogReader] for testing.
  /// When `null`, uses [DiagnosticLog.reader].
  final DiagnosticLogReader? readerForTest;

  const DiagnosticsPage({super.key, this.readerForTest});

  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();

  static Color levelColor(String? level) {
    switch (level) {
      case 'error':
        return Colors.red;
      case 'warn':
        return Colors.orange;
      case 'info':
        return Colors.blue;
      case 'debug':
      default:
        return Colors.grey;
    }
  }
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  bool _diagnosticsEnabled = true;
  DiagnosticLogStats? _stats;
  List<Map<String, dynamic>> _recentLines = [];
  bool _loading = true;
  String? _error;
  bool _exporting = false;

  DiagnosticLogReader? get _reader =>
      widget.readerForTest ?? DiagnosticLog.reader();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final reader = _reader;
    if (reader == null) {
      safeSetState(() {
        _loading = false;
        _stats = const DiagnosticLogStats(
            fileCount: 0, totalBytes: 0, newestModified: null);
      });
      return;
    }

    try {
      // When a test reader is injected, skip the disk-based load and
      // use default values (no real file I/O needed).
      final isTest = widget.readerForTest != null;
      final enabled = isTest
          ? true
          : await loadDiagnosticLoggingEnabledFromDisk();

      final stats = await reader.stats();
      final lines = await reader.tail(maxLines: 500);

      final parsed = <Map<String, dynamic>>[];
      for (final line in lines) {
        try {
          parsed.add(jsonDecode(line) as Map<String, dynamic>);
        } catch (_) {
          // Skip malformed lines.
        }
      }

      safeSetState(() {
        _diagnosticsEnabled = enabled;
        _stats = stats;
        _recentLines = parsed;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      safeSetState(() {
        _error = '加载日志失败: $e';
        _loading = false;
      });
    }
  }

  Future<void> _toggleEnabled(bool value) async {
    DiagnosticLog.setEnabled(value);
    await saveDiagnosticLoggingEnabledToDisk(value);
    safeSetState(() => _diagnosticsEnabled = value);
  }

  Future<void> _export() async {
    final reader = _reader;
    if (reader == null) return;

    safeSetState(() => _exporting = true);
    try {
      final tmpDir = await getTemporaryDirectory();
      final timestamp = _formatTimestamp(DateTime.now());
      final outputPath = '${tmpDir.path}/legado_diagnostics_$timestamp.jsonl';
      await reader.exportMerged(outputPath: outputPath);

      final file = File(outputPath);
      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('导出失败：文件未生成')),
          );
        }
        return;
      }

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(outputPath)],
          subject: 'Legado 诊断日志',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    } finally {
      safeSetState(() => _exporting = false);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确定要清空所有诊断日志吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final reader = _reader;
    if (reader == null) return;

    try {
      await reader.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('日志已清空')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清空失败: $e')),
      );
    }

    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断日志'),
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return ListView(
        children: [
          _buildControls(),
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(
                _error ?? '',
                style: TextStyle(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      );
    }

    final stats = _stats;
    final isEmpty = stats == null || stats.fileCount == 0;

    return ListView(
      children: [
        _buildControls(),
        if (!isEmpty) _buildStatsCard(stats, theme),
        if (!isEmpty) _buildLogList(theme),
        if (isEmpty) _buildEmptyState(theme),
      ],
    );
  }

  Widget _buildControls() {
    return Column(
      children: [
        SwitchListTile(
          title: const Text('启用诊断日志'),
          subtitle: const Text('关闭后不再写入新事件，已有日志仍可查看/导出/清空'),
          value: _diagnosticsEnabled,
          onChanged: _toggleEnabled,
        ),
        const Divider(indent: 16, endIndent: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: (_exporting || _loading) ? null : _export,
                icon: _exporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.ios_share),
                label: const Text('导出'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: (_loading || _exporting) ? null : _clear,
                icon: const Icon(Icons.delete_outline),
                label: const Text('清空'),
              ),
            ],
          ),
        ),
        const Divider(indent: 16, endIndent: 16),
      ],
    );
  }

  Widget _buildStatsCard(DiagnosticLogStats? stats, ThemeData theme) {
    if (stats == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('日志信息',
                  style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary)),
              const SizedBox(height: 12),
              _statsRow('文件数量', '${stats.fileCount}'),
              const SizedBox(height: 4),
              _statsRow('总大小', _formatSize(stats.totalBytes)),
              if (stats.newestModified != null) ...[
                const SizedBox(height: 4),
                _statsRow(
                    '最新记录', _formatDateTimeLocal(stats.newestModified!)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statsRow(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(label,
              style: const TextStyle(color: Colors.grey, fontSize: 13)),
        ),
        Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13))),
      ],
    );
  }

  Widget _buildLogList(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '最近记录 (${_recentLines.length})',
            style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary),
          ),
        ),
        ..._recentLines.map((event) => _LogTile(event: event)),
      ],
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 32),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.note_alt_outlined,
                size: 64, color: theme.colorScheme.onSurface.withAlpha(100)),
            const SizedBox(height: 16),
            Text(
              '暂无诊断日志',
              style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface.withAlpha(150)),
            ),
            const SizedBox(height: 8),
            Text(
              '应用运行时的事件将记录在此',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withAlpha(100)),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDateTimeLocal(DateTime utc) {
    final local = utc.toLocal();
    return '${local.year}-${_pad2(local.month)}-${_pad2(local.day)} '
        '${_pad2(local.hour)}:${_pad2(local.minute)}:${_pad2(local.second)}';
  }

  static String _formatTimestamp(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}${_pad2(local.month)}${_pad2(local.day)}'
        '-${_pad2(local.hour)}${_pad2(local.minute)}${_pad2(local.second)}';
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _LogTile extends StatefulWidget {
  final Map<String, dynamic> event;

  const _LogTile({required this.event});

  @override
  State<_LogTile> createState() => _LogTileState();
}

class _LogTileState extends State<_LogTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final theme = Theme.of(context);
    final level = event['level'] as String? ?? 'debug';
    final category = event['category'] as String? ?? '';
    final message = event['message'] as String? ?? '';
    final ts = event['ts'] as String? ?? '';
    final error = event['error'] as String?;
    final stack = event['stack'] as String?;
    final metadata = event['metadata'] as Map<String, dynamic>?;
    final hasDetail = error != null ||
        stack != null ||
        (metadata != null && metadata.isNotEmpty);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: InkWell(
        onTap: hasDetail ? () => safeSetState(() => _expanded = !_expanded) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: DiagnosticsPage.levelColor(level)
                          .withAlpha(30),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      level.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: DiagnosticsPage.levelColor(level),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatTsCompact(ts),
                    style: TextStyle(
                        fontSize: 11,
                        color:
                            theme.colorScheme.onSurface.withAlpha(150)),
                  ),
                  const Spacer(),
                  if (hasDetail)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color:
                          theme.colorScheme.onSurface.withAlpha(120),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              if (category.isNotEmpty)
                Text(
                  category,
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          theme.colorScheme.onSurface.withAlpha(180),
                      fontWeight: FontWeight.w500),
                ),
              Text(
                message,
                style: const TextStyle(fontSize: 13),
                maxLines: _expanded ? null : 2,
                overflow: _expanded ? null : TextOverflow.ellipsis,
              ),
              if (_expanded && hasDetail) ...[
                const Divider(height: 16),
                if (error != null) ...[
                  Text('错误:', style: _detailLabelStyle(theme)),
                  const SizedBox(height: 2),
                  Text(error,
                      style: _detailValueStyle(theme, Colors.red)),
                  const SizedBox(height: 8),
                ],
                if (stack != null) ...[
                  Text('堆栈:', style: _detailLabelStyle(theme)),
                  const SizedBox(height: 2),
                  Text(
                    stack,
                    style: _detailValueStyle(theme, null),
                    maxLines: 20,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                ],
                if (metadata != null && metadata.isNotEmpty) ...[
                  Text('元数据:', style: _detailLabelStyle(theme)),
                  const SizedBox(height: 2),
                  ...metadata.entries.map((e) => Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          '${e.key}: ${e.value}',
                          style: _detailValueStyle(theme, null),
                        ),
                      )),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatTsCompact(String ts) {
    try {
      final dt = DateTime.parse(ts).toLocal();
      return '${_pd2(dt.hour)}:${_pd2(dt.minute)}:${_pd2(dt.second)}';
    } catch (_) {
      return ts;
    }
  }

  String _pd2(int n) => n.toString().padLeft(2, '0');

  TextStyle _detailLabelStyle(ThemeData theme) {
    return TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: theme.colorScheme.onSurface.withAlpha(180),
    );
  }

  TextStyle _detailValueStyle(ThemeData theme, Color? color) {
    return TextStyle(
      fontSize: 12,
      fontFamily: 'monospace',
      color: color ?? theme.colorScheme.onSurface.withAlpha(200),
    );
  }
}
