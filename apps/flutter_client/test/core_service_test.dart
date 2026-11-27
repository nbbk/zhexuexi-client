// 切片 2：CoreService 接线的回归测试。
//
// 插件、校验器、配置路径、建档案四处全部可注入 fake，不碰平台通道、
// 不碰 MMKV、不碰 path_provider；配置写临时目录。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_sing_box/flutter_sing_box.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/core/clash_api_client.dart';
import 'package:zhexuexi_client/core/config_validator.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/singbox_core.dart';

/// 插件 fake：只记调用、不碰平台通道，状态由测试手动推。
class _FakePlugin extends FlutterSingBox {
  final _stateController = StreamController<ProxyState>.broadcast();
  final _logController = StreamController<List<ClientLog>>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int reloadCalls = 0;

  @override
  Stream<ProxyState> get proxyStateStream => _stateController.stream;

  // 0.1.9：日志流也桩掉——真实现的 logStream 走 EventChannel，
  // 纯 test() 里 ServicesBinding 未初始化，listen 会抛错。
  @override
  Stream<List<ClientLog>> get logStream => _logController.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> startVpn() async {
    startCalls++;
    _stateController.add(const ProxyStarted());
  }

  @override
  Future<void> stopVpn() async {
    stopCalls++;
    _stateController.add(const ProxyStopped());
  }

  @override
  Future<void> serviceReload() async {
    reloadCalls++;
    _stateController.add(const ProxyStarted());
  }

  @override
  Future<String> getSingBoxVersion() async => '1.14.4';

  void emit(ProxyState state) => _stateController.add(state);

  void emitLogs(List<ClientLog> logs) => _logController.add(logs);

  Future<void> close() async {
    await _stateController.close();
    await _logController.close();
  }
}

/// 校验器 fake：按开关返回通过或固定错误。
class _FakeValidator implements ConfigValidator {
  List<String> errors = const [];

  @override
  Future<List<String>> validate(Map<String, dynamic> config) async => errors;
}

/// Clash API fake：trafficSample 按开关成功或抛错，不碰真网络；
/// proxyDelayDetailed 默认测通（123ms），按需改成失败；
/// [delayQueue] 非空时按顺序出队（模拟“首次超时、重试后通过”），
/// 空了回落到 [delayResult]（模拟“两次都失败”时重试也失败）。
/// 0.1.9 采样：[connectionEntries] 与两路 DNS 结果可注入；
/// [proxyDnsQueue] 非空时代理路 DNS 按顺序出队（模拟“通过→失败”
/// 的黑断翻转）。
class _FakeClashApi extends ClashApiClient {
  Object? error;
  ProxyDelayResult delayResult = const ProxyDelayResult(delay: 123);
  final List<ProxyDelayResult> delayQueue = [];
  int delayCalls = 0;
  final List<String> delayTags = [];
  Duration? lastDelayTimeout;
  List<ConnectionEntry> connectionEntries = const [];
  DnsQueryResult directDnsResult = const DnsQueryResult(
    ok: true,
    latencyMs: 120,
  );
  DnsQueryResult proxyDnsResult = const DnsQueryResult(
    ok: true,
    latencyMs: 45,
  );
  final List<DnsQueryResult> proxyDnsQueue = [];

  @override
  Future<List<ConnectionEntry>> getConnectionEntries() async =>
      connectionEntries;

  @override
  Future<DnsQueryResult> queryDns(String name, {String type = 'A'}) async {
    if (name.contains('youtube')) {
      if (proxyDnsQueue.isNotEmpty) return proxyDnsQueue.removeAt(0);
      return proxyDnsResult;
    }
    return directDnsResult;
  }

