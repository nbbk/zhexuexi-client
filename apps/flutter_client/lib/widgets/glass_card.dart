import 'dart:ui';

import 'package:material_ui/material_ui.dart';

import '../core/app_theme.dart';
import '../core/app_tokens.dart';

/// 苹果毛玻璃效果卡片（全端共用）：半透明＋背景模糊＋细边框＋柔和阴影。
///
/// 用 Flutter 跨端 API 实现（[BackdropFilter]＋半透明＋圆角），
/// 不写端专属样式；浅色/深色两套透明度与边框色按当前
/// [ThemeData.brightness] 走，不按平台分支。
/// 0.1.14 做强：模糊 16→24、夜晚填充白 8%→12%、边框 15%→20%，
/// 白天填充 60%→65%、边框 65%→70%，玻璃感更明显，底色透出来
/// 的层次还在（不是实色卡片）。
/// 0.1.18 玻璃拟物主题：圆角与填充改走主题 token 覆盖值
/// （[AppThemeTokens.cardRadius]／[AppThemeTokens.surfaceGlass]）：
/// 没传 borderRadius 时，玻璃主题圆角 22、填充磨砂白 70%，
/// 其他主题仍是圆角 16、填充底色 65%；显式传了 borderRadius 的
/// 调用方不受影响。
/// 0.1.19 玻璃拟物主题：填充改带蓝调磨砂白 60%（token），边框
/// 2px 半透明白（token [AppThemeTokens.cardBorderWidth]），
/// 卡片顶部加一处高光渐变（像玻璃反光）；其他主题不动。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius,
    this.height,
  });

  final Widget child;

  /// 卡片内边距（不传时由 child 自己留白，与普通 Card 用法一致）。
  final EdgeInsetsGeometry? padding;

  /// 卡片外边距。
  final EdgeInsetsGeometry? margin;

  /// 圆角（不传时走主题覆盖值，玻璃主题 22、其他主题 16，
  /// 见 [AppTokens.radiusLarge]）。
  final double? borderRadius;

  /// 固定高度（不传时由 child 内容定高）。首页状态卡与流量格用它
  /// 统一高度：内容超长时内部省略，不把卡片撑高。
  final double? height;

  @override
  Widget build(BuildContext context) {
    final tokens = appThemeTokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(
      borderRadius ?? tokens.cardRadius ?? AppTokens.radiusLarge,
    );
    return Container(
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.40 : 0.10),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              // 白天是象牙白半透明、夜晚是白 12% 半透明（品牌色走，
              // 毛玻璃效果保留：半透明＋背景模糊＋细边框＋柔和阴影）。
              // 玻璃拟物主题（0.1.18）用磨砂白 surfaceGlass 作填充，
              // 0.1.19 起是带蓝调的 60%。
              color: dark
                  ? Colors.white.withValues(alpha: 0.12)
                  : tokens.surfaceGlass ??
                      tokens.background.withValues(alpha: 0.65),
              // 玻璃拟物主题（0.1.19）：顶部一处高光（像玻璃反光），
              // 白 22% 从顶到底 30% 处褪到透明；其他主题不加。
              // gradient 画在 color 之上，半透明，两者叠加。
              gradient: (!dark && tokens.surfaceGlass != null)
                  ? LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.3],
                      colors: [
                        Colors.white.withValues(alpha: 0.22),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    )
                  : null,
              borderRadius: radius,
              // 玻璃拟物主题（0.1.19）：2px 半透明白描边（像白画框），
              // 其他主题仍是 1px。
              border: Border.all(
                color: dark
                    ? Colors.white.withValues(alpha: 0.20)
                    : tokens.surfaceGlass != null
                        ? Colors.white.withValues(alpha: 0.60)
                        : Colors.white.withValues(alpha: 0.70),
                width: dark ? 1 : (tokens.cardBorderWidth ?? 1),
              ),
            ),
            // 透明 Material：卡片里的 ListTile 要有 Material 祖先才
            // 能画背景与水波纹（0.1.2：我的页 7 张 Card 换成 GlassCard
            // 后没了这层，debug 下 ListTile 直接断言报错；原生 Card
            // 自带 Material，GlassCard 必须自己补）。
            child: Material(
              type: MaterialType.transparency,
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 毛玻璃页面的背景渐变（全端同一套，见当前主题的
/// [AppThemeTokens.backgroundGradient]）：
/// 包在页面最外层，给 [GlassCard] 留出“透”的层次。
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = appThemeTokensOf(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: tokens.backgroundGradient,
        ),
      ),
      child: child,
    );
  }
}
