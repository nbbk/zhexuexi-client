import 'package:material_ui/material_ui.dart';

/// 全端共用的主题注册表：主题 = 一个主题对象（全部颜色 token），
/// 新增主题就是加一个主题定义，不用改页面代码。
///
/// 配色从品牌自己的 Logo（v1/v2：深蓝底＋金色信号弧＋金色实心哲人侧脸）
/// 里取，不用 AI 默认的通用渐变；默认主题里不用紫色、粉色渐变。
/// 皮肤主题（曜石黑金、青瓷月白、落樱粉、星野紫）是用户点的风格，
/// 各自按自己的点缀色走，同样不铺大面积。
/// 气质：学术奢华感（深墨蓝＋香槟金＋象牙白），像烫金书封，
/// 不要 corporate、不要亮金。金色要克制，只作细线点缀
///（选中态细边框、信号弧、细环），不要大面积铺金色。
/// 页面代码只读当前主题的 token（经 [ThemeData.extensions]），
/// 不直接写死色值；颜色、圆角、卡片、动效全部走共用组件
///（[GlassCard]、[BreathingPowerButton]），不按 `Platform.isIOS` /
/// `isAndroid` / `isWindows` 分支写样式。
class AppThemeTokens extends ThemeExtension<AppThemeTokens> {
  const AppThemeTokens({
    required this.deepBlue,
    required this.deepBlueLight,
    required this.gold,
    required this.goldHighlight,
    required this.background,
    required this.backgroundGradient,
    required this.secondaryText,
    required this.powerGradient,
    required this.powerOffGradient,
    required this.segmentedSelectedBackground,
    required this.segmentedSelectedForeground,
  });

  /// 主深蓝：墨蓝（Logo 底色）。白天作文字与主按钮、夜晚作背景。
  final Color deepBlue;

  /// 次深蓝：渐变的另一端。
  final Color deepBlueLight;

  /// 香槟金（点缀，比亮金更 muted、更少黄色）。
  final Color gold;

  /// 淡金高光：信号弧与呼吸光晕用这个，更柔。
  final Color goldHighlight;

  /// 页面底色（白天象牙白 / 夜晚墨蓝黑）。
  final Color background;

  /// 页面背景渐变（毛玻璃卡片后面的底色）。
  final List<Color> backgroundGradient;

  /// 次要文字：蓝灰（跟蓝色系走，不要纯灰）。
  final Color secondaryText;

  /// 电源开关渐变：深蓝渐变（墨蓝 → 次深蓝），不要紫色。
  final List<Color> powerGradient;

  /// 电源开关关掉时的渐变（灰）。
  final List<Color> powerOffGradient;

  /// 三段切换（规则/全局/直连）的选中态背景。
  final Color segmentedSelectedBackground;

  /// 三段切换的选中态文字。
  final Color segmentedSelectedForeground;

  @override
  AppThemeTokens copyWith({
    Color? deepBlue,
    Color? deepBlueLight,
    Color? gold,
    Color? goldHighlight,
    Color? background,
    List<Color>? backgroundGradient,
    Color? secondaryText,
    List<Color>? powerGradient,
    List<Color>? powerOffGradient,
    Color? segmentedSelectedBackground,
    Color? segmentedSelectedForeground,
  }) {
    return AppThemeTokens(
      deepBlue: deepBlue ?? this.deepBlue,
      deepBlueLight: deepBlueLight ?? this.deepBlueLight,
      gold: gold ?? this.gold,
      goldHighlight: goldHighlight ?? this.goldHighlight,
      background: background ?? this.background,
      backgroundGradient: backgroundGradient ?? this.backgroundGradient,
      secondaryText: secondaryText ?? this.secondaryText,
      powerGradient: powerGradient ?? this.powerGradient,
      powerOffGradient: powerOffGradient ?? this.powerOffGradient,
      segmentedSelectedBackground:
          segmentedSelectedBackground ?? this.segmentedSelectedBackground,
      segmentedSelectedForeground:
          segmentedSelectedForeground ?? this.segmentedSelectedForeground,
    );
  }

