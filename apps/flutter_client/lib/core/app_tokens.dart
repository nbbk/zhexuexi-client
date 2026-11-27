import 'package:material_ui/material_ui.dart';

/// 全端共用的设计 token：圆角、间距、图标尺寸档、导航断点、
/// 列表性能常量。页面与共用组件只读这里的数值，不写死数字。
///
/// 来源是 UI 调研定稿（见 DEV-PLAN §14）：圆角 10/12/16/28、
/// 间距 8/12/16、图标 16/20/24/32 四档；线条宽度随图标尺寸走
///（Lucide 24px 网格、2px 线——字体图标缩放时线条按比例走；
/// 自定义线条图标用 [AppIconSize.stroke] 取设计线宽）。
class AppTokens {
  AppTokens._();

  /// 圆角：小（chip、角标）10、中（输入框、按钮）12、
  /// 大（卡片）16、特大（电源按钮、底部弹窗）28。
  static const double radiusSmall = 10;
  static const double radiusMedium = 12;
  static const double radiusLarge = 16;
  static const double radiusXLarge = 28;

  /// 间距：紧凑 8、常规 12、页面边距 16。
  static const double spacingXs = 8;
  static const double spacingSm = 12;
  static const double spacingMd = 16;

  /// 导航分端断点：宽度 ≥ 700 用桌面左侧导航栏，< 700 用手机
  /// 底部导航栏（见 [AppShell]）。
  static const double navBreakpoint = 700;

  /// 节点行高：节点列表用 SliverFixedExtentList，行高固定 64，
  /// 滚动时按行复用、不量高。
  static const double nodeRowHeight = 64;

  /// 节点列表缓存区：可视区外多留 500px，减少滚动白屏。
  static const double listCacheExtent = 500;

  /// 延迟数字的绿色（成功态）：主题 token 里没有绿色，这里按亮度各取
  /// 一个两端都可读的绿——白天 #157347（白底约 5.9:1），夜晚
  /// #4ADE80（深色底约 11:1）；首页节点弹窗与节点页延迟芯片共用，
  /// 别各写一对（会漂移）。
  static Color latencyOkColor(Brightness brightness) =>
      brightness == Brightness.dark
          ? const Color(0xFF4ADE80)
          : const Color(0xFF157347);
}

/// 图标尺寸档（Lucide 24px 网格、2px 线、圆角端点）。
///
/// 字体图标（[AppIcon]）缩放时线条按比例走；自定义线条图标
///（如哲人侧脸 [SignalPhilosopherPainter]）用 [stroke] 取
/// 该档对应的设计线宽。
enum AppIconSize {
  /// 16px：角标内的小图标。
  xs(16, 1.5),

  /// 20px：行内操作图标。
  sm(20, 1.75),

  /// 24px：默认档（导航、列表 leading、按钮图标）。
  md(24, 2.0),

  /// 32px：大图标。
  lg(32, 2.25);

  const AppIconSize(this.pixels, this.stroke);

  /// 图标边长（逻辑像素）。
  final double pixels;

  /// 该档对应的设计线宽（自定义线条图标用）。
  final double stroke;
}
