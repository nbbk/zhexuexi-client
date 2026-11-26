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
    test('两台服务器：直连 AliDNS DoH＋代理 8.8.8.8 DoH，只解析 IPv4', () async {
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final result = SingboxConfigBuilder.build(nodes);
      expect(result.skipped, isEmpty);

      final dns = result.config['dns'] as Map<String, dynamic>;
      expect(dns['strategy'], 'ipv4_only');
      // 未列入规则的域名走代理 DNS（有节点时），不再走直连 DoT。
      expect(dns['final'], 'dns-proxy');

      final servers = _dnsServers(result.config);
      expect(servers.length, 2);
      final direct = servers[0];
      expect(direct['tag'], 'dns-direct');
      expect(direct['type'], 'https');
      // 直连解析走阿里云 223.5.5.5：1.1.1.1 国内直连被拦。
      expect(direct['server'], '223.5.5.5');
      expect(direct['server_port'], 443);
      expect(direct['path'], '/dns-query');
      // 直连解析不写 detour（detour 指 direct 出站时 1.14.4 run 拒绝）。
      expect(direct.containsKey('detour'), isFalse);
      expect(direct.containsKey('address'), isFalse);

      final proxy = servers[1];
      expect(proxy['tag'], 'dns-proxy');
      expect(proxy['type'], 'https');
      // 代理 DNS 必须写 IP 不能写域名：dns.google 要先经
      // default_domain_resolver 解析，直连解析一死就全死。
      expect(proxy['server'], '8.8.8.8');
      expect(proxy['server_port'], 443);
      // 代理 DNS 的 detour 必须是 selector 的 tag `Proxy`（逐字一致）。
      expect(proxy['detour'], 'Proxy');

      // 全配置里不许出现 legacy address 写法与已退场的 dns-dot。
      final flat = jsonEncode(result.config);
      expect(flat.contains('"address"'), isFalse);
      expect(flat.contains('dns-dot'), isFalse);
      expect(flat.contains('dns.google'), isFalse);
      expect(flat.contains('1.1.1.1'), isFalse);
    });

    test('DNS 规则：.cn 直连、TikTok / 测 IP / 社交 / 流媒体走代理', () async {
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final result = SingboxConfigBuilder.build(nodes);
      final dns = result.config['dns'] as Map<String, dynamic>;
      final rules = (dns['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.length, 6);
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
      expect(
        (rules[3]['domain_suffix'] as List).contains('facebook.com'),
        isTrue,
      );
      expect(rules[3]['server'], 'dns-proxy');
      expect(
        (rules[4]['domain_suffix'] as List).contains('youtube.com'),
        isTrue,
      );
      expect(rules[4]['server'], 'dns-proxy');
      expect(
        (rules[5]['domain_suffix'] as List).contains('google.com'),
        isTrue,
      );
      expect(rules[5]['server'], 'dns-proxy');
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
      // 前两条（0.1.2 根因 R1，0.1.3 D 路第 1 步删掉 DNS 劫持，
      // 0.1.4 D 路第 2 步删掉 QUIC 阻断，0.1.5 加回，0.1.6 回滚删掉）：
      // sniff、私网旁路；其后才是 TikTok / 社交 / 流媒体 / 测 IP /
      // Google → Proxy，.cn → direct。
      expect(rules.length, 8);
      expect(rules[0], {'action': 'sniff', 'timeout': '300ms'});
      expect(rules[1], {'ip_is_private': true, 'outbound': 'direct'});
      expect(rules[2]['outbound'], 'Proxy');
      expect(
        (rules[2]['domain_suffix'] as List).contains('tiktok.com'),
        isTrue,
      );
      expect(rules[3]['outbound'], 'Proxy');
      expect(
        (rules[3]['domain_suffix'] as List).contains('facebook.com'),
        isTrue,
      );
      expect(rules[4]['outbound'], 'Proxy');
      expect(
        (rules[4]['domain_suffix'] as List).contains('youtube.com'),
        isTrue,
      );
      expect(rules[5]['outbound'], 'Proxy');
      expect(
        (rules[5]['domain_suffix'] as List).contains('ip-api.com'),
        isTrue,
      );
      expect(rules[6]['outbound'], 'Proxy');
      expect(
        (rules[6]['domain_suffix'] as List).contains('google.com'),
        isTrue,
      );
      expect(rules[7]['domain_suffix'], ['.cn']);
      expect(rules[7]['outbound'], 'direct');
    });

    test('空节点：合法空配置，不引用不存在的 Proxy 组', () {
      final result = SingboxConfigBuilder.build([]);
      expect(result.skipped, isEmpty);
      final byTag = _outboundsByTag(result.config);
      expect(byTag.keys, {'direct', 'block'});
      final route = result.config['route'] as Map<String, dynamic>;
      final rules = (route['rules'] as List).cast<Map<String, dynamic>>();
      // 无节点时也保留前两条（sniff / 私网旁路，都不
      // 引用 Proxy 组），其后只有 .cn。
      expect(rules.length, 3);
      expect(rules[0], {'action': 'sniff', 'timeout': '300ms'});
      expect(rules[1], {'ip_is_private': true, 'outbound': 'direct'});
      expect(rules[2]['domain_suffix'], ['.cn']);
      expect(route['final'], 'direct');
      // DNS 与入站、Clash API 照常在；节点为空没有 Proxy 组，
      // 代理 DNS 也不写 detour，服务器是 IP（域名无人解析）。
      // 无节点时 final 回落直连解析（没有代理可走）。
      final dnsServers = _dnsServers(result.config);
      expect(dnsServers.length, 2);
      expect(dnsServers[1].containsKey('detour'), isFalse);
      expect(dnsServers[1]['server'], '8.8.8.8');
      final dns = result.config['dns'] as Map<String, dynamic>;
      expect(dns['final'], 'dns-direct');
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
      // 0.1.8：HY2 出站不填 up/down_mbps（删掉 0.1.7 的两行，回 BBR）。
      expect(hy2.containsKey('up_mbps'), isFalse);
      expect(hy2.containsKey('down_mbps'), isFalse);
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
      // 0.1.8：无 alpn 也不填 Brutal 带宽（两行已删，回 BBR）。
      expect(hy2Out.containsKey('up_mbps'), isFalse);
      expect(hy2Out.containsKey('down_mbps'), isFalse);
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
      expect((route['rules'] as List).length, 8);
    });

    test('全局模式：route 无规则、final 指 Proxy；DNS 全部走代理', () {
      final result = SingboxConfigBuilder.build(
        twoNodes(),
        mode: RoutingMode.global,
      );
      final route = result.config['route'] as Map<String, dynamic>;
      // 全局模式 route 只有前两条（不引用 Proxy 的基础规则），无内置组。
      expect((route['rules'] as List).length, 2);
      expect(route['final'], 'Proxy');
      // 出站组还在（Proxy selector 与自动选择都在）。
      expect(_outboundsByTag(result.config).containsKey('Proxy'), isTrue);
      final rules = dnsRules(result.config);
      // 除 .cn 外全部走代理 DNS；.cn 恒走直连解析（0.1.2 全局慢 P1-1）。
      expect(rules[0]['domain_suffix'], ['.cn']);
      expect(rules[0]['server'], 'dns-direct');
      expect(
        rules.skip(1).every((r) => r['server'] == 'dns-proxy'),
        isTrue,
      );
    });

    test('全局模式无节点：final 回落 direct，不指不存在的 Proxy', () {
      final result = SingboxConfigBuilder.build(
        [],
        mode: RoutingMode.global,
      );
      final route = result.config['route'] as Map<String, dynamic>;
      expect((route['rules'] as List).length, 2);
      expect(route['final'], 'direct');
      expect(_outboundsByTag(result.config).keys, {'direct', 'block'});
    });

    test('直连模式：route 无规则、final 是 direct；DNS 全部走直连解析', () {
      final result = SingboxConfigBuilder.build(
        twoNodes(),
        mode: RoutingMode.direct,
      );
      final route = result.config['route'] as Map<String, dynamic>;
      // 直连模式 route 也只有前两条（都不引用 Proxy），无内置组。
      expect((route['rules'] as List).length, 2);
      expect(route['final'], 'direct');
      final rules = dnsRules(result.config);
      expect(rules.every((r) => r['server'] == 'dns-direct'), isTrue);
      // 直连模式没有任何一条 route 规则引用 Proxy。
      final routeRules =
          (route['rules'] as List).cast<Map<String, dynamic>>();
      expect(
        routeRules.any((r) => r['outbound'] == 'Proxy'),
        isFalse,
      );
      // 直连模式 final 同样走直连解析，不让任何 DNS 查询经代理。
      final dns = result.config['dns'] as Map<String, dynamic>;
      expect(dns['final'], 'dns-direct');
      // 节点出站本身还在（直连模式不断核心，只是 route 不走它们）。
      expect(_outboundsByTag(result.config).containsKey('Proxy'), isTrue);
    });

    test('规则模式 DNS：.cn 直连、TikTok / 测 IP / 社交 / 流媒体走代理', () {
      final result = SingboxConfigBuilder.build(
        twoNodes(),
        mode: RoutingMode.rule,
      );
      final rules = dnsRules(result.config);
      expect(rules.length, 6);
      expect(rules[0]['server'], 'dns-direct');
      expect(rules[1]['server'], 'dns-proxy');
      expect(rules[2]['server'], 'dns-proxy');
      expect(rules[3]['server'], 'dns-proxy');
      expect(rules[4]['server'], 'dns-proxy');
      expect(rules[5]['server'], 'dns-proxy');
      expect(
        (rules[5]['domain_suffix'] as List).contains('google.com'),
        isTrue,
      );
      // 规则模式有节点时 final 走代理 DNS（未列入规则的域名也一样）。
      final dns = result.config['dns'] as Map<String, dynamic>;
      expect(dns['final'], 'dns-proxy');
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

    test('selectorTagForNode（问题 7）：成组节点取组 tag，未成组取自身 tag', () {
      // 双胞胎 A/B：同名多入站成 urltest 组，selector 里只占组 tag 一位。
      final realityA = node('测试机-reality-443-A', NodeSource.direct);
      final realityB = node('测试机-reality-443-B', NodeSource.relay);
      final hy2A = node('测试机-hy2-443-A', NodeSource.direct);
      final single = node('智利-直连', NodeSource.direct);
      final nodes = [realityA, realityB, hy2A, single];
      // 测速仍用自身 tag（delay 接口认出站 tag）。
      expect(
        SingboxConfigBuilder.tagForNode(nodes, realityA),
        '测试机-reality-443-A',
      );
      // 切换认组 tag（selector 成员只有组 tag，PUT 自身 tag 会 400）。
      expect(
        SingboxConfigBuilder.selectorTagForNode(nodes, realityA),
        '测试机',
      );
      expect(
        SingboxConfigBuilder.selectorTagForNode(nodes, realityB),
        '测试机',
      );
      expect(
        SingboxConfigBuilder.selectorTagForNode(nodes, hy2A),
        '测试机',
      );
      expect(
        SingboxConfigBuilder.selectorTagForNode(nodes, single),
        '智利-直连',
      );
      // 和 build() 的 selector 成员、default 对得上。
      final built = SingboxConfigBuilder.build(nodes);
      final byTag = _outboundsByTag(built.config);
      expect(byTag['Proxy']!['outbounds'], ['测试机', '智利-直连']);
      expect(byTag['Proxy']!['default'], '测试机');
    });

    test('selectorTagForNode：生成时会被跳过的节点返回 null', () {
      final grpc = node(
        'grpc-直连',
        NodeSource.direct,
        transport: 'grpc',
      );
      final ok = node('智利-直连', NodeSource.direct);
      final nodes = [grpc, ok];
      expect(SingboxConfigBuilder.selectorTagForNode(nodes, grpc), isNull);
      expect(
        SingboxConfigBuilder.selectorTagForNode(nodes, ok),
        '智利-直连',
      );
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
      // 0.1.6：route 前 2 条是前缀（sniff/私网旁路，
      // QUIC 阻断随 0.1.6 回滚删掉），自定义规则在 [2][3]、TikTok 在 [4]。
      expect(routeRules[2]['domain_suffix'], ['example.com']);
      expect(routeRules[2]['outbound'], 'direct');
      expect(routeRules[3]['domain_suffix'], ['work.example.net']);
      expect(routeRules[3]['outbound'], 'Proxy');
      expect(
        routeRules[4]['domain_suffix'],
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
      // 无节点：2 条前缀＋直连自定义 1 条＋.cn 1 条＝4 条；
      // 走代理的自定义规则没进（没有 Proxy 组可指）。
      expect(routeRules.length, 4);
      expect(routeRules[2]['domain_suffix'], ['direct.example.com']);
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

    test('tun 入站不写 stack（2026-11-26 根因回归）', () {
      // 插件内置 schema 的 tun 分支没有 stack 属性、且
      // additionalProperties: false，写了 stack 校验就拒整份配置，
      // TUN 默认开之后点开关、切模式全卡在 applyNodes；不写 stack
      // 时 sing-box 用默认栈（带 gvisor 编译时 mixed，否则 system）。
      final on = SingboxConfigBuilder.build(
        [ruleNode('甲-直连', NodeSource.direct)],
        tunEnabled: true,
      );
      final tun =
          (on.config['inbounds'] as List)[1] as Map<String, dynamic>;
      expect(tun.containsKey('stack'), isFalse);
      // 其余 tun 字段不动：地址仍是裸字符串（schema 的 Listable 认）。
      expect(tun['address'], '172.19.0.1/30');
      expect(tun['strict_route'], isTrue);
    });

    test('TUN MTU 是 1500，不写 9000（2026-11-26 二轮修复）', () {
      // 9000 远高于手机物理 MTU 约 1500，大包分片/黑洞风险；
      // 拨测不走 TUN 所以它不是拨测全灭的主因，只是叠加因素。
      final on = SingboxConfigBuilder.build(
        [ruleNode('甲-直连', NodeSource.direct)],
        tunEnabled: true,
      );
      final tun =
          (on.config['inbounds'] as List)[1] as Map<String, dynamic>;
      expect(tun['mtu'], 1500);
    });

    test('route 不写 auto_detect_interface / default_interface'
        '（2026-11-26 二轮修复）', () {
      // 上游 1.14.4 route/network.go：这三项在 Android 上写了就
      // 启动报错（"only supported on Linux, Windows and macOS"），
      // 文档 auto_route 一节的三选一在 Android 上全是死路；
      // 环路隔离在插件层 VPNService.openTun 做
      //（addDisallowedApplication 自家包名），不在配置里。
      final on = SingboxConfigBuilder.build(
        [ruleNode('甲-直连', NodeSource.direct)],
        tunEnabled: true,
      );
      final route = on.config['route'] as Map<String, dynamic>;
      expect(route.containsKey('auto_detect_interface'), isFalse);
      expect(route.containsKey('default_interface'), isFalse);
      expect(route.containsKey('override_android_vpn'), isFalse);
      final outbounds = on.config['outbounds'] as List;
      for (final ob in outbounds.cast<Map<String, dynamic>>()) {
        expect(ob.containsKey('bind_interface'), isFalse);
      }
    });

    test('DNS 摘要含 DoH 双路、仅 IPv4、不回落明文、防泄漏不可关闭', () {
      final text = SingboxConfigBuilder.dnsSummary
          .map((e) => '${e.label}：${e.value}')
          .join('\n');
      expect(text, contains('223.5.5.5'));
      expect(text, contains('8.8.8.8/dns-query'));
      expect(text, contains('ipv4_only'));
      expect(text, contains('不可关闭'));
      // 退场的写法不许再出现在摘要里。
      expect(text.contains('dns.google'), isFalse);
      expect(text.contains('1.1.1.1'), isFalse);
      expect(text.contains('8.8.8.8:853'), isFalse);
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

  group('DNS 根因回归（2026-11-26：开关开着没网络＋测速全红点）', () {
    Node dnsNode(String name) => Node(
      name: name,
      protocol: NodeProtocol.vless,
      address: '203.0.113.1',
      port: 443,
      source: NodeSource.direct,
      uuidOrPassword: '11111111-2222-3333-4444-555555555555',
      tls: true,
      sni: 'www.microsoft.com',
    );

    test('测速地址 www.gstatic.com 的 DNS 走代理，不走直连死路', () {
      // Clash API delay 测 https://www.gstatic.com/generate_204。
      // 0.1.2 之前该域名不在任何 DNS 规则里，走 final；final 曾是
      // 直连 DoT 8.8.8.8，国内被拦，每个节点的 delay 都 503，全红点。
      // 0.1.2 起 Google 基础域组覆盖 gstatic.com，明确走代理 DNS。
      final result = SingboxConfigBuilder.build([dnsNode('甲-直连')]);
      final dns = result.config['dns'] as Map<String, dynamic>;
      expect(dns['final'], 'dns-proxy');
      final rules = (dns['rules'] as List).cast<Map<String, dynamic>>();
      final matched = rules.where(
        (r) => (r['domain_suffix'] as List).contains('gstatic.com'),
      );
      expect(matched.length, 1);
      expect(matched.first['server'], 'dns-proxy');
    });

    test('带 detour 的 DNS 服务器写 IP：全配置无域名型 DNS 服务器', () {
      final result = SingboxConfigBuilder.build([dnsNode('甲-直连')]);
      final dns = result.config['dns'] as Map<String, dynamic>;
      final servers = (dns['servers'] as List).cast<Map<String, dynamic>>();
      for (final server in servers) {
        if (!server.containsKey('detour')) continue;
        final address = server['server'] as String;
        expect(
          RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(address),
          isTrue,
          reason: '${server['tag']} 的 server 必须是 IP：$address',
        );
      }
      // 直连解析也不依赖境外 IP。
      expect(servers[0]['server'], '223.5.5.5');
    });

    test('TUN 开着的配置同样走新 DNS（开关开着才进 TUN）', () {
      final result = SingboxConfigBuilder.build(
        [dnsNode('甲-直连')],
        tunEnabled: true,
      );
      final dns = result.config['dns'] as Map<String, dynamic>;
      expect(dns['final'], 'dns-proxy');
      final flat = jsonEncode(result.config);
      expect(flat.contains('dns-dot'), isFalse);
      expect(flat.contains('dns.google'), isFalse);
    });
  });

  group('0.1.2：REALITY 指纹强制 chrome、规则模式 sniff、Google 组', () {
    Node realityNode({String? fingerprint}) => Node(
      name: 'reality-节点',
      protocol: NodeProtocol.vless,
      address: '203.0.113.1',
      port: 443,
      source: NodeSource.direct,
      uuidOrPassword: '11111111-2222-3333-4444-555555555555',
      transport: 'tcp',
      tls: true,
      sni: 'www.microsoft.com',
      realityPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      fingerprint: fingerprint,
    );

    test('firefox/safari 指纹的 REALITY 节点仍生成 chrome', () {
      for (final fp in ['firefox', 'safari', null]) {
        final result = SingboxConfigBuilder.build([realityNode(fingerprint: fp)]);
        final outbound =
            (result.config['outbounds'] as List).first as Map<String, dynamic>;
        final tls = outbound['tls'] as Map<String, dynamic>;
        expect((tls['utls'] as Map)['fingerprint'], 'chrome');
      }
    });

    test('reality 块不含 support_x25519mlkem768（1.14.4 无此字段）', () {
      final result = SingboxConfigBuilder.build([realityNode()]);
      final flat = jsonEncode(result.config);
      expect(flat.contains('support_x25519mlkem768'), isFalse);
    });

    test('DNS 段有 reverse_mapping；劫持对一起去掉（0.1.3 D 路第 1 步）', () {
      // 劫持对是同一机制的两端，必须一起开关：route 里没有 hijack-dns
      // 规则，TUN 入站里也没有 dns_mode 键；只去其一更差（TUN 还在
      // 拦截 DNS、却没有规则应答它）。三种模式＋TUN 开/关全查。
      for (final mode in RoutingMode.values) {
        for (final tun in [false, true]) {
          final result = SingboxConfigBuilder.build(
            [realityNode()],
            mode: mode,
            tunEnabled: tun,
          );
          final flat = jsonEncode(result.config);
          expect(flat.contains('hijack-dns'), isFalse);
          expect(flat.contains('dns_mode'), isFalse);
          final dns = result.config['dns'] as Map<String, dynamic>;
          expect(dns['reverse_mapping'], isTrue);
          if (tun) {
            final inbounds = result.config['inbounds'] as List;
            final tunInbound = inbounds[1] as Map<String, dynamic>;
            expect(tunInbound['type'], 'tun');
            expect(tunInbound.containsKey('dns_mode'), isFalse);
          }
        }
      }
    });

    test('Google 基础域组齐全（20 个）且 route/DNS 各有一条', () {
      expect(SingboxConfigBuilder.googleInfraSuffixes.length, 20);
      for (final domain in [
        'google.com',
        'googleapis.com',
        'gstatic.com',
        'play.google.com',
        'android.com',
        'youtube-nocookie.com',
      ]) {
        expect(
          SingboxConfigBuilder.googleInfraSuffixes,
          contains(domain),
        );
      }
      final result = SingboxConfigBuilder.build([realityNode()]);
      final route = result.config['route'] as Map<String, dynamic>;
      final routeRules =
          (route['rules'] as List).cast<Map<String, dynamic>>();
      final googleRoute = routeRules.where(
        (r) => (r['domain_suffix'] as List?)?.contains('google.com') ?? false,
      );
      expect(googleRoute.length, 1);
      expect(googleRoute.first['outbound'], 'Proxy');
      final dns = result.config['dns'] as Map<String, dynamic>;
      final dnsRules = (dns['rules'] as List).cast<Map<String, dynamic>>();
      final googleDns = dnsRules.where(
        (r) => (r['domain_suffix'] as List).contains('google.com'),
      );
      expect(googleDns.length, 1);
      expect(googleDns.first['server'], 'dns-proxy');
    });

    test('全局模式 .cn 走 dns-direct，route final 仍是 Proxy', () {
      final result = SingboxConfigBuilder.build(
        [realityNode()],
        mode: RoutingMode.global,
      );
      final dns = result.config['dns'] as Map<String, dynamic>;
      final dnsRules = (dns['rules'] as List).cast<Map<String, dynamic>>();
      final cnRule = dnsRules.firstWhere(
        (r) => (r['domain_suffix'] as List).contains('.cn'),
      );
      expect(cnRule['server'], 'dns-direct');
      final route = result.config['route'] as Map<String, dynamic>;
      expect(route['final'], 'Proxy');
      expect(dns['final'], 'dns-proxy');
    });

    test('直连模式没有任何 route 规则引用 Proxy', () {
      final result = SingboxConfigBuilder.build(
        [realityNode()],
        mode: RoutingMode.direct,
      );
      final route = result.config['route'] as Map<String, dynamic>;
      final routeRules =
          (route['rules'] as List).cast<Map<String, dynamic>>();
      expect(
        routeRules.any((r) => r['outbound'] == 'Proxy'),
        isFalse,
      );
    });
  });
}