  @override
  Future<TrafficSample> trafficSample({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (error != null) throw error!;
    return const TrafficSample(up: 0, down: 0);
  }

  @override
  Future<ProxyDelayResult> proxyDelayDetailed(
    String proxyName, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    delayCalls++;
    delayTags.add(proxyName);
    lastDelayTimeout = timeout;
    if (delayQueue.isNotEmpty) return delayQueue.removeAt(0);
    return delayResult;
  }

  String? get lastDelayTag => delayTags.isEmpty ? null : delayTags.last;
}

Node _node(String name, {NodeSource source = NodeSource.direct}) => Node(
  name: name,
  protocol: NodeProtocol.vless,
  address: '203.0.113.1',
  port: 443,
  source: source,
  uuidOrPassword: '11111111-2222-3333-4444-555555555555',
  tls: true,
  sni: 'example.com',
);

/// 让广播流的事件送达监听方。
Future<void> _pumpEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late Directory tmpDir;
  late String configPath;
  late _FakePlugin plugin;
  late _FakeValidator validator;
  late _FakeClashApi fakeApi;
  late List<String> ensureProfileCalls;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('core-service-test-');
    configPath = '${tmpDir.path}/using_config.json';
    plugin = _FakePlugin();
    validator = _FakeValidator();
    fakeApi = _FakeClashApi();
    ensureProfileCalls = [];
  });

  tearDown(() async {
    await plugin.close();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  // 探活的预热/重试等待默认传 0，让拨测类测试不用等真 2 秒；
  // 验预热本身的那一项单独传真值。真实流量复核默认注入“通”（测试
  // 环境没有真 mixed 入站，不注入就恒失败）；验复核本身的那一项
  // 单独传返回 false 的 fake。
  CoreService makeService({
    Duration probeWarmup = Duration.zero,
    Duration probeRetryDelay = Duration.zero,
    Future<bool> Function()? realTrafficProbe,
    Duration sampleInterval = const Duration(seconds: 20),
  }) => CoreService(
    plugin: plugin,
    validator: validator,
    usingConfigPath: () async => configPath,
    ensureSelectedProfile: (path) async {
      ensureProfileCalls.add(path);
    },
    clashApiClient: fakeApi,
    probeWarmup: probeWarmup,
    probeRetryDelay: probeRetryDelay,
    realTrafficProbe: realTrafficProbe ?? () async => true,
    sampleInterval: sampleInterval,
  );

  group('applyNodes', () {
    test('停止时应用成功：写盘、不重载、记节点数', () async {
      final service = makeService();
      await service.init();
      final result = await service.applyNodes([_node('甲-直连')]);
      expect(result.ok, isTrue);
      expect(result.nodeCount, 1);
      expect(result.skipped, isEmpty);
      expect(plugin.reloadCalls, 0);

      final file = File(configPath);
      expect(await file.exists(), isTrue);
      final decoded = jsonDecode(await file.readAsString());
      expect(decoded, isA<Map<String, dynamic>>());
      expect((decoded['outbounds'] as List).length, 5);
      expect(service.currentConfigJson, isNotNull);
      expect(service.appliedNodeCount, 1);
      expect(service.lastAppliedAt, isNotNull);
      service.dispose();
    });

    test('校验失败：不写盘、不重载、返回原因', () async {
      validator.errors = ['dns.servers[0] 仍是 legacy address 写法'];
      final service = makeService();
      await service.init();
      final result = await service.applyNodes([_node('甲-直连')]);
      expect(result.ok, isFalse);
      expect(result.errors, ['dns.servers[0] 仍是 legacy address 写法']);
      expect(await File(configPath).exists(), isFalse);
      expect(plugin.reloadCalls, 0);
      expect(service.currentConfigJson, isNull);
      service.dispose();
    });

    test('已运行时应用成功：调一次重载', () async {
      final service = makeService();
      await service.init();
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      expect(service.status, CoreStatus.started);

      final result = await service.applyNodes([_node('甲-直连')]);
      expect(result.ok, isTrue);
      expect(plugin.reloadCalls, 1);
      service.dispose();
    });

    test('已运行时校验失败：旧文件不动、不重载、状态仍是已启动', () async {
      final service = makeService();
      await service.init();
      final first = await service.applyNodes([_node('甲-直连')]);
      expect(first.ok, isTrue);
      final oldContent = await File(configPath).readAsString();

      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      validator.errors = ['route 缺少 default_domain_resolver'];
      final second = await service.applyNodes([
        _node('甲-直连'),
        _node('乙-直连'),
      ]);
      expect(second.ok, isFalse);
      expect(await File(configPath).readAsString(), oldContent);
      expect(plugin.reloadCalls, 0);
      expect(service.status, CoreStatus.started);
      expect(service.appliedNodeCount, 1);
      service.dispose();
    });
  });

  group('start / stop', () {
    test('没有配置时 start 直接报错，不调插件', () async {
      final service = makeService();
      await service.init();
      await expectLater(service.start(), throwsStateError);
      expect(plugin.startCalls, 0);
      expect(ensureProfileCalls, isEmpty);
      service.dispose();
    });

    test('有配置时 start 先建档案再启动', () async {
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      await service.start();
      expect(ensureProfileCalls, [configPath]);
      expect(plugin.startCalls, 1);
      await _pumpEvents();
      expect(service.status, CoreStatus.started);
      service.dispose();
    });

    test('stop 调插件，状态流回落到已停止', () async {
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      await service.start();
      await _pumpEvents();
      await service.stop();
      expect(plugin.stopCalls, 1);
      await _pumpEvents();
      expect(service.status, CoreStatus.stopped);
      expect(service.lastError, isNull);
      service.dispose();
    });

    test('init 时把磁盘上最后一份配置读回内存', () async {
      final first = makeService();
      await first.init();
      await first.applyNodes([_node('甲-直连'), _node('乙-中转')]);
      first.dispose();

      // 模拟 App 重启：新实例 init 后不用 applyNodes 也能 start。
      final second = makeService();
      await second.init();
      expect(second.currentConfigJson, isNotNull);
      await second.start();
      expect(plugin.startCalls, 1);
      second.dispose();
    });

    test('异常停止进 error 状态并记原因', () async {
      final service = makeService();
      await service.init();
      plugin.emit(const ProxyStopped(errMessage: '核心崩溃'));
      await _pumpEvents();
      expect(service.status, CoreStatus.error);
      expect(service.lastError, '核心崩溃');
      service.dispose();
    });
  });

  group('updateSelectorDefault（切片 4）', () {
    Future<Map<String, dynamic>> readConfig() async {
      final decoded = jsonDecode(await File(configPath).readAsString());
      return decoded as Map<String, dynamic>;
    }

    String proxyDefault(Map<String, dynamic> config) {
      final outbounds = config['outbounds'] as List;
      final proxy = outbounds.cast<Map<String, dynamic>>().firstWhere(
        (ob) => ob['tag'] == 'Proxy',
      );
      return proxy['default'] as String;
    }

    test('只改 Proxy 的 default，不动其它字段、不重载', () async {
      final service = makeService();
      await service.init();
      final applied = await service.applyNodes([
        _node('甲-直连'),
        _node('乙-中转', source: NodeSource.relay),
      ]);
      expect(applied.ok, isTrue);
      expect(proxyDefault(await readConfig()), '甲-直连');

      expect(await service.updateSelectorDefault('乙-中转'), isTrue);
      final updated = await readConfig();
      expect(proxyDefault(updated), '乙-中转');
      // 其它字段原样：节点出站数、route、dns 都没动。
      expect((updated['outbounds'] as List).length, 6);
      expect(updated['route'], isNotNull);
      expect(updated['dns'], isNotNull);
      // 内存里的配置也跟着变，下次 start 读的就是新默认。
      expect(service.currentConfigJson, contains('"default":"乙-中转"'));
      expect(plugin.reloadCalls, 0);
      service.dispose();
    });

    test('没有配置、没有 Proxy 组、tag 不在成员里时返回 false', () async {
      final service = makeService();
      await service.init();
      // 还没 applyNodes，磁盘上没有配置。
      expect(await service.updateSelectorDefault('甲-直连'), isFalse);

      // 空节点配置里没有 Proxy 组。
      await service.applyNodes([]);
      expect(await service.updateSelectorDefault('甲-直连'), isFalse);

      // tag 不在 Proxy 成员里：不写盘。
      await service.applyNodes([_node('甲-直连')]);
      final before = await File(configPath).readAsString();
      expect(await service.updateSelectorDefault('不存在的节点'), isFalse);
      expect(await File(configPath).readAsString(), before);
      service.dispose();
    });
  });

  group('启动后 Clash API 校验（问题 6）', () {
    test('Started 后 /traffic 取到帧：保持 started，探活位不失败', () async {
      final service = makeService();
      await service.init();
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      // 校验是 fire-and-forget 的异步探活，等它跑完再断言。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.status, CoreStatus.started);
      expect(service.lastError, isNull);
      expect(service.probeFailed, isFalse);
      service.dispose();
    });

    test('Started 后 /traffic 探不到：记探活失败，不翻 error', () async {
      fakeApi.error = TimeoutException('Clash API /traffic 超时无帧');
      final service = makeService();
      await service.init();
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // 2026-11-26 二轮修复（方案 A）：核心在跑，控制接口无响应只记
      // 探活位，首页保持“运行中”＋拨测失败提示，不翻 error 闩锁。
      expect(service.status, CoreStatus.started);
      expect(service.probeFailed, isTrue);
      expect(service.lastProbeError, '核心已启动但控制接口无响应');
      expect(service.lastProbeAt, isNotNull);
      expect(service.lastError, isNull);
      service.dispose();
    });

    test('校验期间用户已停止：不记探活失败', () async {
      fakeApi.error = TimeoutException('Clash API /traffic 超时无帧');
      final service = makeService();
      await service.init();
      plugin.emit(const ProxyStarted());
      plugin.emit(const ProxyStopped());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.status, CoreStatus.stopped);
      expect(service.probeFailed, isFalse);
      service.dispose();
    });

    test('Started 后 /traffic 取到帧且拨测通：保持 started', () async {
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.status, CoreStatus.started);
      expect(service.lastError, isNull);
      expect(fakeApi.lastDelayTag, '甲-直连');
      service.dispose();
    });

    test('Started 后 /traffic 取到帧但拨测失败：两次都失败才记探活失败', () async {
      // 2026-11-26 根因：DNS 全死时 /traffic 照常推 0/0 帧，首页
      // 显示“运行中”，实际没网络；拨测失败必须记下来。
      // 但一次失败不立刻记：先重试一次，仍失败才是真不通。
      // 二轮修复：记探活位、不翻 error（核心在跑，首页保持“运行中”）。
      fakeApi.delayResult = const ProxyDelayResult(
        failure: ProxyDelayFailure.failed,
      );
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.status, CoreStatus.started);
      expect(service.probeFailed, isTrue);
      expect(fakeApi.delayCalls, 2);
      expect(service.lastProbeError, contains('代理出站拨测失败'));
      expect(service.lastProbeError, contains('DNS 或节点不通'));
      expect(service.lastError, isNull);
      service.dispose();
    });

    test('拨测目标是默认出站；成组节点直接拨组 tag', () async {
      final service = makeService();
      await service.init();
      await service.applyNodes([
        _node('测试-reality-443'),
        _node('测试-hy2-443'),
      ]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.status, CoreStatus.started);
      // 默认是组 tag `测试`：真 sing-box 1.14.4 实测 delay 组 tag
      // 返回组内当前选用入站的延迟，不再解到 members.first
      //（`测试-reality-443` 不一定是组实际选用的入站）。
      expect(fakeApi.lastDelayTag, '测试');
      expect(fakeApi.delayCalls, 1);
      service.dispose();
    });

    test('拨测预算是 10 秒', () async {
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fakeApi.lastDelayTimeout, const Duration(seconds: 10));
      service.dispose();
    });

    test('首次拨测超时、重试后通过：保持 started，不翻 error', () async {
      fakeApi.delayQueue.addAll([
        const ProxyDelayResult(failure: ProxyDelayFailure.timeout),
        const ProxyDelayResult(delay: 456),
      ]);
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.status, CoreStatus.started);
      expect(service.lastError, isNull);
      expect(fakeApi.delayCalls, 2);
      service.dispose();
    });

    test('拨测超时两次都失败才记探活失败，原因写明已重试与下一步', () async {
      fakeApi.delayResult = const ProxyDelayResult(
        failure: ProxyDelayFailure.timeout,
      );
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.status, CoreStatus.started);
      expect(service.probeFailed, isTrue);
      expect(fakeApi.delayCalls, 2);
      expect(service.lastProbeError, contains('拨测超时'));
      expect(service.lastProbeError, contains('10 秒无响应，已重试一次'));
      expect(service.lastProbeError, contains('点「重新拨测」再试一次'));
      service.dispose();
    });

    test('重试期间保持 started，不闪 error', () async {
      fakeApi.delayResult = const ProxyDelayResult(
        failure: ProxyDelayFailure.failed,
      );
      final service = makeService(
        probeRetryDelay: const Duration(milliseconds: 500),
      );
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      // 第一次拨测已失败、重试还没跑：仍是 started，不是 error。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fakeApi.delayCalls, 1);
      expect(service.status, CoreStatus.started);
      expect(service.probeFailed, isFalse);
      // 重试跑完仍失败：这时才记探活失败，状态仍是 started。
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(fakeApi.delayCalls, 2);
      expect(service.status, CoreStatus.started);
      expect(service.probeFailed, isTrue);
      service.dispose();
    });

    test('预热：取到 /traffic 帧后 2 秒内不拨测', () async {
      final service = makeService(
        probeWarmup: const Duration(seconds: 2),
      );
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fakeApi.delayCalls, 0);
      expect(service.status, CoreStatus.started);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(fakeApi.delayCalls, 1);
      expect(service.status, CoreStatus.started);
      service.dispose();
    });

    test('探活失败后 retryProbe 成功：清掉 probeFailed，状态不动', () async {
      fakeApi.delayResult = const ProxyDelayResult(
        failure: ProxyDelayFailure.failed,
      );
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.status, CoreStatus.started);
      expect(service.probeFailed, isTrue);

      // 节点恢复后点“重新拨测”：只重跑探活，不停核心、不重建配置。
      fakeApi.delayResult = const ProxyDelayResult(delay: 200);
      await service.retryProbe();
      expect(service.status, CoreStatus.started);
      expect(service.probeFailed, isFalse);
      expect(service.lastProbeError, isNull);
      service.dispose();
    });

    test('retryProbe：核心没在跑时不拨测', () async {
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      await service.retryProbe();
      expect(fakeApi.delayCalls, 0);
      expect(service.probeFailed, isFalse);
      service.dispose();
    });

    test('新一轮 Started：清掉上一轮的 _lastError 与探活失败', () async {
      fakeApi.delayResult = const ProxyDelayResult(
        failure: ProxyDelayFailure.failed,
      );
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.probeFailed, isTrue);
      // 上一轮异常停止：记 error。
      plugin.emit(const ProxyStopped(errMessage: '核心崩溃'));
      await _pumpEvents();
      expect(service.status, CoreStatus.error);
      expect(service.lastError, '核心崩溃');
      // 新一轮启动：上一轮的原因与探活失败都清掉（拨测已恢复，
      // 新一轮校验通过，不再把旧失败带回来）。
      fakeApi.delayResult = const ProxyDelayResult(delay: 200);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      expect(service.status, CoreStatus.started);
      expect(service.lastError, isNull);
      expect(service.probeFailed, isFalse);
      service.dispose();
    });

    test('probeStream：探活失败与恢复都推事件', () async {
      fakeApi.delayResult = const ProxyDelayResult(
        failure: ProxyDelayFailure.failed,
      );
      final service = makeService();
      await service.init();
      final seen = <ProbeState>[];
      final sub = service.probeStream.listen(seen.add);
      await service.applyNodes([_node('甲-直连')]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen.last.failed, isTrue);
      expect(seen.last.error, contains('代理出站拨测失败'));
      fakeApi.delayResult = const ProxyDelayResult(delay: 200);
      await service.retryProbe();
      // 广播流事件是异步投递：等一个微任务再读，不然 seen 里还是旧事件。
      await _pumpEvents();
      expect(seen.last.failed, isFalse);
      await sub.cancel();
      service.dispose();
    });

    test('0.1.3：delay 通但真实流量不通：只记探活失败，不翻 error', () async {
      // D 路修复 2 的核心场景：0.1.2 的 delay 拨测直拨出站，DNS
      // 全死时它照常通；经 mixed 入站的真实流量复核才抓得到。
      fakeApi.delayResult = const ProxyDelayResult(delay: 200);
      final service = makeService(realTrafficProbe: () async => false);
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.status, CoreStatus.started);
      expect(service.probeFailed, isTrue);
      expect(service.lastProbeError, contains('真实流量不通'));
      expect(service.lastProbeError, contains('DNS 或路由可能有问题'));
      service.dispose();
    });
  });

  group('0.1.9：采样时序', () {
    test('启动后按间隔采样：行含相对秒数、两路 DNS、出站聚合', () async {
      fakeApi.connectionEntries = const [
        ConnectionEntry(
          chains: ['美国01-hy2-443-A', '美国01', 'Proxy'],
          upload: 1000,
          download: 2000,
        ),
        ConnectionEntry(
          chains: ['美国01-hy2-443-A', '美国01', 'Proxy'],
          upload: 500,
          download: 700,
        ),
        ConnectionEntry(chains: ['direct'], upload: 10, download: 20),
      ];
      final service = makeService(
        sampleInterval: const Duration(milliseconds: 100),
      );
      await service.init();
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(service.samplingTimeline.length, greaterThanOrEqualTo(2));
      final row = service.samplingTimeline.first;
      expect(row, startsWith('+'));
      expect(row, contains('直连DNS 通过 120ms'));
      expect(row, contains('代理DNS 通过 45ms'));
      expect(row, contains('连接 3条'));
      expect(row, contains('美国01-hy2-443-A：2条'));
      expect(row, contains('direct：1条'));
      expect(service.blackoutAt, isNull);
      service.dispose();
    });

    test('代理路 DNS 通过变失败的那次采样标疑似黑断，之后不再重复标', () async {
      fakeApi.connectionEntries = const [];
      // 前两轮通过，第三轮起失败。
      fakeApi.proxyDnsQueue.addAll([
        const DnsQueryResult(ok: true, latencyMs: 40),
        const DnsQueryResult(ok: true, latencyMs: 42),
        const DnsQueryResult(ok: false, error: 'DNS Rcode 2'),
        const DnsQueryResult(ok: false, error: 'DNS Rcode 2'),
      ]);
      final service = makeService(
        sampleInterval: const Duration(milliseconds: 100),
      );
      await service.init();
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 550));
      final marked = service.samplingTimeline
          .where((row) => row.contains('疑似黑断'))
          .toList();
      expect(marked.length, 1);
      expect(marked.first, contains('代理DNS 失败'));
      expect(service.blackoutAt, isNotNull);
      service.dispose();
    });

    test('代理路 DNS 从没通过过：失败不标黑断', () async {
      fakeApi.connectionEntries = const [];
      fakeApi.proxyDnsResult = const DnsQueryResult(
        ok: false,
        error: 'DNS Rcode 2',
      );
      final service = makeService(
        sampleInterval: const Duration(milliseconds: 100),
      );
      await service.init();
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(service.samplingTimeline, isNotEmpty);
      expect(
        service.samplingTimeline.any((row) => row.contains('疑似黑断')),
        isFalse,
      );
      expect(service.blackoutAt, isNull);
      service.dispose();
    });

    test('核心停即清空时序与黑断标记', () async {
      fakeApi.connectionEntries = const [];
      final service = makeService(
        sampleInterval: const Duration(milliseconds: 100),
      );
      await service.init();
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(service.samplingTimeline, isNotEmpty);
      plugin.emit(const ProxyStopped());
      await _pumpEvents();
      expect(service.samplingTimeline, isEmpty);
      expect(service.blackoutAt, isNull);
      service.dispose();
    });

    test('核心日志尾巴：logStream 的行进内存环，核心停即清空', () async {
      final service = makeService();
      await service.init();
      plugin.emitLogs(const [
        ClientLog(level: 4, message: 'inbound connection to 203.0.113.1:443'),
        ClientLog(level: 2, message: 'blocked packet connection'),
      ]);
      await _pumpEvents();
      expect(service.coreLogTail, [
        '[Info] inbound connection to 203.0.113.1:443',
        '[Error] blocked packet connection',
      ]);
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      // 新一轮启动清掉上一轮的日志尾巴（与时序同规则）。
      expect(service.coreLogTail, isEmpty);
      service.dispose();
    });
  });

  group('0.1.10：采样 TUN 证据', () {
    test('TUN 流按 tcp/udp 分上下行，只发不收单独计数', () async {
      // 0.1.9 死态的特征：Proxy 流 ↑4.9KB ↓0B（只发不收）。
      // 采样行要直接印出来：tcp 只发不收、udp 有下行 → TCP 回包断；
      // 两者都只发不收 → TUN 回包全断；两者都有下行 → 回包通。
      fakeApi.connectionEntries = const [
        ConnectionEntry(
          chains: ['美国01-reality-443-A', '美国01', 'Proxy'],
          upload: 4900,
          download: 0,
          network: 'tcp',
          inboundType: 'tun',
        ),
        ConnectionEntry(
          chains: ['direct'],
          upload: 100,
          download: 397000,
          network: 'tcp',
          inboundType: 'tun',
        ),
        ConnectionEntry(
          chains: ['direct'],
          upload: 50,
          download: 200,
          network: 'udp',
          inboundType: 'tun',
        ),
        // mixed 入站是本机探针，不算进 TUN 段。
        ConnectionEntry(
          chains: ['direct'],
          upload: 10,
          download: 20,
          network: 'tcp',
          inboundType: 'mixed',
        ),
      ];
      final service = makeService(
        sampleInterval: const Duration(milliseconds: 100),
      );
      await service.init();
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(service.samplingTimeline, isNotEmpty);
      final row = service.samplingTimeline.first;
      expect(row, contains('TUN tcp：2条'));
      expect(row, contains('↓387.7KB'));
      expect(row, contains('udp：1条'));
      expect(row, contains('只发不收：1条'));
      service.dispose();
    });

    test('无 TUN 流时印 TUN 无连接，不影响出站聚合', () async {
      fakeApi.connectionEntries = const [
        ConnectionEntry(chains: ['direct'], upload: 10, download: 20),
      ];
      final service = makeService(
        sampleInterval: const Duration(milliseconds: 100),
      );
      await service.init();
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(service.samplingTimeline, isNotEmpty);
      final row = service.samplingTimeline.first;
      expect(row, contains('TUN 无连接'));
      expect(row, contains('direct：1条'));
      service.dispose();
    });
  });
}
