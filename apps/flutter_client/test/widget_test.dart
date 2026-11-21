// 冒烟测试：App 能启动、四个 tab 齐全、首页大开关占位在。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:zhexuexi_client/main.dart';

void main() {
  testWidgets('App 启动：四个 tab 与首页大开关占位', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ZhexuexiApp()));
    await tester.pumpAndSettle();

    // 品牌名来自包内 brand.json（阶段 0 兜底）。
    expect(find.text('哲学系'), findsWidgets);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('节点'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    // 首页默认显示“未连接”。
    expect(find.text('未连接'), findsOneWidget);
    expect(find.byIcon(Icons.power_settings_new), findsOneWidget);
  });

  testWidgets('点底部导航能切到节点页', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ZhexuexiApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('节点'));
    await tester.pumpAndSettle();
    expect(find.text('搜索节点'), findsOneWidget);
    expect(find.text('一键测速'), findsOneWidget);
  });
}
