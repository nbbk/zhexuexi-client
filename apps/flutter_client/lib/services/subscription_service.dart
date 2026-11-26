import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/node_model.dart';
import '../core/userinfo.dart';
import 'subscription_parser.dart';

/// 订阅拉取服务（切片 1：拉取＋三种格式解析＋回退链）。
///
/// 约定（见 docs/api/panel-adapter.md）：
/// - 每次拉订阅必须显式带 `?format=singbox`（UA 不含任何嗅探命中子串时，
///   不带 format 会拿到默认 base64）；
/// - UA 用 `Zhexuexi/0.1.0`（不含 clash/stash/mihomo/sing-box/sfa/sfi/sfm）；
/// - 令牌只存系统密钥库（flutter_secure_storage），绝不写明文文件、不进日志；
/// - 订阅地址（不含令牌）存 shared_preferences，令牌与地址分开存；
/// - `subscription-userinfo` 头是中转口径，直连流量不在头里。
/// - 拉取失败回退链：singbox → base64 → clash；但 404/410/429/400 是
///   令牌或地址问题，不回退，直接报给用户。
class SubscriptionService {
  SubscriptionService({Dio? dio, FlutterSecureStorage? storage})
      : _dio = dio ?? Dio(),
        _storage = storage ?? const FlutterSecureStorage();

  final Dio _dio;
  final FlutterSecureStorage _storage;

  static const String _tokenKey = 'subscription_token';

  /// 订阅地址（不含令牌，例如 `https://example.com/x9f2`）。
  static const String _baseUrlKey = 'subscription_base_url';

  /// 当前 UA（版本号随发布走，阶段 1 与 pubspec version 同步）。
  static const String userAgent = 'Zhexuexi/0.1.0';

  /// 保存订阅令牌（只进系统密钥库）。
  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  /// 读订阅令牌；未绑定返回 null。
  Future<String?> readToken() => _storage.read(key: _tokenKey);

  /// 清除订阅令牌（换绑 / 退出登录时调用）。
  Future<void> clearToken() => _storage.delete(key: _tokenKey);

