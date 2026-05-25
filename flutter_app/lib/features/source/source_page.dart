import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/diagnostics/diagnostic_log.dart';
import '../../core/providers.dart';
import '../../core/services/source_validation_service.dart';
import '../../core/widgets/safe_setstate.dart';
import '../../src/rust/api.dart' as rust_api;
import 'source_check_progress_page.dart';

enum _SourceSortMode { defaults, respondTimeAsc, lastCheckAtDesc }

extension _SourceSortModeX on _SourceSortMode {
  String get label {
    switch (this) {
      case _SourceSortMode.defaults:
        return '默认排序';
      case _SourceSortMode.respondTimeAsc:
        return '按延迟升序';
      case _SourceSortMode.lastCheckAtDesc:
        return '按最后校验时间降序';
    }
  }
}

/// `@visibleForTesting` — 让 widget test 能直接弹出 [`_LiveTestDialog`] 而不必
/// 走完整 SourcePage → 列表 tap → 校验规则的链路（避免连 FRB 真实调用）。
/// 仅在 source_validation_live_test_test.dart 用。
///
/// BATCH-20 (F-W2B-020)：原 module-level `LiveTestRunner` typedef +
/// `debugLiveTestRunnerOverride` global mutable 删除；测试通过
/// `ProviderScope.overrides` 注入 fake [SourceValidationService]，
/// 不再依赖全局 mutable state。
@visibleForTesting
Future<void> showLiveTestDialogForTesting(
  BuildContext context, {
  required String dbPath,
  required String sourceId,
  required String sourceName,
}) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _LiveTestDialog(
      dbPath: dbPath,
      sourceId: sourceId,
      sourceName: sourceName,
    ),
  );
}

class SourcePage extends ConsumerStatefulWidget {
  const SourcePage({super.key});

  @override
  ConsumerState<SourcePage> createState() => _SourcePageState();
}

class _SourcePageState extends ConsumerState<SourcePage> {
  bool _selectMode = false;
  final Set<String> _selectedIds = {};
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  _SourceSortMode _sortMode = _SourceSortMode.defaults;
  bool _failuresOnly = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sourcesAsync = ref.watch(allSourcesProvider);

    return Scaffold(
      appBar: _selectMode ? _buildSelectAppBar() : _buildNormalAppBar(),
      body: sourcesAsync.when(
        data: (sources) => _buildSourceList(context, sources),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
      bottomNavigationBar:
          _selectMode ? _buildBottomActionBar(context) : null,
      floatingActionButton: _selectMode
          ? null
          : FloatingActionButton(
              onPressed: () => _showAddSourceDialog(context),
              child: const Icon(Icons.add),
            ),
    );
  }

