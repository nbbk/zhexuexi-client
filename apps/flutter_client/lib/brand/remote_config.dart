import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'brand_config.dart';
import 'remote_config_keys.dart';

/// 客户端版本号（与 pubspec.yaml 的 version 同步）。
/// 远程配置的 `min_app_version` 低于它时，`forceUpdateRequired` 为真。
const String appVersion = '0.1.8';

/// 远程配置（切片 7：远程配置中心＋品牌远程替换）。
///
/// 信封格式见 docs/api/remote-config.md 与 DEV-PLAN 附录 B：
/// 顶层 JSON 含 `config_version` / `brand` / `panel` / `announcement` /
/// `features` 等字段，外加 `signature`（Ed25519，base64）。
/// 签名是对除 `signature` 外的全部内容做规范 JSON（key 排序、无空格）
/// 后的字节；验签失败的配置一律不用。
class RemoteConfig {
  const RemoteConfig({
    required this.configVersion,
    this.updatedAt,
    required this.minAppVersion,
    required this.forceUpdate,
    this.forceUpdateMessage,
    this.downloadUrl = '',
    required this.brand,
    required this.panelDomain,
    required this.panelApiBase,
    required this.minPanelVersion,
    required this.subscriptionUrl,
    required this.subscriptionBackupUrls,
    required this.subscriptionFormat,
    this.announcement,
    required this.features,
    this.updateServerBaseUrl = '',
    this.updateVersionPath = '',
  });

  /// 包内默认值（全新安装、本地无缓存、远程也拉不到时用）：
  /// 版本 0，品牌走包内 brand.json，订阅地址为空。
  factory RemoteConfig.defaults() => RemoteConfig(
        configVersion: 0,
        minAppVersion: '0.1.0',
        forceUpdate: false,
        brand: BrandConfig.defaults(),
        panelDomain: BrandConfig.defaults().panelDomain,
        panelApiBase: '',
        minPanelVersion: BrandConfig.defaults().minPanelVersion,
        subscriptionUrl: '',
        subscriptionBackupUrls: const [],
        subscriptionFormat: 'singbox',
        features: const RemoteConfigFeatures(),
      );

  /// 从签过名的信封顶层 JSON 解析（不含验签；验签由调用方先做）。
  factory RemoteConfig.fromJson(Map<String, dynamic> json) {
    final brand = BrandConfig.fromJson(json);
    final panel = json['panel'] as Map<String, dynamic>? ?? const {};
    final announcementJson =
        json['announcement'] as Map<String, dynamic>?;
    final featuresJson = json['features'] as Map<String, dynamic>?;
    final backupUrls = panel['subscription_backup_urls'];
    final update = json['update'] as Map<String, dynamic>? ?? const {};
    return RemoteConfig(
      configVersion: json['config_version'] as int? ?? 0,
      updatedAt: json['updated_at'] as String?,
      minAppVersion: json['min_app_version'] as String? ?? '0.1.0',
      forceUpdate: json['force_update'] as bool? ?? false,
      forceUpdateMessage: json['force_update_message'] as String?,
      downloadUrl: json['download_url'] as String? ?? '',
      brand: brand,
      panelDomain: panel['panel_domain'] as String? ?? brand.panelDomain,
      panelApiBase: panel['panel_api_base'] as String? ?? '',
      minPanelVersion:
          panel['min_panel_version'] as String? ?? brand.minPanelVersion,
      subscriptionUrl:
          panel['subscription_url'] as String? ?? brand.subscriptionUrl,
      subscriptionBackupUrls: backupUrls is List
          ? backupUrls.whereType<String>().toList()
          : const [],
      subscriptionFormat:
          panel['subscription_format'] as String? ?? 'singbox',
      announcement: announcementJson == null
          ? null
          : RemoteConfigAnnouncement.fromJson(announcementJson),
      features: featuresJson == null
          ? const RemoteConfigFeatures()
          : RemoteConfigFeatures.fromJson(featuresJson),
      updateServerBaseUrl: update['server_base_url'] as String? ?? '',
      updateVersionPath: update['version_path'] as String? ?? '',
    );
  }

  /// 配置版本号，单调递增；客户端只接受比本地缓存新的版本，不回退。
  final int configVersion;

