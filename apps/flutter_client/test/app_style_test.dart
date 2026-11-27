// 风格基础：主题注册表、毛玻璃卡片、呼吸电源开关、平滑转场。
//
// 不碰真机与真偏好文件：SharedPreferences 用 mock；
// 呼吸动画只在“开”时转，关态下 pumpAndSettle 不会被无限动画卡住，
// 开态测试用手动 pump。
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/app_motion.dart';
import 'package:zhexuexi_client/core/app_theme.dart';
import 'package:zhexuexi_client/core/app_tokens.dart';
import 'package:zhexuexi_client/services/theme_notifier.dart';
import 'package:zhexuexi_client/widgets/glass_card.dart';
import 'package:zhexuexi_client/widgets/power_button.dart';

/// WCAG 相对亮度（0–1）。
double _relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

/// WCAG 对比度（1–21）；正文 4.5:1、非文字图形 3:1。
double _contrast(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  group('主题注册表', () {
    test('注册了五套皮肤 × 白天/夜晚两档，默认白天，id 不存在回落默认', () {
      expect(
        AppThemes.all.map((t) => t.id).toList(),
        [
          'day',
          'night',
          'obsidian-day',
          'obsidian-night',
          'celadon-day',
          'celadon-night',
          'sakura-day',
          'sakura-night',
          'violet-day',
          'violet-night',
        ],
      );
      expect(AppThemes.defaultId, 'day');
      expect(AppThemes.byId('night').name, '夜晚');
      expect(AppThemes.byId('nope').id, 'day');
      expect(AppThemes.byId(null).id, 'day');
    });

    test('默认主题 token 是定好的品牌色（墨蓝＋香槟金＋象牙白）', () {
      final t = AppThemes.day.tokens;
      expect(t.deepBlue, const Color(0xFF082E63));
      expect(t.deepBlueLight, const Color(0xFF0B3D84));
      expect(t.gold, const Color(0xFFEEC362));
      expect(t.goldHighlight, const Color(0xFFF4D89A));
      expect(t.background, const Color(0xFFFAF7F0));
      expect(t.secondaryText, const Color(0xFF5C6B7A));
      expect(t.powerGradient, [
        const Color(0xFF082E63),
        const Color(0xFF0B3D84),
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
      expect(AppThemes.night.tokens.gold, const Color(0xFFEEC362));
    });

    test('夜晚 scaffold 底色 #070F1C（非纯黑），渐变三色齐全', () {
      final night = AppThemes.night;
      expect(night.themeData.scaffoldBackgroundColor, const Color(0xFF070F1C));
      expect(
        night.tokens.backgroundGradient,
        [
          const Color(0xFF070F1C),
          const Color(0xFF082E63),
          const Color(0xFF0B3D84),
        ],
      );
      // 白天渐变回归象牙白。
      expect(
        AppThemes.day.tokens.backgroundGradient,
        [const Color(0xFFFAF7F0), Colors.white],
      );
    });

    test('cardTheme/dialogTheme 兜底：原生 Card/对话框不露 M3 默认深色面', () {
      final night = AppThemes.night.themeData;
      expect(night.cardTheme.color, Colors.white.withValues(alpha: 0.08));
      expect(night.cardTheme.surfaceTintColor, Colors.transparent);
      expect(night.dialogTheme.backgroundColor, const Color(0xFF082E63));
      final day = AppThemes.day.themeData;
      expect(
        day.cardTheme.color,
        const Color(0xFFFAF7F0).withValues(alpha: 0.6),
      );
      expect(day.dialogTheme.backgroundColor, const Color(0xFFFAF7F0));
    });

    test('主题定义能编出 ThemeData：底色、扩展 token 都在', () {
      final data = AppThemes.day.themeData;
      expect(data.brightness, Brightness.light);
      expect(data.scaffoldBackgroundColor, const Color(0xFFFAF7F0));
      expect(data.extension<AppThemeTokens>(), isNotNull);
      expect(AppThemes.night.themeData.brightness, Brightness.dark);
      // 顶栏刷成墨蓝（不要 M3 默认浅灰蓝 surface），标题与图标走白色。
      expect(
        data.appBarTheme.backgroundColor,
        const Color(0xFF082E63),
      );
      expect(data.appBarTheme.foregroundColor, Colors.white);
      expect(
        AppThemes.night.themeData.appBarTheme.backgroundColor,
        const Color(0xFF082E63),
      );
      expect(
        AppThemes.night.themeData.appBarTheme.foregroundColor,
        Colors.white,
      );
    });

    test('新皮肤：四套 × 白天/夜晚的 token 是定好的色值', () {
      // 曜石黑金。
      var t = AppThemes.obsidianDay.tokens;
      expect(t.deepBlue, const Color(0xFF0B0B10));
      expect(t.deepBlueLight, const Color(0xFF1C1C26));
      expect(t.gold, const Color(0xFFD4AF37));
      expect(t.background, const Color(0xFFF5F3EE));
      expect(t.powerGradient, [
        const Color(0xFF0B0B10),
        const Color(0xFF2A2A35),
      ]);
      expect(AppThemes.obsidianNight.tokens.background, const Color(0xFF050508));
      expect(AppThemes.obsidianNight.brightness, Brightness.dark);
      // 青瓷月白。
      t = AppThemes.celadonDay.tokens;
      expect(t.deepBlue, const Color(0xFF1F5C4D));
      expect(t.deepBlueLight, const Color(0xFF3E8A76));
      expect(t.gold, const Color(0xFFC9A86A));
      expect(t.background, const Color(0xFFF7F6F1));
      expect(t.secondaryText, const Color(0xFF4E6A61));
      expect(AppThemes.celadonNight.tokens.background, const Color(0xFF0A1F1A));
      expect(AppThemes.celadonNight.tokens.segmentedSelectedForeground,
          const Color(0xFF0A1F1A));
      // 落樱粉。
      t = AppThemes.sakuraDay.tokens;
      expect(t.deepBlue, const Color(0xFF9E3D5E));
      expect(t.deepBlueLight, const Color(0xFFC96A8C));
      expect(t.gold, const Color(0xFFF0B8C8));
      expect(t.background, const Color(0xFFFFF8F9));
      expect(t.secondaryText, const Color(0xFF7E5F6B));
      expect(AppThemes.sakuraNight.tokens.background, const Color(0xFF1E0E14));
      expect(AppThemes.sakuraNight.tokens.segmentedSelectedForeground,
          const Color(0xFF1E0E14));
      // 星野紫。
      t = AppThemes.violetDay.tokens;
      expect(t.deepBlue, const Color(0xFF4C2A85));
      expect(t.deepBlueLight, const Color(0xFF7B5EA7));
      expect(t.gold, const Color(0xFFEEC362));
      expect(t.background, const Color(0xFFF7F5FB));
      expect(AppThemes.violetNight.tokens.background, const Color(0xFF120A24));
      expect(AppThemes.violetNight.brightness, Brightness.dark);
      // 墨蓝两档原样不动。
      expect(AppThemes.day.tokens.deepBlue, const Color(0xFF082E63));
      expect(AppThemes.night.tokens.background, const Color(0xFF070F1C));
    });

    test('新皮肤：文字对比度都达标（白天主色字、夜晚点缀字、次要文字、'
        '三段选中、开关白图标）', () {
      const defs = [
        AppThemes.obsidianDay,
        AppThemes.obsidianNight,
        AppThemes.celadonDay,
        AppThemes.celadonNight,
        AppThemes.sakuraDay,
        AppThemes.sakuraNight,
        AppThemes.violetDay,
        AppThemes.violetNight,
      ];
      for (final def in defs) {
        final t = def.tokens;
        final bg = t.background;
        // 顶栏：白字在主色上（白天夜晚都走这对）。
        expect(_contrast(Colors.white, t.deepBlue), greaterThanOrEqualTo(4.5),
            reason: '${def.id} 顶栏白字');
        // 白天主色字在底色上；夜晚点缀字在底色上（主色夜晚只作装饰）。
        if (def.brightness == Brightness.light) {
          expect(_contrast(t.deepBlue, bg), greaterThanOrEqualTo(4.5),
              reason: '${def.id} 主色字');
        } else {
          expect(_contrast(t.gold, bg), greaterThanOrEqualTo(4.5),
              reason: '${def.id} 点缀字');
        }
        expect(_contrast(t.secondaryText, bg), greaterThanOrEqualTo(4.5),
            reason: '${def.id} 次要文字');
        expect(
          _contrast(
            t.segmentedSelectedForeground,
            t.segmentedSelectedBackground,
          ),
          greaterThanOrEqualTo(4.5),
          reason: '${def.id} 三段选中',
        );
        // 开关上的白色信号弧是非文字图形，3:1 即可。
        for (final g in t.powerGradient) {
          expect(_contrast(Colors.white, g), greaterThanOrEqualTo(3.0),
              reason: '${def.id} 开关图标');
        }
      }
    });

    test('新皮肤：ThemeData 能编出来，底色与兜底色跟 token 走', () {
      for (final def in [
        AppThemes.obsidianDay,
        AppThemes.obsidianNight,
        AppThemes.celadonDay,
        AppThemes.celadonNight,
        AppThemes.sakuraDay,
        AppThemes.sakuraNight,
        AppThemes.violetDay,
        AppThemes.violetNight,
      ]) {
        final data = def.themeData;
        expect(data.brightness, def.brightness);
        expect(data.scaffoldBackgroundColor, def.tokens.background);
        expect(data.extension<AppThemeTokens>(), isNotNull);
        expect(data.appBarTheme.backgroundColor, def.tokens.deepBlue);
        expect(data.appBarTheme.foregroundColor, Colors.white);
        if (def.brightness == Brightness.light) {
          expect(
            data.dialogTheme.backgroundColor,
            def.tokens.background,
          );
          expect(
            data.cardTheme.color,
            def.tokens.background.withValues(alpha: 0.6),
          );
        } else {
          expect(data.dialogTheme.backgroundColor, def.tokens.deepBlue);
          expect(data.cardTheme.color, Colors.white.withValues(alpha: 0.08));
        }
      }
    });

    test('ThemeNotifier：新皮肤 id 切换持久化，重建读回', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(appThemeProvider.notifier)
          .setTheme('sakura-night');
      expect(container.read(appThemeProvider), 'sakura-night');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_theme_id'), 'sakura-night');
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      for (
        var i = 0;
        i < 50 && container2.read(appThemeProvider) != 'sakura-night';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(container2.read(appThemeProvider), 'sakura-night');
    });

    test('AppTokens.latencyOkColor：白天夜晚各一支绿，两处共用', () {
      expect(
        AppTokens.latencyOkColor(Brightness.light),
        const Color(0xFF157347),
      );
      expect(
        AppTokens.latencyOkColor(Brightness.dark),
        const Color(0xFF4ADE80),
      );
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
        const Color(0xFF082E63),
        const Color(0xFF0B3D84),
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
