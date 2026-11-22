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

/// sing-box 内置 Clash API 的最小客户端（切片 3：首页实时速率；
/// 切片 4：测速与选出站）。
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

  /// 单个出站的延迟（毫秒）；测不到返回 null（调用方当“测速失败”标灰，
  /// 不抛异常——一键测速要的是一张完整的表，不是第一个失败就炸掉）。
  ///
  /// 走 Clash API `GET /proxies/{name}/delay?url=...&timeout=...`。
  /// 两个实测出来的坑（真 sing-box 1.14.4 验过，不要按直觉改回）：
  /// - 测速地址必须是 **https**：sing-box 1.14.4 的 delay 处理里
  ///   `http://` 开头的 url 会被直接清空（见上游
  ///   experimental/clashapi/proxies.go `getProxyDelay`），http 测速
  ///   永远 503；所以这里固定用 https://www.gstatic.com/generate_204，
  ///   与配置里 urltest 组的 http 地址不是同一个（组里用 http 没问题，
  ///   只有 delay 接口有这个限制）；
  /// - 超时是毫秒整数，sing-box 按 16 位解析，超过 32767 会 400，
  ///   调用方不要传更大的 timeout。
  /// 200 且 `delay` 为非负整数时返回延迟；404（没有这个出站）、408
  /// （超时）、503（测速失败）与任何网络异常都返回 null。
  static const String speedTestUrl = 'https://www.gstatic.com/generate_204';

  Future<int?> proxyDelay(
    String proxyName, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = _httpClientFactory();
    try {
      final uri = Uri.parse(
        '$_baseUrl/proxies/${Uri.encodeComponent(proxyName)}/delay'
        '?url=${Uri.encodeQueryComponent(speedTestUrl)}'
        '&timeout=${timeout.inMilliseconds}',
      );
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) return null;
      final parsed = jsonDecode(body);
      if (parsed is! Map<String, dynamic>) return null;
      final delay = parsed['delay'];
      // delay 为 0 不是“0 毫秒”，是 sing-box 的错误信号（上游
      // delay==0 时直接回 503，这里只是兜底）；负数同理。
      if (delay is! num || delay <= 0) return null;
      return delay.toInt();
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 把 selector 组 [groupName] 的当前出站切到 [proxyName]。
  ///
  /// 走 Clash API `PUT /proxies/{group}`，body `{"name": ...}`；
  /// 204（sing-box 1.14.4 实测）或 200 返回 true，其余状态码与
  /// 网络异常返回 false。切换只改运行时选择，不改磁盘配置——
  /// 要落盘见 [CoreService.updateSelectorDefault]。
  Future<bool> selectProxy(String groupName, String proxyName) async {
    final client = _httpClientFactory();
    try {
      final uri = Uri.parse(
        '$_baseUrl/proxies/${Uri.encodeComponent(groupName)}',
      );
      final request = await client.putUrl(uri).timeout(
        const Duration(seconds: 10),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'name': proxyName}));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.noContent ||
          response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// 读 selector 组 [groupName] 当前选中的出站名（`now` 字段）；
  /// 读不到返回 null。供界面确认切换结果用。
  Future<String?> selectedProxy(String groupName) async {
    final client = _httpClientFactory();
    try {
      final uri = Uri.parse(
        '$_baseUrl/proxies/${Uri.encodeComponent(groupName)}',
      );
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) return null;
      final parsed = jsonDecode(body);
      if (parsed is! Map<String, dynamic>) return null;
      final now = parsed['now'];
      return now is String && now.isNotEmpty ? now : null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }
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
