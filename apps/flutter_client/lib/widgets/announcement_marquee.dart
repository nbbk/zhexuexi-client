import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// 公告跑马灯（自研，不引包；2026-11-26 0.1.2 第 3 条）。
///
/// 行为（用户定稿）：
/// - 多条：逐条滚完切下一条，每条静止 1.2 秒 → 滚动 → 末尾静止
///   1.2 秒 → 淡出切换 250ms；
/// - 短文本（宽 ≤ 可视宽）不滚动，静止 3 秒后切下一条；
/// - 单条长文本：在文本后拼一份副本＋48px 间隔，无缝循环；
/// - 速度默认 50 px/s（[velocityPxPerSecond]），滚动时长按
///   `距离 / 速度` 算；
/// - 切后台停、恢复续跑；系统减弱动态时静态显示首条标题；
/// - 语义给完整标题（滚动中的截断文本不进无障碍树）。
class AnnouncementMarquee extends StatefulWidget {
  const AnnouncementMarquee({
    super.key,
    required this.lines,
    this.velocityPxPerSecond = 50,
  });

  /// 要轮播的标题行（[Announcement.displayLine]）。
  final List<String> lines;

  /// 滚动速度（像素/秒），默认 50。
  final double velocityPxPerSecond;

  @override
  State<AnnouncementMarquee> createState() => _AnnouncementMarqueeState();
}

enum _Phase { stillStart, scrolling, stillEnd, fading }

class _AnnouncementMarqueeState extends State<AnnouncementMarquee>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller = AnimationController(
    vsync: this,
  )..addStatusListener(_onScrollStatus);

  Timer? _timer;
  int _index = 0;
  double _opacity = 1.0;
  _Phase _phase = _Phase.stillStart;
  bool _paused = false;
  bool _reduceMotion = false;

  String _currentLine = '';
  double _textWidth = 0;
  double _viewWidth = 0;
  bool _needsScroll = false;

  /// 单条长文本无缝循环。
  bool get _loop => widget.lines.length == 1 && _needsScroll;

  /// 本次滚动的总距离：多条是“尾巴露出来”（文本宽－可视宽），
  /// 单条循环是“文本宽＋48px 间隔”。
  double get _scrollDistance => _loop
      ? _textWidth + _loopGap
      : (_textWidth - _viewWidth).clamp(0, double.infinity);

  static const Duration _stillDuration = Duration(milliseconds: 1200);
  static const Duration _shortStillDuration = Duration(seconds: 3);
  static const Duration _fadeDuration = Duration(milliseconds: 250);
  static const double _loopGap = 48;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.of(context).disableAnimations;
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      _currentLine = '';
    }
  }

  @override
  void didUpdateWidget(AnnouncementMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lines != widget.lines) {
      _index = 0;
      _currentLine = '';
      _cancelTimer();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelTimer();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // 切后台停：控制器停住（保持当前进度）、定时器取消。
      _paused = true;
      _cancelTimer();
      _controller.stop();
    } else if (state == AppLifecycleState.resumed && _paused) {
      // 恢复续跑：滚动中的从当前进度继续，静止/淡出中的重走本阶段。
      _paused = false;
      switch (_phase) {
        case _Phase.scrolling:
          _controller.forward(from: _controller.value);
        case _Phase.stillStart:
          _scheduleStill(start: true);
        case _Phase.stillEnd:
          _scheduleStill(start: false);
        case _Phase.fading:
          _advanceIndex();
      }
    }
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _onScrollStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_loop) {
      // 单条循环：滚完一份立刻从头再滚（副本＋间隔保证无缝）。
      if (!_paused) _controller.forward(from: 0);
      return;
    }
    // 多条：滚完 → 末尾静止 1.2 秒 → 淡出切下一条。
    _phase = _Phase.stillEnd;
    _scheduleStill(start: false);
  }

  /// 静止阶段的定时器：开头静止 1.2 秒后开滚（短文本静止 3 秒后
  /// 直接切下一条），末尾静止 1.2 秒后淡出切下一条。
  void _scheduleStill({required bool start}) {
    _cancelTimer();
    if (start && !_needsScroll) {
      _timer = Timer(_shortStillDuration, _fadeToNext);
      return;
    }
    _timer = Timer(
      _stillDuration,
      start ? _startScroll : _fadeToNext,
    );
  }

  void _startItem() {
    _cancelTimer();
    _controller.reset();
    _phase = _Phase.stillStart;
    // 单条短文本：一直静态，不开定时器、不淡出。
    if (widget.lines.length == 1 && !_needsScroll) return;
    _scheduleStill(start: true);
  }

  void _startScroll() {
    if (_paused) return;
    _phase = _Phase.scrolling;
    final distance = _scrollDistance;
    if (distance <= 0) {
      _fadeToNext();
      return;
    }
    final ms = (distance / widget.velocityPxPerSecond * 1000).round();
    _controller.duration = Duration(milliseconds: ms);
    _controller.forward(from: 0);
  }

  void _fadeToNext() {
    if (widget.lines.length <= 1 && !_loop) return;
    if (_loop) return;
    _phase = _Phase.fading;
    setState(() => _opacity = 0);
    _cancelTimer();
    _timer = Timer(_fadeDuration, _advanceIndex);
  }

  void _advanceIndex() {
    if (!mounted) return;
    setState(() {
      _index = (_index + 1) % widget.lines.length;
      _opacity = 1.0;
      _currentLine = '';
    });
  }

  double _measure(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) return const SizedBox.shrink();
    // 减弱动态：静态显示首条标题，不开动画、不开定时器。
    if (_reduceMotion) {
      return Text(
        widget.lines.first,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final line = widget.lines[_index % widget.lines.length];
        final style = DefaultTextStyle.of(context).style;
        final textWidth = _measure(line, style);
        if (line != _currentLine || width != _viewWidth) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _currentLine = line;
            _viewWidth = width;
            _textWidth = textWidth;
            _needsScroll = textWidth > width;
            _startItem();
          });
        }
        return Semantics(
          label: line,
          child: ExcludeSemantics(
            // ClipRect＋OverflowBox：长文本 Row 的固有宽超出可视宽是
            // 正常的（要滚出去），不能让 Row 报 overflow 错误；
            // OverflowBox 放行超宽子项，ClipRect 把绘制裁到可视宽。
            child: ClipRect(
              child: AnimatedOpacity(
                opacity: _opacity,
                duration: _fadeDuration,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) => Transform.translate(
                    // 实时读 _scrollDistance：build 时 _textWidth 还是 0，
                    // 捕获的 distance 恒为 0 会让跑马灯永远不动
                    //（控制器在转、位移恒 0；2026-11-26 调试定位）。
                    offset: Offset(
                      -_controller.value * _scrollDistance,
                      0,
                    ),
                    child: child,
                  ),
                  child: OverflowBox(
                    maxWidth: double.infinity,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          line,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.visible,
                        ),
                        if (_loop) ...[
                          const SizedBox(width: _loopGap),
                          Text(
                            line,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.visible,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
