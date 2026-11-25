import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/app_motion.dart';
import '../core/app_theme.dart';
import '../core/app_tokens.dart';

/// 大开关的中心图标（可替换组件，图标由参数传入）。
///
/// 不要传统电源符号（⏻）：默认放 Logo v1 的信号弧＋哲人侧脸线条版
///（[SignalPhilosopherPainter]）；定稿图标以后由 [icon] 传入替换
/// 即可，按钮实现不用改。
/// 开/关只换颜色与弧光：开是淡金高光＋信号弧由内向外逐圈亮起，
/// 关只剩淡轮廓。
class PowerButtonIcon extends StatelessWidget {
  const PowerButtonIcon({
    super.key,
    this.icon,
    required this.color,
    this.size = 48,
    this.isOn = true,
    this.animation,
  });

  /// 定稿图标（以后传）；null 时显示信号弧＋哲人侧脸线条版。
  final IconData? icon;

  final Color color;

  final double size;

  /// 是否已连接：开时弧光逐圈亮起，关时只剩淡轮廓。
  final bool isOn;

  /// 呼吸动画（按钮的呼吸控制器）：传了就按它的进度逐圈点亮信号弧，
  /// 不传时弧光全亮（静态，如减弱动态时）。
  final Animation<double>? animation;

  @override
  Widget build(BuildContext context) {
    if (icon != null) {
      return Icon(icon, size: size, color: color);
    }
    final painter = SignalPhilosopherPainter(
      color,
      isOn: isOn,
      progress: animation?.value ?? 0,
      animated: animation != null,
    );
    final anim = animation;
    if (anim == null) {
      return CustomPaint(size: Size(size, size), painter: painter);
    }
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) => CustomPaint(
        size: Size(size, size),
        painter: SignalPhilosopherPainter(
          color,
          isOn: isOn,
          progress: anim.value,
          animated: true,
        ),
      ),
    );
  }
}

/// 信号弧＋哲人侧脸线条版（终稿，按 Logo v1 重画）：
///
/// - 侧脸朝右：额头—眉—鼻—唇—大胡子—颈，细线描边、没有填充；
/// - 头顶一枝月桂（茎＋三片叶）；
/// - 脸右侧三道信号弧向外扩散；
/// - 开时信号弧由内向外逐圈亮起（[progress] 是 0–1 的呼吸周期，
///   每道弧错开 1/3 周期）；关时只剩淡轮廓。
class SignalPhilosopherPainter extends CustomPainter {
  SignalPhilosopherPainter(
    this.color, {
    this.isOn = true,
    this.progress = 0,
    this.animated = true,
  });

  final Color color;

  /// 是否已连接。
  final bool isOn;

  /// 呼吸周期进度 0–1（[animated] 为 false 时忽略）。
  final double progress;

