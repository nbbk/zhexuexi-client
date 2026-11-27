// 切片 6：自定义分流规则（域名规整、增删开关、持久化、进配置）的回归测试。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/custom_rule.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/routing_mode.dart';
import 'package:zhexuexi_client/core/singbox_config.dart';
import 'package:zhexuexi_client/services/custom_rules_notifier.dart';

Node _node(String name, {NodeSource source = NodeSource.direct}) => Node(
  name: name,
  protocol: NodeProtocol.vless,
  address: '203.0.113.1',
  port: 443,
  source: source,
  uuidOrPassword: '11111111-2222-3333-4444-555555555555',
  tls: true,
  sni: 'example.com',
);

List<Map<String, dynamic>> _routeRules(Map<String, dynamic> config) {
  final route = config['route'] as Map<String, dynamic>;
  return (route['rules'] as List).cast<Map<String, dynamic>>();
}

List<Map<String, dynamic>> _dnsRules(Map<String, dynamic> config) {
  final dns = config['dns'] as Map<String, dynamic>;
  return (dns['rules'] as List).cast<Map<String, dynamic>>();
}

/// 让 Notifier 里读持久化的 Future 送达。
Future<void> _pumpEvents() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

void main() {
  group('域名规整', () {
    test('接受标准后缀，大小写与前导 *. / . 都规整掉', () {
      expect(CustomRule.normalizeDomain('example.com'), 'example.com');
      expect(CustomRule.normalizeDomain('Example.COM'), 'example.com');
      expect(CustomRule.normalizeDomain('*.example.com'), 'example.com');
      expect(CustomRule.normalizeDomain('.example.com'), 'example.com');
      expect(
        CustomRule.normalizeDomain('  sub.example.com  '),
        'sub.example.com',
      );
    });

    test('拒绝空串、带协议、带路径、带端口、带空格、带通配、单段', () {
      expect(CustomRule.normalizeDomain(''), isNull);
      expect(CustomRule.normalizeDomain('   '), isNull);
      expect(CustomRule.normalizeDomain('https://example.com'), isNull);
      expect(CustomRule.normalizeDomain('example.com/path'), isNull);
      expect(CustomRule.normalizeDomain('example.com:443'), isNull);
      expect(CustomRule.normalizeDomain('exa mple.com'), isNull);
      expect(CustomRule.normalizeDomain('*.com'), isNull);
      expect(CustomRule.normalizeDomain('com'), isNull);
      expect(CustomRule.normalizeDomain('*'), isNull);
      expect(CustomRule.normalizeDomain('-example.com'), isNull);
      expect(CustomRule.normalizeDomain('example-.com'), isNull);
      expect(CustomRule.normalizeDomain('example..com'), isNull);
    });
  });

  group('模型 JSON 往返', () {
    test('toJson/fromJson 一致；脏数据 fromJson 返回 null', () {
      const rule = CustomRule(
        id: '1',
        domain: 'example.com',
        action: CustomRuleAction.direct,
        enabled: false,
      );
      final restored = CustomRule.fromJson(rule.toJson());
      expect(restored, isNotNull);
      expect(restored!.id, '1');
      expect(restored.domain, 'example.com');
      expect(restored.action, CustomRuleAction.direct);
      expect(restored.enabled, isFalse);

      expect(CustomRule.fromJson({'domain': 'not a domain'}), isNull);
      expect(CustomRule.fromJson({'id': '1'}), isNull);
      expect(
        CustomRule.fromJson({
          'id': '1',
          'domain': 'example.com',
          'action': 'bogus',
        })!.action,
        CustomRuleAction.proxy,
      );
    });
  });

  group('Notifier 增删开关与持久化', () {
    late ProviderContainer container;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer();
    });

    tearDown(() => container.dispose());

    test('加规则成功、重复与不合格都返回 false', () async {
      final notifier = container.read(customRulesProvider.notifier);
      expect(await notifier.addRule('example.com', CustomRuleAction.proxy), isTrue);
      expect(container.read(customRulesProvider).length, 1);
      // 同域名再加（写法不同也算重复）拒绝。
      expect(
        await notifier.addRule('*.Example.COM', CustomRuleAction.direct),
        isFalse,
      );
      expect(await notifier.addRule('not a domain', CustomRuleAction.proxy), isFalse);
      expect(container.read(customRulesProvider).length, 1);
    });

    test('删规则与开关规则；不存在的 id 返回 false', () async {
      final notifier = container.read(customRulesProvider.notifier);
      await notifier.addRule('example.com', CustomRuleAction.proxy);
      await notifier.addRule('other.org', CustomRuleAction.direct);
      final id = container.read(customRulesProvider).first.id;
      expect(await notifier.setEnabled(id, false), isTrue);
      expect(container.read(customRulesProvider).first.enabled, isFalse);
      // activeRules 只认已启用的。
      expect(notifier.activeRules.length, 1);
      expect(await notifier.removeRule(id), isTrue);
      expect(container.read(customRulesProvider).length, 1);
      expect(await notifier.removeRule('no-such-id'), isFalse);
      expect(await notifier.setEnabled('no-such-id', true), isFalse);
    });

    test('持久化：新容器读回旧规则', () async {
      final notifier = container.read(customRulesProvider.notifier);
      await notifier.addRule('example.com', CustomRuleAction.direct);
      await _pumpEvents();
      container.dispose();
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      container2.read(customRulesProvider); // 先读一次触发 build（异步读回），再等它送达。
      await _pumpEvents();
      final rules = container2.read(customRulesProvider);
      expect(rules.length, 1);
      expect(rules.first.domain, 'example.com');
      expect(rules.first.action, CustomRuleAction.direct);
    });
  });

  group('进配置（切片 6）', () {
    test('自定义规则插在内置规则前面；DNS 映射同样在前', () {
      final rules = [
        const CustomRule(
          id: '1',
          domain: 'example.com',
          action: CustomRuleAction.direct,
        ),
        const CustomRule(
          id: '2',
          domain: 'work.example.net',
          action: CustomRuleAction.proxy,
        ),
      ];
      final result = SingboxConfigBuilder.build(
        [_node('甲-直连')],
        customRules: rules,
      );
      final routeRules = _routeRules(result.config);
      // 前两条是基础规则（sniff / 私网旁路；劫持 DNS
      // 已随 0.1.3 D 路第 1 步去掉，QUIC 阻断已随 0.1.4 D 路第 2 步
      // 去掉、0.1.5 加回、0.1.6 回滚删掉），其后两条是自定义规则（按加入顺序），
      // 再后才是内置 TikTok。
      expect(routeRules[2]['domain_suffix'], ['example.com']);
      expect(routeRules[2]['outbound'], 'direct');
      expect(routeRules[3]['domain_suffix'], ['work.example.net']);
      expect(routeRules[3]['outbound'], 'Proxy');
      expect(routeRules[4]['domain_suffix'], SingboxConfigBuilder.tiktokSuffixes);

      final dnsRules = _dnsRules(result.config);
      expect(dnsRules[0]['domain_suffix'], ['example.com']);
      expect(dnsRules[0]['server'], 'dns-direct');
      expect(dnsRules[1]['domain_suffix'], ['work.example.net']);
      expect(dnsRules[1]['server'], 'dns-proxy');
      expect(dnsRules[2]['domain_suffix'], ['.cn']);
    });

    test('关闭的规则不进配置', () {
      final rules = [
        const CustomRule(
          id: '1',
          domain: 'example.com',
          action: CustomRuleAction.direct,
          enabled: false,
        ),
      ];
      final result = SingboxConfigBuilder.build(
        [_node('甲-直连')],
        customRules: rules,
      );
      // 只查规则段：节点自身的 SNI 本来就是 example.com，不能按
      // 整份配置是否含该串断言。
      final routeRules = _routeRules(result.config);
      final dnsRules = _dnsRules(result.config);
      // route 前 2 条是前缀（无 domain_suffix 键），空安全取。
      final inRules = [...routeRules, ...dnsRules].any(
        (r) =>
            (r['domain_suffix'] as List?)?.contains('example.com') ?? false,
      );
      expect(inRules, isFalse);
    });

    test('没有节点时走代理的自定义规则不进，直连的照常进', () {
      final rules = [
        const CustomRule(
          id: '1',
          domain: 'proxy.example.com',
          action: CustomRuleAction.proxy,
        ),
        const CustomRule(
          id: '2',
          domain: 'direct.example.com',
          action: CustomRuleAction.direct,
        ),
      ];
      final result = SingboxConfigBuilder.build([], customRules: rules);
      final routeRules = _routeRules(result.config);
      expect(routeRules.length, 4);
      expect(routeRules[2]['domain_suffix'], ['direct.example.com']);
      expect(routeRules[2]['outbound'], 'direct');
      expect(routeRules[3]['domain_suffix'], ['.cn']);
      final dnsRules = _dnsRules(result.config);
      expect(dnsRules[0]['domain_suffix'], ['direct.example.com']);
      expect(dnsRules[0]['server'], 'dns-direct');
    });

    test('全局模式与直连模式下自定义规则仍是唯一的例外口', () {
      final rules = [
        const CustomRule(
          id: '1',
          domain: 'direct.example.com',
          action: CustomRuleAction.direct,
        ),
      ];
      final global = SingboxConfigBuilder.build(
        [_node('甲-直连')],
        mode: RoutingMode.global,
        customRules: rules,
      );
      final globalRules = _routeRules(global.config);
      expect(globalRules.length, 3);
      expect(globalRules[2]['outbound'], 'direct');
      expect((global.config['route'] as Map)['final'], 'Proxy');

      final direct = SingboxConfigBuilder.build(
        [_node('甲-直连')],
        mode: RoutingMode.direct,
        customRules: [
          const CustomRule(
            id: '2',
            domain: 'proxy.example.com',
            action: CustomRuleAction.proxy,
          ),
        ],
      );
      final directRules = _routeRules(direct.config);
      expect(directRules.length, 3);
      expect(directRules[2]['outbound'], 'Proxy');
      expect((direct.config['route'] as Map)['final'], 'direct');
    });

    test('不传 customRules 时老调用不受影响', () {
      final result = SingboxConfigBuilder.build([_node('甲-直连')]);
      final routeRules = _routeRules(result.config);
      // 0.1.6：前缀 2 条，TikTok 在 [2]（0.1.5 是 3 条前缀、TikTok 在 [3]）。
      expect(routeRules[2]['domain_suffix'], SingboxConfigBuilder.tiktokSuffixes);
    });
  });

  group('TUN 入站（切片 6）', () {
    test('tunEnabled=false 不写 tun 入站；=true 写一条 tun 入站', () {
      final off = SingboxConfigBuilder.build([_node('甲-直连')]);
      final offInbounds = off.config['inbounds'] as List;
      expect(offInbounds.length, 1);
      expect(offInbounds[0]['type'], 'mixed');

      final on = SingboxConfigBuilder.build(
        [_node('甲-直连')],
        tunEnabled: true,
      );
      final onInbounds = on.config['inbounds'] as List;
      expect(onInbounds.length, 2);
      final tun = onInbounds[1] as Map<String, dynamic>;
      expect(tun['type'], 'tun');
      expect(tun['tag'], 'tun-in');
      expect(tun['auto_route'], isTrue);
      // 0.1.3 D 路第 1 步：TUN 入站不写 dns_mode（劫持对一起去掉，
      // 不写即默认，恢复 0.1.1 行为）。
      expect(tun.containsKey('dns_mode'), isFalse);
      // 0.1.10：tun 入站写 `stack: gvisor`（TUN 回包修法）。
      // 2026-11-26 的“不能写 stack”回归已解除：上游 option/tun.go:52
      // 的 Stack 字段已补进本地 schema 快照，gen_models.dart 重生成
      // 了 TunInbound 模型，校验放行；不写时走 sing-box 默认栈（mixed）
      // 正是 0.1.9 死态的故障链，写 gvisor 才绕过它。
      expect(tun['stack'], 'gvisor');
      // TUN 只改入站，出站与 route.final 不变。
      expect((on.config['route'] as Map)['final'], 'direct');
    });
  });

  group('DNS 摘要（切片 6：设置页展示用）', () {
    test('摘要含 DoH 双路、仅 IPv4、不回落明文、防泄漏不可关闭', () {
      final summary = SingboxConfigBuilder.dnsSummary;
      final text = summary.map((e) => '${e.label}：${e.value}').join('\n');
      expect(text, contains('223.5.5.5'));
      expect(text, contains('8.8.8.8/dns-query'));
      expect(text, contains('ipv4_only'));
      expect(text, contains('不回落'));
      expect(text, contains('不可关闭'));
      // 摘要里没有任何明文 UDP 服务器写法。
      expect(text.contains('udp'), isFalse);
    });
  });
}
