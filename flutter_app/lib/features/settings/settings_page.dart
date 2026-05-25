import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/notification_service.dart';
import '../../core/color_scheme_config.dart';
import '../../core/providers.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage>
    with WidgetsBindingObserver {
  bool _notificationPermissionGranted = false;
  bool _isCheckingPermission = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNotificationPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkNotificationPermission();
      clearPendingRoute();
    }
  }

  Future<void> _checkNotificationPermission() async {
    final granted = await NotificationService.hasPermission();
    if (!mounted) return;
    setState(() {
      _notificationPermissionGranted = granted;
      _isCheckingPermission = false;
    });
  }

  Future<void> _onNotificationSwitchToggled(bool value) async {
    if (value) {
      final granted = await NotificationService.requestPermission();
      if (!mounted) return;
      setState(() => _notificationPermissionGranted = granted);
      // BATCH-20 (F-W2B-003)：删冗余 if (mounted) 包装，line 53 已 early-return
      // 后续不需要再 check；统一 if (!mounted) return; early-return 风格。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(granted ? '通知权限已开启' : '通知权限请求被拒绝'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      // value 来自 Switch 异步回调，从规范角度 dialog 入口前补一次 mounted check。
      if (!mounted) return;
      _showDisableNotificationDialog();
    }
  }

  void _showDisableNotificationDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关闭通知'),
        content: const Text('请在系统设置中关闭通知权限'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              savePendingRoute('/settings');
              NotificationService.openNotificationSettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView.builder(
        itemCount: 29,
        itemBuilder: (context, index) => _buildSettingItem(
          context,
          index,
          colorScheme,
        ),
      ),
    );
  }

  Widget _buildSettingItem(
    BuildContext context,
    int index,
    ColorScheme colorScheme,
  ) {
    switch (index) {
      case 0:
        return const _SectionHeader(title: '通知');
      case 1:
        return ListTile(
          leading: Icon(
            _notificationPermissionGranted
                ? Icons.notifications_active
                : Icons.notifications_off_outlined,
            color: _notificationPermissionGranted
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          title: const Text('通知权限'),
          subtitle: Text(
            _isCheckingPermission
                ? '检查中...'
                : _notificationPermissionGranted
                    ? '已授权'
                    : '未授权（点击开启）',
          ),
          trailing: Switch(
            value: _notificationPermissionGranted,
            onChanged:
                _isCheckingPermission ? null : _onNotificationSwitchToggled,
          ),
        );
      case 2:
        return const Divider(indent: 16, endIndent: 16);
      case 3:
        return const _SectionHeader(title: '显示');
      case 4:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Icon(Icons.format_size),
              const SizedBox(width: 12),
              const Text('字体大小'),
              const SizedBox(width: 8),
              Text(
                '${ref.watch(fontSizeProvider).round()}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Expanded(
                child: Slider(
                  value: ref.watch(fontSizeProvider),
                  min: 14,
                  max: 28,
                  divisions: 14,
                  label: '${ref.watch(fontSizeProvider).round()}',
                  onChanged: (value) {
                    // BATCH-18d (F-W2A-008)：派生 fontSizeProvider 后，
                    // 字号写入必须走 readerSettingsProvider；这样 reader
                    // 端与 settings 页共享同一 source of truth。
                    final notifier = ref.read(readerSettingsProvider.notifier);
                    notifier.state = notifier.state.copyWith(fontSize: value);
                    saveReaderSettingsToDisk(notifier.state);
                  },
                ),
              ),
            ],
          ),
        );
      case 5:
        return const SizedBox(height: 8);
      case 6:
        return RadioGroup<ThemeMode>(
          groupValue: ref.watch(themeModeProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(themeModeProvider.notifier).state = value;
              saveThemeModeToDisk(value);
            }
          },
          child: Column(
            children: ThemeMode.values
                .map(
                  (mode) => RadioListTile<ThemeMode>(
                    title: Text(_themeModeLabel(mode)),
                    value: mode,
                    secondary: Icon(_themeModeIcon(mode)),
                  ),
                )
                .toList(),
          ),
        );
      case 7:
        return const Divider(indent: 16, endIndent: 16);
      case 8:
        return const _SectionHeader(title: '主题色');
      case 9:
        return const _ColorPickerSection();
      case 10:
        return const Divider(indent: 16, endIndent: 16);
      case 11:
        return const _SectionHeader(title: '主页');
      case 12:
        return SwitchListTile(
          secondary: const Icon(Icons.explore_outlined),
          title: const Text('显示「发现」'),
          subtitle: const Text('底栏显示「发现」tab'),
          value: ref.watch(showDiscoveryProvider),
          onChanged: (v) {
            ref.read(showDiscoveryProvider.notifier).state = v;
            saveShowDiscoveryToDisk(v);
          },
        );
      case 13:
        return SwitchListTile(
          secondary: const Icon(Icons.rss_feed_outlined),
          title: const Text('显示「订阅」'),
          subtitle: const Text('底栏显示「订阅」tab'),
          value: ref.watch(showRssProvider),
          onChanged: (v) {
            ref.read(showRssProvider.notifier).state = v;
            saveShowRssToDisk(v);
          },
        );
      case 14:
        return ListTile(
          leading: const Icon(Icons.home_outlined),
          title: const Text('启动默认页'),
          subtitle: Text(ref.watch(defaultHomePageProvider).label),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showDefaultHomePageDialog(context),
        );
      case 15:
        return SwitchListTile(
          secondary: const Icon(Icons.menu_book_outlined),
          title: const Text('点书名直接打开阅读'),
          subtitle: const Text('「书架管理」页点书名时直接进入阅读'),
          value: ref.watch(bookshelfManageOpenReaderProvider),
          onChanged: (v) {
            ref.read(bookshelfManageOpenReaderProvider.notifier).state = v;
            saveBookshelfManageOpenReaderToDisk(v);
          },
        );
      case 16:
        return const Divider(indent: 16, endIndent: 16);
      case 17:
        return const _SectionHeader(title: '工具');
      case 18:
        return ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: const Text('备份/恢复'),
          subtitle: const Text('导出/导入书架数据到 zip'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/backup'),
        );
      case 19:
        return ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('阅读统计'),
          subtitle: const Text('查看阅读时长'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/read-stats'),
        );
      case 20:
        return ListTile(
          leading: const Icon(Icons.cleaning_services_outlined),
          title: const Text('缓存管理'),
          subtitle: const Text('清理章节内容缓存'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/cache-management'),
        );
      case 21:
        return ListTile(
          leading: const Icon(Icons.star_outline),
          title: const Text('RSS 收藏'),
          subtitle: const Text('已收藏的 RSS 文章'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/rss-favorites'),
        );
      case 22:
        return ListTile(
          leading: const Icon(Icons.cloud_sync_outlined),
          title: const Text('订阅源'),
          subtitle: const Text('RuleSub 订阅管理'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/rule-subs'),
        );
      case 23:
        return ListTile(
          leading: const Icon(Icons.rule),
          title: const Text('替换规则'),
          subtitle: const Text('管理正则替换规则'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/replace-rules'),
        );
      case 24:
        return ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('诊断日志'),
          subtitle: const Text('查看、导出或清空本地诊断记录'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/diagnostics'),
        );
      case 25:
        return const Divider(indent: 16, endIndent: 16);
      case 26:
        return const _SectionHeader(title: '关于');
      case 27:
        return const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Legado Reader'),
          subtitle: Text('版本 0.1.0'),
        );
      case 28:
        return const ListTile(
          leading: Icon(Icons.code),
          title: Text('技术栈'),
          subtitle: Text('Flutter + Rust (flutter_rust_bridge)'),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return '跟随系统';
      case ThemeMode.light:
        return '浅色模式';
      case ThemeMode.dark:
        return '深色模式';
    }
  }

  IconData _themeModeIcon(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return Icons.brightness_auto;
      case ThemeMode.light:
        return Icons.light_mode;
      case ThemeMode.dark:
        return Icons.dark_mode;
    }
  }

  /// BATCH-26d (05-22): 启动默认页 4 选对话框。模式参考
  /// [`bookshelf_page._showSortDialog`]：用 `SimpleDialog` + `ListTile +
  /// trailing Icons.check + Navigator.pop(ctx, value)`，不用已 deprecated
  /// 的 `RadioListTile.groupValue/onChanged`（对齐 BATCH-19a 决策）。
  ///
  /// 选完写 provider + 持久化，并 SnackBar 提示「下次启动生效」（用户
  /// 感知不到立即效果，要重启后才走 [applyDefaultHomePage] 跳转）。
  Future<void> _showDefaultHomePageDialog(BuildContext context) async {
    final current = ref.read(defaultHomePageProvider);
    final picked = await showDialog<DefaultHomePage>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('启动默认页'),
        children: [
          for (final v in DefaultHomePage.values)
            ListTile(
              title: Text(v.label),
              trailing: v == current
                  ? Icon(
                      Icons.check,
                      color: Theme.of(ctx).colorScheme.primary,
                    )
                  : null,
              onTap: () => Navigator.pop(ctx, v),
            ),
        ],
      ),
    );
    if (picked == null || picked == current) return;
    ref.read(defaultHomePageProvider.notifier).state = picked;
    // showDialog 结束后回到本页，await 后必须复查 mounted。
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已设为「${picked.label}」(下次启动生效)')),
    );
    // 持久化 fire-and-forget（与 26c 的 saveShowDiscoveryToDisk /
    // saveShowRssToDisk / 书架 grid view 同模式：不 await 写盘，让 UX
    // 立刻反馈，写失败由 errorTag 走 debugPrint）。
    saveDefaultHomePageToDisk(picked);
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
      ),
    );
  }
}

// ── Color picker section ───────────────────────────────────────────

class _ColorPickerSection extends ConsumerWidget {
  const _ColorPickerSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(colorSchemeConfigProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.wallpaper),
          title: const Text('莫奈动态取色'),
          subtitle: const Text('跟随系统壁纸自动生成配色（Android 12+）'),
          value: config.source == ColorSource.dynamic_,
          onChanged: (v) {
            ref
                .read(colorSchemeConfigProvider.notifier)
                .setSource(v ? ColorSource.dynamic_ : ColorSource.preset);
          },
        ),
        if (config.source == ColorSource.preset) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: presetSeedColors.map((color) {
                final selected = config.presetSeed == color.toARGB32();
                return GestureDetector(
                  onTap: () {
                    ref
                        .read(colorSchemeConfigProvider.notifier)
                        .setPresetSeed(color.toARGB32());
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                        width: 3,
                      ),
                      boxShadow: selected
                          ? [
                              BoxShadow(
                                color: color.withAlpha(0x60),
                                blurRadius: 8,
                                spreadRadius: 1,
                              )
                            ]
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
