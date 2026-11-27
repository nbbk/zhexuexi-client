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

/// 切换 selector 出站失败的原因（不要一律报“核心没有响应”：
/// 连不上与名字不在组里是两回事，界面提示要分清）。
enum ProxySelectFailure {
  /// 连不上 Clash API（核心没起、端口没监听、请求超时）。
  apiUnreachable,

  /// 组里没有这个出站（sing-box 回 400/404，如成组节点用了自身 tag）。
  notInGroup,

  /// 其他非 2xx（状态码见 [ProxySelectResult.statusCode]）。
  rejected,
}

/// 一次切换的结果。
class ProxySelectResult {
  const ProxySelectResult({required this.ok, this.failure, this.statusCode});

  /// 是否切过去了。
  final bool ok;

  /// 失败原因；成功时为 null。
  final ProxySelectFailure? failure;

  /// Clash API 回的状态码；连不上时为 null。
  final int? statusCode;
}

/// 一条实时连接的完整条目（`GET /connections` 的原始字段）。
///
/// `chains` 是路由追踪的出站链（叶子出站在首位，如
/// `['测试机-hy2-443-A', '测试机', 'Proxy']`）；`upload` /
/// `download` 是该连接累计的上下行字节（不是速率）。
class ConnectionEntry {
  const ConnectionEntry({
    required this.chains,
    required this.upload,
    required this.download,
  });

  /// 出站链（叶子在前）；空链的条目由 [ClashApiClient.getConnectionEntries]
  /// 直接丢掉，不进采样聚合。
  final List<String> chains;

  /// 该连接累计上行字节。
  final int upload;

  /// 该连接累计下行字节。
  final int download;
}

/// 一次 DNS 探针的结果（Clash API `GET /dns/query`）。
class DnsQueryResult {
  const DnsQueryResult({required this.ok, this.latencyMs, this.error});

  /// 是否查到（HTTP 200 且 DNS Rcode 为 0）。
  final bool ok;

  /// 往返耗时（毫秒）；失败时为 null。
  final int? latencyMs;

  /// 失败原因（人话，采样行直接用）；成功时为 null。
  final String? error;
}
enum ProxyDelayFailure {
  /// 连不上 Clash API（核心没起、端口没监听、请求超时）。
  apiUnreachable,

  /// 404：核心里没有这个出站。
  notFound,

  /// 408/504：规定时间内没测出延迟。
  timeout,

  /// 503/其他：出站存在但拨号或请求失败。
  failed,
}

/// 一次测速的结果。
class ProxyDelayResult {
  const ProxyDelayResult({this.delay, this.failure});

  /// 测到的延迟（毫秒）；测不到时为 null。
  final int? delay;

  /// 失败原因；测到时为 null。
  final ProxyDelayFailure? failure;

