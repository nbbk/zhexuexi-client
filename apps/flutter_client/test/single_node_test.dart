// 单个节点添加（第 7 项）与扫码/粘贴分流落到实处（第 6、7、10 项）：
// 单节点存储、与订阅节点的合并、handleContent 的端到端路由。
//
// 不碰真面板与真密钥库：订阅服务用桩，安全存储用内存 fake，
// 地址用 SharedPreferences mock。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/services/content_intake.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/node_override_store.dart';
import 'package:zhexuexi_client/services/single_node_store.dart';
import 'package:zhexuexi_client/services/subscription_parser.dart';
import 'package:zhexuexi_client/services/subscription_service.dart';
import 'package:zhexuexi_client/services/subscription_store.dart';
import 'package:zhexuexi_client/services/subscriptions_notifier.dart';

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

/// 订阅桩：按完整地址给节点列表或抛错，不拉网络、不碰密钥库。
class _StubSubscriptionService extends SubscriptionService {
  _StubSubscriptionService({super.storage});

  String? primaryUrl;
  final Map<String, NodeListResult> results = {};
  final Map<String, SubscriptionException> failures = {};

  @override
  Future<String?> readSubscriptionUrl() async => primaryUrl;

  @override
  Future<void> updateBaseUrl(String base) async {}

  @override
  Future<NodeListResult> fetchNodes({
    required String subscriptionUrl,
  }) async {
    final failure = failures[subscriptionUrl];
    if (failure != null) throw failure;
    final result = results[subscriptionUrl];
    if (result == null) {
      throw const SubscriptionException(
        kind: SubscriptionErrorKind.network,
        message: '网络不通，检查订阅地址',
      );
    }
    return result;
  }
}

const _uuid = '11111111-2222-3333-4444-555555555555';

/// 面板 1.4.22/1.4.23“复制链接”生成的标准 VLESS 单条链接
///（REALITY，-A 直连后缀，带用户 UUID）。
const _vlessLink =
    'vless://$_uuid@203.0.113.1:443'
    '?encryption=none&security=reality'
    '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    '&sid=abcdef01&sni=www.microsoft.com&fp=chrome&type=tcp'
    '&flow=xtls-rprx-vision#测试机-reality-443-A';

/// 面板单条 HY2 链接（-A 直连后缀，带用户 UUID）。
const _hy2Link =
    'hysteria2://$_uuid@203.0.113.1:443'
    '?sni=hy2test.example.com&alpn=h3#测试机-hy2-443-A';

const _primaryUrl =
    'https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _customUrlA = 'https://airport-a.example.com/sub/aaaa1111';
const _customUrlB = 'https://airport-b.example.com/sub/bbbb2222';

Node _node(
  String name, {
  String address = '203.0.113.1',
  int port = 443,
}) => Node(
  name: name,
  protocol: NodeProtocol.vless,
  address: address,
  port: port,
  source: NodeSource.direct,
  uuidOrPassword: _uuid,
  tls: true,
);

