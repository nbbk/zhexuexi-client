// 切片 7：远程配置中心测试（规范 JSON、Ed25519 验签、地址链、版本规则、
// 本地缓存、订阅 404 重试、远程公告优先、强制更新）。
//
// 不碰真面板与真配置中心：Dio 用拦截器伪造响应；签名用测试内临时生成
// 的 Ed25519 密钥对（cryptography 包），私钥不出测试进程；
// 唯一用真密钥的用例是 test/fixtures/remote_config_v1.json，
// 它是用 tools/remote-config/sign.py + 真私钥签的（私钥只在 /tmp），
// 验签走编译进客户端的公钥，证明 openssl 签名与 Dart 验签能对上。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_sing_box/flutter_sing_box.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/brand/brand_config.dart';
import 'package:zhexuexi_client/brand/remote_config.dart';
import 'package:zhexuexi_client/core/clash_api_client.dart';
import 'package:zhexuexi_client/core/core_provider.dart';
import 'package:zhexuexi_client/core/singbox_core.dart';
import 'package:zhexuexi_client/services/announcement_service.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/remote_config_notifier.dart';
import 'package:zhexuexi_client/services/remote_config_service.dart';
import 'package:zhexuexi_client/services/subscription_service.dart';
import 'package:zhexuexi_client/services/subscription_store.dart';

/// 测试内临时生成的一对 Ed25519 密钥（只活在测试进程里）。
class _TempKeys {
  late final SimpleKeyPair keyPair;
  late final String publicKeyBase64;

  Future<void> init() async {
    keyPair = await Ed25519().newKeyPair();
    final pub = await keyPair.extractPublicKey();
    publicKeyBase64 = base64Encode(pub.bytes);
  }

  /// 给一份 payload（不含 signature）签名，返回整封信封 JSON 字符串。
  Future<String> signEnvelope(Map<String, dynamic> payload) async {
    final message = utf8.encode(canonicalJson(payload));
    final sig = await Ed25519().sign(message, keyPair: keyPair);
    final envelope = Map<String, dynamic>.of(payload)
      ..['signature'] = base64Encode(sig.bytes);
    return jsonEncode(envelope);
  }
}

/// 最小配置 payload（example.com / 203.0.113.x 脱敏地址）。
Map<String, dynamic> _payload({
  int version = 1,
  String subscriptionUrl =
      'https://sub.example.com/x9f2/sub_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  List<String> backupUrls = const [],
  bool forceUpdate = false,
  String minAppVersion = '0.1.0',
  String appName = '哲学系',
}) {
  return {
    'config_version': version,
    'updated_at': '2026-11-23T02:00:00+08:00',
    'min_app_version': minAppVersion,
    'force_update': forceUpdate,
    'brand': {
      'app_name': appName,
      'logo_url': 'https://config.example.com/zhexuexi/logo.png',
      'primary_color': '#16324F',
      'accent_color': '#E8A317',
      'support_url': 'https://example.com/support',
    },
    'panel': {
      'panel_domain': 'panel.example.com',
      'min_panel_version': '1.3.29',
      'subscription_url': subscriptionUrl,
      if (backupUrls.isNotEmpty) 'subscription_backup_urls': backupUrls,
      'subscription_format': 'singbox',
    },
    'features': {
      'auto_select': true,
      'tun_default': false,
      'show_traffic': true,
    },
  };
}

/// 按 URL 返回假响应的 Dio（远程配置拉取用）。
Dio _configDio(Map<String, ({int status, String body})> byUrl) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final fake = byUrl[options.uri.toString()];
        if (fake == null) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            ),
          );
          return;
        }
        final response = Response<String>(
          requestOptions: options,
          statusCode: fake.status,
          data: fake.body,
        );
        if (fake.status >= 200 && fake.status < 300) {
          handler.resolve(response);
        } else {
          handler.reject(
            DioException(
              requestOptions: options,
              response: response,
              type: DioExceptionType.badResponse,
            ),
          );
        }
      },
    ),
  );
  return dio;
}

/// 插件 fake（0.1.4：核心起来后重拉测试用）：只记调用、不碰平台通道，
/// 状态由测试手动推。
class _FakeCorePlugin extends FlutterSingBox {
  final _stateController = StreamController<ProxyState>.broadcast();

  @override
  Stream<ProxyState> get proxyStateStream => _stateController.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> startVpn() async {
    _stateController.add(const ProxyStarted());
  }

  @override
  Future<void> stopVpn() async {
    _stateController.add(const ProxyStopped());
  }

  @override
  Future<void> serviceReload() async {
    _stateController.add(const ProxyStarted());
  }

  @override
  Future<String> getSingBoxVersion() async => '1.14.4';

  void emit(ProxyState state) => _stateController.add(state);

  Future<void> close() => _stateController.close();
}

