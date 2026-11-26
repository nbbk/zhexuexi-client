// 多订阅：存储（主订阅＋手动加的订阅）、合并去重、
// 各自 userinfo、管理页的回归测试。
//
// 不碰真面板与真密钥库：订阅服务用桩（按地址给节点列表或抛错），
// 安全存储用内存 fake，地址用 SharedPreferences mock。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/userinfo.dart';
import 'package:zhexuexi_client/features/nodes/nodes_page.dart';
import 'package:zhexuexi_client/features/nodes/subscriptions_page.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
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
  String? primaryUrl;
  final calls = <String>[];
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
    calls.add(subscriptionUrl);
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

Node _node(
  String name, {
  String address = '203.0.113.1',
  int port = 443,
  String uuid = '11111111-2222-3333-4444-555555555555',
}) => Node(
  name: name,
  protocol: NodeProtocol.vless,
  address: address,
  port: port,
  source: NodeSource.direct,
  uuidOrPassword: uuid,
  tls: true,
);

NodeListResult _result(
  List<Node> nodes, {
  SubscriptionUserinfo? userinfo,
}) => NodeListResult(
  nodes: nodes,
  failedCount: 0,
  userinfo: userinfo,
  format: SubscriptionFormat.singbox,
);

const _primaryUrl =
    'https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _customUrl = 'https://airport.example.com/sub/abcdef123456';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SubscriptionStore', () {
    test('手动加订阅：默认名取 host，启用，整条进安全存储', () async {
      final storage = _FakeSecureStorage();
      final store = SubscriptionStore(storage: storage);
      final added = await store.addCustom(_customUrl);
      expect(added.error, isNull);
      expect(added.entry!.name, 'airport.example.com');
      expect(added.entry!.enabled, isTrue);
      expect(added.entry!.isPrimary, isFalse);
      final listed = await store.listCustom();
      expect(listed.length, 1);
      expect(listed.first.url, _customUrl);
      // 订阅链接不在 SharedPreferences 里（令牌只进系统密钥库）。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('custom_subscriptions'), isNull);
      expect(await storage.read(key: 'custom_subscriptions'), isNotNull);
    });

    test('连续加两个订阅：两个都存着，谁也不顶掉谁', () async {
      final store = SubscriptionStore(storage: _FakeSecureStorage());
      expect((await store.addCustom(_customUrl)).error, isNull);
      const second = 'https://airport-b.example.com/sub/bbbb2222';
      expect((await store.addCustom(second)).error, isNull);
      final listed = await store.listCustom();
      expect(listed.length, 2);
      expect(listed.map((e) => e.url).toList(), [_customUrl, second]);
    });

    test('同一条订阅链接加两次：第二次拒绝，列表里只有一条', () async {
      final store = SubscriptionStore(storage: _FakeSecureStorage());
      expect((await store.addCustom(_customUrl)).error, isNull);
      expect(
        (await store.addCustom(_customUrl)).error,
        '这个订阅已经加过了',
      );
      expect((await store.listCustom()).length, 1);
    });

    test('链接不是合法 http(s) URL：拒绝并给原因', () async {
      final store = SubscriptionStore(storage: _FakeSecureStorage());
      expect(
        (await store.addCustom('not a url')).error,
        '订阅链接不对，要以 http:// 或 https:// 开头',
      );
      expect(
        (await store.addCustom('ftp://example.com/sub')).error,
        isNotNull,
      );
      expect((await store.listCustom()).length, 0);
      // 不要求令牌以 sub_ 开头：XBoard 格式的链接直接收。
      final ok = await store.addCustom(_customUrl);
      expect(ok.error, isNull);
    });

    test('改名 / 停用 / 删除手动加的订阅', () async {
      final store = SubscriptionStore(storage: _FakeSecureStorage());
      final id = (await store.addCustom(_customUrl)).entry!.id;
      expect(await store.rename(id, '机场 A'), isTrue);
      expect((await store.listCustom()).first.name, '机场 A');
      expect(await store.rename(id, '  '), isFalse);
      expect(await store.setEnabled(id, false), isTrue);
      expect((await store.listCustom()).first.enabled, isFalse);
      expect(await store.removeCustom(id), isTrue);
      expect(await store.listCustom(), isEmpty);
      expect(await store.removeCustom(id), isFalse);
    });

    test('主订阅不给删；主订阅改名与停用走 prefs', () async {
      final store = SubscriptionStore(storage: _FakeSecureStorage());
      expect(
        await store.removeCustom(SubscriptionEntry.primaryId),
        isFalse,
      );
      expect(
        await store.rename(SubscriptionEntry.primaryId, '我的面板'),
        isTrue,
      );
      expect(await store.setEnabled(SubscriptionEntry.primaryId, false), isTrue);
      final listed = await store.listSubscriptions(primaryUrl: _primaryUrl);
      expect(listed.length, 1);
      expect(listed.first.isPrimary, isTrue);
      expect(listed.first.name, '我的面板');
      expect(listed.first.enabled, isFalse);
    });

    test('老单个订阅平滑成主订阅：不丢绑定，默认名“自家面板”', () async {
      final storage = _FakeSecureStorage();
      final service = SubscriptionService(storage: storage);
      await service.saveSubscriptionLink(_primaryUrl);
      final store = SubscriptionStore(storage: storage);
      final listed = await store.listSubscriptions(
        primaryUrl: await service.readSubscriptionUrl(),
      );
      expect(listed.length, 1);
      expect(listed.first.id, SubscriptionEntry.primaryId);
      expect(listed.first.name, '自家面板');
      expect(listed.first.url, _primaryUrl);
      expect(listed.first.enabled, isTrue);
      expect(await store.listCustom(), isEmpty);
    });

    test('没有主订阅时列表只有手动加的', () async {
      final store = SubscriptionStore(storage: _FakeSecureStorage());
      await store.addCustom(_customUrl);
      final listed = await store.listSubscriptions(primaryUrl: null);
      expect(listed.length, 1);
      expect(listed.first.isPrimary, isFalse);
    });

    test('存坏的 JSON 按空列表算，不拖垮列表', () async {
      final storage = _FakeSecureStorage();
      await storage.write(key: 'custom_subscriptions', value: 'not json');
      final store = SubscriptionStore(storage: storage);
      expect(await store.listCustom(), isEmpty);
    });
  });

  group('NodesNotifier 多订阅合并', () {
    late _FakeSecureStorage storage;
    late _StubSubscriptionService service;
    late ProviderContainer container;

    Future<void> buildContainer({String? primaryUrl}) async {
      storage = _FakeSecureStorage();
      service = _StubSubscriptionService()..primaryUrl = primaryUrl;
      container = ProviderContainer(
        overrides: [
          subscriptionServiceProvider.overrideWithValue(service),
          subscriptionStoreProvider.overrideWithValue(
            SubscriptionStore(storage: storage),
          ),
        ],
      );
      addTearDown(container.dispose);
    }

    Future<SubscriptionEntry> addCustom() async {
      final store = container.read(subscriptionStoreProvider);
      return (await store.addCustom(_customUrl)).entry!;
    }

    test('合并：主订阅在前，内容相同的只留第一条（主订阅优先）', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      final custom = await addCustom();
      final shared = _node('共享节点', address: '203.0.113.10');
      final renamedSameContent = _node('共享节点-别名', address: '203.0.113.10');
      service.results[_primaryUrl] = _result([
        _node('自家 A'),
        shared,
      ]);
      service.results[_customUrl] = _result([
        renamedSameContent,
        _node('机场 B', address: '203.0.113.2'),
      ]);
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.status, NodesStatus.loaded);
      expect(
        state.nodes.map((n) => n.name).toList(),
        ['自家 A', '共享节点', '机场 B'],
      );
      // 去重留的是主订阅那条，来源也是主订阅。
      expect(state.nodes[1].subscriptionId, SubscriptionEntry.primaryId);
      expect(state.nodes[1].subscriptionName, '自家面板');
      expect(state.nodes[2].subscriptionId, custom.id);
      expect(state.nodes[2].subscriptionName, 'airport.example.com');
      expect(service.calls, [_primaryUrl, _customUrl]);
    });

    test('两个手动订阅同时挂载：节点合并，摘要各一条', () async {
      await buildContainer();
      const secondUrl = 'https://airport-b.example.com/sub/bbbb2222';
      final store = container.read(subscriptionStoreProvider);
      await store.addCustom(_customUrl);
      await store.addCustom(secondUrl);
      service.results[_customUrl] = _result([
        _node('机场 A', address: '203.0.113.2'),
      ]);
      service.results[secondUrl] = _result([
        _node('机场 B', address: '203.0.113.3'),
      ]);
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.status, NodesStatus.loaded);
      expect(
        state.nodes.map((n) => n.name).toList(),
        ['机场 A', '机场 B'],
      );
      expect(state.subscriptionSummaries.length, 2);
      expect(
        state.subscriptionSummaries.map((s) => s.nodeCount).toList(),
        [1, 1],
      );
    });

    test('一条订阅拉取失败不影响其他条：有成功就显示合并节点', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      await addCustom();
      service.results[_primaryUrl] = _result([_node('自家 A')]);
      service.failures[_customUrl] = const SubscriptionException(
        kind: SubscriptionErrorKind.network,
        message: '网络不通，检查订阅地址',
      );
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.status, NodesStatus.loaded);
      expect(state.nodes.map((n) => n.name).toList(), ['自家 A']);
      expect(state.subscriptionSummaries.length, 2);
      expect(state.subscriptionSummaries[0].errorMessage, isNull);
      expect(state.subscriptionSummaries[0].nodeCount, 1);
      expect(
        state.subscriptionSummaries[1].errorMessage,
        '网络不通，检查订阅地址',
      );
      expect(state.subscriptionSummaries[1].nodeCount, 0);
    });

    test('全部失败才报错误状态', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      await addCustom();
      service.failures[_primaryUrl] = const SubscriptionException(
        kind: SubscriptionErrorKind.network,
        message: '网络不通，检查订阅地址',
      );
      service.failures[_customUrl] = const SubscriptionException(
        kind: SubscriptionErrorKind.network,
        message: '网络不通，检查订阅地址',
      );
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.status, NodesStatus.error);
      expect(state.errorMessage, '网络不通，检查订阅地址');
      expect(state.nodes, isEmpty);
    });

    test('各自 userinfo 分别显示；state.userinfo 仍是主订阅那一份', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      await addCustom();
      service.results[_primaryUrl] = _result(
        [_node('自家 A')],
        userinfo: SubscriptionUserinfo.parse(
          'upload=100; download=200; total=1000; expire=1798765432',
        ),
      );
      service.results[_customUrl] = _result(
        [_node('机场 B', address: '203.0.113.2')],
        userinfo: SubscriptionUserinfo.parse(
          'upload=10; download=20; total=500; expire=1798765432',
        ),
      );
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.userinfo?.used, 300);
      expect(state.userinfo?.total, 1000);
      expect(state.subscriptionSummaries[0].userinfo?.used, 300);
      expect(state.subscriptionSummaries[1].userinfo?.used, 30);
      expect(state.subscriptionSummaries[1].userinfo?.total, 500);
    });

    test('没有 userinfo 头的订阅对应项为 null（界面显示“—”）', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      await addCustom();
      service.results[_primaryUrl] = _result([_node('自家 A')]);
      service.results[_customUrl] = _result([
        _node('机场 B', address: '203.0.113.2'),
      ]);
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.userinfo, isNull);
      expect(state.subscriptionSummaries[1].userinfo, isNull);
    });

    test('停用的订阅不拉、节点不显示', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      final custom = await addCustom();
      final store = container.read(subscriptionStoreProvider);
      await store.setEnabled(custom.id, false);
      service.results[_primaryUrl] = _result([_node('自家 A')]);
      service.results[_customUrl] = _result([_node('机场 B')]);
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.nodes.map((n) => n.name).toList(), ['自家 A']);
      expect(service.calls, [_primaryUrl]);
      expect(state.subscriptionSummaries[1].enabled, isFalse);
      expect(state.subscriptionSummaries[1].nodeCount, 0);
    });

    test('单个刷新只重拉那一条，其余用缓存', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      final custom = await addCustom();
      service.results[_primaryUrl] = _result([_node('自家 A')]);
      service.results[_customUrl] = _result([
        _node('机场 B', address: '203.0.113.2'),
      ]);
      final notifier = container.read(nodesProvider.notifier);
      await notifier.refresh();
      service.calls.clear();
      service.results[_customUrl] = _result([
        _node('机场 C', address: '203.0.113.3'),
      ]);
      expect(await notifier.refreshSubscription(custom.id), isTrue);
      expect(service.calls, [_customUrl]);
      final state = container.read(nodesProvider);
      expect(
        state.nodes.map((n) => n.name).toList(),
        ['自家 A', '机场 C'],
      );
    });

    test('没有订阅时保持 initial 状态', () async {
      await buildContainer();
      await container.read(nodesProvider.notifier).refresh();
      expect(container.read(nodesProvider).status, NodesStatus.initial);
    });

    test('主订阅 404 不重试手动加的订阅：自定义订阅 404 只记该条错误', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      await addCustom();
      service.results[_primaryUrl] = _result([_node('自家 A')]);
      service.failures[_customUrl] = const SubscriptionException(
        kind: SubscriptionErrorKind.invalid,
        message: '订阅已失效，请重新绑定',
      );
      await container.read(nodesProvider.notifier).refresh();
      final state = container.read(nodesProvider);
      expect(state.status, NodesStatus.loaded);
      expect(state.nodes.map((n) => n.name).toList(), ['自家 A']);
      expect(
        state.subscriptionSummaries[1].errorMessage,
        '订阅已失效，请重新绑定',
      );
    });

    test('选中节点：合并后名字还在就保留，不在回落默认', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      await addCustom();
      service.results[_primaryUrl] = _result([_node('自家 A')]);
      service.results[_customUrl] = _result([
        _node('机场 B', address: '203.0.113.2'),
      ]);
      final notifier = container.read(nodesProvider.notifier);
      await notifier.refresh();
      expect(
        container.read(nodesProvider).selectedNodeName,
        '自家 A',
      );
      // 手动加的订阅被删后，它的节点不在了，选中回落到剩下的默认节点。
      final store = container.read(subscriptionStoreProvider);
      final custom = (await store.listCustom()).first;
      await store.removeCustom(custom.id);
      await notifier.refresh();
      expect(
        container.read(nodesProvider).selectedNodeName,
        '自家 A',
      );
    });
  });

  group('SubscriptionsNotifier', () {
    test('添加 / 改名 / 停用 / 删除后列表与节点跟着变', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = _FakeSecureStorage();
      final service = _StubSubscriptionService()..primaryUrl = _primaryUrl;
      service.results[_primaryUrl] = _result([_node('自家 A')]);
      service.results[_customUrl] = _result([
        _node('机场 B', address: '203.0.113.2'),
      ]);
      final container = ProviderContainer(
        overrides: [
          subscriptionServiceProvider.overrideWithValue(service),
          subscriptionStoreProvider.overrideWithValue(
            SubscriptionStore(storage: storage),
          ),
        ],
      );
      addTearDown(container.dispose);
      final listNotifier = container.read(subscriptionsProvider.notifier);
      await listNotifier.load();
      expect(container.read(subscriptionsProvider).length, 1);
      expect(await listNotifier.add('not a url'), isNotNull);
      expect(await listNotifier.add(_customUrl), isNull);
      expect(container.read(subscriptionsProvider).length, 2);
      expect(
        container.read(nodesProvider).nodes.map((n) => n.name).toList(),
        ['自家 A', '机场 B'],
      );
      final customId = container
          .read(subscriptionsProvider)
          .firstWhere((e) => !e.isPrimary)
          .id;
      expect(await listNotifier.rename(customId, '机场 A'), isTrue);
      expect(
        container
            .read(subscriptionsProvider)
            .firstWhere((e) => e.id == customId)
            .name,
        '机场 A',
      );
      expect(await listNotifier.setEnabled(customId, false), isTrue);
      expect(
        container.read(nodesProvider).nodes.map((n) => n.name).toList(),
        ['自家 A'],
      );
      expect(await listNotifier.remove(customId), isTrue);
      expect(container.read(subscriptionsProvider).length, 1);
      // 主订阅不给删。
      expect(
        await listNotifier.remove(SubscriptionEntry.primaryId),
        isFalse,
      );
    });
  });

  group('管理页与节点页 widget', () {
    testWidgets('管理页：列出订阅，主订阅无删除按钮，手动加的有', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final storage = _FakeSecureStorage();
      final store = SubscriptionStore(storage: storage);
      await store.addCustom(_customUrl);
      final service = _StubSubscriptionService()..primaryUrl = _primaryUrl;
      service.results[_primaryUrl] = _result([_node('自家 A')]);
      service.results[_customUrl] = _result([_node('机场 B')]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subscriptionServiceProvider.overrideWithValue(service),
            subscriptionStoreProvider.overrideWithValue(store),
          ],
          child: const MaterialApp(home: SubscriptionsPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('自家面板'), findsOneWidget);
      // 手动加的默认名就是 host，名字行与 host 行各出现一次。
      expect(find.text('airport.example.com'), findsNWidgets(2));
      expect(find.text('example.com'), findsOneWidget);
      expect(find.text('添加订阅'), findsOneWidget);
      expect(find.text('扫码'), findsOneWidget);
      // 删除按钮只有手动加的那一条有。
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('改名'), findsNWidgets(2));
      expect(find.byType(Switch), findsNWidgets(2));
    });

    testWidgets('节点行不再显示来源小标签（来源只在订阅列表里）', (tester) async {
      // 来源用构造参数传（字段是 final，数据层保留，只是不显示）。
      final tagged = Node(
        name: '机场 B',
        protocol: NodeProtocol.vless,
        address: '203.0.113.2',
        port: 443,
        source: NodeSource.direct,
        uuidOrPassword: '11111111-2222-3333-4444-555555555555',
        tls: true,
        subscriptionId: 'custom_1',
        subscriptionName: '机场 A',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            nodesProvider.overrideWith(() => _StubNodesNotifier(tagged)),
          ],
          child: const MaterialApp(home: Scaffold(body: NodesPage())),
        ),
      );
      await tester.pumpAndSettle();
      // 分组默认折叠：先点组头展开（组头标题是订阅名＋数量），行才渲染；
      // 来源只出现在组头，不在节点行里。
      await tester.tap(find.text('机场 A（1）'));
      await tester.pumpAndSettle();
      expect(find.text('机场 B'), findsOneWidget);
      expect(find.text('机场 A'), findsNothing);
      expect(find.text('管理订阅'), findsWidgets);
    });

    testWidgets('延迟芯片：点“未测速”只测这一行、不选中节点', (tester) async {
      final stub = _StubNodesNotifier(_node('测试节点'));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [nodesProvider.overrideWith(() => stub)],
          child: const MaterialApp(home: Scaffold(body: NodesPage())),
        ),
      );
      await tester.pumpAndSettle();
      // 分组默认折叠：先点组头展开，行才渲染（无订阅信息的节点归“未分组”）。
      await tester.tap(find.text('未分组（1）'));
      await tester.pumpAndSettle();
      expect(find.text('未测速'), findsOneWidget);
      await tester.tap(find.text('未测速'));
      await tester.pumpAndSettle();
      expect(stub.singleTestCalls, ['single']);
      expect(stub.selectCalls, isEmpty);
    });

    testWidgets('延迟芯片：单测进行中显示转圈', (tester) async {
      final node = _node('测试节点');
      final stub = _StubNodesNotifier(
        node,
        stateOverride: NodesState(
          nodes: [node],
          status: NodesStatus.loaded,
          testingSingleNodeKey: node.dedupKey,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [nodesProvider.overrideWith(() => stub)],
          child: const MaterialApp(home: Scaffold(body: NodesPage())),
        ),
      );
      // 转圈是无限动画，pumpAndSettle 永远等不到沉降，用手动 pump。
      // 分组默认折叠：先点组头展开，行才渲染（无订阅信息的节点归“未分组”）。
      await tester.tap(find.text('未分组（1）'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}

class _StubNodesNotifier extends NodesNotifier {
  _StubNodesNotifier(this._node, {this.stateOverride});

  final Node _node;
  final NodesState? stateOverride;

  /// 记录 testSingleSpeed 被调了几次（不真发请求）。
  final singleTestCalls = <String>[];

  /// 记录 selectNode 被调了几次（点芯片不该选中）。
  final selectCalls = <String>[];

  @override
  NodesState build() =>
      stateOverride ??
      NodesState(nodes: [_node], status: NodesStatus.loaded);

  @override
  Future<void> refresh() async {}

  @override
  Future<bool> testSingleSpeed(Node node) async {
    singleTestCalls.add('single');
    return true;
  }

  @override
  Future<bool> selectNode(
    Node node, {
    String? reason,
    bool auto = false,
  }) async {
    selectCalls.add('select');
    return true;
  }
}
