import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 账号密码登录服务（切片 9：MVP 补片）。
///
/// 契约见 docs/api/client-login.md；面板侧接口还不存在，面板实现时照
/// 契约做。客户端只按契约调接口，不猜面板行为。
/// - 登录请求 `POST https://<面板域名>:<端口>/api/v1/client/login`，
///   请求体 `{username, password}`，成功返回会话令牌 + 该账号的订阅链接；
/// - 端口段 9870–9880，默认端口 9876：探测顺序是记住的端口 → 9876 →
///   9870→9880（跳过已试过的）；收到任何 HTTP 响应即为通并记住该端口，
///   只有连接失败 / 超时 / 证书校验失败才换下一个端口；
/// - 会话令牌只存系统密钥库（与订阅令牌同种存储），绝不存明文密码；
///   用户名与记住的端口不敏感，存 shared_preferences。
class AuthService {
  AuthService({Dio? dio, FlutterSecureStorage? storage})
      : _dio = dio ?? Dio(),
        _storage = storage ?? const FlutterSecureStorage();

  final Dio _dio;
  final FlutterSecureStorage _storage;

  /// 会话令牌（只进系统密钥库）。
  static const String _sessionTokenKey = 'client_session_token';

  /// 登录成功的账号名（只用于我的页显示，不敏感）。
  static const String _usernameKey = 'client_login_username';

  /// 上次登录成功时服务器实际响应的端口（非敏感，下次优先试它）。
  static const String _rememberedPortKey = 'client_login_port';

  /// 上次填过的面板域名（登录页默认填它）。
  static const String _lastDomainKey = 'client_login_last_domain';

  /// 登录端口段（含两端）。
  static const int minLoginPort = 9870;
  static const int maxLoginPort = 9880;

  /// 默认登录端口：9876（用户 2026-11-23 06:21 定）。
  static const int defaultLoginPort = 9876;

  /// 单个端口的超时：连接、发送、接收各 5 秒；11 个端口全试一遍
  /// 最多约 55 秒。
  static const Duration _perPortTimeout = Duration(seconds: 5);

  /// 端口探测顺序（纯函数，测试直接测它）：
  /// 1. 上次记住的端口（在段内才认）；
  /// 2. 默认端口 9876（还没试过时）；
  /// 3. 9870 → 9880 逐个试，跳过前面已试过的。
  static List<int> probeOrder(int? rememberedPort) {
    final order = <int>[];
    if (rememberedPort != null &&
        rememberedPort >= minLoginPort &&
        rememberedPort <= maxLoginPort) {
      order.add(rememberedPort);
    }
    if (!order.contains(defaultLoginPort)) order.add(defaultLoginPort);
    for (var p = minLoginPort; p <= maxLoginPort; p++) {
      if (!order.contains(p)) order.add(p);
    }
    return order;
  }

  /// 面板域名归一化：去掉协议、端口、路径与前后空格，只留 host；
  /// 不合法返回 ''（调用方报“面板域名不对”）。
  /// 接受 `ccpanel.jiankong.cf` 与 `https://ccpanel.jiankong.cf:11111/x`
  /// 两种写法；localhost 也认。
  static String normalizePanelDomain(String input) {
    var s = input.trim().toLowerCase();
    if (s.isEmpty) return '';
    if (s.contains('://')) {
      final uri = Uri.tryParse(s);
      if (uri == null || uri.host.isEmpty) return '';
      s = uri.host;
    } else {
      s = s.split('/').first.split(':').first.trim();
    }
    if (s.isEmpty || s.contains(' ') || s.contains('_')) return '';
    if (s != 'localhost' && !s.contains('.')) return '';
    return s;
  }

  /// 读会话令牌；未登录返回 null。
  Future<String?> readSessionToken() =>
      _storage.read(key: _sessionTokenKey);

