// 切片 9：登录页 widget 测试（三个输入框、密码可见切换、加载态、
// 错误常驻显示、登录成功回我的页）。
//
// 不碰真面板：authProvider 用桩 notifier 覆盖（登录只记调用、不发请求）；
// 域名默认值由桩直接给（已按占位规则过滤过的值）。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhexuexi_client/brand/remote_config.dart';
import 'package:zhexuexi_client/features/auth/login_page.dart';
import 'package:zhexuexi_client/services/auth_notifier.dart';
import 'package:zhexuexi_client/services/remote_config_notifier.dart';
import 'package:zhexuexi_client/widgets/app_icon.dart';

/// 远程配置桩：只给 panel_domain，其余走 RemoteConfig.fromJson 默认值。
class _StubRemoteConfigNotifier extends RemoteConfigNotifier {
  _StubRemoteConfigNotifier(this.panelDomain);

  final String panelDomain;

  @override
  RemoteConfigState build() => RemoteConfigState(
    config: RemoteConfig.fromJson({
      'panel': {'panel_domain': panelDomain},
    }),
    source: RemoteConfigSource.bundled,
  );
}

class _StubAuthNotifier extends AuthNotifier {
  _StubAuthNotifier({
    this.defaultDomain = 'ccpanel.jiankong.cf',
    this.loginError,
    this.delayedLogin = false,
  });

  /// defaultPanelDomain 的返回值（已按占位规则过滤：占位域名时为 ''）。
  final String defaultDomain;

  /// 登录失败时要报的原因；为 null 时登录成功。
  final String? loginError;

  /// 为 true 时登录一直挂起，直到测试手动放行（测加载态用）。
  final bool delayedLogin;

  final calls = <String>[];
  Completer<bool>? loginCompleter;

  @override
  AuthState build() => const AuthState();

  @override
  Future<void> restore() async {}

  @override
  Future<String> defaultPanelDomain() async => defaultDomain;

  @override
  Future<bool> login({
    required String panelDomain,
    required String username,
    required String password,
  }) async {
    calls.add('login:$panelDomain:$username');
    if (panelDomain.isEmpty) {
      state = state.copyWith(
        errorMessage: '面板域名不对，请填写面板域名（如 panel.example.com）',
      );
      return false;
    }
    if (username.isEmpty || password.isEmpty) {
      state = state.copyWith(errorMessage: '账号和密码都要填');
      return false;
    }
    if (loginError != null) {
      state = state.copyWith(errorMessage: loginError);
      return false;
    }
    if (delayedLogin) {
      state = state.copyWith(loading: true);
      loginCompleter = Completer<bool>();
      final ok = await loginCompleter!.future;
      state = AuthState(username: ok ? username : null);
      return ok;
    }
    state = AuthState(username: username);
    return true;
  }
}

Future<_StubAuthNotifier> _pumpLoginPage(
  WidgetTester tester, {
  _StubAuthNotifier? stub,
  String? remotePanelDomain,
}) async {
  final authStub = stub ?? _StubAuthNotifier();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => authStub),
        if (remotePanelDomain != null)
          remoteConfigProvider.overrideWith(
            () => _StubRemoteConfigNotifier(remotePanelDomain),
          ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LoginPage()),
              ),
              child: const Text('去登录页'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('去登录页'));
  await tester.pumpAndSettle();
  return authStub;
}

Future<void> _fillLoginForm(
  WidgetTester tester, {
  String domain = 'ccpanel.jiankong.cf',
  String username = 'nianba',
  String password = 'pw123456',
}) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), domain);
  await tester.enterText(fields.at(1), username);
  await tester.enterText(fields.at(2), password);
  await tester.pump();
}

