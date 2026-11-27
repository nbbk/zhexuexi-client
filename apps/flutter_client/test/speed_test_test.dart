// 切片 4：节点测速＋自动选节点的回归测试。
//
// 不碰真核心：Clash API 用本机假 HttpServer（delay 按名字给数），
// 核心状态用桩（只认 status 与 updateSelectorDefault），订阅用桩
// （直接给节点列表）。5 分钟后台重测的定时器只在测速后才启动，
// 跑测试时不会触发；tearDown 里 dispose container 取消它。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_sing_box/flutter_sing_box.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/clash_api_client.dart';
import 'package:zhexuexi_client/core/core_provider.dart';
import 'package:zhexuexi_client/core/direct_ping.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/singbox_core.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/subscription_parser.dart';
import 'package:zhexuexi_client/services/subscription_service.dart';
import 'package:zhexuexi_client/services/subscription_store.dart';

/// 插件 fake：只提供状态流，不碰平台通道。
class _FakePlugin extends FlutterSingBox {
  final _stateController = StreamController<ProxyState>.broadcast();

  @override
  Stream<ProxyState> get proxyStateStream => _stateController.stream;

  // 0.1.9：日志流也桩掉——真实现走 EventChannel `log_event`，
  // 测试里无原生实现，listen 会报 MissingPluginException。
  @override
  Stream<List<ClientLog>> get logStream =>
      Stream<List<ClientLog>>.empty();

  @override
  Future<void> init() async {}

  Future<void> close() => _stateController.close();
}

/// 核心桩：状态手动给，updateSelectorDefault 只记调用。
class _StubCoreService extends CoreService {
  _StubCoreService() : super(plugin: _FakePlugin());

  CoreStatus statusValue = CoreStatus.stopped;

  /// 启动探活位（2026-11-26 二轮修复）：true＝核心在跑但出站
  /// 拨测失败，测速要改走直连并明确提示。
  bool probeFailedValue = false;
  String? probeErrorValue;

  @override
  bool get probeFailed => probeFailedValue;

  @override
  String? get lastProbeError => probeErrorValue;

  final List<String> persistedTags = [];
  bool persistOk = true;

  @override
  CoreStatus get status => statusValue;

  @override
  Future<bool> updateSelectorDefault(String tag) async {
    persistedTags.add(tag);
    return persistOk;
  }
}

/// 订阅桩：直接给节点列表，不拉网络、不碰密钥库。
/// 假安全存储：内存 Map，不碰真密钥库的 MethodChannel。
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
  }) async => _map[key];

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

class _StubSubscriptionService extends SubscriptionService {
  List<Node> nodes = [];

  @override
  Future<String?> readSubscriptionUrl() async =>
      'https://example.com/sub';

  @override
  Future<NodeListResult> fetchNodes({
    required String subscriptionUrl,
  }) async => NodeListResult(
    nodes: nodes,
    failedCount: 0,
    userinfo: null,
    format: SubscriptionFormat.singbox,
  );
}

/// 直连探测桩：按地址给固定结果，不碰真网络。
/// 203.0.113.4 超时（失败原因“超时不可达”）；203.0.113.5（grpc 节点）
/// 直连最快（40ms），但它配置里没有出站、选不了（自动选择要跳过它）。
/// [_probeDelay] 设了就先等一等（组测速互斥测试用：让第一轮还在
/// 飞，第二轮进不去）。
Duration _probeDelay = Duration.zero;

Future<DirectProbeResult> _fakeProbe(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (_probeDelay > Duration.zero) {
    await Future<void>.delayed(_probeDelay);
  }
  return switch (host) {
    '203.0.113.1' => const DirectProbeResult.reachable(120),
    '203.0.113.2' => const DirectProbeResult.reachable(86),
    '203.0.113.3' => const DirectProbeResult.reachable(210),
    '203.0.113.4' => const DirectProbeResult.failed(
      DirectProbeFailure.timeout,
    ),
    '203.0.113.5' => const DirectProbeResult.reachable(40),
    _ => const DirectProbeResult.failed(DirectProbeFailure.other),
  };
}

Node _node(
  String name,
  NodeSource source, {
  String transport = 'tcp',
  String address = '203.0.113.1',
  String? realityPublicKey,
}) => Node(
  name: name,
  protocol: NodeProtocol.vless,
  address: address,
  port: 443,
  source: source,
  uuidOrPassword: '11111111-2222-3333-4444-555555555555',
  transport: transport,
  tls: true,
  realityPublicKey: realityPublicKey,
);

