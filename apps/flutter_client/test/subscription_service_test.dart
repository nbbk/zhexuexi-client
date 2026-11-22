// 切片 1：订阅拉取服务测试（回退链、状态码映射、链接拆存）。
//
// 不碰真面板：Dio 用拦截器伪造响应；令牌用内存假安全存储；
// 地址用 SharedPreferences mock。fixture 见 test/fixtures/。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/services/subscription_parser.dart';
import 'package:zhexuexi_client/services/subscription_service.dart';

class _FakeSecureStorage extends FlutterSecureStorage {
  final _map = <String, String>{};

  @override
  Future<String?> read({required String key, AndroidOptions? aOptions, AppleOptions? iOptions, LinuxOptions? lOptions, WindowsOptions? wOptions, WebOptions? webOptions, AppleOptions? mOptions}) async => _map[key];

  @override
  Future<void> write({required String key, required String? value, AndroidOptions? aOptions, AppleOptions? iOptions, LinuxOptions? lOptions, WindowsOptions? wOptions, WebOptions? webOptions, AppleOptions? mOptions}) async {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }

  @override
  Future<void> delete({required String key, AndroidOptions? aOptions, AppleOptions? iOptions, LinuxOptions? lOptions, WindowsOptions? wOptions, WebOptions? webOptions, AppleOptions? mOptions}) async {
    _map.remove(key);
  }
}

/// 按 `?format=` 返回不同正文/状态的假 Dio。
Dio _fakeDio(Map<String, ({int status, String body, Map<String, String> headers})> byFormat, {void Function()? onRequest}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        onRequest?.call();
        final format = options.uri.queryParameters['format'] ?? 'singbox';
        final fake = byFormat[format] ?? byFormat['singbox']!;
        final response = Response<String>(
          requestOptions: options,
          statusCode: fake.status,
          data: fake.body,
          headers: Headers.fromMap(
            fake.headers.map((k, v) => MapEntry(k, [v])),
          ),
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

void main() {
  const url = 'https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('fetchNodes', () {
    test('200 singbox：4 节点 + userinfo 头 + 格式 singbox', () async {
      final body = await File('test/fixtures/singbox_137.json').readAsString();
      final service = SubscriptionService(
        dio: _fakeDio({
          'singbox': (
            status: 200,
            body: body,
            headers: {
              'subscription-userinfo':
                  'upload=100; download=200; total=1000; expire=1798765432',
            },
          ),
        }),
        storage: _FakeSecureStorage(),
      );
      final result = await service.fetchNodes(subscriptionUrl: url);
      expect(result.nodes.length, 4);
      expect(result.failedCount, 1);
      expect(result.format, SubscriptionFormat.singbox);
      expect(result.userinfo?.used, 300);
      expect(result.userinfo?.total, 1000);
      expect(result.userinfo?.expire, 1798765432);
      expect(result.nodes[0].protocol, NodeProtocol.vless);
    });

    test('singbox 正文解析失败 → 回退 base64 成功', () async {
      final base64Body = await File(
        'test/fixtures/links_base64.txt',
      ).readAsString();
      var calls = 0;
      final service = SubscriptionService(
        dio: _fakeDio(
          {
            'singbox': (status: 200, body: 'this is not json', headers: {}),
            'base64': (status: 200, body: base64Body, headers: {}),
          },
          onRequest: () => calls++,
        ),
        storage: _FakeSecureStorage(),
      );
      final result = await service.fetchNodes(subscriptionUrl: url);
      expect(result.format, SubscriptionFormat.base64);
      expect(result.nodes.length, 5);
      expect(calls, 2);
    });

    test('三种格式都解析失败 → 抛 parseFailed', () async {
      final service = SubscriptionService(
        dio: _fakeDio({
          'singbox': (status: 200, body: 'garbage', headers: {}),
          'base64': (status: 200, body: 'garbage', headers: {}),
          'clash': (status: 200, body: 'garbage', headers: {}),
        }),
        storage: _FakeSecureStorage(),
      );
      expect(
        () => service.fetchNodes(subscriptionUrl: url),
        throwsA(
          isA<SubscriptionException>().having(
            (e) => e.kind,
            'kind',
            SubscriptionErrorKind.parseFailed,
          ),
        ),
      );
    });

    test('404 不回退，直接报“订阅已失效，请重新绑定”', () async {
      var calls = 0;
      final service = SubscriptionService(
        dio: _fakeDio(
          {'singbox': (status: 404, body: '', headers: {})},
          onRequest: () => calls++,
        ),
        storage: _FakeSecureStorage(),
      );
      await expectLater(
        () => service.fetchNodes(subscriptionUrl: url),
        throwsA(
          isA<SubscriptionException>()
              .having(
                (e) => e.kind,
                'kind',
                SubscriptionErrorKind.invalid,
              )
              .having(
                (e) => e.message,
                'message',
                '订阅已失效，请重新绑定',
              ),
        ),
      );
      expect(calls, 1);
    });

    test('410 报“订阅已到期”', () async {
      final service = SubscriptionService(
        dio: _fakeDio({'singbox': (status: 410, body: '', headers: {})}),
        storage: _FakeSecureStorage(),
      );
      expect(
        () => service.fetchNodes(subscriptionUrl: url),
        throwsA(
          isA<SubscriptionException>().having(
            (e) => e.kind,
            'kind',
            SubscriptionErrorKind.expired,
          ),
        ),
      );
    });

    test('429 带 Retry-After，报 rateLimited 且退避 600 秒', () async {
      final service = SubscriptionService(
        dio: _fakeDio({
          'singbox': (
            status: 429,
            body: '',
            headers: {'retry-after': '600'},
          ),
        }),
        storage: _FakeSecureStorage(),
      );
      expect(
        () => service.fetchNodes(subscriptionUrl: url),
        throwsA(
          isA<SubscriptionException>()
              .having(
                (e) => e.kind,
                'kind',
                SubscriptionErrorKind.rateLimited,
              )
              .having(
                (e) => e.retryAfterSeconds,
                'retryAfterSeconds',
                600,
              ),
        ),
      );
    });
  });

  group('订阅链接拆存', () {
    test('保存完整链接：地址进 prefs、令牌进安全存储，读回能拼回', () async {
      final storage = _FakeSecureStorage();
      final service = SubscriptionService(dio: Dio(), storage: storage);
      await service.saveSubscriptionLink(url);
      expect(await service.hasBinding(), isTrue);
      expect(await service.readSubscriptionUrl(), url);
      expect(await storage.read(key: 'subscription_token'), url.split('/').last);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('subscription_base_url'), 'https://example.com/x9f2');
    });

    test('链接不对（无 sub_ 令牌）直接报错', () async {
      final service = SubscriptionService(
        dio: Dio(),
        storage: _FakeSecureStorage(),
      );
      expect(
        () => service.saveSubscriptionLink('https://example.com/x9f2/notatoken'),
        throwsA(isA<SubscriptionException>()),
      );
      expect(await service.hasBinding(), isFalse);
    });

    test('clearBinding 后地址与令牌一起清掉', () async {
      final service = SubscriptionService(
        dio: Dio(),
        storage: _FakeSecureStorage(),
      );
      await service.saveSubscriptionLink(url);
      await service.clearBinding();
      expect(await service.hasBinding(), isFalse);
      expect(await service.readSubscriptionUrl(), isNull);
    });
  });
}
