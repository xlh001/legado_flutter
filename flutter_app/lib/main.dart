import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/color_scheme_config.dart';
import 'core/diagnostics/diagnostic_log.dart';
import 'core/download_runner.dart';
import 'core/notification_service.dart';
import 'core/providers.dart';
import 'core/refresh_rate_controller.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'src/rust/api.dart' as rust_api;
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      final diagnosticLoggingEnabled =
          await loadDiagnosticLoggingEnabledFromDisk();
      final diagnosticLogLevel = await loadDiagnosticLogLevelFromDisk();
      await DiagnosticLog.init(
        enabled: diagnosticLoggingEnabled,
        minLevel: diagnosticLogLevel,
      );

      await _runAppStartup();
    },
    (error, stack) {
      DiagnosticLog.error(
        'flutter.zone_error',
        'Uncaught async error',
        error: error,
        stack: stack,
      );
    },
  );
}

Future<void> _runAppStartup() async {
  // Apply preferred display mode as early as possible so animations like
  // simulation page-flip can leverage the high refresh rate from first frame.
  // Failure here must not block app startup.
  final refreshRateMode = await loadRefreshRateModeFromDisk();
  await RefreshRateController.apply(refreshRateMode);

  try {
    await RustLib.init();
    final pong = await rust_api.ping();
    debugPrint('[FRB smoke] ping() returned: $pong');
    DiagnosticLog.info(
      'frb.smoke',
      'FRB smoke ping succeeded',
      metadata: {'response': pong},
      source: 'frb',
    );
    if (pong != 'pong') {
      debugPrint('[FRB smoke] WARNING: unexpected ping response: $pong');
      DiagnosticLog.warn(
        'frb.smoke',
        'FRB smoke ping returned unexpected response',
        metadata: {'response': pong},
        source: 'frb',
      );
    }
  } catch (e, st) {
    debugPrint('[FRB smoke] init/ping FAILED: $e');
    debugPrint('[FRB smoke] stack: $st');
    DiagnosticLog.error(
      'frb.smoke',
      'FRB smoke init/ping failed',
      error: e,
      stack: st,
      source: 'frb',
    );
    // Show a visible error page instead of crashing the process. Common
    // causes: missing libbridge.so, write-protected db dir, ABI mismatch.
    runApp(_FrbInitErrorApp(error: e, stack: st));
    return;
  }

  await NotificationService.init();

  final themeMode = await loadThemeModeFromDisk();
  // BATCH-18d (F-W2A-008)：启动加载 readerSettings，让派生的
  // fontSizeProvider 第一帧拿到正确值。reader_page 进入时仍会再次
  // loadReaderSettingsFromDisk（_readerSettingsLoaded flag 控制），
  // helper 幂等无副作用。
  final readerSettings = await loadReaderSettingsFromDisk();
  // BATCH-26c (05-22): 启动加载底栏 tab 显隐 toggle，让 _AppShell
  // 第一帧就拿到正确的 destinations 数组，避免「先渲染 4 destination
  // 再因 listen 收缩到 2/3」的视觉抖动。default true 与原 legado
  // pref_config_other.xml `android:defaultValue="true"` 对齐。
  final showDiscovery = await loadShowDiscoveryFromDisk();
  final showRss = await loadShowRssFromDisk();
  // BATCH-26d (05-22): 启动加载 defaultHomePage，让 startup postFrame
  // 跳转决策能拿到正确值。与 26c 同模式 wire（disk → ProviderScope.overrides）。
  final defaultHomePage = await loadDefaultHomePageFromDisk();
  // BATCH-27d-followup (05-22): 启动加载 bookshelfManageOpenReader，
  // BookshelfManagePage 第一帧就拿到正确 toggle 值（避免「先渲染默认
  // false 再 listen 异步刷新」的视觉抖动）。
  final bookshelfManageOpenReader =
      await loadBookshelfManageOpenReaderFromDisk();
  // BATCH-27c-2 (05-22): 启动加载 selectedRemoteServerId，让
  // RemoteBooksPage 第一帧就走选中 server 凭据路径，避免先渲染 -1
  // fallback 再 listen 切换造成的请求浪费。
  final selectedRemoteServerId = await loadSelectedRemoteServerIdFromDisk();
  runApp(ProviderScope(
    overrides: [
      themeModeProvider.overrideWith((ref) => themeMode),
      readerSettingsProvider.overrideWith((ref) => readerSettings),
      refreshRateModeProvider.overrideWith((ref) => refreshRateMode),
      showDiscoveryProvider.overrideWith((ref) => showDiscovery),
      showRssProvider.overrideWith((ref) => showRss),
      defaultHomePageProvider.overrideWith((ref) => defaultHomePage),
      bookshelfManageOpenReaderProvider
          .overrideWith((ref) => bookshelfManageOpenReader),
      selectedRemoteServerIdProvider
          .overrideWith((ref) => selectedRemoteServerId),
    ],
    child: const LegadoApp(),
  ));
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    // pendingRoute 优先级最高（重启后回到通知 / 外部 deep link 跳转点）。
    // 命中后提前 return，避免后续 defaultHomePage 跳转覆盖。
    final route = await loadPendingRoute();
    if (route != null) {
      router.go(route);
      await clearPendingRoute();
      return;
    }
    // BATCH-26d: 应用 defaultHomePage（仅当对应 tab 可见，对齐原版
    // MainActivity.kt:385-398 upHomePage 行为：toggle 关闭时保留 bookshelf
    // 兜底，不跳）。
    applyDefaultHomePage(
      router,
      defaultHomePage,
      showDiscovery: showDiscovery,
      showRss: showRss,
    );
  });
}

