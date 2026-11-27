// 第 8 项“登录自动带订阅”客户端侧：登录时订阅去重。
//
// 登录回包里的订阅已经绑过（主订阅或手动加的多订阅里已有同一条）
// 时跳过绑定，不重复拉取、不在订阅列表里多一条重复项；
// 没绑过时正常绑定；绑定失败仍回滚本次登录。
//
// 不碰真面板与真密钥库：登录服务、订阅服务、节点 notifier 都用桩，
// 多订阅存储用内存 fake 安全存储。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/services/auth_notifier.dart';
import 'package:zhexuexi_client/services/auth_service.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/subscription_service.dart';
import 'package:zhexuexi_client/services/subscription_store.dart';

class _FakeSecureStorage extends FlutterSecureStorage {
  final _map = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
  }) async => _map[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
  }) async {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
  }) async {
    _map.remove(key);
  }
}

/// 登录桩：按预设回包返回，不发请求。
class _FakeAuthService extends AuthService {
  _FakeAuthService({this.loginSubscriptionUrl, this.planName});

  final String? loginSubscriptionUrl;
  final String? planName;
  final logoutCalls = <String>[];
  final loginCalls = <String>[];

  @override
  Future<AuthLoginResult> login({
    required String panelDomain,
    required String username,
    required String password,
  }) async {
    loginCalls.add(panelDomain);
    return AuthLoginResult(
      token: 'sess_0123456789abcdef',
      username: username,
      planName: planName,
      subscriptionUrl: loginSubscriptionUrl,
      port: 9876,
    );
  }

  @override
  Future<void> saveLastPanelDomain(String domain) async {}

  @override
  Future<void> logout() async {
    logoutCalls.add('logout');
  }
}

/// 订阅桩：主订阅地址由字段给定，保存/清除只记调用。
class _FakeSubscriptionService extends SubscriptionService {
  String? primaryUrl;
  final saveCalls = <String>[];
  final clearCalls = <String>[];

  @override
  Future<String?> readSubscriptionUrl() async => primaryUrl;

  @override
  Future<void> saveSubscriptionLink(String link) async {
    saveCalls.add(link);
  }

  @override
  Future<void> clearBinding() async {
    clearCalls.add('clear');
  }
}

/// 节点桩：bindAndRefresh 只记调用，不拉网络；可预设绑定失败。
class _StubNodesNotifier extends NodesNotifier {
  _StubNodesNotifier({this.bindError});

  final String? bindError;
  final bindCalls = <String>[];
  final refreshCalls = <String>[];
  final clearCalls = <String>[];
  NodesState _state = const NodesState();

  @override
  NodesState build() => _state;

  @override
  Future<void> bindAndRefresh(String link) async {
    bindCalls.add(link);
    if (bindError != null) {
      _state = _state.copyWith(
        status: NodesStatus.error,
        errorMessage: bindError,
      );
    } else {
      _state = const NodesState(status: NodesStatus.loaded);
    }
    state = _state;
  }

  @override
  Future<void> refresh() async {
    refreshCalls.add('refresh');
  }

  @override
  Future<void> clear() async {
    clearCalls.add('clear');
    _state = const NodesState();
    state = _state;
  }
}

