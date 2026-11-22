// 切片 1：节点页 widget 测试（分组、搜索、明文角标、解析失败提示、绑定入口）。
//
// 不碰真面板：nodesProvider 用桩 notifier 覆盖，状态直接给定。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/features/nodes/nodes_page.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';

class _StubNodesNotifier extends NodesNotifier {
  _StubNodesNotifier(this._state);

  final NodesState _state;
  final calls = <String>[];

  @override
  NodesState build() => _state;

  @override
  Future<void> refresh() async {
    // 桩：保持给定状态，不真拉订阅。
  }

  @override
  Future<void> bindAndRefresh(String link) async {}

  @override
  Future<bool> testAllSpeeds() async {
    calls.add('test');
    return true;
  }

  @override
  Future<bool> autoSelect() async {
    calls.add('auto');
    return true;
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
}

Node _node(String name, NodeSource source, {bool plain = false}) {
  return Node(
    name: name,
    protocol: NodeProtocol.vless,
    address: '203.0.113.10',
    port: 443,
    source: source,
    uuidOrPassword: '11111111-2222-3333-4444-555555555555',
    tls: !plain,
    isPlainText: plain,
  );
}

Future<_StubNodesNotifier> _pumpPage(
  WidgetTester tester,
  NodesState state,
) async {
  final stub = _StubNodesNotifier(state);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [nodesProvider.overrideWith(() => stub)],
      child: const MaterialApp(home: Scaffold(body: NodesPage())),
    ),
  );
  await tester.pumpAndSettle();
  return stub;
}

void main() {
  testWidgets('节点列表：按中转/直连分组，明文节点标“明文”', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node('香港-中转', NodeSource.relay),
          _node('智利-直连', NodeSource.direct),
          _node('日本-直连', NodeSource.direct, plain: true),
        ],
        status: NodesStatus.loaded,
      ),
    );
    expect(find.text('中转节点（1）'), findsOneWidget);
    expect(find.text('直连节点（2）'), findsOneWidget);
    expect(find.text('香港-中转'), findsOneWidget);
    expect(find.text('日本-直连'), findsOneWidget);
    expect(find.text('明文'), findsOneWidget);
    expect(find.text('未测速'), findsNWidgets(3));
    expect(find.text('共 3 个节点'), findsOneWidget);
  });

  testWidgets('解析失败 N 个：显示提示横条，其余节点正常列出', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [_node('智利-直连', NodeSource.direct)],
        failedCount: 2,
        status: NodesStatus.loaded,
      ),
    );
    expect(find.textContaining('解析失败 2 个节点'), findsOneWidget);
    expect(find.text('智利-直连'), findsOneWidget);
  });

  testWidgets('搜索框按名字过滤', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node('香港-中转', NodeSource.relay),
          _node('智利-直连', NodeSource.direct),
        ],
        status: NodesStatus.loaded,
      ),
    );
    await tester.enterText(find.byType(TextField).first, '香港');
    await tester.pumpAndSettle();
    expect(find.text('香港-中转'), findsOneWidget);
    expect(find.text('智利-直连'), findsNothing);
  });

  testWidgets('未绑定：显示粘贴订阅链接入口', (tester) async {
    await _pumpPage(tester, const NodesState(status: NodesStatus.initial));
    expect(find.text('粘贴完整订阅链接'), findsOneWidget);
    expect(find.text('绑定并刷新'), findsOneWidget);
    expect(find.text('绑定订阅后这里会列出节点'), findsOneWidget);
  });

  testWidgets('失败：显示原因与重新拉取按钮', (tester) async {
    await _pumpPage(
      tester,
      const NodesState(
        status: NodesStatus.error,
        errorMessage: '订阅已失效，请重新绑定',
      ),
    );
    expect(find.text('订阅已失效，请重新绑定'), findsOneWidget);
    expect(find.text('重新拉取'), findsOneWidget);
  });

  testWidgets('一键测速与自动选择按钮可用，点了调对应方法', (tester) async {
    final stub = await _pumpPage(
      tester,
      NodesState(
        nodes: [_node('智利-直连', NodeSource.direct)],
        status: NodesStatus.loaded,
      ),
    );
    await tester.tap(find.text('一键测速'));
    await tester.pumpAndSettle();
    expect(stub.calls, contains('test'));
    await tester.tap(find.text('自动选择'));
    await tester.pumpAndSettle();
    expect(stub.calls, contains('auto'));
  });

  testWidgets('测速结果：测到的写延迟，失败的标灰写“测速失败”', (tester) async {
    final fast = _node('智利-直连', NodeSource.direct)..latencyMs = 86;
    final bad = _node('坏节点-直连', NodeSource.direct)
      ..latencyFailed = true;
    await _pumpPage(
      tester,
      NodesState(nodes: [fast, bad], status: NodesStatus.loaded),
    );
    expect(find.text('86ms'), findsOneWidget);
    expect(find.text('测速失败'), findsOneWidget);
    expect(find.text('未测速'), findsNothing);
  });

  testWidgets('当前节点标“使用中”且在组内置顶', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node('日本-直连', NodeSource.direct),
          _node('智利-直连', NodeSource.direct),
        ],
        status: NodesStatus.loaded,
        selectedNodeName: '智利-直连',
      ),
    );
    expect(find.text('使用中'), findsOneWidget);
    // 列表里智利在日本前面（置顶），虽然原顺序是日本在前。
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .toList();
    expect(
      texts.indexOf('智利-直连') < texts.indexOf('日本-直连'),
      isTrue,
    );
  });

  testWidgets('测速中：按钮显示进度且禁用', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [_node('智利-直连', NodeSource.direct)],
        status: NodesStatus.loaded,
        testingSpeed: true,
        speedTestedCount: 1,
        speedTestTotal: 3,
      ),
    );
    expect(find.text('测速中 1/3'), findsOneWidget);
    final testButton = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('测速中 1/3'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(testButton.onPressed, isNull);
  });

  testWidgets('选择原因与测速失败原因常驻显示', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [_node('智利-直连', NodeSource.direct)],
        status: NodesStatus.loaded,
        speedTestError: '核心未启动，先在首页打开开关再测速',
        selectionReason: '已选 智利-直连：延迟最低 86ms（共测 1 个，0 个失败）',
      ),
    );
    expect(find.text('核心未启动，先在首页打开开关再测速'), findsOneWidget);
    expect(find.textContaining('已选 智利-直连'), findsOneWidget);
  });

  testWidgets('点一行选中该节点', (tester) async {
    final stub = await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node('智利-直连', NodeSource.direct),
          _node('日本-直连', NodeSource.direct),
        ],
        status: NodesStatus.loaded,
      ),
    );
    await tester.tap(find.text('日本-直连'));
    await tester.pumpAndSettle();
    expect(stub.calls, contains('select:日本-直连'));
  });
}
