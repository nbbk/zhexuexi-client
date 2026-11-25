import 'package:material_ui/material_ui.dart';

/// 全端共用的主题注册表：主题 = 一个主题对象（全部颜色 token），
/// 新增主题就是加一个主题定义，不用改页面代码。
///
/// 配色从品牌自己的 Logo（v1/v2：深蓝底＋金色信号弧＋留白哲人侧脸）
/// 里取，不用 AI 默认的通用渐变；所有紫色、粉色渐变全部去掉。
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

/// 主题注册表：现在注册两个主题（白天、夜晚），默认白天。
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

  /// 全部已注册主题（设置页切换列表从这里出）。
  static const List<AppThemeDefinition> all = [day, night];

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
