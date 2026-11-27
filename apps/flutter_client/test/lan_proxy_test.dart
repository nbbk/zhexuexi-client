// 0.1.14：局域网代理的回归测试。
//
// Builder：开关只改 mixed 入站的监听地址（127.0.0.1 ↔ 0.0.0.0）
// 与端口、鉴权 users，出站/路由/DNS 一点不动。
// Notifier：默认值（关/2080/鉴权开/用户名 zhexuexi/密码自动生成）、
// 持久化、端口钳制、空账号不收。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/singbox_config.dart';
import 'package:zhexuexi_client/services/lan_proxy_notifier.dart';

Node _node() => Node(
  name: '日本-直连',
  protocol: NodeProtocol.vless,
  address: '203.0.113.1',
  port: 443,
  source: NodeSource.direct,
  uuidOrPassword: '11111111-2222-3333-4444-555555555555',
  tls: true,
);

/// 配置里的 mixed 入站（tag mixed-in）。
Map<String, dynamic> _mixed(Map<String, dynamic> config) {
  final inbounds = config['inbounds'] as List;
  return inbounds
      .cast<Map<String, dynamic>>()
      .firstWhere((inbound) => inbound['tag'] == 'mixed-in');
}

void main() {
  group('SingboxConfigBuilder：局域网代理只改 mixed 入站', () {
    test('默认：只听 127.0.0.1:2080，无 users', () {
      final mixed = _mixed(SingboxConfigBuilder.build([_node()]).config);
      expect(mixed['type'], 'mixed');
      expect(mixed['listen'], '127.0.0.1');
      expect(mixed['listen_port'], 2080);
      expect(mixed.containsKey('users'), isFalse);
    });

    test('开开关：监听改 0.0.0.0，端口不变，无账号时仍无 users', () {
      final mixed = _mixed(
        SingboxConfigBuilder.build([_node()], lanProxy: true).config,
      );
      expect(mixed['listen'], '0.0.0.0');
      expect(mixed['listen_port'], 2080);
      expect(mixed.containsKey('users'), isFalse);
    });

    test('端口可改：开与关都按新端口出', () {
      final off = _mixed(
        SingboxConfigBuilder.build(
          [_node()],
          lanProxyPort: 8080,
        ).config,
      );
      expect(off['listen'], '127.0.0.1');
      expect(off['listen_port'], 8080);
      final on = _mixed(
        SingboxConfigBuilder.build(
          [_node()],
          lanProxy: true,
          lanProxyPort: 8080,
        ).config,
      );
      expect(on['listen'], '0.0.0.0');
      expect(on['listen_port'], 8080);
    });

    test('鉴权账号都有：写 users；缺一半：不写', () {
      final authed = _mixed(
        SingboxConfigBuilder.build(
          [_node()],
          lanProxy: true,
          lanProxyUsername: 'zhexuexi',
          lanProxyPassword: 'example-password',
        ).config,
      );
      expect(authed['users'], [
        {'username': 'zhexuexi', 'password': 'example-password'},
      ]);
      final noPassword = _mixed(
        SingboxConfigBuilder.build(
          [_node()],
          lanProxy: true,
          lanProxyUsername: 'zhexuexi',
        ).config,
      );
      expect(noPassword.containsKey('users'), isFalse);
      final noUsername = _mixed(
        SingboxConfigBuilder.build(
          [_node()],
          lanProxy: true,
          lanProxyPassword: 'example-password',
        ).config,
      );
      expect(noUsername.containsKey('users'), isFalse);
    });

    test('其余配置不变：出站/路由/DNS 在开关前后一模一样', () {
      final off = SingboxConfigBuilder.build([_node()]).config;
      final on = SingboxConfigBuilder.build(
        [_node()],
        lanProxy: true,
        lanProxyPort: 8080,
        lanProxyUsername: 'zhexuexi',
        lanProxyPassword: 'example-password',
      ).config;
      expect(jsonEncode(on['outbounds']), jsonEncode(off['outbounds']));
      expect(jsonEncode(on['route']), jsonEncode(off['route']));
      expect(jsonEncode(on['dns']), jsonEncode(off['dns']));
    });
  });

  group('LanProxyNotifier', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    /// 读一次 state（等 build 里的异步偏好读回）。
    Future<LanProxyState> readState(ProviderContainer container) async {
      container.read(lanProxyProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return container.read(lanProxyProvider);
    }

    test('默认值：关/2080/鉴权开/用户名 zhexuexi/密码自动生成 12 位', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = await readState(container);
      expect(state.enabled, isFalse);
      expect(state.port, 2080);
      expect(state.authEnabled, isTrue);
      expect(state.username, 'zhexuexi');
      expect(state.password.length, 12);
      expect(
        state.password.split('').every(
          (c) => RegExp(r'[a-zA-Z0-9]').hasMatch(c),
        ),
        isTrue,
      );
    });

    test('密码只生成一次：新容器读回同一把', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final first = await readState(container);
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      final second = await readState(container2);
      expect(second.password, first.password);
    });

    test('端口钳在 1–65535', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await readState(container);
      final notifier = container.read(lanProxyProvider.notifier);
      await notifier.setPort(0);
      expect(container.read(lanProxyProvider).port, 1);
      await notifier.setPort(70000);
      expect(container.read(lanProxyProvider).port, 65535);
      await notifier.setPort(8080);
      expect(container.read(lanProxyProvider).port, 8080);
    });

    test('空用户名/空密码不收，留旧值', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await readState(container);
      final notifier = container.read(lanProxyProvider.notifier);
      expect(await notifier.setUsername('  '), isFalse);
      expect(container.read(lanProxyProvider).username, 'zhexuexi');
      final password = container.read(lanProxyProvider).password;
      expect(await notifier.setPassword(''), isFalse);
      expect(container.read(lanProxyProvider).password, password);
    });

    test('鉴权关着时 authCredentials 为 null，开着时有账号', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await readState(container);
      final notifier = container.read(lanProxyProvider.notifier);
      expect(
        container.read(lanProxyProvider).authCredentials?.username,
        'zhexuexi',
      );
      await notifier.setAuthEnabled(false);
      expect(container.read(lanProxyProvider).authCredentials, isNull);
    });

    test('开关持久化：新容器读回开着', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await readState(container);
      await container.read(lanProxyProvider.notifier).setEnabled(true);
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      final second = await readState(container2);
      expect(second.enabled, isTrue);
      expect(second.password, isNotEmpty);
    });

    test('generatePassword：12 位，只含字母数字', () {
      final password = LanProxyNotifier.generatePassword();
      expect(password.length, 12);
      expect(RegExp(r'^[a-zA-Z0-9]{12}$').hasMatch(password), isTrue);
      // 两次生成不一样（随机种子不同）。
      expect(
        LanProxyNotifier.generatePassword() == password,
        isFalse,
      );
    });
  });
}
