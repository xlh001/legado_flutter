import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/providers.dart';
import '../../src/rust/api.dart' as rust_api;

/// R24: 进程级标志位，避免在同一次 app 运行内重复显示迁移说明。
/// 不持久化（不靠 SharedPreferences）— 每次启动 app 重新提示一次，
/// 这是有意为之的弱提示，确保关心的用户能注意到。
///
/// BATCH-20 (F-W2B-065)：原 module-level mutable `bool _r24NoticeShown` 改为
/// StateProvider，让测试可 override 重置；行为与原来一致（同一进程内只显示
/// 一次）。私有可见（双下划线前缀）确保不被外部 watch / mutate。
final _r24NoticeShownProvider = StateProvider<bool>((_) => false);

class ReplaceRulePage extends ConsumerStatefulWidget {
  const ReplaceRulePage({super.key});

  @override
  ConsumerState<ReplaceRulePage> createState() => _ReplaceRulePageState();
}

class _ReplaceRulePageState extends ConsumerState<ReplaceRulePage> {
  @override
  void initState() {
    super.initState();
    // R24: 提示 schema 已升级、原"作用范围"信息已重置为全局。
    // Provider 修改必须在 widget build 之外 — 用 Future.microtask 延迟到下一微任务。
    final shown = ref.read(_r24NoticeShownProvider);
    if (!shown) {
      Future.microtask(() {
        if (!mounted) return;
        ref.read(_r24NoticeShownProvider.notifier).state = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '替换规则功能已升级（v10）。原"作用范围"信息已重置为全局，'
              '可在编辑规则里填写书名或书源 URL 重新限定。',
            ),
            duration: Duration(seconds: 3),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rulesAsync = ref.watch(allReplaceRulesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('替换规则'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(allReplaceRulesProvider),
          ),
        ],
      ),
      body: rulesAsync.when(
        data: (rules) => _buildRuleList(context, rules),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showRuleEditDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildRuleList(
      BuildContext context, List<Map<String, dynamic>> rules) {
    if (rules.isEmpty) {
      return const Center(child: Text('暂无替换规则，点击右下角添加'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: rules.length,
      itemBuilder: (context, index) {
        final rule = rules[index];
        final enabled = rule['enabled'] == true;
        // R24: scope 现在是 Option<String> — 子串匹配 book.name 或
        // book.origin。空 / null 表示全局。
        final scope = (rule['scope'] as String?)?.trim() ?? '';
        final scopeContent = rule['scope_content'] != false;
        final scopeTitle = rule['scope_title'] == true;
        final excludeScope =
            (rule['exclude_scope'] as String?)?.trim() ?? '';
        final scopeLabel =
            scope.isEmpty ? '全局' : '范围: ${_truncate(scope, 20)}';
        final targetLabel = [
          if (scopeContent) '正文',
          if (scopeTitle) '标题',
        ].join('+');
        final excludeLabel = excludeScope.isEmpty
            ? ''
            : '  排除: ${_truncate(excludeScope, 16)}';
        return Card(
          child: ListTile(
            leading: Icon(
              enabled ? Icons.check_circle : Icons.cancel,
              color: enabled ? context.al.success : context.al.textSecondary,
            ),
            title: Text(rule['name'] ?? '未命名规则'),
            subtitle: Text(
              '${rule['pattern'] ?? ''} → ${rule['replacement'] ?? ''}\n'
              '[$scopeLabel] [$targetLabel]$excludeLabel',
            ),
            isThreeLine: true,
            trailing: Switch(
              value: enabled,
              onChanged: (val) =>
                  _toggleRule(rule['id'] as String, val),
            ),
            onTap: () => _showRuleActions(context, rule),
          ),
        );
      },
    );
  }

  String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  Future<void> _toggleRule(String id, bool enabled) async {
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      await rust_api.setReplaceRuleEnabled(
          dbPath: dbPath, id: id, enabled: enabled);
      bumpReplaceRuleGeneration(ref);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e')),
        );
      }
    }
  }

  /// R110: 统一的添加 / 编辑对话框。`existing == null` 时表现等同
  /// 原 `_showAddRuleDialog`（生成新 id）；`existing != null` 时预填
  /// 全部字段、保留原 id / sort_number / created_at / enabled，
  /// 通过 `saveReplaceRule` upsert。
  ///
  /// R120: 表单 controller 改由 [_RuleEditDialog] 拥有（StatefulWidget
  /// 的 State 字段），由它的 dispose 释放，避免每次开关 dialog 都泄漏
  /// 5 个 TextEditingController。
  void _showRuleEditDialog(BuildContext context,
      [Map<String, dynamic>? existing]) {
    showDialog(
      context: context,
      builder: (ctx) => _RuleEditDialog(
        existing: existing,
        onSave: (ruleJson) async {
          await ref.read(dbInitializedProvider.future);
          final dbPath = await ref.read(dbPathProvider.future);
          await rust_api.saveReplaceRule(
              dbPath: dbPath, ruleJson: ruleJson);
          bumpReplaceRuleGeneration(ref);
        },
      ),
    );
  }

  void _showRuleActions(
      BuildContext context, Map<String, dynamic> rule) {
    // R111: 结构化展示完整字段而非仅 pattern，方便用户在不进入编辑
    // 的情况下确认规则配置（scope / exclude_scope / 作用对象）。
    final pattern = rule['pattern'] as String? ?? '';
    final replacement = rule['replacement'] as String? ?? '';
    final scope = (rule['scope'] as String?)?.trim() ?? '';
    final excludeScope =
        (rule['exclude_scope'] as String?)?.trim() ?? '';
    final scopeContent = rule['scope_content'] != false;
    final scopeTitle = rule['scope_title'] == true;
    final targetLabel = scopeContent && scopeTitle
        ? '正文+标题'
        : scopeContent
            ? '正文'
            : scopeTitle
                ? '标题'
                : '（未选）';
    final scopeDisplay = scope.isEmpty ? '全局' : _truncate(scope, 200);
    final excludeDisplay =
        excludeScope.isEmpty ? '无' : _truncate(excludeScope, 200);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(rule['name'] ?? '规则操作'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ruleDetailRow('匹配模式', _truncate(pattern, 200)),
              _ruleDetailRow('替换为',
                  replacement.isEmpty ? '（空）' : _truncate(replacement, 200)),
              _ruleDetailRow('作用范围', scopeDisplay),
              _ruleDetailRow('排除范围', excludeDisplay),
              _ruleDetailRow('作用对象', targetLabel),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showRuleEditDialog(context, rule);
            },
            child: const Text('编辑'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteRule(rule['id'] as String);
            },
            child:
                Text('删除', style: TextStyle(color: context.al.destructive)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _ruleDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          SelectableText(value),
        ],
      ),
    );
  }

