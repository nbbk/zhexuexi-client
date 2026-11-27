import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// 更新下载的网络路由（0.1.16）：代理优先、失败回落直连。
///
/// 背景：更新器以前用默认直连 Dio，而客户端自身被排除在 TUN 外
/// （防环路，`addDisallowedApplication` 自家包名），所以开着代理
/// 更新还是走国内直连，GitHub 不稳就下不动。核心跑着时本机
/// 127.0.0.1:2080 的 mixed 入站一定在听（配置里无条件写），更新
/// 检查与 APK 下载都先走它；代理那条路不通就同一请求重试一次
/// 直连；核心没开时直接直连，不尝试代理。
///
/// 写法照抄 `RemoteConfigService.createProxyDio`（同一入站、同一
/// `findProxy` 口径），只多两点：端口与鉴权从局域网代理设置取
/// （端口可改；鉴权开着时 mixed 入站要账号密码，没配就 407），
/// 以及代理失败回落直连的重试。
///
/// 注意：Dart HttpClient 没有原生 SOCKS5，走 HTTP 代理那一侧，
/// 不接 SOCKS。局域网代理开时入站监听改 0.0.0.0，本机
/// 127.0.0.1 照样能连，端口与鉴权不变。
class UpdateHttp {
  UpdateHttp({
    required bool Function() coreRunning,
    Dio? proxiedDio,
    Dio? directDio,
    int proxyPort = localProxyPort,
    ({String username, String password})? proxyCredentials,
  })  : _coreRunning = coreRunning, // ignore: prefer_initializing_formals
        _proxiedDio = proxiedDio ??
            createProxyDio(port: proxyPort, credentials: proxyCredentials),
        _directDio = directDio ?? Dio();

  /// 本地 mixed 入站默认端口（与 [SingboxConfigBuilder.mixedPort]
  /// 一致；局域网代理设置里可改，生产从 `lanProxyProvider` 取）。
  static const int localProxyPort = 2080;

  /// 代理建连超时：短一点，代理不通时别拖太久才回落直连。
  /// 版本检查与下载建连都走这个（各自的 send/receive 超时另算，
  /// 见调用处 Options）。
  static const Duration proxyConnectTimeout = Duration(seconds: 8);

  final bool Function() _coreRunning;
  final Dio _proxiedDio;
  final Dio _directDio;

  /// 造一个经本地 mixed 入站的 Dio：HTTP(S) 请求走
  /// `PROXY 127.0.0.1:<port>`，即走核心的代理出站。
  /// [credentials] 非空时遇 407 回账号密码（局域网代理鉴权开着
  /// 时 mixed 入站要鉴权；不给就 407，走回落直连）。
  static Dio createProxyDio({
    required int port,
    ({String username, String password})? credentials,
    Duration connectTimeout = proxyConnectTimeout,
  }) {
    final dio = Dio(BaseOptions(connectTimeout: connectTimeout));
    final adapter = IOHttpClientAdapter();
    adapter.createHttpClient = () {
      final client = HttpClient();
      client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
      final creds = credentials;
      if (creds != null) {
        client.authenticateProxy = (host, port, scheme, realm) async {
          client.addProxyCredentials(
            host,
            port,
            realm ?? '',
            HttpClientBasicCredentials(creds.username, creds.password),
          );
          return true;
        };
      }
      return client;
    };
    dio.httpClientAdapter = adapter;
    return dio;
  }

  Future<Response<T>> get<T>(String url, {Options? options}) =>
      _run((dio) => dio.get<T>(url, options: options));

  Future<Response> download(
    String url,
    String savePath, {
    Options? options,
    ProgressCallback? onReceiveProgress,
  }) =>
      _run(
        (dio) => dio.download(
          url,
          savePath,
          options: options,
          onReceiveProgress: onReceiveProgress,
        ),
      );

  /// 核心没开直接直连；开着先走代理，代理失败（见
  /// [_isProxyFailure]）同一请求重试一次直连；代理之外的失败
  /// （如服务器回 404/500，说明代理本身是通的）不重试，直接抛。
  Future<T> _run<T>(Future<T> Function(Dio dio) request) async {
    if (!_coreRunning()) return request(_directDio);
    try {
      return await request(_proxiedDio);
    } on DioException catch (e) {
      if (!_isProxyFailure(e)) rethrow;
      return request(_directDio);
    }
  }

  /// 代理失败才回落：建连/发包/收包的网络错，以及代理要鉴权
  /// （407，没配账号或账号不对）。
  static bool _isProxyFailure(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return true;
      case DioExceptionType.badResponse:
        return e.response?.statusCode == 407;
      default:
        return false;
    }
  }
}
