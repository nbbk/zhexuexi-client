import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
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
/// 1. 面板 `https://<panel_api_base>/client-config.json`（方案 A，
///    须面板新增公开只读接口，待拍板 D10；面板接口地址取自本地缓存
///    的最后一份好配置的 panel_api_base，没有时用包内默认值，
///    example.com 占位地址跳过。0.1.3 D 路修复 3：必须从
///    panel_api_base（:11111）派生，不要拼 `https://$panelDomain/`——
///    panel_domain 无端口会打到 443，面板 443 根本不通，即使 1.4.29
///    加了路由也打不到。0.1.4 C 路 P0-1：无缓存时也进链——用包内
///    品牌 fallback [bundledPanelApiBase]（与已发布配置的
///    panel_api_base 同值），不再等 Raw/Worker 先成功一次才出现；
///    登录页占位符仍用 panel.example.com，不在这里暴露给用户输入）；
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
    Dio? proxyDio,
    List<String>? configUrls,
    SharedPreferences? prefs,
    String? publicKeyBase64,
    bool Function()? coreStarted,
  })  : _dio = dio ?? Dio(),
        // ignore: prefer_initializing_formals
        _proxyDio = proxyDio,
        _configUrlsOverride = configUrls,
        _prefsOverride = prefs,
        _publicKeyBase64 = publicKeyBase64 ?? remoteConfigPublicKeyBase64,
        // ignore: prefer_initializing_formals
        _coreStarted = coreStarted;

  final Dio _dio;

  /// 经本地 mixed 入站（127.0.0.1:2080）的 Dio（0.1.3 D 路修复 3：
  /// 开关已开时再试一轮；为 null 时不跑代理轮。生产用
  /// [createProxyDio] 造，测试可注入 mock Dio）。
  /// 构造器参数名 proxyDio 是 provider 与测试用的公开 API，
  /// 私有字段名不能跨库作 initializing formal，赋值处见 ignore。
  final Dio? _proxyDio;

  /// 核心是否已启动（开关是否开着）：生产由 provider 注入
  /// `() => ref.read(coreServiceProvider).status == CoreStatus.started`；
  /// 为 null 时认为没启动、不跑代理轮。
  final bool Function()? _coreStarted;

  /// 造一个经本地 mixed 入站的 Dio：HTTP(S) 请求走
  /// `PROXY 127.0.0.1:2080`，即走核心的代理出站。开关开着时手机
  /// 直连可能被墙、代理出站却是通的（订阅能拉就是旁证），远程
  /// 配置直连失败后经代理再试一轮。
  static Dio createProxyDio() {
    final dio = Dio();
    final adapter = IOHttpClientAdapter();
    adapter.createHttpClient = () {
      final client = HttpClient();
      client.findProxy = (_) => 'PROXY 127.0.0.1:2080';
      return client;
    };
    dio.httpClientAdapter = adapter;
    return dio;
  }

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

  /// 包内品牌 fallback 的面板接口地址（0.1.4 C 路 P0-1：修鸡生蛋——
  /// 无缓存时面板地址也要进地址链，不再等 Raw/Worker 先成功一次
  /// 把 panel_api_base 写进缓存才出现。值与已发布 client-config.json
  /// 的 panel_api_base 一致；只用在地址链内部取值，登录页占位符
  /// 仍是 panel.example.com，不向用户暴露真实域名）。
  static const String bundledPanelApiBase =
      'https://ccpanel.jiankong.cf:11111';

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

  /// 默认三地址链（面板地址由当前缓存/包内默认的 panel_api_base 派生）。
  Future<List<String>> defaultConfigUrls() async {
    final urls = <String>[];
    final cached = await loadCached();
    if (cached != null && !isPlaceholderDomain(cached.panelDomain)) {
      // 0.1.3 D 路修复 3：面板地址从 panel_api_base（:11111）派生，
      // 不要拼 https://$panelDomain/——panel_domain 无端口会打到
      // 443，面板 443 根本不通，即使 1.4.29 加了 /client-config.json
      // 路由也打不到。panel_api_base 为空时 panelApiBaseOrDerived
      // 回落到 https://$panelDomain（老行为）。
      final apiBase = cached.panelApiBaseOrDerived;
      final base = apiBase.endsWith('/')
          ? apiBase.substring(0, apiBase.length - 1)
          : apiBase;
      urls.add('$base/client-config.json');
    } else if (cached == null) {
      // 0.1.4 C 路 P0-1：无缓存时面板地址也要进链——用包内品牌
      // fallback 的真实 panel_api_base。旧逻辑在这里整段跳过面板
      // 地址（占位域名 panel.example.com），派生修复只在第二份
      // 及以后的拉取生效，首跑是死代码，用户从未成功缓存过就永远
      // 拉不到面板，这是 0.1.3 仍拉不到的鸡生蛋根因。
      urls.add('$bundledPanelApiBase/client-config.json');
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

  /// 一次 GET（0.1.3 D 路修复 3：显式设 connectTimeout——以前只
  /// 设了 send/receive，连接阶段卡住时超时口径不明确；全部状态码
  /// 都走 Response 分支，404 在调用方数，不靠 DioException）。
  Future<Response<String>> _getOnce(String url, {required Dio dio}) {
    return dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        connectTimeout: fetchTimeout,
        sendTimeout: fetchTimeout,
        receiveTimeout: fetchTimeout,
        // 404 单路径收：Dio 默认 validateStatus 下 404 会以
        // DioException 抛出来，调用方的 404 分支走不到；这里让全部
        // 状态码都走 Response 分支，404 只在调用方数。
        validateStatus: (_) => true,
      ),
    );
  }

  /// GET 一次，网络层失败（超时/断连，没收到任何 HTTP 响应）时再
  /// 试一次（0.1.3 D 路修复 3：每地址重试一次；404 与其他 HTTP
  /// 状态码是服务器明确回答，不重试；拦截器 reject 的 404 带
  /// response，同样不重试）。重试也失败就把第二次的异常抛出来。
  Future<Response<String>> _getWithRetry(
    String url, {
    required Dio dio,
  }) async {
    try {
      return await _getOnce(url, dio: dio);
    } on DioException catch (e) {
      if (e.response != null) rethrow;
      debugPrint('远程配置拉取重试一次（$url）');
      return await _getOnce(url, dio: dio);
    }
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
        final response = await _getWithRetry(url, dio: _dio);
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
  /// - 全部失败且无缓存 → 用包内默认值，状态 failed；
  /// - 真拉过、且每个地址都明确回 404、又无缓存 → 状态 notPublished
  ///   （配置根本还没发布，不是网络问题；2026-11-25 实测
  ///   https://cc.jiankong.cf/client-config.json 与 GitHub Raw 都 404）。
  ///   只认 404：500、超时、断网仍算普通 failed。
  /// - 每次尝试的结局都记进 [RemoteConfigRefreshResult.failures]
  ///  （URL＋kind＋message），设置页“检查更新”失败时逐条列出来，
  ///   不只报一句“请检查网络”。
  Future<RemoteConfigRefreshResult> refresh() async {
    final cached = await loadCached();
    final urls = _configUrlsOverride ?? await defaultConfigUrls();
    var sawValid = false;
    var attempted = 0;
    // 每个地址至少有一轮明确回 404 的地址集合（0.1.3 D 路修复 3：
    // 两轮都跑时 notPublished 按“每个地址都 404”算，不按尝试次数算）。
    final notFoundUrls = <String>{};
    final failures = <RemoteConfigAttemptFailure>[];

    /// 对一个地址做一次尝试（直连或经代理，由 [dio]/[viaProxy] 决定）。
    /// 拉到比缓存新的版本就存缓存并返回它（调用方直接回 updated）；
    /// 否则返回 null，继续试下一个地址。404 计数与失败记录都在这
    /// 里做，每次尝试只数一次（重试是 [_getWithRetry] 内部的事，
    /// 不另计数；重试成功时这里只看到一次成功的 Response）。
    Future<RemoteConfig?> tryUrl(
      String url,
      Dio dio, {
      required bool viaProxy,
    }) async {
      if (!isFetchableUrl(url)) return null;
      // attempted 只在直连轮计：代理轮重访同一批地址，不重复计
      //（notPublished 判定 `notFound == attempted` 靠它）。
      if (!viaProxy) attempted++;
      try {
        final response = await _getWithRetry(url, dio: dio);
        if (response.statusCode == 404) {
          notFoundUrls.add(url);
          failures.add(
            RemoteConfigAttemptFailure(
              url: url,
              kind: RemoteConfigFailureKind.notFound,
              message: '404 未找到（配置还没发布到这个地址）',
              viaProxy: viaProxy,
            ),
          );
          debugPrint('远程配置拉取 404（$url）${viaProxy ? '（经代理）' : ''}');
          return null;
        }
        if (response.statusCode != 200 || response.data == null) {
          final isEmpty200 =
              response.statusCode == 200 && response.data == null;
          failures.add(
            RemoteConfigAttemptFailure(
              url: url,
              kind: isEmpty200
                  ? RemoteConfigFailureKind.invalidEnvelope
                  : RemoteConfigFailureKind.httpStatus,
              message: isEmpty200 ? '空响应' : 'HTTP ${response.statusCode}',
              viaProxy: viaProxy,
            ),
          );
          debugPrint(
            '远程配置拉取失败（$url）：HTTP ${response.statusCode}',
          );
          return null;
        }
        final config = await _parseEnvelope(response.data!);
        if (config == null) {
          failures.add(
            RemoteConfigAttemptFailure(
              url: url,
              kind: RemoteConfigFailureKind.invalidEnvelope,
              message: '验签失败或格式不对',
              viaProxy: viaProxy,
            ),
          );
          debugPrint('远程配置拉取失败（$url）：验签失败或格式不对');
          return null;
        }
        sawValid = true;
        debugPrint('远程配置拉取成功（$url）：v${config.configVersion}');
        // 只接受比缓存新的版本，不回退；同版/旧版继续试下一个地址
        // （另一个地址可能有更新的版本）。
        if (cached != null && config.configVersion <= cached.configVersion) {
          return null;
        }
        await saveCache(response.data!);
        return config;
      } on DioException catch (e) {
        // 404 在这里也数（与上面 Response 分支二选一、每次尝试只
        // 数一次）：生产 Dio 开了 validateStatus 后 404 走 Response
        // 分支，但拦截器 reject 的 404（测试 mock 与个别 Dio 版本）
        // 仍以 DioException（带 response）抛出来；只留一路，
        // 另一路的 404 就数不到，notPublished 判定会错成 failed。
        if (e.response?.statusCode == 404) {
          notFoundUrls.add(url);
          failures.add(
            RemoteConfigAttemptFailure(
              url: url,
              kind: RemoteConfigFailureKind.notFound,
              message: '404 未找到（配置还没发布到这个地址）',
              viaProxy: viaProxy,
            ),
          );
          debugPrint('远程配置拉取 404（$url）');
          return null;
        }
        // validateStatus 全收之后这里只剩网络层异常（超时/断连）。
        final kind = switch (e.type) {
          DioExceptionType.connectionTimeout ||
          DioExceptionType.sendTimeout ||
          DioExceptionType.receiveTimeout => RemoteConfigFailureKind.timeout,
          DioExceptionType.connectionError =>
            RemoteConfigFailureKind.connectionError,
          _ => e.response != null
              ? RemoteConfigFailureKind.httpStatus
              : RemoteConfigFailureKind.connectionError,
        };
        final message = switch (kind) {
          RemoteConfigFailureKind.timeout => '连接超时（10 秒无响应）',
          RemoteConfigFailureKind.connectionError => '连不上（网络不通或域名解析失败）',
          RemoteConfigFailureKind.httpStatus =>
            'HTTP ${e.response?.statusCode ?? '未知'}',
          _ => e.message ?? e.toString(),
        };
        failures.add(
          RemoteConfigAttemptFailure(
            url: url,
            kind: kind,
            message: message,
            viaProxy: viaProxy,
          ),
        );
        debugPrint('远程配置拉取失败（$url）：$e');
        return null;
      } catch (e) {
        failures.add(
          RemoteConfigAttemptFailure(
            url: url,
            kind: RemoteConfigFailureKind.connectionError,
            message: e.toString(),
            viaProxy: viaProxy,
          ),
        );
        debugPrint('远程配置拉取失败（$url）：$e');
        return null;
      }
    }

    // 第一轮：直连。
    for (final url in urls) {
      final updated = await tryUrl(url, _dio, viaProxy: false);
      if (updated != null) {
        return RemoteConfigRefreshResult(
          status: RemoteConfigRefreshStatus.updated,
          config: updated,
          failures: failures,
        );
      }
    }
    // 第二轮（0.1.3 D 路修复 3）：开关已开时经本地 mixed 入站再试
    // 一轮——手机直连可能被墙、代理出站却是通的。只在第一轮没拿到
    // 新版时跑；开关没开（或没注入代理 Dio）时不跑。
    // 0.1.4 C 路 P0-2：
    // - 代理轮跳过已知 404 的地址：直连轮已回 404 的 URL，代理轮
    //   再试一次也只会是 404（服务端状态与走不走代理无关），跳过
    //   它们把等待时间省下来给 Raw；
    // - 代理轮跳过要留痕：0.1.3 里核心未启动时代理轮整段跳过且
    //   failures 里不留任何痕迹，用户与协调员分不清“没跑”与
    //   “跑了也失败”。注入了代理 Dio 但核心未启动时，记一条
    //   proxySkipped（不参与 notPublished 判定：attempted 只计
    //   直连轮，notFoundUrls 不动）。
    if (_coreStarted?.call() == true && _proxyDio != null) {
      for (final url in urls) {
        if (notFoundUrls.contains(url)) continue;
        final updated = await tryUrl(url, _proxyDio, viaProxy: true);
        if (updated != null) {
          return RemoteConfigRefreshResult(
            status: RemoteConfigRefreshStatus.updated,
            config: updated,
            failures: failures,
          );
        }
      }
    } else if (_proxyDio != null) {
      failures.add(
        const RemoteConfigAttemptFailure(
          url: '代理轮',
          kind: RemoteConfigFailureKind.proxySkipped,
          message: '核心未启动，开关没开或核心未连接',
          viaProxy: true,
        ),
      );
    }
    if (cached != null) {
      return RemoteConfigRefreshResult(
        status: sawValid
            ? RemoteConfigRefreshStatus.upToDate
            : RemoteConfigRefreshStatus.offlineCached,
        config: cached,
        failures: failures,
      );
    }
    if (attempted > 0 && notFoundUrls.length == attempted) {
      return RemoteConfigRefreshResult(
        status: RemoteConfigRefreshStatus.notPublished,
        config: RemoteConfig.defaults(),
        failures: failures,
      );
    }
    return RemoteConfigRefreshResult(
      status: RemoteConfigRefreshStatus.failed,
      config: RemoteConfig.defaults(),
      failures: failures,
    );
  }
}