  /// 是否测到了延迟。
  bool get ok => delay != null;
}
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
  /// 要失败原因时用 [proxyDelayDetailed]。
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
    final result = await proxyDelayDetailed(
      proxyName,
      timeout: timeout,
    );
    return result.delay;
  }

  /// [proxyDelay] 的带原因版：测不到时 [ProxyDelayResult.failure]
  /// 说明是哪种失败（404 没有这个出站、408/504 超时、503 拨号失败、
  /// 连不上是核心没响应），调用方据此写失败原因。
  ///
  /// Dart 侧的 getUrl / 等响应超时必须是拨测预算＋5 秒，大于服务端
  /// 预算：服务端预算一到就回 408/504，Dart 必须等到那个响应；
  /// Dart 先超时会误报成 apiUnreachable（2026-11-26 启动拨测
  /// 预算放到 10 秒后这里跟着变成 15 秒，节点页手动测速仍是 5 秒
  /// 预算、这里仍是 10 秒，各走各的预算）。
  Future<ProxyDelayResult> proxyDelayDetailed(
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
      final httpTimeout = timeout + const Duration(seconds: 5);
      final request = await client.getUrl(uri).timeout(httpTimeout);
      final response = await request.close().timeout(httpTimeout);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == HttpStatus.notFound) {
        return const ProxyDelayResult(failure: ProxyDelayFailure.notFound);
      }
      if (response.statusCode == HttpStatus.requestTimeout ||
          response.statusCode == HttpStatus.gatewayTimeout) {
        return const ProxyDelayResult(failure: ProxyDelayFailure.timeout);
      }
      if (response.statusCode != HttpStatus.ok) {
        return const ProxyDelayResult(failure: ProxyDelayFailure.failed);
      }
      final parsed = jsonDecode(body);
      if (parsed is! Map<String, dynamic>) {
        return const ProxyDelayResult(failure: ProxyDelayFailure.failed);
      }
      final delay = parsed['delay'];
      // delay 为 0 不是“0 毫秒”，是 sing-box 的错误信号（上游
      // delay==0 时直接回 503，这里只是兜底）；负数同理。
      if (delay is! num || delay <= 0) {
        return const ProxyDelayResult(failure: ProxyDelayFailure.failed);
      }
      return ProxyDelayResult(delay: delay.toInt());
    } catch (_) {
      return const ProxyDelayResult(
        failure: ProxyDelayFailure.apiUnreachable,
      );
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
  /// 要失败原因时用 [selectProxyDetailed]。
  Future<bool> selectProxy(String groupName, String proxyName) async {
    final result = await selectProxyDetailed(groupName, proxyName);
    return result.ok;
  }

  /// [selectProxy] 的带原因版：失败时区分“核心没有响应”
  /// （[ProxySelectFailure.apiUnreachable]，连不上）与“节点不在
  /// 运行配置里”（[ProxySelectFailure.notInGroup]，sing-box 回
  /// 400/404），不要一律报“核心没有响应”。
  Future<ProxySelectResult> selectProxyDetailed(
    String groupName,
    String proxyName,
  ) async {
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
      final statusCode = response.statusCode;
      if (statusCode == HttpStatus.noContent ||
          statusCode == HttpStatus.ok) {
        return ProxySelectResult(ok: true, statusCode: statusCode);
      }
      if (statusCode == HttpStatus.badRequest ||
          statusCode == HttpStatus.notFound) {
        return ProxySelectResult(
          ok: false,
          failure: ProxySelectFailure.notInGroup,
          statusCode: statusCode,
        );
      }
      return ProxySelectResult(
        ok: false,
        failure: ProxySelectFailure.rejected,
        statusCode: statusCode,
      );
    } catch (_) {
      return const ProxySelectResult(
        ok: false,
        failure: ProxySelectFailure.apiUnreachable,
      );
    } finally {
      client.close();
    }
  }

  /// 实时连接的完整条目（`GET /connections`，2026-11-27 0.1.9
  /// 采样时序）：每条含 chain、累计上下行字节；核心没跑、接口不通或
  /// 回包解析失败时返回空列表，不抛异常。空 chain 的条目直接丢掉。
  Future<List<ConnectionEntry>> getConnectionEntries() async {
    final client = _httpClientFactory();
    try {
      final uri = Uri.parse('$_baseUrl/connections');
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) return const [];
      final parsed = jsonDecode(body);
      if (parsed is! Map<String, dynamic>) return const [];
      final connections = parsed['connections'];
      if (connections is! List) return const [];
      final entries = <ConnectionEntry>[];
      for (final entry in connections) {
        if (entry is! Map<String, dynamic>) continue;
        final chain = entry['chains'];
        if (chain is! List || chain.isEmpty) continue;
        entries.add(
          ConnectionEntry(
            chains: chain.map((e) => e.toString()).toList(),
            upload: (entry['upload'] as num?)?.toInt() ?? 0,
            download: (entry['download'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      return entries;
    } catch (_) {
      return const [];
    } finally {
      client.close();
    }
  }

  /// DNS 探针（2026-11-27 0.1.9 采样时序）：`GET /dns/query?name=…&type=A`，
  /// 走核心的 DNS 规则选服务器（不经过 Dart 侧 DNS）。
  ///
  /// Dart 侧超时 15 秒，大于服务端 `DNSTimeout = 10s`
  ///（`constant/timeout.go:11`）：服务端预算一到先回 500，Dart 必须
  /// 等到那个响应；Dart 先超时会把“服务端已判失败”误报成“连不上”。
  /// 成功只认 HTTP 200 且回包 `Status`（DNS Rcode）为 0；其余一律
  /// 失败（原因写进 [DnsQueryResult.error]），不抛异常。
  Future<DnsQueryResult> queryDns(
    String name, {
    String type = 'A',
  }) async {
    final stopwatch = Stopwatch()..start();
    final client = _httpClientFactory();
    try {
      final uri = Uri.parse(
        '$_baseUrl/dns/query?name=${Uri.encodeQueryComponent(name)}'
        '&type=${Uri.encodeQueryComponent(type)}',
      );
      const timeout = Duration(seconds: 15);
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();
      stopwatch.stop();
      if (response.statusCode != HttpStatus.ok) {
        return DnsQueryResult(
          ok: false,
          error: 'HTTP ${response.statusCode}',
        );
      }
      final parsed = jsonDecode(body);
      if (parsed is! Map<String, dynamic>) {
        return const DnsQueryResult(ok: false, error: '回包不是 JSON');
      }
      final status = parsed['Status'];
      if (status is num && status != 0) {
        return DnsQueryResult(ok: false, error: 'DNS Rcode $status');
      }
      if (status is! num) {
        return const DnsQueryResult(ok: false, error: '回包无 Status 字段');
      }
      return DnsQueryResult(ok: true, latencyMs: stopwatch.elapsedMilliseconds);
    } catch (e) {
      stopwatch.stop();
      if (e is TimeoutException) {
        return const DnsQueryResult(ok: false, error: '15 秒超时');
      }
      return const DnsQueryResult(ok: false, error: '控制接口无响应');
    } finally {
      client.close();
    }
  }

  /// 实时连接的 chain 列表（`GET /connections`，2026-11-26 0.1.2
  /// P0-4 诊断可见性）：每条连接一条字符串，chain 用 ` → ` 拼起来
  ///（如 `Proxy → 直连节点 → direct`）；核心没跑、接口不通或
  /// 回包解析失败时返回空列表，不抛异常。
  Future<List<String>> getConnections() async {
    final entries = await getConnectionEntries();
    return entries.map((e) => e.chains.join(' → ')).toList();
  }

  /// 读 selector 组 [groupName] 当前选中的出站名（`now` 字段）；
  /// 读不到返回 null。供界面确认切换结果用。
  Future<String?> selectedProxy(String groupName) async {    final client = _httpClientFactory();
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
