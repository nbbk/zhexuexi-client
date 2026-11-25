// 切片 2：sing-box 配置生成的回归测试。
//
// fixture 全部用脱敏数据（example.com / 203.0.113.x / 假 UUID），形状按
// 面板 1.3.37 的实际输出与 panel-adapter.md §6.1.2 的域名清单编。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/core/custom_rule.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/routing_mode.dart';
import 'package:zhexuexi_client/core/singbox_config.dart';
import 'package:zhexuexi_client/services/subscription_parser.dart';

Future<String> _fixture(String name) =>
    File('test/fixtures/$name').readAsString();

/// 取配置里的 dns.servers。
List<Map<String, dynamic>> _dnsServers(Map<String, dynamic> config) {
  final dns = config['dns'] as Map<String, dynamic>;
  return (dns['servers'] as List).cast<Map<String, dynamic>>();
}

/// 取配置里的 outbounds（按 tag 索引）。
Map<String, Map<String, dynamic>> _outboundsByTag(
  Map<String, dynamic> config,
) {
  final outbounds = config['outbounds'] as List;
  return {
    for (final ob in outbounds.cast<Map<String, dynamic>>())
      ob['tag'] as String: ob,
  };
}

void main() {
  group('DNS（客户端自生成，新格式）', () {
    test('三台服务器：DoH 双路＋DoT 兜底，只解析 IPv4', () async {
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final result = SingboxConfigBuilder.build(nodes);
      expect(result.skipped, isEmpty);

      final dns = result.config['dns'] as Map<String, dynamic>;
      expect(dns['strategy'], 'ipv4_only');
      expect(dns['final'], 'dns-dot');

      final servers = _dnsServers(result.config);
      expect(servers.length, 3);
      final direct = servers[0];
      expect(direct['tag'], 'dns-direct');
      expect(direct['type'], 'https');
      expect(direct['server'], '1.1.1.1');
      expect(direct['server_port'], 443);
      expect(direct['path'], '/dns-query');
      // 直连解析不写 detour（detour 指 direct 出站时 1.14.4 run 拒绝）。
      expect(direct.containsKey('detour'), isFalse);
      expect(direct.containsKey('address'), isFalse);

      final proxy = servers[1];
      expect(proxy['tag'], 'dns-proxy');
      expect(proxy['type'], 'https');
      expect(proxy['server'], 'dns.google');
      expect(proxy['server_port'], 443);
      // 代理 DNS 的 detour 必须是 selector 的 tag `Proxy`（逐字一致）。
      expect(proxy['detour'], 'Proxy');

      final dot = servers[2];
      expect(dot['tag'], 'dns-dot');
      expect(dot['type'], 'tls');
      expect(dot['server'], '8.8.8.8');
      expect(dot['server_port'], 853);
      expect(dot.containsKey('detour'), isFalse);

      // 全配置里不许出现 legacy address 写法。
      final flat = jsonEncode(result.config);
      expect(flat.contains('"address"'), isFalse);
    });

    test('DNS 规则：.cn 直连、TikTok 与测 IP 走代理', () async {
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final result = SingboxConfigBuilder.build(nodes);
      final dns = result.config['dns'] as Map<String, dynamic>;
      final rules = (dns['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.length, 3);
      expect(rules[0]['domain_suffix'], ['.cn']);
      expect(rules[0]['server'], 'dns-direct');
      expect(
        (rules[1]['domain_suffix'] as List).contains('tiktok.com'),
        isTrue,
      );
      expect(rules[1]['server'], 'dns-proxy');
      expect(
        (rules[2]['domain_suffix'] as List).contains('ip-api.com'),
        isTrue,
      );
      expect(rules[2]['server'], 'dns-proxy');
    });
  });

  group('route 规则与出站组', () {
    test('面板 fixture：4 节点＋Proxy＋自动选择＋direct＋block', () async {
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final result = SingboxConfigBuilder.build(nodes);
      final byTag = _outboundsByTag(result.config);
      expect(byTag.length, 8);

      final proxy = byTag['Proxy']!;
      expect(proxy['type'], 'selector');
      expect(proxy['outbounds'], [
        '智利-直连',
        '香港-中转',
        '日本-直连',
        '新加坡-中转',
      ]);
      // 默认选第一个直连节点（智利-直连）。
      expect(proxy['default'], '智利-直连');

      final auto = byTag['自动选择']!;
      expect(auto['type'], 'urltest');
      expect(auto['url'], 'http://www.gstatic.com/generate_204');
      expect(auto['interval'], '5m');

      final route = result.config['route'] as Map<String, dynamic>;
      expect(route['final'], 'direct');
      expect(route['default_domain_resolver'], 'dns-direct');
      final rules = (route['rules'] as List).cast<Map<String, dynamic>>();
      // TikTok / 社交 / 流媒体 / 测 IP → Proxy，.cn → direct。
      expect(rules.length, 5);
      expect(rules[0]['outbound'], 'Proxy');
      expect(
        (rules[0]['domain_suffix'] as List).contains('tiktok.com'),
        isTrue,
      );
      expect(rules[1]['outbound'], 'Proxy');
      expect(
        (rules[1]['domain_suffix'] as List).contains('facebook.com'),
        isTrue,
      );
      expect(rules[2]['outbound'], 'Proxy');
      expect(
        (rules[2]['domain_suffix'] as List).contains('youtube.com'),
        isTrue,
      );
      expect(rules[3]['outbound'], 'Proxy');
      expect(
        (rules[3]['domain_suffix'] as List).contains('ip-api.com'),
        isTrue,
      );
      expect(rules[4]['domain_suffix'], ['.cn']);
      expect(rules[4]['outbound'], 'direct');
    });

    test('空节点：合法空配置，不引用不存在的 Proxy 组', () {
      final result = SingboxConfigBuilder.build([]);
      expect(result.skipped, isEmpty);
      final byTag = _outboundsByTag(result.config);
      expect(byTag.keys, {'direct', 'block'});
      final route = result.config['route'] as Map<String, dynamic>;
      final rules = (route['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.length, 1);
      expect(rules[0]['domain_suffix'], ['.cn']);
      expect(route['final'], 'direct');
      // DNS 与入站、Clash API 照常在；节点为空没有 Proxy 组，
      // 代理 DNS 也不写 detour，服务器改用 IP（域名无人解析）。
      final dnsServers = _dnsServers(result.config);
      expect(dnsServers.length, 3);
      expect(dnsServers[1].containsKey('detour'), isFalse);
      expect(dnsServers[1]['server'], '8.8.8.8');
      final inbounds = result.config['inbounds'] as List;
      expect((inbounds.first as Map)['listen_port'], 2080);
      final experimental = result.config['experimental'] as Map;
      expect(
        (experimental['clash_api'] as Map)['external_controller'],
        '127.0.0.1:9090',
      );
    });

    test('重名节点加 (2) 后缀，不丢节点', () {
      final nodes = [
        Node(
          name: '同名-直连',
          protocol: NodeProtocol.vless,
          address: '203.0.113.1',
          port: 443,
          source: NodeSource.direct,
          uuidOrPassword: '11111111-2222-3333-4444-555555555555',
          tls: true,
        ),
        Node(
          name: '同名-直连',
          protocol: NodeProtocol.vless,
          address: '203.0.113.2',
          port: 443,
          source: NodeSource.direct,
          uuidOrPassword: '11111111-2222-3333-4444-555555555555',
          tls: true,
        ),
      ];
      final result = SingboxConfigBuilder.build(nodes);
      expect(result.skipped, isEmpty);
      final byTag = _outboundsByTag(result.config);
      expect(byTag.containsKey('同名-直连'), isTrue);
      expect(byTag.containsKey('同名-直连 (2)'), isTrue);
      final proxy = byTag['Proxy']!;
      expect(proxy['outbounds'], ['同名-直连', '同名-直连 (2)']);
    });

    test('全是中转节点时 selector 默认取第一个节点', () {
      final nodes = [
        Node(
          name: '甲-中转',
          protocol: NodeProtocol.trojan,
          address: '203.0.113.1',
          port: 443,
          source: NodeSource.relay,
          uuidOrPassword: 'example-password',
          tls: true,
        ),
        Node(
          name: '乙-中转',
          protocol: NodeProtocol.trojan,
          address: '203.0.113.2',
          port: 443,
          source: NodeSource.relay,
          uuidOrPassword: 'example-password',
          tls: true,
        ),
      ];
      final result = SingboxConfigBuilder.build(nodes);
      final byTag = _outboundsByTag(result.config);
      expect(byTag['Proxy']!['default'], '甲-中转');
    });
  });

  group('节点出站字段', () {
    test('VLESS：UUID＋TLS SNI＋WS 路径与 Host 头', () async {
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final result = SingboxConfigBuilder.build(nodes);
      final vless = _outboundsByTag(result.config)['智利-直连']!;
      expect(vless['type'], 'vless');
      expect(vless['server'], 'cl04.example.com');
      expect(vless['server_port'], 24443);
      expect(vless['uuid'], '11111111-2222-3333-4444-555555555555');
      expect((vless['tls'] as Map)['server_name'], 'cl04.example.com');
      final transport = vless['transport'] as Map<String, dynamic>;
      expect(transport['type'], 'ws');
      expect(transport['path'], '/example-path');
      expect((transport['headers'] as Map)['Host'], 'cl04.example.com');
    });

    test('SS：加密方式与密码都在；VMess：alter_id 0、security auto', () async {
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final result = SingboxConfigBuilder.build(nodes);
      final byTag = _outboundsByTag(result.config);
      final ss = byTag['新加坡-中转']!;
      expect(ss['type'], 'shadowsocks');
      expect(ss['method'], 'aes-256-gcm');
      expect(ss['password'], 'example-ss-password');
      final vmess = byTag['日本-直连']!;
      expect(vmess['alter_id'], 0);
      expect(vmess['security'], 'auto');
      // 该 VMess 节点无 Host 头，transport 里不写 headers。
      expect((vmess['transport'] as Map).containsKey('headers'), isFalse);
    });

    test('链接列表：HY2 出站带密码＋TLS；SS 方法从链接里取', () async {
      final body = await _fixture('links_plain.txt');
      final parsed = parseLinkList(body);
      expect(parsed.nodes.length, 5);
      expect(parsed.failedCount, 1);
      final result = SingboxConfigBuilder.build(parsed.nodes);
      expect(result.skipped, isEmpty);
      final byTag = _outboundsByTag(result.config);
      // VMess 先占了“日本-直连”，HY2 去重后是“日本-直连 (2)”。
      final hy2 = byTag['日本-直连 (2)']!;
      expect(hy2['type'], 'hysteria2');
      expect(hy2['password'], 'example-hy2-password');
      expect((hy2['tls'] as Map)['enabled'], isTrue);
      expect((hy2['tls'] as Map)['server_name'], 'hy2.example.com');
      final ss = byTag['新加坡-中转']!;
      expect(ss['method'], 'aes-256-gcm');
    });

    test('TUIC：uuid 与密码从 userInfo 拆开；拆不开的跳过', () {
      final ok = Node(
        name: 'TUIC-直连',
        protocol: NodeProtocol.tuic,
        address: '203.0.113.20',
        port: 443,
        source: NodeSource.direct,
        uuidOrPassword: '11111111-2222-3333-4444-555555555555:example-password',
        tls: true,
        sni: 'tuic.example.com',
      );
      final bad = Node(
        name: '坏TUIC-直连',
        protocol: NodeProtocol.tuic,
        address: '203.0.113.21',
        port: 443,
        source: NodeSource.direct,
        uuidOrPassword: 'no-colon-here',
        tls: true,
      );
      final result = SingboxConfigBuilder.build([ok, bad]);
      expect(result.skipped.length, 1);
      expect(result.skipped.first, contains('坏TUIC-直连'));
      final tuic = _outboundsByTag(result.config)['TUIC-直连']!;
      expect(tuic['uuid'], '11111111-2222-3333-4444-555555555555');
      expect(tuic['password'], 'example-password');
    });

    test('HY2/TUIC：alpn 与 congestion_control 解析后写回出站', () {
      final hy2 = Node(
        name: 'HY2-直连',
        protocol: NodeProtocol.hysteria2,
        address: '203.0.113.1',
        port: 443,
        source: NodeSource.direct,
        uuidOrPassword: '11111111-2222-3333-4444-555555555555',
        tls: true,
        sni: 'example.com',
        alpn: 'h3',
      );
      final tuic = Node(
        name: 'TUIC-直连',
        protocol: NodeProtocol.tuic,
        address: '203.0.113.20',
        port: 443,
        source: NodeSource.direct,
        uuidOrPassword: '11111111-2222-3333-4444-555555555555:example-password',
        tls: true,
        sni: 'example.com',
        alpn: 'h3',
        congestionControl: 'bbr',
      );
      final result = SingboxConfigBuilder.build([hy2, tuic]);
      expect(result.skipped, isEmpty);
      final byTag = _outboundsByTag(result.config);
      final hy2Out = byTag['HY2-直连']!;
      expect((hy2Out['tls'] as Map)['alpn'], ['h3']);
      final tuicOut = byTag['TUIC-直连']!;
      expect(tuicOut['congestion_control'], 'bbr');
      expect((tuicOut['tls'] as Map)['alpn'], ['h3']);
    });

    test('HY2/TUIC：没有 alpn 时不写 alpn 键、不写 congestion_control 键', () {
      final hy2 = Node(
        name: 'HY2-直连',
        protocol: NodeProtocol.hysteria2,
        address: '203.0.113.1',
        port: 443,
        source: NodeSource.direct,
        uuidOrPassword: '11111111-2222-3333-4444-555555555555',
        tls: true,
        sni: 'example.com',
      );
      final result = SingboxConfigBuilder.build([hy2]);
      expect(result.skipped, isEmpty);
      final hy2Out = _outboundsByTag(result.config)['HY2-直连']!;
      expect((hy2Out['tls'] as Map).containsKey('alpn'), isFalse);
      expect(hy2Out.containsKey('congestion_control'), isFalse);
    });

    test('grpc 节点跳过不静默当裸 TCP；SS 缺方法跳过', () {
      final grpc = Node(
        name: 'GRPC-直连',
        protocol: NodeProtocol.vless,
        address: '203.0.113.30',
        port: 443,
        source: NodeSource.direct,
        uuidOrPassword: '11111111-2222-3333-4444-555555555555',
        transport: 'grpc',
        tls: true,
      );
      final noMethod = Node(
        name: '无方法-中转',
        protocol: NodeProtocol.shadowsocks,
        address: '203.0.113.31',
        port: 8388,
        source: NodeSource.relay,
        uuidOrPassword: 'example-password',
      );
      final result = SingboxConfigBuilder.build([grpc, noMethod]);
      expect(result.skipped.length, 2);
      expect(result.skipped[0], contains('GRPC-直连'));
      expect(result.skipped[0], contains('grpc'));
      expect(result.skipped[1], contains('无方法-中转'));
      // 两个都跳过后仍是合法空配置。
      expect(_outboundsByTag(result.config).keys, {'direct', 'block'});
    });

    test('配置 JSON 可往返编解码', () async {
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final result = SingboxConfigBuilder.build(nodes);
      final decoded = jsonDecode(result.toJsonString());
      expect(decoded, isA<Map<String, dynamic>>());
      expect((decoded['outbounds'] as List).length, 8);
    });
  });

  group('模式切换（切片 3：规则 / 全局 / 直连）', () {
    List<Node> twoNodes() => [
      Node(
        name: '甲-直连',
        protocol: NodeProtocol.vless,
        address: '203.0.113.1',
        port: 443,
        source: NodeSource.direct,
        uuidOrPassword: '11111111-2222-3333-4444-555555555555',
        tls: true,
      ),
      Node(
        name: '乙-中转',
        protocol: NodeProtocol.trojan,
        address: '203.0.113.2',
        port: 443,
        source: NodeSource.relay,
        uuidOrPassword: 'example-password',
        tls: true,
      ),
    ];

    List<Map<String, dynamic>> dnsRules(Map<String, dynamic> config) {
      final dns = config['dns'] as Map<String, dynamic>;
      return (dns['rules'] as List).cast<Map<String, dynamic>>();
    }

    test('默认不传 mode 就是规则模式（老调用不受影响）', () {
      final result = SingboxConfigBuilder.build(twoNodes());
      final route = result.config['route'] as Map<String, dynamic>;
      expect(route['final'], 'direct');
      expect((route['rules'] as List).length, 5);
    });

    test('全局模式：route 无规则、final 指 Proxy；DNS 全部走代理', () {
      final result = SingboxConfigBuilder.build(
        twoNodes(),
        mode: RoutingMode.global,
      );
      final route = result.config['route'] as Map<String, dynamic>;
      expect((route['rules'] as List), isEmpty);
      expect(route['final'], 'Proxy');
      // 出站组还在（Proxy selector 与自动选择都在）。
      expect(_outboundsByTag(result.config).containsKey('Proxy'), isTrue);
      final rules = dnsRules(result.config);
      expect(rules.every((r) => r['server'] == 'dns-proxy'), isTrue);
    });

    test('全局模式无节点：final 回落 direct，不指不存在的 Proxy', () {
      final result = SingboxConfigBuilder.build(
        [],
        mode: RoutingMode.global,
      );
      final route = result.config['route'] as Map<String, dynamic>;
      expect((route['rules'] as List), isEmpty);
      expect(route['final'], 'direct');
      expect(_outboundsByTag(result.config).keys, {'direct', 'block'});
    });

    test('直连模式：route 无规则、final 是 direct；DNS 全部走直连解析', () {
      final result = SingboxConfigBuilder.build(
        twoNodes(),
        mode: RoutingMode.direct,
      );
      final route = result.config['route'] as Map<String, dynamic>;
      expect((route['rules'] as List), isEmpty);
      expect(route['final'], 'direct');
      final rules = dnsRules(result.config);
      expect(rules.every((r) => r['server'] == 'dns-direct'), isTrue);
      // 节点出站本身还在（直连模式不断核心，只是 route 不走它们）。
      expect(_outboundsByTag(result.config).containsKey('Proxy'), isTrue);
    });

    test('规则模式 DNS：.cn 直连、TikTok 与测 IP 走代理', () {
      final result = SingboxConfigBuilder.build(
        twoNodes(),
        mode: RoutingMode.rule,
      );
      final rules = dnsRules(result.config);
      expect(rules.length, 3);
      expect(rules[0]['server'], 'dns-direct');
      expect(rules[1]['server'], 'dns-proxy');
      expect(rules[2]['server'], 'dns-proxy');
    });
  });

  group('selector 默认节点与 tag 映射（切片 4）', () {
    Node node(
      String name,
      NodeSource source, {
      NodeProtocol protocol = NodeProtocol.vless,
      String transport = 'tcp',
    }) => Node(
      name: name,
      protocol: protocol,
      address: '203.0.113.1',
      port: 443,
      source: source,
      uuidOrPassword: '11111111-2222-3333-4444-555555555555',
      transport: transport,
      tls: true,
    );

    test('tagForNode：名字就是 tag；重名加 (2) 后缀，与配置一致', () {
      final a = node('香港-中转', NodeSource.relay);
      final b = node('香港-中转', NodeSource.relay);
      final c = node('智利-直连', NodeSource.direct);
      final nodes = [a, b, c];
      expect(SingboxConfigBuilder.tagForNode(nodes, a), '香港-中转');
      expect(SingboxConfigBuilder.tagForNode(nodes, b), '香港-中转 (2)');
      expect(SingboxConfigBuilder.tagForNode(nodes, c), '智利-直连');
      // 和 build() 生成的 tag 对得上（同一个列表、同一套去重）。
      final built = SingboxConfigBuilder.build(nodes);
      final tags = _outboundsByTag(built.config).keys;
      expect(tags, containsAll(['香港-中转', '香港-中转 (2)', '智利-直连']));
    });

    test('tagForNode：生成时会被跳过的节点返回 null', () {
      final grpc = node(
        'grpc-直连',
        NodeSource.direct,
        transport: 'grpc',
      );
      final unknown = node(
        '未知-直连',
        NodeSource.direct,
        protocol: NodeProtocol.unknown,
      );
      final ok = node('智利-直连', NodeSource.direct);
      final nodes = [grpc, unknown, ok];
      expect(SingboxConfigBuilder.tagForNode(nodes, grpc), isNull);
      expect(SingboxConfigBuilder.tagForNode(nodes, unknown), isNull);
      expect(SingboxConfigBuilder.tagForNode(nodes, ok), '智利-直连');
    });

    test('defaultNodeName：第一个直连节点；没有直连时取第一个', () {
      expect(
        SingboxConfigBuilder.defaultNodeName([
          node('甲-中转', NodeSource.relay),
          node('乙-直连', NodeSource.direct),
        ]),
        '乙-直连',
      );
      expect(
        SingboxConfigBuilder.defaultNodeName([
          node('甲-中转', NodeSource.relay),
          node('乙-中转', NodeSource.relay),
        ]),
        '甲-中转',
      );
      expect(SingboxConfigBuilder.defaultNodeName([]), isNull);
      // 全是跳过的节点时也没有默认节点。
      expect(
        SingboxConfigBuilder.defaultNodeName([
          node('grpc-直连', NodeSource.direct, transport: 'grpc'),
        ]),
        isNull,
      );
    });

    test('build(selectedNodeName)：selector 默认用指定的节点', () {
      final nodes = [
        node('甲-直连', NodeSource.direct),
        node('乙-中转', NodeSource.relay),
      ];
      final result = SingboxConfigBuilder.build(
        nodes,
        selectedNodeName: '乙-中转',
      );
      final proxy = _outboundsByTag(result.config)['Proxy']!;
      expect(proxy['default'], '乙-中转');
    });

    test('build(selectedNodeName)：名字不在列表里、或节点被跳过时回落默认', () {
      final nodes = [
        node('甲-直连', NodeSource.direct),
        node('乙-中转', NodeSource.relay),
      ];
      final unknown = SingboxConfigBuilder.build(
        nodes,
        selectedNodeName: '不存在的节点',
      );
      expect(
        _outboundsByTag(unknown.config)['Proxy']!['default'],
        '甲-直连',
      );
      final skipped = SingboxConfigBuilder.build(
        [
          node('甲-直连', NodeSource.direct),
          node('grpc-中转', NodeSource.relay, transport: 'grpc'),
        ],
        selectedNodeName: 'grpc-中转',
      );
      expect(
        _outboundsByTag(skipped.config)['Proxy']!['default'],
        '甲-直连',
      );
    });

    test('build 不传 selectedNodeName 时默认规则不变（老调用不受影响）', () {
      final nodes = [
        node('甲-中转', NodeSource.relay),
        node('乙-直连', NodeSource.direct),
      ];
      final result = SingboxConfigBuilder.build(nodes);
      expect(
        _outboundsByTag(result.config)['Proxy']!['default'],
        '乙-直连',
      );
    });
  });

  group('自定义规则与 TUN（切片 6）', () {
    Node ruleNode(String name, NodeSource source) => Node(
      name: name,
      protocol: NodeProtocol.vless,
      address: '203.0.113.1',
      port: 443,
      source: source,
      uuidOrPassword: '11111111-2222-3333-4444-555555555555',
      tls: true,
    );

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
        [ruleNode('甲-直连', NodeSource.direct)],
        customRules: rules,
      );
      final route = result.config['route'] as Map<String, dynamic>;
      final routeRules = (route['rules'] as List).cast<Map<String, dynamic>>();
      expect(routeRules[0]['domain_suffix'], ['example.com']);
      expect(routeRules[0]['outbound'], 'direct');
      expect(routeRules[1]['domain_suffix'], ['work.example.net']);
      expect(routeRules[1]['outbound'], 'Proxy');
      expect(
        routeRules[2]['domain_suffix'],
        SingboxConfigBuilder.tiktokSuffixes,
      );

      final dns = result.config['dns'] as Map<String, dynamic>;
      final dnsRules = (dns['rules'] as List).cast<Map<String, dynamic>>();
      expect(dnsRules[0]['domain_suffix'], ['example.com']);
      expect(dnsRules[0]['server'], 'dns-direct');
      expect(dnsRules[1]['domain_suffix'], ['work.example.net']);
      expect(dnsRules[1]['server'], 'dns-proxy');
    });

    test('关闭的规则不进配置；没有节点时走代理的规则不进', () {
      final disabled = SingboxConfigBuilder.build(
        [ruleNode('甲-直连', NodeSource.direct)],
        customRules: [
          const CustomRule(
            id: '1',
            domain: 'example.com',
            action: CustomRuleAction.direct,
            enabled: false,
          ),
        ],
      );
      expect(jsonEncode(disabled.config).contains('example.com'), isFalse);

      final noNodes = SingboxConfigBuilder.build(
        [],
        customRules: [
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
        ],
      );
      final route = noNodes.config['route'] as Map<String, dynamic>;
      final routeRules = (route['rules'] as List).cast<Map<String, dynamic>>();
      expect(routeRules.length, 2);
      expect(routeRules[0]['domain_suffix'], ['direct.example.com']);
    });

    test('tunEnabled=true 加一条 tun 入站；=false 不写', () {
      final off = SingboxConfigBuilder.build([
        ruleNode('甲-直连', NodeSource.direct),
      ]);
      final offInbounds = off.config['inbounds'] as List;
      expect(offInbounds.length, 1);

      final on = SingboxConfigBuilder.build(
        [ruleNode('甲-直连', NodeSource.direct)],
        tunEnabled: true,
      );
      final onInbounds = on.config['inbounds'] as List;
      expect(onInbounds.length, 2);
      final tun = onInbounds[1] as Map<String, dynamic>;
      expect(tun['type'], 'tun');
      expect(tun['tag'], 'tun-in');
      expect(tun['auto_route'], isTrue);
    });

    test('DNS 摘要含 DoH 双路、DoT 兜底、仅 IPv4、不回落明文、防泄漏不可关闭', () {
      final text = SingboxConfigBuilder.dnsSummary
          .map((e) => '${e.label}：${e.value}')
          .join('\n');
      expect(text, contains('1.1.1.1'));
      expect(text, contains('dns.google'));
      expect(text, contains('8.8.8.8:853'));
      expect(text, contains('ipv4_only'));
      expect(text, contains('不可关闭'));
    });
  });

  group('切片 10：REALITY / AnyTLS / SOCKS5 出站与同节点 fallback 组', () {
    // 契约样例（~/workspace/slice10-fixtures/contract.md）：先解析
    // 再生成，出站与分组必须与契约一致。
    const contractBase64 =
        'dmxlc3M6Ly8xMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTVAMjAzLjAuMTEzLjE6NDQzP2VuY3J5cHRpb249bm9uZSZzZWN1cml0eT1yZWFsaXR5JnBiaz1BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBJnNpZD1hYmNkZWYwMSZzbmk9d3d3Lm1pY3Jvc29mdC5jb20mZnA9Y2hyb21lJnR5cGU9dGNwJmZsb3c9eHRscy1ycHJ4LXZpc2lvbiNleGFtcGxlLW5vZGUtcmVhbGl0eS00NDMKYW55dGxzOi8vMTExMTExMTEtMjIyMi0zMzMzLTQ0NDQtNTU1NTU1NTU1NTU1QDIwMy4wLjExMy4xOjQ0Mz9zbmk9ZXhhbXBsZS5jb20jZXhhbXBsZS1ub2RlLWFueXRscy00NDMKc29ja3M1Oi8vdXNlcjE6cGFzczEyMzRAMjAzLjAuMTEzLjE6MTA4MCNleGFtcGxlLW5vZGUtc29ja3MtMTA4MAo=';

    List<Node> contractNodes() =>
        parseLinkList(contractBase64).nodes;

    test('契约三节点：出站形状与契约逐字一致', () {
      final result = SingboxConfigBuilder.build(contractNodes());
      expect(result.skipped, isEmpty);
      final byTag = _outboundsByTag(result.config);

      final reality = byTag['example-node-reality-443']!;
      expect(reality, {
        'type': 'vless',
        'tag': 'example-node-reality-443',
        'server': '203.0.113.1',
        'server_port': 443,
        'uuid': '11111111-2222-3333-4444-555555555555',
        'flow': 'xtls-rprx-vision',
        'tls': {
          'enabled': true,
          'server_name': 'www.microsoft.com',
          'utls': {'enabled': true, 'fingerprint': 'chrome'},
          'reality': {
            'enabled': true,
            'public_key':
                'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
            'short_id': 'abcdef01',
          },
        },
      });

      final anytls = byTag['example-node-anytls-443']!;
      expect(anytls, {
        'type': 'anytls',
        'tag': 'example-node-anytls-443',
        'server': '203.0.113.1',
        'server_port': 443,
        'password': '11111111-2222-3333-4444-555555555555',
        'tls': {'enabled': true, 'server_name': 'example.com'},
      });

      final socks = byTag['example-node-socks-1080']!;
      expect(socks, {
        'type': 'socks',
        'tag': 'example-node-socks-1080',
        'server': '203.0.113.1',
        'server_port': 1080,
        'version': '5',
        'username': 'user1',
        'password': 'pass1234',
      });
    });

    test('契约三节点：urltest 组名就是节点名，成员是三个入站', () {
      final result = SingboxConfigBuilder.build(contractNodes());
      final byTag = _outboundsByTag(result.config);

      final group = byTag['example-node']!;
      expect(group['type'], 'urltest');
      expect(group['outbounds'], [
        'example-node-reality-443',
        'example-node-anytls-443',
        'example-node-socks-1080',
      ]);
      expect(group['url'], 'http://www.gstatic.com/generate_204');
      expect(group['interval'], '5m');

      // selector 里该节点只占组 tag 一位，默认就是组 tag。
      final proxy = byTag['Proxy']!;
      expect(proxy['type'], 'selector');
      expect(proxy['outbounds'], ['example-node']);
      expect(proxy['default'], 'example-node');

      // '自动选择' 仍列全部节点自己的 tag（原有行为）。
      final auto = byTag['自动选择']!;
      expect(auto['outbounds'], [
        'example-node-reality-443',
        'example-node-anytls-443',
        'example-node-socks-1080',
      ]);
    });

    test('单个入站的节点不成组，直接进 selector', () {
      final nodes = [
        parseNodeLink(
          'vless://11111111-2222-3333-4444-555555555555@203.0.113.1:443'
          '?encryption=none&security=reality'
          '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          '&sid=abcdef01&sni=www.microsoft.com&fp=chrome&type=tcp'
          '&flow=xtls-rprx-vision#example-node-reality-443',
        )!,
      ];
      final result = SingboxConfigBuilder.build(nodes);
      final byTag = _outboundsByTag(result.config);
      expect(byTag.containsKey('example-node'), isFalse);
      expect(byTag['Proxy']!['outbounds'], ['example-node-reality-443']);
      expect(byTag['Proxy']!['default'], 'example-node-reality-443');
    });

    test('成组节点＋未成组节点混排：selector 按顺序列组与单节点', () {
      final nodes = [
        ...contractNodes(),
        Node(
          name: '智利-直连',
          protocol: NodeProtocol.vless,
          address: '203.0.113.2',
          port: 443,
          source: NodeSource.direct,
          uuidOrPassword: '11111111-2222-3333-4444-555555555555',
          tls: true,
          sni: 'cl04.example.com',
        ),
      ];
      final result = SingboxConfigBuilder.build(nodes);
      expect(result.skipped, isEmpty);
      final byTag = _outboundsByTag(result.config);
      expect(byTag['Proxy']!['outbounds'], ['example-node', '智利-直连']);
      // 默认选第一个直连节点：契约三节点都是直连来源，第一个是组 tag。
      expect(byTag['Proxy']!['default'], 'example-node');
    });

    test('selectedNodeName 指向成组节点时默认就是组 tag', () {
      final result = SingboxConfigBuilder.build(
        contractNodes(),
        selectedNodeName: 'example-node-anytls-443',
      );
      final byTag = _outboundsByTag(result.config);
      expect(byTag['Proxy']!['default'], 'example-node');
    });

    test('REALITY 指纹缺省时按 chrome 写；无 flow 时不写 flow', () {
      final node = Node(
        name: 'example-node-reality-443',
        protocol: NodeProtocol.vless,
        address: '203.0.113.1',
        port: 443,
        source: NodeSource.direct,
        uuidOrPassword: '11111111-2222-3333-4444-555555555555',
        tls: true,
        sni: 'www.microsoft.com',
        realityPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        realityShortId: 'abcdef01',
      );
      final result = SingboxConfigBuilder.build([node]);
      final byTag = _outboundsByTag(result.config);
      final reality = byTag['example-node-reality-443']!;
      final tls = reality['tls'] as Map<String, dynamic>;
      expect(
        (tls['utls'] as Map<String, dynamic>)['fingerprint'],
        'chrome',
      );
      expect(reality.containsKey('flow'), isFalse);
    });

    test('SOCKS5 缺用户名：跳过并给出原因', () {
      final node = Node(
        name: 'example-node-socks-1080',
        protocol: NodeProtocol.socks5,
        address: '203.0.113.1',
        port: 1080,
        source: NodeSource.direct,
        uuidOrPassword: 'pass1234',
      );
      final result = SingboxConfigBuilder.build([node]);
      expect(result.skipped, ['example-node-socks-1080：缺少 SOCKS5 用户名']);
      final byTag = _outboundsByTag(result.config);
      expect(byTag.containsKey('example-node-socks-1080'), isFalse);
    });
  });
}
