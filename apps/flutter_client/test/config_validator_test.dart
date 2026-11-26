// 切片 2：配置校验器的回归测试。
//
// 结构检查是纯同步的，直接测；schema 校验走插件内置的官方 sing-box 1.14
// schema（纯离线，asset 由插件自带），用生成器产出的真实配置回归。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/core/config_validator.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/singbox_config.dart';
import 'package:zhexuexi_client/services/subscription_parser.dart';

Future<String> _fixture(String name) =>
    File('test/fixtures/$name').readAsString();

void main() {
  // schema 校验经 rootBundle 读插件 asset，测试里先初始化绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('结构检查（纯同步）', () {
    test('生成器产出的配置零错误', () async {
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final config = SingboxConfigBuilder.build(nodes).config;
      expect(SingBoxSchemaConfigValidator.structuralErrors(config), isEmpty);
    });

    test('legacy address 写法、缺 default_domain_resolver、tag 重复都报出来', () {
      final legacy = {
        'dns': {
          'servers': [
            {'tag': 'dns-direct', 'address': 'https://doh.pub/dns-query'},
          ],
          'strategy': 'ipv4_only',
        },
        'inbounds': [
          {'type': 'mixed', 'tag': 'mixed-in'},
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {'final': 'direct'},
      };
      final errors = SingBoxSchemaConfigValidator.structuralErrors(legacy);
      expect(errors.any((e) => e.contains('legacy address')), isTrue);
      expect(
        errors.any((e) => e.contains('default_domain_resolver')),
        isTrue,
      );
      expect(errors.any((e) => e.contains('tag 重复')), isTrue);
    });

    test('带 detour 的 DNS 服务器用域名：报出来（2026-11-26 根因）', () {
      // dns.google 经 Proxy 的引导解析依赖直连 1.1.1.1，国内一死
      // 就全死；带 detour 的 DNS 服务器必须写 IP。
      final errors = SingBoxSchemaConfigValidator.structuralErrors({
        'dns': {
          'servers': [
            {
              'tag': 'dns-proxy',
              'type': 'https',
              'server': 'dns.google',
              'server_port': 443,
              'path': '/dns-query',
              'detour': 'Proxy',
            },
          ],
          'strategy': 'ipv4_only',
        },
        'inbounds': [
          {'type': 'mixed', 'tag': 'mixed-in'},
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'final': 'direct',
          'default_domain_resolver': 'dns-direct',
        },
      });
      expect(errors.any((e) => e.contains('须写 IP')), isTrue);
    });

    test('缺段与 strategy 不对都报出来', () {
      final errors = SingBoxSchemaConfigValidator.structuralErrors({
        'dns': {'servers': [], 'strategy': 'prefer_ipv4'},
      });
      expect(errors.any((e) => e.contains('缺少 inbounds 段')), isTrue);
      expect(errors.any((e) => e.contains('缺少 outbounds 段')), isTrue);
      expect(errors.any((e) => e.contains('缺少 route 段')), isTrue);
      expect(errors.any((e) => e.contains('ipv4_only')), isTrue);
    });
  });

  group('官方 schema 校验（插件内置，纯离线）', () {
    test('生成器产出的配置通过 schema', () async {
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final config = SingboxConfigBuilder.build(nodes).config;
      final validator = SingBoxSchemaConfigValidator();
      final errors = await validator.validate(config);
      expect(errors, isEmpty);
    });

    test('空节点配置也通过 schema', () async {
      final config = SingboxConfigBuilder.build([]).config;
      final validator = SingBoxSchemaConfigValidator();
      expect(await validator.validate(config), isEmpty);
    });

    test('TUN 开着的配置通过 schema（2026-11-26 根因回归）', () async {
      // TUN 默认开之后每份配置都带 tun 入站；上一轮写的
      // `"stack": "gvisor"` 被插件内置 schema 以
      // "Additional property stack is not allowed" 拒绝，
      // applyNodes 每次都 ok:false、开关与模式切换一起卡死。
      // 修后不写 stack，TUN 开着的配置必须 0 报错。
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final validator = SingBoxSchemaConfigValidator();
      final config = SingboxConfigBuilder.build(
        nodes,
        tunEnabled: true,
      ).config;
      expect(await validator.validate(config), isEmpty);
      // 用户真机节点形状：VLESS REALITY + SS + HY2，TUN 开着同样过。
      final handBuilt = SingboxConfigBuilder.build(
        [
          Node(
            name: '测试-REALITY',
            protocol: NodeProtocol.vless,
            address: '203.0.113.1',
            port: 443,
            source: NodeSource.direct,
            uuidOrPassword: '11111111-2222-3333-4444-555555555555',
            transport: 'tcp',
            tls: true,
            sni: 'www.microsoft.com',
            realityPublicKey:
                'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
            realityShortId: 'abcd1234',
            flow: 'xtls-rprx-vision',
          ),
          Node(
            name: '测试-SS',
            protocol: NodeProtocol.shadowsocks,
            address: '203.0.113.2',
            port: 8388,
            source: NodeSource.direct,
            uuidOrPassword: 'password123',
            method: 'aes-256-gcm',
          ),
          Node(
            name: '测试-HY2',
            protocol: NodeProtocol.hysteria2,
            address: '203.0.113.3',
            port: 443,
            source: NodeSource.direct,
            uuidOrPassword: 'password123',
            tls: true,
            sni: 'hy2.example.com',
            alpn: 'h3',
          ),
        ],
        tunEnabled: true,
      ).config;
      expect(await validator.validate(handBuilt), isEmpty);
    });

    test('非法 type 的出站通不过 schema', () async {
      final body = await _fixture('singbox_137.json');
      final nodes = parseSingboxJson(body).nodes;
      final config = SingboxConfigBuilder.build(nodes).config;
      (config['outbounds'] as List).add({
        'type': 'not-a-real-outbound',
        'tag': '坏出站',
      });
      final validator = SingBoxSchemaConfigValidator();
      final errors = await validator.validate(config);
      expect(errors, isNotEmpty);
    });
  });
}
