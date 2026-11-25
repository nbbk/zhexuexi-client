// 粘贴/扫码内容分流（第 6、7 项共用）：按内容是订阅还是单条节点链接
// 自动区分。纯分类，不碰存储、不拉网络。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/services/content_intake.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';

const _vlessRealityLink =
    'vless://$_uuid@203.0.113.1:443'
    '?encryption=none&security=reality'
    '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    '&sid=abcdef01&sni=www.microsoft.com&fp=chrome&type=tcp'
    '&flow=xtls-rprx-vision#测试机-reality-443-A';

const _hy2Link =
    'hysteria2://$_uuid@203.0.113.1:443'
    '?sni=hy2test.example.com&alpn=h3#测试机-hy2-443-A';

void main() {
  group('classifyContent：单条节点链接 → singleNode', () {
    test('VLESS（面板 reality 单条链接格式，-A 后缀）', () {
      expect(classifyContent(_vlessRealityLink), ScannedContentKind.singleNode);
    });

    test('HY2（面板单条链接格式，-A 后缀）', () {
      expect(classifyContent(_hy2Link), ScannedContentKind.singleNode);
    });

    test('Trojan / SS / TUIC / AnyTLS / SOCKS5', () {
      expect(
        classifyContent(
          'trojan://example-password@203.0.113.1:443?sni=example.com#测试-直连',
        ),
        ScannedContentKind.singleNode,
      );
      expect(
        classifyContent(
          'ss://YWVzLTI1Ni1nY206ZXhhbXBsZS1zcy1wYXNzd29yZA==@203.0.113.13:8388#新加坡-中转',
        ),
        ScannedContentKind.singleNode,
      );
      expect(
        classifyContent(
          'tuic://$_uuid:example-password@203.0.113.1:443?sni=example.com&congestion_control=bbr&alpn=h3#TUIC-直连',
        ),
        ScannedContentKind.singleNode,
      );
      expect(
        classifyContent(
          'anytls://$_uuid@203.0.113.1:443?sni=example.com#example-node-anytls-443',
        ),
        ScannedContentKind.singleNode,
      );
      expect(
        classifyContent(
          'socks5://user1:pass1234@203.0.113.1:1080#example-node-socks-1080',
        ),
        ScannedContentKind.singleNode,
      );
    });

    test('VMess（base64 JSON）', () {
      final payload = base64Encode(
        utf8.encode(
          '{"ps":"测试-直连","add":"203.0.113.12","port":8080,"id":"$_uuid"}',
        ),
      );
      expect(
        classifyContent('vmess://$payload'),
        ScannedContentKind.singleNode,
      );
    });

    test('单条链接带首尾空白与换行也认', () {
      expect(
        classifyContent('  $_hy2Link\n'),
        ScannedContentKind.singleNode,
      );
    });
  });

  group('classifyContent：订阅链接', () {
    test('自家面板链接（sub_ 令牌结尾）→ primarySubscriptionUrl', () {
      const link =
          'https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      expect(
        classifyContent(link),
        ScannedContentKind.primarySubscriptionUrl,
      );
      expect(isPrimarySubscriptionLink(link), isTrue);
    });

    test('机场订阅链接 → subscriptionUrl', () {
      expect(
        classifyContent('https://airport.example.com/sub/abcdef123456'),
        ScannedContentKind.subscriptionUrl,
      );
      expect(
        isPrimarySubscriptionLink(
          'https://airport.example.com/sub/abcdef123456',
        ),
        isFalse,
      );
    });
  });

  group('classifyContent：订阅正文 → subscriptionBody', () {
    test('sing-box JSON 正文', () {
      expect(
        classifyContent('''
{
  "outbounds": [
    {"type": "vless", "tag": "example-node-reality-443",
     "server": "203.0.113.1", "server_port": 443,
     "uuid": "$_uuid"}
  ]
}
'''),
        ScannedContentKind.subscriptionBody,
      );
    });

    test('Clash YAML 正文', () {
      expect(
        classifyContent('''
proxies:
  - name: example-node-reality-443
    type: vless
    server: 203.0.113.1
    port: 443
    uuid: $_uuid
'''),
        ScannedContentKind.subscriptionBody,
      );
    });

    test('链接列表正文（多行）与 base64 订阅', () {
      expect(
        classifyContent('$_vlessRealityLink\n$_hy2Link\n'),
        ScannedContentKind.subscriptionBody,
      );
      final base64Body = base64Encode(
        utf8.encode('$_vlessRealityLink\n$_hy2Link\n'),
      );
      expect(
        classifyContent(base64Body),
        ScannedContentKind.subscriptionBody,
      );
    });
  });

  group('classifyContent：无法识别 → unknown', () {
    test('垃圾、空串、只有网址域名', () {
      expect(classifyContent('this-is-not-a-link'), ScannedContentKind.unknown);
      expect(classifyContent(''), ScannedContentKind.unknown);
      expect(classifyContent('   '), ScannedContentKind.unknown);
      expect(classifyContent('example.com'), ScannedContentKind.unknown);
      expect(
        classifyContent('{"outbounds": []}'),
        ScannedContentKind.unknown,
      );
    });
  });
}
