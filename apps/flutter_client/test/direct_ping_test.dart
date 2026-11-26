// 直连探测（开关关着时的测速）的单测：成功、快速拒绝、超时三种情况。
//
// 成功与拒绝走真回环 TCP（本机 ServerSocket / 关掉的端口），
// 超时与各类 SocketException 走假 connect，不等真网络。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/core/direct_ping.dart';

void main() {
  test('连通成功：返回耗时（毫秒），失败原因为空', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final result = await probeDirectLatency(
      '127.0.0.1',
      server.port,
    );
    expect(result.isReachable, isTrue);
    expect(result.latencyMs, isNotNull);
    expect(result.latencyMs, greaterThanOrEqualTo(0));
    expect(result.latencyMs, lessThan(5000));
    expect(result.failure, isNull);
  });

  test('快速拒绝：TCP 被 RST 也算可达，耗时照样能反映网络延迟', () async {
    // 先占一个端口再关掉：连它一定被拒绝，不会悬着等超时。
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    final result = await probeDirectLatency('127.0.0.1', port);
    expect(result.isReachable, isTrue);
    expect(result.latencyMs, isNotNull);
    expect(result.latencyMs, lessThan(5000));
    expect(result.failure, isNull);
  });

  test('快速拒绝（假 connect 抛 refused）：按错误码/文案认成可达', () async {
    Future<void> refused(
      String host,
      int port, {
      Duration? timeout,
    }) async {
      throw const SocketException(
        'Connection refused',
        osError: OSError('Connection refused', 111),
      );
    }

    final result = await probeDirectLatency(
      '203.0.113.1',
      443,
      connect: refused,
    );
    expect(result.isReachable, isTrue);
    expect(result.latencyMs, isNotNull);
    expect(result.failure, isNull);
  });

  test('超时：规定时间内没回包就报超时不可达，不无限等', () async {
    Future<void> never(
      String host,
      int port, {
      Duration? timeout,
    }) => Completer<void>().future;

    final stopwatch = Stopwatch()..start();
    final result = await probeDirectLatency(
      '203.0.113.1',
      443,
      timeout: const Duration(milliseconds: 200),
      connect: never,
    );
    stopwatch.stop();
    expect(result.isReachable, isFalse);
    expect(result.latencyMs, isNull);
    expect(result.failure, DirectProbeFailure.timeout);
    expect(result.failure?.label, '超时不可达');
    // 200ms 超时就要回，不该拖到秒级。
    expect(stopwatch.elapsedMilliseconds, lessThan(2000));
  });

  test('超时（假 connect 抛 TimeoutException）：同样报超时不可达', () async {
    Future<void> timesOut(
      String host,
      int port, {
      Duration? timeout,
    }) async {
      throw TimeoutException('connect timed out', timeout);
    }

    final result = await probeDirectLatency(
      '203.0.113.1',
      443,
      connect: timesOut,
    );
    expect(result.failure, DirectProbeFailure.timeout);
  });

  test('超时（SocketException timed out，按 110 错误码认）', () async {
    Future<void> timesOut(
      String host,
      int port, {
      Duration? timeout,
    }) async {
      throw const SocketException(
        'Connection timed out',
        osError: OSError('Connection timed out', 110),
      );
    }

    final result = await probeDirectLatency(
      '203.0.113.1',
      443,
      connect: timesOut,
    );
    expect(result.failure, DirectProbeFailure.timeout);
  });

  test('其他错误（DNS/网络不可达）：报连接失败，与超时区分开', () async {
    Future<void> unreachable(
      String host,
      int port, {
      Duration? timeout,
    }) async {
      throw const SocketException(
        'Network is unreachable',
        osError: OSError('Network is unreachable', 101),
      );
    }

    final result = await probeDirectLatency(
      '203.0.113.1',
      443,
      connect: unreachable,
    );
    expect(result.isReachable, isFalse);
    expect(result.failure, DirectProbeFailure.other);
    expect(result.failure?.label, '连接失败');
  });

  test('地址/端口非法：直接报连接失败，不抛异常', () async {
    expect(
      (await probeDirectLatency('', 443)).failure,
      DirectProbeFailure.other,
    );
    expect(
      (await probeDirectLatency('127.0.0.1', 0)).failure,
      DirectProbeFailure.other,
    );
    expect(
      (await probeDirectLatency('127.0.0.1', 70000)).failure,
      DirectProbeFailure.other,
    );
  });
}