  @override
  AppThemeTokens lerp(ThemeExtension<AppThemeTokens>? other, double t) {
    if (other is! AppThemeTokens) return this;
    Color lerpColor(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return AppThemeTokens(
      deepBlue: lerpColor(deepBlue, other.deepBlue),
      deepBlueLight: lerpColor(deepBlueLight, other.deepBlueLight),
      gold: lerpColor(gold, other.gold),
      goldHighlight: lerpColor(goldHighlight, other.goldHighlight),
      background: lerpColor(background, other.background),
      backgroundGradient: [
        for (var i = 0; i < backgroundGradient.length; i++)
          lerpColor(
            backgroundGradient[i],
            other.backgroundGradient[i],
          ),
      ],
      secondaryText: lerpColor(secondaryText, other.secondaryText),
      powerGradient: [
        for (var i = 0; i < powerGradient.length; i++)
          lerpColor(powerGradient[i], other.powerGradient[i]),
      ],
      powerOffGradient: [
        for (var i = 0; i < powerOffGradient.length; i++)
          lerpColor(powerOffGradient[i], other.powerOffGradient[i]),
      ],
      segmentedSelectedBackground: lerpColor(
        segmentedSelectedBackground,
        other.segmentedSelectedBackground,
      ),
      segmentedSelectedForeground: lerpColor(
        segmentedSelectedForeground,
        other.segmentedSelectedForeground,
      ),
    );
  }
}

/// 一个主题定义：id＋名字＋亮度＋全部颜色 token。
class AppThemeDefinition {
  const AppThemeDefinition({
    required this.id,
    required this.name,
    required this.brightness,
    required this.tokens,
  });

  /// 主题 id（持久化存这个，如 `day` / `night`）。
  final String id;

  /// 显示名（设置页切换用，如“白天”/“夜晚”）。
  final String name;

  final Brightness brightness;

  /// 全部颜色 token。
  final AppThemeTokens tokens;

  /// 由 token 派生的 [ThemeData]（颜色方案、底色、次要文字色、
  /// token 扩展都从这里出，页面只读它）。
  ThemeData get themeData {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: tokens.deepBlue,
        primary: brightness == Brightness.dark
            ? tokens.gold
            : tokens.deepBlue,
        secondary: tokens.gold,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: tokens.background,
      // 原生 Card / 弹窗的兜底色（2026-11-26 0.1.2 夜晚黑底）：
      // 没换成 GlassCard 的地方也别露 M3 默认深色 surface；
      // 夜晚白 8%、白天底色 60%（与 GlassCard 同款），
      // surfaceTintColor 透明（不要 M3 的色调 tint）。
      // 底色从当前主题的 token 派生（墨蓝两档算出来跟原来写死的
      // #FAF7F0 / #082E63 一模一样，见 app_style_test）。
      cardTheme: CardThemeData(
        color: brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.08)
            : tokens.background.withValues(alpha: 0.6),
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: brightness == Brightness.dark
            ? tokens.deepBlue
            : tokens.background,
      ),
      // 顶栏刷成墨蓝（不要 M3 默认的浅灰蓝 surface），标题与图标走白色。
      // 白字在墨蓝上的对比度 13.28:1，夜晚同理。
      appBarTheme: AppBarTheme(
        backgroundColor: tokens.deepBlue,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: TextTheme(
        bodySmall: TextStyle(color: tokens.secondaryText),
      ),
      extensions: [tokens],
      useMaterial3: true,
    );
  }
}

/// 主题注册表：五套皮肤 × 白天/夜晚两档，默认墨蓝白天。
/// 后面加更多风格主题时，只在这里加一个主题定义，不用改页面代码。
class AppThemes {
  AppThemes._();

  /// 默认主题（墨蓝＋香槟金＋象牙白；色值取自 Logo 实测：
  /// 主墨蓝 #082E63、次深蓝 #0B3D84、金 #EEC362、淡金 #F4D89A）。
  static const AppThemeDefinition day = AppThemeDefinition(
    id: 'day',
    name: '白天',
    brightness: Brightness.light,
    tokens: AppThemeTokens(
      deepBlue: Color(0xFF082E63),
      deepBlueLight: Color(0xFF0B3D84),
      gold: Color(0xFFEEC362),
      goldHighlight: Color(0xFFF4D89A),
      background: Color(0xFFFAF7F0),
      backgroundGradient: [Color(0xFFFAF7F0), Colors.white],
      secondaryText: Color(0xFF5C6B7A),
      powerGradient: [Color(0xFF082E63), Color(0xFF0B3D84)],
      powerOffGradient: [Color(0xFF9CA3AF), Color(0xFF6B7280)],
      segmentedSelectedBackground: Color(0xFF082E63),
      segmentedSelectedForeground: Colors.white,
    ),
  );

