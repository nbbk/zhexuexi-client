// 0.1.2：第 6 条开关中心图案按 Logo v1（金色实心哲人脸）重画的
// golden 测试。
//
// 注意：首次生成（--update-goldens）后必须人工对照
// assets/logo/logo.png 肉眼验收 48px 与 120px 两档，
// 不得自动通过——golden 只是防回归，不证明像 Logo。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhexuexi_client/widgets/power_button.dart';

const _gold = Color(0xFFF4D89A);
const _nightBg = Color(0xFF070F1C);
const _dayBg = Color(0xFFFAF7F0);

Finder _painterFinder() => find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter is SignalPhilosopherPainter,
);

Future<void> _pumpPainter(
  WidgetTester tester, {
  required double size,
  required bool isOn,
  required double progress,
  required Color background,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: background,
        body: Center(
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: SignalPhilosopherPainter(
                _gold,
                isOn: isOn,
                progress: progress,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('48px 开态夜晚：动画进度 0', (tester) async {
    await _pumpPainter(
      tester,
      size: 48,
      isOn: true,
      progress: 0,
      background: _nightBg,
    );
    await expectLater(
      _painterFinder(),
      matchesGoldenFile('goldens/power_button_logo_48_on_night_p0.png'),
    );
  });

  testWidgets('48px 开态夜晚：动画进度 0.5', (tester) async {
    await _pumpPainter(
      tester,
      size: 48,
      isOn: true,
      progress: 0.5,
      background: _nightBg,
    );
    await expectLater(
      _painterFinder(),
      matchesGoldenFile('goldens/power_button_logo_48_on_night_p50.png'),
    );
  });

  testWidgets('48px 开态夜晚：动画进度 1', (tester) async {
    await _pumpPainter(
      tester,
      size: 48,
      isOn: true,
      progress: 1,
      background: _nightBg,
    );
    await expectLater(
      _painterFinder(),
      matchesGoldenFile('goldens/power_button_logo_48_on_night_p100.png'),
    );
  });

  testWidgets('48px 关态夜晚', (tester) async {
    await _pumpPainter(
      tester,
      size: 48,
      isOn: false,
      progress: 0.5,
      background: _nightBg,
    );
    await expectLater(
      _painterFinder(),
      matchesGoldenFile('goldens/power_button_logo_48_off_night_p50.png'),
    );
  });

  testWidgets('48px 开态白天', (tester) async {
    await _pumpPainter(
      tester,
      size: 48,
      isOn: true,
      progress: 0.5,
      background: _dayBg,
    );
    await expectLater(
      _painterFinder(),
      matchesGoldenFile('goldens/power_button_logo_48_on_day_p50.png'),
    );
  });

  testWidgets('48px 关态白天', (tester) async {
    await _pumpPainter(
      tester,
      size: 48,
      isOn: false,
      progress: 0.5,
      background: _dayBg,
    );
    await expectLater(
      _painterFinder(),
      matchesGoldenFile('goldens/power_button_logo_48_off_day_p50.png'),
    );
  });

  testWidgets('120px 开态夜晚（人工验收大档）', (tester) async {
    await _pumpPainter(
      tester,
      size: 120,
      isOn: true,
      progress: 0.5,
      background: _nightBg,
    );
    await expectLater(
      _painterFinder(),
      matchesGoldenFile('goldens/power_button_logo_120_on_night_p50.png'),
    );
  });
}