  Future<void> _deleteRule(String id) async {
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      await rust_api.deleteReplaceRule(dbPath: dbPath, id: id);
      bumpReplaceRuleGeneration(ref);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('规则已删除')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }
}

/// R120: 替换规则添加 / 编辑对话框。把 5 个 [TextEditingController] 与
/// 两个 checkbox 状态作为 State 字段持有，并在 [dispose] 释放，避免
/// 之前在 `_showRuleEditDialog` 函数体里 new 出来后无人 dispose 的
/// 泄漏。`onSave` 由调用方提供，负责将 ruleJson 写入数据库 + bump
/// replace-rule generation；本 widget 仅在 onSave 成功后 pop，失败
/// 弹 SnackBar 留在原位让用户修改。
class _RuleEditDialog extends StatefulWidget {
  const _RuleEditDialog({required this.existing, required this.onSave});

  final Map<String, dynamic>? existing;

  /// 调用方负责把序列化后的规则 JSON 写入 DB 并 bump
  /// replace-rule generation。错误请通过抛异常回报，本 widget
  /// 会捕获并展示 SnackBar，不 pop。
  final Future<void> Function(String ruleJson) onSave;

  @override
  State<_RuleEditDialog> createState() => _RuleEditDialogState();
}

class _RuleEditDialogState extends State<_RuleEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _patternCtrl;
  late final TextEditingController _replacementCtrl;
  late final TextEditingController _scopeCtrl;
  late final TextEditingController _excludeCtrl;
  late bool _scopeContent;
  late bool _scopeTitle;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?['name'] as String? ?? '');
    _patternCtrl =
        TextEditingController(text: e?['pattern'] as String? ?? '');
    _replacementCtrl = TextEditingController(
        text: e?['replacement'] as String? ?? '');
    _scopeCtrl =
        TextEditingController(text: (e?['scope'] as String?) ?? '');
    _excludeCtrl = TextEditingController(
        text: (e?['exclude_scope'] as String?) ?? '');
    // R24 默认值：scope_content=true, scope_title=false。
    _scopeContent = e == null ? true : (e['scope_content'] != false);
    _scopeTitle = e == null ? false : (e['scope_title'] == true);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _patternCtrl.dispose();
    _replacementCtrl.dispose();
    _scopeCtrl.dispose();
    _excludeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final pattern = _patternCtrl.text.trim();
    if (name.isEmpty || pattern.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // R110: edit 模式复用原 id / sort_number / created_at / enabled，
    // 仅刷新 updated_at；add 模式生成新 id。
    final existing = widget.existing;
    final id = _isEdit
        ? existing!['id'] as String
        : '${now}_${Random().nextInt(99999)}';
    final scopeText = _scopeCtrl.text.trim();
    final excludeText = _excludeCtrl.text.trim();
    final ruleJson = jsonEncode({
      'id': id,
      'name': name,
      'pattern': pattern,
      'replacement': _replacementCtrl.text,
      'enabled': _isEdit ? (existing!['enabled'] != false) : true,
      'scope': scopeText.isEmpty ? null : scopeText,
      'scope_title': _scopeTitle,
      'scope_content': _scopeContent,
      'exclude_scope': excludeText.isEmpty ? null : excludeText,
      'sort_number':
          _isEdit ? (existing!['sort_number'] as int? ?? 0) : 0,
      'created_at':
          _isEdit ? (existing!['created_at'] as int? ?? now) : now,
      'updated_at': now,
    });
    try {
      await widget.onSave(ruleJson);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_isEdit ? "保存" : "添加"}失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? '编辑替换规则' : '添加替换规则'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: '规则名称'),
            ),
            TextField(
              controller: _patternCtrl,
              decoration:
                  const InputDecoration(labelText: '匹配模式 (正则)'),
            ),
            TextField(
              controller: _replacementCtrl,
              decoration: const InputDecoration(labelText: '替换文本'),
            ),
            const SizedBox(height: 8),
            // R24: scope 改为自由文本，对齐原 Legado UI（"选填
            // 书名或书源 URL"）。子串匹配，留空 = 全局。
            TextField(
              controller: _scopeCtrl,
              decoration: const InputDecoration(
                labelText: '作用范围',
                helperText: '选填书名或书源 URL，留空 = 全局；多个用空格分隔',
              ),
            ),
            TextField(
              controller: _excludeCtrl,
              decoration: const InputDecoration(
                labelText: '排除范围',
                helperText: '选填书名或书源 URL，命中即跳过',
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('作用于正文'),
              value: _scopeContent,
              onChanged: (v) =>
                  setState(() => _scopeContent = v ?? true),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('作用于章节标题'),
              value: _scopeTitle,
              onChanged: (v) =>
                  setState(() => _scopeTitle = v ?? false),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(_isEdit ? '保存' : '添加'),
        ),
      ],
    );
  }
}
