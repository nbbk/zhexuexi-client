// 切片 3：首页（大开关接真实核心、流量三格 userinfo 口径、模式切换）
// 的 Widget 回归测试。插件、校验器、配置路径、Clash API 全部可注入
// fake / 本机闭口，不碰平台通道、不碰 MMKV、不碰真核心。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sing_box/flutter_sing_box.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/clash_api_client.dart';
import 'package:zhexuexi_client/core/config_validator.dart';
import 'package:zhexuexi_client/core/core_provider.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/singbox_core.dart';
import 'package:zhexuexi_client/core/userinfo.dart';
import 'package:zhexuexi_client/features/home/home_page.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';

/// 插件 fake：只记调用、不碰平台通道，状态由测试手动推。
class _FakePlugin extends FlutterSingBox {
  final _stateController = StreamController<ProxyState>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int reloadCalls = 0;

  @override
  Stream<ProxyState> get proxyStateStream => _stateController.stream;

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

  Future<void> close() => _stateController.close();
}

/// 校验器 fake：默认通过。
class _FakeValidator implements ConfigValidator {
  @override
  Future<List<String>> validate(Map<String, dynamic> config) async => [];
}

/// 节点列表桩：只返回给定的节点与 userinfo，不拉订阅。
class _StubNodesNotifier extends NodesNotifier {
  _StubNodesNotifier({required this.nodes, this.userinfo});

  final List<Node> nodes;
  final SubscriptionUserinfo? userinfo;