  /// 保存一条完整订阅链接：拆成地址（不含令牌，进 shared_preferences）
  /// 与令牌（进系统密钥库）。令牌是路径最后一段，形如 `sub_` + 64 位十六进制。
  Future<void> saveSubscriptionLink(String link) async {
    final uri = Uri.parse(link.trim());
    final segments = uri.pathSegments;
    if (segments.isEmpty) {
      throw const SubscriptionException(
        kind: SubscriptionErrorKind.invalid,
        message: '订阅链接不对，找不到令牌',
      );
    }
    final token = segments.last;
    if (!token.startsWith('sub_')) {
      throw const SubscriptionException(
        kind: SubscriptionErrorKind.invalid,
        message: '订阅链接不对，令牌应以 sub_ 开头',
      );
    }
    final base = uri.replace(pathSegments: segments.sublist(0, segments.length - 1)).toString();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, base);
    await saveToken(token);
  }

  /// 读已绑定的完整订阅地址（地址 + 令牌拼回）；未绑定返回 null。
  /// 先判地址再读令牌：未绑定时不碰安全存储通道。
  Future<String?> readSubscriptionUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final base = prefs.getString(_baseUrlKey);
    if (base == null || base.isEmpty) return null;
    final token = await readToken();
    if (token == null || token.isEmpty) return null;
    return '$base/$token';
  }

  /// 读订阅地址的 origin（如 `https://example.com`，不含路径与令牌）；
  /// 未绑定返回 null。公告（`GET /api/v1/public-info`）走这个 origin，
  /// 令牌绝不拼进公告请求里。
  Future<String?> readPanelOrigin() async {
    final prefs = await SharedPreferences.getInstance();
    final base = prefs.getString(_baseUrlKey);
    if (base == null || base.isEmpty) return null;
    final uri = Uri.tryParse(base);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return uri.origin;
  }

  /// 是否已绑定订阅（地址与令牌都在）。
  Future<bool> hasBinding() async => await readSubscriptionUrl() != null;

  /// 清除绑定（地址与令牌一起清）。
  Future<void> clearBinding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_baseUrlKey);
    await clearToken();
  }

  /// 只换订阅地址的 base（不含令牌），令牌不动。
  /// 远程配置换地址时用（切片 7）：令牌存在面板里，跟订阅路径走，
  /// 只换地址、不换令牌，用户无感知。
  Future<void> updateBaseUrl(String base) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, base.replaceAll(RegExp(r'/+$'), ''));
  }

  /// 取一条订阅地址的 base（去掉令牌那一段）。
  /// 完整订阅链接的最后一段是令牌（`sub_` 开头），去掉它；
  /// 不是完整链接（最后一段不是令牌）时原样当 base 用。
  /// 远程配置里的备用地址可能是不带令牌的 base，也可能带了占位令牌，
  /// 两种都认。
  static String baseOf(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    final segments = uri.pathSegments;
    if (segments.isEmpty) return uri.origin;
    final last = segments.last;
    final baseSegments =
        last.startsWith('sub_') ? segments.sublist(0, segments.length - 1) : segments;
    if (baseSegments.isEmpty) return uri.origin;
    return uri.replace(pathSegments: baseSegments).toString().replaceAll(RegExp(r'/+$'), '');
  }

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
        // 订阅拉取超时 15 秒，失败由调用方提示“网络不通，请检查网络后重试”。
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

  /// 拉订阅并解析成节点列表（含回退链）。
  ///
  /// 顺序：singbox → base64 → clash。某一格式返回 200 但正文解析失败时
  /// 试下一格式；404/410/429/400 直接抛，不回退。
  /// 返回节点、解析失败数、userinfo 头与最终生效的格式。
  Future<NodeListResult> fetchNodes({required String subscriptionUrl}) async {
    SubscriptionException? lastError;
    for (final format in const [
      SubscriptionFormat.singbox,
      SubscriptionFormat.base64,
      SubscriptionFormat.clash,
    ]) {
      try {
        return await _fetchAndParse(subscriptionUrl, format);
      } on SubscriptionException catch (e) {
        // 令牌/地址问题不回退；网络问题与解析失败才试下一格式。
        if (e.kind != SubscriptionErrorKind.network &&
            e.kind != SubscriptionErrorKind.parseFailed) {
          rethrow;
        }
        lastError = e;
      }
    }
    throw lastError ??
        const SubscriptionException(
          kind: SubscriptionErrorKind.parseFailed,
          message: '订阅内容解析失败',
        );
  }

  Future<NodeListResult> _fetchAndParse(
    String subscriptionUrl,
    SubscriptionFormat format,
  ) async {
    final formatParam = switch (format) {
      SubscriptionFormat.singbox => 'singbox',
      SubscriptionFormat.base64 => 'base64',
      SubscriptionFormat.clash => 'clash',
    };
    final uri = Uri.parse(subscriptionUrl).replace(
      queryParameters: {
        ...Uri.parse(subscriptionUrl).queryParameters,
        'format': formatParam,
      },
    );
    try {
      final response = await _dio.get<String>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.plain,
          headers: {'User-Agent': userAgent},
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      final body = response.data ?? '';
      final parsed = parseSubscription(body, format);
      // 0 个节点且有解析失败 = 该格式没读懂正文，继续回退；
      // 合法空订阅是 0 节点 0 失败，不触发回退。
      if (parsed.nodes.isEmpty && parsed.failedCount > 0) {
        throw const SubscriptionException(
          kind: SubscriptionErrorKind.parseFailed,
          message: '订阅内容解析失败',
        );
      }
      return NodeListResult(
        nodes: parsed.nodes,
        failedCount: parsed.failedCount,
        userinfo: SubscriptionUserinfo.parse(
          response.headers.value('subscription-userinfo'),
        ),
        format: format,
      );
    } on FormatException {
      throw const SubscriptionException(
        kind: SubscriptionErrorKind.parseFailed,
        message: '订阅内容解析失败',
      );
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  SubscriptionException _mapDioError(DioException e) {
    final status = e.response?.statusCode;
    final retryAfter = e.response?.headers.value('retry-after');
    switch (status) {
      case 404:
        // 面板语义：令牌不对或路由不对（Worker 对未知路径也回 404），
        // 不是“订阅失效”——别让用户以为订阅本身没了。
        return const SubscriptionException(
          kind: SubscriptionErrorKind.invalid,
          message: '订阅链接不对或令牌不对，请检查链接或重新获取',
        );
      case 410:
        // 面板 1.4.27 语义：410 = 该订阅已退场（通用/合并订阅退场），
        // 不是到期；要用户去用订阅用户的新链接。
        return const SubscriptionException(
          kind: SubscriptionErrorKind.retired,
          message: '该订阅已退场，请使用订阅用户的新订阅链接',
        );
      case 429:
        return SubscriptionException(
          kind: SubscriptionErrorKind.rateLimited,
          message: '请求太频繁，请稍后再试',
          retryAfterSeconds: int.tryParse(retryAfter ?? '') ?? 600,
        );
      case 400:
        return const SubscriptionException(
          kind: SubscriptionErrorKind.badRequest,
          message: '订阅请求参数不对，请联系管理员',
        );
      default:
        // 没收到响应（超时/断网）或未列出的状态码：先按网络问题报，
        // 让用户检查网络后重试，不猜订阅本身的原因。
        return const SubscriptionException(
          kind: SubscriptionErrorKind.network,
          message: '网络不通，请检查网络后重试',
        );
    }
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

  /// 流量与到期（中转口径；没有 userinfo 头时为 null）。
  final SubscriptionUserinfo? userinfo;

  final int statusCode;
}

/// 拉订阅并解析后的节点列表结果。
class NodeListResult {
  const NodeListResult({
    required this.nodes,
    required this.failedCount,
    required this.userinfo,
    required this.format,
  });

  /// 解析出的节点。
  final List<Node> nodes;

  /// 解析失败的节点个数。
  final int failedCount;

  /// 流量与到期（中转口径；没有 userinfo 头时为 null）。
  final SubscriptionUserinfo? userinfo;

  /// 最终生效的订阅格式。
  final SubscriptionFormat format;
}

/// 订阅失败的种类（界面按种类给不同的提示，不把技术细节推给用户）。
enum SubscriptionErrorKind {
  /// 订阅链接不对或令牌不对（404）：链接或令牌有问题，请检查或重新获取。
  invalid,

  /// 该订阅已退场（410）：通用/合并订阅退场，请用订阅用户的新订阅链接。
  retired,

  /// 同一 IP 连续失败被锁（429）：退避重试，带 Retry-After。
  rateLimited,

  /// 请求参数非法（400）：开发侧问题。
  badRequest,

  /// 网络不通 / 超时。
  network,

  /// 正文三种格式都解析失败。
  parseFailed,
}

/// 订阅拉取/解析失败时抛出的异常（带种类，界面按种类提示）。
class SubscriptionException implements Exception {
  const SubscriptionException({
    required this.kind,
    required this.message,
    this.retryAfterSeconds,
  });

  final SubscriptionErrorKind kind;

  /// 给用户看的提示（不含技术细节）。
  final String message;

  /// 429 时面板给的退避秒数（默认 600）。
  final int? retryAfterSeconds;

  @override
  String toString() => 'SubscriptionException($kind: $message)';
}
