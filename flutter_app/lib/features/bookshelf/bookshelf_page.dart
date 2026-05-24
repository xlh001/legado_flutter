import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/persistence/json_store.dart';
import '../../core/providers.dart';
import '../../core/update_toc_runner.dart';
import '../../core/widgets/safe_setstate.dart';
import '../../src/rust/api.dart' as rust_api;
import 'widgets/book_group_dialogs.dart';

/// 书架页（批次 7：加分组 TabBar）。
///
/// AppBar.bottom = TabBar：第 0 Tab "全部"(group_id=-1) + 第 1 Tab "未分组"
/// (group_id=0) + 用户分组（来自 [bookGroupsProvider]）。每个 Tab 调
/// [booksByGroupProvider](groupId) 拿对应书列表。
///
/// 长按书条 → 底部 Sheet：删除 / 移动到分组（[GroupSelectDialog]）。
/// AppBar 菜单 → 管理分组（[GroupManageDialog]）/ 备份恢复 / 导入本地书。
///
/// 批次 13 (05-19): 顶栏 PopupMenu 加"导入本地书"项，触发 file_picker
/// 选 .txt/.epub/.umd → 调 [`rust_api.importLocalBook`] → invalidate
/// 书架 providers + SnackBar 成功提示 + 自动跳到 reader。
class BookshelfPage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假 dbPath，避免 widget test 走 path_provider。
  final String? dbPathOverride;

  /// 测试钩子：注入假 documentsDir，避免 widget test 走 path_provider。
  final String? documentsDirOverride;

  /// 测试钩子：注入假的"导入本地书"文件选择器。返回选中文件绝对路径
  /// 或 null（用户取消）。
  final Future<String?> Function()? pickFileForLocalImportOverride;

  /// 测试钩子：注入假的 importLocalBook FRB 调用，返回与真实 FRB
  /// 相同形状的 JSON 字符串 `{"book_id":"..."}`。
  final Future<String> Function({
    required String dbPath,
    required String filePath,
    required String documentsDir,
  })? importLocalBookOverride;

  /// BATCH-27a: 测试钩子，注入假的 exportBookshelfJson FRB 调用，返回
  /// 与真实 FRB 同形状的 JSON 字符串（`"[]"` 或 `'[{"name":"..."}]'`）。
  final Future<String> Function({required String dbPath})?
      exportBookshelfJsonOverride;

  /// BATCH-27a: 测试钩子，注入假的 documents 目录路径（不走 path_provider）。
  /// 与 [documentsDirOverride] 字段语义类似，但 `_onExportBookshelf` 用
  /// 此字段决定 books.json 的写入位置。
  final String? exportDocumentsDirectoryOverride;

  /// BATCH-27b: 测试钩子，注入假的 updateBookToc FRB 调用，返回新章节数。
  /// 透传给 [UpdateTocRunner.enqueue] 让 worker 走假实现，避免 widget test
  /// 走真 FRB / 网络。生产路径不传该 override，runner 默认调
  /// [`rust_api.updateBookToc`]。
  final UpdateBookTocFn? updateBookTocOverride;

  const BookshelfPage({
    super.key,
    this.dbPathOverride,
    this.documentsDirOverride,
    this.pickFileForLocalImportOverride,
    this.importLocalBookOverride,
    this.exportBookshelfJsonOverride,
    this.exportDocumentsDirectoryOverride,
    this.updateBookTocOverride,
  });

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {
  bool _isGridView = false;

  /// BATCH-27b: 「更新目录」批量任务进度状态。监听 [UpdateTocRunner.onProgress]
  /// 后写回这三字段触发 AppBar transient badge rebuild。
  bool _isUpdatingToc = false;
  int _updateTocProcessed = 0;
  int _updateTocTotal = 0;
  StreamSubscription<UpdateTocProgress>? _updateTocSub;

  final LayerLink _menuLayerLink = LayerLink();
  OverlayEntry? _menuOverlay;

  @override
  void initState() {
    super.initState();
    loadBookshelfGridViewFromDisk().then((value) {
      safeSetState(() => _isGridView = value);
    });
    // BATCH-27b: 挂 progress 监听。runner 是 singleton —— 即使其它入口（未来
    // batch-deep-cache 等）也能共享同一进度通道。dispose 时 cancel 避免
    // 旧 page 的 setState 在 unmount 后被触发。
    _updateTocSub = UpdateTocRunner().onProgress.listen((p) {
      if (!mounted) return;
      safeSetState(() {
        _isUpdatingToc = p.isRunning;
        _updateTocProcessed = p.processed;
        _updateTocTotal = p.total;
      });
      if (p.isDone) {
        // invalidate 让书架重新拉书（chapter_count 已变 / dur_chapter_title
        // 不动，但订单时间或 last_check_time 可能影响排序）
        ref.invalidate(allBooksProvider);
        ref.invalidate(booksByGroupProvider);
        if (mounted) {
          // hide 当前 SnackBar：批次开始时 _onUpdateToc 弹的「已开始刷新目录」
          // 还可能在 4s 默认 dismiss timer 内，让位给完成消息。
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '目录刷新完成：成 ${p.success} / 失 ${p.fail}',
              ),
            ),
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _menuOverlay?.remove();
    _updateTocSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(bookGroupsProvider);
    // 批次 8: 全局监听排序方式；切换排序后下方所有 Tab 都会重新拉书。
    final sortOrder = ref.watch(bookshelfSortProvider);

    return groupsAsync.when(
      // 错误 / loading 时仍展示 TabBar 骨架（只有"全部"+"未分组"两个虚拟 Tab），
      // 避免分组拉取失败导致整页都进不去。
      loading: () => _buildScaffold(context, const [], sortOrder),
      error: (e, _) => _buildScaffold(context, const [], sortOrder),
      data: (groups) => _buildScaffold(context, groups, sortOrder),
    );
  }

  void _showMoreMenu(
    BuildContext innerCtx,
    List<_TabSpec> tabSpec,
    int sortOrder,
  ) {
    _menuOverlay?.remove();
    _menuOverlay = null;
    final theme = Theme.of(innerCtx);
    final colorScheme = theme.colorScheme;
    final screenHeight = MediaQuery.of(innerCtx).size.height;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          entry.remove();
          _menuOverlay = null;
        },
        child: Stack(
          children: [
            CompositedTransformFollower(
              link: _menuLayerLink,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 8),
              child: GestureDetector(
                onTap: () {},
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(16),
                  color: colorScheme.surfaceContainerHigh,
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: screenHeight * 0.65,
                      minWidth: 160,
                      maxWidth: 200,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _buildMenuItems(ctx, innerCtx,
                            tabSpec, sortOrder, () {
                          entry.remove();
                          _menuOverlay = null;
                        }),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    _menuOverlay = entry;
    Overlay.of(innerCtx).insert(entry);
  }

  List<Widget> _buildMenuItems(
    BuildContext overlayCtx,
    BuildContext pageCtx,
    List<_TabSpec> tabSpec,
    int sortOrder,
    VoidCallback closeMenu,
  ) {
    Future<void> onSelect(String value) async {
      closeMenu();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;

      if (value == 'manage_groups') {
        await showDialog(
          context: pageCtx,
          builder: (_) => const GroupManageDialog(),
        );
      } else if (value == 'import_local') {
        await _onImportLocalBook(pageCtx);
      } else if (value == 'cache_export') {
        if (pageCtx.mounted) pageCtx.push('/downloads');
      } else if (value == 'qr_scan') {
        if (pageCtx.mounted) pageCtx.push('/qr-scan');
      } else if (value == 'bookshelf_layout') {
        await _showLayoutDialog(pageCtx);
      } else if (value == 'export_bookshelf') {
        await _onExportBookshelf(pageCtx);
      } else if (value == 'update_toc') {
        await _onUpdateToc(pageCtx, tabSpec, sortOrder);
      } else if (value == 'add_remote') {
        if (pageCtx.mounted) pageCtx.push('/remote-books');
      } else if (value == 'bookshelf_manage') {
        if (pageCtx.mounted) pageCtx.push('/bookshelf-manage');
      } else if (value == 'add_url') {
        await _onAddUrl(pageCtx);
      } else if (value == 'import_bookshelf') {
        await _onImportBookshelf(pageCtx);
      } else if (value == 'sort') {
        _showSortDialog(pageCtx);
      }
    }

    return [
      _overlayMenuItem(overlayCtx, 'update_toc', Icons.refresh, '更新目录',
          () => onSelect('update_toc')),
      _overlayMenuItem(overlayCtx, 'import_local', Icons.note_add, '添加本地书',
          () => onSelect('import_local')),
      _overlayMenuItem(overlayCtx, 'add_remote', Icons.cloud_outlined, '添加远程书',
          () => onSelect('add_remote')),
      _overlayMenuItem(overlayCtx, 'add_url', Icons.link, '添加网络URL',
          () => onSelect('add_url')),
      _overlayMenuItem(overlayCtx, 'qr_scan', Icons.qr_code_scanner, '扫码导入',
          () => onSelect('qr_scan')),
      _overlayMenuItem(overlayCtx, 'bookshelf_manage', Icons.edit_note,
          '书架管理', () => onSelect('bookshelf_manage')),
      _overlayMenuItem(overlayCtx, 'cache_export', Icons.download_outlined,
          '缓存/导出', () => onSelect('cache_export')),
      _overlayMenuItem(overlayCtx, 'manage_groups', Icons.folder_outlined,
          '分组管理', () => onSelect('manage_groups')),
      _overlayMenuItem(overlayCtx, 'bookshelf_layout', Icons.dashboard_outlined,
          '书架布局', () => onSelect('bookshelf_layout')),
      _overlayMenuItem(overlayCtx, 'sort', Icons.sort, '书架排序',
          () => onSelect('sort')),
      _overlayMenuItem(overlayCtx, 'export_bookshelf', Icons.upload_file,
          '导出书架', () => onSelect('export_bookshelf')),
      _overlayMenuItem(overlayCtx, 'import_bookshelf',
          Icons.file_download_outlined, '导入书架',
          () => onSelect('import_bookshelf')),
      _overlayDisabledMenuItem(
          overlayCtx, Icons.article_outlined, '日志'),
    ];
  }

  Widget _buildScaffold(BuildContext context,
      List<Map<String, dynamic>> groups, int sortOrder) {
    // Tab 总数 = 2 (全部 + 未分组) + N 个用户分组。
    // ValueKey 让用户分组数变化时 DefaultTabController 重建，避免 controller
    // 长度不匹配抛 assertion。
    final tabSpec = <_TabSpec>[
      const _TabSpec(label: '全部', groupId: -1),
      const _TabSpec(label: '未分组', groupId: 0),
      for (final g in groups)
        _TabSpec(
          label: g['name'] as String? ?? '未命名',
          groupId: (g['id'] as num).toInt(),
        ),
    ];

    return DefaultTabController(
      key: ValueKey(tabSpec.length),
      length: tabSpec.length,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          centerTitle: false,
          title: Align(
            alignment: Alignment.centerLeft,
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: UnderlineTabIndicator(
                borderSide: BorderSide(
                  width: 3,
                  color: Theme.of(context).colorScheme.primary,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
              tabs: [for (final t in tabSpec) Tab(text: t.label)],
            ),
          ),
          actions: [
            // TOC update progress badge
            if (_isUpdatingToc)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Tooltip(
                  message:
                      '正在更新目录 $_updateTocProcessed/$_updateTocTotal',
                  child: SizedBox(
                    width: 40,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        Positioned(
                          right: -8,
                          top: -2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$_updateTocProcessed/$_updateTocTotal',
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.surface,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: '搜索',
              onPressed: () => context.push('/search'),
            ),
            Builder(
              builder: (innerCtx) => CompositedTransformTarget(
                link: _menuLayerLink,
                child: IconButton(
                  icon: const Icon(Icons.more_vert),
                  tooltip: '更多',
                  onPressed: () => _showMoreMenu(
                    innerCtx, tabSpec, sortOrder),
                ),
              ),
            ),
          ],
        ),
        body: TabBarView(
          children: [
            for (final t in tabSpec)
              _BookListView(
                groupId: t.groupId,
                sortOrder: sortOrder,
                isGridView: _isGridView,
              )
          ],
        ),
      ),
    );
  }

  /// 批次 13 (05-19): 选本地文件 → 调 [`rust_api.importLocalBook`] →
  /// invalidate 书架/分组 providers → SnackBar 提示成功 → 自动跳到
  /// reader 页面。
  ///
  /// 走过 `pickFileForLocalImportOverride` / `importLocalBookOverride`
  /// 测试钩子时不依赖真实 file_picker / FRB / path_provider；生产代码
  /// 跑默认路径。
  ///
  /// 失败处理：所有异常（用户取消除外）都会 catch + SnackBar 提示，避免
  /// 把异常向上抛打断书架页。
  Future<void> _onImportLocalBook(BuildContext context) async {
    try {
      final pickFn = widget.pickFileForLocalImportOverride ??
          () async {
            final result = await FilePicker.pickFiles(
              type: FileType.custom,
              allowedExtensions: ['txt', 'epub', 'umd'],
            );
            if (result == null || result.files.isEmpty) return null;
            return result.files.single.path;
          };
      final pickedPath = await pickFn();
      if (pickedPath == null || pickedPath.isEmpty) return;
      if (!context.mounted) return;
      // 解析 dbPath / documentsDir
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final String documentsDir = widget.documentsDirOverride ??
          await resolvePersistenceDir();
      // FRB 调用
      final importFn = widget.importLocalBookOverride ??
          ({
            required String dbPath,
            required String filePath,
            required String documentsDir,
          }) =>
              rust_api.importLocalBook(
                dbPath: dbPath,
                filePath: filePath,
                documentsDir: documentsDir,
              );
      final json = await importFn(
        dbPath: dbPath,
        filePath: pickedPath,
        documentsDir: documentsDir,
      );
      // 解析返回 JSON `{"book_id": "..."}`
      String? bookId;
      try {
        final Map<String, dynamic> map =
            jsonDecode(json) as Map<String, dynamic>;
        bookId = map['book_id'] as String?;
      } catch (_) {
        bookId = null;
      }
      if (!context.mounted) return;
      // 让书架 / 分组所有相关 providers 立刻刷新
      ref.invalidate(allBooksProvider);
      ref.invalidate(booksByGroupProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(bookId != null && bookId.isNotEmpty
              ? '导入成功 (id: ${bookId.substring(0, bookId.length < 8 ? bookId.length : 8)})'
              : '导入成功'),
        ),
      );
      // 自动跳到 reader（GoRouter `/reader?bookId=...`）
      if (bookId != null && bookId.isNotEmpty && context.mounted) {
        context.push(
          Uri(path: '/reader', queryParameters: {'bookId': bookId}).toString(),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }

  /// 批次 8 (05-19): 排序选择对话框。点 AppBar `Icons.sort` 按钮触发，
  /// 选中后写回 [readerSettingsProvider] 并落盘 [saveReaderSettingsToDisk]。
  /// `bookshelfSortProvider` 是从 readerSettings 派生的 Provider，state 一变
  /// 各 Tab 的 [booksByGroupProvider]`((groupId, sort))` 自然换 key 触发重拉。
  ///
  /// UI 用 ListTile + trailing check 模拟单选；不用 RadioListTile 是因为
  /// Flutter 3.32 后其 groupValue/onChanged 已弃用（与
  /// [GroupSelectDialog] 同模式，避免新增 deprecation warning）。
  Future<void> _showSortDialog(BuildContext context) async {
    final current = ref.read(readerSettingsProvider).bookshelfSort;
    // 0..5 与 Rust BookSort enum 对齐（含 0=Default）。
    const labels = <int, String>{
      0: '默认',
      1: '名称',
      2: '作者',
      3: '加入时间',
      4: '上次阅读',
      5: '章节数',
    };
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) {
        return SimpleDialog(
          title: const Text('书架排序'),
          children: [
            for (final entry in labels.entries)
              ListTile(
                title: Text(entry.value),
                trailing: entry.key == current
                    ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, entry.key),
              ),
          ],
        );
      },
    );
    if (picked == null || picked == current) return;
    final notifier = ref.read(readerSettingsProvider.notifier);
    final updated = notifier.state.copyWith(bookshelfSort: picked);
    notifier.state = updated;
    // 持久化到 settings.json，杀进程重启后保留排序。
    await saveReaderSettingsToDisk(updated);
  }

  /// BATCH-27a (05-22): 书架布局对话框（列表 / 网格）。对齐原 legado
  /// `main_bookshelf.xml:51 menu_bookshelf_layout` →
  /// `BaseBookshelfFragment.kt:115 configBookshelf` 的 2 选行为。
  ///
  /// UI 复用 [_showSortDialog] 同款 SimpleDialog + ListTile + check
  /// trailing 模式（避免新增 deprecation warning，与 BATCH-19a 决策一致）。
  /// 选完写回 [_isGridView] 并落盘 [saveBookshelfGridViewToDisk]，
  /// 与现有 `Icons.list/Icons.grid_view` IconButton 切换路径完全等价。
  Future<void> _showLayoutDialog(BuildContext context) async {
    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return SimpleDialog(
          title: const Text('书架布局'),
          children: [
            for (final entry in const <(bool, String)>[
              (false, '列表'),
              (true, '网格'),
            ])
              ListTile(
                title: Text(entry.$2),
                trailing: _isGridView == entry.$1
                    ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, entry.$1),
              ),
          ],
        );
      },
    );
    if (picked == null || picked == _isGridView) return;
    // setState after await showDialog 必须 mounted check —
    // 用户可能在 dialog 仍打开时退出页面，对齐
    // `.trellis/spec/flutter-app/async-and-mounted.md` Pattern 2.
    safeSetState(() => _isGridView = picked);
    await saveBookshelfGridViewToDisk(_isGridView);
  }

  /// BATCH-27a (05-22): 导出书架 JSON 到 documents_dir/books.json。
  /// 对齐原 legado `BookshelfViewModel.kt:102-128 exportBookshelf`：
  /// 调 FRB [`rust_api.exportBookshelfJson`] 拿 `[{name,author,intro}]`
  /// → 写入 `<docs>/books.json` → SnackBar 显示路径。空书架（`"[]"`）
  /// 不落盘，直接 SnackBar「书架为空」。失败 catch + SnackBar 提示，
  /// 不向上抛打断书架页。
  ///
  /// 走过 `exportBookshelfJsonOverride` / `exportDocumentsDirectoryOverride`
  /// 测试钩子时不依赖 path_provider / FRB；生产路径走默认实现。
  Future<void> _onExportBookshelf(BuildContext context) async {
    try {
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final exportFn = widget.exportBookshelfJsonOverride ??
          ({required String dbPath}) =>
              rust_api.exportBookshelfJson(dbPath: dbPath);
      final json = await exportFn(dbPath: dbPath);
      if (!context.mounted) return;
      // 空书架（pretty 序列化对空数组也只输出 `[]`，无换行）→ 早返回不写文件
      if (json.trim() == '[]') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('书架为空')),
        );
        return;
      }
      // 解析 documents 目录：测试钩子优先；其次 documentsDirOverride（与
      // 导入本地书共用）；最后走 path_provider。
      final String docsDir = widget.exportDocumentsDirectoryOverride ??
          widget.documentsDirOverride ??
          await resolvePersistenceDir();
      final filePath = '$docsDir/books.json';
      final file = File(filePath);
      await file.writeAsString(json);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出到 $filePath')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    }
  }

  /// BATCH-27b (05-22): 当前 Tab 内非本地、可更新的书批量刷目录。
  ///
  /// 对齐原 legado `BaseBookshelfFragment.kt:98 activityViewModel.upToc(books)` +
  /// `MainViewModel.kt:96-180 upToc/startUpTocJob`：
  /// 1. 读当前 tab `(groupId, sortOrder)` → `booksByGroupProvider.future`
  /// 2. filter `!isLocal && canUpdate`（local 判断对齐 import_local_book 落库
  ///    时的 `source_id` 字段；local 书 source_id 是 'local'，远程书是真实
  ///    source UUID。)
  /// 3. 提取 bookIds → `UpdateTocRunner().enqueue(...)`，listen onProgress
  ///    在 [initState] 已挂；这里 fire-and-forget。
  /// 4. 空批早返回 + SnackBar「无可刷新的书」。
  ///
  /// 失败处理：单本失败由 runner 内部静默 catch + log；整批不抛错。结果
  /// 总结 SnackBar 由 [initState] 的 onProgress listener 在 isDone 时弹。
  Future<void> _onUpdateToc(
    BuildContext context,
    List<_TabSpec> tabSpec,
    int sortOrder,
  ) async {
    try {
      final controller = DefaultTabController.maybeOf(context);
      final tabIndex = controller?.index ?? 0;
      if (tabIndex < 0 || tabIndex >= tabSpec.length) {
        return;
      }
      final groupId = tabSpec[tabIndex].groupId;
      final books = await ref
          .read(booksByGroupProvider((groupId, sortOrder)).future);
      if (!context.mounted) return;
      final ids = <String>[];
      for (final b in books) {
        // local 判断：import_local_book 落库时把 source_id 写成 'local'
        // (core/bridge/src/local_book.rs ensure_local_source LOCAL_SOURCE_ID)。
        // 远程书 source_id 是真实 UUID 形态，长度 + 字符集都不会撞。
        // can_update：原 legado Book.canUpdate 默认 true；只在书源类型为
        // 仅本地或用户手动关闭时为 false。Dart 端 schema 字段名是
        // `can_update`（snake_case，与 storage::Book serde 输出一致）。
        final sourceId = (b['source_id'] as String?)?.trim() ?? '';
        if (sourceId.isEmpty || sourceId == 'local') continue;
        final canUpdate = b['can_update'];
        if (canUpdate is bool && !canUpdate) continue;
        if (canUpdate is num && canUpdate == 0) continue;
        final id = (b['id'] as String?) ?? '';
        if (id.isEmpty) continue;
        ids.add(id);
      }
      if (ids.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前 Tab 无可刷新的书')),
        );
        return;
      }
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      if (!context.mounted) return;
      // ignore: discarded_futures — enqueue 内部 fire-and-forget 启 worker，
      // 调用方靠 onProgress 监听完成；此处不能 await，否则 SnackBar 在
      // 跑完前不会弹。
      UpdateTocRunner().enqueue(
        ids,
        dbPath: dbPath,
        overrideFn: widget.updateBookTocOverride,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已开始刷新目录（${ids.length} 本）')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('刷新目录失败: $e')),
      );
    }
  }

  /// BATCH-27e (05-22): 添加网络URL — 单 URL add 入口。
  Future<void> _onAddUrl(BuildContext context) async {
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => const _AddUrlDialog(),
    );
    if (text == null || text.trim().isEmpty) return;
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final urls = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (urls.isEmpty) return;

    int success = 0;
    int fail = 0;
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);

      for (final url in urls) {
        try {
          final sourceJson = await rust_api.findBookSourceForUrl(
            dbPath: dbPath,
            bookUrl: url,
          );
          if (sourceJson == null) {
            fail++;
            continue;
          }
          final infoJson = await rust_api.getBookInfoOnline(
            sourceJson: sourceJson,
            bookUrl: url,
          );
          await rust_api.saveBook(
            dbPath: dbPath,
            bookJson: infoJson,
          );
          success++;
        } catch (e) {
          debugPrint('[add_url] $url failed: $e');
          fail++;
        }
      }
      if (!context.mounted) return;
      ref.invalidate(allBooksProvider);
      ref.invalidate(booksByGroupProvider);
      messenger.showSnackBar(
        SnackBar(content: Text('添加完成：成功 $success / 失败 $fail')),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }

  /// BATCH-27e (05-22): 导入书架 — 三选一 SimpleDialog（粘贴 / 文件 / URL）。
  /// BATCH-29: 加 URL 导入选项（HTTP GET → parse JSON）。
  Future<void> _onImportBookshelf(BuildContext context) async {
    final choice = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('导入书架'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(1),
            child: const Text('手动粘贴 JSON'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(2),
            child: const Text('从文件导入'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(3),
            child: const Text('从 URL 导入'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (!context.mounted) return;

    String? text;
    if (choice == 1) {
      text = await showDialog<String>(
        context: context,
        builder: (ctx) => const _PasteBookshelfJsonDialog(),
      );
    } else if (choice == 2) {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      text = await File(file.path!).readAsString();
    } else {
      text = await showDialog<String>(
        context: context,
        builder: (ctx) => const _UrlImportDialog(),
      );
      if (text != null && text.isNotEmpty) {
        try {
          final client = HttpClient();
          final request = await client.getUrl(Uri.parse(text.trim()));
          final response = await request.close();
          text = await response.transform(utf8.decoder).join();
          client.close();
        } catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('URL 请求失败: $e')),
          );
          return;
        }
      }
    }
    if (text == null || text.trim().isEmpty) return;
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);

      final dynamic raw = jsonDecode(text);
      if (raw is! List) {
        messenger.showSnackBar(
          const SnackBar(content: Text('格式不对：需要 JSON 数组')),
        );
        return;
      }
      final books = raw.whereType<Map>().toList();
      if (books.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('书单为空')),
        );
        return;
      }

      int success = 0;
      int skip = 0;
      int fail = 0;
      final enabledJson = await rust_api.getEnabledSources(dbPath: dbPath);
      final sources = jsonDecode(enabledJson);
      if (sources is! List || sources.isEmpty) {
        if (!context.mounted) return;
        messenger.showSnackBar(
          const SnackBar(content: Text('没有启用的书源')),
        );
        return;
      }
      for (final item in books) {
        final name = (item['name'] as String?)?.trim() ?? '';
        if (name.isEmpty) {
          skip++;
          continue;
        }
        try {
          Map<String, dynamic>? matched;
          for (final s in sources) {
            if (s is! Map) continue;
            final sid = (s['id'] as String?) ?? '';
            if (sid.isEmpty) continue;
            final resultJson = await rust_api.searchWithSourceFromDb(
              dbPath: dbPath,
              sourceId: sid,
              keyword: name,
            );
            final results = jsonDecode(resultJson);
            if (results is List && results.isNotEmpty) {
              matched = results.first as Map<String, dynamic>;
              break;
            }
          }
          if (matched == null) {
            fail++;
            continue;
          }
          await rust_api.saveBook(
            dbPath: dbPath,
            bookJson: jsonEncode(matched),
          );
          success++;
        } catch (e) {
          debugPrint('[import_bookshelf] $name failed: $e');
          fail++;
        }
      }
      if (!context.mounted) return;
      ref.invalidate(allBooksProvider);
      ref.invalidate(booksByGroupProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text('导入完成：成功 $success / 跳过 $skip / 失败 $fail'),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }
}