/// 一次远程配置刷新的结果。
class RemoteConfigRefreshResult {
  const RemoteConfigRefreshResult({
    required this.status,
    required this.config,
    this.failures = const [],
  });

  /// 刷新结果（见 [RemoteConfigRefreshStatus]）。
  final RemoteConfigRefreshStatus status;

  /// 刷新后生效的配置（updated/upToDate/offlineCached 时是缓存或新配置，
  /// failed/notPublished 时是包内默认值）。
  final RemoteConfig config;

  /// 每次尝试的结局（按地址链顺序；成功拿到新版时只含它之前的失败）。
  /// 失败时给用户看的合并原因（给用户看，一行一条）。
  final List<RemoteConfigAttemptFailure> failures;

  /// 全部尝试失败时的合并原因（给用户看，一行一条）。
  /// proxySkipped 那条不拼 URL（它不是一次地址尝试），单独成行，
  /// 让用户一眼分清“代理轮没跑”与“代理轮跑了也失败”。
  String get failureMessage => failures
      .map(
        (f) => f.kind == RemoteConfigFailureKind.proxySkipped
            ? '· 代理轮未跑：${f.message}'
            : '· ${f.url}：${f.message}${f.viaProxy ? '（经代理）' : ''}',
      )
      .join('\n');
}

