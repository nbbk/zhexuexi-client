import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// 全端共用的动效规范：时长统一 200–300ms，别有的快有的慢。
///
/// - 页面切换：淡入＋从右滑入（[fadeSlideRoute] / [appPageRoute]），300ms；
/// - 按压反馈：Material 自带的 splash 与 highlight，或
///   [AnimatedScale] 按压缩放，200ms；
/// - 列表增删：[AnimatedList]，250ms；首次入场逐项间隔 80ms；
/// - 状态切换（选中态、开关开/关）：[AnimatedContainer]，250ms；
/// - 节点进详情（[OpenContainer]）：450ms；
/// - 卡片展开 / 弹窗：300–400ms（[showAppDialog] 用 350ms）。
///
/// 跟随系统减弱动态：系统开了“减弱动态”时所有动效归零
///（[AppMotion.effective]）；呼吸、转圈等循环动画也停住。
class AppMotion {
  AppMotion._();

  /// 页面切换时长。
  static const Duration page = Duration(milliseconds: 300);

  /// 按压反馈时长。
  static const Duration press = Duration(milliseconds: 200);

  /// 列表增删过渡时长。
  static const Duration list = Duration(milliseconds: 250);

  /// 状态切换（选中态、开关开/关、渐变淡入淡出）时长。
  static const Duration state = Duration(milliseconds: 250);

  /// 列表首次入场逐项间隔（第 n 行晚 n×80ms 出现，只首次）。
  static const Duration stagger = Duration(milliseconds: 80);

  /// 节点进详情（OpenContainer）时长。
  static const Duration detail = Duration(milliseconds: 450);

  /// 卡片展开 / 弹窗时长。
  static const Duration expand = Duration(milliseconds: 350);

  /// 跟随系统减弱动态：系统开了“减弱动态”时动效归零，
  /// 否则返回原时长。所有动效入口都走它。
  static Duration effective(BuildContext context, Duration duration) {
    return MediaQuery.of(context).disableAnimations ? Duration.zero : duration;
  }

  /// 当前是否减弱动态（循环动画用它决定要不要转）。
  static bool animationsDisabled(BuildContext context) {
    return MediaQuery.of(context).disableAnimations;
  }
}

/// 平滑转场：淡入＋从右滑入（300ms），页面切换不要直接跳变。
/// 多订阅管理页等新开的页面都走这个，不要直接用 [MaterialPageRoute]。
/// iOS 右滑返回见 [appPageRoute]。
PageRouteBuilder<T> fadeSlideRoute<T>(
  WidgetBuilder builder, {
  Duration duration = AppMotion.page,
}) {
  return PageRouteBuilder<T>(
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
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

/// 页面路由（统一入口）：淡入＋轻微右滑，300ms。
///
/// iOS 走 [_FadeSlideCupertinoRoute]（[CupertinoPageRoute] 子类），
/// 转场同样是淡入＋右滑 300ms，但保留原生右滑返回手势；
/// 其他端走 [fadeSlideRoute]。减弱动态时两档时长都归零。
PageRoute<T> appPageRoute<T>(BuildContext context, WidgetBuilder builder) {
  final duration = AppMotion.effective(context, AppMotion.page);
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return _FadeSlideCupertinoRoute<T>(
      builder: builder,
      routeDuration: duration,
    );
  }
  return fadeSlideRoute<T>(builder, duration: duration);
}

/// iOS 页面路由：淡入＋右滑 300ms，同时保留原生右滑返回。
///
/// [CupertinoPageRoute] 的右滑返回手势与转场实现无关，
/// 只改 [buildTransitions] 不影响手势。
class _FadeSlideCupertinoRoute<T> extends CupertinoPageRoute<T> {
  _FadeSlideCupertinoRoute({
    required super.builder,
    required this.routeDuration,
  });

  final Duration routeDuration;

  @override
  Duration get transitionDuration => routeDuration;

  @override
  Duration get reverseTransitionDuration => routeDuration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    final slide = Tween<Offset>(
      begin: const Offset(0.08, 0),
      end: Offset.zero,
    ).animate(fade);
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(position: slide, child: child),
    );
  }
}

/// 弹窗（统一入口）：淡入＋轻微缩放，350ms。
///
/// 代替裸 [showDialog]：弹窗不要瞬间跳出来；减弱动态时归零。
/// [builder] 返回的一般是 [AlertDialog]，居中由它自己定。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final duration = AppMotion.effective(context, AppMotion.expand);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: duration,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}