/// 单个 Tab 内的书列表视图。
///
/// 抽出独立 widget 以便每个 Tab 通过 [booksByGroupProvider]`((groupId, sortOrder))`
/// 各自拿数据，互不污染缓存。`isGridView` 由父级 [BookshelfPage] 全局
/// 控制（"列表/网格"切换是用户在所有 Tab 间共享的偏好）；`sortOrder`
/// 同样全局共享（批次 8）。
class _BookListView extends ConsumerWidget {
  final int groupId;
  final int sortOrder;
  final bool isGridView;

  const _BookListView({
    required this.groupId,
    required this.sortOrder,
    required this.isGridView,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(booksByGroupProvider((groupId, sortOrder)));
    return booksAsync.when(
      data: (books) => _buildBookList(context, ref, books),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败: $e')),
    );
  }

  Widget _buildBookList(BuildContext context, WidgetRef ref,
      List<Map<String, dynamic>> books) {
    if (books.isEmpty) {
      return const Center(child: Text('书架为空，去搜索添加书籍吧'));
    }
    if (isGridView) {
      return _buildGridView(context, ref, books);
    }
    return _buildListView(context, ref, books);
  }

  Widget _buildListView(
      BuildContext context, WidgetRef ref, List<Map<String, dynamic>> books) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return _buildListTileItem(context, ref, book);
      },
    );
  }

  /// Redesigned list-tile item matching the reference design:
  /// - 80×120 cover (rounded 12px, gradient placeholder)
  /// - Title 16px/w500/max 2 lines
  /// - Author row with person icon
  /// - Chapter row with radio_button_unchecked icon
  /// - Right-aligned progress badge chip
  /// - Subtle bottom border
  Widget _buildListTileItem(
      BuildContext context, WidgetRef ref, Map<String, dynamic> book) {
    final name = book['name'] as String? ?? '未知书名';
    final author = book['author'] as String? ?? '';
    final durTitle = book['dur_chapter_title'] as String?;
    final chapterCount = book['chapter_count'] as num? ?? 0;
    final bookId = book['id'] as String? ?? '';
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () => context.push(
        Uri(path: '/reader', queryParameters: {'bookId': bookId}).toString(),
      ),
      onLongPress: () => _showBookActionSheet(context, ref, book),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Cover: 80×120, aspect 2:3, rounded 12px
                _buildListCover(context, book),
                const SizedBox(width: 16),
                // Info area (expanded) - reserve space for badge
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (author.isNotEmpty)
                          Row(
                            children: [
                              Icon(Icons.person,
                                  size: 14, color: context.al.textSecondary),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  author,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.al.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        if (durTitle != null && durTitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(Icons.radio_button_unchecked,
                                  size: 12, color: context.al.textSecondary),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  durTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.al.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
            // Progress badge: absolutely positioned on right side, vertically centered
            if (chapterCount > 0)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$chapterCount',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: context.al.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// List-view cover: 80×120 (aspect 2:3), rounded 12px corners.
  /// Falls back to a gradient placeholder with the book title's first
  /// character when no image is available.
  Widget _buildListCover(BuildContext context, Map<String, dynamic> book) {
    final name = book['name'] as String? ?? '';
    final localPath = book['custom_cover_path'] as String?;
    final coverUrl = book['cover_url'] as String?;

    Widget child;

    if (localPath != null && localPath.isNotEmpty) {
      child = Image.file(
        File(localPath),
        fit: BoxFit.cover,
        width: 80,
        height: 120,
        cacheWidth: 80,
        cacheHeight: 120,
        errorBuilder: (_, __, ___) =>
            _buildListCoverPlaceholder(context, name),
      );
    } else if (coverUrl != null && coverUrl.isNotEmpty) {
      child = CachedNetworkImage(
        imageUrl: coverUrl,
        fit: BoxFit.cover,
        width: 80,
        height: 120,
        memCacheWidth: 80,
        memCacheHeight: 120,
        placeholder: (_, __) => _buildListCoverPlaceholder(context, name),
        errorWidget: (_, __, ___) =>
            _buildListCoverPlaceholder(context, name),
      );
    } else {
      child = _buildListCoverPlaceholder(context, name);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(width: 80, height: 120, child: child),
    );
  }

  /// Gradient placeholder for the list-view cover when no image is
  /// available. Shows the first character of the book title centred
  /// within an 80×120 container.
  Widget _buildListCoverPlaceholder(BuildContext context, String name) {
    final colorScheme = Theme.of(context).colorScheme;
    final initials = name.isNotEmpty ? name[0] : '';

    return Container(
      width: 80,
      height: 120,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.secondaryContainer,
          ],
        ),
      ),
      child: Center(
        child: Text(
          initials,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }

  Widget _buildGridView(
      BuildContext context, WidgetRef ref, List<Map<String, dynamic>> books) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.52,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        final name = book['name'] as String? ?? '未知书名';
        final chapterCount = book['chapter_count'] as num? ?? 0;
        final bookId = book['id'] as String? ?? '';
        final colorScheme = Theme.of(context).colorScheme;

        return GestureDetector(
          onTap: () => context.push(
            Uri(path: '/reader',
                queryParameters: {'bookId': bookId}).toString(),
          ),
          onLongPress: () => _showBookActionSheet(context, ref, book),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildGridCover(context, book, name, chapterCount),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 34,
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGridCover(BuildContext context, Map<String, dynamic> book,
      String name, num chapterCount) {
    final localPath = book['custom_cover_path'] as String?;
    final coverUrl = book['cover_url'] as String?;
    final colorScheme = Theme.of(context).colorScheme;
    final initials = name.isNotEmpty ? name[0] : '';

    Widget imageChild;
    if (localPath != null && localPath.isNotEmpty) {
      imageChild = Image.file(
        File(localPath),
        fit: BoxFit.cover,
        cacheWidth: 120,
        cacheHeight: 180,
      );
    } else if (coverUrl != null && coverUrl.isNotEmpty) {
      imageChild = CachedNetworkImage(
        imageUrl: coverUrl,
        fit: BoxFit.cover,
        memCacheWidth: 120,
        memCacheHeight: 180,
        placeholder: (_, __) =>
            _gridCoverPlaceholder(colorScheme, initials),
        errorWidget: (_, __, ___) =>
            _gridCoverPlaceholder(colorScheme, initials),
      );
    } else {
      imageChild = _gridCoverPlaceholder(colorScheme, initials);
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withAlpha(0x14),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          imageChild,
          if (chapterCount > 0)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(0x26),
                      blurRadius: 3,
                    ),
                  ],
                ),
                child: Text(
                  '$chapterCount',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _gridCoverPlaceholder(ColorScheme cs, String initials) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primaryContainer, cs.secondaryContainer],
        ),
      ),
      child: Center(
        child: Text(
          initials,
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: cs.onPrimaryContainer.withAlpha(0x80),
          ),
        ),
      ),
    );
  }

  /// 长按书条弹底部 Sheet：移动到分组 / 删除。
  /// 抽出独立方法是因为列表 / 网格两套渲染都需要复用同一份动作菜单。
  Future<void> _showBookActionSheet(
      BuildContext context, WidgetRef ref, Map<String, dynamic> book) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移动到分组'),
              onTap: () => Navigator.pop(ctx, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑信息'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: context.al.destructive),
              title: Text('删除', style: TextStyle(color: context.al.destructive)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'move') {
      await _moveBookToGroup(context, ref, book);
    } else if (action == 'edit') {
      final bookId = book['id'] as String?;
      if (bookId != null && bookId.isNotEmpty) {
        context.push(
          Uri(path: '/book-info-edit', queryParameters: {'bookId': bookId})
              .toString(),
        );
      }
    } else if (action == 'delete') {
      await _deleteBook(context, ref, book);
    }
  }

  Future<void> _moveBookToGroup(BuildContext context, WidgetRef ref,
      Map<String, dynamic> book) async {
    final currentGroupId = (book['group_id'] as num?)?.toInt() ?? 0;
    final newGroupId = await showDialog<int>(
      context: context,
      builder: (_) => GroupSelectDialog(currentGroupId: currentGroupId),
    );
    if (newGroupId == null || newGroupId == currentGroupId) return;
    if (!context.mounted) return;
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      final bookId = book['id'] as String?;
      if (bookId == null || bookId.isEmpty) return;
      await rust_api.setBookGroup(
        dbPath: dbPath,
        bookId: bookId,
        groupId: newGroupId,
      );
      // 刷新所有分组的书列表（旧分组要少一本，新分组要多一本）
      ref.invalidate(booksByGroupProvider);
      ref.invalidate(allBooksProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已移动到目标分组')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移动失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteBook(BuildContext context, WidgetRef ref,
      Map<String, dynamic> book) async {
    final name = book['name'] as String? ?? '未知';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要把《$name》从书架中删除吗？\n\n该操作会同时删除章节缓存和阅读进度。'),
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
    if (!context.mounted) return;
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      final bookId = book['id'] as String?;
      if (bookId == null || bookId.isEmpty) return;
      await rust_api.deleteBook(dbPath: dbPath, id: bookId);
      ref.invalidate(allBooksProvider);
      ref.invalidate(booksByGroupProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除《$name》')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }
}

/// BATCH-27e (05-22): add_url 的 URL 输入对话框。
class _AddUrlDialog extends StatefulWidget {
  const _AddUrlDialog();

  @override
  State<_AddUrlDialog> createState() => _AddUrlDialogState();
}

class _AddUrlDialogState extends State<_AddUrlDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加网络URL'),
      content: TextField(
        controller: _ctrl,
        maxLines: 5,
        decoration: const InputDecoration(
          hintText: 'https://example.com/book/123\nhttps://example.com/book/456',
          labelText: '书籍URL（每行一个）',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final text = _ctrl.text.trim();
            if (text.isEmpty) return;
            Navigator.of(context).pop(text);
          },
          child: const Text('添加'),
        ),
      ],
    );
  }
}

