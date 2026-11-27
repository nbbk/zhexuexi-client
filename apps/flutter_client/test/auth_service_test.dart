// 切片 9：账号密码登录服务测试（端口探测顺序 / 记住端口 / 失败映射 /
// 令牌存储）。
//
// 不碰真面板：Dio 用拦截器按端口伪造响应或连接失败；令牌用内存假安全
// 存储；记住的端口与用户名用 SharedPreferences mock。
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/services/auth_service.dart';

class _FakeSecureStorage extends FlutterSecureStorage {
  final _map = <String, String>{};

  @override
  Future<String?> read({required String key, AndroidOptions? aOptions, AppleOptions? iOptions, LinuxOptions? lOptions, WindowsOptions? wOptions, WebOptions? webOptions, AppleOptions? mOptions}) async => _map[key];

  @override
  Future<void> write({required String key, required String? value, AndroidOptions? aOptions, AppleOptions? iOptions, LinuxOptions? lOptions, WindowsOptions? wOptions, WebOptions? webOptions, AppleOptions? mOptions}) async {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }

  @override
  Future<void> delete({required String key, AndroidOptions? aOptions, AppleOptions? iOptions, LinuxOptions? lOptions, WindowsOptions? wOptions, WebOptions? webOptions, AppleOptions? mOptions}) async {
    _map.remove(key);
  }
}

/// 按端口伪造登录响应：[byPort] 是端口 → (状态码, 响应体)；
/// [failPorts] 里的端口直接报连接失败（换下一个端口）；
/// [tried] 按实际尝试顺序记下每个端口。
Dio _fakeDio(
  Map<int, ({int status, String body})> byPort, {
  Set<int> failPorts = const {},
  List<int>? tried,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final port = options.uri.port;
        tried?.add(port);
        if (failPorts.contains(port) || !byPort.containsKey(port)) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: 'Connection refused',
            ),
          );
          return;
        }
        final fake = byPort[port]!;
        final response = Response<String>(
          requestOptions: options,
          statusCode: fake.status,
          data: fake.body,
        );
        if (fake.status >= 200 && fake.status < 300) {
          handler.resolve(response);
        } else {
          handler.reject(
            DioException(
              requestOptions: options,
              response: response,
              type: DioExceptionType.badResponse,
            ),
          );
        }
      },
    ),
  );
  return dio;
}

const _successBody =
    '{"token":"sess_0123456789abcdef","username":"nianba",'
    '"subscription_url":"https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}';

// 真实形状的登录回包（面板 client_login.go）：plan_name 顶层字段 +
// plan 对象（name 为档位名）。
const _successBodyWithPlan =
    '{"token":"sess_0123456789abcdef","username":"nianba",'
    '"plan_name":"标准版",'
    '"plan":{"id":"pl-abc123","name":"标准版","group_id":"","group_name":"",'
    '"traffic_limit_mb":102400,"traffic_limit_mode":"period",'
    '"reset_mode":"monthly","traffic_used":123456,"expires_at":0},'
    '"subscription_url":"https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}';