/// Clash API fake（0.1.4：核心起来后重拉测试用）：拨测恒通，不碰真网络。
class _FakeCoreClashApi extends ClashApiClient {
  @override
  Future<TrafficSample> trafficSample({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    return const TrafficSample(up: 0, down: 0);
  }

  @override
  Future<ProxyDelayResult> proxyDelayDetailed(
    String proxyName, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    return const ProxyDelayResult(delay: 123);
  }
}

class _FakeSecureStorage extends FlutterSecureStorage {
  final _map = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
  }) async =>
      _map[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
  }) async {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
  }) async {
    _map.remove(key);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('canonicalJson', () {
    test('key 递归排序、无空格', () {
      expect(
        canonicalJson({
          'b': 1,
          'a': {'d': 4, 'c': 3},
          'list': [
            {'z': 1, 'a': 2},
          ],
        }),
        '{"a":{"c":3,"d":4},"b":1,"list":[{"a":2,"z":1}]}',
      );
    });

    test('与 Python json.dumps(sort_keys=True, separators) 一致', () {
      // Python：json.dumps({"b": 1, "a": "哲学系"}, sort_keys=True,
      // separators=(',', ':'), ensure_ascii=False)
      // == '{"a":"哲学系","b":1}'（中文不转义）。
      expect(canonicalJson({'b': 1, 'a': '哲学系'}), '{"a":"哲学系","b":1}');
    });
  });

  group('compareVersions', () {
    test('大小与相等', () {
      expect(compareVersions('0.1.0', '0.2.0'), lessThan(0));
      expect(compareVersions('0.2.0', '0.1.0'), greaterThan(0));
      expect(compareVersions('1.0', '1.0.0'), 0);
      expect(compareVersions('1.0.0', '1.0.0'), 0);
      expect(compareVersions('1.10.0', '1.9.0'), greaterThan(0));
    });
  });

  group('verifySignature', () {
    test('临时密钥对：签了就过，改一个字就不过', () async {
      final keys = _TempKeys();
      await keys.init();
      final payload = _payload(version: 7);
      final envelopeJson = await keys.signEnvelope(payload);
      final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;
      final ok = await RemoteConfig.verifySignature(
        payload: Map<String, dynamic>.of(envelope)..remove('signature'),
        signatureBase64: envelope['signature'] as String,
        publicKeyBase64: keys.publicKeyBase64,
      );
      expect(ok, isTrue);

      // 改一个字（品牌名），签名就对不上。
      final tampered = Map<String, dynamic>.of(envelope);
      final brand = Map<String, dynamic>.of(
        tampered['brand'] as Map<String, dynamic>,
      );
      brand['app_name'] = '哲学系X';
      tampered['brand'] = brand;
      final tamperedOk = await RemoteConfig.verifySignature(
        payload: Map<String, dynamic>.of(tampered)..remove('signature'),
        signatureBase64: envelope['signature'] as String,
        publicKeyBase64: keys.publicKeyBase64,
      );
      expect(tamperedOk, isFalse);
    });

    test('错钥 / 坏 base64 / 长度不对都不过', () async {
      final keys = _TempKeys();
      await keys.init();
      final other = _TempKeys();
      await other.init();
      final payload = _payload();
      final envelopeJson = await keys.signEnvelope(payload);
      final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;
      final sig = envelope['signature'] as String;
      final clean = Map<String, dynamic>.of(envelope)..remove('signature');
      // 另一把钥验同一份签名。
      expect(
        await RemoteConfig.verifySignature(
          payload: clean,
          signatureBase64: sig,
          publicKeyBase64: other.publicKeyBase64,
        ),
        isFalse,
      );
      // 坏 base64。
      expect(
        await RemoteConfig.verifySignature(
          payload: clean,
          signatureBase64: '!!!not-base64!!!',
          publicKeyBase64: keys.publicKeyBase64,
        ),
        isFalse,
      );
      // 签名长度不对（32 字节不是 64 字节）。
      expect(
        await RemoteConfig.verifySignature(
          payload: clean,
          signatureBase64: base64Encode(List.filled(32, 0)),
          publicKeyBase64: keys.publicKeyBase64,
        ),
        isFalse,
      );
    });
  });

  group('真密钥 fixture（openssl 签名 + 编译进客户端的公钥）', () {
    test('test/fixtures/remote_config_v1.json 验签通过、字段对', () async {
      final raw = await File(
        'test/fixtures/remote_config_v1.json',
      ).readAsString();
      final config = await RemoteConfigService.parseAndVerifyEnvelope(raw);
      expect(config, isNotNull);
      expect(config!.configVersion, 1);
      expect(config.brand.appName, '哲学系');
      expect(config.panelDomain, 'panel.example.com');
      expect(config.subscriptionUrl, contains('sub.example.com/x9f2'));
      expect(config.announcement?.id, '20261123-test');
      expect(config.downloadUrl, 'https://example.com/download');
      expect(
        config.subscriptionBackupUrls,
        ['https://sub2.example.com/x9f2'],
      );
    });

    test('fixture 改一个字就验不过', () async {
      final raw = await File(
        'test/fixtures/remote_config_v1.json',
      ).readAsString();
      final tampered = raw.replaceFirst('哲学系', '哲学系X');
      expect(
        await RemoteConfigService.parseAndVerifyEnvelope(tampered),
        isNull,
      );
    });

    test('缺 signature 字段直接拒', () async {
      final raw = await File(
        'test/fixtures/remote_config_v1.json',
      ).readAsString();
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      envelope.remove('signature');
      final config = await RemoteConfigService.parseAndVerifyEnvelope(
        jsonEncode(envelope),
      );
      expect(config, isNull);
    });
  });

  group('isFetchableUrl', () {
    test('只认 HTTPS，HTTP 只放行本机回环', () {
      expect(
        RemoteConfigService.isFetchableUrl(
          'https://panel.example.com/client-config.json',
        ),
        isTrue,
      );
      expect(
        RemoteConfigService.isFetchableUrl(
          'http://panel.example.com/client-config.json',
        ),
        isFalse,
      );
      expect(
        RemoteConfigService.isFetchableUrl('http://127.0.0.1:8080/c.json'),
        isTrue,
      );
      expect(
        RemoteConfigService.isFetchableUrl('http://localhost:8080/c.json'),
        isTrue,
      );
      expect(RemoteConfigService.isFetchableUrl('ftp://example.com/c.json'),
          isFalse);
      expect(RemoteConfigService.isFetchableUrl(''), isFalse);
    });
  });

  group('RemoteConfigService.refresh', () {
    const configUrlA = 'http://127.0.0.1:18081/client-config.json';
    const configUrlB = 'http://127.0.0.1:18082/client-config.json';

    test('地址链：第一个 404、第二个验签通过就用第二个', () async {
      final keys = _TempKeys();
      await keys.init();
      final envelope = await keys.signEnvelope(_payload(version: 2));
      final prefs = await SharedPreferences.getInstance();
      final service = RemoteConfigService(
        dio: _configDio({
          configUrlA: (status: 404, body: ''),
          configUrlB: (status: 200, body: envelope),
        }),
        configUrls: [configUrlA, configUrlB],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final result = await service.refresh();
      expect(result.status, RemoteConfigRefreshStatus.updated);
      expect(result.config.configVersion, 2);
    });

    test('签名不过的地址跳过，继续试下一个', () async {
      final keys = _TempKeys();
      await keys.init();
      final good = await keys.signEnvelope(_payload(version: 2));
      final badPayload = _payload(version: 9, appName: '哲学系X');
      // 拿 v9 的 payload 配 v2 的签名：签名对不上。
      final badEnvelope = jsonDecode(good) as Map<String, dynamic>;
      badEnvelope['brand'] = badPayload['brand'];
      final prefs = await SharedPreferences.getInstance();
      final service = RemoteConfigService(
        dio: _configDio({
          configUrlA: (status: 200, body: jsonEncode(badEnvelope)),
          configUrlB: (status: 200, body: good),
        }),
        configUrls: [configUrlA, configUrlB],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final result = await service.refresh();
      expect(result.status, RemoteConfigRefreshStatus.updated);
      expect(result.config.configVersion, 2);
    });

    test('版本规则：同版/旧版不回退，新版才应用并存缓存', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      // 先存一份 v3 缓存。
      final v3 = await keys.signEnvelope(_payload(version: 3));
      await prefs.setString(RemoteConfigService.cacheKey, v3);

      Future<RemoteConfigRefreshResult> refreshWith(String envelope) async {
        final service = RemoteConfigService(
          dio: _configDio({configUrlA: (status: 200, body: envelope)}),
          configUrls: [configUrlA],
          prefs: prefs,
          publicKeyBase64: keys.publicKeyBase64,
        );
        return service.refresh();
      }

      // 远程同版 v3：不更新，缓存还是 v3。
      var result = await refreshWith(
        await keys.signEnvelope(_payload(version: 3)),
      );
      expect(result.status, RemoteConfigRefreshStatus.upToDate);
      expect(result.config.configVersion, 3);
      // 远程旧版 v2：同样不回退。
      result = await refreshWith(
        await keys.signEnvelope(_payload(version: 2)),
      );
      expect(result.status, RemoteConfigRefreshStatus.upToDate);
      expect(result.config.configVersion, 3);
      // 远程新版 v4：应用并存缓存。
      result = await refreshWith(
        await keys.signEnvelope(_payload(version: 4, appName: '哲学系新')),
      );
      expect(result.status, RemoteConfigRefreshStatus.updated);
      expect(result.config.configVersion, 4);
      expect(result.config.brand.appName, '哲学系新');
      final cached = await RemoteConfigService(
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      ).loadCached();
      expect(cached?.configVersion, 4);
    });

    test('全部失败：有缓存用缓存，没缓存用包内默认值', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      RemoteConfigService failing() => RemoteConfigService(
            dio: _configDio({}),
            configUrls: [configUrlA],
            prefs: prefs,
            publicKeyBase64: keys.publicKeyBase64,
          );

      // 没缓存：failed + 默认值（版本 0）。
      var result = await failing().refresh();
      expect(result.status, RemoteConfigRefreshStatus.failed);
      expect(result.config.configVersion, 0);

      // 有缓存：offlineCached + 缓存的版本。
      final v3 = await keys.signEnvelope(_payload(version: 3));
      await prefs.setString(RemoteConfigService.cacheKey, v3);
      result = await failing().refresh();
      expect(result.status, RemoteConfigRefreshStatus.offlineCached);
      expect(result.config.configVersion, 3);
    });

    test('全部地址都 404 且无缓存：状态 notPublished，不是网络问题', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      final service = RemoteConfigService(
        dio: _configDio({
          configUrlA: (status: 404, body: ''),
          configUrlB: (status: 404, body: ''),
        }),
        configUrls: [configUrlA, configUrlB],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final result = await service.refresh();
      expect(result.status, RemoteConfigRefreshStatus.notPublished);
      expect(result.config.configVersion, 0);
      // failures 逐条：两个地址都是 404。
      expect(result.failures.length, 2);
      expect(
        result.failures.map((f) => f.kind),
        everyElement(RemoteConfigFailureKind.notFound),
      );
      expect(result.failureMessage, contains(configUrlA));
      expect(result.failureMessage, contains(configUrlB));
    });

    test('Worker 404＋Raw 超时→failed 且 failures 逐条列原因', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      // configUrlA 404；configUrlB 不在假 Dio 的表里：按约定算断网。
      final service = RemoteConfigService(
        dio: _configDio({configUrlA: (status: 404, body: '')}),
        configUrls: [configUrlA, configUrlB],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final result = await service.refresh();
      expect(result.status, RemoteConfigRefreshStatus.failed);
      expect(result.failures.length, 2);
      expect(result.failures[0].url, configUrlA);
      expect(result.failures[0].kind, RemoteConfigFailureKind.notFound);
      expect(result.failures[1].url, configUrlB);
      expect(
        result.failures[1].kind,
        RemoteConfigFailureKind.connectionError,
      );
      expect(result.failureMessage, contains('404 未找到'));
      expect(result.failureMessage, contains('连不上'));
    });

    test('200 验签失败＋另一地址 404→failed，失败种类分得清', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      final service = RemoteConfigService(
        dio: _configDio({
          configUrlA: (status: 200, body: '{"config_version": 9}'),
          configUrlB: (status: 404, body: ''),
        }),
        configUrls: [configUrlA, configUrlB],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final result = await service.refresh();
      expect(result.status, RemoteConfigRefreshStatus.failed);
      expect(result.failures.length, 2);
      expect(
        result.failures[0].kind,
        RemoteConfigFailureKind.invalidEnvelope,
      );
      expect(result.failures[1].kind, RemoteConfigFailureKind.notFound);
    });

    test('非 DioException 不丢计数：attempted 照样算', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            throw StateError('boom');
          },
        ),
      );
      final service = RemoteConfigService(
        dio: dio,
        configUrls: [configUrlA],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final result = await service.refresh();
      // 只试了一个地址且不是 404：failed 不是 notPublished，
      // failures 里有一条（计数没丢）。
      expect(result.status, RemoteConfigRefreshStatus.failed);
      expect(result.failures.length, 1);
      expect(result.failures[0].url, configUrlA);
    });

    test('404 与断网混着：不是全 404，仍是 failed', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      // configUrlB 不在假 Dio 的表里：按 _configDio 的约定算断网。
      final service = RemoteConfigService(
        dio: _configDio({configUrlA: (status: 404, body: '')}),
        configUrls: [configUrlA, configUrlB],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final result = await service.refresh();
      expect(result.status, RemoteConfigRefreshStatus.failed);
      expect(result.config.configVersion, 0);
    });

    test('0.1.3：面板 URL 从 panel_api_base（:11111）派生，三源顺序不变', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(RemoteConfigService.cacheKey);
      // 缓存一份带 panel_api_base 的配置（面板域名 ccpanel.jiankong.cf）。
      final payload = _payload(version: 5);
      final panel = payload['panel'] as Map<String, dynamic>;
      panel['panel_domain'] = 'ccpanel.jiankong.cf';
      panel['panel_api_base'] = 'https://ccpanel.jiankong.cf:11111';
      final envelope = await keys.signEnvelope(payload);
      await prefs.setString(RemoteConfigService.cacheKey, envelope);
      final service = RemoteConfigService(
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final urls = await service.defaultConfigUrls();
      // 第一位是面板 :11111（不是拼 https://$panelDomain/ 打 443），
      // 其后 Worker、Raw 顺序不变。
      expect(urls[0], 'https://ccpanel.jiankong.cf:11111/client-config.json');
      expect(urls[1], RemoteConfigService.workerConfigUrl);
      expect(urls[2], RemoteConfigService.rawConfigUrl);
      await prefs.remove(RemoteConfigService.cacheKey);
    });

    test('0.1.3：panel_api_base 为空时回落到 https://<域名>', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(RemoteConfigService.cacheKey);
      final payload = _payload(version: 5);
      final panel = payload['panel'] as Map<String, dynamic>;
      panel['panel_domain'] = 'ccpanel.jiankong.cf';
      // panel_api_base 不写：fromJson 默认为 ''。
      final envelope = await keys.signEnvelope(payload);
      await prefs.setString(RemoteConfigService.cacheKey, envelope);
      final service = RemoteConfigService(
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final urls = await service.defaultConfigUrls();
      expect(urls[0], 'https://ccpanel.jiankong.cf/client-config.json');
      await prefs.remove(RemoteConfigService.cacheKey);
    });

    test('0.1.3：网络层失败每地址重试一次；404 不重试', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(RemoteConfigService.cacheKey);
      final envelope = await keys.signEnvelope(_payload(version: 6));
      // configUrlA：第一次断网、第二次 200；configUrlB：404。
      final calls = <String, int>{};
      Dio countingDio() {
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final url = options.uri.toString();
              calls[url] = (calls[url] ?? 0) + 1;
              if (url == configUrlA && calls[url] == 1) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.connectionError,
                  ),
                );
                return;
              }
              if (url == configUrlA) {
                handler.resolve(
                  Response<String>(
                    requestOptions: options,
                    statusCode: 200,
                    data: envelope,
                  ),
                );
                return;
              }
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response<String>(
                    requestOptions: options,
                    statusCode: 404,
                    data: '',
                  ),
                  type: DioExceptionType.badResponse,
                ),
              );
            },
          ),
        );
        return dio;
      }

      final service = RemoteConfigService(
        dio: countingDio(),
        configUrls: [configUrlB, configUrlA],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final result = await service.refresh();
      // B 先 404（只试一次），A 重试一次后拿到新版。
      expect(result.status, RemoteConfigRefreshStatus.updated);
      expect(result.config.configVersion, 6);
      expect(calls[configUrlB], 1);
      expect(calls[configUrlA], 2);
      await prefs.remove(RemoteConfigService.cacheKey);
    });

    test('0.1.3：开关已开时直连全败后经代理再试一轮', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(RemoteConfigService.cacheKey);
      final envelope = await keys.signEnvelope(_payload(version: 7));
      var proxyCalls = 0;
      final proxyDio = Dio();
      proxyDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            proxyCalls++;
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: envelope,
              ),
            );
          },
        ),
      );
      final service = RemoteConfigService(
        // 直连 Dio：表是空的，全部按断网算。
        dio: _configDio({}),
        proxyDio: proxyDio,
        configUrls: [configUrlA, configUrlB],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
        coreStarted: () => true,
      );
      final result = await service.refresh();
      expect(result.status, RemoteConfigRefreshStatus.updated);
      expect(result.config.configVersion, 7);
      // 代理轮只试了第一个地址就拿到了新版。
      expect(proxyCalls, 1);
      // 直连轮的两条失败照常记录，且都标直连（不是经代理）。
      expect(result.failures.length, 2);
      expect(result.failures.every((f) => !f.viaProxy), isTrue);
      await prefs.remove(RemoteConfigService.cacheKey);
    });

    test('0.1.3：开关没开时不跑代理轮；两轮都败时失败标“经代理”', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(RemoteConfigService.cacheKey);
      var proxyCalls = 0;
      final proxyDio = Dio();
      proxyDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            proxyCalls++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            );
          },
        ),
      );
      // 开关没开：代理 Dio 一次也不该被调；但 0.1.4 起跳过要留痕，
      // failures 里多一条 proxySkipped（不是地址尝试，不参与
      // notPublished 判定）。
      final offService = RemoteConfigService(
        dio: _configDio({}),
        proxyDio: proxyDio,
        configUrls: [configUrlA, configUrlB],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
        coreStarted: () => false,
      );
      final offResult = await offService.refresh();
      expect(offResult.status, RemoteConfigRefreshStatus.failed);
      expect(proxyCalls, 0);
      expect(offResult.failures.length, 3);
      expect(offResult.failures[2].kind, RemoteConfigFailureKind.proxySkipped);
      expect(offResult.failureMessage, contains('代理轮未跑'));

      // 开关开着、代理也败：两轮各两条失败，代理轮的标 viaProxy。
      final onService = RemoteConfigService(
        dio: _configDio({}),
        proxyDio: proxyDio,
        configUrls: [configUrlA, configUrlB],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
        coreStarted: () => true,
      );
      final onResult = await onService.refresh();
      expect(onResult.status, RemoteConfigRefreshStatus.failed);
      expect(onResult.failures.length, 4);
      expect(onResult.failures[0].viaProxy, isFalse);
      expect(onResult.failures[1].viaProxy, isFalse);
      expect(onResult.failures[2].viaProxy, isTrue);
      expect(onResult.failures[3].viaProxy, isTrue);
      expect(onResult.failureMessage, contains('（经代理）'));
      // 代理轮每地址各试两次（首次断网＋重试一次），共 4 次调用。
      expect(proxyCalls, 4);
    });

    test('0.1.4：无缓存时面板地址也进链（品牌 fallback :11111）', () async {
      // C 路 P0-1 的鸡生蛋：0.1.3 里无缓存 → panel_domain 是占位
      // 域名 → 面板地址整段跳过，派生修复只在有缓存后生效。
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(RemoteConfigService.cacheKey);
      final service = RemoteConfigService(prefs: prefs);
      final urls = await service.defaultConfigUrls();
      expect(
        urls[0],
        'https://ccpanel.jiankong.cf:11111/client-config.json',
      );
      expect(urls[1], RemoteConfigService.workerConfigUrl);
      expect(urls[2], RemoteConfigService.rawConfigUrl);
    });

    test('0.1.4：代理轮跳过直连已 404 的地址', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(RemoteConfigService.cacheKey);
      // 直连轮：A 404、B 断网；代理轮只该再试 B（A 再试也是 404）。
      final proxyUrls = <String>[];
      final proxyDio = Dio();
      proxyDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            proxyUrls.add(options.uri.toString());
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            );
          },
        ),
      );
      final service = RemoteConfigService(
        dio: _configDio({configUrlA: (status: 404, body: '')}),
        proxyDio: proxyDio,
        configUrls: [configUrlA, configUrlB],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
        coreStarted: () => true,
      );
      final result = await service.refresh();
      expect(result.status, RemoteConfigRefreshStatus.failed);
      // B 一次＋重试一次，共 2 次代理调用；A 一次也没经代理试过。
      expect(proxyUrls, [configUrlB, configUrlB]);
      // 失败：直连 A 404、直连 B 断网、代理 B 断网，共 3 条。
      expect(result.failures.length, 3);
      expect(
        result.failures.where((f) => f.viaProxy).map((f) => f.url),
        [configUrlB],
      );
      await prefs.remove(RemoteConfigService.cacheKey);
    });

    test('缓存被改坏就当作没有缓存', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RemoteConfigService.cacheKey,
        '{"config_version": 3, "signature": "AAAA"}',
      );
      final service = RemoteConfigService(
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      expect(await service.loadCached(), isNull);
      expect(prefs.getString(RemoteConfigService.cacheKey), isNull);
    });
  });

  group('RemoteConfigNotifier', () {
    const configUrl = 'http://127.0.0.1:18081/client-config.json';

    test('init：无缓存拉到新版 → fresh；全失败有缓存 → cached', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      final envelope = await keys.signEnvelope(_payload(version: 2));
      final service = RemoteConfigService(
        dio: _configDio({configUrl: (status: 200, body: envelope)}),
        configUrls: [configUrl],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final container = ProviderContainer(
        overrides: [remoteConfigServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      await container.read(remoteConfigProvider.notifier).init();
      var state = container.read(remoteConfigProvider);
      expect(state.source, RemoteConfigSource.fresh);
      expect(state.config.configVersion, 2);
      expect(state.offline, isFalse);

      // 第二轮：地址全挂，有缓存 → cached + offline。
      final failing = RemoteConfigService(
        dio: _configDio({}),
        configUrls: [configUrl],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final container2 = ProviderContainer(
        overrides: [remoteConfigServiceProvider.overrideWithValue(failing)],
      );
      addTearDown(container2.dispose);
      await container2.read(remoteConfigProvider.notifier).init();
      state = container2.read(remoteConfigProvider);
      expect(state.source, RemoteConfigSource.cached);
      expect(state.config.configVersion, 2);
      expect(state.offline, isTrue);
    });

    test('0.1.4：refresh 进行中再调，等同一轮结果，不合成 upToDate', () async {
      // C 路 P0-3 的旧 bug：启动拉取没跑完时点检查更新，直接回
      // 合成的 upToDate 配空 failures，全新安装显示“已是最新配置
      // （v0）”。现在第二次调用等正在跑的那轮，两次都拿到真结果。
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(RemoteConfigService.cacheKey);
      final envelope = await keys.signEnvelope(_payload(version: 8));
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: envelope,
              ),
            );
          },
        ),
      );
      final service = RemoteConfigService(
        dio: dio,
        configUrls: [configUrl],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final container = ProviderContainer(
        overrides: [remoteConfigServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(remoteConfigProvider.notifier);
      final first = notifier.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final second = notifier.refresh();
      final results = await Future.wait([first, second]);
      expect(results[0].status, RemoteConfigRefreshStatus.updated);
      expect(results[1].status, RemoteConfigRefreshStatus.updated);
      expect(results[0].config.configVersion, 8);
      expect(results[1].config.configVersion, 8);
      expect(container.read(remoteConfigProvider).source,
          RemoteConfigSource.fresh);
      await prefs.remove(RemoteConfigService.cacheKey);
    });

    test('0.1.4：启动拉取失败后核心起来了，再触发一次 refresh', () async {
      // C 路 P0-2：启动时后台拉取发生在核心启动前，代理轮恒跳过；
      // 核心 stopped → started 跃迁后，失败过的拉取要再试一次。
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(RemoteConfigService.cacheKey);
      final envelope = await keys.signEnvelope(_payload(version: 2));
      var calls = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            // 前两次调用（首轮直连＋重试一次）断网，之后通。
            if (calls <= 2) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                ),
              );
              return;
            }
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: envelope,
              ),
            );
          },
        ),
      );
      final service = RemoteConfigService(
        dio: dio,
        configUrls: [configUrl],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final plugin = _FakeCorePlugin();
      final core = CoreService(
        plugin: plugin,
        clashApiClient: _FakeCoreClashApi(),
        usingConfigPath: () async => '/tmp/014-test-no-such-config.json',
        realTrafficProbe: () async => true,
        probeWarmup: Duration.zero,
        probeRetryDelay: Duration.zero,
      );
      await core.init();
      final container = ProviderContainer(
        overrides: [
          remoteConfigServiceProvider.overrideWithValue(service),
          coreServiceProvider.overrideWithValue(core),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await plugin.close();
        core.dispose();
      });
      final notifier = container.read(remoteConfigProvider.notifier);
      await notifier.init();
      // 启动拉取失败：无缓存 → bundled v0。
      expect(container.read(remoteConfigProvider).source,
          RemoteConfigSource.bundled);
      // 核心起来 → 监听触发重拉，等它变成 fresh。
      plugin.emit(const ProxyStarted());
      var fresh = false;
      for (var i = 0; i < 50 && !fresh; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        fresh =
            container.read(remoteConfigProvider).source ==
                RemoteConfigSource.fresh;
      }
      expect(fresh, isTrue);
      expect(container.read(remoteConfigProvider).config.configVersion, 2);
      await prefs.remove(RemoteConfigService.cacheKey);
    });
  });

  group('订阅 404 重试（切片 7）', () {
    const token =
        'sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const oldBase = 'https://old.example.com/x9f2';
    const newBase = 'https://new.example.com/x9f2';
    const configUrl = 'http://127.0.0.1:18081/client-config.json';

    Future<ProviderContainer> buildContainer({
      required Dio subDio,
      required RemoteConfigService configService,
      required _FakeSecureStorage storage,
      required SharedPreferences prefs,
    }) async {
      final container = ProviderContainer(
        overrides: [
          subscriptionServiceProvider.overrideWithValue(
            SubscriptionService(dio: subDio, storage: storage),
          ),
          remoteConfigServiceProvider.overrideWithValue(configService),
          // 订阅列表走假存储＋测试偏好：不碰真安全存储的 MethodChannel。
          subscriptionStoreProvider.overrideWithValue(
            SubscriptionStore(storage: storage, prefs: prefs),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Dio subDio({required bool newBaseWorks}) {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            final url = options.uri.toString();
            if (url.startsWith(newBase)) {
              if (!newBaseWorks) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<String>(
                      requestOptions: options,
                      statusCode: 404,
                      data: '',
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }
              final body = await File(
                'test/fixtures/singbox_137.json',
              ).readAsString();
              handler.resolve(
                Response<String>(
                  requestOptions: options,
                  statusCode: 200,
                  data: body,
                ),
              );
              return;
            }
            // 旧地址：一律 404（令牌查无此人）。
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<String>(
                  requestOptions: options,
                  statusCode: 404,
                  data: '',
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );
      return dio;
    }

    test('旧地址 404 → 拉远程配置 → 新地址拉通，提示换地址', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final subService = SubscriptionService(
        dio: Dio(),
        storage: storage,
      );
      await subService.saveSubscriptionLink('$oldBase/$token');

      final envelope = await keys.signEnvelope(
        _payload(subscriptionUrl: '$newBase/$token'),
      );
      final configService = RemoteConfigService(
        dio: _configDio({configUrl: (status: 200, body: envelope)}),
        configUrls: [configUrl],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final container = await buildContainer(
        subDio: subDio(newBaseWorks: true),
        configService: configService,
        storage: storage,
        prefs: prefs,
      );
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.status, NodesStatus.loaded);
      expect(state.nodes, isNotEmpty);
      expect(state.addressNotice, contains('已自动切换到新地址'));
      // 本地绑定已换成新地址，令牌没变。
      final url = await subService.readSubscriptionUrl();
      expect(url, startsWith(newBase));
      expect(url, endsWith(token));
    });

    test('新地址也拉不通 → 报原错，本地绑定不动', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final subService = SubscriptionService(
        dio: Dio(),
        storage: storage,
      );
      await subService.saveSubscriptionLink('$oldBase/$token');

      final envelope = await keys.signEnvelope(
        _payload(subscriptionUrl: '$newBase/$token'),
      );
      final configService = RemoteConfigService(
        dio: _configDio({configUrl: (status: 200, body: envelope)}),
        configUrls: [configUrl],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final container = await buildContainer(
        subDio: subDio(newBaseWorks: false),
        configService: configService,
        storage: storage,
        prefs: prefs,
      );
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.status, NodesStatus.error);
      expect(state.errorMessage, '订阅链接不对或令牌不对，请检查链接或重新获取');
      final url = await subService.readSubscriptionUrl();
      expect(url, startsWith(oldBase));
    });

    test('备用地址：主地址拉不通时试备用地址', () async {
      final keys = _TempKeys();
      await keys.init();
      final prefs = await SharedPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final subService = SubscriptionService(
        dio: Dio(),
        storage: storage,
      );
      await subService.saveSubscriptionLink('$oldBase/$token');

      // 主订阅地址指向一个拉不通的域名，备用地址是新地址。
      const deadBase = 'https://dead.example.com/x9f2';
      final envelope = await keys.signEnvelope(
        _payload(
          subscriptionUrl: '$deadBase/$token',
          backupUrls: ['$newBase/$token'],
        ),
      );
      final configService = RemoteConfigService(
        dio: _configDio({configUrl: (status: 200, body: envelope)}),
        configUrls: [configUrl],
        prefs: prefs,
        publicKeyBase64: keys.publicKeyBase64,
      );
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            final url = options.uri.toString();
            if (url.startsWith(newBase)) {
              final body = await File(
                'test/fixtures/singbox_137.json',
              ).readAsString();
              handler.resolve(
                Response<String>(
                  requestOptions: options,
                  statusCode: 200,
                  data: body,
                ),
              );
              return;
            }
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<String>(
                  requestOptions: options,
                  statusCode: 404,
                  data: '',
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );
      final container = await buildContainer(
        subDio: dio,
        configService: configService,
        storage: storage,
        prefs: prefs,
      );
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.status, NodesStatus.loaded);
      expect(state.addressNotice, contains('已自动切换到新地址'));
    });
  });

  group('远程公告优先（切片 7）', () {
    test('有远程公告时不发 public-info 请求', () async {
      SharedPreferences.setMockInitialValues({
        'subscription_base_url': 'https://example.com/x9f2',
      });
      var requested = false;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requested = true;
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: {'login_notice': '面板公告'},
              ),
            );
          },
        ),
      );
      final service = AnnouncementService(
        dio: dio,
        remoteAnnouncement: () => '远程标题\n远程正文',
      );
      expect(await service.fetchNotice(), '远程标题\n远程正文');
      expect(requested, isFalse);
    });

    test('没有远程公告时回落 public-info', () async {
      SharedPreferences.setMockInitialValues({
        'subscription_base_url': 'https://example.com/x9f2',
      });
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: {'login_notice': '面板公告'},
              ),
            );
          },
        ),
      );
      final service = AnnouncementService(
        dio: dio,
        remoteAnnouncement: () => null,
      );
      expect(await service.fetchNotice(), '面板公告');
    });
  });

  group('强制更新判定', () {
    RemoteConfig config({required bool force, required String min}) {
      return RemoteConfig(
        configVersion: 1,
        minAppVersion: min,
        forceUpdate: force,
        brand: BrandConfig.defaults(),
        panelDomain: 'panel.example.com',
        panelApiBase: '',
        minPanelVersion: '1.3.29',
        subscriptionUrl: '',
        subscriptionBackupUrls: const [],
        subscriptionFormat: 'singbox',
        features: const RemoteConfigFeatures(),
      );
    }

    test('force_update 且当前版本低于最低版本才强制', () {
      // 当前客户端版本是 0.1.6（见 lib/brand/remote_config.dart）。
      expect(config(force: true, min: '0.2.0').forceUpdateRequired, isTrue);
      expect(config(force: true, min: '0.1.0').forceUpdateRequired, isFalse);
      expect(config(force: true, min: '0.0.9').forceUpdateRequired, isFalse);
      expect(config(force: false, min: '9.9.9').forceUpdateRequired, isFalse);
    });
  });

  group('download_url（切片 8）', () {
    test('顶层 download_url 解析与 round-trip', () {
      final json = _payload()
        ..['download_url'] = 'https://example.com/download';
      final config = RemoteConfig.fromJson(json);
      expect(config.downloadUrl, 'https://example.com/download');
      expect(
        RemoteConfig.fromJson(config.toJson()).downloadUrl,
        'https://example.com/download',
      );
    });

    test('没给 download_url 时为空串，升级弹窗只说明原因、不写地址', () {
      expect(RemoteConfig.fromJson(_payload()).downloadUrl, '');
      expect(RemoteConfig.defaults().downloadUrl, '');
    });
  });

  group('SubscriptionService.baseOf', () {
    test('完整链接去令牌、base 原样', () {
      expect(
        SubscriptionService.baseOf(
          'https://sub.example.com/x9f2/sub_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        ),
        'https://sub.example.com/x9f2',
      );
      expect(
        SubscriptionService.baseOf('https://sub2.example.com/x9f2'),
        'https://sub2.example.com/x9f2',
      );
      expect(SubscriptionService.baseOf('not-a-url'), '');
      expect(SubscriptionService.baseOf(''), '');
    });
  });
}