  AppBar _buildNormalAppBar() {
    final cs = Theme.of(context).colorScheme;
    return AppBar(
      titleSpacing: 0,
      title: Container(
        height: 44,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(28),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(Icons.search, size: 20, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                style: TextStyle(fontSize: 15, color: cs.onSurface),
                decoration: InputDecoration(
                  hintText: '搜索书源',
                  hintStyle: TextStyle(
                    fontSize: 15,
                    color: cs.onSurfaceVariant.withAlpha(0x99),
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: (v) => safeSetState(() => _searchQuery = v),
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.sort_by_alpha),
          tooltip: '排序',
          onPressed: () => _showSortMenu(context),
        ),
        IconButton(
          icon: Icon(
            _failuresOnly ? Icons.filter_alt : Icons.filter_list,
          ),
          tooltip: _failuresOnly ? '仅看失败' : '筛选',
          onPressed: () => _showFilterMenu(context),
        ),
        IconButton(
          icon: const Icon(Icons.file_upload_outlined),
          tooltip: '导入',
          onPressed: () => _showImportDialog(context),
        ),
        IconButton(
          icon: const Icon(Icons.more_vert),
          tooltip: '更多',
          onPressed: () => _showMoreMenu(context),
        ),
      ],
    );
  }

  AppBar _buildSelectAppBar() {
    return AppBar(
      title: Text('已选 ${_selectedIds.length} 项'),
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _exitSelectMode,
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.select_all),
          tooltip: '全选',
          onPressed: _selectAll,
        ),
        IconButton(
          icon: const Icon(Icons.deselect),
          tooltip: '取消全选',
          onPressed: () => setState(() => _selectedIds.clear()),
        ),
      ],
    );
  }

  Widget _buildBottomActionBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = ref.read(allSourcesProvider).valueOrNull?.length ?? 0;
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        border: Border(top: BorderSide(color: cs.outlineVariant.withAlpha(0x40))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              if (_selectedIds.length == total) {
                _selectedIds.clear();
              } else {
                _selectAll();
              }
              setState(() {});
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _selectedIds.length == total && total > 0
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  size: 20,
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '全选 (${_selectedIds.length}/$total)',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () {
                    final sources =
                        ref.read(allSourcesProvider).valueOrNull ?? [];
                    for (final s in sources) {
                      final id = s['id'];
                      if (id is String && id.isNotEmpty) {
                        if (_selectedIds.contains(id)) {
                          _selectedIds.remove(id);
                        } else {
                          _selectedIds.add(id);
                        }
                      }
                    }
                    setState(() {});
                  },
                  child: const Text('反选', style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () => _deleteSelected(context),
                  child: Text('删除',
                      style: TextStyle(
                        fontSize: 13,
                        color: _selectedIds.isEmpty
                            ? cs.onSurfaceVariant.withAlpha(0x60)
                            : cs.onSurfaceVariant,
                      )),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.more_vert, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () => _showBatchSelectionMenu(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showSortMenu(BuildContext context) {
    showMenu<_SourceSortMode>(
      context: context,
      position: const RelativeRect.fromLTRB(1000, 100, 0, 0),
      items: [
        for (final mode in _SourceSortMode.values)
          PopupMenuItem(
            value: mode,
            child: Row(
              children: [
                Icon(
                  _sortMode == mode ? Icons.check : Icons.sort,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Text(mode.label),
              ],
            ),
          ),
      ],
    ).then((mode) {
      if (mode == null || mode == _sortMode) return;
      safeSetState(() => _sortMode = mode);
    });
  }

  void _showFilterMenu(BuildContext context) {
    showMenu<bool>(
      context: context,
      position: const RelativeRect.fromLTRB(1000, 100, 0, 0),
      items: [
        PopupMenuItem(
          value: false,
          child: Row(
            children: [
              Icon(!_failuresOnly ? Icons.check : Icons.list, size: 20),
              const SizedBox(width: 12),
              const Text('全部'),
            ],
          ),
        ),
        PopupMenuItem(
          value: true,
          child: Row(
            children: [
              Icon(_failuresOnly ? Icons.check : Icons.error_outline, size: 20),
              const SizedBox(width: 12),
              const Text('仅看失败'),
            ],
          ),
        ),
      ],
    ).then((failuresOnly) {
      if (failuresOnly == null || failuresOnly == _failuresOnly) return;
      safeSetState(() => _failuresOnly = failuresOnly);
    });
  }

  void _showBatchSelectionMenu(BuildContext context) {
    showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(1000, 1000, 0, 0),
      items: const [
        PopupMenuItem(
          value: 'batch_check',
          child: Row(
            children: [
              Icon(Icons.fact_check_outlined, size: 20),
              SizedBox(width: 12),
              Text('批量校验'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value != 'batch_check' || !mounted) return;
      _showBatchCheckConfigDialog(context);
    });
  }

  Future<void> _showBatchCheckConfigDialog(BuildContext context) async {
    final sources = ref.read(allSourcesProvider).valueOrNull ?? [];
    final selectedSources = sources
        .where((s) => _selectedIds.contains(s['id']))
        .map((s) => Map<String, dynamic>.from(s))
        .toList();
    if (selectedSources.isEmpty) return;

    final args = await showDialog<SourceCheckProgressArgs>(
      context: context,
      builder: (ctx) => _BatchCheckConfigDialog(sources: selectedSources),
    );
    if (args == null) return;
    if (!mounted) return;
    await context.push('/source-check-progress', extra: args);
    if (!mounted) return;
    ref.invalidate(allSourcesProvider);
  }

  void _showMoreMenu(BuildContext context) {
    showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(1000, 100, 0, 0),
      items: [
        PopupMenuItem(
          value: 'export',
          onTap: () => _showExportDialog(context),
          child: const Row(
            children: [
              Icon(Icons.file_upload_outlined, size: 20),
              SizedBox(width: 12),
              Text('导出书源 JSON', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'import_file',
          onTap: () => _importFromFile(context),
          child: const Row(
            children: [
              Icon(Icons.folder_open, size: 20),
              SizedBox(width: 12),
              Text('从文件导入', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'import_paste',
          onTap: () => _showImportDialog(context),
          child: const Row(
            children: [
              Icon(Icons.content_paste, size: 20),
              SizedBox(width: 12),
              Text('粘贴 JSON 导入', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSourceList(BuildContext context, List<Map<String, dynamic>> sources) {
    final filtered = (_searchQuery.isEmpty
            ? sources
            : sources.where((s) {
                final name = (s['name'] as String?)?.toLowerCase() ?? '';
                return name.contains(_searchQuery.toLowerCase());
              }).toList())
        .where((s) => !_failuresOnly || _sourceError(s).isNotEmpty)
        .toList();
    _sortSources(filtered);

    if (filtered.isEmpty) {
      return const Center(child: Text('暂无书源，点击右下角添加'));
    }
    return ListView.builder(
      padding: EdgeInsets.only(
        left: 0, right: 0,
        bottom: _selectMode ? 0 : 80,
      ),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final source = filtered[index];
        final id = source['id'] is String ? source['id'] as String : '';
        final validId = id.isNotEmpty;
        final enabled = source['enabled'] == true;
        final respondTime = _sourceInt(source, 'respond_time');
        final lastError = _sourceError(source);
        final cs = Theme.of(context).colorScheme;

        Widget leading;
        if (_selectMode) {
          leading = Checkbox(
            value: validId && _selectedIds.contains(id),
            onChanged: validId ? (_) => _toggleSelect(id) : null,
          );
        } else {
          leading = const SizedBox(width: 24);
        }

        return InkWell(
          onTap: validId
              ? (_selectMode
                  ? () => _toggleSelect(id)
                  : () => _showSourceActions(context, source))
              : null,
          onLongPress:
              _selectMode || !validId ? null : () => _enterSelectMode(id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              source['name'] as String? ?? '未知书源',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        source['url'] as String? ?? '',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!_selectMode) ...[
                  if (respondTime > 0) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${respondTime}ms',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (lastError.isNotEmpty) ...[
                    Tooltip(
                      message: lastError,
                      child: Icon(
                        Icons.error_outline,
                        color: context.al.destructive,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Switch(
                    value: enabled,
                    onChanged:
                        validId ? (val) => _toggleSource(id, val) : null,
                  ),
                  const SizedBox(width: 4),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: enabled
                          ? const Color(0xFF00C853)
                          : cs.outlineVariant,
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(Icons.open_in_new,
                        size: 20, color: cs.onSurfaceVariant),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () =>
                        _showSourceActions(context, source),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(Icons.more_vert,
                        size: 20, color: cs.onSurfaceVariant),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () =>
                        _showSourceActions(context, source),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  int _sourceInt(Map<String, dynamic> source, String key) {
    final value = source[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  String _sourceError(Map<String, dynamic> source) {
    return (source['last_check_error'] as String?)?.trim() ?? '';
  }

  void _sortSources(List<Map<String, dynamic>> sources) {
    switch (_sortMode) {
      case _SourceSortMode.defaults:
        return;
      case _SourceSortMode.respondTimeAsc:
        sources.sort((a, b) {
          final av = _sourceInt(a, 'respond_time');
          final bv = _sourceInt(b, 'respond_time');
          if (av == 0 && bv == 0) return 0;
          if (av == 0) return 1;
          if (bv == 0) return -1;
          return av.compareTo(bv);
        });
        return;
      case _SourceSortMode.lastCheckAtDesc:
        sources.sort(
          (a, b) => _sourceInt(b, 'last_check_at')
              .compareTo(_sourceInt(a, 'last_check_at')),
        );
        return;
    }
  }

  Future<void> _toggleSource(String id, bool enabled) async {
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      await rust_api.setSourceEnabled(dbPath: dbPath, id: id, enabled: enabled);
      ref.invalidate(allSourcesProvider);
      DiagnosticLog.info('source.edit', 'Source ${enabled ? "enabled" : "disabled"}',
          metadata: {'source_id': id});
    } catch (e) {
      DiagnosticLog.warn('source.edit', 'Failed to toggle source',
          error: e, metadata: {'source_id': id});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e')),
        );
      }
    }
  }

  void _showAddSourceDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加书源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '书源名称')),
            TextField(controller: urlCtrl, decoration: const InputDecoration(labelText: '书源 URL')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              try {
                await ref.read(dbInitializedProvider.future);
                final dbPath = await ref.read(dbPathProvider.future);
                await rust_api.createSource(dbPath: dbPath, name: name, url: url);
                ref.invalidate(allSourcesProvider);
                DiagnosticLog.info('source.add', 'Source added', metadata: {'source_name': name});
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                DiagnosticLog.warn('source.add', 'Failed to add source',
                    error: e, metadata: {'source_name': name});
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('添加失败: $e')),
                  );
                }
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _showImportDialog(BuildContext context) {
    final jsonCtrl = TextEditingController();
    bool importing = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('导入书源 JSON'),
          content: SizedBox(
            width: double.maxFinite,
            child: TextField(
              controller: jsonCtrl,
              maxLines: 8,
              enabled: !importing,
              decoration: const InputDecoration(
                hintText: '粘贴书源 JSON 数组 [...]',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: importing ? null : () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: importing
                  ? null
                  : () async {
                      final json = jsonCtrl.text.trim();
                      if (json.isEmpty) return;
                      setDialogState(() => importing = true);
                      try {
                        await ref.read(dbInitializedProvider.future);
                        final dbPath = await ref.read(dbPathProvider.future);
                        final count = await rust_api.importSourcesFromJson(
                          dbPath: dbPath,
                          json: json,
                        );
                        ref.invalidate(allSourcesProvider);
                        DiagnosticLog.info('source.import', 'Imported sources from JSON',
                            metadata: {'count': count});
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('成功导入 $count 个书源')),
                          );
                        }
                      } catch (e) {
                        DiagnosticLog.warn('source.import', 'Import from JSON failed',
                            error: e);
                        if (ctx.mounted) {
                          setDialogState(() => importing = false);
                        }
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text('导入失败: $e')),
                          );
                        }
                      }
                    },
              child: importing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('导入'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSourceActions(BuildContext context, Map<String, dynamic> source) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(source['name'] ?? '书源操作'),
        content: Text(source['url'] ?? ''),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _showValidateDialog(context, source);
            },
            icon: const Icon(Icons.checklist, size: 18),
            label: const Text('校验规则'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              final sid = source['id'];
              if (sid is String && sid.isNotEmpty) _deleteSource(sid);
            },
            child: Text('删除', style: TextStyle(color: context.al.destructive)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _showValidateDialog(BuildContext context, Map<String, dynamic> source) async {
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      final sourceId = source['id'] ?? '';
      final sourceName = source['name'] ?? '书源';
      final resultJson = await rust_api.validateSourceFromDb(
        dbPath: dbPath,
        sourceId: sourceId,
      );
      final List<dynamic> issues = const JsonDecoder().convert(resultJson);
      final errorCount = issues.where((i) => (i as Map)['severity'] == 'error').length;
      final warnCount = issues.where((i) => (i as Map)['severity'] == 'warning').length;
      DiagnosticLog.info('source.validate', 'Validated source',
          metadata: {'source_id': sourceId, 'source_name': sourceName, 'errors': errorCount, 'warnings': warnCount});
      if (!mounted) return;
      // 批次 21 (05-19): 即使静态校验通过 (issues 空)，仍弹 dialog 让用户能进入"实跑测试"。
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${source['name'] ?? '书源'} 校验结果'),
          content: SizedBox(
            width: double.maxFinite,
            child: issues.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      '书源规则校验通过，未发现问题。\n如需进一步验证可用「实跑测试」。',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: issues.length,
                    itemBuilder: (_, i) {
                      final issue = issues[i] as Map<String, dynamic>;
                      final severity = (issue['severity'] as String?) ?? '';
                      final Color color = severity == 'error'
                          ? context.al.destructive
                          : severity == 'warning'
                              ? context.al.warning
                              : Theme.of(context).colorScheme.primary;
                      final IconData icon = severity == 'error'
                          ? Icons.error
                          : severity == 'warning'
                              ? Icons.warning
                              : Icons.info;
                      return ListTile(
                        leading: Icon(icon, color: color, size: 20),
                        title: Text((issue['field'] as String?) ?? '',
                            style: TextStyle(
                                fontSize: 12, color: context.al.onSurface)),
                        subtitle: Text((issue['message'] as String?) ?? '',
                            style: const TextStyle(fontSize: 13)),
                        dense: true,
                      );
                    },
                  ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _showLiveTestDialog(context, source);
              },
              icon: const Icon(Icons.play_circle_outline, size: 18),
              label: const Text('实跑测试'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('校验失败: $e')),
        );
      }
    }
  }

  Future<void> _showLiveTestDialog(
      BuildContext context, Map<String, dynamic> source) async {
    final id = source['id'];
    if (id is! String || id.isEmpty) return;
    String? dbPath;
    try {
      await ref.read(dbInitializedProvider.future);
      dbPath = await ref.read(dbPathProvider.future);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('数据库未就绪: $e')),
        );
      }
      return;
    }
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _LiveTestDialog(
        dbPath: dbPath!,
        sourceId: id,
        sourceName: (source['name'] as String?) ?? '书源',
      ),
    );
  }

  Future<void> _deleteSource(String id) async {
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      await rust_api.deleteSource(dbPath: dbPath, id: id);
      ref.invalidate(allSourcesProvider);
      DiagnosticLog.info('source.delete', 'Source deleted', metadata: {'source_id': id});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('书源已删除')),
        );
      }
    } catch (e) {
      DiagnosticLog.warn('source.delete', 'Failed to delete source',
          error: e, metadata: {'source_id': id});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  Future<void> _showExportDialog(BuildContext context) async {
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      final json = await rust_api.exportAllSources(dbPath: dbPath);
      await Clipboard.setData(ClipboardData(text: json));
      DiagnosticLog.info('source.export', 'Exported all sources');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已复制所有书源 JSON 到剪贴板')),
        );
      }
    } catch (e) {
      DiagnosticLog.warn('source.export', 'Export failed', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    }
  }

  Future<void> _importFromFile(BuildContext context) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;

      final single = result.files.single;
      final json = single.path != null
          ? await File(single.path!).readAsString()
          : single.bytes != null
              ? utf8.decode(single.bytes!)
              : '';
      if (json.trim().isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('文件内容为空')),
          );
        }
        return;
      }

      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      final count = await rust_api.importSourcesFromJson(
        dbPath: dbPath,
        json: json,
      );
      ref.invalidate(allSourcesProvider);
      DiagnosticLog.info('source.import', 'Imported sources from file',
          metadata: {'count': count});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('成功导入 $count 个书源')),
        );
      }
    } catch (e) {
      DiagnosticLog.warn('source.import', 'File import failed', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文件导入失败: $e')),
        );
      }
    }
  }

  void _enterSelectMode(String id) {
    setState(() {
      _selectMode = true;
      _selectedIds.add(id);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _selectAll() {
    final sources = ref.read(allSourcesProvider).valueOrNull ?? [];
    setState(() {
      for (final s in sources) {
        final id = s['id'];
        if (id is String && id.isNotEmpty) _selectedIds.add(id);
      }
    });
  }

  Future<void> _deleteSelected(BuildContext context) async {
    final count = _selectedIds.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除书源'),
        content: Text('确定要删除选中的 $count 个书源吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: context.al.destructive)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      for (final id in _selectedIds) {
        await rust_api.deleteSource(dbPath: dbPath, id: id);
      }
      if (!mounted) return;
      _exitSelectMode();
      ref.invalidate(allSourcesProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除 $count 个书源')),
        );
      }
      DiagnosticLog.info('source.batch_delete', 'Batch deleted sources',
          metadata: {'count': count});
    } catch (e) {
      DiagnosticLog.warn('source.batch_delete', 'Batch delete failed',
          error: e, metadata: {'count': count});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('批量删除失败: $e')),
        );
      }
    }
  }
}