  /// 夜晚主题：墨蓝黑底＋香槟金点缀（深蓝作背景，
  /// 高亮与选中走金色，保证深色底上看得清）。
  /// 注意：墨蓝 #082E63 在夜晚底 #070F1C 上的对比度只有 1.45:1，
  /// 仅用于渐变底色等装饰，不放文字；夜晚文字走金色（11.53:1）
  /// 与浅色次要文字。
  static const AppThemeDefinition night = AppThemeDefinition(
    id: 'night',
    name: '夜晚',
    brightness: Brightness.dark,
    tokens: AppThemeTokens(
      deepBlue: Color(0xFF082E63),
      deepBlueLight: Color(0xFF0B3D84),
      gold: Color(0xFFEEC362),
      goldHighlight: Color(0xFFF4D89A),
      background: Color(0xFF070F1C),
      backgroundGradient: [
        Color(0xFF070F1C),
        Color(0xFF082E63),
        Color(0xFF0B3D84),
      ],
      secondaryText: Color(0xFF8A9BAE),
      powerGradient: [Color(0xFF082E63), Color(0xFF0B3D84)],
      powerOffGradient: [Color(0xFF9CA3AF), Color(0xFF6B7280)],
      segmentedSelectedBackground: Color(0xFFEEC362),
      segmentedSelectedForeground: Color(0xFF082E63),
    ),
  );

  /// 曜石黑金 · 白天：曜石黑＋沉金，黑卡感。
  /// 白字在主色上 19.63:1、主色在底色上 17.71:1、次要文字 4.93:1。
  static const AppThemeDefinition obsidianDay = AppThemeDefinition(
    id: 'obsidian-day',
    name: '曜石黑金 · 白天',
    brightness: Brightness.light,
    tokens: AppThemeTokens(
      deepBlue: Color(0xFF0B0B10),
      deepBlueLight: Color(0xFF1C1C26),
      gold: Color(0xFFD4AF37),
      goldHighlight: Color(0xFFF0D98C),
      background: Color(0xFFF5F3EE),
      backgroundGradient: [Color(0xFFF5F3EE), Colors.white],
      secondaryText: Color(0xFF5C6B7A),
      powerGradient: [Color(0xFF0B0B10), Color(0xFF2A2A35)],
      powerOffGradient: [Color(0xFF9CA3AF), Color(0xFF6B7280)],
      segmentedSelectedBackground: Color(0xFF0B0B10),
      segmentedSelectedForeground: Colors.white,
    ),
  );

  /// 曜石黑金 · 夜晚：主色只作渐变底色装饰（在夜晚底上 1.04:1，
  /// 不放文字）；夜晚文字走金色（9.68:1）与浅色次要文字（8.00:1）；
  /// 三段选中：金底＋曜石字 9.34:1。
  static const AppThemeDefinition obsidianNight = AppThemeDefinition(
    id: 'obsidian-night',
    name: '曜石黑金 · 夜晚',
    brightness: Brightness.dark,
    tokens: AppThemeTokens(
      deepBlue: Color(0xFF0B0B10),
      deepBlueLight: Color(0xFF1C1C26),
      gold: Color(0xFFD4AF37),
      goldHighlight: Color(0xFFF0D98C),
      background: Color(0xFF050508),
      backgroundGradient: [
        Color(0xFF050508),
        Color(0xFF0B0B10),
        Color(0xFF1C1C26),
      ],
      secondaryText: Color(0xFF9AA3B2),
      powerGradient: [Color(0xFF0B0B10), Color(0xFF2A2A35)],
      powerOffGradient: [Color(0xFF9CA3AF), Color(0xFF6B7280)],
      segmentedSelectedBackground: Color(0xFFD4AF37),
      segmentedSelectedForeground: Color(0xFF0B0B10),
    ),
  );