/// 五个节点：香港-中转 300ms、智利-直连 86ms、日本-直连 210ms、
/// 坏节点-直连测速失败、grpc-直连配置里没有出站（测速失败）。
/// 地址各不相同：多订阅合并按内容去重（去重键不含名字），
/// 同地址＋同 UUID 的节点会被当成同一条。
List<Node> _fiveNodes() => [
  _node('香港-中转', NodeSource.relay, address: '203.0.113.1'),
  _node('智利-直连', NodeSource.direct, address: '203.0.113.2'),
  _node('日本-直连', NodeSource.direct, address: '203.0.113.3'),
  _node('坏节点-直连', NodeSource.direct, address: '203.0.113.4'),
  _node(
    'grpc-直连',
    NodeSource.direct,
    transport: 'grpc',
    address: '203.0.113.5',
  ),
];

void main() {
  // refresh() 会读订阅列表（SharedPreferences）：普通 test() 没有
  // binding，先初始化并给 mock 偏好（空绑定＝只有主订阅）。
  // 注意：test binding 会把 HttpClient 换成永远回 400 的假实现，
  // 假 Clash API 服务器要走真 HTTP，这里把它还原
  //（setupHttpOverrides 只在 binding 创建时调一次，不会每测重设）。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});

  late HttpServer apiServer;
  late List<String> putBodies;
  late int putStatus;
  late int delayHits;
  late Map<String, int?> delays;
  // 0.1.2：测速调用记录（预热顺序、10 秒预算、并发上限、重试次数）。
  late List<String> delayNames;
  late List<String?> delayTimeouts;
  late Map<String, int> delayHitsByName;
  late int currentConcurrent;
  late int maxConcurrent;
  late _StubCoreService core;
  late _StubSubscriptionService subscription;
  late ProviderContainer container;

  /// 起一个 Clash API 假服务器：delay 按 [delays] 表给数，
  /// 没在表里的返回 503；PUT /proxies/Proxy 记 body、回 204。
  Future<String> startApiServer() async {
    putBodies = [];
    delayHits = 0;
    apiServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    apiServer.listen((request) async {
      try {
        final segments = request.uri.pathSegments;
        if (request.method == 'GET' &&
            segments.length == 3 &&
            segments[0] == 'proxies' &&
            segments[2] == 'delay') {
          // 注意：pathSegments 已经是 percent 解码后的，中文名直接就是原文，
          // 再调 Uri.decodeComponent 会对 raw 非 ASCII 抛错（见复现）。
          final name = segments[1];
          delayHits++;
          delayNames.add(name);
          delayTimeouts.add(request.uri.queryParameters['timeout']);
          delayHitsByName[name] = (delayHitsByName[name] ?? 0) + 1;
          // 并发跟踪：同时在途的 delay 请求数（0.1.2 并发上限 2）。
          currentConcurrent++;
          if (currentConcurrent > maxConcurrent) {
            maxConcurrent = currentConcurrent;
          }
          try {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          } finally {
            currentConcurrent--;
          }
          final response = request.response;
          response.headers.contentType = ContentType.json;
          if (name == 'slow-node') {
            // 504：规定时间内没测出延迟（原因与 503 的拨号失败分开）。
            response.statusCode = HttpStatus.gatewayTimeout;
            response.write('{"message":"Timeout"}');
            await response.close();
            return;
          }
          if (name == 'flaky-node') {
            // 第一次 504（超时）、重试后通：0.1.2 只在超时失败时重试一次。
            if (delayHitsByName[name] == 1) {
              response.statusCode = HttpStatus.gatewayTimeout;
              response.write('{"message":"Timeout"}');
            } else {
              response.write('{"delay":120}');
            }
            await response.close();
            return;
          }
          final delay = delays[name];
          if (delay == null) {
            response.statusCode = HttpStatus.serviceUnavailable;
            response.write(
              '{"message":"An error occurred in the delay test"}',
            );
          } else {
            response.write('{"delay":$delay}');
          }
          await response.close();
          return;
        }
        if (request.method == 'PUT' &&
            segments.length == 2 &&
            segments[0] == 'proxies') {
          putBodies.add(await utf8.decoder.bind(request).join());
          request.response.statusCode = putStatus;
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } catch (_) {}
    });
    return 'http://127.0.0.1:${apiServer.port}';
  }

  setUp(() async {
    delays = {
      '香港-中转': 300,
      '智利-直连': 86,
      '日本-直连': 210,
    };
    delayNames = [];
    delayTimeouts = [];
    delayHitsByName = {};
    currentConcurrent = 0;
    maxConcurrent = 0;
    putStatus = HttpStatus.noContent;
    final baseUrl = await startApiServer();
    core = _StubCoreService();
    subscription = _StubSubscriptionService()..nodes = _fiveNodes();
    container = ProviderContainer(
      overrides: [
        subscriptionServiceProvider.overrideWithValue(subscription),
        coreServiceProvider.overrideWithValue(core),
        clashApiClientProvider.overrideWithValue(
          ClashApiClient(baseUrl: baseUrl),
        ),
        // 直连探测走桩（按地址给数）：核心关着时的测速不碰真网络。
        directProbeProvider.overrideWithValue(_fakeProbe),
        // 订阅列表走假存储＋测试偏好：不碰真安全存储的 MethodChannel。
        subscriptionStoreProvider.overrideWithValue(
          SubscriptionStore(
            storage: _FakeSecureStorage(),
            prefs: await SharedPreferences.getInstance(),
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await apiServer.close(force: true);
    });
  });

  Future<NodesNotifier> loadNodes() async {
    final notifier = container.read(nodesProvider.notifier);
    await notifier.refresh();
    expect(container.read(nodesProvider).nodes.length, 5);
    return notifier;
  }

  test('一键测速：全部测到，失败的标灰、不丢节点', () async {
    core.statusValue = CoreStatus.started;
    final notifier = await loadNodes();
    expect(await notifier.testAllSpeeds(), isTrue);

    final state = container.read(nodesProvider);
    expect(state.testingSpeed, isFalse);
    expect(state.speedTestedCount, 5);
    expect(state.speedTestTotal, 5);
    expect(state.speedTestAt, isNotNull);
    expect(state.speedTestError, isNull);
    expect(state.speedTestDirect, isFalse);
    // 开关开着：走 Clash API（5 个节点里 grpc 没有出站，只调 4 次，
    // 再加开批前 1 次预热拨测）。
    expect(delayHits, 5);
    // 预热先拨当前默认出站（selector `Proxy`），再测各节点；
    // 预算 10 秒（与启动探活 probeTimeout 对齐）。
    expect(delayNames.first, 'Proxy');
    expect(delayTimeouts, everyElement('10000'));
    final byName = {for (final n in state.nodes) n.name: n};
    expect(byName['香港-中转']!.latencyMs, 300);
    expect(byName['智利-直连']!.latencyMs, 86);
    expect(byName['日本-直连']!.latencyMs, 210);
    // 坏节点：delay 接口 503 → 失败标灰。
    expect(byName['坏节点-直连']!.latencyMs, isNull);
    expect(byName['坏节点-直连']!.latencyFailed, isTrue);
    // grpc 节点：配置里没有出站，不调接口，直接标失败。
    expect(byName['grpc-直连']!.latencyMs, isNull);
    expect(byName['grpc-直连']!.latencyFailed, isTrue);
  });

  test('一键测速：核心未启动时走直连探测，不启动核心、不调 Clash API', () async {
    core.statusValue = CoreStatus.stopped;
    final notifier = await loadNodes();
    expect(await notifier.testAllSpeeds(), isTrue);

    final state = container.read(nodesProvider);
    expect(state.testingSpeed, isFalse);
    expect(state.speedTestedCount, 5);
    expect(state.speedTestTotal, 5);
    expect(state.speedTestAt, isNotNull);
    expect(state.speedTestError, isNull);
    expect(state.speedTestDirect, isTrue);
    // 直连探测没碰 Clash API：delay 接口一次没调。
    expect(delayHits, 0);
    final byName = {for (final n in state.nodes) n.name: n};
    expect(byName['香港-中转']!.latencyMs, 120);
    expect(byName['智利-直连']!.latencyMs, 86);
    expect(byName['日本-直连']!.latencyMs, 210);
    // 超时：标失败，原因写清是超时不可达。
    expect(byName['坏节点-直连']!.latencyMs, isNull);
    expect(byName['坏节点-直连']!.latencyFailed, isTrue);
    expect(byName['坏节点-直连']!.latencyFailureReason, '超时不可达');
    // grpc 节点：直连不看配置里有没有出站，照样测连通性。
    expect(byName['grpc-直连']!.latencyMs, 40);
    expect(byName['grpc-直连']!.latencyFailed, isFalse);
  });

  test('组测速：只测该组节点，其他组不动', () async {
    core.statusValue = CoreStatus.stopped;
    final notifier = await loadNodes();
    final nodes = container.read(nodesProvider).nodes;
    expect(
      await notifier.testGroupSpeeds('g-a', nodes.sublist(0, 2)),
      isTrue,
    );

    final state = container.read(nodesProvider);
    expect(state.testingSpeed, isFalse);
    expect(state.testingGroupKey, isNull);
    expect(state.speedTestedCount, 2);
    expect(state.speedTestTotal, 2);
    expect(state.speedTestDirect, isTrue);
    expect(state.speedTestAt, isNotNull);
    // 直连探测没碰 Clash API：delay 接口一次没调。
    expect(delayHits, 0);
    final byName = {for (final n in state.nodes) n.name: n};
    expect(byName['香港-中转']!.latencyMs, 120);
    expect(byName['智利-直连']!.latencyMs, 86);
    // 其他组一个没动：延迟还是空、也没标失败。
    expect(byName['日本-直连']!.latencyMs, isNull);
    expect(byName['日本-直连']!.latencyFailed, isFalse);
    expect(byName['坏节点-直连']!.latencyMs, isNull);
    expect(byName['坏节点-直连']!.latencyFailed, isFalse);
    expect(byName['grpc-直连']!.latencyMs, isNull);
    expect(byName['grpc-直连']!.latencyFailed, isFalse);
  });

  test('组测速：空组返回 false，不改状态', () async {
    core.statusValue = CoreStatus.stopped;
    final notifier = await loadNodes();
    expect(await notifier.testGroupSpeeds('g-a', []), isFalse);
    expect(container.read(nodesProvider).testingSpeed, isFalse);
    expect(container.read(nodesProvider).testingGroupKey, isNull);
  });

  test('组测速互斥：进行中时一键/单节点/另一组都返回 false', () async {
    _probeDelay = const Duration(milliseconds: 300);
    addTearDown(() => _probeDelay = Duration.zero);
    core.statusValue = CoreStatus.stopped;
    final notifier = await loadNodes();
    final nodes = container.read(nodesProvider).nodes;
    final first = notifier.testGroupSpeeds('g-a', nodes.sublist(0, 2));
    // 第一轮还在飞（直连探测被拖慢 300ms）：三路都进不去。
    expect(await notifier.testAllSpeeds(), isFalse);
    expect(await notifier.testSingleSpeed(nodes[0]), isFalse);
    expect(await notifier.testGroupSpeeds('g-b', nodes.sublist(2, 4)), isFalse);
    expect(await first, isTrue);
    final state = container.read(nodesProvider);
    expect(state.testingSpeed, isFalse);
    expect(state.testingGroupKey, isNull);
    expect(state.speedTestedCount, 2);
  });

  test('一键测速：开关开着但探活失败，改走直连并明确提示、不静默切换', () async {
    // 2026-11-26 二轮修复：只认 status == started 时，探活失败
    // （核心在跑、出站不通）会被当成“开关开着”走代理口径，delay
    // 全灭还分不清是代理不通还是直连不通。现在改走直连探测，
    // 但横幅写明是探活失败后改口径，结果不代表代理延迟。
    core.statusValue = CoreStatus.started;
    core.probeFailedValue = true;
    core.probeErrorValue = '代理出站拨测失败：拨测超时（10 秒无响应）';
    final notifier = await loadNodes();
    expect(await notifier.testAllSpeeds(), isTrue);

    final state = container.read(nodesProvider);
    expect(state.speedTestDirect, isTrue);
    expect(state.speedTestDirectFallback, isTrue);
    expect(state.speedTestError, contains('代理出站拨测失败'));
    expect(state.speedTestError, contains('改用直连探测'));
    expect(state.speedTestError, contains('不代表代理延迟'));
    // 直连探测没碰 Clash API：delay 接口一次没调。
    expect(delayHits, 0);
    final byName = {for (final n in state.nodes) n.name: n};
    expect(byName['香港-中转']!.latencyMs, 120);
    expect(byName['智利-直连']!.latencyMs, 86);
  });

  test('单节点测速：开关开着但探活失败，同样改走直连并写横幅', () async {
    core.statusValue = CoreStatus.started;
    core.probeFailedValue = true;
    core.probeErrorValue = '核心已启动但控制接口无响应';
    final notifier = await loadNodes();
    final node = container
        .read(nodesProvider)
        .nodes
        .firstWhere((n) => n.name == '智利-直连');
    expect(await notifier.testSingleSpeed(node), isTrue);

    final state = container.read(nodesProvider);
    expect(state.speedTestDirect, isTrue);
    expect(state.speedTestDirectFallback, isTrue);
    expect(state.speedTestError, contains('控制接口无响应'));
    expect(delayHits, 0);
    expect(node.latencyMs, 86);
  });

  test('自动选择：选延迟最低的可用节点，说明写清测了几个、失败几个', () async {
    core.statusValue = CoreStatus.started;
    final notifier = await loadNodes();
    expect(await notifier.autoSelect(), isTrue);

    final state = container.read(nodesProvider);
    expect(state.selectedNodeName, '智利-直连');
    expect(state.autoSelectEnabled, isTrue);
    expect(state.selectionReason, contains('智利-直连'));
    expect(state.selectionReason, contains('86ms'));
    expect(state.selectionReason, contains('共测 5 个'));
    expect(state.selectionReason, contains('2 个失败'));
    // 运行时切换走了 PUT，默认选择也落了盘。
    expect(putBodies, ['{"name":"智利-直连"}']);
    expect(core.persistedTags, ['智利-直连']);
  });

  test('自动选择：核心未启动时用直连延迟选，跳过选不了的 grpc 节点', () async {
    core.statusValue = CoreStatus.stopped;
    final notifier = await loadNodes();
    expect(await notifier.autoSelect(), isTrue);

    final state = container.read(nodesProvider);
    // grpc 直连最快（40ms）但配置里没有出站、选不了：跳过它选 86ms 的智利。
    expect(state.selectedNodeName, '智利-直连');
    expect(state.autoSelectEnabled, isTrue);
    expect(state.selectionReason, contains('直连延迟'));
    expect(state.selectionReason, contains('86ms'));
    expect(delayHits, 0);
    // 核心没启动：运行时切换不调接口，只落盘。
    expect(putBodies, isEmpty);
    expect(core.persistedTags, ['智利-直连']);
  });

  test('自动选择：已有结果时不再重测，直接选', () async {
    core.statusValue = CoreStatus.started;
    final notifier = await loadNodes();
    await notifier.testAllSpeeds();
    // 把假服务器的延迟改掉：如果重测，选出来的会变。
    delays['日本-直连'] = 10;
    expect(await notifier.autoSelect(), isTrue);
    expect(
      container.read(nodesProvider).selectedNodeName,
      '智利-直连',
    );
  });

  test('自动选择：全部失败时不选，原因写清楚', () async {
    core.statusValue = CoreStatus.started;
    delays.clear();
    final notifier = await loadNodes();
    expect(await notifier.autoSelect(), isFalse);
    final state = container.read(nodesProvider);
    expect(state.selectedNodeName, '智利-直连'); // 默认规则，没动
    expect(state.selectionReason, '全部节点测速失败，无法自动选择');
    expect(putBodies, isEmpty);
  });

  test('手动点节点：切换＋落盘，关掉自动选择开关', () async {
    core.statusValue = CoreStatus.started;
    final notifier = await loadNodes();
    await notifier.autoSelect();
    expect(container.read(nodesProvider).autoSelectEnabled, isTrue);

    final japan = container
        .read(nodesProvider)
        .nodes
        .firstWhere((n) => n.name == '日本-直连');
    expect(await notifier.selectNode(japan), isTrue);
    final state = container.read(nodesProvider);
    expect(state.selectedNodeName, '日本-直连');
    expect(state.autoSelectEnabled, isFalse);
    expect(state.selectionReason, contains('日本-直连'));
    expect(putBodies.last, '{"name":"日本-直连"}');
    expect(core.persistedTags.last, '日本-直连');
  });

  test('手动点不支持的节点：不切，原因写清楚', () async {
    core.statusValue = CoreStatus.started;
    final notifier = await loadNodes();
    final grpc = container
        .read(nodesProvider)
        .nodes
        .firstWhere((n) => n.name == 'grpc-直连');
    expect(await notifier.selectNode(grpc), isFalse);
    expect(
      container.read(nodesProvider).selectionReason,
      '该节点暂不支持，无法选择',
    );
    expect(putBodies, isEmpty);
  });

  test('核心没启动时点节点：只落盘不调接口，下次启动还用它', () async {
    core.statusValue = CoreStatus.stopped;
    final notifier = await loadNodes();
    final japan = container
        .read(nodesProvider)
        .nodes
        .firstWhere((n) => n.name == '日本-直连');
    expect(await notifier.selectNode(japan), isTrue);
    expect(
      container.read(nodesProvider).selectedNodeName,
      '日本-直连',
    );
    expect(putBodies, isEmpty);
    expect(core.persistedTags, ['日本-直连']);
  });

  test('核心切换失败（PUT 不通）：不切，选中节点保持原样', () async {
    core.statusValue = CoreStatus.started;
    final notifier = await loadNodes();
    // 把 PUT 接口搞坏：关掉假服务器再建一个只回 404 的。
    await apiServer.close(force: true);
    apiServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    apiServer.listen((request) async {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    // clashApiClient 仍指向旧端口（已关闭），PUT 直接连不上。
    final japan = container
        .read(nodesProvider)
        .nodes
        .firstWhere((n) => n.name == '日本-直连');
    expect(await notifier.selectNode(japan), isFalse);
    expect(
      container.read(nodesProvider).selectedNodeName,
      '智利-直连',
    );
    expect(
      container.read(nodesProvider).selectionReason,
      '切换失败，核心没有响应',
    );
    expect(core.persistedTags, isEmpty);
  });

  test('核心切换失败（PUT 回 400，名字不在组里）：原因不是“核心没有响应”', () async {
    core.statusValue = CoreStatus.started;
    final notifier = await loadNodes();
    // 假服务器 PUT 回 400：sing-box 对组里没有的名字就是这么回的。
    putStatus = HttpStatus.badRequest;
    final japan = container
        .read(nodesProvider)
        .nodes
        .firstWhere((n) => n.name == '日本-直连');
    expect(await notifier.selectNode(japan), isFalse);
    expect(
      container.read(nodesProvider).selectedNodeName,
      '智利-直连',
    );
    expect(
      container.read(nodesProvider).selectionReason,
      '切换失败，节点不在运行配置里',
    );
    expect(core.persistedTags, isEmpty);
  });

  test('手动点成组节点（问题 7）：PUT 与落盘用的都是组 tag', () async {
    core.statusValue = CoreStatus.started;
    // 双胞胎 A/B：三条入站同属一个节点，selector 里只占组 tag 一位。
    // 地址各不相同（合并按内容去重，同地址＋同 UUID 算同一条）。
    subscription.nodes = [
      _node('测试机-reality-443-A', NodeSource.direct, address: '203.0.113.1'),
      _node('测试机-reality-443-B', NodeSource.relay, address: '203.0.113.2'),
      _node('测试机-hy2-443-A', NodeSource.direct, address: '203.0.113.3'),
    ];
    final notifier = container.read(nodesProvider.notifier);
    await notifier.refresh();
    expect(container.read(nodesProvider).nodes.length, 3);
    final target = container
        .read(nodesProvider)
        .nodes
        .firstWhere((n) => n.name == '测试机-reality-443-A');
    expect(await notifier.selectNode(target), isTrue);
    final state = container.read(nodesProvider);
    expect(state.selectedNodeName, '测试机-reality-443-A');
    // 以前这里 PUT 的是自身 tag，sing-box 回 400、界面报“核心没有响应”；
    // 现在 PUT 组 tag，落盘的默认选择也是组 tag。
    expect(putBodies, ['{"name":"测试机"}']);
    expect(core.persistedTags, ['测试机']);
  });

  test('一键测速：504 标“超时不可达”，503 标“连接失败”', () async {
    core.statusValue = CoreStatus.started;
    subscription.nodes = [
      _node('智利-直连', NodeSource.direct, address: '203.0.113.2'),
      _node('slow-node', NodeSource.direct, address: '203.0.113.4'),
      _node('坏节点-直连', NodeSource.direct, address: '203.0.113.6'),
    ];
    final notifier = container.read(nodesProvider.notifier);
    await notifier.refresh();
    expect(await notifier.testAllSpeeds(), isTrue);
    final byName = {
      for (final n in container.read(nodesProvider).nodes) n.name: n,
    };
    expect(byName['智利-直连']!.latencyMs, 86);
    expect(byName['slow-node']!.latencyFailed, isTrue);
    expect(byName['slow-node']!.latencyFailureReason, '超时不可达');
    // 504 超时重试了一次（还是超时，原因不变）；503 快速失败不重试。
    expect(delayHitsByName['slow-node'], 2);
    expect(delayHitsByName['坏节点-直连'], 1);
    expect(byName['坏节点-直连']!.latencyFailed, isTrue);
    expect(byName['坏节点-直连']!.latencyFailureReason, '连接失败');
  });

  test('一键测速：超时失败重试一次，重试通了就记延迟', () async {
    core.statusValue = CoreStatus.started;
    subscription.nodes = [
      _node('flaky-node', NodeSource.direct, address: '203.0.113.2'),
    ];
    final notifier = container.read(nodesProvider.notifier);
    await notifier.refresh();
    expect(await notifier.testAllSpeeds(), isTrue);
    final node = container.read(nodesProvider).nodes.first;
    expect(node.latencyMs, 120);
    expect(node.latencyFailed, isFalse);
    expect(delayHitsByName['flaky-node'], 2);
  });

  test('一键测速：REALITY 节点 1 秒内就 503，原因写核心版本问题', () async {
    core.statusValue = CoreStatus.started;
    subscription.nodes = [
      _node(
        'reality-node',
        NodeSource.direct,
        address: '203.0.113.2',
        realityPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      ),
      _node('坏节点-直连', NodeSource.direct, address: '203.0.113.6'),
    ];
    final notifier = container.read(nodesProvider.notifier);
    await notifier.refresh();
    expect(await notifier.testAllSpeeds(), isTrue);
    final byName = {
      for (final n in container.read(nodesProvider).nodes) n.name: n,
    };
    expect(byName['reality-node']!.latencyFailed, isTrue);
    expect(
      byName['reality-node']!.latencyFailureReason,
      'REALITY 握手失败（核心版本问题，可能）',
    );
    // 非 REALITY 节点同样快速 503，还是笼统“连接失败”。
    expect(byName['坏节点-直连']!.latencyFailureReason, '连接失败');
  });

  test('一键测速：并发不超过 2 路', () async {
    core.statusValue = CoreStatus.started;
    subscription.nodes = [
      _node('香港-中转', NodeSource.relay, address: '203.0.113.1'),
      _node('智利-直连', NodeSource.direct, address: '203.0.113.2'),
      _node('日本-直连', NodeSource.direct, address: '203.0.113.3'),
      _node('flaky-node', NodeSource.direct, address: '203.0.113.7'),
    ];
    final notifier = container.read(nodesProvider.notifier);
    await notifier.refresh();
    expect(await notifier.testAllSpeeds(), isTrue);
    expect(maxConcurrent, lessThanOrEqualTo(2));
    // 4 个节点都要测到（flaky 重试后也通了）。
    final byName = {
      for (final n in container.read(nodesProvider).nodes) n.name: n,
    };
    expect(byName['flaky-node']!.latencyMs, 120);
  });

  test('一键测速：预热失败不阻塞测速', () async {
    core.statusValue = CoreStatus.started;
    // 预热拨的是 selector `Proxy`：假服务器里它不在 delays 表里，
    // 回 503（预热失败），后面的节点照样测。
    final notifier = await loadNodes();
    expect(await notifier.testAllSpeeds(), isTrue);
    final byName = {
      for (final n in container.read(nodesProvider).nodes) n.name: n,
    };
    expect(byName['智利-直连']!.latencyMs, 86);
  });

  test('刷新订阅：选中的节点还在就保留，不在了回落默认规则', () async {
    core.statusValue = CoreStatus.started;
    final notifier = await loadNodes();
    await notifier.autoSelect();
    expect(
      container.read(nodesProvider).selectedNodeName,
      '智利-直连',
    );

    // 订阅更新后智利节点没了：回落到第一个直连节点。
    // 地址各不相同（多订阅合并按内容去重，同地址＋同 UUID 算同一条）。
    subscription.nodes = [
      _node('香港-中转', NodeSource.relay, address: '203.0.113.1'),
      _node('日本-直连', NodeSource.direct, address: '203.0.113.3'),
    ];
    await notifier.refresh();
    expect(
      container.read(nodesProvider).selectedNodeName,
      '日本-直连',
    );

    // 订阅更新后智利节点还在：保留选中。
    subscription.nodes = _fiveNodes();
    await notifier.refresh();
    // 刷新后选中回落默认（日本没了？不，智利在列表里但 selected 被
    // 上次刷新改成了日本-直连，日本还在五节点里，所以保留日本）。
    expect(
      container.read(nodesProvider).selectedNodeName,
      '日本-直连',
    );
  });

  group('单个测试 testSingleSpeed', () {
    test('只测一个节点：只改这一行的延迟，其他行不动、不重排', () async {
      core.statusValue = CoreStatus.started;
      final notifier = await loadNodes();
      final nodes = container.read(nodesProvider).nodes;
      final target = nodes.firstWhere((n) => n.name == '智利-直连');
      expect(await notifier.testSingleSpeed(target), isTrue);
      final state = container.read(nodesProvider);
      expect(state.nodes.map((n) => n.name).toList(), [
        '香港-中转',
        '智利-直连',
        '日本-直连',
        '坏节点-直连',
        'grpc-直连',
      ]);
      expect(
        state.nodes
            .firstWhere((n) => n.name == '智利-直连')
            .latencyMs,
        86,
      );
      // 其他行没测过：延迟还是 null、没标失败。
      for (final n in state.nodes) {
        if (n.name == '智利-直连') continue;
        expect(n.latencyMs, isNull);
        expect(n.latencyFailed, isFalse);
      }
      expect(state.testingSingleNodeKey, isNull);
      expect(state.speedTestAt, isNotNull);
    });

    test('核心未启动：单个测速走直连探测，不调 Clash API', () async {
      core.statusValue = CoreStatus.stopped;
      final notifier = await loadNodes();
      final nodes = container.read(nodesProvider).nodes;
      final target = nodes.firstWhere((n) => n.name == '智利-直连');
      expect(await notifier.testSingleSpeed(target), isTrue);
      final state = container.read(nodesProvider);
      expect(state.speedTestDirect, isTrue);
      expect(delayHits, 0);
      expect(target.latencyMs, 86);
      expect(target.latencyFailed, isFalse);
      // 其他行没测过：延迟还是 null、没标失败。
      for (final n in state.nodes) {
        if (n.name == '智利-直连') continue;
        expect(n.latencyMs, isNull);
        expect(n.latencyFailed, isFalse);
      }
      expect(state.testingSingleNodeKey, isNull);
      expect(state.speedTestAt, isNotNull);
    });

    test('一键测速进行中：单个测试直接返回 false，不打架', () async {
      core.statusValue = CoreStatus.started;
      final notifier = await loadNodes();
      final nodes = container.read(nodesProvider).nodes;
      // 不 await：一键测速的同步段先把 testingSpeed 置 true，
      // 单个测试看到就直接返回。
      final allFuture = notifier.testAllSpeeds();
      expect(await notifier.testSingleSpeed(nodes.first), isFalse);
      await allFuture;
    });

    test('已有单节点在测：再点另一个直接返回 false', () async {
      core.statusValue = CoreStatus.started;
      final notifier = await loadNodes();
      final nodes = container.read(nodesProvider).nodes;
      final first = notifier.testSingleSpeed(nodes[0]);
      expect(await notifier.testSingleSpeed(nodes[1]), isFalse);
      await first;
    });

    test('测不到的节点标失败（配置里没有出站的 grpc 节点）', () async {
      core.statusValue = CoreStatus.started;
      final notifier = await loadNodes();
      final nodes = container.read(nodesProvider).nodes;
      final grpc = nodes.firstWhere((n) => n.name == 'grpc-直连');
      expect(await notifier.testSingleSpeed(grpc), isTrue);
      expect(grpc.latencyMs, isNull);
      expect(grpc.latencyFailed, isTrue);
    });
  });
}
