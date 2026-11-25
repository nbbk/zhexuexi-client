import 'package:material_ui/material_ui.dart';

/// 全端共用的动效规范：时长统一 200–300ms，别有的快有的慢。
///
/// - 页面切换：淡入＋从右滑入（[fadeSlideRoute]），250ms；
/// - 按压反馈：Material 自带的 splash 与 highlight，或
///   [AnimatedScale] 按压缩放，200ms；
/// - 列表增删：[AnimatedList]，250ms；
/// - 状态切换（选中态、开关开/关）：[AnimatedContainer]，250ms。
class AppMotion {
  AppMotion._();

  /// 页面切换时长。
  static const Duration page = Duration(milliseconds: 250);

  /// 按压反馈时长。
  static const Duration press = Duration(milliseconds: 200);

  /// 列表增删过渡时长。
  static const Duration list = Duration(milliseconds: 250);

  /// 状态切换（选中态、开关开/关、渐变淡入淡出）时长。
  static const Duration state = Duration(milliseconds: 250);
}

/// 平滑转场：淡入＋从右滑入（250ms），页面切换不要直接跳变。
/// 多订阅管理页等新开的页面都走这个，不要直接用 [MaterialPageRoute]。
PageRouteBuilder<T> fadeSlideRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    transitionDuration: AppMotion.page,
    reverseTransitionDuration: AppMotion.page,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final fade = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
      );
      final slide = Tween<Offset>(
        begin: const Offset(0.08, 0),
        end: Offset.zero,
      ).animate(fade);
      return FadeTransition(
        opacity: fade,
        child: SlideTransition(position: slide, child: child),
      );
    },
  );
}
