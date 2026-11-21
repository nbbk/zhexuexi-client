import 'dart:convert';

import 'package:flutter/services.dart';

/// 品牌变量（唯一事实来源是远程配置，包内 brand.json 只是默认值兜底）。
///
/// 字段与 DEV-PLAN 附录 A / 客户端方案 §6.2 的远程配置 JSON 对应。
/// 远程配置拉到后以远程为准，拉不到用包内默认值，绝不因拉不到配置就白屏。
class BrandConfig {
  const BrandConfig({
    required this.appName,
    required this.primaryColor,
    required this.accentColor,
    required this.logoUrl,
    required this.supportUrl,
    required this.subscriptionUrl,
    required this.panelDomain,
    required this.minPanelVersion,
  });

  /// 包内默认值（与 assets/brand.json 一致；示例地址一律 example.com）。
  factory BrandConfig.defaults() => const BrandConfig(
        appName: '哲学系',
        primaryColor: 0xFF16324F,
        accentColor: 0xFFE8A317,
        logoUrl: '',
        supportUrl: 'https://example.com/support',
        subscriptionUrl: '',
        panelDomain: 'panel.example.com',
        minPanelVersion: '1.3.29',
      );

  factory BrandConfig.fromJson(Map<String, dynamic> json) {
    final defaults = BrandConfig.defaults();
    final brand = json['brand'] as Map<String, dynamic>? ?? const {};
    final panel = json['panel'] as Map<String, dynamic>? ?? const {};
    return BrandConfig(
      appName: brand['app_name'] as String? ?? defaults.appName,
      primaryColor: _parseColor(
        brand['primary_color'] as String?,
        defaults.primaryColor,
      ),
      accentColor: _parseColor(
        brand['accent_color'] as String?,
        defaults.accentColor,
      ),
      logoUrl: brand['logo_url'] as String? ?? defaults.logoUrl,
      supportUrl: brand['support_url'] as String? ?? defaults.supportUrl,
      subscriptionUrl:
          panel['subscription_url'] as String? ?? defaults.subscriptionUrl,
      panelDomain: panel['panel_domain'] as String? ?? defaults.panelDomain,
      minPanelVersion:
          panel['min_panel_version'] as String? ?? defaults.minPanelVersion,
    );
  }

  static int _parseColor(String? hex, int fallback) {
    if (hex == null) return fallback;
    final cleaned = hex.replaceFirst('#', '');
    if (cleaned.length != 6) return fallback;
    final value = int.tryParse(cleaned, radix: 16);
    if (value == null) return fallback;
    return 0xFF000000 | value;
  }

  /// 显示名（重启即生效的品牌变量之一）。
  final String appName;

  /// 主色（深海蓝）。
  final int primaryColor;

  /// 强调色（琥珀金，只用在开关、当前节点、主要按钮）。
  final int accentColor;

  /// 远程 Logo 地址（空表示用包内 Logo）。
  final String logoUrl;

  /// 客服 / 帮助链接。
  final String supportUrl;

  /// 当前订阅地址（令牌不放这里，令牌在安全存储里）。
  final String subscriptionUrl;

  /// 面板域名（不带协议与端口）。
  final String panelDomain;

  /// 面板版本门：低于此版本的面板，启动时提示升级（阶段 1 实现检查）。
  final String minPanelVersion;

  Map<String, dynamic> toJson() => {
        'brand': {
          'app_name': appName,
          'primary_color':
              '#${primaryColor.toRadixString(16).substring(2).toUpperCase()}',
          'accent_color':
              '#${accentColor.toRadixString(16).substring(2).toUpperCase()}',
          'logo_url': logoUrl,
          'support_url': supportUrl,
        },
        'panel': {
          'subscription_url': subscriptionUrl,
          'panel_domain': panelDomain,
          'min_panel_version': minPanelVersion,
        },
      };

  /// 读包内默认 brand.json（阶段 0 占位；阶段 1 由远程配置覆盖）。
  static Future<BrandConfig> loadBundled() async {
    try {
      final raw = await rootBundle.loadString('assets/brand.json');
      return BrandConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      // 包内文件读不到也不崩：用代码里的默认值。
      return BrandConfig.defaults();
    }
  }
}