  /// 青瓷月白 · 白天：青瓷深绿＋釉金，清新雅致。
  /// 白字在主色上 7.79:1、主色在底色上 7.20:1、次要文字 5.45:1。
  static const AppThemeDefinition celadonDay = AppThemeDefinition(
    id: 'celadon-day',
    name: '青瓷月白 · 白天',
    brightness: Brightness.light,
    tokens: AppThemeTokens(
      deepBlue: Color(0xFF1F5C4D),
      deepBlueLight: Color(0xFF3E8A76),
      gold: Color(0xFFC9A86A),
      goldHighlight: Color(0xFFF2E3C0),
      background: Color(0xFFF7F6F1),
      backgroundGradient: [Color(0xFFF7F6F1), Colors.white],
      secondaryText: Color(0xFF4E6A61),
      powerGradient: [Color(0xFF1F5C4D), Color(0xFF3E8A76)],
      powerOffGradient: [Color(0xFF9CA3AF), Color(0xFF6B7280)],
      segmentedSelectedBackground: Color(0xFF1F5C4D),
      segmentedSelectedForeground: Colors.white,
    ),
  );

  /// 青瓷月白 · 夜晚：主色只作渐变底色装饰（在夜晚底上 2.20:1，
  /// 不放文字）；夜晚文字走釉金（7.59:1）与浅色次要文字（6.83:1）；
  /// 三段选中不用主色作字（3.45:1 不够），改用夜晚底色作字 7.59:1。
  static const AppThemeDefinition celadonNight = AppThemeDefinition(
    id: 'celadon-night',
    name: '青瓷月白 · 夜晚',
    brightness: Brightness.dark,
    tokens: AppThemeTokens(
      deepBlue: Color(0xFF1F5C4D),
      deepBlueLight: Color(0xFF3E8A76),
      gold: Color(0xFFC9A86A),
      goldHighlight: Color(0xFFF2E3C0),
      background: Color(0xFF0A1F1A),
      backgroundGradient: [
        Color(0xFF0A1F1A),
        Color(0xFF1F5C4D),
        Color(0xFF3E8A76),
      ],
      secondaryText: Color(0xFF93A8A2),
      powerGradient: [Color(0xFF1F5C4D), Color(0xFF3E8A76)],
      powerOffGradient: [Color(0xFF9CA3AF), Color(0xFF6B7280)],
      segmentedSelectedBackground: Color(0xFFC9A86A),
      segmentedSelectedForeground: Color(0xFF0A1F1A),
    ),
  );

  /// 落樱粉 · 白天：豆沙粉＋浅樱，温柔浪漫。
  /// 白字在主色上 6.40:1、主色在底色上 6.11:1、次要文字 5.37:1。
  static const AppThemeDefinition sakuraDay = AppThemeDefinition(
    id: 'sakura-day',
    name: '落樱粉 · 白天',
    brightness: Brightness.light,
    tokens: AppThemeTokens(
      deepBlue: Color(0xFF9E3D5E),
      deepBlueLight: Color(0xFFC96A8C),
      gold: Color(0xFFF0B8C8),
      goldHighlight: Color(0xFFFBE3EA),
      background: Color(0xFFFFF8F9),
      backgroundGradient: [Color(0xFFFFF8F9), Colors.white],
      secondaryText: Color(0xFF7E5F6B),
      powerGradient: [Color(0xFF9E3D5E), Color(0xFFC96A8C)],
      powerOffGradient: [Color(0xFF9CA3AF), Color(0xFF6B7280)],
      segmentedSelectedBackground: Color(0xFF9E3D5E),
      segmentedSelectedForeground: Colors.white,
    ),
  );