  /// 读登录成功的账号名；未登录返回 null。
  Future<String?> readUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_usernameKey);
  }

  /// 读记住的端口；没有返回 null（段外的值不认，当作没有）。
  Future<int?> readRememberedPort() async {
    final prefs = await SharedPreferences.getInstance();
    final port = prefs.getInt(_rememberedPortKey);
    if (port == null ||
        port < minLoginPort ||
        port > maxLoginPort) {
      return null;
    }
    return port;
  }

  /// 读上次填过的面板域名；没有返回 null。
  Future<String?> readLastPanelDomain() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastDomainKey);
  }

  /// 记住上次填过的面板域名（登录成功后调）。
  Future<void> saveLastPanelDomain(String domain) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastDomainKey, domain);
  }

  /// 恢复会话：令牌与账号名都在才算登录态；缺一个就当未登录。
  Future<AuthSession?> restoreSession() async {
    final token = await readSessionToken();
    if (token == null || token.isEmpty) return null;
    final username = await readUsername();
    if (username == null || username.isEmpty) return null;
    return AuthSession(token: token, username: username);
  }

  /// 登录。
  ///
  /// 按 [probeOrder] 逐个端口发登录请求：收到 HTTP 响应就停（记住该端口，
  /// 再按状态码映射）；连接失败 / 超时 / 证书校验失败才换下一个端口。
  /// 成功时会话令牌进系统密钥库，账号名与端口写 shared_preferences。
  /// 失败抛 [AuthException]（带给用户看的文案，不含技术细节）。
  Future<AuthLoginResult> login({
    required String panelDomain,
    required String username,
    required String password,
  }) async {
    final domain = normalizePanelDomain(panelDomain);
    if (domain.isEmpty) {
      throw const AuthException(
        kind: AuthErrorKind.invalidDomain,
        message: '面板域名不对，请填写面板域名（如 ccpanel.jiankong.cf）',
      );
    }
    if (username.trim().isEmpty || password.isEmpty) {
      throw const AuthException(
        kind: AuthErrorKind.invalidInput,
        message: '账号和密码都要填',
      );
    }
    final remembered = await readRememberedPort();
    for (final port in probeOrder(remembered)) {
      final result = await _tryLoginAt(
        domain: domain,
        port: port,
        username: username.trim(),
        password: password,
      );
      // null = 该端口连接失败 / 超时 / 证书校验失败，换下一个端口。
      if (result == null) continue;
      return result;
    }
    throw const AuthException(
      kind: AuthErrorKind.unreachable,
      message: '面板连接不上，检查面板域名与网络',
    );
  }

  /// 在一个端口上发一次登录请求。
  /// 收到 HTTP 响应返回映射后的结果（成功或 [AuthException]）；
  /// 连接失败 / 超时 / 证书校验失败返回 null（调用方换下一个端口）。
  Future<AuthLoginResult?> _tryLoginAt({
    required String domain,
    required int port,
    required String username,
    required String password,
  }) async {
    final url = 'https://$domain:$port/api/v1/client/login';
    try {
      // 响应按纯文本收、自己 jsonDecode：面板返回的不是 JSON 时
      // 报“面板返回的数据不对”，不让 Dio 的类型转换把流程炸掉。
      final response = await _dio.post<String>(
        url,
        data: {'username': username, 'password': password},
        options: Options(
          responseType: ResponseType.plain,
          headers: {'User-Agent': _userAgent},
          sendTimeout: _perPortTimeout,
          receiveTimeout: _perPortTimeout,
          connectTimeout: _perPortTimeout,
        ),
      );
      // 收到响应就是通了：先记住这个端口，再按状态码映射。
      await _rememberPort(port);
      return await _mapSuccess(response, port);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == null) return null; // 没收到响应：换下一个端口。
      // 收到响应就是通了：先记住这个端口，再按状态码映射。
      await _rememberPort(port);
      throw _mapStatusError(status);
    }
  }

  /// 成功响应的解析：不是 JSON 或缺 token，都是面板返回的数据不对
  ///（开发侧问题）。
  Future<AuthLoginResult> _mapSuccess(
    Response<String> response,
    int port,
  ) async {
    final Object? decoded = () {
      try {
        return jsonDecode(response.data ?? '');
      } catch (_) {
        return null;
      }
    }();
    final data = decoded is Map<String, dynamic> ? decoded : null;
    if (data == null) {
      throw const AuthException(
        kind: AuthErrorKind.invalidResponse,
        message: '面板返回的数据不对，请联系管理员',
      );
    }
    final token = data['token'] as String?;
    if (token == null || token.isEmpty) {
      throw const AuthException(
        kind: AuthErrorKind.invalidResponse,
        message: '面板返回的数据不对，请联系管理员',
      );
    }
    final username = data['username'] as String? ?? '';
    final subscriptionUrl = data['subscription_url'] as String?;
    await _storage.write(key: _sessionTokenKey, value: token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usernameKey, username);
    return AuthLoginResult(
      token: token,
      username: username,
      subscriptionUrl:
          subscriptionUrl == null || subscriptionUrl.isEmpty
              ? null
              : subscriptionUrl,
      port: port,
    );
  }

  /// 按状态码映射失败文案（不读响应体细节，不把技术细节推给用户）。
  AuthException _mapStatusError(int status) {
    switch (status) {
      case 401:
        return const AuthException(
          kind: AuthErrorKind.wrongCredentials,
          message: '账号或密码不对',
        );
      case 404:
        return const AuthException(
          kind: AuthErrorKind.endpointMissing,
          message: '面板版本太旧，没有账号登录接口，请先升级面板',
        );
      case 429:
        return const AuthException(
          kind: AuthErrorKind.rateLimited,
          message: '请求太频繁，请稍后再试',
        );
      default:
        if (status >= 500) {
          return const AuthException(
            kind: AuthErrorKind.serverError,
            message: '面板出错了，请稍后再试',
          );
        }
        return const AuthException(
          kind: AuthErrorKind.serverError,
          message: '登录请求不对，请联系管理员',
        );
    }
  }

  Future<void> _rememberPort(int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_rememberedPortKey, port);
  }

  /// 登出：清会话令牌与账号名；订阅与节点不受影响（DEV-PLAN §10.2）。
  /// 记住的端口保留（下次登录还优先试它）。
  Future<void> logout() async {
    await _storage.delete(key: _sessionTokenKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_usernameKey);
  }

  /// 当前 UA（与订阅拉取同一套，见 subscription_service.dart）。
  static const String _userAgent = 'Zhexuexi/0.1.0';
}