  @override
  NodesState build() => NodesState(
    nodes: nodes,
    userinfo: userinfo,
    status: NodesStatus.loaded,
  );
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

void main() {
  late Directory tmpDir;
  late String configPath;
  late _FakePlugin plugin;
  late CoreService service;
  late String closedApiBaseUrl;
  var goToMeCalls = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    goToMeCalls = 0;
    tmpDir = await Directory.systemTemp.createTemp('home-page-test-');
    configPath = '${tmpDir.path}/using_config.json';
    plugin = _FakePlugin();
    service = CoreService(
      plugin: plugin,
      validator: _FakeValidator(),
      usingConfigPath: () async => configPath,
      ensureSelectedProfile: (_) async {},
    );
    await service.init();
    // 拿一个当前没人监听的端口当 Clash API 地址：核心没启动时
    // 速率流以错误结束，首页速率回“—”，不崩。
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    closedApiBaseUrl = 'http://127.0.0.1:${probe.port}';
    await probe.close();
  });

  tearDown(() async {
    service.dispose();
    await plugin.close();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    List<Node> nodes = const [],
    SubscriptionUserinfo? userinfo,
  }) async {
    // 首页内容一屏放不下时 ListView 只构建可见子项，到期格与模式段
    // 会在 800x600 默认视口下不可见；测试用高视口一次全渲染。
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreServiceProvider.overrideWithValue(service),
          nodesProvider.overrideWith(
            () => _StubNodesNotifier(nodes: nodes, userinfo: userinfo),
          ),
          clashApiClientProvider.overrideWithValue(
            ClashApiClient(baseUrl: closedApiBaseUrl),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: HomePage(
              onGoToMe: () {
                goToMeCalls++;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 点大开关（当前是未连接图标）。
  ///
  /// 注意：开关处理里有真异步文件 IO（applyNodes 写配置），在
  /// testWidgets 的 fake 时间下等不到它完成；tap 与等待必须包在
  /// runAsync（真实异步区）里，再 pumpAndSettle 刷界面。
  Future<void> tapSwitch(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.power_settings_new));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('未绑定：未连接、节点未选择、三格全是“—”、写明仅中转', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('当前节点：未选择'), findsOneWidget);
    // 实时速率、已用 / 总量、剩余流量、到期日四格都是“—”。
    expect(find.text('—'), findsNWidgets(4));
    expect(find.text('仅中转'), findsOneWidget);
    expect(find.textContaining('未拉到流量数据'), findsOneWidget);
    // 默认规则模式选中。
    final segmented = tester.widget<SegmentedButton<String>>(
      find.byType(SegmentedButton<String>),
    );
    expect(segmented.selected, {'rule'});
  });

  testWidgets('有 userinfo 头：三格按字节格式化显示、到期带剩余天数', (
    tester,
  ) async {
    final expire =
        DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
        1000;
    final info = SubscriptionUserinfo.parse(
      'upload=100; download=200; total=1000; expire=$expire',
    );
    await pumpHome(
      tester,
      nodes: [_node('甲-直连')],
      userinfo: info,
    );
    expect(find.text('当前节点：甲-直连'), findsOneWidget);
    expect(find.text('300 B / 1000 B'), findsOneWidget);
    expect(find.text('700 B'), findsOneWidget);
    // 到期格写“剩 N 天”（带空格，区别于“剩余流量”标签）。
    expect(find.textContaining('剩 '), findsOneWidget);
    expect(find.textContaining('流量口径：仅中转'), findsOneWidget);
  });

  testWidgets('头里只有 expire（管理面板模式）：用量格是“—”，到期正常显示', (
    tester,
  ) async {
    final expire =
        DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
        1000;
    final info = SubscriptionUserinfo.parse('expire=$expire');
    await pumpHome(
      tester,
      nodes: [_node('甲-直连')],
      userinfo: info,
    );
    // 已用 / 总量与实时速率两格是“—”，剩余格是不限量（total 没给），
    // 到期格正常显示日期＋剩余天数。
    expect(find.text('—'), findsNWidgets(2));
    expect(find.text('不限量'), findsOneWidget);
    expect(find.textContaining('剩 '), findsOneWidget);
  });

  testWidgets('已过期：到期格写“已到期”', (tester) async {
    final info = SubscriptionUserinfo.parse(
      'upload=100; download=200; total=1000; expire=1000000000',
    );
    await pumpHome(
      tester,
      nodes: [_node('甲-直连')],
      userinfo: info,
    );
    expect(find.text('已到期'), findsOneWidget);
  });

  testWidgets('点开关（有节点）：先写配置再启动，状态变已连接', (tester) async {
    await pumpHome(tester, nodes: [_node('甲-直连'), _node('乙-中转')]);
    await tapSwitch(tester);
    expect(plugin.startCalls, 1);
    expect(find.text('已连接'), findsOneWidget);
    // 真文件 IO 也必须在 runAsync 里 await：testWidgets 的 fake 时间
    // 下直接 await File.exists() 永远等不到完成（实测挂 30 秒超时）。
    final configExists = await tester.runAsync(
      () => File(configPath).exists(),
    );
    expect(configExists, isTrue);
    // 再点一次停核心：停也要在 runAsync 里点，不然插件流的第二跳
    // 广播微任务在 fake 时间里赶不上 pumpAndSettle，界面还停在“已连接”。
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.power));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(plugin.stopCalls, 1);
    expect(find.text('未连接'), findsOneWidget);
  });

  testWidgets('点开关（无节点）：不启动，提示先绑定订阅并跳到我的页', (
    tester,
  ) async {
    await pumpHome(tester);
    await tapSwitch(tester);
    expect(plugin.startCalls, 0);
    expect(find.text('请先绑定订阅，再开启代理'), findsOneWidget);
    expect(goToMeCalls, 1);
    expect(find.text('未连接'), findsOneWidget);
  });

  testWidgets('模式切换（已启动）：重载一次、磁盘配置跟着变', (tester) async {
    await pumpHome(tester, nodes: [_node('甲-直连')]);
    await tapSwitch(tester);
    expect(find.text('已连接'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('全局模式'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(plugin.reloadCalls, 1);
    // 读盘断言同样走 runAsync（见上）。
    var decoded =
        jsonDecode((await tester.runAsync<String>(
              () => File(configPath).readAsString(),
            ))!)
            as Map<String, dynamic>;
    expect((decoded['route'] as Map)['final'], 'Proxy');

    await tester.runAsync(() async {
      await tester.tap(find.text('直连模式'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(plugin.reloadCalls, 2);
    decoded =
        jsonDecode((await tester.runAsync<String>(
              () => File(configPath).readAsString(),
            ))!)
            as Map<String, dynamic>;
    expect((decoded['route'] as Map)['final'], 'direct');
    expect(((decoded['route'] as Map)['rules'] as List), isEmpty);
  });
}
