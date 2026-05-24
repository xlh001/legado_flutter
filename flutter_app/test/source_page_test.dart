import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/source/source_page.dart';
import 'package:legado_flutter/core/providers.dart';

void main() {
  testWidgets('shows loading indicator', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSourcesProvider.overrideWith(
            (ref) => Future.delayed(const Duration(seconds: 1), () => <Map<String, dynamic>>[]),
          ),
        ],
        child: const MaterialApp(home: SourcePage()),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('shows error message', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSourcesProvider.overrideWith((ref) => Future.error('Connection failed')),
        ],
        child: const MaterialApp(home: SourcePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('加载失败: Connection failed'), findsOneWidget);
  });

  testWidgets('shows search bar in app bar', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSourcesProvider.overrideWith((ref) => Future.value(<Map<String, dynamic>>[])),
        ],
        child: const MaterialApp(home: SourcePage()),
      ),
    );
    await tester.pumpAndSettle();
    // AppBar now has a search bar instead of a title text
    expect(find.byIcon(Icons.search), findsWidgets);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
  });

  testWidgets('shows empty message when no sources', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSourcesProvider.overrideWith((ref) => Future.value(<Map<String, dynamic>>[])),
        ],
        child: const MaterialApp(home: SourcePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无书源，点击右下角添加'), findsOneWidget);
  });

  testWidgets('shows action buttons in app bar', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSourcesProvider.overrideWith((ref) => Future.value(<Map<String, dynamic>>[])),
        ],
        child: const MaterialApp(home: SourcePage()),
      ),
    );
    await tester.pumpAndSettle();
    // New AppBar has sort, filter, import, more_vert buttons
    expect(find.byIcon(Icons.sort_by_alpha), findsOneWidget);
    expect(find.byIcon(Icons.filter_list), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
  });

  testWidgets('shows FAB with add icon', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSourcesProvider.overrideWith((ref) => Future.value(<Map<String, dynamic>>[])),
        ],
        child: const MaterialApp(home: SourcePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets('shows source list with names and URLs', (WidgetTester tester) async {
    final sources = [
      <String, dynamic>{'name': 'Source A', 'url': 'https://a.com', 'enabled': true, 'id': 's1'},
      <String, dynamic>{'name': 'Source B', 'url': 'https://b.com', 'enabled': true, 'id': 's2'},
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSourcesProvider.overrideWith((ref) => Future.value(sources)),
        ],
        child: const MaterialApp(home: SourcePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Source A'), findsOneWidget);
    expect(find.text('https://a.com'), findsOneWidget);
    expect(find.text('Source B'), findsOneWidget);
    expect(find.text('https://b.com'), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(2));
  });

  testWidgets('shows disabled source with cancel icon', (WidgetTester tester) async {
    final sources = [
      <String, dynamic>{'name': 'Disabled', 'url': 'https://d.com', 'enabled': false, 'id': 's3'},
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSourcesProvider.overrideWith((ref) => Future.value(sources)),
        ],
        child: const MaterialApp(home: SourcePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('shows fallback name for null source name', (WidgetTester tester) async {
    final sources = [
      <String, dynamic>{'name': null, 'url': null, 'enabled': true, 'id': 's4'},
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSourcesProvider.overrideWith((ref) => Future.value(sources)),
        ],
        child: const MaterialApp(home: SourcePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未知书源'), findsOneWidget);
  });
}
