import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/app_motion.dart';
import '../core/app_theme.dart';

/// 大开关的中心图标（可替换组件，图标由参数传入）。
///
/// 不要传统电源符号（⏻）：默认放 Logo 的信号弧＋哲人侧脸线条版
///（线条风：三道信号弧＋哲人侧脸轮廓，都是细线描边）；
/// 定稿图标以后由 [icon] 传入替换即可，按钮实现不用改。
/// 开/关只换颜色：开是淡金高光、关是暗色。
class PowerButtonIcon extends StatelessWidget {
  const PowerButtonIcon({
    super.key,
    this.icon,
    required this.color,
    this.size = 48,
  });

  /// 定稿图标（以后传）；null 时显示信号弧＋哲人侧脸线条版占位。
  final IconData? icon;

  final Color color;

  final double size;

  @override
  Widget build(BuildContext context) {
    if (icon != null) {
      return Icon(icon, size: size, color: color);
    }
    return CustomPaint(
      size: Size(size, size),
      painter: _SignalPhilosopherPainter(color),
    );
  }
}

/// 信号弧＋哲人侧脸线条版：三道同心信号弧从哲人头顶向外扩散，
/// 哲人侧脸是细线轮廓（额头—鼻—唇—下巴—颈），都是描边、没有填充。
class _SignalPhilosopherPainter extends CustomPainter {
  _SignalPhilosopherPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.055
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width;
    final h = size.height;
    // 信号弧：弧心在哲人头顶，向上向外张开。
    final arcCenter = Offset(w * 0.52, h * 0.34);
    for (var i = 0; i < 3; i++) {
      final radius = w * (0.13 + 0.11 * i);
      canvas.drawArc(
        Rect.fromCircle(center: arcCenter, radius: radius),
        -2.5,
        1.6,
        false,
        paint,
      );
    }
    // 哲人侧脸轮廓（朝左）：头顶—额头—鼻梁—鼻尖—唇—下巴—颈。
    final face = Path()
      ..moveTo(w * 0.58, h * 0.30)
      ..cubicTo(w * 0.44, h * 0.28, w * 0.36, h * 0.36, w * 0.36, h * 0.46)
      ..cubicTo(w * 0.36, h * 0.50, w * 0.33, h * 0.52, w * 0.31, h * 0.55)
      ..cubicTo(w * 0.29, h * 0.58, w * 0.31, h * 0.60, w * 0.34, h * 0.61)
      ..cubicTo(w * 0.32, h * 0.64, w * 0.33, h * 0.66, w * 0.36, h * 0.67)
      ..cubicTo(w * 0.34, h * 0.70, w * 0.36, h * 0.72, w * 0.39, h * 0.72)
      ..cubicTo(w * 0.40, h * 0.76, w * 0.44, h * 0.78, w * 0.48, h * 0.77)
      ..cubicTo(w * 0.46, h * 0.84, w * 0.46, h * 0.88, w * 0.50, h * 0.90);
    canvas.drawPath(face, paint);
  }

  @override
  bool shouldRepaint(_SignalPhilosopherPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 渐变呼吸电源开关（全端共用）：圆形、开/关两种状态一眼分清。
///
/// - 开：深蓝渐变＋呼吸动效（光晕一圈一圈扩散、按钮轻微缩放循环）
///   ＋金色信号弧图标（光晕也走金色/深蓝，不要紫色）；
/// - 关：灰色＋无动效＋无光晕＋暗色图标；
/// - 开与关的切换本身 250ms 平滑过渡（渐变/光晕淡入淡出，
///   不是瞬间跳变）。
///
/// 用 Flutter 跨端动画 API 实现，不写端专属样式。
/// 注意：呼吸控制器只在“开”时转，关时停住——测试里 `pumpAndSettle`
/// 在关态下不会被无限动画卡住。
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

  /// 中心图标（见 [PowerButtonIcon]；不传时显示占位圆环）。
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

  @override
  void initState() {
    super.initState();
    if (widget.isOn) _controller.repeat();
  }

  @override
  void didUpdateWidget(BreathingPowerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOn == oldWidget.isOn) return;
    if (widget.isOn) {
      _controller.repeat();
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
    return SizedBox(
      width: widget.size * 1.7,
      height: widget.size * 1.7,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // 按钮轻微缩放：只在“开”时呼吸（1.0 → 1.04 → 1.0），关时静止。
          final scale = widget.isOn
              ? 1.0 +
                    0.04 *
                        (0.5 -
                            0.5 *
                                math.cos(_controller.value * 2 * math.pi))
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
                    color: (widget.isOn
                            ? appThemeTokensOf(context).powerGradient.last
                            : Colors.grey)
                        .withValues(alpha: widget.isOn ? 0.45 : 0.2),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              // 中心图标：开亮色、关暗色，两层 250ms 交叉淡入淡出。
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedOpacity(
                    opacity: widget.isOn ? 1.0 : 0.0,
                    duration: AppMotion.state,
                    child: PowerButtonIcon(
                      icon: widget.icon,
                      color: brightIconColor,
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: widget.isOn ? 0.0 : 1.0,
                    duration: AppMotion.state,
                    child: PowerButtonIcon(
                      icon: widget.icon,
                      color: darkIconColor,
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
