// 节点本地改动（详情页编辑）：覆盖存储、刷新后不丢、
// updateNodeOverride 校验、详情页编辑态。
//
// 不碰真面板与真密钥库：订阅服务用桩，安全存储用内存 fake，
// 地址用 SharedPreferences mock。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/features/nodes/node_detail_page.dart';
import 'package:zhexuexi_client/services/node_override_store.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/single_node_store.dart';
import 'package:zhexuexi_client/services/subscription_parser.dart';
import 'package:zhexuexi_client/services/subscription_service.dart';
import 'package:zhexuexi_client/services/subscription_store.dart';

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

const _primaryUrl =
    'https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Node _node(
  String name, {
  String address = '203.0.113.1',
  int port = 443,
  NodeProtocol protocol = NodeProtocol.vless,
  String? subscriptionId,
}) => Node(
  name: name,
  protocol: protocol,
  address: address,
  port: port,
  source: NodeSource.direct,
  uuidOrPassword: _uuid,
  tls: true,
  sni: 'www.microsoft.com',
  flow: 'xtls-rprx-vision',
  subscriptionId: subscriptionId,
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

  group('NodeOverrideStore：写/读/删', () {
    test('写一条覆盖再读出来，字段齐全', () async {
      final store = NodeOverrideStore(storage: _FakeSecureStorage());
      final node = _node('订阅节点', subscriptionId: 'primary');
      await store.saveOverride(
        subscriptionId: node.subscriptionId,
        dedupKey: node.dedupKey,
        fields: {...NodeOverrideStore.fieldsOf(node), 'name': '改名后'},
      );
      final read = await store.readOverride(
        subscriptionId: 'primary',
        dedupKey: node.dedupKey,
      );
      expect(read, isNotNull);
      expect(read!['name'], '改名后');
      expect(read['address'], '203.0.113.1');
      expect(read['port'], 443);
      expect(read['protocol'], 'vless');
    });

    test('覆盖键含订阅 id：同内容节点在两个订阅里各改各的', () {
      final node = _node('订阅节点');
      final keyA = NodeOverrideStore.overrideKey(
        subscriptionId: 'primary',
        dedupKey: node.dedupKey,
      );
      final keyB = NodeOverrideStore.overrideKey(
        subscriptionId: 'custom_1',
        dedupKey: node.dedupKey,
      );
      expect(keyA, isNot(keyB));
      expect(
        NodeOverrideStore.overrideKey(
          subscriptionId: 'primary',
          dedupKey: node.dedupKey,
        ),
        keyA,
      );
    });

    test('删覆盖：删完读不到，删不存在的也不报错', () async {
      final store = NodeOverrideStore(storage: _FakeSecureStorage());
      final node = _node('订阅节点', subscriptionId: 'primary');
      await store.saveOverride(
        subscriptionId: 'primary',
        dedupKey: node.dedupKey,
        fields: NodeOverrideStore.fieldsOf(node),
      );
      await store.clearOverride(
        subscriptionId: 'primary',
        dedupKey: node.dedupKey,
      );
      expect(
        await store.readOverride(
          subscriptionId: 'primary',
          dedupKey: node.dedupKey,
        ),
        isNull,
      );
      await store.clearOverride(
        subscriptionId: 'primary',
        dedupKey: node.dedupKey,
      );
    });

    test('applyTo：只换可编辑字段，来源/订阅/分组/明文沿用原节点', () {
      final node = _node(
        '订阅节点',
        subscriptionId: 'primary',
      )..latencyMs = 86;
      final applied = NodeOverrideStore.applyTo(node, {
        ...NodeOverrideStore.fieldsOf(node),
        'name': '改名后',
        'address': '203.0.113.99',
      });
      expect(applied.name, '改名后');
      expect(applied.address, '203.0.113.99');
      expect(applied.subscriptionId, 'primary');
      expect(applied.source, NodeSource.direct);
      // 原始键记下来，供再次编辑/删除时找回这条覆盖。
      expect(applied.originDedupKey, node.dedupKey);
      // 刚测的延迟不被盖覆盖清掉。
      expect(applied.latencyMs, 86);
      // 原节点不动。
      expect(node.name, '订阅节点');
    });

    test('applyTo：字段表里缺的项沿用原节点（协议切走又切回不丢参数）', () {
      final node = _node('订阅节点');
      final applied = NodeOverrideStore.applyTo(node, {'name': '新名'});
      expect(applied.name, '新名');
      expect(applied.address, '203.0.113.1');
      expect(applied.flow, 'xtls-rprx-vision');
      expect(applied.sni, 'www.microsoft.com');
    });

    test('applyTo：已有原始键时保留，不被新 dedupKey 顶掉', () {
      final node = _node('订阅节点');
      final once = NodeOverrideStore.applyTo(node, {
        ...NodeOverrideStore.fieldsOf(node),
        'address': '203.0.113.99',
      });
      final twice = NodeOverrideStore.applyTo(once, {
        ...NodeOverrideStore.fieldsOf(once),
        'address': '203.0.113.100',
      });
      expect(twice.originDedupKey, node.dedupKey);
    });

    test('密钥库调用永不返回：readAll 超时后返回空表，不卡死刷新', () async {
      // 没装插件的 widget 测试里，未处理的方法通道调用会一直挂起
      // （纯 Dart 测试里同样调用是立刻抛错）；超时保护保证
      // 一次刷新最多等 5 秒，不会把界面卡死。
      final store = NodeOverrideStore(storage: _HangingSecureStorage());
      final result = await store.readAll();
      expect(result, isEmpty);
    });
  });

  group('NodeOverrideStore.validateFields', () {
    Map<String, dynamic> fields({
      String name = '节点',
      String address = '203.0.113.1',
      dynamic port = 443,
      String protocol = 'vless',
      String? secret = _uuid,
    }) => {
      'name': name,
      'address': address,
      'port': port,
      'protocol': protocol,
      'uuidOrPassword': secret,
    };

    test('合法字段返回 null', () {
      expect(NodeOverrideStore.validateFields(fields()), isNull);
    });

    test('名称/地址空着拒绝', () {
      expect(
        NodeOverrideStore.validateFields(fields(name: '  ')),
        '名称不能为空',
      );
      expect(
        NodeOverrideStore.validateFields(fields(address: '')),
        '地址不能为空',
      );
    });

    test('端口非法拒绝：0、65536、非数字', () {
      for (final bad in [0, 65536, -1, 'abc', '']) {
        expect(
          NodeOverrideStore.validateFields(fields(port: bad)),
          '端口须是 1–65535 的整数',
        );
      }
      expect(
        NodeOverrideStore.validateFields(fields(port: '8443')),
        isNull,
      );
    });

    test('VLESS/VMess/Trojan 没 UUID 拒绝', () {
      for (final protocol in ['vless', 'vmess', 'trojan']) {
        expect(
          NodeOverrideStore.validateFields(
            fields(protocol: protocol, secret: ''),
          ),
          'VLESS/VMess/Trojan 需要填写 UUID',
        );
      }
    });

    test('HY2/TUIC 没密码拒绝，SS 没密码不拦', () {
      for (final protocol in ['hysteria2', 'tuic']) {
        expect(
          NodeOverrideStore.validateFields(
            fields(protocol: protocol, secret: ''),
          ),
          'Hysteria2/TUIC 需要填写密码',
        );
      }
      expect(
        NodeOverrideStore.validateFields(
          fields(protocol: 'shadowsocks', secret: ''),
        ),
        isNull,
      );
    });
  });

  group('NodesNotifier：刷新后改动不丢', () {
    late _FakeSecureStorage storage;
    late _StubSubscriptionService service;
    late NodeOverrideStore overrideStore;
    late ProviderContainer container;

    Future<void> buildContainer({String? primaryUrl}) async {
      storage = _FakeSecureStorage();
      service = _StubSubscriptionService(storage: storage)
        ..primaryUrl = primaryUrl;
      overrideStore = NodeOverrideStore(storage: storage);
      container = ProviderContainer(
        overrides: [
          subscriptionServiceProvider.overrideWithValue(service),
          subscriptionStoreProvider.overrideWithValue(
            SubscriptionStore(storage: storage),
          ),
          singleNodeStoreProvider.overrideWithValue(
            SingleNodeStore(storage: storage),
          ),
          nodeOverrideStoreProvider.overrideWithValue(overrideStore),
        ],
      );
      addTearDown(container.dispose);
    }

    test('订阅节点改名改地址：刷新后改动还在，再刷新一次也还在', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      service.results[_primaryUrl] = _result([_node('订阅节点')]);
      final notifier = container.read(nodesProvider.notifier);
      await notifier.refresh();
      final original = container.read(nodesProvider).nodes.first;
      final error = await notifier.updateNodeOverride(original, {
        'name': '改名后',
        'address': '203.0.113.99',
        'port': 8443,
      });
      expect(error, isNull);
      var state = container.read(nodesProvider);
      expect(state.nodes.first.name, '改名后');
      expect(state.nodes.first.address, '203.0.113.99');
      expect(state.nodes.first.port, 8443);
      expect(state.nodes.first.originDedupKey, original.dedupKey);
      // 订阅来源没变，改动只换可编辑字段。
      expect(state.nodes.first.subscriptionId, 'primary');
      // 再刷新一次（订阅重拉、节点重建），改动还在。
      await notifier.refresh();
      state = container.read(nodesProvider);
      expect(state.nodes.first.name, '改名后');
      expect(state.nodes.first.address, '203.0.113.99');
      expect(state.nodes.first.originDedupKey, original.dedupKey);
    });

    test('单节点改地址：刷新后改动还在', () async {
      await buildContainer();
      final store = container.read(singleNodeStoreProvider);
      await store.addSingleNode(_vlessLink);
      final notifier = container.read(nodesProvider.notifier);
      await notifier.refresh();
      final original = container.read(nodesProvider).nodes.first;
      expect(
        await notifier.updateNodeOverride(original, {
          'address': '203.0.113.99',
        }),
        isNull,
      );
      await notifier.refresh();
      final state = container.read(nodesProvider);
      expect(state.nodes.first.address, '203.0.113.99');
      expect(state.nodes.first.originDedupKey, original.dedupKey);
    });

    test('updateNodeOverride 校验：空地址、非法端口、缺 UUID 都拒绝且不写盘', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      service.results[_primaryUrl] = _result([_node('订阅节点')]);
      final notifier = container.read(nodesProvider.notifier);
      await notifier.refresh();
      final node = container.read(nodesProvider).nodes.first;
      expect(
        await notifier.updateNodeOverride(node, {'address': ''}),
        '地址不能为空',
      );
      expect(
        await notifier.updateNodeOverride(node, {'port': 70000}),
        '端口须是 1–65535 的整数',
      );
      expect(
        await notifier.updateNodeOverride(node, {'uuidOrPassword': ''}),
        'VLESS/VMess/Trojan 需要填写 UUID',
      );
      expect(await overrideStore.readAll(), isEmpty);
      expect(container.read(nodesProvider).nodes.first.address, '203.0.113.1');
    });

    test('clearNodeOverride：恢复默认，刷新后回到订阅原始值', () async {
      await buildContainer(primaryUrl: _primaryUrl);
      service.results[_primaryUrl] = _result([_node('订阅节点')]);
      final notifier = container.read(nodesProvider.notifier);
      await notifier.refresh();
      final original = container.read(nodesProvider).nodes.first;
      expect(
        await notifier.updateNodeOverride(original, {'name': '改名后'}),
        isNull,
      );
      expect(container.read(nodesProvider).nodes.first.name, '改名后');
      await notifier.clearNodeOverride(
        container.read(nodesProvider).nodes.first,
      );
      final state = container.read(nodesProvider);
      expect(state.nodes.first.name, '订阅节点');
      expect(state.nodes.first.originDedupKey, isNull);
      expect(await overrideStore.readAll(), isEmpty);
    });

    test('删改过的单节点：按原始键删，原文整条删掉', () async {
      await buildContainer();
      final store = container.read(singleNodeStoreProvider);
      await store.addSingleNode(_vlessLink);
      final notifier = container.read(nodesProvider.notifier);
      await notifier.refresh();
      final original = container.read(nodesProvider).nodes.first;
      expect(
        await notifier.updateNodeOverride(original, {
          'address': '203.0.113.99',
        }),
        isNull,
      );
      final edited = container.read(nodesProvider).nodes.first;
      expect(edited.address, '203.0.113.99');
      // 新 dedupKey 已变，只有原始键还指着原文那条。
      expect(edited.dedupKey, isNot(original.dedupKey));
      expect(await notifier.removeSingleNode(edited), isTrue);
      // 存储里的原文整条删掉了；refresh 在订阅与单节点都空时
      // 只把状态切回 initial、不清空旧节点列表（既有行为），
      // 所以这里只断言存储空了。
      expect(await store.listNodes(), isEmpty);
    });
  });

  group('NodeDetailPage：编辑态', () {
    late _StubDetailNotifier stub;

    Future<void> pumpDetail(WidgetTester tester, Node node) async {
      // 编辑表单很长，视口加高到 1600，保存按钮不用滚就能点到。
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      stub = _StubDetailNotifier(
        NodesState(nodes: [node], status: NodesStatus.loaded),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [nodesProvider.overrideWith(() => stub)],
          child: MaterialApp(home: NodeDetailPage(node: node)),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> enterField(
      WidgetTester tester,
      String label,
      String text,
    ) async {
      final field = find.ancestor(
        of: find.text(label),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, text);
    }

    testWidgets('编辑：改名改地址，保存调 updateNodeOverride 并回显“已保存”', (
      tester,
    ) async {
      await pumpDetail(tester, _node('智利-直连'));
      expect(find.text('203.0.113.1:443'), findsOneWidget);
      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('编辑节点'), findsOneWidget);
      await enterField(tester, '名称', '改名后');
      await enterField(tester, '地址', '203.0.113.99');
      // 表单很长，保存按钮在首屏下面，先滚到可见再点。
      await tester.ensureVisible(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(stub.updateCalls.length, 1);
      expect(stub.updateCalls.first['name'], '改名后');
      expect(stub.updateCalls.first['address'], '203.0.113.99');
      expect(find.text('已保存'), findsOneWidget);
      // 详情页标题立刻回显新名字，不等下次刷新。
      expect(find.text('改名后'), findsOneWidget);
    });

    testWidgets('校验：地址清空、端口 70000、VLESS 缺 UUID，保存被拒', (
      tester,
    ) async {
      await pumpDetail(tester, _node('智利-直连'));
      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();

      await enterField(tester, '地址', '');
      await tester.ensureVisible(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(find.text('地址不能为空'), findsOneWidget);
      expect(stub.updateCalls, isEmpty);

      await enterField(tester, '地址', '203.0.113.1');
      await enterField(tester, '端口', '70000');
      await tester.ensureVisible(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(find.text('端口须是 1–65535 的整数'), findsOneWidget);
      expect(stub.updateCalls, isEmpty);

      await enterField(tester, '端口', '443');
      await enterField(tester, 'UUID', '');
      await tester.ensureVisible(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(find.text('VLESS/VMess/Trojan 需要填写 UUID'), findsOneWidget);
      expect(stub.updateCalls, isEmpty);
    });

    testWidgets('已修改节点显示“已修改”，点“恢复默认”调 clearNodeOverride', (
      tester,
    ) async {
      final node = Node(
        name: '智利-直连',
        protocol: NodeProtocol.vless,
        address: '203.0.113.99',
        port: 443,
        source: NodeSource.direct,
        uuidOrPassword: _uuid,
        tls: true,
        subscriptionId: 'primary',
        subscriptionName: '自家面板',
        originDedupKey: 'primary|vless|203.0.113.1|443|$_uuid',
      );
      await pumpDetail(tester, node);
      expect(find.text('已修改（非订阅原始值）'), findsOneWidget);
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();
      expect(stub.clearCalls.length, 1);
      expect(find.text('已恢复默认'), findsOneWidget);
    });

    testWidgets('没改动的节点不显示“已修改”', (tester) async {
      await pumpDetail(tester, _node('智利-直连'));
      expect(find.text('已修改（非订阅原始值）'), findsNothing);
      expect(find.text('恢复默认'), findsNothing);
    });
  });
}

/// 永远不返回的密钥库（模拟没装插件的 widget 测试里
/// 未处理的方法通道调用一直挂起的情况）。
class _HangingSecureStorage extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
  }) {
    // 永远不返回的 Future（模拟挂起的方法通道调用）。
    final completer = Completer<String?>();
    return completer.future;
  }
}

class _StubDetailNotifier extends NodesNotifier {
  _StubDetailNotifier(this._state);

  final NodesState _state;
  final updateCalls = <Map<String, dynamic>>[];
  final clearCalls = <Node>[];
  final calls = <String>[];

  @override
  NodesState build() => _state;

  @override
  Future<String?> updateNodeOverride(
    Node node,
    Map<String, dynamic> editedFields,
  ) async {
    updateCalls.add(editedFields);
    return null;
  }

  @override
  Future<void> clearNodeOverride(Node node) async {
    clearCalls.add(node);
  }

  @override
  Future<bool> selectNode(
    Node node, {
    String? reason,
    bool auto = false,
  }) async {
    calls.add('select:${node.name}');
    return true;
  }

  @override
  Future<bool> testSingleSpeed(Node node) async {
    calls.add('speed');
    return true;
  }
}