NodeListResult _result(List<Node> nodes) => NodeListResult(
  nodes: nodes,
  failedCount: 0,
  userinfo: null,
  format: SubscriptionFormat.singbox,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SingleNodeStore', () {
    test('VLESS 单条链接：能加上，字段齐全，来源是直连（-A）', () async {
      final store = SingleNodeStore(storage: _FakeSecureStorage());
      final added = await store.addSingleNode(_vlessLink);
      expect(added.error, isNull);
      final node = added.node!;
      expect(node.name, '测试机-reality-443-A');
      expect(node.protocol, NodeProtocol.vless);
      expect(node.address, '203.0.113.1');
      expect(node.port, 443);
      expect(node.source, NodeSource.direct);
      expect(node.uuidOrPassword, _uuid);
      expect(node.tls, isTrue);
      expect(node.sni, 'www.microsoft.com');
      expect(node.realityPublicKey,
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
      expect(node.flow, 'xtls-rprx-vision');
      expect((await store.listNodes()).length, 1);
    });

    test('HY2 单条链接：能加上，TLS、SNI、ALPN 都在', () async {
      final store = SingleNodeStore(storage: _FakeSecureStorage());
      final added = await store.addSingleNode(_hy2Link);
      expect(added.error, isNull);
      final node = added.node!;
      expect(node.name, '测试机-hy2-443-A');
      expect(node.protocol, NodeProtocol.hysteria2);
      expect(node.tls, isTrue);
      expect(node.transport, 'udp');
      expect(node.sni, 'hy2test.example.com');
      expect(node.alpn, 'h3');
    });

    test('解析不出的链接：拒绝并给原因，不写存储', () async {
      final store = SingleNodeStore(storage: _FakeSecureStorage());
      final added = await store.addSingleNode('not-a-node-link');
      expect(added.error, isNotNull);
      expect(added.node, isNull);
      expect(await store.listNodes(), isEmpty);
    });

    test('同一条节点加两次：第二次拒绝，列表里只有一条', () async {
      final store = SingleNodeStore(storage: _FakeSecureStorage());
      expect((await store.addSingleNode(_vlessLink)).error, isNull);
      final again = await store.addSingleNode(_vlessLink);
      expect(again.error, '这个节点已经加过了');
      expect((await store.listNodes()).length, 1);
    });

    test('删除单节点：删完列表空了，再删返回 false', () async {
      final store = SingleNodeStore(storage: _FakeSecureStorage());
      await store.addSingleNode(_vlessLink);
      await store.addSingleNode(_hy2Link);
      final key = (await store.listNodes()).first.dedupKey;
      expect(await store.removeSingleNode(key), isTrue);
      expect((await store.listNodes()).length, 1);
      expect(await store.removeSingleNode(key), isFalse);
    });

    test('订阅正文：sing-box JSON 一段存进去，解出两个节点', () async {
      final store = SingleNodeStore(storage: _FakeSecureStorage());
      final result = await store.addContent('''
{
  "outbounds": [
    {"type": "vless", "tag": "正文节点-A",
     "server": "203.0.113.1", "server_port": 443, "uuid": "$_uuid"},
    {"type": "hysteria2", "tag": "正文节点-B",
     "server": "203.0.113.2", "server_port": 443, "password": "$_uuid",
     "tls": {"enabled": true, "server_name": "example.com"}}
  ]
}
''');
      expect(result.error, isNull);
      expect(result.addedCount, 2);
      expect(
        (await store.listNodes()).map((n) => n.name).toList(),
        ['正文节点-A', '正文节点-B'],
      );
    });

    test('订阅正文：解不出节点、或全已存在时拒绝', () async {
      final store = SingleNodeStore(storage: _FakeSecureStorage());
      expect(
        (await store.addContent('garbage')).error,
        '内容里没有能识别的节点',
      );
      await store.addSingleNode(_vlessLink);
      expect(
        (await store.addContent(_vlessLink)).error,
        '这些节点已经加过了',
      );
    });
  });

  group('NodesNotifier：单节点与订阅节点合并', () {
    late _FakeSecureStorage storage;
    late _StubSubscriptionService service;
    late ProviderContainer container;

    Future<void> buildContainer({String? primaryUrl}) async {
      storage = _FakeSecureStorage();
      service = _StubSubscriptionService(storage: storage)
        ..primaryUrl = primaryUrl;
      container = ProviderContainer(
        overrides: [
          subscriptionServiceProvider.overrideWithValue(service),
          subscriptionStoreProvider.overrideWithValue(
            SubscriptionStore(storage: storage),
          ),
          singleNodeStoreProvider.overrideWithValue(
            SingleNodeStore(storage: storage),
          ),
          nodeOverrideStoreProvider.overrideWithValue(
            NodeOverrideStore(storage: storage),
          ),
        ],
      );
      addTearDown(container.dispose);
    }

    test('只有单节点、没有订阅：也显示，状态是 loaded', () async {
      await buildContainer();
      final store = container.read(singleNodeStoreProvider);
      await store.addSingleNode(_vlessLink);
      await store.addSingleNode(_hy2Link);
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.status, NodesStatus.loaded);
      expect(
        state.nodes.map((n) => n.name).toList(),
        ['测试机-reality-443-A', '测试机-hy2-443-A'],
      );
      expect(state.selectedNodeName, '测试机-reality-443-A');
    });

    test('单节点拼在订阅节点后面，来源标“手动添加”', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      service.results[_primaryUrl] = _result([_node('订阅节点')]);
      final store = container.read(singleNodeStoreProvider);
      await store.addSingleNode(_vlessLink);
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(
        state.nodes.map((n) => n.name).toList(),
        ['订阅节点', '测试机-reality-443-A'],
      );
      expect(state.nodes[1].subscriptionId, SingleNodeStore.singleNodesId);
      expect(
        state.nodes[1].subscriptionName,
        SingleNodeStore.singleNodesName,
      );
    });

    test('内容与订阅节点相同时订阅优先，只留一条', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      // 订阅节点与 VLESS 链接内容完全相同（同地址/端口/UUID/SNI/
      // REALITY/flow），去重键相等，合并时只留订阅那条。
      service.results[_primaryUrl] = _result([
        Node(
          name: '订阅里的同名节点',
          protocol: NodeProtocol.vless,
          address: '203.0.113.1',
          port: 443,
          source: NodeSource.direct,
          uuidOrPassword: _uuid,
          transport: 'tcp',
          tls: true,
          sni: 'www.microsoft.com',
          realityPublicKey:
              'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          realityShortId: 'abcdef01',
          fingerprint: 'chrome',
          flow: 'xtls-rprx-vision',
        ),
      ]);
      final store = container.read(singleNodeStoreProvider);
      await store.addSingleNode(_vlessLink);
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.nodes.length, 1);
      expect(state.nodes.first.name, '订阅里的同名节点');
    });

    test('单个刷新后单节点还在', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      final customId =
          (await container
                  .read(subscriptionStoreProvider)
                  .addCustom(_customUrlA))
              .entry!
              .id;
      service.results[_primaryUrl] = _result([_node('订阅节点')]);
      service.results[_customUrlA] = _result([_node('机场 A')]);
      final store = container.read(singleNodeStoreProvider);
      await store.addSingleNode(_hy2Link);
      final notifier = container.read(nodesProvider.notifier);
      await notifier.refresh();
      service.results[_customUrlA] = _result([
        _node('机场 A 新', address: '203.0.113.9'),
      ]);
      expect(await notifier.refreshSubscription(customId), isTrue);
      expect(
        container.read(nodesProvider).nodes.map((n) => n.name).toList(),
        ['订阅节点', '机场 A 新', '测试机-hy2-443-A'],
      );
    });

    test('notifier.addSingleNode：成功返回 null、失败返回原因', () async {
      await buildContainer();
      final notifier = container.read(nodesProvider.notifier);
      expect(await notifier.addSingleNode(_vlessLink), isNull);
      expect(
        container.read(nodesProvider).nodes.map((n) => n.name).toList(),
        ['测试机-reality-443-A'],
      );
      expect(
        await notifier.addSingleNode('garbage'),
        '这条节点链接解析不出来，检查是不是复制全了',
      );
    });

    test('notifier.addNodesFromContent：JSON 正文一次加两个', () async {
      await buildContainer();
      final notifier = container.read(nodesProvider.notifier);
      final result = await notifier.addNodesFromContent('''
{
  "outbounds": [
    {"type": "vless", "tag": "正文节点-A",
     "server": "203.0.113.1", "server_port": 443, "uuid": "$_uuid"},
    {"type": "hysteria2", "tag": "正文节点-B",
     "server": "203.0.113.2", "server_port": 443, "password": "$_uuid",
     "tls": {"enabled": true, "server_name": "example.com"}}
  ]
}
''');
      expect(result.error, isNull);
      expect(result.addedCount, 2);
      expect(container.read(nodesProvider).nodes.length, 2);
    });
  });

  group('handleContent 端到端（粘贴/扫码同一条路）', () {
    late _FakeSecureStorage storage;
    late _StubSubscriptionService service;
    late ProviderContainer container;

    Future<void> buildContainer() async {
      storage = _FakeSecureStorage();
      service = _StubSubscriptionService(storage: storage);
      container = ProviderContainer(
        overrides: [
          subscriptionServiceProvider.overrideWithValue(service),
          subscriptionStoreProvider.overrideWithValue(
            SubscriptionStore(storage: storage),
          ),
          singleNodeStoreProvider.overrideWithValue(
            SingleNodeStore(storage: storage),
          ),
          nodeOverrideStoreProvider.overrideWithValue(
            NodeOverrideStore(storage: storage),
          ),
        ],
      );
      addTearDown(container.dispose);
    }

    /// 挂一个最小的 Consumer，拿一个能调 handleContent 的 WidgetRef。
    /// 必须复用同一个 container（UncontrolledProviderScope），
    /// 不然 handleContent 写的状态和断言读的不是同一份。
    Future<WidgetRef> pumpRef(WidgetTester tester) async {
      late WidgetRef captured;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return const MaterialApp(home: SizedBox());
            },
          ),
        ),
      );
      return captured;
    }

    testWidgets('单条 VLESS 链接 → 加为单节点', (tester) async {
      await buildContainer();
      final ref = await pumpRef(tester);
      final result = await handleContent(ref, _vlessLink);
      expect(result.error, isNull);
      expect(result.message, '已添加节点');
      expect(
        container.read(nodesProvider).nodes.map((n) => n.name).toList(),
        ['测试机-reality-443-A'],
      );
    });

    testWidgets('机场订阅链接 → 往多订阅列表里加，不顶掉旧的', (tester) async {
      await buildContainer();
      service.results[_customUrlA] = _result([_node('机场 A')]);
      service.results[_customUrlB] = _result([
        _node('机场 B', address: '203.0.113.2'),
      ]);
      final ref = await pumpRef(tester);
      expect((await handleContent(ref, _customUrlA)).error, isNull);
      expect((await handleContent(ref, _customUrlB)).error, isNull);
      expect(container.read(subscriptionsProvider).length, 2);
      expect(
        container.read(nodesProvider).nodes.map((n) => n.name).toList(),
        ['机场 A', '机场 B'],
      );
    });

    testWidgets('无法识别的内容 → 返回原因，什么都不写', (tester) async {
      await buildContainer();
      final ref = await pumpRef(tester);
      final result = await handleContent(ref, 'garbage');
      expect(result.error, '内容无法识别：不是节点链接，也不是订阅链接');
      expect(container.read(nodesProvider).nodes, isEmpty);
      expect(container.read(subscriptionsProvider), isEmpty);
    });

    testWidgets('自家面板订阅链接 410 → 报退场原因，不当成到期', (tester) async {
      await buildContainer();
      const primaryLink =
          'https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      service.primaryUrl = primaryLink;
      service.failures[primaryLink] = const SubscriptionException(
        kind: SubscriptionErrorKind.retired,
        message: '该订阅已退场，请使用订阅用户的新订阅链接',
      );
      final ref = await pumpRef(tester);
      final result = await handleContent(ref, primaryLink);
      expect(result.error, '该订阅已退场，请使用订阅用户的新订阅链接');
      expect(result.message, isNull);
      expect(container.read(nodesProvider).status, NodesStatus.error);
    });
  });
}
