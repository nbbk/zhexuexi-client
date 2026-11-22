// 切片 2：配置校验器的回归测试。
//
// 结构检查是纯同步的，直接测；schema 校验走插件内置的官方 sing-box 1.14
// schema（纯离线，asset 由插件自带），用生成器产出的真实配置回归。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/core/config_validator.dart';
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