/// 一次远程配置拉取尝试的结局。
class RemoteConfigAttemptFailure {
  const RemoteConfigAttemptFailure({
    required this.url,
    required this.kind,
    required this.message,
    this.viaProxy = false,
  });

  /// 试过的地址。
  final String url;

  /// 失败种类。
  final RemoteConfigFailureKind kind;

  /// 给用户看的原因。
  final String message;

  /// 这次尝试是否经本地 mixed 入站（开关已开时的第二轮）。
  final bool viaProxy;
}

/// 一次远程配置拉取失败的种类。
enum RemoteConfigFailureKind {
  /// 404：配置还没发布到这个地址。
  notFound,

  /// 超时（10 秒无响应）。
  timeout,

  /// 连不上（网络不通或域名解析失败）。
  connectionError,

  /// 其他 HTTP 状态码。
  httpStatus,

  /// 200 但验签失败或格式不对。
  invalidEnvelope,

  /// 代理轮因核心未启动而跳过（不是一次地址尝试，不参与
  /// notPublished 判定；只进 failures，让设置页逐条展示时可见）。
  proxySkipped,
}

/// 远程配置刷新的五种结果。
enum RemoteConfigRefreshStatus {
  /// 拉到更新的版本，已应用并存缓存。
  updated,

  /// 拉到的都是旧版/同版，本地缓存已是最新。
  upToDate,

  /// 全部地址失败，正在用本地缓存的最后一份好配置。
  offlineCached,

  /// 全部失败且本地无缓存，用包内默认值。
  failed,

  /// 真拉过、每个地址都回 404、且本地无缓存：配置根本还没发布，
  /// 不是网络问题；用包内默认值，等服务端发布后再拉。
  notPublished,
}