class _BatchCheckConfigDialog extends StatefulWidget {
  final List<Map<String, dynamic>> sources;

  const _BatchCheckConfigDialog({required this.sources});

  @override
  State<_BatchCheckConfigDialog> createState() =>
      _BatchCheckConfigDialogState();
}

class _BatchCheckConfigDialogState extends State<_BatchCheckConfigDialog> {
  late final TextEditingController _keywordCtrl;
  final Set<String> _stages = {'search', 'book_info', 'toc', 'content'};
  double _timeoutSecs = 180;
  double _concurrency = 8;

  static const Map<String, String> _stageLabels = {
    'search': '搜索',
    'book_info': '书籍详情',
    'toc': '目录',
    'content': '正文',
  };

  @override
  void initState() {
    super.initState();
    _keywordCtrl = TextEditingController(text: '我的');
  }

  @override
  void dispose() {
    _keywordCtrl.dispose();
    super.dispose();
  }

  void _start() {
    if (_stages.isEmpty) return;
    final ids = <String>[];
    for (final source in widget.sources) {
      final id = source['id'];
      if (id is String && id.isNotEmpty) ids.add(id);
    }
    if (ids.isEmpty) return;
    Navigator.of(context).pop(
      SourceCheckProgressArgs(
        sources: widget.sources,
        sourceIds: ids,
        keyword: _keywordCtrl.text.trim().isEmpty
            ? '我的'
            : _keywordCtrl.text.trim(),
        stages: _stages.toList(growable: false),
        timeoutSecs: _timeoutSecs.round(),
        concurrency: _concurrency.round(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('批量校验 ${widget.sources.length} 个书源'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _keywordCtrl,
              decoration: const InputDecoration(
                labelText: '搜索关键字',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text('校验阶段', style: Theme.of(context).textTheme.labelLarge),
            for (final entry in _stageLabels.entries)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(entry.value),
                value: _stages.contains(entry.key),
                onChanged: (checked) {
                  setState(() {
                    if (checked == true) {
                      _stages.add(entry.key);
                    } else {
                      _stages.remove(entry.key);
                    }
                  });
                },
              ),
            const SizedBox(height: 8),
            Text('超时：${_timeoutSecs.round()} 秒'),
            Slider(
              min: 5,
              max: 300,
              divisions: 59,
              value: _timeoutSecs,
              label: '${_timeoutSecs.round()}s',
              onChanged: (v) => setState(() => _timeoutSecs = v),
            ),
            Text('并发数：${_concurrency.round()}'),
            Slider(
              min: 1,
              max: 16,
              divisions: 15,
              value: _concurrency,
              label: '${_concurrency.round()}',
              onChanged: (v) => setState(() => _concurrency = v),
            ),
            if (_stages.isEmpty)
              Text(
                '至少选择一个阶段',
                style: TextStyle(color: context.al.destructive),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _stages.isEmpty ? null : _start,
          child: const Text('开始校验'),
        ),
      ],
    );
  }
}

/// 批次 21 (05-19) — 书源实跑 LiveTest dialog。
///
/// 顶部：关键字输入框（默认 "测试"）+ "开始测试" 按钮 / 测试中按钮
/// 进度区：4 个 ListTile (search / book_info / toc / content) — 测试中
/// 显示 [CircularProgressIndicator]，完成后切换为 check / error 图标 +
/// sample / error 文本 + 延迟 ms。
///
/// BATCH-20 (F-W2B-020)：通过 [sourceValidationServiceProvider] 注入实现，
/// 测试用 `ProviderScope.overrides` 替换 fake，生产走真实 FRB 调用。
class _LiveTestDialog extends ConsumerStatefulWidget {
  final String dbPath;
  final String sourceId;
  final String sourceName;
  const _LiveTestDialog({
    required this.dbPath,
    required this.sourceId,
    required this.sourceName,
  });

  @override
  ConsumerState<_LiveTestDialog> createState() => _LiveTestDialogState();
}

class _LiveTestDialogState extends ConsumerState<_LiveTestDialog> {
  late final TextEditingController _keywordCtrl;
  bool _running = false;
  String? _error;
  // 4 个 stage 的最终结果。null = 还没跑 / 还在跑。
  List<Map<String, dynamic>>? _stages;
  List<Map<String, dynamic>> _staticIssues = const [];

  // stage 顺序与 Rust 端一致；用于显示固定的 4 个 placeholder ListTile。
  static const List<String> _stageKeys = [
    'search',
    'book_info',
    'toc',
    'content',
  ];
  static const Map<String, String> _stageLabels = {
    'search': '搜索',
    'book_info': '书籍详情',
    'toc': '章节列表',
    'content': '章节内容',
  };

  @override
  void initState() {
    super.initState();
    _keywordCtrl = TextEditingController(text: '测试');
  }

  @override
  void dispose() {
    _keywordCtrl.dispose();
    super.dispose();
  }

  Future<void> _runTest() async {
    final keyword = _keywordCtrl.text.trim();
    if (keyword.isEmpty) {
      setState(() => _error = '请输入关键字');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _stages = null;
      _staticIssues = const [];
    });
    try {
      final svc = ref.read(sourceValidationServiceProvider);
      final json = await svc.validateLive(
        dbPath: widget.dbPath,
        sourceId: widget.sourceId,
        keyword: keyword,
      );
      final decoded = const JsonDecoder().convert(json);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('返回格式异常: $json');
      }
      final stages = (decoded['stages'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final issues = (decoded['static_issues'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (!mounted) return;
      setState(() {
        _running = false;
        _stages = stages;
        _staticIssues = issues;
      });
      final passCount = stages.where((s) => s['ok'] == true).length;
      final failCount = stages.length - passCount;
      DiagnosticLog.info('source.live_test', 'Live test completed',
          metadata: {'source_id': widget.sourceId, 'source_name': widget.sourceName, 'stages': stages.length, 'passed': passCount, 'failed': failCount});
    } catch (e) {
      if (!mounted) return;
      DiagnosticLog.warn('source.live_test', 'Live test failed',
          error: e, metadata: {'source_id': widget.sourceId, 'source_name': widget.sourceName});
      setState(() {
        _running = false;
        _error = e.toString();
      });
    }
  }

  Widget _buildStageTile(String key) {
    final label = _stageLabels[key] ?? key;
    if (_running && _stages == null) {
      return ListTile(
        dense: true,
        leading: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text(label),
        subtitle: const Text('测试中…'),
      );
    }
    if (_stages == null) {
      return ListTile(
        dense: true,
        leading: Icon(Icons.radio_button_unchecked,
            color: context.al.textSecondary, size: 20),
        title: Text(label),
        subtitle: const Text('待开始'),
      );
    }
    final found = _stages!.firstWhere(
      (s) => s['stage'] == key,
      orElse: () => const <String, dynamic>{},
    );
    if (found.isEmpty) {
      return ListTile(
        dense: true,
        leading:
            Icon(Icons.help_outline, color: context.al.textSecondary, size: 20),
        title: Text(label),
        subtitle: const Text('未返回结果'),
      );
    }
    final ok = found['ok'] == true;
    final latency = found['latency_ms'];
    final sample = found['sample'] as String?;
    final error = found['error'] as String?;
    return ListTile(
      dense: true,
      leading: Icon(
        ok ? Icons.check_circle : Icons.error,
        color: ok ? context.al.success : context.al.destructive,
        size: 20,
      ),
      title: Text(label),
      subtitle: Text(
        ok ? (sample ?? '成功') : (error ?? '失败'),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: latency is num ? Text('${latency}ms') : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.sourceName} · 实跑测试'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _keywordCtrl,
                    enabled: !_running,
                    decoration: const InputDecoration(
                      labelText: '关键字',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _running ? null : _runTest,
                  child: _running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('开始测试'),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.al.destructive),
                ),
              ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            for (final key in _stageKeys) _buildStageTile(key),
            if (_stages != null && _staticIssues.isNotEmpty) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                child: Text(
                  '静态校验问题 (${_staticIssues.length})',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              for (final issue in _staticIssues)
                ListTile(
                  dense: true,
                  leading: Icon(
                    issue['severity'] == 'error'
                        ? Icons.error
                        : issue['severity'] == 'warning'
                            ? Icons.warning
                            : Icons.info,
                    size: 18,
                    color: issue['severity'] == 'error'
                        ? context.al.destructive
                        : issue['severity'] == 'warning'
                            ? context.al.warning
                            : Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(
                    (issue['field'] as String?) ?? '',
                    style: TextStyle(
                        fontSize: 11, color: context.al.onSurface),
                  ),
                  subtitle: Text((issue['message'] as String?) ?? '',
                      style: const TextStyle(fontSize: 12)),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _running ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
