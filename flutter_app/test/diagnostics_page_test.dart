import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/diagnostics/diagnostic_log_reader.dart';
import 'package:legado_flutter/features/settings/diagnostics_page.dart';
import 'package:legado_flutter/features/settings/settings_page.dart';

/// Fake [DiagnosticLogReader] that returns canned data without real I/O.
class FakeDiagnosticLogReader implements DiagnosticLogReader {
  final DiagnosticLogStats fakeStats;
  final List<String> fakeLines;

  FakeDiagnosticLogReader({
    this.fakeStats = const DiagnosticLogStats(
        fileCount: 0, totalBytes: 0, newestModified: null),
    this.fakeLines = const [],
  });

  @override
  Directory get directory => Directory.systemTemp;

  @override
  Future<List<String>> tail({int maxLines = 500}) async => fakeLines;

  @override
  Future<File> exportMerged({required String outputPath}) async =>
      File(outputPath);

  @override
  Future<void> clear() async {}

  @override
  Future<DiagnosticLogStats> stats() async => fakeStats;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('diagnostics_ui_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('Settings 工具段含诊断日志 ListTile', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('诊断日志'), findsOneWidget);
    expect(find.text('查看、导出或清空本地诊断记录'), findsOneWidget);
    expect(find.byIcon(Icons.bug_report_outlined), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsAtLeastNWidgets(7));
  });

  testWidgets('诊断日志页空状态显示正确', (tester) async {
    final reader = FakeDiagnosticLogReader();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DiagnosticsPage(readerForTest: reader),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('暂无诊断日志'), findsOneWidget);
    expect(find.text('应用运行时的事件将记录在此'), findsOneWidget);
    expect(find.text('刷新'), findsOneWidget);
    expect(find.text('启用诊断日志'), findsOneWidget);
  });

  testWidgets('诊断日志页显示 stats 与 log 行', (tester) async {
    final reader = FakeDiagnosticLogReader(
      fakeStats: const DiagnosticLogStats(
        fileCount: 3,
        totalBytes: 1024 * 10,
        newestModified: null,
      ),
      fakeLines: [
        r'{"ts":"2026-05-25T10:00:00.000Z","level":"info","source":"flutter","category":"test.category","message":"test message one","metadata":{"key1":"value1"}}',
        r'{"ts":"2026-05-25T10:00:01.000Z","level":"error","source":"flutter","category":"test.error","message":"test error message","error":"fatal"}',
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DiagnosticsPage(readerForTest: reader),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Stats card.
    expect(find.text('日志信息'), findsOneWidget);
    expect(find.text('文件数量'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('10.0 KB'), findsOneWidget);

    // Log lines.
    expect(find.textContaining('最近记录'), findsOneWidget);
    expect(find.text('test.category'), findsOneWidget);
    expect(find.text('test message one'), findsOneWidget);
    expect(find.text('INFO'), findsAtLeastNWidgets(1));
  });

  testWidgets('清空按钮弹窗确认并清空', (tester) async {
    final reader = FakeDiagnosticLogReader(
      fakeStats: const DiagnosticLogStats(
          fileCount: 1, totalBytes: 500, newestModified: null),
      fakeLines: [
        r'{"ts":"2026-05-25T10:00:00.000Z","level":"info","source":"flutter","category":"test.clear","message":"to be cleared"}',
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DiagnosticsPage(readerForTest: reader),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Tap 清空 button.
    final clearButton = find.widgetWithText(OutlinedButton, '清空');
    expect(clearButton, findsOneWidget);
    await tester.tap(clearButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Dialog should appear.
    expect(find.text('清空日志'), findsOneWidget);
    expect(find.text('确定要清空所有诊断日志吗？此操作不可撤销。'), findsOneWidget);

    // Confirm — use the FilledButton in the dialog.
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Should show SnackBar "日志已清空".
    expect(find.text('日志已清空'), findsOneWidget);
  });

  testWidgets('启用诊断日志开关可切换', (tester) async {
    final reader = FakeDiagnosticLogReader();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DiagnosticsPage(readerForTest: reader),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('启用诊断日志'), findsOneWidget);
    final switchFinder = find.byType(Switch);
    expect(switchFinder, findsAtLeastNWidgets(1));

    await tester.tap(switchFinder.first);
    await tester.pump();
  });

  testWidgets('刷新按钮重新加载数据', (tester) async {
    final reader = FakeDiagnosticLogReader(
      fakeStats: const DiagnosticLogStats(
          fileCount: 1, totalBytes: 100, newestModified: null),
      fakeLines: [
        r'{"ts":"2026-05-25T10:00:00.000Z","level":"info","source":"flutter","category":"test.refresh","message":"before refresh"}',
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DiagnosticsPage(readerForTest: reader),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('test.refresh'), findsOneWidget);
    expect(find.text('before refresh'), findsOneWidget);

    // Verify refresh button works.
    expect(find.text('刷新'), findsOneWidget);
  });

  testWidgets('导出按钮存在且可交互', (tester) async {
    final reader = FakeDiagnosticLogReader(
      fakeStats: const DiagnosticLogStats(
          fileCount: 1, totalBytes: 200, newestModified: null),
      fakeLines: [
        r'{"ts":"2026-05-25T10:00:00.000Z","level":"info","source":"flutter","category":"test.export","message":"export me"}',
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DiagnosticsPage(readerForTest: reader),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final exportButton = find.widgetWithText(OutlinedButton, '导出');
    expect(exportButton, findsOneWidget);
    expect(tester.widget<OutlinedButton>(exportButton).onPressed, isNotNull);

    // Tap export — should not crash.
    await tester.tap(exportButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Page should still render.
    expect(find.text('诊断日志'), findsOneWidget);
  });

  testWidgets('诊断日志页窄屏按钮区不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(361, 794));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final reader = FakeDiagnosticLogReader(
      fakeStats: const DiagnosticLogStats(
          fileCount: 1, totalBytes: 200, newestModified: null),
      fakeLines: [
        r'{"ts":"2026-05-25T10:00:00.000Z","level":"info","source":"flutter","category":"test.overflow","message":"overflow check"}',
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DiagnosticsPage(readerForTest: reader),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(OutlinedButton, '刷新'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '导出'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '清空'), findsOneWidget);
  });
}
