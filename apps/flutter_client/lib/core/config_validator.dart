import 'package:flutter_sing_box/flutter_sing_box.dart';

/// 配置校验器（可注入 fake 做测试）。
abstract class ConfigValidator {
  /// 返回错误列表；空列表即合法。错误文案给诊断与日志用，不直接展示给
  /// 用户（用户侧只显示“配置校验失败，已保留旧配置继续跑”）。
  Future<List<String>> validate(Map<String, dynamic> config);
}

/// 官方 JSON Schema 校验（插件内置 sing-box 1.14 schema，纯离线）＋
/// 结构检查。
///
/// 两层缺一不可：schema 校验按官方字段表逐项核对（类型、枚举、必填）；
/// 结构检查是 builder 回归的快速防线（legacy 写法、tag 重复、
/// default_domain_resolver 缺失这类 schema 可能放过的、但 1.14 运行时
/// 一定会拒绝的问题）。
class SingBoxSchemaConfigValidator implements ConfigValidator {
  SingBoxSchemaConfigValidator({this._assetLoader});

  final Future<String> Function(String)? _assetLoader;

  @override
  Future<List<String>> validate(Map<String, dynamic> config) async {
    final errors = <String>[];
    errors.addAll(structuralErrors(config));
    try {
      final validator = await SingBoxSchemaValidator.instance(
        assetLoader: _assetLoader,
      );
      final schemaErrors = validator.validateSync(config);
      for (final e in schemaErrors) {
        errors.add(e.toErrorString());
        errors.addAll(validator.diagnoseCombinatorError(config, e));
      }
    } catch (e) {
      // schema 加载失败不等于配置非法，但宁可不换配置、不冒险跑坏配置：
      // 记一条错误，让调用方按校验失败处理（保留旧配置）。
      errors.add('schema 校验器加载失败：$e');
    }
    return errors;
  }

  /// 与 schema 无关的结构检查（纯同步，单测可直接调）。
  static List<String> structuralErrors(Map<String, dynamic> config) {
    final errors = <String>[];
    for (final section in ['dns', 'inbounds', 'outbounds', 'route']) {
      if (config[section] == null) errors.add('缺少 $section 段');
    }
    // DNS 段：legacy address 写法在 1.14 下会被核心直接拒绝。
    final dns = config['dns'];
    if (dns is Map<String, dynamic>) {
      final servers = dns['servers'];
      if (servers is List) {
        for (var i = 0; i < servers.length; i++) {
          final server = servers[i];
          if (server is Map<String, dynamic>) {
            if (server.containsKey('address')) {
              errors.add('dns.servers[$i] 仍是 legacy address 写法');
            }
            if (server['type'] == null) {
              errors.add('dns.servers[$i] 缺少 type');
            }
          } else {
            errors.add('dns.servers[$i] 不是对象');
          }
        }
      } else {
        errors.add('dns.servers 不是数组');
      }
      if (dns['strategy'] != 'ipv4_only') {
        errors.add('dns.strategy 不是 ipv4_only');
      }
    }
    final route = config['route'];
    if (route is Map<String, dynamic>) {
      if (route['default_domain_resolver'] == null) {
        errors.add('route 缺少 default_domain_resolver');
      }
    }
    // 出站 tag 必须唯一，否则核心拒绝加载。
    final outbounds = config['outbounds'];
    if (outbounds is List) {
      final tags = <String>{};
      for (final ob in outbounds) {
        if (ob is Map<String, dynamic>) {
          final tag = ob['tag'] as String?;
          if (tag == null || tag.isEmpty) {
            errors.add('有出站缺少 tag');
          } else if (!tags.add(tag)) {
            errors.add('出站 tag 重复：$tag');
          }
        }
      }
    }
    return errors;
  }
}
