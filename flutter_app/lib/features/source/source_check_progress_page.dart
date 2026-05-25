import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/providers.dart';
import '../../core/services/source_validation_service.dart';
import '../../core/widgets/safe_setstate.dart';

class SourceCheckProgressArgs {
  final List<Map<String, dynamic>> sources;
  final List<String> sourceIds;
  final String keyword;
  final List<String> stages;
  final int timeoutSecs;
  final int concurrency;

  const SourceCheckProgressArgs({
    required this.sources,
    required this.sourceIds,
    required this.keyword,
    required this.stages,
    required this.timeoutSecs,
    required this.concurrency,
  });

  Map<String, dynamic> get configJson => {
        'keyword': keyword,
        'stages': stages,
        'timeout_secs': timeoutSecs,
        'concurrency': concurrency,
      };
}

enum _StageUiStatus { pending, ok, fail, skipped }

class _SourceCheckRowState {
  final String id;
  final String name;
  final Map<String, _StageUiStatus> stageStatus;
  int? totalLatencyMs;
  String? error;

  _SourceCheckRowState({
    required this.id,
    required this.name,
    required Iterable<String> stages,
  }) : stageStatus = {
          for (final stage in _allStages)
            stage: stages.contains(stage)
                ? _StageUiStatus.pending
                : _StageUiStatus.skipped,
        };

  bool get completed =>
      totalLatencyMs != null ||
      error != null ||
      stageStatus.values
          .any((s) => s == _StageUiStatus.ok || s == _StageUiStatus.fail);
}

const List<String> _allStages = ['search', 'book_info', 'toc', 'content'];
const Map<String, String> _stageLabels = {
  'search': '搜索',
  'book_info': '详情',
  'toc': '目录',
  'content': '正文',
};

class SourceCheckProgressPage extends ConsumerStatefulWidget {
  final SourceCheckProgressArgs args;

  const SourceCheckProgressPage({super.key, required this.args});

  @override
  ConsumerState<SourceCheckProgressPage> createState() =>
      _SourceCheckProgressPageState();
}

class _SourceCheckProgressPageState
    extends ConsumerState<SourceCheckProgressPage> {
  late final Map<String, _SourceCheckRowState> _rowsById;
  late final List<_SourceCheckRowState> _rows;
  bool _running = true;
  String? _batchError;

  @override
  void initState() {
    super.initState();
    _rowsById = {
      for (final source in widget.args.sources)
        if (source['id'] is String && (source['id'] as String).isNotEmpty)
          source['id'] as String: _SourceCheckRowState(
            id: source['id'] as String,
            name: (source['name'] as String?) ?? '未知书源',
            stages: widget.args.stages,
          ),
    };
    _rows = _rowsById.values.toList(growable: true);
    Future.microtask(_runBatch);
  }

  Future<void> _runBatch() async {
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      if (!mounted) return;
      final service = ref.read(sourceValidationServiceProvider);
      final resultJson = await service.batchCheckSources(
        dbPath: dbPath,
        sourceIdsJson: jsonEncode(widget.args.sourceIds),
        configJson: jsonEncode(widget.args.configJson),
      );
      if (!mounted) return;
      final decoded = const JsonDecoder().convert(resultJson);
      if (decoded is! List<dynamic>) {
        throw Exception('返回格式异常: $resultJson');
      }
      safeSetState(() {
        for (final item in decoded.whereType<Map<String, dynamic>>()) {
          _mergeProgress(item);
        }
        _running = false;
      });
      ref.invalidate(allSourcesProvider);
    } catch (e) {
      if (!mounted) return;
      safeSetState(() {
        _running = false;
        _batchError = e.toString();
      });
    }
  }

  void _mergeProgress(Map<String, dynamic> progress) {
    final id = progress['source_id'] as String?;
    if (id == null || id.isEmpty) return;
    final existing = _rowsById[id];
    final row = existing ??
        _SourceCheckRowState(
          id: id,
          name: (progress['source_name'] as String?) ?? '未知书源',
          stages: widget.args.stages,
        );
    if (existing == null) {
      _rowsById[id] = row;
      _rows.add(row);
    }

    final stages = progress['stages'];
    if (stages is List<dynamic>) {
      for (final stage in stages.whereType<Map<String, dynamic>>()) {
        final key = stage['stage'] as String?;
        if (key == null || key.isEmpty) continue;
        row.stageStatus[key] =
            stage['ok'] == true ? _StageUiStatus.ok : _StageUiStatus.fail;
      }
    }
    final latency = progress['total_latency_ms'];
    if (latency is int) row.totalLatencyMs = latency;
    if (latency is num) row.totalLatencyMs = latency.toInt();
    row.error = (progress['error'] as String?)?.trim();
  }

  int get _completedCount => _rows.where((row) => row.completed).length;

  @override
  Widget build(BuildContext context) {
    final total = _rows.length;
    final completed = _completedCount;
    final hasBatchError = _batchError != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _running
              ? '校验书源 ($completed/$total)'
              : hasBatchError
                  ? '校验失败 $completed/$total'
                  : '已完成 $completed/$total',
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _running
                      ? '正在校验，完成后会自动刷新书源列表'
                      : hasBatchError
                          ? '批量校验失败'
                          : '批量校验已完成',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: _running ? null : 1,
                ),
                if (_batchError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _batchError!,
                    style: TextStyle(color: context.al.destructive),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _rows.length,
              itemBuilder: (context, index) {
                return _SourceCheckProgressTile(row: _rows[index]);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceCheckProgressTile extends StatelessWidget {
  final _SourceCheckRowState row;

  const _SourceCheckProgressTile({required this.row});

  @override
  Widget build(BuildContext context) {
    final failed = row.error?.isNotEmpty == true ||
        row.stageStatus.values.any((s) => s == _StageUiStatus.fail);
    return ListTile(
      title: Text(row.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            children: [
              for (final stage in _allStages)
                _StageChip(
                  label: _stageLabels[stage] ?? stage,
                  status: row.stageStatus[stage] ?? _StageUiStatus.skipped,
                ),
            ],
          ),
          if (row.error?.isNotEmpty == true) ...[
            const SizedBox(height: 6),
            Text(
              row.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.al.destructive),
            ),
          ],
        ],
      ),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Icon(
            failed
                ? Icons.error_outline
                : row.completed
                    ? Icons.check_circle_outline
                    : Icons.radio_button_unchecked,
            color: failed
                ? context.al.destructive
                : row.completed
                    ? context.al.success
                    : context.al.textSecondary,
          ),
          if (row.totalLatencyMs != null)
            Text(
              '${row.totalLatencyMs}ms',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}

class _StageChip extends StatelessWidget {
  final String label;
  final _StageUiStatus status;

  const _StageChip({required this.label, required this.status});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      _StageUiStatus.pending => (
          Icons.radio_button_unchecked,
          context.al.textSecondary
        ),
      _StageUiStatus.ok => (Icons.check_circle, context.al.success),
      _StageUiStatus.fail => (Icons.error, context.al.destructive),
      _StageUiStatus.skipped => (
          Icons.remove_circle_outline,
          context.al.disabled
        ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 3),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
