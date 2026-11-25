// 冒烟测试：App 能启动、四个 tab 齐全、首页大开关占位在。
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zhexuexi_client/main.dart';
import 'package:zhexuexi_client/widgets/power_button.dart';

void main() {
  testWidgets('App 启动：四个 tab 与首页大开关占位', (WidgetTester tester) async {
    // 首页是 ListView 懒加载：默认 600 高视口下开关区在折叠线下
    // 不会被构建，先把视口拉高再断言。
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: ZhexuexiApp()));
    await tester.pumpAndSettle();

    // 品牌名来自包内 brand.json（阶段 0 兜底）。
    expect(find.text('哲学系'), findsWidgets);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('节点'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    // 首页默认显示“静候连接 / 轻触开启”，大开关是呼吸按钮
    //（中心图标是金色信号弧占位，不写死电源符号）。
    expect(find.text('静候连接'), findsOneWidget);
    expect(find.text('轻触开启'), findsOneWidget);
    expect(find.byType(BreathingPowerButton), findsOneWidget);
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
