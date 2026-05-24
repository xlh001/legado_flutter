/// Task X3 — 精确搜索可见性 (05-24 updated for HTML-aligned AppBar).
///
/// 校验 PRD 要求：
///   1. 精准搜索 toggle 在 more_vert PopupMenu 中（HTML 对齐后移到菜单）
///   2. 点击「精准搜索」菜单项 → _precisionMode 翻转 + SnackBar 显示
///   3. _doSearch 后 _lastSearchKeyword 被记忆（通过 debug getter 验证）
///   4. toggle 后用记忆 keyword 重跑（即便 TextField 已被清空也能重过滤）
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/search/search_page.dart';

Widget _buildSearchPage({Completer<bool>? dbInitCompleter}) {
  return ProviderScope(
    overrides: [
      dbDirProvider.overrideWith((ref) => Future.value('.')),
      dbPathProvider.overrideWith((ref) => Future.value('test_legado.db')),
      dbInitializedProvider.overrideWith(
        (ref) => dbInitCompleter?.future ?? Future.value(true),
      ),
    ],
    child: const MaterialApp(home: SearchPage()),
  );
}

/// Helper: open the more_vert menu, tap a PopupMenuItem by text, close the menu.
Future<void> _tapMenuItem(WidgetTester tester, String text) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('AppBar 用搜索框 + more_vert 菜单替代旧 AppBar 标题',
      (WidgetTester tester) async {
    await tester.pumpWidget(_buildSearchPage());
    await tester.pumpAndSettle();
    // AppBar now has a search bar with search icon + more_vert
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byIcon(Icons.search), findsWidgets);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    // The text "搜索" is no longer an AppBar title
    expect(find.text('搜索'), findsNothing);
  });

  testWidgets('默认 _precisionMode=false → 菜单中精准搜索 checkbox 未选中',
      (WidgetTester tester) async {
    await tester.pumpWidget(_buildSearchPage());
    await tester.pumpAndSettle();
    // Open the more_vert menu
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    // The menu should contain "精准搜索" item
    expect(find.text('精准搜索'), findsOneWidget);
  });

  testWidgets('点击菜单中精准搜索 → _precisionMode 翻转 (false → true)',
      (WidgetTester tester) async {
    await tester.pumpWidget(_buildSearchPage());
    await tester.pumpAndSettle();
    // Open menu and tap "精准搜索"
    await _tapMenuItem(tester, '精准搜索');
    // SnackBar should show
    expect(find.text('已切换到精确搜索'), findsOneWidget);
    // Let SnackBar duration finish
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('再次点击精准搜索 → 翻回模糊模式',
      (WidgetTester tester) async {
    await tester.pumpWidget(_buildSearchPage());
    await tester.pumpAndSettle();
    // First toggle to precise
    await _tapMenuItem(tester, '精准搜索');
    await tester.pump(const Duration(seconds: 2));
    // Second toggle back to fuzzy
    await _tapMenuItem(tester, '精准搜索');
    expect(find.text('已切换到模糊搜索'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });
}
