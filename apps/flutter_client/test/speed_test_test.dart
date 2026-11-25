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

  @override
  Future<void> init() async {}

  Future<void> close() => _stateController.close();
}

/// 核心桩：状态手动给，updateSelectorDefault 只记调用。
class _StubCoreService extends CoreService {
  _StubCoreService() : super(plugin: _FakePlugin());

  CoreStatus statusValue = CoreStatus.stopped;
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

Node _node(
  String name,
  NodeSource source, {
  String transport = 'tcp',
  String address = '203.0.113.1',
}) => Node(
  name: name,
  protocol: NodeProtocol.vless,
  address: address,
  port: 443,
  source: source,
  uuidOrPassword: '11111111-2222-3333-4444-555555555555',
  transport: transport,
  tls: true,
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
  late Map<String, int?> delays;
  late _StubCoreService core;
  late _StubSubscriptionService subscription;
  late ProviderContainer container;

  /// 起一个 Clash API 假服务器：delay 按 [delays] 表给数，
  /// 没在表里的返回 503；PUT /proxies/Proxy 记 body、回 204。
  Future<String> startApiServer() async {
    putBodies = [];
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
          final response = request.response;
          response.headers.contentType = ContentType.json;
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
          request.response.statusCode = HttpStatus.noContent;
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

  test('一键测速：核心未启动时不发请求，直接报原因', () async {
    core.statusValue = CoreStatus.stopped;
    final notifier = await loadNodes();
    expect(await notifier.testAllSpeeds(), isFalse);
    final state = container.read(nodesProvider);
    expect(state.speedTestError, '核心未启动，先在首页打开开关再测速');
    expect(
      state.nodes.every((n) => n.latencyMs == null),
      isTrue,
    );
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

    test('核心未启动：不发请求，报和一键测速一样的提示', () async {
      core.statusValue = CoreStatus.stopped;
      final notifier = await loadNodes();
      final nodes = container.read(nodesProvider).nodes;
      expect(
        await notifier.testSingleSpeed(nodes.first),
        isFalse,
      );
      final state = container.read(nodesProvider);
      expect(
        state.speedTestError,
        '核心未启动，先在首页打开开关再测速',
      );
      expect(nodes.first.latencyMs, isNull);
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
