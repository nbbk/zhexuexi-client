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

/// 信号弧＋哲人侧脸实心版（终稿，按 Logo v1 重画，2026-11-26 0.1.2）：
/// v1 定稿是金色实心哲人脸（assets/logo/logo.png），“留白脸”是
/// v2 备选；这里按 v1 做——
/// - 侧脸朝右：实心填充剪影（额头—鼻—唇—下颌—颈），眉眼用
///   evenOdd 镂空进同一条脸路径；
/// - 下巴三股填充胡须（两股长须＋一滴小须）；
/// - 头顶一枝月桂（茎＋7 片填充椭圆叶）；
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
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // 脸与月桂：开时全亮、关时淡轮廓。
    final faceAlpha = isOn ? 1.0 : 0.35;
    fillPaint.color = color.withValues(alpha: faceAlpha);

    // 侧脸剪影（朝右，金色实心填充，按 Logo v1 锚点）：
    // 顶左 → 额顶右 → 右缘 → 鼻梁 → 鼻尖 → 鼻底回折 → 唇折线 →
    // 下颌 → 左缘内凹腰 → 颈底 → 闭合（后脑左缘略内凹）。
    // 眉眼用 PathFillType.evenOdd 镂空进同一条脸路径。
    final face = Path()
      ..moveTo(w * 0.06, h * 0.33)
      ..lineTo(w * 0.56, h * 0.23)
      ..lineTo(w * 0.59, h * 0.32)
      ..lineTo(w * 0.62, h * 0.38)
      ..lineTo(w * 0.65, h * 0.43)
      ..lineTo(w * 0.59, h * 0.44)
      ..lineTo(w * 0.55, h * 0.45)
      ..lineTo(w * 0.53, h * 0.47)
      ..lineTo(w * 0.49, h * 0.51)
      ..quadraticBezierTo(w * 0.10, h * 0.52, w * 0.12, h * 0.55)
      ..lineTo(w * 0.26, h * 0.67)
      ..quadraticBezierTo(w * 0.08, h * 0.50, w * 0.06, h * 0.33)
      ..close()
      // 眉（圆角矩形）与眼（圆）镂空。
      // 2026-11-26 golden 肉眼验收：眉底与眼顶原先重叠（0.33/0.313），
      // 镂空连成一个团；眉收窄到 0.315、眼下移到 0.36，
      // 两者分开才像 Logo（眉是斜杠、眼是圆点）。
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(w * 0.40, h * 0.28, w * 0.55, h * 0.315),
          Radius.circular(w * 0.015),
        ),
      )
      ..addOval(
        Rect.fromCircle(
          center: Offset(w * 0.49, h * 0.36),
          radius: w * 0.027,
        ),
      );
    face.fillType = PathFillType.evenOdd;
    canvas.drawPath(face, fillPaint);

    // 胡子：3 股填充须片（按 Logo v1：两股长须向下扫＋一滴小须）。
    // 左长须：根部 x 0.28–0.42、y 0.51，扫至尖 (0.45, 0.87)。
    final beardLeft = Path()
      ..moveTo(w * 0.28, h * 0.51)
      ..quadraticBezierTo(w * 0.26, h * 0.70, w * 0.45, h * 0.87)
      ..quadraticBezierTo(w * 0.44, h * 0.68, w * 0.42, h * 0.51)
      ..close();
    canvas.drawPath(beardLeft, fillPaint);
    // 右长须：根部 x 0.48–0.56、y 0.50，扫至尖 (0.61, 0.87)。
    final beardRight = Path()
      ..moveTo(w * 0.48, h * 0.50)
      ..quadraticBezierTo(w * 0.50, h * 0.68, w * 0.61, h * 0.87)
      ..quadraticBezierTo(w * 0.58, h * 0.66, w * 0.56, h * 0.50)
      ..close();
    canvas.drawPath(beardRight, fillPaint);
    // 泪滴小须：中心 (0.53, 0.62)，尺寸 0.07×0.15。
    final beardDrop = Path()
      ..moveTo(w * 0.53, h * 0.545)
      ..quadraticBezierTo(w * 0.565, h * 0.60, w * 0.53, h * 0.695)
      ..quadraticBezierTo(w * 0.495, h * 0.60, w * 0.53, h * 0.545)
      ..close();
    canvas.drawPath(beardDrop, fillPaint);

    // 月桂枝：茎＋7 片填充椭圆叶（按 Logo v1；小尺寸下叶糊成一团
    // 时退路是减为 5 片，见 PATCH_NOTES 0.1.2）。
    final stemPaint = Paint()
      ..color = color.withValues(alpha: faceAlpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 0.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(w * 0.09, h * 0.19),
      Offset(w * 0.53, h * 0.14),
      stemPaint,
    );
    void drawLeaf(double cx, double cy, double tilt) {
      canvas.save();
      canvas.translate(w * cx, h * cy);
      canvas.rotate(tilt);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: w * 0.075,
          height: w * 0.035,
        ),
        fillPaint,
      );
      canvas.restore();
    }

    // 上排三片（-35°）、下排三片（+35°）、顶叶一片。
    for (final leaf in const [
      (0.18, 0.15, -0.61),
      (0.29, 0.12, -0.61),
      (0.42, 0.09, -0.61),
      (0.21, 0.21, 0.61),
      (0.32, 0.18, 0.61),
      (0.46, 0.15, 0.61),
      (0.52, 0.14, -0.61),
    ]) {
      drawLeaf(leaf.$1, leaf.$2, leaf.$3);
    }

    // 三道信号弧：弧心在脸右侧（口鼻高度），向右张开。
    // 开时逐圈亮起（每道错开 1/3 周期），关时淡轮廓；
    // 静态（减弱动态）时三道全亮。
    // 弧比脸线细一档、间距拉开，开态满透明度也不会糊成一片扇形。
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 0.55
      ..strokeCap = StrokeCap.round;
    final arcCenter = Offset(w * 0.59, h * 0.48);
    for (var i = 0; i < 3; i++) {
      final radius = w * const [0.13, 0.24, 0.34][i];
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
        -1.22,
        2.44,
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
