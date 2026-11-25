// 切片 1：三种订阅格式解析的回归测试。
//
// fixture 全部用脱敏数据（example.com / 203.0.113.x / 假 UUID），形状按
// 面板 1.3.37 的实际输出（sing-box JSON 新 DNS 格式）与 panel-adapter.md
// §6 的字段清单编。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/services/subscription_parser.dart';

Future<String> _fixture(String name) =>
    File('test/fixtures/$name').readAsString();

void main() {
  group('sing-box JSON（面板 1.3.37 形状）', () {
    test('4 个节点 + 1 个坏节点，组出站不计失败', () async {
      final body = await _fixture('singbox_137.json');
      final result = parseSingboxJson(body);
      expect(result.nodes.length, 4);
      expect(result.failedCount, 1);

      final vless = result.nodes[0];
      expect(vless.name, '智利-直连');
      expect(vless.protocol, NodeProtocol.vless);
      expect(vless.address, 'cl04.example.com');
      expect(vless.port, 24443);
      expect(vless.source, NodeSource.direct);
      expect(vless.tls, isTrue);
      expect(vless.sni, 'cl04.example.com');
      expect(vless.transport, 'ws');
      expect(vless.wsPath, '/example-path');
      expect(vless.isPlainText, isFalse);

      final trojan = result.nodes[1];
      expect(trojan.name, '香港-中转');
      expect(trojan.protocol, NodeProtocol.trojan);
      expect(trojan.source, NodeSource.relay);
      expect(trojan.tls, isTrue);

      final vmess = result.nodes[2];
      expect(vmess.name, '日本-直连');
      expect(vmess.protocol, NodeProtocol.vmess);
      expect(vmess.tls, isFalse);
      expect(vmess.isPlainText, isTrue);
      expect(vmess.wsPath, '/example-path2');

      final ss = result.nodes[3];
      expect(ss.name, '新加坡-中转');
      expect(ss.protocol, NodeProtocol.shadowsocks);
      expect(ss.source, NodeSource.relay);
      expect(ss.isPlainText, isTrue);
    });

    test('空配置：0 个节点，不算失败', () {
      final result = parseSingboxJson('{"outbounds": []}');
      expect(result.nodes, isEmpty);
      expect(result.failedCount, 0);
    });

    test('没有 outbounds 数组：抛 FormatException（调用方走回退链）', () {
      expect(() => parseSingboxJson('{}'), throwsFormatException);
      expect(() => parseSingboxJson('not json'), throwsFormatException);
    });

    test('dns / route 段不影响解析（只读 outbounds）', () async {
      final body = await _fixture('singbox_137.json');
      final result = parseSingboxJson(body);
      // dns-direct / dns-proxy 是 DNS 服务器，不是节点。
      expect(
        result.nodes.any((n) => n.name.contains('dns')),
        isFalse,
      );
    });
  });

  group('Clash YAML', () {
    test('4 个节点 + 1 个坏节点，proxy-groups/rules/dns 不读', () async {
      final body = await _fixture('clash.yaml');
      final result = parseClashYaml(body);
      expect(result.nodes.length, 4);
      expect(result.failedCount, 1);

      final vless = result.nodes[0];
      expect(vless.name, '智利-直连');
      expect(vless.protocol, NodeProtocol.vless);
      expect(vless.tls, isTrue);
      expect(vless.sni, 'cl04.example.com');
      expect(vless.transport, 'ws');
      expect(vless.wsPath, '/example-path');

      final vmess = result.nodes[2];
      expect(vmess.protocol, NodeProtocol.vmess);
      expect(vmess.tls, isFalse);
      expect(vmess.isPlainText, isTrue);

      // 策略组里的名字不是节点，不重复计入。
      expect(
        result.nodes.where((n) => n.name == '自动选择'),
        isEmpty,
      );
    });

    test('没有 proxies 数组：抛 FormatException', () {
      expect(() => parseClashYaml('port: 7890\n'), throwsFormatException);
    });
  });

  group('base64 / plain 链接列表', () {
    test('base64：5 个节点 + 1 行垃圾，HY2 保留', () async {
      final body = await _fixture('links_base64.txt');
      final result = parseLinkList(body);
      expect(result.nodes.length, 5);
      expect(result.failedCount, 1);
      expect(
        result.nodes.map((n) => n.protocol),
        contains(NodeProtocol.hysteria2),
      );
    });

    test('plain：与 base64 同样的 5 个节点', () async {
      final body = await _fixture('links_plain.txt');
      final result = parseLinkList(body);
      expect(result.nodes.length, 5);
      expect(result.failedCount, 1);

      final vless = result.nodes[0];
      expect(vless.name, '智利-直连');
      expect(vless.tls, isTrue);
      expect(vless.wsPath, '/example-path');

      final vmess = result.nodes[1];
      expect(vmess.name, '日本-直连');
      expect(vmess.address, '203.0.113.12');
      expect(vmess.port, 8080);
      expect(vmess.isPlainText, isTrue);

      final hy2 = result.nodes[4];
      expect(hy2.protocol, NodeProtocol.hysteria2);
      expect(hy2.tls, isTrue);
    });

    test('空行跳过不计失败', () {
      final result = parseLinkList('\n\nvless://11111111-2222-3333-4444-555555555555@203.0.113.10:443#测试-直连\n\n');
      expect(result.nodes.length, 1);
      expect(result.failedCount, 0);
    });
  });

  group('单条链接解析', () {
    test('vless 无 TLS 是明文，sni 为空时取 host', () {
      final node = parseNodeLink(
        'vless://11111111-2222-3333-4444-555555555555@203.0.113.10:8080?type=ws&path=%2Fexample-path&host=ws.example.com#测试-直连',
      );
      expect(node, isNotNull);
      expect(node!.tls, isFalse);
      expect(node.isPlainText, isTrue);
      expect(node.sni, 'ws.example.com');
      expect(node.wsPath, '/example-path');
    });

    test('ss 三种写法都能解', () {
      // base64(method:password)@host:port
      final a = parseNodeLink(
        'ss://YWVzLTI1Ni1nY206ZXhhbXBsZS1zcy1wYXNzd29yZA==@203.0.113.13:8388#新加坡-中转',
      );
      expect(a, isNotNull);
      expect(a!.protocol, NodeProtocol.shadowsocks);
      expect(a.uuidOrPassword, 'example-ss-password');
      // base64(method:password@host:port) 整体
      final b = parseNodeLink(
        'ss://YWVzLTI1Ni1nY206ZXhhbXBsZS1zcy1wYXNzd29yZEAyMDMuMC4xMTMuMTM6ODM4OA==#新加坡-中转',
      );
      expect(b, isNotNull);
      expect(b!.address, '203.0.113.13');
      expect(b.port, 8388);
      // 明文 method:password@host:port
      final c = parseNodeLink(
        'ss://aes-256-gcm:example-ss-password@203.0.113.13:8388#新加坡-中转',
      );
      expect(c, isNotNull);
      expect(c!.address, '203.0.113.13');
    });

    test('垃圾链接返回 null', () {
      expect(parseNodeLink('this-is-not-a-link'), isNull);
      expect(parseNodeLink('vless://@203.0.113.10:443#无UUID-直连'), isNull);
      expect(parseNodeLink('unknown://abc@203.0.113.10:443#测试-直连'), isNull);
    });
  });

  group('切片 10：REALITY / AnyTLS / SOCKS5（对齐契约）', () {
    // 契约样例（~/workspace/slice10-fixtures/contract.md 与 links.txt，
    // 脱敏值，逐字照抄）。
    const realityLink =
        'vless://11111111-2222-3333-4444-555555555555@203.0.113.1:443'
        '?encryption=none&security=reality'
        '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        '&sid=abcdef01&sni=www.microsoft.com&fp=chrome&type=tcp'
        '&flow=xtls-rprx-vision#example-node-reality-443';
    const anytlsLink =
        'anytls://11111111-2222-3333-4444-555555555555@203.0.113.1:443'
        '?sni=example.com#example-node-anytls-443';
    const socks5Link =
        'socks5://user1:pass1234@203.0.113.1:1080#example-node-socks-1080';
    // 契约的 base64 订阅（subscription-base64.txt，逐字照抄）。
    const contractBase64 =
        'dmxlc3M6Ly8xMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTVAMjAzLjAuMTEzLjE6NDQzP2VuY3J5cHRpb249bm9uZSZzZWN1cml0eT1yZWFsaXR5JnBiaz1BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBJnNpZD1hYmNkZWYwMSZzbmk9d3d3Lm1pY3Jvc29mdC5jb20mZnA9Y2hyb21lJnR5cGU9dGNwJmZsb3c9eHRscy1ycHJ4LXZpc2lvbiNleGFtcGxlLW5vZGUtcmVhbGl0eS00NDMKYW55dGxzOi8vMTExMTExMTEtMjIyMi0zMzMzLTQ0NDQtNTU1NTU1NTU1NTU1QDIwMy4wLjExMy4xOjQ0Mz9zbmk9ZXhhbXBsZS5jb20jZXhhbXBsZS1ub2RlLWFueXRscy00NDMKc29ja3M1Oi8vdXNlcjE6cGFzczEyMzRAMjAzLjAuMTEzLjE6MTA4MCNleGFtcGxlLW5vZGUtc29ja3MtMTA4MAo=';

    test('契约 base64 订阅：3 节点 0 失败，REALITY 字段齐全', () {
      final result = parseLinkList(contractBase64);
      expect(result.nodes.length, 3);
      expect(result.failedCount, 0);

      final reality = result.nodes[0];
      expect(reality.name, 'example-node-reality-443');
      expect(reality.protocol, NodeProtocol.vless);
      expect(reality.address, '203.0.113.1');
      expect(reality.port, 443);
      expect(
        reality.uuidOrPassword,
        '11111111-2222-3333-4444-555555555555',
      );
      expect(reality.tls, isTrue);
      expect(reality.isPlainText, isFalse);
      expect(reality.transport, 'tcp');
      expect(
        reality.realityPublicKey,
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );
      expect(reality.realityShortId, 'abcdef01');
      expect(reality.sni, 'www.microsoft.com');
      expect(reality.fingerprint, 'chrome');
      expect(reality.flow, 'xtls-rprx-vision');

      final anytls = result.nodes[1];
      expect(anytls.name, 'example-node-anytls-443');
      expect(anytls.protocol, NodeProtocol.anytls);
      expect(
        anytls.uuidOrPassword,
        '11111111-2222-3333-4444-555555555555',
      );
      expect(anytls.tls, isTrue);
      expect(anytls.sni, 'example.com');

      final socks = result.nodes[2];
      expect(socks.name, 'example-node-socks-1080');
      expect(socks.protocol, NodeProtocol.socks5);
      expect(socks.address, '203.0.113.1');
      expect(socks.port, 1080);
      expect(socks.username, 'user1');
      expect(socks.uuidOrPassword, 'pass1234');
      expect(socks.isPlainText, isTrue);
    });

    test('契约 plain 三行：与 base64 同样的 3 个节点', () {
      final result = parseLinkList(
        '$realityLink\n$anytlsLink\n$socks5Link\n',
      );
      expect(result.nodes.length, 3);
      expect(result.failedCount, 0);
      expect(
        result.nodes.map((n) => n.name),
        [
          'example-node-reality-443',
          'example-node-anytls-443',
          'example-node-socks-1080',
        ],
      );
    });

    test('REALITY 不依赖参数顺序，encryption=none 有无都能解', () {
      final shuffled = parseNodeLink(
        'vless://11111111-2222-3333-4444-555555555555@203.0.113.1:443'
        '?flow=xtls-rprx-vision&fp=chrome&sni=www.microsoft.com'
        '&sid=abcdef01&type=tcp&security=reality'
        '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        '#example-node-reality-443',
      );
      expect(shuffled, isNotNull);
      expect(shuffled!.realityPublicKey,
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
      expect(shuffled.realityShortId, 'abcdef01');
      expect(shuffled.sni, 'www.microsoft.com');
      expect(shuffled.fingerprint, 'chrome');
      expect(shuffled.flow, 'xtls-rprx-vision');
      expect(shuffled.tls, isTrue);
    });

    test('REALITY 缺 pbk：解析失败，不降级成普通 TLS', () {
      expect(
        parseNodeLink(
          'vless://11111111-2222-3333-4444-555555555555@203.0.113.1:443'
          '?security=reality&sid=abcdef01&sni=www.microsoft.com'
          '&fp=chrome&type=tcp&flow=xtls-rprx-vision'
          '#example-node-reality-443',
        ),
        isNull,
      );
    });

    test('SOCKS5 缺用户名或缺密码：解析失败', () {
      expect(
        parseNodeLink(
          'socks5://user1@203.0.113.1:1080#example-node-socks-1080',
        ),
        isNull,
      );
      expect(
        parseNodeLink('socks5://203.0.113.1:1080#example-node-socks-1080'),
        isNull,
      );
    });

    test('sing-box JSON：REALITY / AnyTLS / SOCKS5 三种出站都能解', () {
      final result = parseSingboxJson('''
{
  "outbounds": [
    {"type": "vless", "tag": "example-node-reality-443",
     "server": "203.0.113.1", "server_port": 443,
     "uuid": "11111111-2222-3333-4444-555555555555",
     "flow": "xtls-rprx-vision",
     "tls": {"enabled": true, "server_name": "www.microsoft.com",
             "utls": {"enabled": true, "fingerprint": "chrome"},
             "reality": {"enabled": true,
                         "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                         "short_id": "abcdef01"}}},
    {"type": "anytls", "tag": "example-node-anytls-443",
     "server": "203.0.113.1", "server_port": 443,
     "password": "11111111-2222-3333-4444-555555555555",
     "tls": {"enabled": true, "server_name": "example.com"}},
    {"type": "socks", "tag": "example-node-socks-1080",
     "server": "203.0.113.1", "server_port": 1080, "version": "5",
     "username": "user1", "password": "pass1234"}
  ]
}
''');
      expect(result.nodes.length, 3);
      expect(result.failedCount, 0);
      final reality = result.nodes[0];
      expect(reality.protocol, NodeProtocol.vless);
      expect(reality.realityPublicKey,
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
      expect(reality.realityShortId, 'abcdef01');
      expect(reality.fingerprint, 'chrome');
      expect(reality.flow, 'xtls-rprx-vision');
      expect(reality.sni, 'www.microsoft.com');
      final anytls = result.nodes[1];
      expect(anytls.protocol, NodeProtocol.anytls);
      expect(anytls.tls, isTrue);
      expect(anytls.sni, 'example.com');
      final socks = result.nodes[2];
      expect(socks.protocol, NodeProtocol.socks5);
      expect(socks.username, 'user1');
      expect(socks.uuidOrPassword, 'pass1234');
    });

    test('Clash YAML：REALITY / AnyTLS / SOCKS5 三种 proxy 都能解', () {
      final result = parseClashYaml('''
proxies:
  - name: example-node-reality-443
    type: vless
    server: 203.0.113.1
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    tls: true
    servername: www.microsoft.com
    fingerprint: chrome
    network: tcp
    flow: xtls-rprx-vision
    reality-opts:
      public-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      short-id: abcdef01
  - name: example-node-anytls-443
    type: anytls
    server: 203.0.113.1
    port: 443
    password: 11111111-2222-3333-4444-555555555555
    sni: example.com
  - name: example-node-socks-1080
    type: socks5
    server: 203.0.113.1
    port: 1080
    username: user1
    password: pass1234
''');
      expect(result.nodes.length, 3);
      expect(result.failedCount, 0);
      final reality = result.nodes[0];
      expect(reality.protocol, NodeProtocol.vless);
      expect(reality.realityPublicKey,
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
      expect(reality.realityShortId, 'abcdef01');
      expect(reality.fingerprint, 'chrome');
      expect(reality.flow, 'xtls-rprx-vision');
      final anytls = result.nodes[1];
      expect(anytls.protocol, NodeProtocol.anytls);
      expect(anytls.tls, isTrue);
      expect(anytls.sni, 'example.com');
      final socks = result.nodes[2];
      expect(socks.protocol, NodeProtocol.socks5);
      expect(socks.username, 'user1');
      expect(socks.uuidOrPassword, 'pass1234');
    });
  });

  group('1.4.23：HY2/TUIC 不再被 sing-box/Clash 订阅丢掉', () {
    test('sing-box JSON：HY2 密码＋tls.alpn、TUIC uuid＋password＋congestion_control', () {
      final result = parseSingboxJson('''
{
  "outbounds": [
    {"type": "hysteria2", "tag": "example-node-hy2-443",
     "server": "203.0.113.1", "server_port": 443,
     "password": "11111111-2222-3333-4444-555555555555",
     "tls": {"enabled": true, "server_name": "example.com", "alpn": ["h3"]}},
    {"type": "tuic", "tag": "example-node-tuic-443",
     "server": "203.0.113.1", "server_port": 443,
     "uuid": "11111111-2222-3333-4444-555555555555", "password": "example-password",
     "congestion_control": "bbr",
     "tls": {"enabled": true, "server_name": "example.com", "alpn": ["h3"]}}
  ]
}
''');
      expect(result.nodes.length, 2);
      expect(result.failedCount, 0);
      final hy2 = result.nodes[0];
      expect(hy2.protocol, NodeProtocol.hysteria2);
      expect(hy2.uuidOrPassword, '11111111-2222-3333-4444-555555555555');
      expect(hy2.tls, isTrue);
      expect(hy2.transport, 'udp');
      expect(hy2.sni, 'example.com');
      expect(hy2.alpn, 'h3');
      final tuic = result.nodes[1];
      expect(tuic.protocol, NodeProtocol.tuic);
      expect(
        tuic.uuidOrPassword,
        '11111111-2222-3333-4444-555555555555:example-password',
      );
      expect(tuic.tls, isTrue);
      expect(tuic.transport, 'udp');
      expect(tuic.congestionControl, 'bbr');
      expect(tuic.alpn, 'h3');
    });

    test('sing-box JSON：TUIC 缺 password 丢掉，不生成连不上的出站', () {
      final result = parseSingboxJson('''
{
  "outbounds": [
    {"type": "tuic", "tag": "example-node-tuic-443",
     "server": "203.0.113.1", "server_port": 443,
     "uuid": "11111111-2222-3333-4444-555555555555",
     "tls": {"enabled": true, "server_name": "example.com"}}
  ]
}
''');
      expect(result.nodes, isEmpty);
      expect(result.failedCount, 1);
    });

    test('Clash YAML：HY2 alpn、TUIC congestion-controller 都保留', () {
      final result = parseClashYaml('''
proxies:
  - name: example-node-hy2-443
    type: hysteria2
    server: 203.0.113.1
    port: 443
    password: 11111111-2222-3333-4444-555555555555
    sni: example.com
    alpn: [h3]
  - name: example-node-tuic-443
    type: tuic
    server: 203.0.113.1
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    password: example-password
    congestion-controller: bbr
    sni: example.com
    alpn: [h3]
''');
      expect(result.nodes.length, 2);
      expect(result.failedCount, 0);
      final hy2 = result.nodes[0];
      expect(hy2.protocol, NodeProtocol.hysteria2);
      expect(hy2.uuidOrPassword, '11111111-2222-3333-4444-555555555555');
      expect(hy2.tls, isTrue);
      expect(hy2.alpn, 'h3');
      final tuic = result.nodes[1];
      expect(tuic.protocol, NodeProtocol.tuic);
      expect(
        tuic.uuidOrPassword,
        '11111111-2222-3333-4444-555555555555:example-password',
      );
      expect(tuic.congestionControl, 'bbr');
      expect(tuic.alpn, 'h3');
    });

    test('链接：HY2 alpn=h3、TUIC congestion_control=bbr＋alpn=h3', () {
      final parsed = parseLinkList('''
hysteria2://11111111-2222-3333-4444-555555555555@203.0.113.1:443?sni=example.com&alpn=h3#HY2-直连
tuic://11111111-2222-3333-4444-555555555555:example-password@203.0.113.1:443?sni=example.com&congestion_control=bbr&alpn=h3#TUIC-直连
''');
      expect(parsed.nodes.length, 2);
      expect(parsed.failedCount, 0);
      expect(parsed.nodes[0].alpn, 'h3');
      expect(parsed.nodes[1].congestionControl, 'bbr');
      expect(parsed.nodes[1].alpn, 'h3');
    });
  });

  group('1.4.25 twin：A/B 后缀决定来源', () {
    // 面板 1.4.25 起节点名不再写“-中转”“-直连”，改用 -A（直连）/
    // -B（中转）后缀；解析器只认旧后缀时 A/B 全被默认成直连，
    // 4 个节点全分进直连组。
    const uuid = '11111111-2222-3333-4444-555555555555';
    test('链接：-A 直连、-B 中转（VLESS 与 HY2）', () {
      final realityA = parseNodeLink(
        'vless://$uuid@203.0.113.1:443'
        '?encryption=none&security=reality'
        '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        '&sid=abcdef01&sni=www.microsoft.com&fp=chrome&type=tcp'
        '&flow=xtls-rprx-vision#测试机-reality-443-A',
      );
      expect(realityA, isNotNull);
      expect(realityA!.source, NodeSource.direct);
      final realityB = parseNodeLink(
        'vless://$uuid@cp.jiankong.cf:443'
        '?encryption=none&security=reality'
        '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        '&sid=abcdef01&sni=www.microsoft.com&fp=chrome&type=tcp'
        '&flow=xtls-rprx-vision#测试机-reality-443-B',
      );
      expect(realityB, isNotNull);
      expect(realityB!.source, NodeSource.relay);
      final hy2A = parseNodeLink(
        'hysteria2://$uuid@203.0.113.1:443?sni=example.com&alpn=h3#测试机-hy2-443-A',
      );
      expect(hy2A, isNotNull);
      expect(hy2A!.source, NodeSource.direct);
      final hy2B = parseNodeLink(
        'hysteria2://$uuid@cp.jiankong.cf:443?sni=example.com&alpn=h3#测试机-hy2-443-B',
      );
      expect(hy2B, isNotNull);
      expect(hy2B!.source, NodeSource.relay);
    });

    test('旧后缀 -中转/-直连仍认', () {
      final relay = parseNodeLink(
        'vless://$uuid@203.0.113.1:443#香港-中转',
      );
      expect(relay!.source, NodeSource.relay);
      final direct = parseNodeLink(
        'vless://$uuid@203.0.113.1:443#智利-直连',
      );
      expect(direct!.source, NodeSource.direct);
    });

    test('sing-box JSON：tag 带 -A/-B', () {
      final result = parseSingboxJson('''
{
  "outbounds": [
    {"type": "vless", "tag": "测试机-reality-443-A",
     "server": "203.0.113.1", "server_port": 443, "uuid": "$uuid"},
    {"type": "vless", "tag": "测试机-reality-443-B",
     "server": "cp.jiankong.cf", "server_port": 443, "uuid": "$uuid"}
  ]
}
''');
      expect(result.nodes.length, 2);
      expect(result.nodes[0].source, NodeSource.direct);
      expect(result.nodes[1].source, NodeSource.relay);
    });
  });

  group('格式猜测', () {
    test('JSON → singbox；含 proxies: → clash；其他 → base64', () {
      expect(detectFormat('{"outbounds": []}'), SubscriptionFormat.singbox);
      expect(detectFormat('proxies:\n  - name: x\n'), SubscriptionFormat.clash);
      expect(detectFormat('dmxlc3M6Ly9hYmM='), SubscriptionFormat.base64);
    });
  });
}
