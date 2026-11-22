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
        await Future<void>.delayed(const Duration(seconds: 30));
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
  });
}
