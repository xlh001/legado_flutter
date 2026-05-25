import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/persistence/json_store.dart';
import '../../core/providers.dart';
import '../../core/diagnostics/diagnostic_log.dart';
import '../../core/security/secure_storage.dart';
import '../../core/services/backup_api_client.dart';
import '../../core/services/file_picker_service.dart';
import '../../core/util/import_summary_label.dart';
import '../../core/widgets/safe_setstate.dart';

/// 本地备份/恢复页（批次 10 / 05-19）。
///
/// 对齐原 Legado `BackupRestore` UI 的最小可用版：
/// - 顶部"导出备份"卡片：选保存目录 → 调 [`exportBackupZip`] →
///   生成 `legado_backup_<yyyyMMdd-HHmm>.zip`（兼容原版 `backup` 前缀
///   也能识别）→ SnackBar 显示文件路径。
/// - 中部"导入备份"卡片：[FilePicker] 选 zip → 调 [`validateBackupZip`]
///   显示"识别到 N 项" → 用户确认 → 调 [`importBackupZip`] →
///   解析 ImportSummary JSON 显示导入条数 → invalidate 书架/分组/书源/
///   替换规则相关 providers 让 UI 立刻刷新。
///
/// **入口**：GoRouter `/backup`。bookshelf_page AppBar PopupMenu 加
/// "备份/恢复" 项触发跳转。
///
/// **测试**：BATCH-20 (F-W2B-004) 起，所有 FRB / file_picker /
/// path_provider 调用都通过 Riverpod provider 注入；widget test 用
/// `ProviderScope.overrides` 替换 [backupApiClientProvider] /
/// [filePickerServiceProvider] / [dbPathProvider]，不再依赖构造函数 *Override。
/// `dbPathOverride` 保留作为简易测试 hook（与 cache_management 等保持一致）。
class BackupPage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假 dbPath 避免 widget test 走 path_provider。
  final String? dbPathOverride;

  const BackupPage({
    super.key,
    this.dbPathOverride,
  });

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  /// 用户选择的待导入 zip 路径（pick 之后填入）。
  String? _pickedZipPath;

  /// 已对待导入 zip 跑过 validate 的结果（识别到的文件名列表）。
  List<String>? _pickedZipRecognized;

  /// 导出进行中。
  bool _exporting = false;

  /// 导入进行中（含 validate 阶段）。
  bool _importing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('备份/恢复'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'WebDAV 配置',
            onPressed: () => context.push('/webdav-config'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildExportCard(context),
          const SizedBox(height: 16),
          _buildImportCard(context),
          const SizedBox(height: 16),
          _buildWebDavCard(context),
        ],
      ),
    );
  }

  Widget _buildExportCard(BuildContext context) {
    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ListTile(
              leading: Icon(Icons.upload),
              title: Text('导出当前书架到 zip'),
              subtitle: Text('兼容原 Legado 格式'),
            ),
            if (_exporting) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  icon: const Icon(Icons.save_alt),
                  label: const Text('选择保存目录并导出'),
                  onPressed: _exporting || _importing ? null : _onExport,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImportCard(BuildContext context) {
    final picked = _pickedZipPath;
    final recognized = _pickedZipRecognized;
    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ListTile(
              leading: Icon(Icons.download),
              title: Text('从 zip 恢复书架'),
              subtitle: Text('支持原 Legado 备份文件'),
            ),
            if (_importing) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择 zip 文件'),
                  onPressed: _exporting || _importing ? null : _onPickZip,
                ),
              ),
            ),
            if (picked != null) ...[
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  '已选择: $picked',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (recognized != null)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    recognized.isEmpty
                        ? '未识别到任何 Legado 备份文件'
                        : '识别到 ${recognized.length} 项: ${recognized.join(", ")}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.restore),
                    label: const Text('确认导入'),
                    onPressed: (_exporting ||
                            _importing ||
                            recognized == null ||
                            recognized.isEmpty)
                        ? null
                        : _onConfirmImport,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 拼接 `legado_backup_<yyyyMMdd-HHmm>.zip` 文件名。本工程导出
  /// 用 `legado_backup_` 前缀；原 Legado 用 `backup` 前缀也能被
  /// validate_backup_zip 识别（见 Rust 端 backup_dao::validate_zip）。
  String _buildBackupFileName() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}';
    return 'legado_backup_$stamp.zip';
  }

  Future<String> _resolveDbPath() async {
    final override = widget.dbPathOverride;
    if (override != null) return override;
    return ref.read(dbPathProvider.future);
  }

  Future<void> _onExport() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final picker = ref.read(filePickerServiceProvider);
      final dir = await picker.pickDirectory();
      if (dir == null || dir.isEmpty) {
        return;
      }
      final dbPath = await _resolveDbPath();
      final outPath = '$dir/${_buildBackupFileName()}';
      DiagnosticLog.info('backup.export', 'Local export started',
          metadata: {'db_path_basename': dbPath.split('/').last});
      final api = ref.read(backupApiClientProvider);
      await api.exportBackup(dbPath: dbPath, outZipPath: outPath);
      DiagnosticLog.info('backup.export', 'Local export completed',
          metadata: {'out_path_basename': outPath.split('/').last});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出: $outPath')),
      );
    } catch (e) {
      if (!mounted) return;
      DiagnosticLog.error('backup.export', 'Local export failed', error: e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    } finally {
      safeSetState(() => _exporting = false);
    }
  }

  Future<void> _onPickZip() async {
    if (_importing) return;
    setState(() {
      _importing = true;
      _pickedZipRecognized = null;
    });
    try {
      final picker = ref.read(filePickerServiceProvider);
      final path = await picker.pickZipFile();
      if (path == null || path.isEmpty) {
        if (mounted) {
          setState(() => _pickedZipPath = null);
        }
        return;
      }
      // dry-run validate：列出 zip 内识别到的 Legado 备份文件名。
      final api = ref.read(backupApiClientProvider);
      final names = await api.validateZip(zipPath: path);
      if (!mounted) return;
      DiagnosticLog.info('backup.import', 'Backup zip validated',
          metadata: {'recognized_count': names.length});
      setState(() {
        _pickedZipPath = path;
        _pickedZipRecognized = names;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('解析备份文件失败: $e')),
      );
    } finally {
      safeSetState(() => _importing = false);
    }
  }

  Future<void> _onConfirmImport() async {
    final path = _pickedZipPath;
    if (path == null || path.isEmpty) return;
    if (_importing) return;
    // 二次确认：导入是 upsert 合并语义（与原 Legado 一致），不会清空
    // 现有数据，但用户应明白可能产生新书 / 新分组。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认导入'),
        content: const Text(
          '导入会把备份中的书架、分组、书签、替换规则、书源合并到当前数据库。\n现有数据不会被清空。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _importing = true);
    try {
      final dbPath = await _resolveDbPath();
      final api = ref.read(backupApiClientProvider);
      final summaryJson = await api.importBackup(dbPath: dbPath, zipPath: path);
      if (!mounted) return;
      DiagnosticLog.info('backup.import', 'Backup import completed');
      // 解析 ImportSummary：{books, groups, bookmarks, replace_rules, sources, errors}
      final label = formatImportSummaryLabel(
        summaryJson,
        prefix: '导入完成',
        fallback: '导入完成',
      );
      // 让书架/分组/书源/替换规则相关 providers 立刻刷新。
      ref.invalidate(allBooksProvider);
      ref.invalidate(booksByGroupProvider);
      ref.invalidate(bookGroupsProvider);
      ref.invalidate(allSourcesProvider);
      ref.invalidate(allReplaceRulesProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(label)),
      );
      // 导入完后清空选中的 zip，避免用户重复点"确认导入"。
      if (mounted) {
        setState(() {
          _pickedZipPath = null;
          _pickedZipRecognized = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    } finally {
      safeSetState(() => _importing = false);
    }
  }

  // ============================================================
  // 批次 11 — WebDAV 同步 UI + handlers
  // ============================================================

  /// 处理 WebDAV 同步进行中（上传 / 下载 / 列表）。共享一个 flag 让按钮
  /// 全部 disable 防并发误触。
  bool _webdavBusy = false;

  Widget _buildWebDavCard(BuildContext context) {
    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ListTile(
              leading: Icon(Icons.cloud),
              title: Text('WebDAV 同步'),
              subtitle: Text('与远端备份目录上传 / 下载 zip'),
            ),
            if (_webdavBusy) const LinearProgressIndicator(),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.cloud_upload),
                      label: const Text('上传到 WebDAV'),
                      onPressed: (_exporting || _importing || _webdavBusy)
                          ? null
                          : _onWebDavUpload,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      icon: const Icon(Icons.cloud_download),
                      label: const Text('从 WebDAV 恢复'),
                      onPressed: (_exporting || _importing || _webdavBusy)
                          ? null
                          : _onWebDavRestore,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                '配置入口在右上角齿轮图标。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 读 `<documentsDir>/webdav.json` + `secure_storage` 的 `webdav_password`，
  /// 拼回类型化数据类。返回 `null` 表示未配置（让 caller 提示"先去配置"）。
  ///
  /// BATCH-03 (F-W2B-001)：webdav.json 仅含 url / user / deviceName 3 个非
  /// 敏感字段；password 字段从 secure_storage 取（Android Keystore / iOS
  /// Keychain）。secure_storage 未配置时 password 走空串兜底，由 webdav
  /// 服务器最终返 401 给用户错误反馈（与原行为一致）。
  ///
  /// BATCH-03 (F-W2B-006)：返回值从 `Map<String, String>?` 改为类型化
  /// [_WebDavCredentials]，消除 caller 9 处 `cfg['xxx']!` 强制断言。
  Future<_WebDavCredentials?> _loadWebDavConfig() async {
    // BATCH-18g (F-W2A-058)：走 json_store 公共 helper。readJsonFile 自吞
    // 异常返回 null（与原 catch (_) → null 等价）。url trim+empty→null
    // 校验保留在 caller，因为这是 backup_page 特有的"未配置"语义。
    //
    // BATCH-20 (F-W2B-004)：删 webdavConfigDirOverride 测试钩子；测试改用
    // tempDir 注入到 path_provider mock 即可（与 webdav_config_page_test.dart
    // 一致）。
    final map = await readJsonFile('webdav.json');
    if (map == null) return null;
    final url = (map['url'] as String?)?.trim() ?? '';
    if (url.isEmpty) return null;
    return _WebDavCredentials(
      url: url,
      user: (map['user'] as String?) ?? '',
      password: (await readSecret('webdav_password')) ?? '',
      deviceName: (map['deviceName'] as String?) ?? '',
    );
  }

  /// 拼接远端 backup 文件名。优先用 `deviceName-` 后缀，否则用 `legado_flutter`
  /// 当 fallback,避免与原 Legado 设备同名冲突。日期 yyyy-MM-dd,与原版
  /// `Backup.getNowZipFileName` 一致。
  String _buildRemoteBackupFileName(String? deviceName) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${now.year}-${two(now.month)}-${two(now.day)}';
    final dev = (deviceName ?? '').trim();
    return dev.isNotEmpty ? 'backup$date-$dev.zip' : 'backup$date.zip';
  }

  Future<void> _onWebDavUpload() async {
    if (_webdavBusy) return;
    final cfg = await _loadWebDavConfig();
    if (!mounted) return;
    if (cfg == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先去配置 WebDAV')),
      );
      return;
    }
    setState(() => _webdavBusy = true);
    try {
      final dbPath = await _resolveDbPath();
      final fileName = _buildRemoteBackupFileName(cfg.deviceName);
      final api = ref.read(backupApiClientProvider);
      await api.webdavUpload(
        dbPath: dbPath,
        url: cfg.url,
        user: cfg.user,
        password: cfg.password,
        fileName: fileName,
      );
      DiagnosticLog.info('backup.webdav', 'WebDAV upload completed',
          metadata: {'file_name': fileName});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已上传: $fileName')),
      );
    } catch (e) {
      if (!mounted) return;
      DiagnosticLog.error('backup.webdav', 'WebDAV upload failed', error: e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('上传失败: $e')),
      );
    } finally {
      safeSetState(() => _webdavBusy = false);
    }
  }

  Future<void> _onWebDavRestore() async {
    if (_webdavBusy) return;
    final cfg = await _loadWebDavConfig();
    if (!mounted) return;
    if (cfg == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先去配置 WebDAV')),
      );
      return;
    }
    setState(() => _webdavBusy = true);
    try {
      final api = ref.read(backupApiClientProvider);
      final json = await api.webdavList(
        url: cfg.url,
        user: cfg.user,
        password: cfg.password,
      );
      final List<dynamic> raw = jsonDecode(json) as List<dynamic>;
      final files = raw.cast<String>();
      DiagnosticLog.info('backup.webdav', 'WebDAV list completed',
          metadata: {'file_count': files.length});
      if (!mounted) return;
      if (files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('远端无可恢复的备份')),
        );
        return;
      }
      // 单选 dialog
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('选择要恢复的备份'),
          children: files
              .map((f) => SimpleDialogOption(
                    onPressed: () => Navigator.of(ctx).pop(f),
                    child: Text(f),
                  ))
              .toList(),
        ),
      );
      if (picked == null) return;
      if (!mounted) return;
      // 下载 + 导入
      final dbPath = await _resolveDbPath();
      final summaryJson = await api.webdavDownload(
        dbPath: dbPath,
        url: cfg.url,
        user: cfg.user,
        password: cfg.password,
        fileName: picked,
      );
      if (!mounted) return;
      DiagnosticLog.info('backup.webdav', 'WebDAV download completed',
          metadata: {'file_name': picked});
      // 解析 ImportSummary
      final label = formatImportSummaryLabel(
        summaryJson,
        prefix: '从 WebDAV 恢复',
        fallback: '从 WebDAV 恢复完成',
      );
      ref.invalidate(allBooksProvider);
      ref.invalidate(booksByGroupProvider);
      ref.invalidate(bookGroupsProvider);
      ref.invalidate(allSourcesProvider);
      ref.invalidate(allReplaceRulesProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(label)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复失败: $e')),
      );
    } finally {
      safeSetState(() => _webdavBusy = false);
    }
  }
}

/// WebDAV 凭据 + 设备名（BATCH-03 / F-W2B-006）。
///
/// 替代原 `Map<String, String>` 表达，避免 9 处 `cfg['xxx']!` 强制断言。
/// 保持 file-private（无跨文件复用必要 — webdav_config_page 自己直接读
/// secure_storage + json，不走这个数据类）。
///
/// password 字段非 nullable，由 [_BackupPageState._loadWebDavConfig] 在
/// secure_storage 缺失时填空串兜底（与原 `(map['password'] as String?) ?? ''`
/// 行为对齐）。
class _WebDavCredentials {
  final String url;
  final String user;
  final String password;
  final String deviceName;

  const _WebDavCredentials({
    required this.url,
    required this.user,
    required this.password,
    required this.deviceName,
  });
}
