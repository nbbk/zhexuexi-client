import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/userinfo.dart';

/// 订阅拉取服务（阶段 0 占位实现）。
///
/// 约定（见 docs/api/panel-adapter.md）：
/// - 每次拉订阅必须显式带 `?format=singbox`（UA 不含任何嗅探命中子串时，
///   不带 format 会拿到默认 base64）；
/// - UA 用 `Zhexuexi/0.1.0`（不含 clash/stash/mihomo/sing-box/sfa/sfi/sfm）；
/// - 令牌只存系统密钥库（flutter_secure_storage），绝不写明文文件、不进日志；
/// - `subscription-userinfo` 头是中转口径，直连流量不在头里。
/// 节点解析（sing-box JSON / Clash YAML / base64）在阶段 1 按格式逐个实现。
class SubscriptionService {
  SubscriptionService({Dio? dio, FlutterSecureStorage? storage})
      : _dio = dio ?? Dio(),
        _storage = storage ?? const FlutterSecureStorage();

  final Dio _dio;
  final FlutterSecureStorage _storage;

  static const String _tokenKey = 'subscription_token';

  /// 当前 UA（版本号随发布走，阶段 1 与 pubspec version 同步）。
  static const String userAgent = 'Zhexuexi/0.1.0';

  /// 保存订阅令牌（只进系统密钥库）。
  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  /// 读订阅令牌；未绑定返回 null。
  Future<String?> readToken() => _storage.read(key: _tokenKey);

  /// 清除订阅令牌（换绑 / 退出登录时调用）。
  Future<void> clearToken() => _storage.delete(key: _tokenKey);

  /// 拉一次订阅。
  ///
  /// [subscriptionUrl] 是面板给的完整订阅地址（不含令牌，令牌拼在路径里，
  /// 形如 `https://example.com/x9f2/sub_xxx`）。
  /// 返回原始订阅正文与 userinfo 头；正文解析在阶段 1 做。
  Future<SubscriptionFetchResult> fetch(String subscriptionUrl) async {
    final uri = Uri.parse(subscriptionUrl).replace(
      queryParameters: {
        ...Uri.parse(subscriptionUrl).queryParameters,
        'format': 'singbox',
      },
    );
    final response = await _dio.get<String>(
      uri.toString(),
      options: Options(
        responseType: ResponseType.plain,
        headers: {'User-Agent': userAgent},
        // 订阅拉取超时 15 秒，失败由调用方提示“网络不通，检查订阅地址”。
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    return SubscriptionFetchResult(
      body: response.data ?? '',
      userinfo: SubscriptionUserinfo.parse(
        response.headers.value('subscription-userinfo'),
      ),
      statusCode: response.statusCode ?? 0,
    );
  }
}

/// 一次订阅拉取的结果。
class SubscriptionFetchResult {
  const SubscriptionFetchResult({
    required this.body,
    required this.userinfo,
    required this.statusCode,
  });

  /// 订阅正文（sing-box JSON，阶段 1 再解析成节点列表）。
  final String body;

  /// 流量与到期（中转口径）。
  final SubscriptionUserinfo userinfo;

  final int statusCode;
}