  /// 落樱粉 · 夜晚：主色只作渐变底色装饰（在夜晚底上 2.91:1，
  /// 不放文字）；夜晚文字走浅樱（10.99:1）与浅色次要文字（7.28:1）；
  /// 三段选中不用主色作字（3.78:1 不够），改用夜晚底色作字 10.99:1。
  static const AppThemeDefinition sakuraNight = AppThemeDefinition(
    id: 'sakura-night',
    name: '落樱粉 · 夜晚',
    brightness: Brightness.dark,
    tokens: AppThemeTokens(
      deepBlue: Color(0xFF9E3D5E),
      deepBlueLight: Color(0xFFC96A8C),
      gold: Color(0xFFF0B8C8),
      goldHighlight: Color(0xFFFBE3EA),
      background: Color(0xFF1E0E14),
      backgroundGradient: [
        Color(0xFF1E0E14),
        Color(0xFF9E3D5E),
        Color(0xFFC96A8C),
      ],
      secondaryText: Color(0xFFB89AA6),
      powerGradient: [Color(0xFF9E3D5E), Color(0xFFC96A8C)],
      powerOffGradient: [Color(0xFF9CA3AF), Color(0xFF6B7280)],
      segmentedSelectedBackground: Color(0xFFF0B8C8),
      segmentedSelectedForeground: Color(0xFF1E0E14),
    ),
  );

  /// 星野紫 · 白天：深紫＋香槟金，神秘贵气。
  /// 白字在主色上 10.62:1、主色在底色上 9.82:1、次要文字 5.04:1。
  static const AppThemeDefinition violetDay = AppThemeDefinition(
    id: 'violet-day',
    name: '星野紫 · 白天',
    brightness: Brightness.light,
    tokens: AppThemeTokens(
      deepBlue: Color(0xFF4C2A85),
      deepBlueLight: Color(0xFF7B5EA7),
      gold: Color(0xFFEEC362),
      goldHighlight: Color(0xFFF4D89A),
      background: Color(0xFFF7F5FB),
      backgroundGradient: [Color(0xFFF7F5FB), Colors.white],
      secondaryText: Color(0xFF6E6390),
      powerGradient: [Color(0xFF4C2A85), Color(0xFF7B5EA7)],
      powerOffGradient: [Color(0xFF9CA3AF), Color(0xFF6B7280)],
      segmentedSelectedBackground: Color(0xFF4C2A85),
      segmentedSelectedForeground: Colors.white,
    ),
  );

  /// 星野紫 · 夜晚：主色只作渐变底色装饰（在夜晚底上 1.81:1，
  /// 不放文字）；夜晚文字走金色（11.53:1）与浅色次要文字（7.57:1）；
  /// 三段选中：金底＋深紫字 6.38:1。
  static const AppThemeDefinition violetNight = AppThemeDefinition(
    id: 'violet-night',
    name: '星野紫 · 夜晚',
    brightness: Brightness.dark,
    tokens: AppThemeTokens(
      deepBlue: Color(0xFF4C2A85),
      deepBlueLight: Color(0xFF7B5EA7),
      gold: Color(0xFFEEC362),
      goldHighlight: Color(0xFFF4D89A),
      background: Color(0xFF120A24),
      backgroundGradient: [
        Color(0xFF120A24),
        Color(0xFF4C2A85),
        Color(0xFF7B5EA7),
      ],
      secondaryText: Color(0xFFA99CC9),
      powerGradient: [Color(0xFF4C2A85), Color(0xFF7B5EA7)],
      powerOffGradient: [Color(0xFF9CA3AF), Color(0xFF6B7280)],
      segmentedSelectedBackground: Color(0xFFEEC362),
      segmentedSelectedForeground: Color(0xFF4C2A85),
    ),
  );

  /// 全部已注册主题（设置页切换列表从这里出）。
  static const List<AppThemeDefinition> all = [
    day,
    night,
    obsidianDay,
    obsidianNight,
    celadonDay,
    celadonNight,
    sakuraDay,
    sakuraNight,
    violetDay,
    violetNight,
  ];

  /// 默认主题 id。
  static const String defaultId = 'day';

  /// 按 id 取主题；id 不存在时回落默认主题（不让坏偏好拖垮界面）。
  static AppThemeDefinition byId(String? id) {
    for (final theme in all) {
      if (theme.id == id) return theme;
    }
    return day;
  }
}

/// 取当前主题的 token（页面代码只读它，不直接写死色值）。
/// 只能在有 [Theme] 的子树里调；没有时回落默认主题的 token。
AppThemeTokens appThemeTokensOf(BuildContext context) {
  return Theme.of(context).extension<AppThemeTokens>() ??
      AppThemes.day.tokens;
}
