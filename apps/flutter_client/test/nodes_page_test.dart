// 切片 1：节点页 widget 测试（分组、搜索、解析失败提示、绑定入口）。
//
// 节点行新布局（2026-11-26）：卡片里只有协议圆圈＋名称单行＋延迟芯片
// ＋铅笔详情按钮，不再显示地址行、“使用中”角标、“明文”角标；
// 选中态只看边框＋背景。
//
// 不碰真面板：nodesProvider 用桩 notifier 覆盖，状态直接给定。
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhexuexi_client/core/app_theme.dart';
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
  Future<void> bindAndRefresh(String link) async {
    calls.add('bind:$link');
  }

  @override
  Future<bool> testAllSpeeds() async {
    calls.add('test');
    return true;
  }

  /// testGroupSpeeds 被调了几次，以及最后一次测的组 key 与节点
  /// （0.1.15 组头测速测试用）。
  int testGroupCalls = 0;
  String? lastGroupKey;
  List<Node> lastGroupNodes = [];

  /// testGroupSpeeds 测到后给该组节点写的延迟。
  int groupLatencyMs = 77;

  /// testGroupSpeeds 的门：设了就等它完成才回（测“测速中…”用），
  /// 不设就立即完成。
  Completer<bool>? testGroupGate;

  @override
  Future<bool> testGroupSpeeds(String groupKey, List<Node> groupNodes) async {
    testGroupCalls++;
    lastGroupKey = groupKey;
    lastGroupNodes = groupNodes;
    state = state.copyWith(testingSpeed: true, testingGroupKey: groupKey);
    if (testGroupGate != null) {
      final ok = await testGroupGate!.future;
      state = state.copyWith(testingSpeed: false, testingGroupKey: null);
      if (!ok) return false;
    }
    final nodes = state.nodes;
    for (final node in groupNodes) {
      node.latencyMs = groupLatencyMs;
      node.latencyFailed = false;
      node.latencyFailureReason = null;
    }
    state = state.copyWith(
      nodes: List.of(nodes),
      testingSpeed: false,
      testingGroupKey: null,
    );
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

Node _node(
  String name,
  NodeSource source, {
  bool plain = false,
  String address = '203.0.113.10',
  NodeProtocol protocol = NodeProtocol.vless,
  String? subscriptionId,
  String? subscriptionName,
}) {
  return Node(
    name: name,
    protocol: protocol,
    address: address,
    port: 443,
    source: source,
    uuidOrPassword: '11111111-2222-3333-4444-555555555555',
    tls: !plain,
    isPlainText: plain,
    subscriptionId: subscriptionId,
    subscriptionName: subscriptionName,
  );
}

/// 展开页面上指定标题的订阅分组（默认全部折叠，节点行要先展开才可见）。
Future<void> _expandGroup(WidgetTester tester, String header) async {
  await tester.tap(find.text(header));
  await tester.pumpAndSettle();
}

Future<_StubNodesNotifier> _pumpPage(
  WidgetTester tester,
  NodesState state, {
  ThemeData? theme,
}) async {
  final stub = _StubNodesNotifier(state);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [nodesProvider.overrideWith(() => stub)],
      child: MaterialApp(
        theme: theme,
        home: const Scaffold(body: NodesPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return stub;
}

/// 伪造剪贴板内容：mock 住平台通道的 Clipboard.getData，
/// 让“粘贴”按钮读到给定文本。真实 Clipboard.setData 在测试环境里
/// 不返回（会一直挂起），所以不直接用它。
void _mockClipboard(String text) {
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': text};
        }
        return null;
      });
}

void _unmockClipboard() {
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}

