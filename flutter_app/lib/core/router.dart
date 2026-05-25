import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';
import '../features/bookshelf/bookshelf_page.dart';
import '../features/bookshelf/book_info_edit_page.dart';
import '../features/explore/explore_page.dart';
import '../features/my/my_hub_page.dart';
import '../features/reader/reader_page.dart';
import '../features/search/search_page.dart';
import '../features/settings/backup_page.dart';
import '../features/settings/cache_management_page.dart';
import '../features/settings/read_stats_page.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/webdav_config_page.dart';
import '../features/source/source_page.dart';
import '../features/source/source_check_progress_page.dart';
import '../features/download/download_page.dart';
import '../features/replace_rule/replace_rule_page.dart';
import '../features/rss/rss_article_list_page.dart';
import '../features/rss/rss_article_detail_page.dart';
import '../features/rss/rss_favorites_page.dart';
import '../features/rss/rss_source_manage_page.dart';
import '../features/rss/rss_tab_page.dart';
import '../features/rule_sub/rule_sub_page.dart';
import '../features/qr/qr_scan_page.dart';
import '../features/remote_books/remote_books_page.dart';
import '../features/bookshelf/bookshelf_manage_page.dart';
import '../features/settings/diagnostics_page.dart';

final router = GoRouter(
  initialLocation: '/bookshelf',
  routes: [
    // BATCH-26a (05-22): 顶层 5 tab → 4 tab 重构。对齐原 legado
    // `main_bnv.xml`（书架 / 发现 / 订阅 / 我的）。
    // /search /sources /downloads /settings 退出 ShellBranch，下移到顶级
    // GoRoute；从 bookshelf AppBar IconButton / hub ListTile / PopupMenu
    // 入。
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          _AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/bookshelf',
              builder: (context, state) => const BookshelfPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/explore',
              builder: (context, state) => const ExplorePage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/rss',
              builder: (context, state) => const RssTabPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/my',
              builder: (context, state) => const MyHubPage(),
            ),
          ],
        ),
      ],
    ),
    // BATCH-26a (05-22): 原 ShellBranch 的 4 个路由全部下移为顶级
    // GoRoute，path / builder 不变。/search 由 bookshelf AppBar search
    // IconButton 入；/sources /settings 走 hub（BATCH-26b 填）；
    // /downloads 由 bookshelf PopupMenu「缓存/导出」入。
    GoRoute(
      path: '/search',
      builder: (context, state) => const SearchPage(),
    ),
    GoRoute(
      path: '/sources',
      builder: (context, state) => const SourcePage(),
    ),
    GoRoute(
      path: '/source-check-progress',
      builder: (context, state) {
        final args = state.extra;
        if (args is SourceCheckProgressArgs) {
          return SourceCheckProgressPage(args: args);
        }
        return const SourcePage();
      },
    ),
    GoRoute(
      path: '/downloads',
      builder: (context, state) => const DownloadPage(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsPage(),
    ),
    GoRoute(
      path: '/reader',
      builder: (context, state) {
        final bookId = state.uri.queryParameters['bookId'] ?? '';
        final chapterIndex =
            int.tryParse(state.uri.queryParameters['chapterIndex'] ?? '0') ?? 0;
        return ReaderPage(bookId: bookId, chapterIndex: chapterIndex);
      },
    ),
    GoRoute(
      path: '/replace-rules',
      builder: (context, state) => const ReplaceRulePage(),
    ),
    // 批次 9 (05-19): 书信息编辑页。bookId 通过 query param 传入；页面内
    // 用 [bookByIdProvider] 拉完整 book Map 初始化 5 个 TextField。
    GoRoute(
      path: '/book-info-edit',
      builder: (context, state) {
        final bookId = state.uri.queryParameters['bookId'] ?? '';
        return BookInfoEditPage(bookId: bookId);
      },
    ),
    // 批次 10 (05-19): 本地备份/恢复页。导出 zip / 选 zip 导入。
    GoRoute(
      path: '/backup',
      builder: (context, state) => const BackupPage(),
    ),
    // 批次 11 (05-19): WebDAV 同步配置页。URL/账号/密码/设备名 4 字段。
    GoRoute(
      path: '/webdav-config',
      builder: (context, state) => const WebDavConfigPage(),
    ),
    // 批次 14 (05-19): 阅读统计页。bookshelf_page PopupMenu 入口。
    GoRoute(
      path: '/read-stats',
      builder: (context, state) => const ReadStatsPage(),
    ),
    // 批次 15 (05-19): 缓存管理页。bookshelf_page PopupMenu 入口。
    GoRoute(
      path: '/cache-management',
      builder: (context, state) => const CacheManagementPage(),
    ),
    // 批次 16 (05-19): RSS 源管理页。BATCH-26a 后入口改由 RSS tab AppBar
    // 「RSS 源设置」IconButton 进入（原 bookshelf PopupMenu 入口已撤）。
    GoRoute(
      path: '/rss-source-manage',
      builder: (context, state) => const RssSourceManagePage(),
    ),
    // 批次 17 (05-19): RSS 文章列表页。从源管理页 ListTile 点击进入。
    GoRoute(
      path: '/rss-articles',
      builder: (context, state) {
        final sourceUrl = state.uri.queryParameters['sourceUrl'] ?? '';
        return RssArticleListPage(sourceUrl: sourceUrl);
      },
    ),
    // 批次 18 (05-19): RSS 文章详情页（WebView 渲染）。从文章列表 / 收藏页进入。
    GoRoute(
      path: '/rss-articles-detail',
      builder: (context, state) {
        final sourceUrl = state.uri.queryParameters['sourceUrl'] ?? '';
        final link = state.uri.queryParameters['link'] ?? '';
        return RssArticleDetailPage(sourceUrl: sourceUrl, link: link);
      },
    ),
    // 批次 18 (05-19): RSS 收藏页。BATCH-26a 后入口改由 RSS tab AppBar
    // 「收藏」IconButton 进入（原 bookshelf PopupMenu 入口已撤）。
    GoRoute(
      path: '/rss-favorites',
      builder: (context, state) => const RssFavoritesPage(),
    ),
    // 批次 19 (05-19): 订阅源页（RuleSub MVP）。bookshelf_page PopupMenu 入口。
    GoRoute(
      path: '/rule-subs',
      builder: (context, state) => const RuleSubPage(),
    ),
    // 批次 20 (05-19): QR 扫码导入页。
    // 入口：bookshelf_page PopupMenu / source_page / rss_source_manage /
    // rule_sub 各 AppBar IconButton。扫描结果由 page 自己处理 + pop。
    GoRoute(
      path: '/qr-scan',
      builder: (context, state) => const QrScanPage(),
    ),
    // BATCH-27c (05-22): 远程书浏览页。bookshelf PopupMenu「添加远程书」
    // 入口（27a 灰显占位 → 27c 改可点）。复用 webdav_config_page 凭据
    // + Rust webdav list_dir / download_file 通用 FRB（funcId 113/114）。
    GoRoute(
      path: '/remote-books',
      builder: (_, __) => const RemoteBooksPage(),
    ),
    // BATCH-27d (05-22): 书架管理批量编辑页。bookshelf PopupMenu「书架
    // 管理」入口（27a 灰显占位 → 27d 改可点）。长按多选 → 批量删除 /
    // canUpdate toggle / 移分组 / 清缓存 actionbar。
    GoRoute(
      path: '/bookshelf-manage',
      builder: (_, __) => const BookshelfManagePage(),
    ),
    // Task 05-25: 诊断日志页。Settings → 工具 → 诊断日志 入口。
    GoRoute(
      path: '/diagnostics',
      builder: (_, __) => const DiagnosticsPage(),
    ),
  ],
);

