// 0.1.2：公告跑马灯（自研，不引包）的回归测试。
//
// 不依赖真实字体度量：长文本用 60 个字符（测试字体下远宽于容器），
// 只断言位移速度与切换行为，不写死文本像素宽。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/widgets/announcement_marquee.dart';

// 长文本用 ASCII：测试字体下每个字符宽一个字号（14px），
// 60 个字符约 840px，远宽于 200px 容器，一定触发滚动；
// 中文字符在测试字体里量出的宽度不可靠，不用它断言滚动。
const String _longLine =
    'This is a very long announcement title for marquee scrolling test 0123456789';

double _offset(WidgetTester tester) {
  // 只取跑马灯自己的 Transform（Scaffold/Center 里另有 Transform，
  // 全局找会命中多个）。
  final transform = tester.widget<Transform>(
    find.descendant(
      of: find.byType(AnnouncementMarquee),
      matching: find.byType(Transform),
    ),
  );
  return transform.transform.getTranslation().x;
}

Future<void> _pumpMarquee(
  WidgetTester tester,
  List<String> lines, {
  double width = 200,
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Center(
            child: SizedBox(
              width: width,
              child: AnnouncementMarquee(lines: lines),
            ),
          ),
        ),
      ),
    ),
  );
  // 首帧的 post-frame 回调跑完（量宽度、启动静止定时器）。
  await tester.pump();
}

void main() {
  testWidgets('短文本静止不动', (tester) async {
    await _pumpMarquee(tester, ['短文本']);
    expect(_offset(tester), 0);
    await tester.pump(const Duration(seconds: 5));
    expect(_offset(tester), 0);
    expect(find.text('短文本'), findsOneWidget);
  });

  testWidgets('长文本：静止 1.2 秒后滚动，1 秒位移约 50px', (tester) async {
    await _pumpMarquee(tester, [_longLine]);
    expect(_offset(tester), 0);
    // 静止 1.2 秒内不动。
    await tester.pump(const Duration(milliseconds: 1200));
    expect(_offset(tester), 0);
    // 再滚 1 秒：速度 50px/s，位移约 -50。
    await tester.pump(const Duration(seconds: 1));
    expect(_offset(tester), closeTo(-50, 15));
  });

  testWidgets('多条切换：短文本静止 3 秒后淡出切下一条', (tester) async {
    await _pumpMarquee(tester, ['短A', '短B']);
    expect(find.text('短A'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('短B'), findsOneWidget);
    expect(find.text('短A'), findsNothing);
  });

  testWidgets('单条长文本循环：滚完一份回到开头继续滚', (tester) async {
    await _pumpMarquee(tester, [_longLine]);
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump(const Duration(seconds: 1));
    expect(_offset(tester), closeTo(-50, 15));
    // 一直滚：位移先变大，滚完一份（文本宽＋48px 间隔）后回到
    // 接近 0 的位置再滚（无缝循环，不是停在末尾）。
    var sawFar = false;
    var restarted = false;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 1));
      final offset = _offset(tester);
      if (offset < -200) sawFar = true;
      // 重启帧本身位移恰为 -0.0（刚从头开滚），也算重启。
      if (sawFar && offset > -60) {
        restarted = true;
        break;
      }
      expect(offset, lessThan(0));
    }
    expect(restarted, isTrue);
  });

  testWidgets('减弱动态：静态显示首条标题，不滚动', (tester) async {
    await _pumpMarquee(
      tester,
      [_longLine, '第二条'],
      disableAnimations: true,
    );
    // 减弱动态时跑马灯内部没有 Transform（纯 Text），也不切下一条。
    expect(
      find.descendant(
        of: find.byType(AnnouncementMarquee),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
    expect(find.text(_longLine), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('第二条'), findsNothing);
  });

  testWidgets('切后台停、恢复续跑', (tester) async {
    await _pumpMarquee(tester, [_longLine]);
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump(const Duration(milliseconds: 500));
    final beforePause = _offset(tester);
    expect(beforePause, closeTo(-25, 15));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 2));
    // 后台 2 秒：位移一点没动。
    expect(_offset(tester), beforePause);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    // flutter_test 的帧时间 quirks：在测试体里调 forward() 后，
    // 第一次 pump(duration) 不推进 ticker（生产环境帧连续跑，
    // 不受影响）；先热身一帧，再滚 1 秒。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    // 恢复后续跑：又滚了约 50px。
    expect(_offset(tester), closeTo(beforePause - 50, 15));
  });

  testWidgets('空列表不渲染', (tester) async {
    await _pumpMarquee(tester, []);
    expect(find.byType(AnnouncementMarquee), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });
}
