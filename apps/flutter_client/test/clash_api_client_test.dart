// 切片 3：Clash API /traffic 流式读取的回归测试。
//
// 用本机真 HttpServer 伪造 sing-box 的 Clash API。
// 注意两个已实测的坑（不要按直觉改回）：
// - dart:io 的 HttpServer 会把 body 块缓冲到响应关闭才发出，
//   “写帧不关”的假流式服务器永远到不了客户端；所以假服务器
//   写完帧就关响应（流保持打开的性质已由阶段 0 对真 sing-box 验证）；
// - `Stream.timeout` 对 async* 源流不触发超时，超时逻辑在
//   ClashApiClient.trafficSample 里用手动 Timer 实现。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/core/clash_api_client.dart';

void main() {
  late HttpServer server;

  tearDown(() async {
    await server.close(force: true);
  });

  /// 起一个 /traffic 服务器：推两帧有效数据，中间夹一行坏数据，
  /// 然后关闭响应（见文件头注释：不关客户端收不到）。
  Future<String> startTrafficServer() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        if (request.uri.path != '/traffic') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final response = request.response;
        response.headers.contentType = ContentType.json;
        response.write('{"up":100,"down":200}\n');
        response.write('this is not json\n');
        response.write('{"up":300,"down":400}\n');
        await response.close();
      } catch (_) {
        // 测试结束时 tearDown 强制关服务器，写响应可能抛错，忽略。
      }
    });
    return 'http://127.0.0.1:${server.port}';
  }

  test('流式读取：逐帧出数，坏行跳过不中断', () async {
    final baseUrl = await startTrafficServer();
    final client = ClashApiClient(baseUrl: baseUrl);
    final samples = await client
        .trafficStream()
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(samples.length, 2);
    expect(samples[0].up, 100);
    expect(samples[0].down, 200);
    expect(samples[1].up, 300);
    expect(samples[1].down, 400);
  });

  test('trafficSample 只取一帧就关连接', () async {
    final baseUrl = await startTrafficServer();
    final client = ClashApiClient(baseUrl: baseUrl);
    final sample = await client.trafficSample();
    expect(sample.up, 100);
    expect(sample.down, 200);
  });

  test('/traffic 非 200 时流以错误结束', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    final client = ClashApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
    await expectLater(
      client.trafficStream().toList(),
      throwsA(isA<HttpException>()),
    );
  });

  test('核心没启动（端口连不上）时流以错误结束', () async {
    // 先占一个端口再关掉，拿到一个当前没人监听的端口。
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final client = ClashApiClient(baseUrl: 'http://127.0.0.1:$port');
    await expectLater(
      client.trafficStream().toList(),
      throwsA(isA<SocketException>()),
    );
  });

  test('trafficSample 超时无帧时抛 TimeoutException', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        // 发响应头（写一个空行，客户端跳过）后一直不推帧。
        request.response.write('\n');
        await request.response.flush();
        // 500ms 后正常关响应：让 trafficStream 的生成器在测试还在跑时
        // 干净走完，避免 tearDown 强关服务器时错误在测试结束后才冒出来
        // （测试框架会把它算成“测试完成后失败”）。
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await request.response.close();
      } catch (_) {
        // tearDown 强制关服务器时写响应可能抛错，忽略。
      }
    });
    final client = ClashApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
    await expectLater(
      client.trafficSample(timeout: const Duration(milliseconds: 200)),
      throwsA(isA<TimeoutException>()),
    );
    // 等服务器自己关响应、流走完再结束测试。
    await Future<void>.delayed(const Duration(seconds: 1));
  });

  group('proxyDelay / selectProxy / selectedProxy（切片 4）', () {
    /// 延迟/切换的假服务器：delay 按名字给数，PUT 记录 body。
    Future<(String, List<String>)> startProxyServer() async {
      final puts = <String>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          final segments = request.uri.pathSegments;
          if (request.method == 'GET' &&
              segments.length == 3 &&
              segments[0] == 'proxies' &&
              segments[2] == 'delay') {
            // 注意：pathSegments 已经是 percent 解码后的，中文名直接就是原文，
            // 再调 Uri.decodeComponent 会对 raw 非 ASCII 抛错（见复现）。
            final name = segments[1];
            final response = request.response;
            response.headers.contentType = ContentType.json;
            if (name == 'good-node') {
              response.write('{"delay":123}');
            } else if (name == '香港-中转') {
              // 中文名：客户端必须 URL 编码，编错了核心会 404。
              response.write('{"delay":88}');
            } else if (name == 'zero-node') {
              // delay 为 0 是 sing-box 的错误信号，不是 0 毫秒。
              response.write('{"delay":0}');
            } else if (name == 'missing-node') {
              response.statusCode = HttpStatus.notFound;
              response.write('{"message":"Resource not found"}');
            } else {
              response.statusCode = HttpStatus.serviceUnavailable;
              response.write(
                '{"message":"An error occurred in the delay test"}',
              );
            }
            await response.close();
            return;
          }
          if (request.method == 'PUT' &&
              segments.length == 2 &&
              segments[0] == 'proxies') {
            final body = await utf8.decoder.bind(request).join();
            puts.add(body);
            request.response.statusCode = HttpStatus.noContent;
            await request.response.close();
            return;
          }
          if (request.method == 'GET' &&
              segments.length == 2 &&
              segments[0] == 'proxies') {
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"now":"good-node"}');
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        } catch (_) {
          // tearDown 强制关服务器，写响应可能抛错，忽略。
        }
      });
      return ('http://127.0.0.1:${server.port}', puts);
    }

    test('proxyDelay：200 返回延迟，404/503/0 都是 null 不抛错', () async {
      final (baseUrl, _) = await startProxyServer();
      final client = ClashApiClient(baseUrl: baseUrl);
      expect(await client.proxyDelay('good-node'), 123);
      expect(await client.proxyDelay('missing-node'), isNull);
      expect(await client.proxyDelay('bad-node'), isNull);
      expect(await client.proxyDelay('zero-node'), isNull);
    });

    test('proxyDelay：中文名要 URL 编码，核心连不上返回 null', () async {
      final (baseUrl, _) = await startProxyServer();
      final client = ClashApiClient(baseUrl: baseUrl);
      // 名字里有中文：编码错了核心会 404，测不到。
      expect(await client.proxyDelay('香港-中转'), 88);

      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final down = ClashApiClient(baseUrl: 'http://127.0.0.1:$port');
      expect(await down.proxyDelay('good-node'), isNull);
    });

    test('selectProxy：PUT body 是 {"name": ...}，204 返回 true', () async {
      final (baseUrl, puts) = await startProxyServer();
      final client = ClashApiClient(baseUrl: baseUrl);
      expect(await client.selectProxy('Proxy', 'good-node'), isTrue);
      expect(puts, ['{"name":"good-node"}']);
    });

    test('selectProxy：核心连不上返回 false 不抛错', () async {
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final client = ClashApiClient(baseUrl: 'http://127.0.0.1:$port');
      expect(await client.selectProxy('Proxy', 'good-node'), isFalse);
    });

    test('selectedProxy：读 now 字段；非 200 返回 null', () async {
      final (baseUrl, _) = await startProxyServer();
      final client = ClashApiClient(baseUrl: baseUrl);
      expect(await client.selectedProxy('Proxy'), 'good-node');

      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final down = ClashApiClient(baseUrl: 'http://127.0.0.1:$port');
      expect(await down.selectedProxy('Proxy'), isNull);
    });
  });

  group('selectProxyDetailed / proxyDelayDetailed（问题 7）', () {
    /// 假服务器：PUT 到 MissingGroup 回 404（组本身不存在）、
    /// PUT body 名字是 not-in-group 回 400（sing-box 对组里没有的
    /// 名字就是这么回的，见真核复现）；delay 按名字给状态码。
    Future<String> startDetailedServer() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          final segments = request.uri.pathSegments;
          if (request.method == 'GET' &&
              segments.length == 3 &&
              segments[0] == 'proxies' &&
              segments[2] == 'delay') {
            final name = segments[1];
            final response = request.response;
            response.headers.contentType = ContentType.json;
            if (name == 'good-node') {
              response.write('{"delay":123}');
            } else if (name == 'missing-node') {
              response.statusCode = HttpStatus.notFound;
              response.write('{"message":"Resource not found"}');
            } else if (name == 'slow-node') {
              response.statusCode = HttpStatus.gatewayTimeout;
              response.write('{"message":"Timeout"}');
            } else {
              response.statusCode = HttpStatus.serviceUnavailable;
              response.write(
                '{"message":"An error occurred in the delay test"}',
              );
            }
            await response.close();
            return;
          }
          if (request.method == 'PUT' &&
              segments.length == 2 &&
              segments[0] == 'proxies') {
            final body = await utf8.decoder.bind(request).join();
            final parsed = jsonDecode(body) as Map<String, dynamic>;
            if (segments[1] == 'MissingGroup') {
              request.response.statusCode = HttpStatus.notFound;
            } else if (parsed['name'] == 'not-in-group') {
              request.response.statusCode = HttpStatus.badRequest;
              request.response.write(
                '{"message":"Selector update error: not found"}',
              );
            } else {
              request.response.statusCode = HttpStatus.noContent;
            }
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        } catch (_) {}
      });
      return 'http://127.0.0.1:${server.port}';
    }

    test('selectProxyDetailed：204 是 ok；400/404 是 notInGroup', () async {
      final baseUrl = await startDetailedServer();
      final client = ClashApiClient(baseUrl: baseUrl);
      final ok = await client.selectProxyDetailed('Proxy', 'good-node');
      expect(ok.ok, isTrue);
      expect(ok.failure, isNull);
      expect(ok.statusCode, HttpStatus.noContent);

      final notInGroup = await client.selectProxyDetailed(
        'Proxy',
        'not-in-group',
      );
      expect(notInGroup.ok, isFalse);
      expect(notInGroup.failure, ProxySelectFailure.notInGroup);
      expect(notInGroup.statusCode, HttpStatus.badRequest);

      final missingGroup = await client.selectProxyDetailed(
        'MissingGroup',
        'good-node',
      );
      expect(missingGroup.ok, isFalse);
      expect(missingGroup.failure, ProxySelectFailure.notInGroup);
      expect(missingGroup.statusCode, HttpStatus.notFound);
    });

    test('selectProxyDetailed：核心连不上是 apiUnreachable', () async {
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final down = ClashApiClient(baseUrl: 'http://127.0.0.1:$port');
      final result = await down.selectProxyDetailed('Proxy', 'good-node');
      expect(result.ok, isFalse);
      expect(result.failure, ProxySelectFailure.apiUnreachable);
      expect(result.statusCode, isNull);
    });

    test('proxyDelayDetailed：200/404/504/503 各有原因', () async {
      final baseUrl = await startDetailedServer();
      final client = ClashApiClient(baseUrl: baseUrl);
      final ok = await client.proxyDelayDetailed('good-node');
      expect(ok.delay, 123);
      expect(ok.failure, isNull);
      expect(ok.ok, isTrue);

      final missing = await client.proxyDelayDetailed('missing-node');
      expect(missing.delay, isNull);
      expect(missing.failure, ProxyDelayFailure.notFound);

      final slow = await client.proxyDelayDetailed('slow-node');
      expect(slow.delay, isNull);
      expect(slow.failure, ProxyDelayFailure.timeout);

      final bad = await client.proxyDelayDetailed('bad-node');
      expect(bad.delay, isNull);
      expect(bad.failure, ProxyDelayFailure.failed);
    });

    test('proxyDelayDetailed：核心连不上是 apiUnreachable', () async {
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final down = ClashApiClient(baseUrl: 'http://127.0.0.1:$port');
      final result = await down.proxyDelayDetailed('good-node');
      expect(result.delay, isNull);
      expect(result.failure, ProxyDelayFailure.apiUnreachable);
    });
  });

  group('0.1.2：10 秒预算、getConnections', () {
    test('proxyDelayDetailed：timeout=10000 发给服务端，Dart 侧等 15 秒', () async {
      // 服务端 11 秒后才回 200：Dart 侧超时是预算＋5 秒（15 秒），
      // 不会先超时误报 apiUnreachable；旧写法（预算＋5 秒按 5 秒算
      // 出 10 秒）会在 10 秒时先断。
      String? seenTimeout;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          seenTimeout = request.uri.queryParameters['timeout'];
          await Future<void>.delayed(const Duration(seconds: 11));
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"delay":123}');
          await request.response.close();
        } catch (_) {}
      });
      final client = ClashApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final result = await client.proxyDelayDetailed(
        'good-node',
        timeout: const Duration(seconds: 10),
      );
      expect(seenTimeout, '10000');
      expect(result.delay, 123);
      expect(result.failure, isNull);
    });

    test('getConnections：chain 拼成字符串；404/连不上返回空列表', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          final response = request.response;
          response.headers.contentType = ContentType.json;
          if (request.uri.path == '/connections') {
            response.write(
              '{"connections": ['
              '{"metadata": {"host": "example.com"}, "chains": ["Proxy", "直连节点", "direct"]}, '
              '{"metadata": {"host": "other.com"}, "chains": ["direct"]}, '
              '{"metadata": {"host": "nochain.com"}}'
              ']}',
            );
          } else {
            response.statusCode = HttpStatus.notFound;
          }
          await response.close();
        } catch (_) {}
      });
      final client = ClashApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      expect(await client.getConnections(), [
        'Proxy → 直连节点 → direct',
        'direct',
      ]);

      // 非 200：空列表，不抛错。
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final down = ClashApiClient(baseUrl: 'http://127.0.0.1:$port');
      expect(await down.getConnections(), isEmpty);
    });
  });
}