  /// 是否逐圈点亮；false 时三道弧全亮（静态）。
  final bool animated;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 线宽按图标尺寸档走（md 24px 网格对应 2px 线，见 AppIconSize）。
    final stroke = AppIconSize.md.stroke * (w / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // 脸与月桂：开时全亮、关时淡轮廓。
    final faceAlpha = isOn ? 1.0 : 0.35;
    paint.color = color.withValues(alpha: faceAlpha);
    fillPaint.color = color.withValues(alpha: faceAlpha);

    // 侧脸轮廓（朝右）：头顶—额头—眉—鼻尖—唇—下巴—大胡子尖。
    // 脸整体左移、鼻子与信号弧之间留出空位，侧脸才有横向舒展；
    // 头顶与后脑不要同一点起笔，留开口、别闭合成环。
    final face = Path()
      ..moveTo(w * 0.30, h * 0.24)
      ..cubicTo(w * 0.40, h * 0.235, w * 0.47, h * 0.27, w * 0.50, h * 0.325)
      ..cubicTo(w * 0.51, h * 0.35, w * 0.51, h * 0.365, w * 0.505, h * 0.38)
      ..cubicTo(w * 0.56, h * 0.39, w * 0.625, h * 0.415, w * 0.64, h * 0.445)
      ..cubicTo(w * 0.635, h * 0.47, w * 0.595, h * 0.485, w * 0.565, h * 0.495)
      ..cubicTo(w * 0.59, h * 0.51, w * 0.595, h * 0.53, w * 0.57, h * 0.545)
      ..cubicTo(w * 0.545, h * 0.56, w * 0.525, h * 0.57, w * 0.51, h * 0.585)
      ..cubicTo(w * 0.46, h * 0.65, w * 0.385, h * 0.72, w * 0.375, h * 0.79)
      ..cubicTo(w * 0.375, h * 0.835, w * 0.41, h * 0.86, w * 0.455, h * 0.85);
    canvas.drawPath(face, paint);

    // 后脑—颈（与脸线分开起笔，底部留开口）。
    final back = Path()
      ..moveTo(w * 0.22, h * 0.28)
      ..cubicTo(w * 0.175, h * 0.33, w * 0.16, h * 0.42, w * 0.175, h * 0.50)
      ..cubicTo(w * 0.19, h * 0.58, w * 0.215, h * 0.65, w * 0.24, h * 0.72);
    canvas.drawPath(back, paint);

    // 眉＋眼睛（实心圆点）。
    canvas.drawLine(
      Offset(w * 0.42, h * 0.39),
      Offset(w * 0.52, h * 0.38),
      paint,
    );
    canvas.drawCircle(Offset(w * 0.47, h * 0.43), w * 0.022, fillPaint);

    // 月桂枝：茎＋三片叶脉线（短线、圆头、沿茎分开斜向上，
    // 实心椭圆叶在小尺寸下会糊成横条，改用叶脉线）。
    final laurel = Path()
      ..moveTo(w * 0.19, h * 0.235)
      ..quadraticBezierTo(w * 0.30, h * 0.14, w * 0.45, h * 0.115);
    canvas.drawPath(laurel, paint);
    for (final leaf in [
      (0.26, 0.19, 0.205, 0.14),
      (0.335, 0.155, 0.315, 0.085),
      (0.41, 0.13, 0.405, 0.065),
    ]) {
      canvas.drawLine(
        Offset(w * leaf.$1, h * leaf.$2),
        Offset(w * leaf.$3, h * leaf.$4),
        paint,
      );
    }

    // 三道信号弧：弧心在脸右侧（口鼻高度），向右张开。
    // 开时逐圈亮起（每道错开 1/3 周期），关时淡轮廓；
    // 静态（减弱动态）时三道全亮。
    // 弧比脸线细一档、间距拉开，开态满透明度也不会糊成一片扇形。
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 0.65
      ..strokeCap = StrokeCap.round;
    final arcCenter = Offset(w * 0.72, h * 0.47);
    for (var i = 0; i < 3; i++) {
      final radius = w * (0.11 + 0.07 * i);
      final double alpha;
      if (!isOn) {
        alpha = 0.25;
      } else if (!animated) {
        alpha = 1.0;
      } else {
        final pulse = 0.5 - 0.5 * math.cos(2 * math.pi * (progress - i / 3));
        alpha = 0.45 + 0.55 * pulse;
      }
      canvas.drawArc(
        Rect.fromCircle(center: arcCenter, radius: radius),
        -0.9,
        1.8,
        false,
        arcPaint..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(SignalPhilosopherPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.isOn != isOn ||
      oldDelegate.animated != animated ||
      oldDelegate.progress != progress;
}

/// 渐变呼吸电源开关（全端共用）：圆形、开/关两种状态一眼分清。
///
/// - 开：深蓝渐变＋呼吸动效（光晕一圈一圈扩散、按钮轻微缩放循环）
///   ＋金色信号弧图标（光晕也走金色/深蓝，不要紫色），
///   信号弧由内向外逐圈亮起；
/// - 关：灰色＋无动效＋无光晕＋暗色图标，只剩淡轮廓；
/// - 开与关的切换本身 250ms 平滑过渡（渐变/光晕淡入淡出，
///   不是瞬间跳变）。
///
/// 用 Flutter 跨端动画 API 实现，不写端专属样式。
/// 注意：呼吸控制器只在“开”时转，关时停住——测试里 `pumpAndSettle`
/// 在关态下不会被无限动画卡住；系统减弱动态时也不转。
class BreathingPowerButton extends StatefulWidget {
  const BreathingPowerButton({
    super.key,
    required this.isOn,
    required this.enabled,
    required this.onPressed,
    this.size = 120,
    this.icon,
  });

  /// 是否已连接（开）。
  final bool isOn;

  /// 是否可点（连接中/断开中时不可点）。
  final bool enabled;

  final VoidCallback onPressed;

  /// 按钮直径。
  final double size;

  /// 中心图标（见 [PowerButtonIcon]；不传时显示信号弧＋哲人侧脸）。
  final IconData? icon;

  @override
  State<BreathingPowerButton> createState() => _BreathingPowerButtonState();
}

class _BreathingPowerButtonState extends State<BreathingPowerButton>
    with SingleTickerProviderStateMixin {
  /// 一圈呼吸约 2.4 秒；只在“开”时循环，关时停住。
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  // initState 里不能读 MediaQuery（减弱动态），呼吸同步只走
  // didChangeDependencies（首次构建时也会调）与 didUpdateWidget。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(BreathingPowerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOn != oldWidget.isOn) _syncAnimation();
  }

  /// 呼吸只在“开”且系统没减弱动态时转；否则停住并归零，
  /// 信号弧按静态全亮画（不留半亮的弧）。
  void _syncAnimation() {
    final reduceMotion = AppMotion.animationsDisabled(context);
    if (widget.isOn && !reduceMotion) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 开是淡金高光信号弧（更柔）、关是暗色图标。
    final brightIconColor = appThemeTokensOf(context).goldHighlight;
    final darkIconColor = theme.colorScheme.onSurfaceVariant;
    final reduceMotion = AppMotion.animationsDisabled(context);
    return SizedBox(
      width: widget.size * 1.7,
      height: widget.size * 1.7,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // 按钮轻微缩放：只在“开”时呼吸（1.0 → 1.04 → 1.0），关时静止。
          final scale = widget.isOn && !reduceMotion
              ? 1.0 +
                    0.04 *
                        (0.5 - 0.5 * math.cos(_controller.value * 2 * math.pi))
              : 1.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              // 三圈光晕：开时依次扩散（每圈错开 1/3 周期），由浓转淡；
              // 关时 250ms 淡出、无光晕。光晕走柔金色（淡金高光，
              // 低透明度扩散，不要亮金）。
              AnimatedOpacity(
                opacity: widget.isOn ? 1.0 : 0.0,
                duration: AppMotion.state,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    for (var i = 0; i < 3; i++)
                      _HaloRing(
                        progress: (_controller.value + i / 3) % 1.0,
                        size: widget.size,
                        color: appThemeTokensOf(context).goldHighlight,
                      ),
                  ],
                ),
              ),
              Transform.scale(scale: scale, child: child),
            ],
          );
        },
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.enabled ? widget.onPressed : null,
            customBorder: const CircleBorder(),
            child: AnimatedContainer(
              duration: AppMotion.state,
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // 开：深蓝渐变（墨蓝 → 次深蓝）；关：灰色。渐变本身
                // 250ms 平滑过渡。开时再描一道金色细环（细线点缀，
                // 不要大面积金色）。
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: widget.isOn
                      ? appThemeTokensOf(context).powerGradient
                      : appThemeTokensOf(context).powerOffGradient,
                ),
                border: Border.all(
                  color: widget.isOn
                      ? appThemeTokensOf(context).gold.withValues(alpha: 0.7)
                      : Colors.white.withValues(alpha: 0.15),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color:
                        (widget.isOn
                                ? appThemeTokensOf(context).powerGradient.last
                                : appThemeTokensOf(context)
                                    .powerOffGradient
                                    .last)
                            .withValues(alpha: widget.isOn ? 0.45 : 0.2),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              // 中心图标：开亮色、关暗色，两层 250ms 交叉淡入淡出。
              // 开的那层接呼吸控制器，信号弧逐圈亮起；减弱动态时
              // 不接控制器，弧光静态全亮。
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedOpacity(
                    opacity: widget.isOn ? 1.0 : 0.0,
                    duration: AppMotion.state,
                    child: PowerButtonIcon(
                      icon: widget.icon,
                      color: brightIconColor,
                      isOn: true,
                      animation: reduceMotion ? null : _controller,
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: widget.isOn ? 0.0 : 1.0,
                    duration: AppMotion.state,
                    child: PowerButtonIcon(
                      icon: widget.icon,
                      color: darkIconColor,
                      isOn: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一圈扩散光晕：从按钮边缘向外扩到 1.6 倍，同时透明度由 0.30 淡到 0
///（柔金色低透明度扩散，不要亮金）。
class _HaloRing extends StatelessWidget {
  const _HaloRing({
    required this.progress,
    required this.size,
    required this.color,
  });

  /// 扩散进度 0.0–1.0。
  final double progress;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 1.0 + 0.6 * progress,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withValues(alpha: 0.30 * (1 - progress)),
            width: 2,
          ),
        ),
      ),
    );
  }
}
