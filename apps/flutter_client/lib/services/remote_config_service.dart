import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../brand/brand_config.dart';
import '../brand/remote_config.dart';
import '../brand/remote_config_keys.dart';

/// 远程配置中心（切片 7：三地址链＋Ed25519 验签＋本地缓存）。
///
/// 流程（见 docs/api/remote-config.md 与客户端方案 §6.4）：
/// 启动 → 按地址列表顺序拉（超时 10 秒/个）→ 第一个验签通过且版本
/// 比本地缓存新的就用 → 存本地缓存（最后一份好配置）→ 全部失败用
/// 本地缓存 → 本地也没有缓存（全新安装首次就失败）用包内默认值。
///
/// 地址链（三个不同域名，一个被封试下一个）：
/// 1. 面板 `https://<panel_domain>/client-config.json`（方案 A，须面板
///    新增公开只读接口，待拍板 D10；面板域名取自本地缓存的最后一份
///    好配置，没有时用包内默认值，example.com 占位地址跳过）；
/// 2. Worker 直出 `https://cc.jiankong.cf/client-config.json`（方案 B，
///    须 Worker 加一条路由反代/直出配置）；
/// 3. GitHub Raw（方案 C，配置 JSON 放客户端仓根目录的 client-config.json）。
/// 另有运营方追加的地址（shared_preferences `remote_config_extra_urls`，
/// 排在三地址之后；目前没有在界面里改它的入口，见 remote-config.md）。
///
/// 铁律：
/// - 验签失败的配置一律不用（当作没拉到，继续试下一个地址）；
/// - 只接受比本地缓存新的版本，不回退；
/// - 传输层一律 HTTPS；HTTP 地址直接拒绝（本机回环地址除外，只给
///   本地假服务器测试用，生产地址全是 HTTPS）；
/// - 配置里只有公开信息（品牌、订阅地址模板、面板域名），绝不放订阅令牌。
class RemoteConfigService {
  RemoteConfigService({
    Dio? dio,
    List<String>? configUrls,
    SharedPreferences? prefs,
    String? publicKeyBase64,
  })  : _dio = dio ?? Dio(),
        _configUrlsOverride = configUrls,
        _prefsOverride = prefs,
        _publicKeyBase64 = publicKeyBase64 ?? remoteConfigPublicKeyBase64;

  final Dio _dio;

  /// 测试注入的地址链（为 null 时走默认三地址链）。
  final List<String>? _configUrlsOverride;
  final SharedPreferences? _prefsOverride;

  /// 验签用的公钥（默认编译进客户端的那把；测试可注入临时密钥对的公钥）。
  final String _publicKeyBase64;

  /// 本地缓存（最后一份好配置，整封信封原文，含 signature）。
  static const String cacheKey = 'remote_config_cache';

  /// 运营方追加的配置中心地址（JSON 列表，排在默认三地址之后）。
  static const String extraUrlsKey = 'remote_config_extra_urls';

  /// 单个地址的拉取超时。
  static const Duration fetchTimeout = Duration(seconds: 10);

  /// Worker 直出地址（方案 B；Worker 里须加 /client-config.json 路由）。
  static const String workerConfigUrl =
      'https://cc.jiankong.cf/client-config.json';

  /// GitHub Raw 备用地址（方案 C；文件须由运营方签名后推到仓根目录）。
  static const String rawConfigUrl =
      'https://raw.githubusercontent.com/nbbk/zhexuexi-client/main/client-config.json';

  /// 占位域名（包内默认值的 panel_domain）：这种地址不拉，跳过。
  static bool isPlaceholderDomain(String host) {
    final h = host.toLowerCase();
    return h.isEmpty ||
        h.endsWith('.example.com') ||
        h == 'example.com' ||
        h.endsWith('.example.net') ||
        h == 'example.net' ||
        h.endsWith('.example.org') ||
        h == 'example.org' ||
        h.endsWith('.test') ||
        h == 'localhost';
  }

