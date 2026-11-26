// UI 优化落地测试：导航分端、设计 token、Lucide 图标、动效、
// 节点详情页、逐项入场、哲人侧脸图标。
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhexuexi_client/core/app_motion.dart';
import 'package:zhexuexi_client/core/app_tokens.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/features/nodes/node_detail_page.dart';
import 'package:zhexuexi_client/features/nodes/nodes_page.dart';
import 'package:zhexuexi_client/main.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/widgets/app_icon.dart';
import 'package:zhexuexi_client/widgets/power_button.dart';

class _StubNodesNotifier extends NodesNotifier {
  _StubNodesNotifier(this._state);

  final NodesState _state;
  final calls = <String>[];

  @override
  NodesState build() => _state;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> bindAndRefresh(String link) async {}

  @override
  Future<bool> testAllSpeeds() async => true;

  @override
  Future<bool> autoSelect() async => true;

  @override
  Future<bool> selectNode(
    Node node, {
    String? reason,
    bool auto = false,
  }) async {
    calls.add('select:${node.name}');
    return true;
  }

  @override
  Future<bool> testSingleSpeed(Node node) async {
    calls.add('speed:${node.name}');
    return true;
  }
}

Node _node(String name, NodeSource source, {bool plain = false}) {
  return Node(
    name: name,
    protocol: NodeProtocol.vless,
    address: '203.0.113.10',
    port: 443,
    source: source,
    uuidOrPassword: '11111111-2222-3333-4444-555555555555',
    tls: !plain,
    isPlainText: plain,
  );
}