void main() {
  testWidgets('三个输入框 + 登录按钮，域名默认填上次填过的', (tester) async {
    await _pumpLoginPage(tester);
    expect(find.text('面板域名'), findsOneWidget);
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    final domainField = tester.widget<TextField>(find.byType(TextField).at(0));
    expect(domainField.controller?.text, 'ccpanel.jiankong.cf');
    // 密码默认是密文。
    final passwordField = tester.widget<TextField>(
      find.byType(TextField).at(2),
    );
    expect(passwordField.obscureText, isTrue);
  });

  testWidgets('域名框占位符是通用示例域名，不含真实域名', (tester) async {
    await _pumpLoginPage(tester);
    final domainField = tester.widget<TextField>(
      find.byType(TextField).at(0),
    );
    expect(domainField.decoration?.hintText, '如 panel.example.com');
    expect(domainField.decoration?.hintText, isNot(contains('jiankong')));
  });

  testWidgets('域名未配置：域名框留空，提示常驻显示', (tester) async {
    await _pumpLoginPage(tester, stub: _StubAuthNotifier(defaultDomain: ''));
    final domainField = tester.widget<TextField>(find.byType(TextField).at(0));
    expect(domainField.controller?.text, '');
    expect(find.text('面板地址未配置，请填写面板域名'), findsOneWidget);
    // 填上域名后提示消失。
    await tester.enterText(find.byType(TextField).at(0), 'panel.example.org');
    await tester.pump();
    expect(find.text('面板地址未配置，请填写面板域名'), findsNothing);
  });

  testWidgets('拉到远程配置：域名栏不显示，点“使用其他面板”后才出现', (
    tester,
  ) async {
    await _pumpLoginPage(
      tester,
      remotePanelDomain: 'ccpanel.jiankong.cf',
    );
    // 只留账号、密码：域名栏不渲染，域名不在屏幕上。
    expect(find.text('面板域名'), findsNothing);
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('使用其他面板'), findsOneWidget);
    // 点入口：域名框出现，里面预填当前值。
    await tester.tap(find.text('使用其他面板'));
    await tester.pumpAndSettle();
    expect(find.text('面板域名'), findsOneWidget);
    expect(find.text('使用其他面板'), findsNothing);
    final domainField = tester.widget<TextField>(
      find.byType(TextField).at(0),
    );
    expect(domainField.controller?.text, 'ccpanel.jiankong.cf');
  });

  testWidgets('密码可见切换：点眼睛图标切换明文/密文', (tester) async {
    await _pumpLoginPage(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(2)).obscureText,
      isTrue,
    );
    // 密码框的眼睛已迁到 Lucide（AppIcons.eye / eyeOff），
    // 不再是 Material Icons.visibility。
    await tester.tap(find.byIcon(AppIcons.eye));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).at(2)).obscureText,
      isFalse,
    );
  });

  testWidgets('空账号密码点登录：错误常驻显示在页内，不关页面', (tester) async {
    await _pumpLoginPage(tester);
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(find.text('账号和密码都要填'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });

  testWidgets('登录失败：原因常驻显示，页面不关', (tester) async {
    final stub = await _pumpLoginPage(
      tester,
      stub: _StubAuthNotifier(loginError: '账号或密码不对'),
    );
    await _fillLoginForm(tester);
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(find.text('账号或密码不对'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(stub.calls, ['login:ccpanel.jiankong.cf:nianba']);
  });

  testWidgets('登录中：按钮变“登录中…”且防重复点，成功后回我的页', (tester) async {
    final stub = await _pumpLoginPage(
      tester,
      stub: _StubAuthNotifier(delayedLogin: true),
    );
    await _fillLoginForm(tester);
    await tester.tap(find.text('登录'));
    await tester.pump();
    expect(find.text('登录中…'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
      isNull,
    );
    stub.loginCompleter!.complete(true);
    await tester.pumpAndSettle();
    // 回到首页：登录页已 pop。
    expect(find.text('去登录页'), findsOneWidget);
    expect(find.text('账号登录'), findsNothing);
  });

  testWidgets('登录成功：直接回我的页', (tester) async {
    await _pumpLoginPage(tester);
    await _fillLoginForm(tester);
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(find.text('去登录页'), findsOneWidget);
  });
}
