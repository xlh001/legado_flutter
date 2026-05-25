import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/reader/change_source_dialog.dart';

void main() {
  testWidgets('换源搜索单个书源返回后立即显示结果', (tester) async {
    final slow = Completer<String>();

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeSourceDialog(
          dbPath: '/tmp/test.db',
          bookName: '测试书',
          bookAuthor: '作者',
          currentSourceId: 'current',
          currentSourceName: '当前源',
          getEnabledSourcesOverride: (_) async => jsonEncode([
            {'id': 'slow', 'name': '慢书源'},
            {'id': 'fast', 'name': '快书源'},
          ]),
          searchWithSourceOverride: (_, sourceId, __) {
            if (sourceId == 'slow') return slow.future;
            return Future.value(jsonEncode([
              {'book_url': 'https://fast/book', 'author': '作者'},
            ]));
          },
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('快书源'), findsOneWidget);
    expect(find.text('慢书源'), findsNothing);
    expect(find.textContaining('找到 1 个匹配书源'), findsOneWidget);

    slow.complete(jsonEncode([
      {'book_url': 'https://slow/book', 'author': '作者'},
    ]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('慢书源'), findsOneWidget);
    expect(find.textContaining('找到 2 个匹配书源'), findsOneWidget);
  });

  testWidgets('换源刷新后旧搜索结果不会覆盖新搜索', (tester) async {
    final oldSearch = Completer<String>();
    var sourceLoadCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeSourceDialog(
          dbPath: '/tmp/test.db',
          bookName: '测试书',
          bookAuthor: '作者',
          currentSourceId: 'current',
          currentSourceName: '当前源',
          getEnabledSourcesOverride: (_) async {
            sourceLoadCount++;
            if (sourceLoadCount == 1) {
              return jsonEncode([
                {'id': 'old', 'name': '旧书源'},
              ]);
            }
            return jsonEncode([
              {'id': 'new', 'name': '新书源'},
            ]);
          },
          searchWithSourceOverride: (_, sourceId, __) {
            if (sourceId == 'old') return oldSearch.future;
            return Future.value(jsonEncode([
              {'book_url': 'https://new/book', 'author': '作者'},
            ]));
          },
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('重新搜索'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('新书源'), findsOneWidget);
    expect(find.text('旧书源'), findsNothing);

    oldSearch.complete(jsonEncode([
      {'book_url': 'https://old/book', 'author': '作者'},
    ]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('新书源'), findsOneWidget);
    expect(find.text('旧书源'), findsNothing);
  });
}