const _loginUrl =
    'https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _oldUrl =
    'https://example.com/x9f2/sub_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _httpLoginUrl =
    'http://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<
    ({
      ProviderContainer container,
      _StubNodesNotifier nodes,
      _FakeAuthService auth,
      _FakeSubscriptionService service,
    })
  >
  buildEnv({
    String? loginSubscriptionUrl = _loginUrl,
    String? primaryUrl,
    List<String> customUrls = const [],
    String? bindError,
    String? planName,
  }) async {
    final storage = _FakeSecureStorage();
    final store = SubscriptionStore(storage: storage);
    for (final url in customUrls) {
      expect((await store.addCustom(url)).error, isNull);
    }
    final auth = _FakeAuthService(
      loginSubscriptionUrl: loginSubscriptionUrl,
      planName: planName,
    );
    final service = _FakeSubscriptionService()..primaryUrl = primaryUrl;
    final nodes = _StubNodesNotifier(bindError: bindError);
    final container = ProviderContainer(
      overrides: [
        authServiceProvider.overrideWithValue(auth),
        subscriptionServiceProvider.overrideWithValue(service),
        subscriptionStoreProvider.overrideWithValue(store),
        nodesProvider.overrideWith(() => nodes),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, nodes: nodes, auth: auth, service: service);
  }

  Future<bool> doLogin(ProviderContainer container) =>
      container.read(authProvider.notifier).login(
        panelDomain: 'panel.example.com',
        username: 'nianba',
        password: 'pw',
      );

  group('AuthNotifier.resolvePanelDomain 解析顺序（0.1.3）', () {
    test('远程配置有值、手填为空：用远程配置的 panel_domain', () {
      expect(
        AuthNotifier.resolvePanelDomain(
          typed: '',
          remoteDomain: 'ccpanel.jiankong.cf',
        ),
        'ccpanel.jiankong.cf',
      );
    });

    test('手填优先：手填了就用手填的，不用远程配置的', () {
      expect(
        AuthNotifier.resolvePanelDomain(
          typed: 'my.panel.local',
          remoteDomain: 'ccpanel.jiankong.cf',
        ),
        'my.panel.local',
      );
    });

    test('两边都没有：不发请求，提示先拉取配置或手填', () async {
      final env = await buildEnv();
      final ok = await env.container.read(authProvider.notifier).login(
        panelDomain: '',
        username: 'nianba',
        password: 'pw',
      );
      expect(ok, isFalse);
      expect(
        env.container.read(authProvider).errorMessage,
        contains('拉取远程配置'),
      );
      // 没调登录服务：一个请求都没发。
      expect(env.auth.loginCalls, isEmpty);
    });
  });

  group('AuthNotifier.login 订阅去重', () {
    test('手动加过同一订阅：跳过绑定，登录仍成功', () async {
      final env = await buildEnv(customUrls: [_loginUrl]);
      expect(await doLogin(env.container), isTrue);
      expect(env.container.read(authProvider).username, 'nianba');
      expect(env.nodes.bindCalls, isEmpty);
      // 跳过绑定不是回滚：会话没删、旧绑定没动。
      expect(env.auth.logoutCalls, isEmpty);
      expect(env.service.saveCalls, isEmpty);
    });

    test('没加过：正常绑定一次', () async {
      final env = await buildEnv();
      expect(await doLogin(env.container), isTrue);
      expect(env.container.read(authProvider).username, 'nianba');
      expect(env.nodes.bindCalls, [_loginUrl]);
    });

    test('登录成功：档位名进状态（0.1.12）', () async {
      final env = await buildEnv(planName: '标准版');
      expect(await doLogin(env.container), isTrue);
      expect(env.container.read(authProvider).planName, '标准版');
    });

    test('主订阅已是同一条：跳过绑定', () async {
      final env = await buildEnv(primaryUrl: _loginUrl);
      expect(await doLogin(env.container), isTrue);
      expect(env.container.read(authProvider).username, 'nianba');
      expect(env.nodes.bindCalls, isEmpty);
      expect(env.auth.logoutCalls, isEmpty);
    });

    test('末尾斜杠差异算同一条：主订阅带 / 也跳过', () async {
      final env = await buildEnv(primaryUrl: '$_loginUrl/');
      expect(await doLogin(env.container), isTrue);
      expect(env.nodes.bindCalls, isEmpty);
    });

    test('首尾空白差异算同一条：回包链接带空格也跳过', () async {
      final env = await buildEnv(
        loginSubscriptionUrl: '  $_loginUrl  ',
        primaryUrl: _loginUrl,
      );
      expect(await doLogin(env.container), isTrue);
      expect(env.nodes.bindCalls, isEmpty);
    });

    test('http 与 https 不算同一条：手动加的是 http，照常绑定', () async {
      final env = await buildEnv(customUrls: [_httpLoginUrl]);
      expect(await doLogin(env.container), isTrue);
      expect(env.nodes.bindCalls, [_loginUrl]);
    });

    test('账号下没有订阅：登录成功，不绑定', () async {
      final env = await buildEnv(loginSubscriptionUrl: null);
      expect(await doLogin(env.container), isTrue);
      expect(env.container.read(authProvider).username, 'nianba');
      expect(env.nodes.bindCalls, isEmpty);
    });

    test('绑定失败仍回滚：恢复旧订阅、删会话、登录失败', () async {
      final env = await buildEnv(
        loginSubscriptionUrl: _loginUrl,
        primaryUrl: _oldUrl,
        bindError: '网络不通，检查订阅地址',
      );
      expect(await doLogin(env.container), isFalse);
      final state = env.container.read(authProvider);
      expect(state.username, isNull);
      expect(state.errorMessage, contains('订阅绑定失败'));
      // 回滚：删会话令牌、把旧订阅写回去、刷新节点列表。
      expect(env.auth.logoutCalls, ['logout']);
      expect(env.service.saveCalls, [_oldUrl]);
      expect(env.nodes.refreshCalls, ['refresh']);
    });
  });
}