  /// 该地址能不能拉：只认 HTTPS；HTTP 只放行本机回环（本地测试用）。
  static bool isFetchableUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    if (uri.scheme == 'https') return true;
    if (uri.scheme == 'http') {
      final host = uri.host.toLowerCase();
      return host == '127.0.0.1' || host == '::1' || host == 'localhost';
    }
    return false;
  }

  Future<SharedPreferences> get _prefsInstance async =>
      _prefsOverride ?? await SharedPreferences.getInstance();

  /// 默认三地址链（面板地址由当前缓存/包内默认的 panel_domain 派生）。
  Future<List<String>> defaultConfigUrls() async {
    final urls = <String>[];
    final cached = await loadCached();
    final panelDomain =
        cached?.panelDomain ?? BrandConfig.defaults().panelDomain;
    if (!isPlaceholderDomain(panelDomain)) {
      urls.add('https://$panelDomain/client-config.json');
    }
    urls.add(workerConfigUrl);
    urls.add(rawConfigUrl);
    final prefs = await _prefsInstance;
    final extraRaw = prefs.getString(extraUrlsKey);
    if (extraRaw != null && extraRaw.isNotEmpty) {
      try {
        final extra = jsonDecode(extraRaw);
        if (extra is List) urls.addAll(extra.whereType<String>());
      } catch (_) {
        // 追加地址写坏了不阻断默认链。
      }
    }
    return urls;
  }

  /// 运营方追加的地址写进本地（排在默认三地址之后）。
  Future<void> setExtraUrls(List<String> urls) async {
    final prefs = await _prefsInstance;
    await prefs.setString(extraUrlsKey, jsonEncode(urls));
  }

  /// 拉一次远程配置：按地址链顺序试，第一个验签通过的就返回；
  /// 全部失败或验签都不过返回 null，调用方用本地缓存/包内默认值。
  /// 不做版本比较（版本规则在 [refresh] 里，调用方只想要最新验签
  /// 通过的配置时直接调这里）。
  Future<RemoteConfig?> fetchRemote() async {
    final urls = _configUrlsOverride ?? await defaultConfigUrls();
    for (final url in urls) {
      if (!isFetchableUrl(url)) {
        debugPrint('远程配置地址不拉（非 HTTPS）：$url');
        continue;
      }
      try {
        final response = await _dio.get<String>(
          url,
          options: Options(
            responseType: ResponseType.plain,
            sendTimeout: fetchTimeout,
            receiveTimeout: fetchTimeout,
          ),
        );
        if (response.statusCode != 200 || response.data == null) continue;
        final config = await _parseEnvelope(response.data!);
        if (config != null) return config;
      } catch (e) {
        debugPrint('远程配置拉取失败（$url）：$e');
        continue;
      }
    }
    return null;
  }

  /// 解析一封信封并验签：签不过、缺签名字段、JSON 不合法都返回 null。
  /// `raw` 是整封信封原文（含 `signature` 字段）。
  /// [publicKeyBase64] 为空时用编译进客户端的公钥。
  static Future<RemoteConfig?> parseAndVerifyEnvelope(
    String raw, {
    String? publicKeyBase64,
  }) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return await _parseAndVerify(
        decoded,
        publicKeyBase64: publicKeyBase64 ?? remoteConfigPublicKeyBase64,
      );
    } catch (_) {
      return null;
    }
  }

  Future<RemoteConfig?> _parseEnvelope(String raw) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return await _parseAndVerify(
        decoded,
        publicKeyBase64: _publicKeyBase64,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<RemoteConfig?> _parseAndVerify(
    Map<String, dynamic> envelope, {
    required String publicKeyBase64,
  }) async {
    final signature = envelope['signature'];
    if (signature is! String || signature.isEmpty) return null;
    final payload = Map<String, dynamic>.of(envelope)..remove('signature');
    final ok = await RemoteConfig.verifySignature(
      payload: payload,
      signatureBase64: signature,
      publicKeyBase64: publicKeyBase64,
    );
    if (!ok) return null;
    try {
      return RemoteConfig.fromJson(payload);
    } catch (_) {
      return null;
    }
  }

  /// 读本地缓存的最后一份好配置（重新验签，签不过当作没有缓存）。
  Future<RemoteConfig?> loadCached() async {
    final prefs = await _prefsInstance;
    final raw = prefs.getString(cacheKey);
    if (raw == null || raw.isEmpty) return null;
    final config = await parseAndVerifyEnvelope(
      raw,
      publicKeyBase64: _publicKeyBase64,
    );
    if (config == null) {
      // 缓存被改坏了就清掉，别让一份坏缓存一直占着位置。
      await prefs.remove(cacheKey);
    }
    return config;
  }

  /// 把一封验签通过的信封原文存成本地缓存。
  Future<void> saveCache(String rawEnvelope) async {
    final prefs = await _prefsInstance;
    await prefs.setString(cacheKey, rawEnvelope);
  }

  /// 当前生效的配置：缓存优先（验签通过的最后一份好配置），
  /// 没有缓存时拉一次远程，再没有用包内默认值。
  /// 返回品牌配置（main.dart 启动时用；完整配置走 [refresh]）。
  Future<BrandConfig> loadEffective() async {
    final cached = await loadCached();
    if (cached != null) return cached.brand;
    final result = await refresh();
    return result.config.brand;
  }

  /// 刷新一次远程配置（启动时与设置页“检查更新”共用）。
  ///
  /// - 拉到版本比缓存新的、验签通过的配置 → 存缓存，状态 updated；
  /// - 拉到的都是旧版/同版 → 保持缓存，状态 upToDate；
  /// - 全部地址失败但有缓存 → 用缓存，状态 offlineCached；
  /// - 全部失败且无缓存 → 用包内默认值，状态 failed。
  Future<RemoteConfigRefreshResult> refresh() async {
    final cached = await loadCached();
    final urls = _configUrlsOverride ?? await defaultConfigUrls();
    var sawValid = false;
    for (final url in urls) {
      if (!isFetchableUrl(url)) continue;
      try {
        final response = await _dio.get<String>(
          url,
          options: Options(
            responseType: ResponseType.plain,
            sendTimeout: fetchTimeout,
            receiveTimeout: fetchTimeout,
          ),
        );
        if (response.statusCode != 200 || response.data == null) continue;
        final config = await _parseEnvelope(response.data!);
        if (config == null) continue;
        sawValid = true;
        // 只接受比缓存新的版本，不回退；同版/旧版继续试下一个地址
        // （另一个地址可能有更新的版本）。
        if (cached != null && config.configVersion <= cached.configVersion) {
          continue;
        }
        await saveCache(response.data!);
        return RemoteConfigRefreshResult(
          status: RemoteConfigRefreshStatus.updated,
          config: config,
        );
      } catch (e) {
        debugPrint('远程配置拉取失败（$url）：$e');
        continue;
      }
    }
    if (cached != null) {
      return RemoteConfigRefreshResult(
        status: sawValid
            ? RemoteConfigRefreshStatus.upToDate
            : RemoteConfigRefreshStatus.offlineCached,
        config: cached,
      );
    }
    return RemoteConfigRefreshResult(
      status: RemoteConfigRefreshStatus.failed,
      config: RemoteConfig.defaults(),
    );
  }
}

/// 一次远程配置刷新的结果。
class RemoteConfigRefreshResult {
  const RemoteConfigRefreshResult({
    required this.status,
    required this.config,
  });

  /// 刷新结果（见 [RemoteConfigRefreshStatus]）。
  final RemoteConfigRefreshStatus status;

  /// 刷新后生效的配置（updated/upToDate/offlineCached 时是缓存或新配置，
  /// failed 时是包内默认值）。
  final RemoteConfig config;
}

/// 远程配置刷新的四种结果。
enum RemoteConfigRefreshStatus {
  /// 拉到更新的版本，已应用并存缓存。
  updated,

  /// 拉到的都是旧版/同版，本地缓存已是最新。
  upToDate,

  /// 全部地址失败，正在用本地缓存的最后一份好配置。
  offlineCached,

  /// 全部失败且本地无缓存，用包内默认值。
  failed,
}