class _AppShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;

  const _AppShell({required this.navigationShell});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // BATCH-26c (05-22): 底栏 tab 动态显隐。对齐原 legado
    // `MainActivity.kt:364-381` 行为：showDiscovery / showRss 关闭时
    // 隐藏对应 NavigationDestination，但 ShellBranch 与 GoRoute 都不删
    // — 用户仍可直接 URL `/explore` / `/rss` 访问。
    //
    // 4 ShellBranch 固定 0..3 = 书架/发现/订阅/我的；NavigationBar 的
    // selectedIndex / onDestinationSelected 是 view-index（0..可见 tab 数 - 1）
    // 与 branch-index (0..3) 之间的映射，靠 visibleBranchIndices 翻译。
    final showDiscovery = ref.watch(showDiscoveryProvider);
    final showRss = ref.watch(showRssProvider);

    final visibleBranchIndices = <int>[
      0, // 书架（永远可见）
      if (showDiscovery) 1, // 发现
      if (showRss) 2, // 订阅
      3, // 我的（永远可见）
    ];

    // 当前 branch 不在可见列表（用户在 /explore 但刚关掉「显示发现」的
    // 中间帧）→ selectedIndex fallback 0（书架），避免 NavigationBar
    // 渲染负数 selectedIndex 报错。listen 回调（下方）会在下一帧把当前
    // branch 切回 0，视觉短暂落到书架槽位即可。
    final viewIndex = visibleBranchIndices.indexOf(navigationShell.currentIndex);
    final selectedViewIndex = viewIndex < 0 ? 0 : viewIndex;

    // 关闭 toggle 后若当前正在被隐藏的 branch → 自动 goBranch(0) 切回
    // 书架。包 postFrameCallback 避免在 build 期间触发 navigation state
    // 变更（StatefulNavigationShell 内部走 ChangeNotifier，build 内
    // notifyListeners 会触发 setState during build）。
    ref.listen<bool>(showDiscoveryProvider, (prev, next) {
      if (!next && navigationShell.currentIndex == 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          navigationShell.goBranch(0);
        });
      }
    });
    ref.listen<bool>(showRssProvider, (prev, next) {
      if (!next && navigationShell.currentIndex == 2) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          navigationShell.goBranch(0);
        });
      }
    });

    return Scaffold(
      body: navigationShell,
      // BATCH-26a (05-22): 4 NavigationDestination 对齐原 legado
      // `main_bnv.xml` 0-3 槽位（书架 / 发现 / 订阅 / 我的）。
      // BATCH-26c (05-22): 「发现」/「订阅」按 toggle 动态显示。
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedViewIndex,
        onDestinationSelected: (index) {
          final branchIndex = visibleBranchIndices[index];
          navigationShell.goBranch(
            branchIndex,
            initialLocation: branchIndex == navigationShell.currentIndex,
          );
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '书架',
          ),
          if (showDiscovery)
            const NavigationDestination(
              icon: Icon(Icons.explore_outlined),
              selectedIcon: Icon(Icons.explore),
              label: '发现',
            ),
          if (showRss)
            const NavigationDestination(
              icon: Icon(Icons.add_circle_outline),
              selectedIcon: Icon(Icons.add_circle),
              label: '订阅',
            ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