void main() {
  group('设计 token', () {
    test('AppTokens：圆角 / 间距 / 断点 / 行高 / 缓存区取值', () {
      expect(AppTokens.radiusSmall, 10);
      expect(AppTokens.radiusMedium, 12);
      expect(AppTokens.radiusLarge, 16);
      expect(AppTokens.radiusXLarge, 28);
      expect(AppTokens.spacingXs, 8);
      expect(AppTokens.spacingSm, 12);
      expect(AppTokens.spacingMd, 16);
      expect(AppTokens.navBreakpoint, 700);
      expect(AppTokens.nodeRowHeight, 64);
      expect(AppTokens.listCacheExtent, 500);
    });

    test('AppIconSize：四档像素与线宽', () {
      expect(AppIconSize.xs.pixels, 16);
      expect(AppIconSize.xs.stroke, 1.5);
      expect(AppIconSize.sm.pixels, 20);
      expect(AppIconSize.sm.stroke, 1.75);
      expect(AppIconSize.md.pixels, 24);
      expect(AppIconSize.md.stroke, 2.0);
      expect(AppIconSize.lg.pixels, 32);
      expect(AppIconSize.lg.stroke, 2.25);
    });
  });

  group('Lucide 图标', () {
    testWidgets('AppIcon：走 Lucide 字体、默认 24px', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: AppIcon(icon: AppIcons.home)),
        ),
      );
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon?.fontFamily, 'lucide');
      expect(icon.size, 24);
    });

    testWidgets('AppIcon：尺寸档只走 token（sm 20px）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppIcon(icon: AppIcons.settings, size: AppIconSize.sm),
          ),
        ),
      );
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.size, 20);
    });
  });

  group('多端导航', () {
    testWidgets('窄屏 390：底部导航栏、无左侧栏', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ProviderScope(child: ZhexuexiApp()));
      await tester.pumpAndSettle();
      expect(find.byType(BottomNavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('宽屏 1200：左侧导航栏、无底部栏', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ProviderScope(child: ZhexuexiApp()));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsNothing);
    });

    testWidgets('窄屏点底部栏切 tab、宽屏点左侧栏切 tab', (tester) async {
      // 窄屏：点底部栏“节点”。
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ProviderScope(child: ZhexuexiApp()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('节点'));
      await tester.pumpAndSettle();
      expect(find.text('搜索节点'), findsOneWidget);

      // 宽屏：点左侧栏“我的”。
      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(find.text('我的'), findsWidgets);
    });
  });

  group('动效', () {
    test('AppMotion：页面 300 / 详情 450 / 展开 350 / 间隔 80ms', () {
      expect(AppMotion.page, const Duration(milliseconds: 300));
      expect(AppMotion.detail, const Duration(milliseconds: 450));
      expect(AppMotion.expand, const Duration(milliseconds: 350));
      expect(AppMotion.stagger, const Duration(milliseconds: 80));
      expect(AppMotion.list, const Duration(milliseconds: 250));
      expect(AppMotion.state, const Duration(milliseconds: 250));
    });

    testWidgets('AppMotion.effective：减弱动态时归零', (tester) async {
      late Duration normal;
      late Duration reduced;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              normal = AppMotion.effective(context, AppMotion.page);
              return MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: Builder(
                  builder: (context) {
                    reduced = AppMotion.effective(context, AppMotion.page);
                    return const SizedBox();
                  },
                ),
              );
            },
          ),
        ),
      );
      expect(normal, const Duration(milliseconds: 300));
      expect(reduced, Duration.zero);
    });

    testWidgets('appPageRoute：非 iOS 走 PageRouteBuilder，300ms', (tester) async {
      late PageRoute route;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              route = appPageRoute(context, (_) => const Text('detail'));
              return const Text('home');
            },
          ),
        ),
      );
      expect(route, isA<PageRouteBuilder>());
      expect(route.transitionDuration, const Duration(milliseconds: 300));
    });

    testWidgets('appPageRoute：iOS 走 CupertinoPageRoute，保留右滑返回', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      late PageRoute route;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              route = appPageRoute(context, (_) => const Text('detail'));
              return const Text('home');
            },
          ),
        ),
      );
      expect(route, isA<CupertinoPageRoute>());
      expect(route.transitionDuration, const Duration(milliseconds: 300));
    });

    testWidgets('showAppDialog：弹窗出现（350ms 淡入缩放）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return FilledButton(
                onPressed: () => showAppDialog<void>(
                  context: context,
                  builder: (_) => const Text('弹窗内容'),
                ),
                child: const Text('打开'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pump();
      expect(find.text('弹窗内容'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('弹窗内容'), findsOneWidget);
    });
  });

  group('节点详情页', () {
    testWidgets('渲染信息行、“设为当前节点”调 selectNode', (tester) async {
      final node = _node('智利-直连', NodeSource.direct);
      final stub = _StubNodesNotifier(
        NodesState(nodes: [node], status: NodesStatus.loaded),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [nodesProvider.overrideWith(() => stub)],
          child: MaterialApp(home: NodeDetailPage(node: node)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('智利-直连'), findsOneWidget);
      expect(find.text('203.0.113.10:443'), findsOneWidget);
      expect(find.text('未测速'), findsOneWidget);
      expect(find.text('设为当前节点'), findsOneWidget);

      await tester.tap(find.text('设为当前节点'));
      await tester.pumpAndSettle();
      expect(stub.calls, contains('select:智利-直连'));
    });
  });

  group('逐项入场', () {
    testWidgets('减弱动态时节点行直接显示、不等逐项延迟', (tester) async {
      final stub = _StubNodesNotifier(
        NodesState(
          nodes: [
            _node('智利-直连', NodeSource.direct),
            _node('日本-直连', NodeSource.direct),
          ],
          status: NodesStatus.loaded,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [nodesProvider.overrideWith(() => stub)],
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: const Scaffold(body: NodesPage()),
            ),
          ),
        ),
      );
      // 只 pump 一帧、不 settle：开启动效时第二行要晚 80ms 才出现，
      // 减弱动态时两行都直接在。分组默认折叠，先点组头展开再断言行。
      await tester.tap(find.text('未分组（2）'));
      await tester.pump();
      expect(find.text('智利-直连'), findsOneWidget);
      expect(find.text('日本-直连'), findsOneWidget);
    });
  });

  group('哲人侧脸图标', () {
    test('SignalPhilosopherPainter：字段与 shouldRepaint', () {
      final a = SignalPhilosopherPainter(
        const Color(0xFFF4D89A),
        isOn: true,
        progress: 0.2,
        animated: true,
      );
      final b = SignalPhilosopherPainter(
        const Color(0xFFF4D89A),
        isOn: true,
        progress: 0.5,
        animated: true,
      );
      final c = SignalPhilosopherPainter(
        const Color(0xFFF4D89A),
        isOn: true,
        progress: 0.2,
        animated: true,
      );
      expect(a.isOn, isTrue);
      expect(a.animated, isTrue);
      expect(a.progress, 0.2);
      expect(a.shouldRepaint(b), isTrue);
      expect(a.shouldRepaint(c), isFalse);
      final off = SignalPhilosopherPainter(
        const Color(0xFF9CA3AF),
        isOn: false,
        animated: false,
      );
      expect(off.isOn, isFalse);
      expect(a.shouldRepaint(off), isTrue);
    });

    testWidgets('PowerButtonIcon：关态也画哲人图标、颜色淡（不画电源符号）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PowerButtonIcon(
              color: Color(0xFF9CA3AF),
              size: 48,
              isOn: false,
            ),
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is SignalPhilosopherPainter,
        ),
        findsOneWidget,
      );
      // 减弱动态时静态全亮（animated: false 时三道弧全亮）。
      final painter = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is SignalPhilosopherPainter,
        ),
      ).painter as SignalPhilosopherPainter;
      expect(painter.isOn, isFalse);
    });

    testWidgets('PowerButtonIcon：开态画哲人图标（CustomPaint）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PowerButtonIcon(
              color: Color(0xFFF4D89A),
              size: 48,
              isOn: true,
            ),
          ),
        ),
      );
      // 按 painter 类型找：Scaffold 里另有一个 CustomPaint，不能只数个数。
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is SignalPhilosopherPainter,
        ),
        findsOneWidget,
      );
    });
  });
}
