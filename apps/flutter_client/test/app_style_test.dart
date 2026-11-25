// 风格基础：主题注册表、毛玻璃卡片、呼吸电源开关、平滑转场。
//
// 不碰真机与真偏好文件：SharedPreferences 用 mock；
// 呼吸动画只在“开”时转，关态下 pumpAndSettle 不会被无限动画卡住，
// 开态测试用手动 pump。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/app_motion.dart';
import 'package:zhexuexi_client/core/app_theme.dart';
import 'package:zhexuexi_client/services/theme_notifier.dart';
import 'package:zhexuexi_client/widgets/glass_card.dart';
import 'package:zhexuexi_client/widgets/power_button.dart';

void main() {
  group('主题注册表', () {
    test('注册了白天/夜晚两档，默认白天，id 不存在回落默认', () {
      expect(AppThemes.all.map((t) => t.id).toList(), ['day', 'night']);
      expect(AppThemes.defaultId, 'day');
      expect(AppThemes.byId('night').name, '夜晚');
      expect(AppThemes.byId('nope').id, 'day');
      expect(AppThemes.byId(null).id, 'day');
    });

    test('默认主题 token 是定好的品牌色（墨蓝＋香槟金＋象牙白）', () {
      final t = AppThemes.day.tokens;
      expect(t.deepBlue, const Color(0xFF0A1E36));
      expect(t.deepBlueLight, const Color(0xFF10263F));
      expect(t.gold, const Color(0xFFC2A15C));
      expect(t.goldHighlight, const Color(0xFFD8C08A));
      expect(t.background, const Color(0xFFFAF7F0));
      expect(t.secondaryText, const Color(0xFF5C6B7A));
      expect(t.powerGradient, [
        const Color(0xFF0A1E36),
        const Color(0xFF10263F),
      ]);
      // 没有紫色/粉色渐变。
      expect(
        t.powerGradient.any(
          (c) => c == const Color(0xFF8B5CF6) || c == const Color(0xFF3B82F6),
        ),
        isFalse,
      );
    });

    test('夜晚主题 token：墨蓝黑底＋香槟金点缀', () {
      expect(AppThemes.night.brightness, Brightness.dark);
      expect(AppThemes.night.tokens.background, const Color(0xFF070F1C));
      expect(AppThemes.night.tokens.gold, const Color(0xFFC2A15C));
    });

    test('主题定义能编出 ThemeData：底色、扩展 token 都在', () {
      final data = AppThemes.day.themeData;
      expect(data.brightness, Brightness.light);
      expect(data.scaffoldBackgroundColor, const Color(0xFFFAF7F0));
      expect(data.extension<AppThemeTokens>(), isNotNull);
      expect(AppThemes.night.themeData.brightness, Brightness.dark);
    });

    test('ThemeNotifier：默认白天，切换持久化，重建读回夜晚', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(appThemeProvider), 'day');
      await container.read(appThemeProvider.notifier).setTheme('night');
      expect(container.read(appThemeProvider), 'night');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_theme_id'), 'night');
      // 不在注册表里的 id 不接受、不写坏偏好。
      await container.read(appThemeProvider.notifier).setTheme('nope');
      expect(container.read(appThemeProvider), 'night');
      expect(prefs.getString('app_theme_id'), 'night');
      // toggle 切回白天。
      await container.read(appThemeProvider.notifier).toggle();
      expect(container.read(appThemeProvider), 'day');
      // 新 notifier 读回持久化的值（异步读偏好，多等几轮）。
      await container.read(appThemeProvider.notifier).setTheme('night');
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      for (
        var i = 0;
        i < 50 && container2.read(appThemeProvider) != 'night';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(container2.read(appThemeProvider), 'night');
    });
  });

  group('毛玻璃卡片', () {
    testWidgets('白天与夜晚都能渲染子内容', (tester) async {
      for (final theme in [AppThemes.day, AppThemes.night]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.themeData,
            home: const Scaffold(
              body: GlassBackground(child: GlassCard(child: Text('卡片内容'))),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('卡片内容'), findsOneWidget);
      }
    });

    testWidgets('卡片用 BackdropFilter 做背景模糊', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.day.themeData,
          home: const Scaffold(body: GlassCard(child: Text('x'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsOneWidget);
    });
  });

  group('呼吸电源开关', () {
    testWidgets('关态：点一下回调、不写死电源图标、显示信号弧线条画', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.day.themeData,
          home: Scaffold(
            body: BreathingPowerButton(
              isOn: false,
              enabled: true,
              onPressed: () => taps++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 没有传统电源图标。
      expect(find.byIcon(Icons.power), findsNothing);
      expect(find.byIcon(Icons.power_settings_new), findsNothing);
      // 占位是信号弧＋哲人侧脸线条画（PowerButtonIcon 里的 CustomPaint，
      // 不是 Icon；Scaffold/Material 自己也有 CustomPaint，
      // 所以在 PowerButtonIcon 子树里找）。
      // 按钮内部亮/暗两层图标叠加，所以 PowerButtonIcon 有 2 个。
      final iconFinder = find.byType(PowerButtonIcon);
      expect(iconFinder, findsNWidgets(2));
      expect(
        find.descendant(of: iconFinder, matching: find.byType(CustomPaint)),
        findsNWidgets(2),
      );
      await tester.tap(find.byType(BreathingPowerButton));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('关态：不可点时点了没反应', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.day.themeData,
          home: Scaffold(
            body: BreathingPowerButton(
              isOn: false,
              enabled: false,
              onPressed: () => taps++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BreathingPowerButton));
      await tester.pumpAndSettle();
      expect(taps, 0);
    });

    testWidgets('开态：深蓝渐变（不用 pumpAndSettle，呼吸动画在转）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.day.themeData,
          home: Scaffold(
            body: BreathingPowerButton(
              isOn: true,
              enabled: true,
              onPressed: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final container = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      final decoration = container.decoration! as BoxDecoration;
      final gradient = decoration.gradient! as LinearGradient;
      expect(gradient.colors, [
        const Color(0xFF0A1E36),
        const Color(0xFF10263F),
      ]);
      // 开态有金色细环（边框）。
      expect(decoration.border, isNotNull);
    });

    testWidgets('PowerButtonIcon：传图标就用图标，不传画信号弧', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const PowerButtonIcon(color: Colors.white),
                const PowerButtonIcon(
                  icon: Icons.bolt_outlined,
                  color: Colors.white,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.bolt_outlined), findsOneWidget);
      // 不传图标的那一个画信号弧（CustomPaint 在它子树里）。
      final placeholder = find.byWidgetPredicate(
        (w) => w is PowerButtonIcon && w.icon == null,
      );
      expect(placeholder, findsOneWidget);
      expect(
        find.descendant(of: placeholder, matching: find.byType(CustomPaint)),
        findsOneWidget,
      );
    });
  });

  group('平滑转场', () {
    test('fadeSlideRoute：淡入滑动，时长统一 300ms', () {
      final route = fadeSlideRoute((_) => const Text('x'));
      expect(route.transitionDuration, const Duration(milliseconds: 300));
      expect(
        route.reverseTransitionDuration,
        const Duration(milliseconds: 300),
      );
      expect(AppMotion.page, const Duration(milliseconds: 300));
      expect(AppMotion.press, const Duration(milliseconds: 200));
      expect(AppMotion.list, const Duration(milliseconds: 250));
      expect(AppMotion.state, const Duration(milliseconds: 250));
    });
  });
}
