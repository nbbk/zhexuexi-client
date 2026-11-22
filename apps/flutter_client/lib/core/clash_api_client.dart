import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一帧实时流量：`up` / `down` 是字节/秒（Clash API `/traffic` 的口径）。
class TrafficSample {
  const TrafficSample({required this.up, required this.down});

  final int up;
  final int down;

  @override
  String toString() => 'TrafficSample(up=$up, down=$down)';
}

/// sing-box 内置 Clash API 的最小客户端（切片 3：首页实时速率）。
///
/// 只读 `/traffic`（流式，每秒推一帧）；测速与选出站在切片 4。
/// 实现按阶段 0 的验证脚本 `docs/validation/stage0/clash_client.dart`：
/// `/traffic` 是流式接口、永不关闭，只能逐行读，不能等流结束；
/// 核心没启动时 127.0.0.1:9090 连不上，流直接以错误结束，调用方
/// 把速率显示回“—”即可。
/// 注意：这是**本机核心**的实时速率，不是面板 userinfo 的用量——
/// 两者口径不同，对不上时以面板为准（见客户端方案 §7）。
class ClashApiClient {
  ClashApiClient({
    this._baseUrl = 'http://127.0.0.1:9090',
    HttpClient Function()? httpClientFactory,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final String _baseUrl;
  final HttpClient Function() _httpClientFactory;

  /// 实时流量流：每秒一帧，核心停止或连接断开时流结束（可能带错误）。
  /// 坏行（空行、非法 JSON、缺字段）直接跳过，不中断流。
  Stream<TrafficSample> trafficStream() async* {
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(Uri.parse('$_baseUrl/traffic'));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Clash API /traffic 返回 ${response.statusCode}',
        );
      }
      await for (final line in response
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final sample = _parseLine(line);
        if (sample != null) yield sample;
      }
    } finally {
      client.close();
    }
  }

  /// 只取一帧采样（诊断与测试用；超时无帧时抛 [TimeoutException]）。
  ///
  /// 注意：不能用 `Stream.timeout`——它对 async* 源流不触发超时
  /// （实测：源流永不推帧时 `.timeout().first` 一直挂住，见
  /// /tmp/dbg_timeout2.dart）；这里用手动 [Timer] 实现超时。
  Future<TrafficSample> trafficSample({
    Duration timeout = const Duration(seconds: 5),
  }) {
    final completer = Completer<TrafficSample>();
    late final StreamSubscription<TrafficSample> sub;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('Clash API /traffic 超时无帧', timeout),
        );
        unawaited(sub.cancel());
      }
    });
    sub = trafficStream().listen(
      (sample) {
        if (!completer.isCompleted) completer.complete(sample);
        timer.cancel();
        unawaited(sub.cancel());
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
        timer.cancel();
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Clash API /traffic 未推帧就断开'),
          );
        }
        timer.cancel();
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  static TrafficSample? _parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      final parsed = jsonDecode(trimmed);
      if (parsed is! Map<String, dynamic>) return null;
      return TrafficSample(
        up: (parsed['up'] as num?)?.toInt() ?? 0,
        down: (parsed['down'] as num?)?.toInt() ?? 0,
      );
    } on FormatException {
      return null;
    }
  }
}