// 管理员登录：plan 为 null、plan_name 为 ''。
const _successBodyAdmin =
    '{"token":"sess_0123456789abcdef","username":"nianba",'
    '"plan_name":"",'
    '"plan":null,'
    '"subscription_url":"https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('probeOrder', () {
    test('没记住端口：9876 优先，再 9870→9880 跳过 9876', () {
      final order = AuthService.probeOrder(null);
      expect(order.sublist(0, 3), [9876, 9870, 9871]);
      expect(order.length, 11);
      expect(order.toSet().length, 11);
    });

    test('记住 9873：9873 最先，再 9876，再其余端口', () {
      final order = AuthService.probeOrder(9873);
      expect(order.sublist(0, 3), [9873, 9876, 9870]);
      expect(order.length, 11);
      expect(order.toSet().length, 11);
    });

    test('记住的就是 9876：9876 只出现一次', () {
      final order = AuthService.probeOrder(9876);
      expect(order.first, 9876);
      expect(order.where((p) => p == 9876).length, 1);
      expect(order.length, 11);
    });

    test('记住的端口在段外：当作没记住', () {
      expect(AuthService.probeOrder(8999), AuthService.probeOrder(null));
      expect(AuthService.probeOrder(10001), AuthService.probeOrder(null));
      expect(AuthService.probeOrder(11111), AuthService.probeOrder(null));
    });
  });

  group('normalizePanelDomain', () {
    test('裸域名 / 带协议端口路径 / 大小写空格都归一成 host', () {
      expect(
        AuthService.normalizePanelDomain('ccpanel.jiankong.cf'),
        'ccpanel.jiankong.cf',
      );
      expect(
        AuthService.normalizePanelDomain(
          'https://ccpanel.jiankong.cf:11111/x9f2',
        ),
        'ccpanel.jiankong.cf',
      );
      expect(
        AuthService.normalizePanelDomain('  HTTPS://Example.COM/ '),
        'example.com',
      );
      expect(AuthService.normalizePanelDomain('localhost'), 'localhost');
    });

    test('空 / 带空格 / 单段无点 / 下划线都不合法', () {
      expect(AuthService.normalizePanelDomain(''), '');
      expect(AuthService.normalizePanelDomain('not a domain'), '');
      expect(AuthService.normalizePanelDomain('example'), '');
      expect(AuthService.normalizePanelDomain('bad_host.com'), '');
    });
  });

  group('login', () {
    test('域名为空：报通用占位，不含真实域名', () async {
      final service = AuthService(
        dio: Dio(),
        storage: _FakeSecureStorage(),
      );
      await expectLater(
        service.login(
          panelDomain: '',
          username: 'nianba',
          password: 'pw',
        ),
        throwsA(
          isA<AuthException>()
              .having((e) => e.kind, 'kind', AuthErrorKind.invalidDomain)
              .having(
                (e) => e.message,
                'message',
                '面板域名不对，请填写面板域名（如 panel.example.com）',
              ),
        ),
      );
    });

    test('9876 直通：成功，令牌进安全存储，端口被记住', () async {
      final storage = _FakeSecureStorage();
      final tried = <int>[];
      final service = AuthService(
        dio: _fakeDio({9876: (status: 200, body: _successBody)}, tried: tried),
        storage: storage,
      );
      final result = await service.login(
        panelDomain: 'panel.example.com',
        username: 'nianba',
        password: 'pw',
      );
      expect(result.port, 9876);
      expect(result.token, 'sess_0123456789abcdef');
      expect(result.username, 'nianba');
      expect(result.subscriptionUrl, startsWith('https://example.com/'));
      expect(tried, [9876]);
      expect(
        await storage.read(key: 'client_session_token'),
        'sess_0123456789abcdef',
      );
      expect(await service.readRememberedPort(), 9876);
      expect(await service.readUsername(), 'nianba');
      final session = await service.restoreSession();
      expect(session?.username, 'nianba');
    });

    test('9876 不通 → 轮询到 9870，记住 9870', () async {
      final tried = <int>[];
      final service = AuthService(
        dio: _fakeDio(
          {9870: (status: 200, body: _successBody)},
          failPorts: {9876},
          tried: tried,
        ),
        storage: _FakeSecureStorage(),
      );
      final result = await service.login(
        panelDomain: 'panel.example.com',
        username: 'nianba',
        password: 'pw',
      );
      expect(result.port, 9870);
      expect(tried, [9876, 9870]);
      expect(await service.readRememberedPort(), 9870);
    });

    test('记住的端口优先试：记住 9872 且通，只试 9872', () async {
      SharedPreferences.setMockInitialValues({'client_login_port': 9872});
      final tried = <int>[];
      final service = AuthService(
        dio: _fakeDio({9872: (status: 200, body: _successBody)}, tried: tried),
        storage: _FakeSecureStorage(),
      );
      final result = await service.login(
        panelDomain: 'panel.example.com',
        username: 'nianba',
        password: 'pw',
      );
      expect(result.port, 9872);
      expect(tried, [9872]);
    });

    test('记住的端口不通：先试记住的，再 9876，再往下轮询', () async {
      SharedPreferences.setMockInitialValues({'client_login_port': 9872});
      final tried = <int>[];
      final service = AuthService(
        dio: _fakeDio(
          {9875: (status: 200, body: _successBody)},
          failPorts: {9872, 9876, 9870, 9871, 9873, 9874},
          tried: tried,
        ),
        storage: _FakeSecureStorage(),
      );
      final result = await service.login(
        panelDomain: 'panel.example.com',
        username: 'nianba',
        password: 'pw',
      );
      expect(result.port, 9875);
      expect(
        tried,
        [9872, 9876, 9870, 9871, 9873, 9874, 9875],
      );
    });

    test('401：账号或密码不对，不再试其它端口，令牌不存', () async {
      final storage = _FakeSecureStorage();
      final tried = <int>[];
      final service = AuthService(
        dio: _fakeDio(
          {9876: (status: 401, body: '{"error":"bad credentials"}')},
          tried: tried,
        ),
        storage: storage,
      );
      await expectLater(
        service.login(
          panelDomain: 'panel.example.com',
          username: 'nianba',
          password: 'wrong',
        ),
        throwsA(
          isA<AuthException>()
              .having((e) => e.kind, 'kind', AuthErrorKind.wrongCredentials)
              .having((e) => e.message, 'message', '账号或密码不对'),
        ),
      );
      expect(tried, [9876]);
      // 收到响应就算通：端口被记住，下次优先试它。
      expect(await service.readRememberedPort(), 9876);
      expect(await storage.read(key: 'client_session_token'), isNull);
    });

    test('404：面板版本太旧，没有账号登录接口', () async {
      final service = AuthService(
        dio: _fakeDio({9876: (status: 404, body: 'Not Found')}),
        storage: _FakeSecureStorage(),
      );
      await expectLater(
        service.login(
          panelDomain: 'panel.example.com',
          username: 'nianba',
          password: 'pw',
        ),
        throwsA(
          isA<AuthException>()
              .having((e) => e.kind, 'kind', AuthErrorKind.endpointMissing)
              .having(
                (e) => e.message,
                'message',
                '面板版本太旧，没有账号登录接口，请先升级面板',
              ),
        ),
      );
    });

    test('429：请求太频繁', () async {
      final service = AuthService(
        dio: _fakeDio({9876: (status: 429, body: '')}),
        storage: _FakeSecureStorage(),
      );
      await expectLater(
        service.login(
          panelDomain: 'panel.example.com',
          username: 'nianba',
          password: 'pw',
        ),
        throwsA(
          isA<AuthException>()
              .having((e) => e.kind, 'kind', AuthErrorKind.rateLimited),
        ),
      );
    });

    test('11 个端口全不通：面板连接不上', () async {
      final tried = <int>[];
      final service = AuthService(
        dio: _fakeDio({}, tried: tried),
        storage: _FakeSecureStorage(),
      );
      await expectLater(
        service.login(
          panelDomain: 'panel.example.com',
          username: 'nianba',
          password: 'pw',
        ),
        throwsA(
          isA<AuthException>()
              .having((e) => e.kind, 'kind', AuthErrorKind.unreachable)
              .having((e) => e.message, 'message', '面板连接不上，检查面板域名与网络'),
        ),
      );
      expect(tried.length, 11);
      expect(tried.first, 9876);
    });

    test('200 但缺 token：面板返回的数据不对', () async {
      final service = AuthService(
        dio: _fakeDio({9876: (status: 200, body: '{"username":"nianba"}')}),
        storage: _FakeSecureStorage(),
      );
      await expectLater(
        service.login(
          panelDomain: 'panel.example.com',
          username: 'nianba',
          password: 'pw',
        ),
        throwsA(
          isA<AuthException>()
              .having((e) => e.kind, 'kind', AuthErrorKind.invalidResponse),
        ),
      );
    });

    test('200 但不是 JSON：面板返回的数据不对', () async {
      final service = AuthService(
        dio: _fakeDio({9876: (status: 200, body: '<html>not json</html>')}),
        storage: _FakeSecureStorage(),
      );
      await expectLater(
        service.login(
          panelDomain: 'panel.example.com',
          username: 'nianba',
          password: 'pw',
        ),
        throwsA(
          isA<AuthException>()
              .having((e) => e.kind, 'kind', AuthErrorKind.invalidResponse),
        ),
      );
    });

    test('账号下没有订阅：登录成功，subscriptionUrl 为 null', () async {
      final service = AuthService(
        dio: _fakeDio({
          9876: (
            status: 200,
            body: '{"token":"sess_abc","username":"nianba"}',
          ),
        }),
        storage: _FakeSecureStorage(),
      );
      final result = await service.login(
        panelDomain: 'panel.example.com',
        username: 'nianba',
        password: 'pw',
      );
      expect(result.subscriptionUrl, isNull);
      expect(result.username, 'nianba');
    });
  });

  group('planName 解析（0.1.12）', () {
    test('plan_name 优先：回包 plan_name 有值就用它', () {
      expect(
        AuthService.resolvePlanName({
          'plan_name': '标准版',
          'plan': {'name': '旧档位'},
        }),
        '标准版',
      );
    });

    test('plan_name 为空：退到 plan.name', () {
      expect(
        AuthService.resolvePlanName({
          'plan_name': '',
          'plan': {'name': '标准版'},
        }),
        '标准版',
      );
    });

    test('管理员：plan 为 null、plan_name 为空 → null', () {
      expect(
        AuthService.resolvePlanName({'plan_name': '', 'plan': null}),
        isNull,
      );
    });

    test('没有 plan 相关字段 → null', () {
      expect(AuthService.resolvePlanName({'token': 'x'}), isNull);
    });

    test('登录成功：档位名进结果、进持久化，恢复会话也能读到', () async {
      final storage = _FakeSecureStorage();
      final service = AuthService(
        dio: _fakeDio({9876: (status: 200, body: _successBodyWithPlan)}),
        storage: storage,
      );
      final result = await service.login(
        panelDomain: 'panel.example.com',
        username: 'nianba',
        password: 'pw',
      );
      expect(result.planName, '标准版');
      expect(await service.readPlanName(), '标准版');
      final session = await service.restoreSession();
      expect(session?.planName, '标准版');
    });

    test('管理员登录：无档位，旧值不残留', () async {
      SharedPreferences.setMockInitialValues(
        {'client_login_plan_name': '旧档位'},
      );
      final service = AuthService(
        dio: _fakeDio({9876: (status: 200, body: _successBodyAdmin)}),
        storage: _FakeSecureStorage(),
      );
      final result = await service.login(
        panelDomain: 'panel.example.com',
        username: 'nianba',
        password: 'pw',
      );
      expect(result.planName, isNull);
      expect(await service.readPlanName(), isNull);
    });

    test('登出：档位名清除', () async {
      final service = AuthService(
        dio: _fakeDio({9876: (status: 200, body: _successBodyWithPlan)}),
        storage: _FakeSecureStorage(),
      );
      await service.login(
        panelDomain: 'panel.example.com',
        username: 'nianba',
        password: 'pw',
      );
      expect(await service.readPlanName(), '标准版');
      await service.logout();
      expect(await service.readPlanName(), isNull);
    });
  });

  group('logout / restore', () {
    test('登出清令牌与账号名，记住的端口保留', () async {
      final storage = _FakeSecureStorage();
      final service = AuthService(
        dio: _fakeDio({9876: (status: 200, body: _successBody)}),
        storage: storage,
      );
      await service.login(
        panelDomain: 'panel.example.com',
        username: 'nianba',
        password: 'pw',
      );
      expect(await service.restoreSession(), isNotNull);
      await service.logout();
      expect(await service.restoreSession(), isNull);
      expect(await storage.read(key: 'client_session_token'), isNull);
      // 端口保留：下次登录还优先试 9876。
      expect(await service.readRememberedPort(), 9876);
    });
  });
}
