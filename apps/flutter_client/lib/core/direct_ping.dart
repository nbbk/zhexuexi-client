import 'dart:async';
import 'dart:io';

/// 开关关着时的测速：直连探测节点地址的 TCP 连通延迟。
///
/// 不走 sing-box 核心、不走 Clash API，只对 [Node.address]:[Node.port]
/// 做一次 TCP 连接并记耗时：
/// - 连通成功：耗时就是延迟；
/// - 被快速拒绝（RST，如 HY2/TUIC 的 UDP 端口拿 TCP 去连）：拒绝本身
///   回得快，耗时仍能反映到服务器的网络延迟，算可达、不算失败；
/// - 超时才算失败（[DirectProbeFailure.timeout]）；
/// - 其他错误（DNS 解析失败、网络不可达等）算失败
///   （[DirectProbeFailure.other]），与超时区分开。
///
/// 注意：这与开关开着时 Clash API 测出来的“走代理的延迟”不是同一口径
/// ——直连延迟只量到服务器的网络耗时，不含协议握手与代理转发；两个数
/// 不能直接比（见 nodes_page.dart 的提示文案）。

/// 直连探测失败的原因（给用户看的短句见 [DirectProbeFailureLabel]）。
enum DirectProbeFailure {
  /// 超时：规定时间内服务器没有任何响应（TCP 握手没回包），
  /// 最可能是服务器不可达。
  timeout,

  /// 其他连接错误：DNS 解析失败、网络不可达、地址/端口非法等。
  other,
}

extension DirectProbeFailureLabel on DirectProbeFailure {
  /// 给用户看的失败原因短句（节点行 tooltip 与测速汇总用）。
  String get label => switch (this) {
    DirectProbeFailure.timeout => '超时不可达',
    DirectProbeFailure.other => '连接失败',
  };
}

/// 一次直连探测的结果：可达时 [latencyMs] 有值，失败时 [failure] 有值，
/// 两者有且仅有一个有值。
class DirectProbeResult {
  const DirectProbeResult.reachable(this.latencyMs) : failure = null;

  const DirectProbeResult.failed(this.failure) : latencyMs = null;

  /// 可达时的延迟（毫秒）；失败时为 null。
  final int? latencyMs;

  /// 失败原因；可达时为 null。
  final DirectProbeFailure? failure;

  bool get isReachable => latencyMs != null;
}

/// 一次 TCP 连接尝试：连上后由实现方负责关闭连接。
///
/// 默认实现见 [_defaultConnect]（真 [Socket.connect]）。
/// 抽成 typedef 是为了测试：单测可以直接给“立即成功 / 立即拒绝 /
/// 永远不回包”的假实现，不用等真网络超时。
typedef DirectConnect =
    Future<void> Function(String host, int port, {Duration? timeout});

Future<void> _defaultConnect(
  String host,
  int port, {
  Duration? timeout,
}) async {
  final socket = await Socket.connect(host, port, timeout: timeout);
  // 只量握手耗时：连上立刻关，不发任何数据。
  socket.destroy();
}

/// 对 [host]:[port] 做一次直连 TCP 探测。
///
/// [timeout] 是单次探测的上限（默认 5 秒，与 Clash API 测速的超时一致）。
/// [connect] 只给测试用，生产代码不要传。
Future<DirectProbeResult> probeDirectLatency(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 5),
  DirectConnect connect = _defaultConnect,
}) async {
  if (host.isEmpty || port <= 0 || port > 65535) {
    return const DirectProbeResult.failed(DirectProbeFailure.other);
  }
  final stopwatch = Stopwatch()..start();
  try {
    await connect(host, port, timeout: timeout).timeout(timeout);
    return DirectProbeResult.reachable(stopwatch.elapsedMilliseconds);
  } on TimeoutException {
    return const DirectProbeResult.failed(DirectProbeFailure.timeout);
  } on SocketException catch (e) {
    // 被拒绝（RST）算可达：对方回包了，耗时就是网络延迟。
    // 拒绝在各平台的错误码不同：Linux 111、macOS/iOS 61、Windows 10061；
    // osError 为空的假实现按文案认（见 direct_ping_test.dart）。
    if (_isRefused(e)) {
      return DirectProbeResult.reachable(stopwatch.elapsedMilliseconds);
    }
    if (_isTimeout(e)) {
      return const DirectProbeResult.failed(DirectProbeFailure.timeout);
    }
    return const DirectProbeResult.failed(DirectProbeFailure.other);
  } catch (_) {
    return const DirectProbeResult.failed(DirectProbeFailure.other);
  }
}

bool _isRefused(SocketException e) {
  final code = e.osError?.errorCode;
  if (code == 111 || code == 61 || code == 10061) return true;
  return e.message.toLowerCase().contains('refused');
}

bool _isTimeout(SocketException e) {
  final code = e.osError?.errorCode;
  if (code == 110) return true;
  final message = e.message.toLowerCase();
  return message.contains('timed out');
}
