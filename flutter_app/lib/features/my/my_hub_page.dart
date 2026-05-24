import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 「我的」hub 页（BATCH-26b / 05-22, HTML-ui-alignment 05-24）。
///
/// 1:1 复刻原 legado/ Android `pref_main.xml` 14 项 + 3 分组结构：
/// - 第一组（无 header）：书源管理 / TXT 目录规则 / 替换净化 /
///   字典规则 / 主题模式 / Web 服务（SwitchListTile）
/// - 「设置」分组：备份与恢复 / 主题设置 / 其他设置
/// - 「其它」分组：书签 / 阅读记录 / 文件管理 / 关于 / 退出
///
/// 已实现 5 项（书源管理 / 替换净化 / 备份与恢复 / 其他设置 / 阅读记录）
/// onTap 跳现有 GoRoute；其余 9 项灰显（`enabled: false` + onTap 不写 /
/// SwitchListTile.onChanged: null）。占位策略对齐父 PRD R6：不弹
/// SnackBar，让对照原版 14 项可见。BATCH-26b 不引入 ViewModel/Provider，
/// 与 26a 占位风格一致；私有 `_SectionHeader` 与 settings_page 的同名
/// widget 同模式（不 import 避免 features 间互相依赖）。
class MyHubPage extends StatelessWidget {
  const MyHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final subtitleStyle = TextStyle(
      fontSize: 12,
      color: colorScheme.onSurfaceVariant,
    );

    Widget leadingIcon(IconData icon) => SizedBox(
          width: 24,
          height: 24,
          child: Icon(icon, color: colorScheme.primary),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '我的',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w400),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: '帮助',
            onPressed: null,
          ),
        ],
      ),
      body: ListView(
        children: [
          // 第一组（无 header）
          ListTile(
            leading: leadingIcon(Icons.source_outlined),
            title: const Text('书源管理', style: _kTitleTextStyle),
            subtitle: Text('管理书源', style: subtitleStyle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/sources'),
          ),
          ListTile(
            enabled: false,
            leading: leadingIcon(Icons.format_list_numbered),
            title: const Text('TXT 目录规则', style: _kTitleTextStyle),
            subtitle: Text('配置 txt 章节匹配', style: subtitleStyle),
            trailing: const Icon(Icons.chevron_right),
          ),
          ListTile(
            leading: leadingIcon(Icons.find_replace),
            title: const Text('替换净化', style: _kTitleTextStyle),
            subtitle: Text('管理正则替换规则', style: subtitleStyle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/replace-rules'),
          ),
          ListTile(
            enabled: false,
            leading: leadingIcon(Icons.translate),
            title: const Text('字典规则', style: _kTitleTextStyle),
            subtitle: Text('配置词典查询', style: subtitleStyle),
            trailing: const Icon(Icons.chevron_right),
          ),
          ListTile(
            enabled: false,
            leading: leadingIcon(Icons.brightness_6_outlined),
            title: const Text('主题模式', style: _kTitleTextStyle),
            subtitle: Text('跟随系统/亮/暗', style: subtitleStyle),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                '跟随系统',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          SwitchListTile(
            value: false,
            onChanged: null,
            secondary: leadingIcon(Icons.web),
            title: const Text('Web 服务', style: _kTitleTextStyle),
            subtitle: Text('局域网内 HTTP 服务', style: subtitleStyle),
          ),

          const Divider(height: 1, thickness: 0.5, indent: 16, endIndent: 16),
          // 「设置」分组
          const _SectionHeader(title: '设置'),
          ListTile(
            leading: leadingIcon(Icons.settings_backup_restore),
            title: const Text('备份与恢复', style: _kTitleTextStyle),
            subtitle: Text('WebDAV 同步与本地 zip', style: subtitleStyle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/backup'),
          ),
          ListTile(
            enabled: false,
            leading: leadingIcon(Icons.palette_outlined),
            title: const Text('主题设置', style: _kTitleTextStyle),
            subtitle: Text('配色 / 排版', style: subtitleStyle),
            trailing: const Icon(Icons.chevron_right),
          ),
          ListTile(
            leading: leadingIcon(Icons.tune),
            title: const Text('其他设置', style: _kTitleTextStyle),
            subtitle: Text('通用设置', style: subtitleStyle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings'),
          ),

          const Divider(height: 1, thickness: 0.5, indent: 16, endIndent: 16),
          // 「其它」分组
          const _SectionHeader(title: '其它'),
          ListTile(
            enabled: false,
            leading: leadingIcon(Icons.bookmark_outline),
            title: const Text('书签', style: _kTitleTextStyle),
            subtitle: Text('全局书签列表', style: subtitleStyle),
            trailing: const Icon(Icons.chevron_right),
          ),
          ListTile(
            leading: leadingIcon(Icons.history),
            title: const Text('阅读记录', style: _kTitleTextStyle),
            subtitle: Text('累计阅读时长', style: subtitleStyle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/read-stats'),
          ),
          ListTile(
            enabled: false,
            leading: leadingIcon(Icons.folder_outlined),
            title: const Text('文件管理', style: _kTitleTextStyle),
            subtitle: Text('应用内文件浏览器', style: subtitleStyle),
            trailing: const Icon(Icons.chevron_right),
          ),
          ListTile(
            enabled: false,
            leading: leadingIcon(Icons.info_outline),
            title: const Text('关于', style: _kTitleTextStyle),
            subtitle: Text('版本 / 致谢', style: subtitleStyle),
            trailing: const Icon(Icons.chevron_right),
          ),
          ListTile(
            enabled: false,
            leading: leadingIcon(Icons.exit_to_app),
            title: const Text('退出', style: _kTitleTextStyle),
            trailing: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

const TextStyle _kTitleTextStyle = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w500,
);

/// 与 settings_page 私有 `_SectionHeader` 同模式（Padding + Text +
/// color: primary）。BATCH-26b 不 import settings_page —— features 间不互相
/// 依赖，重写一份保持本 file 自洽。
///
/// 05-24 HTML-ui-alignment: fontSize 12, fontWeight w500, letterSpacing 0.5,
/// padding fromLTRB(16, 16, 16, 8).
class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