  /// 配置更新时间（ISO 8601，仅展示用，不参与验签之外的逻辑）。
  final String? updatedAt;

  /// 最低可用客户端版本；低于它时首页弹升级提示。
  final String minAppVersion;

  /// 是否强制更新（只用于旧版解析不了新订阅格式这种真断裂场景）。
  final bool forceUpdate;

  /// 强制更新时给用户看的说明。
  final String? forceUpdateMessage;

  /// 强制更新时给用户看的下载地址（切片 8 接入）：
  /// 官网下载页地址；配置里没给时为空，升级弹窗只说明原因、
  /// 不写地址。下载页本身由发布流程维护（见 docs/release-checklist.md）。
  final String downloadUrl;

  /// 品牌变量（应用名、Logo、主色、强调色、客服链接、订阅地址）。
  final BrandConfig brand;

  /// 面板域名（不带协议与端口）。
  final String panelDomain;

  /// 面板接口地址（为空时由 panelDomain 派生 `https://<域名>`）。
  final String panelApiBase;

  /// 面板版本门。
  final String minPanelVersion;

  /// 当前订阅地址（完整链接模板，不含用户令牌；令牌在用户本机）。
  final String subscriptionUrl;

  /// 备用订阅地址（旧地址 404 时按顺序试，令牌不变、只换地址）。
  final List<String> subscriptionBackupUrls;

  /// 订阅格式（目前只认 singbox，见 panel-adapter.md）。
  final String subscriptionFormat;

  /// 远程公告（带唯一 id，去重用；没有时用面板 public-info 的公告）。
  final RemoteConfigAnnouncement? announcement;

  /// 功能开关（可远程关掉出问题的功能，不用发版）。
  final RemoteConfigFeatures features;

  /// 自托管更新通道的两个配置位（应用内更新，双通道设计）：
  /// - [updateServerBaseUrl]：自托管更新服务器基地址，
  ///   如 `https://update.example.com`；为空表示没配。
  /// - [updateVersionPath]：版本描述接口路径，
  ///   如 `/api/v1/client/version`。
  /// 本轮只加字段与读法、不接线：自托管通道未启用（见
  /// `SelfHostedUpdateSource`），以后服务端就绪后再接线。
  final String updateServerBaseUrl;
  final String updateVersionPath;

  /// 面板接口地址：填了就用，没填由面板域名派生。
  String get panelApiBaseOrDerived =>
      panelApiBase.isNotEmpty ? panelApiBase : 'https://$panelDomain';

  /// 是否到了强制更新的地步：配置要求强制更新，且当前版本低于最低版本。
  bool get forceUpdateRequired =>
      forceUpdate && compareVersions(appVersion, minAppVersion) < 0;

  /// 除 `signature` 外的全部内容（签名对象就是它）。
  Map<String, dynamic> toJson() => {
        'config_version': configVersion,
        if (updatedAt != null) 'updated_at': updatedAt,
        'min_app_version': minAppVersion,
        'force_update': forceUpdate,
        if (forceUpdateMessage != null)
          'force_update_message': forceUpdateMessage,
        if (downloadUrl.isNotEmpty) 'download_url': downloadUrl,
        'brand': {
          'app_name': brand.appName,
          'logo_url': brand.logoUrl,
          'primary_color':
              '#${brand.primaryColor.toRadixString(16).substring(2).toUpperCase()}',
          'accent_color':
              '#${brand.accentColor.toRadixString(16).substring(2).toUpperCase()}',
          'support_url': brand.supportUrl,
        },
        'panel': {
          'panel_domain': panelDomain,
          if (panelApiBase.isNotEmpty) 'panel_api_base': panelApiBase,
          'min_panel_version': minPanelVersion,
          'subscription_url': subscriptionUrl,
          if (subscriptionBackupUrls.isNotEmpty)
            'subscription_backup_urls': subscriptionBackupUrls,
          'subscription_format': subscriptionFormat,
        },
        if (announcement != null) 'announcement': announcement!.toJson(),
        'features': features.toJson(),
        if (updateServerBaseUrl.isNotEmpty || updateVersionPath.isNotEmpty)
          'update': {
            'server_base_url': updateServerBaseUrl,
            'version_path': updateVersionPath,
          },
      };