/// BATCH-27e (05-22): import_bookshelf 的 JSON 粘贴对话框。
class _PasteBookshelfJsonDialog extends StatefulWidget {
  const _PasteBookshelfJsonDialog();

  @override
  State<_PasteBookshelfJsonDialog> createState() =>
      _PasteBookshelfJsonDialogState();
}

class _PasteBookshelfJsonDialogState extends State<_PasteBookshelfJsonDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('粘贴书架 JSON'),
      content: TextField(
        controller: _ctrl,
        maxLines: 10,
        decoration: const InputDecoration(
          hintText: '[{"name": "书名", "author": "作者"}, ...]',
          labelText: 'JSON 数组',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(_ctrl.text);
          },
          child: const Text('导入'),
        ),
      ],
    );
  }
}

/// BATCH-29: import_bookshelf 的 URL 导入对话框。
class _UrlImportDialog extends StatefulWidget {
  const _UrlImportDialog();

  @override
  State<_UrlImportDialog> createState() => _UrlImportDialogState();
}

class _UrlImportDialogState extends State<_UrlImportDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('从 URL 导入'),
      content: TextField(
        controller: _ctrl,
        decoration: const InputDecoration(
          hintText: 'https://example.com/bookshelf.json',
          labelText: 'JSON URL',
        ),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final text = _ctrl.text.trim();
            if (text.isEmpty) return;
            Navigator.of(context).pop(text);
          },
          child: const Text('获取'),
        ),
      ],
    );
  }
}

// ── Menu helpers ───────────────────────────────────────────────────

Widget _overlayMenuItem(BuildContext ctx, String value, IconData icon,
    String label, VoidCallback onTap) {
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: _BookMenuRow(icon: icon, label: label),
    ),
  );
}

Widget _overlayDisabledMenuItem(
    BuildContext ctx, IconData icon, String label) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
    child: Opacity(
      opacity: 0.38,
      child: _BookMenuRow(icon: icon, label: label),
    ),
  );
}

class _BookMenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _BookMenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Icon(icon, size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 14),
          Text(label,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface,
              )),
        ],
      ),
    );
  }
}

class _TabSpec {
  final String label;
  final int groupId;
  const _TabSpec({required this.label, required this.groupId});
}
