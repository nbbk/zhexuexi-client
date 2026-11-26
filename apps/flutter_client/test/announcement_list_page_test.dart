// 0.1.2：公告列表页的回归测试。
//
// 不碰真面板：announcementsProvider 直接覆盖给定的列表。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/features/announcements/announcement_list_page.dart';
import 'package:zhexuexi_client/services/announcement_service.dart';

Future<void> _pumpList(
  WidgetTester tester,
  List<Announcement> announcements,
) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        announcementsProvider.overrideWith((ref) async => announcements),
      ],
      child: const MaterialApp(home: AnnouncementListPage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('置顶在前、其余 created_at 倒序；每行标题＋正文＋时间＋置顶角标', (
    tester,
  ) async {
    await _pumpList(tester, [
      Announcement(
        id: 'an-000001',
        title: '旧公告',
        body: '旧的正文',
        createdAt: DateTime(2026, 11, 25, 9),
      ),
      Announcement(
        id: 'an-000002',
        title: '置顶公告',
        body: '置顶的正文',
        pinned: true,
        createdAt: DateTime(2026, 11, 24, 9),
      ),
      Announcement(
        id: 'an-000003',
        title: '新公告',
        body: '新的正文',
        createdAt: DateTime(2026, 11, 26, 9),
      ),
    ]);
    // 顺序：置顶、新、旧。
    final titles = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((d) => d != null)
        .toList();
    final order = titles
        .where((d) => ['置顶公告', '新公告', '旧公告'].contains(d))
        .toList();
    expect(order, ['置顶公告', '新公告', '旧公告']);
    // 置顶角标只有一个，在置顶那行。
    expect(find.text('置顶'), findsOneWidget);
    // 正文全文与时间都在。
    expect(find.text('置顶的正文'), findsOneWidget);
    expect(find.text('新的正文'), findsOneWidget);
    expect(find.textContaining('2026-11-26'), findsOneWidget);
  });

  testWidgets('空态只在页内出现“暂无公告”', (tester) async {
    await _pumpList(tester, []);
    expect(find.text('暂无公告'), findsOneWidget);
  });

  testWidgets('标题为空时行标题取正文首行', (tester) async {
    await _pumpList(tester, [
      const Announcement(
        id: 'an-000001',
        title: '',
        body: '只有正文的公告',
      ),
    ]);
    expect(find.text('只有正文的公告'), findsWidgets);
  });
}