  /// 验签：`signatureBase64` 是信封里的 `signature` 字段，
  /// `payload` 是除 `signature` 外的全部内容（验签前不做任何改动，
  /// 直接规范化后签名原文）。
  /// 公钥默认用编译进客户端的那把；传 `publicKeyBase64` 可换钥（测试用）。
  static Future<bool> verifySignature({
    required Map<String, dynamic> payload,
    required String signatureBase64,
    String publicKeyBase64 = remoteConfigPublicKeyBase64,
  }) async {
    late final List<int> signature;
    late final List<int> publicKeyBytes;
    try {
      signature = base64Decode(signatureBase64);
      publicKeyBytes = base64Decode(publicKeyBase64);
    } catch (_) {
      return false;
    }
    if (signature.length != 64 || publicKeyBytes.length != 32) {
      return false;
    }
    try {
      final publicKey = SimplePublicKey(
        publicKeyBytes,
        type: KeyPairType.ed25519,
      );
      return await Ed25519().verify(
        utf8.encode(canonicalJson(payload)),
        signature: Signature(signature, publicKey: publicKey),
      );
    } catch (_) {
      return false;
    }
  }
}

/// 远程公告（id 去重用；新 id 才弹，旧 id 不重复弹）。
class RemoteConfigAnnouncement {
  const RemoteConfigAnnouncement({
    required this.id,
    required this.title,
    required this.body,
    this.url,
  });

  factory RemoteConfigAnnouncement.fromJson(Map<String, dynamic> json) {
    return RemoteConfigAnnouncement(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      url: json['url'] as String?,
    );
  }

  final String id;
  final String title;
  final String body;
  final String? url;

  /// 我的页公告卡显示的文本（标题＋正文；标题为空时只显示正文）。
  String get displayText =>
      title.isEmpty ? body : '$title\n$body';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        if (url != null) 'url': url,
      };
}

/// 远程功能开关（默认全开；关掉某项只是远程降级，不改本地偏好）。
class RemoteConfigFeatures {
  const RemoteConfigFeatures({
    this.autoSelect = true,
    this.tunDefault = false,
    this.showTraffic = true,
  });

  factory RemoteConfigFeatures.fromJson(Map<String, dynamic> json) {
    return RemoteConfigFeatures(
      autoSelect: json['auto_select'] as bool? ?? true,
      tunDefault: json['tun_default'] as bool? ?? false,
      showTraffic: json['show_traffic'] as bool? ?? true,
    );
  }

  /// 自动选节点开关是否可用（关掉时节点页不自动选，只手动选）。
  final bool autoSelect;

  /// TUN 默认是否开启（只影响全新安装的默认值，不改用户已选的偏好）。
  final bool tunDefault;

  /// 是否显示流量（三格与我的页订阅卡片）。
  final bool showTraffic;

  Map<String, dynamic> toJson() => {
        'auto_select': autoSelect,
        'tun_default': tunDefault,
        'show_traffic': showTraffic,
      };
}

/// 规范 JSON：key 按字典序递归排序、无空格、无换行。
/// 与 tools/remote-config/sign.py 的 `json.dumps(sort_keys=True,
/// separators=(',', ':'))` 逐字节一致（key 只含 ASCII 时）；
/// 签名方与验签方必须用同一份原文，否则签名对不上。
String canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    final parts = <String>[];
    for (final key in keys) {
      parts.add('${jsonEncode(key)}:${canonicalJson(value[key])}');
    }
    return '{${parts.join(',')}}';
  }
  if (value is List) {
    return '[${value.map(canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

/// 比较 `x.y.z` 形式的版本号：a < b 返回负数，相等返回 0，a > b 返回正数。
/// 段数不足补 0；非数字段按 0 算，不抛错。
int compareVersions(String a, String b) {
  final aParts = a.split('.');
  final bParts = b.split('.');
  final len = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < len; i++) {
    final av = i < aParts.length ? int.tryParse(aParts[i]) ?? 0 : 0;
    final bv = i < bParts.length ? int.tryParse(bParts[i]) ?? 0 : 0;
    if (av != bv) return av.compareTo(bv);
  }
  return 0;
}