void main() {
  testWidgets('节点列表：按订阅分组，不同订阅的节点不混在一起', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node(
            '香港-中转',
            NodeSource.relay,
            address: '203.0.113.11',
            subscriptionId: 'sub-a',
            subscriptionName: '订阅A',
          ),
          _node(
            '智利-直连',
            NodeSource.direct,
            address: '203.0.113.12',
            subscriptionId: 'sub-b',
            subscriptionName: '订阅B',
          ),
          _node(
            '日本-直连',
            NodeSource.direct,
            plain: true,
            address: '203.0.113.13',
            subscriptionId: 'sub-a',
            subscriptionName: '订阅A',
          ),
        ],
        status: NodesStatus.loaded,
      ),
    );
    // 组头显示订阅名，不再按 A 组/B 组（直连/中转）分。
    expect(find.text('订阅A（2）'), findsOneWidget);
    expect(find.text('订阅B（1）'), findsOneWidget);
    expect(find.text('A 组（2）'), findsNothing);
    expect(find.text('B 组（1）'), findsNothing);
    expect(find.text('中转节点'), findsNothing);
    expect(find.text('直连节点'), findsNothing);
    // 默认全部折叠：组头可见，节点行还没渲染出来。
    expect(find.text('香港-中转'), findsNothing);
    expect(find.text('智利-直连'), findsNothing);
    expect(find.text('共 3 个节点'), findsOneWidget);
    // 展开订阅A：只看到 A 的两个节点，B 的节点仍藏着。
    await _expandGroup(tester, '订阅A（2）');
    expect(find.text('香港-中转'), findsOneWidget);
    expect(find.text('日本-直连'), findsOneWidget);
    expect(find.text('智利-直连'), findsNothing);
    // 再展开订阅B：三个节点都可见。
    await _expandGroup(tester, '订阅B（1）');
    expect(find.text('智利-直连'), findsOneWidget);
    expect(find.text('未测速'), findsNWidgets(3));
    // 明文只在详情页里写，行上不再标角标。
    expect(find.text('明文'), findsNothing);
  });

  testWidgets('twin 四节点：同一订阅一组 4 个，不再分 A/B 组', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node(
            '测试机-reality-443-A',
            NodeSource.direct,
            address: '203.0.113.21',
            subscriptionId: 'sub-main',
            subscriptionName: '主订阅',
          ),
          _node(
            '测试机-reality-443-B',
            NodeSource.relay,
            address: '203.0.113.22',
            subscriptionId: 'sub-main',
            subscriptionName: '主订阅',
          ),
          _node(
            '测试机-hy2-443-A',
            NodeSource.direct,
            address: '203.0.113.23',
            subscriptionId: 'sub-main',
            subscriptionName: '主订阅',
          ),
          _node(
            '测试机-hy2-443-B',
            NodeSource.relay,
            address: '203.0.113.24',
            subscriptionId: 'sub-main',
            subscriptionName: '主订阅',
          ),
        ],
        status: NodesStatus.loaded,
      ),
    );
    expect(find.text('主订阅（4）'), findsOneWidget);
    expect(find.text('A 组（2）'), findsNothing);
    expect(find.text('B 组（2）'), findsNothing);
    expect(find.text('直连节点（4）'), findsNothing);
  });

  testWidgets('分组默认折叠：点组头展开，再点收起', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node(
            '智利-直连',
            NodeSource.direct,
            address: '203.0.113.31',
            subscriptionId: 'sub-a',
            subscriptionName: '订阅A',
          ),
        ],
        status: NodesStatus.loaded,
      ),
    );
    expect(find.text('订阅A（1）'), findsOneWidget);
    expect(find.text('智利-直连'), findsNothing);
    await _expandGroup(tester, '订阅A（1）');
    expect(find.text('智利-直连'), findsOneWidget);
    // 再点一次组头收起：节点行不渲染，组头还在。
    await _expandGroup(tester, '订阅A（1）');
    expect(find.text('智利-直连'), findsNothing);
    expect(find.text('订阅A（1）'), findsOneWidget);
  });

  testWidgets('手动添加的单节点自成一组，组头显示“手动添加”', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node(
            '手动节点',
            NodeSource.direct,
            address: '203.0.113.41',
            subscriptionId: 'single_nodes',
            subscriptionName: '手动添加',
          ),
          _node(
            '智利-直连',
            NodeSource.direct,
            address: '203.0.113.42',
            subscriptionId: 'sub-a',
            subscriptionName: '订阅A',
          ),
        ],
        status: NodesStatus.loaded,
      ),
    );
    expect(find.text('手动添加（1）'), findsOneWidget);
    expect(find.text('订阅A（1）'), findsOneWidget);
    await _expandGroup(tester, '手动添加（1）');
    expect(find.text('手动节点'), findsOneWidget);
    expect(find.text('智利-直连'), findsNothing);
  });

  testWidgets('订阅名缺失时组头回落订阅 id；两者都没有时显示“未分组”', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node(
            '无名订阅节点',
            NodeSource.direct,
            address: '203.0.113.51',
            subscriptionId: 'sub-no-name',
          ),
          _node('老数据节点', NodeSource.direct, address: '203.0.113.52'),
        ],
        status: NodesStatus.loaded,
      ),
    );
    expect(find.text('sub-no-name（1）'), findsOneWidget);
    expect(find.text('未分组（1）'), findsOneWidget);
  });

  testWidgets('节点行左侧圆圈放协议简称：VLESS 显示 VL，Hysteria2 显示 HY2', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node(
            '测试机-reality-443-B',
            NodeSource.relay,
            address: 'cp.jiankong.cf',
          ),
          _node(
            '测试机-hy2-443-A',
            NodeSource.direct,
            protocol: NodeProtocol.hysteria2,
          ),
        ],
        status: NodesStatus.loaded,
      ),
    );
    // 默认折叠，先展开分组再看行。
    await _expandGroup(tester, '未分组（2）');
    expect(find.text('VL'), findsOneWidget);
    expect(find.text('HY2'), findsOneWidget);
    // 没有旗标也没有 globe 图标（国旗显示已去掉）。
    expect(find.text('🇭🇰'), findsNothing);
  });

  testWidgets('协议全名与地址行不在卡片上：简称在圆圈，全名只在详情页', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node(
            '测试机-hy2-443-A',
            NodeSource.direct,
            protocol: NodeProtocol.hysteria2,
          ),
        ],
        status: NodesStatus.loaded,
      ),
    );
    // 默认折叠，先展开分组再看行。
    await _expandGroup(tester, '未分组（1）');
    // 圆圈里是简称 HY2，卡片上不再有协议全名与地址行。
    expect(find.text('HY2'), findsOneWidget);
    expect(find.text('Hysteria2'), findsNothing);
    expect(find.text('203.0.113.10:443 · Hysteria2'), findsNothing);
    expect(find.text('203.0.113.10:443'), findsNothing);
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
    // 默认折叠，先展开分组再看行。
    await _expandGroup(tester, '未分组（1）');
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
    // 搜索后组头只剩 1 个（默认折叠，先展开再看行）。
    expect(find.text('未分组（1）'), findsOneWidget);
    await _expandGroup(tester, '未分组（1）');
    expect(find.text('香港-中转'), findsOneWidget);
    expect(find.text('智利-直连'), findsNothing);
  });

  testWidgets('未绑定：显示粘贴订阅/节点链接入口与扫码入口', (tester) async {
    await _pumpPage(tester, const NodesState(status: NodesStatus.initial));
    expect(find.text('粘贴订阅链接或单条节点链接'), findsOneWidget);
    expect(find.text('添加'), findsOneWidget);
    expect(find.text('扫码添加'), findsOneWidget);
    expect(find.text('绑定订阅后这里会列出节点'), findsOneWidget);
  });

  testWidgets('失败：显示原因与重新拉取按钮', (tester) async {
    await _pumpPage(
      tester,
      const NodesState(
        status: NodesStatus.error,
        errorMessage: '订阅链接不对或令牌不对，请检查链接或重新获取',
      ),
    );
    expect(
      find.text('订阅链接不对或令牌不对，请检查链接或重新获取'),
      findsOneWidget,
    );
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

  testWidgets('测速结果：测到的延迟数字本身是绿色，失败的只显示红色圆点', (
    tester,
  ) async {
    final fast = _node('智利-直连', NodeSource.direct)..latencyMs = 86;
    final bad = _node('坏节点-直连', NodeSource.direct)
      ..latencyFailed = true
      ..latencyFailureReason = '超时不可达';
    await _pumpPage(
      tester,
      NodesState(nodes: [fast, bad], status: NodesStatus.loaded),
    );
    // 默认折叠，先展开分组再看行。
    await _expandGroup(tester, '未分组（2）');
    // 通了：延迟数字本身用绿色（白天 #157347），不再是灰字。
    final okText = tester.widget<Text>(find.text('86ms'));
    expect(okText.style?.color, const Color(0xFF157347));
    // 不通：不再写“测速失败”四个字，只显示一个红色圆点。
    expect(find.text('测速失败'), findsNothing);
    final errorColor = Theme.of(
      tester.element(find.text('86ms')),
    ).colorScheme.error;
    final redDot = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle &&
          (w.decoration as BoxDecoration).color == errorColor,
    );
    expect(redDot, findsOneWidget);
    // 失败原因仍在 tooltip 与长按说明里。
    expect(
      find.byTooltip('测速失败：超时不可达，点一下重测'),
      findsOneWidget,
    );
    expect(find.text('未测速'), findsNothing);
  });

  testWidgets('测速结果（夜晚主题）：延迟数字用夜晚可读的浅绿', (tester) async {
    final fast = _node('智利-直连', NodeSource.direct)..latencyMs = 86;
    await _pumpPage(
      tester,
      NodesState(nodes: [fast], status: NodesStatus.loaded),
      theme: AppThemes.night.themeData,
    );
    // 默认折叠，先展开分组再看行。
    await _expandGroup(tester, '未分组（1）');
    final okText = tester.widget<Text>(find.text('86ms'));
    expect(okText.style?.color, const Color(0xFF4ADE80));
  });

  testWidgets('选中节点不挪位置：只变选中态，顺序保持原样，不再写“使用中”', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node('日本-直连', NodeSource.direct, address: '203.0.113.61'),
          _node('智利-直连', NodeSource.direct, address: '203.0.113.62'),
        ],
        status: NodesStatus.loaded,
        selectedNodeName: '智利-直连',
      ),
    );
    // 选中态只看边框＋背景，不再写“使用中”三个字。
    expect(find.text('使用中'), findsNothing);
    // 默认折叠，先展开分组再看顺序。
    await _expandGroup(tester, '未分组（2）');
    // 列表顺序保持原样：日本仍在智利前面，选中不置顶、不重排。
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .toList();
    expect(
      texts.indexOf('日本-直连') < texts.indexOf('智利-直连'),
      isTrue,
    );
  });

  testWidgets('节点行：只有名称一行，超长名单行省略，不折行', (tester) async {
    const longName = '美国01-reality-443-这是一个很长很长的节点名字';
    await _pumpPage(
      tester,
      NodesState(
        nodes: [_node(longName, NodeSource.direct)],
        status: NodesStatus.loaded,
      ),
    );
    // 默认折叠，先展开分组再看行。
    await _expandGroup(tester, '未分组（1）');
    final nameText = tester.widget<Text>(find.text(longName));
    expect(nameText.maxLines, 1);
    expect(nameText.overflow, TextOverflow.ellipsis);
    // 行里没有地址文本，也没有“使用中”。
    expect(find.textContaining('203.0.113.10'), findsNothing);
    expect(find.text('使用中'), findsNothing);
    // 每行一个铅笔详情按钮。
    expect(find.byTooltip('查看详情与编辑'), findsOneWidget);
  });

  testWidgets('选中行有边框与背景色，未选中行没有', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        nodes: [
          _node('智利-直连', NodeSource.direct),
          _node('日本-直连', NodeSource.direct),
        ],
        status: NodesStatus.loaded,
        selectedNodeName: '智利-直连',
      ),
    );
    // 默认折叠，先展开分组再看行。
    await _expandGroup(tester, '未分组（2）');
    final context = tester.element(find.text('智利-直连'));
    final primary = Theme.of(context).colorScheme.primary;
    bool hasSelectedBorder(Widget widget) {
      if (widget is AnimatedContainer) {
        final decoration = widget.decoration;
        if (decoration is BoxDecoration) {
          final border = decoration.border;
          if (border is Border) {
            return border.top.color == primary &&
                decoration.color == primary.withValues(alpha: 0.08);
          }
        }
      }
      return false;
    }

    expect(find.byWidgetPredicate(hasSelectedBorder), findsOneWidget);
  });

  testWidgets('点铅笔进详情页，不选中节点', (tester) async {
    final stub = await _pumpPage(
      tester,
      NodesState(
        nodes: [_node('智利-直连', NodeSource.direct)],
        status: NodesStatus.loaded,
      ),
    );
    // 默认折叠，先展开分组再点铅笔。
    await _expandGroup(tester, '未分组（1）');
    await tester.tap(find.byTooltip('查看详情与编辑'));
    await tester.pumpAndSettle();
    expect(find.text('设为当前节点'), findsOneWidget);
    expect(stub.calls, isNot(contains('select:智利-直连')));
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
    // 默认折叠，先展开分组再点行。
    await _expandGroup(tester, '未分组（2）');
    await tester.tap(find.text('日本-直连'));
    await tester.pumpAndSettle();
    expect(stub.calls, contains('select:日本-直连'));
  });

  group('粘贴按钮', () {
    const primaryLink =
        'https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    // 测试里伪造剪贴板：这台机器上的 flutter_tester 不响应真实剪贴板
    // 通道（Clipboard.setData 会一直挂起），所以用 mock 通道返回值；
    // 正式代码走的仍是 Clipboard.getData，不改。
    setUp(() => addTearDown(_unmockClipboard));

    testWidgets('未绑定：点“粘贴”把剪贴板内容（去首尾空白）填进输入框', (
      tester,
    ) async {
      _mockClipboard('  $primaryLink\n');
      await _pumpPage(tester, const NodesState(status: NodesStatus.initial));
      expect(find.text('粘贴'), findsOneWidget);
      await tester.tap(find.text('粘贴'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byType(TextField).at(1),
      );
      expect(field.controller?.text, primaryLink);
      expect(field.keyboardType, TextInputType.url);
    });

    testWidgets('未绑定：粘贴后点“添加”走 handleContent（绑定主订阅）', (
      tester,
    ) async {
      _mockClipboard(primaryLink);
      final stub = await _pumpPage(
        tester,
        const NodesState(status: NodesStatus.initial),
      );
      await tester.tap(find.text('粘贴'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(stub.calls, contains('bind:$primaryLink'));
      expect(find.text('已绑定订阅'), findsOneWidget);
    });

    testWidgets('失败态：粘贴框独立，点“粘贴”填入后点“添加”走失败态的框', (
      tester,
    ) async {
      _mockClipboard(primaryLink);
      final stub = await _pumpPage(
        tester,
        const NodesState(
          status: NodesStatus.error,
          errorMessage: '订阅链接不对或令牌不对，请检查链接或重新获取',
        ),
      );
      await tester.tap(find.text('粘贴'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byType(TextField).at(1),
      );
      expect(field.controller?.text, primaryLink);
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(stub.calls, contains('bind:$primaryLink'));
    });

    testWidgets('添加节点弹窗：点“粘贴”把剪贴板内容填进弹窗输入框', (
      tester,
    ) async {
      const nodeLink =
          'vless://11111111-2222-3333-4444-555555555555@203.0.113.1:443'
          '?encryption=none&security=reality'
          '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          '&sid=abcdef01&sni=www.microsoft.com&fp=chrome&type=tcp'
          '&flow=xtls-rprx-vision#测试机-reality-443-A';
      _mockClipboard(nodeLink);
      await _pumpPage(
        tester,
        NodesState(
          nodes: [_node('智利-直连', NodeSource.direct)],
          status: NodesStatus.loaded,
        ),
      );
      await tester.tap(find.text('添加节点'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('粘贴'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byType(TextField).last,
      );
      expect(field.controller?.text, nodeLink);
    });

    // 0.1.15：节点页组头“测速”按钮（照抄首页节点弹窗组头的做法）。
    group('组头测速', () {
      /// 两组：订阅 A（2 个节点）＋订阅 B（1 个节点）。
      NodesState twoGroupsState() => NodesState(
        nodes: [
          _node(
            'A1',
            NodeSource.direct,
            subscriptionId: 'sub-a',
            subscriptionName: '订阅A',
          ),
          _node(
            'A2',
            NodeSource.direct,
            subscriptionId: 'sub-a',
            subscriptionName: '订阅A',
          ),
          _node(
            'B1',
            NodeSource.direct,
            subscriptionId: 'sub-b',
            subscriptionName: '订阅B',
          ),
        ],
        status: NodesStatus.loaded,
      );

      testWidgets('组头有“测速”按钮：每组一个，点后只测该组', (tester) async {
        final stub = await _pumpPage(tester, twoGroupsState());
        expect(find.text('测速'), findsNWidgets(2));

        // 点第一组（订阅 A）的“测速”：只调该组，另一组不动。
        await tester.tap(find.text('测速').first);
        await tester.pumpAndSettle();
        expect(stub.testGroupCalls, 1);
        expect(stub.lastGroupKey, 'sub-a');
        expect(stub.lastGroupNodes.map((n) => n.name), ['A1', 'A2']);

        // A 组节点出了延迟，B 组还是“未测速”。
        await _expandGroup(tester, '订阅A（2）');
        expect(find.text('77ms'), findsNWidgets(2));
        await _expandGroup(tester, '订阅B（1）');
        expect(find.text('未测速'), findsOneWidget);
      });

      testWidgets('点组头“测速”不触发展开/收起', (tester) async {
        final stub = await _pumpPage(tester, twoGroupsState());
        await tester.tap(find.text('测速').first);
        await tester.pumpAndSettle();
        expect(stub.testGroupCalls, 1);
        // 两组都还是折叠的：节点行没渲染出来。
        expect(find.text('A1'), findsNothing);
        expect(find.text('B1'), findsNothing);
      });

      testWidgets('组测速进行中：该组按钮变“测速中…”，另一组按钮禁用', (
        tester,
      ) async {
        final stub = await _pumpPage(tester, twoGroupsState());
        stub.testGroupGate = Completer<bool>();
        await tester.tap(find.text('测速').first);
        await tester.pump();
        await tester.pump();
        expect(find.text('测速中…'), findsOneWidget);
        // 剩下那个“测速”是 B 组的（已禁用）：再点不重复测。
        expect(find.text('测速'), findsOneWidget);
        await tester.tap(find.text('测速'));
        await tester.pump();
        expect(stub.testGroupCalls, 1);

        stub.testGroupGate!.complete(true);
        await tester.pumpAndSettle();
        expect(find.text('测速'), findsNWidgets(2));
        expect(find.text('测速中…'), findsNothing);
      });

      testWidgets('一键测速进行中时组头“测速”禁用，不重复测', (tester) async {
        final state = twoGroupsState();
        final stub = await _pumpPage(
          tester,
          state.copyWith(testingSpeed: true),
        );
        await tester.tap(find.text('测速').first);
        await tester.pump();
        expect(stub.testGroupCalls, 0);
        // 点禁用的“测速”不会重复测，但手势会落到外层 InkWell 上把
        // 组展开（与首页节点弹窗组头同一做法：按钮在 InkWell 里，
        // 禁用时不吃手势）；行入场动画的延时要跑完，末尾 pumpAndSettle
        // 清掉，否则测试框架报 Timer 挂起。
        expect(find.text('A1'), findsOneWidget);
        await tester.pumpAndSettle();
      });
    });
  });
}
