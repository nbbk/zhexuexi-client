import 'dart:ui';

import 'package:material_ui/material_ui.dart';

import '../core/app_theme.dart';
import '../core/app_tokens.dart';

/// 苹果毛玻璃效果卡片（全端共用）：半透明＋背景模糊＋细边框＋柔和阴影。
///
/// 用 Flutter 跨端 API 实现（[BackdropFilter]＋半透明＋圆角），
/// 不写端专属样式；浅色/深色两套透明度与边框色按当前
/// [ThemeData.brightness] 走，不按平台分支。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = AppTokens.radiusLarge,
    this.height,
  });

  final Widget child;

  /// 卡片内边距（不传时由 child 自己留白，与普通 Card 用法一致）。
  final EdgeInsetsGeometry? padding;

  /// 卡片外边距。
  final EdgeInsetsGeometry? margin;

  /// 圆角（全端统一，默认 16，见 [AppTokens.radiusLarge]）。
  final double borderRadius;

  /// 固定高度（不传时由 child 内容定高）。首页状态卡与流量格用它
  /// 统一高度：内容超长时内部省略，不把卡片撑高。
  final double? height;

  @override
  Widget build(BuildContext context) {
    final tokens = appThemeTokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(borderRadius);
    return Container(
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.10),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              // 白天是象牙白半透明、夜晚是白 8% 半透明（品牌色走，
              // 毛玻璃效果保留：半透明＋背景模糊＋细边框＋柔和阴影）。
              color: dark
                  ? Colors.white.withValues(alpha: 0.08)
                  : tokens.background.withValues(alpha: 0.6),
              borderRadius: radius,
              border: Border.all(
                color: dark
                    ? Colors.white.withValues(alpha: 0.15)
                    : Colors.white.withValues(alpha: 0.65),
                width: 1,
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