/// 恢复出的登录会话（令牌 + 账号名）。
class AuthSession {
  const AuthSession({required this.token, required this.username});

  final String token;
  final String username;
}

/// 一次登录成功的结果。
class AuthLoginResult {
  const AuthLoginResult({
    required this.token,
    required this.username,
    required this.subscriptionUrl,
    required this.port,
  });

  /// 会话令牌（已存进系统密钥库）。
  final String token;

  /// 登录成功的账号名。
  final String username;

  /// 该账号名下的订阅完整链接；账号下没有订阅时为 null，
  /// 此时登录成功但不绑定订阅。
  final String? subscriptionUrl;

  /// 本次登录实际通的端口（已记住，下次优先试它）。
  final int port;
}

/// 登录失败的种类（界面按种类给不同的提示，不把技术细节推给用户）。
enum AuthErrorKind {
  /// 账号或密码不对（401）。
  wrongCredentials,

  /// 面板版本太旧，没有登录接口（404）。
  endpointMissing,

  /// 请求太频繁（429）。
  rateLimited,

  /// 面板内部出错（5xx）或其它 4xx。
  serverError,

  /// 11 个端口全不通。
  unreachable,

  /// 面板返回的数据不对（200 但缺 token）。
  invalidResponse,

  /// 面板域名不对。
  invalidDomain,

  /// 账号或密码没填。
  invalidInput,
}

/// 登录失败时抛出的异常（带种类，界面按种类提示）。
class AuthException implements Exception {
  const AuthException({required this.kind, required this.message});

  final AuthErrorKind kind;

  /// 给用户看的提示（不含技术细节）。
  final String message;

  @override
  String toString() => 'AuthException($kind: $message)';
}
