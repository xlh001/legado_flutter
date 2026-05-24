import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/search/search_page.dart';
import 'package:legado_flutter/core/providers.dart';

void main() {
  Widget buildSearchPage() {
    return ProviderScope(
      overrides: [
        dbDirProvider.overrideWith((ref) => Future.value('.')),
        dbPathProvider.overrideWith((ref) => Future.value('test_legado.db')),
        dbInitializedProvider.overrideWith((ref) => Future.value(true)),
      ],
      child: const MaterialApp(home: SearchPage()),
    );
  }

  testWidgets('SearchPage shows back button in app bar', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();
    // 05-24 HTML alignment: AppBar has back arrow instead of title text
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('搜索'), findsNothing);
  });

  testWidgets('SearchPage shows hint text in search bar', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();
    // 05-24 HTML alignment: search bar in AppBar with updated hint
    expect(find.text('搜索书名、作者'), findsOneWidget);
  });

  testWidgets('SearchPage shows empty state message', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();
    expect(find.text('输入关键词搜索书籍'), findsOneWidget);
  });

  testWidgets('SearchPage shows search bar and more_vert menu in app bar', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();
    // 05-24 HTML alignment: search icon in search bar + more_vert in AppBar actions
    expect(find.byIcon(Icons.search), findsWidgets);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
  });

  testWidgets('SearchPage does not crash when disposed during async offline search', (WidgetTester tester) async {
    final completer = Completer<bool>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dbDirProvider.overrideWith((ref) => Future.value('.')),
          dbPathProvider.overrideWith((ref) => Future.value('test_legado.db')),
          dbInitializedProvider.overrideWith((ref) => completer.future),
        ],
        child: const MaterialApp(home: SearchPage()),
      ),
    );
    await tester.pumpAndSettle();

    // Enter text to enable search
    await tester.enterText(find.byType(TextField), 'test');
    await tester.pumpAndSettle();

    // Trigger search via onSubmitted of TextField
    await tester.enterText(find.byType(TextField), 'test');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    // Search is now suspended on the hanging dbInitializedProvider future

    // Navigate away, disposing SearchPage
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('SAFE'))),
    );
    await tester.pump();

    // Complete the future that SearchPage was awaiting — code resumes at mounted guard
    completer.complete(true);
    await tester.pump();

    // If we reach here without exception, the mounted guard worked
    expect(find.text('SAFE'), findsOneWidget);
  });

  testWidgets('SearchPage can enter text in search field', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'test keyword');
    await tester.pumpAndSettle();

    expect(find.text('test keyword'), findsOneWidget);
  });

  testWidgets(
      'BATCH-21 (F-W2B-019): 连续两次 _doSearch 后 _searchSeq 自增；'
      '旧 future 不覆盖新结果', (WidgetTester tester) async {
    // 让 dbInitializedProvider 永远不完成 → _doSearch 在 await 处悬停
    // 但 ++_searchSeq 已经在 await 前同步执行过。
    final hangingCompleter = Completer<bool>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dbDirProvider.overrideWith((ref) => Future.value('.')),
          dbPathProvider.overrideWith((ref) => Future.value('test_legado.db')),
          dbInitializedProvider.overrideWith((ref) => hangingCompleter.future),
        ],
        child: const MaterialApp(home: SearchPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 第一次搜索：用 TextField onSubmitted 触发 _doSearch
    await tester.enterText(find.byType(TextField), 'A');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    final state = tester.state<State<SearchPage>>(find.byType(SearchPage));
    // ignore: avoid_dynamic_calls
    expect((state as dynamic).debugSearchSeq, 1);
    // ignore: avoid_dynamic_calls
    expect((state as dynamic).debugLastSearchKeyword, 'A');

    // 第二次搜索：此时 _loading=true，send 按钮被 progress 替换；用
    // onSubmitted 路径触发（直接对 TextField 输入新值再走 _doSearch）。
    // 简化：通过 state.dynamic 调用 onSubmitted 回调；或更直接：模拟用户
    // 在不等第一次完成的情况下用 onSubmitted。
    await tester.enterText(find.byType(TextField), 'B');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // ignore: avoid_dynamic_calls
    expect((state as dynamic).debugSearchSeq, 2,
        reason: '第二次 _doSearch 应自增 seq 到 2');
    // ignore: avoid_dynamic_calls
    expect((state as dynamic).debugLastSearchKeyword, 'B',
        reason: '_lastSearchKeyword 应被新关键词覆盖');

    // 解开 hanging future —— 第一次和第二次的 await 都会拿到 true。
    // 第一次的 await 后会执行 `if (!mounted || seq != _searchSeq) return;`
    // 因为 seq=1 ≠ _searchSeq=2，被拦截，不会改 _loading / 不会回滚
    // _lastSearchKeyword。
    hangingCompleter.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // ignore: avoid_dynamic_calls
    expect((state as dynamic).debugLastSearchKeyword, 'B',
        reason: 'seq 校验保证旧 future 不覆盖新关键词记忆');
  });
}