class LegadoApp extends ConsumerWidget {
  const LegadoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final colorConfig = ref.watch(colorSchemeConfigProvider);
    // Trigger DB init eagerly
    ref.listen(dbInitializedProvider, (_, state) {
      state.whenOrNull(
        data: (ok) {
          debugPrint('[FRB] DB init: $ok');
          DiagnosticLog.info(
            'db.init',
            'Database initialization completed',
            metadata: {'ok': ok},
            source: 'frb',
          );
          if (ok) {
            final dbPath = ref.read(dbPathProvider).valueOrNull;
            if (dbPath != null) {
              DownloadRunner.resetInterruptedTasks(dbPath);
            }
          }
        },
        error: (e, st) {
          debugPrint('[FRB] DB init error: $e');
          DiagnosticLog.error(
            'db.init',
            'Database initialization failed',
            error: e,
            stack: st,
            source: 'frb',
          );
        },
      );
    });

    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final useDynamic = colorConfig.source == ColorSource.dynamic_;

        final lightScheme = useDynamic
            ? (lightDynamic?.harmonized() ??
                ColorScheme.fromSeed(
                    seedColor: Color(colorConfig.presetSeed),
                    brightness: Brightness.light))
            : ColorScheme.fromSeed(
                seedColor: Color(colorConfig.presetSeed),
                brightness: Brightness.light);

        final darkScheme = useDynamic
            ? (darkDynamic?.harmonized() ??
                ColorScheme.fromSeed(
                    seedColor: Color(colorConfig.presetSeed),
                    brightness: Brightness.dark))
            : ColorScheme.fromSeed(
                seedColor: Color(colorConfig.presetSeed),
                brightness: Brightness.dark);

        return MaterialApp.router(
          title: 'Legado Reader',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(lightScheme),
          darkTheme: AppTheme.build(darkScheme),
          themeMode: themeMode,
          routerConfig: router,
        );
      },
    );
  }
}

/// Fallback app shown when FRB initialization fails. Avoids a hard crash on
/// release builds and gives users (or testers) a copyable error message.
class _FrbInitErrorApp extends StatelessWidget {
  final Object error;
  final StackTrace stack;

  const _FrbInitErrorApp({required this.error, required this.stack});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Legado Reader',
      home: Scaffold(
        appBar: AppBar(title: const Text('Legado Reader 启动失败')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Rust 桥接初始化失败',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '常见原因：libbridge.so 缺失或 ABI 不匹配；数据库目录无写入权限；'
                    '应用版本与原生库不一致。',
                  ),
                  const SizedBox(height: 16),
                  SelectableText('Error: $error'),
                  const SizedBox(height: 8),
                  SelectableText(
                    'Stack:\n$stack',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
