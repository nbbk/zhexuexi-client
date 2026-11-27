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
import 'package:zhexuexi_client/brand/brand_config.dart';
import 'package:zhexuexi_client/brand/remote_config.dart';
import 'package:zhexuexi_client/core/clash_api_client.dart';
import 'package:zhexuexi_client/core/config_validator.dart';
import 'package:zhexuexi_client/core/core_provider.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/singbox_core.dart';
import 'package:zhexuexi_client/core/userinfo.dart';
import 'package:zhexuexi_client/features/home/home_page.dart';
import 'package:zhexuexi_client/services/announcement_service.dart';
import 'package:zhexuexi_client/widgets/announcement_marquee.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/remote_config_notifier.dart';
import 'package:zhexuexi_client/services/settings_notifier.dart';
import 'package:zhexuexi_client/widgets/glass_card.dart';
import 'package:zhexuexi_client/widgets/power_button.dart';

/// 插件 fake：只记调用、不碰平台通道，状态由测试手动推。
class _FakePlugin extends FlutterSingBox {
  final _stateController = StreamController<ProxyState>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int reloadCalls = 0;

  @override
  Stream<ProxyState> get proxyStateStream => _stateController.stream;

  // 0.1.9：日志流也桩掉——真实现走 EventChannel `log_event`，
  // 测试里无原生实现，listen 会报 MissingPluginException。
  @override
  Stream<List<ClientLog>> get logStream =>
      Stream<List<ClientLog>>.empty();

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

/// 校验器 fake：默认通过；errors 非空时模拟校验失败（原因进
/// ConfigApplyResult.errors，首页要把它报出来，不只弹固定句）。
class _FakeValidator implements ConfigValidator {
  List<String> errors = const [];

  @override
  Future<List<String>> validate(Map<String, dynamic> config) async =>
      errors;
}

/// Clash API fake：启动后校验（`CoreService._verifyControlApi`）取一帧
/// 就回，不碰真网络。widget 测试里 HttpClient 一律回 400，不注入
/// 这个 fake 时校验会记探活失败，首页显示“运行中”＋拨测失败提示
///（不是“连接失败”）。
class _FakeClashApi extends ClashApiClient {
  /// 启动后校验的拨测结果：默认测通；改成失败可模拟探活失败。
  ProxyDelayResult delayResult = const ProxyDelayResult(delay: 100);

  @override
  Future<TrafficSample> trafficSample({
    Duration timeout = const Duration(seconds: 5),
  }) async => const TrafficSample(up: 0, down: 0);

  /// 启动后校验的拨测桩：默认测通；不桩它时真实现会去连
  /// 127.0.0.1:9090，widget 测试里 HttpClient 一律回 400，
  /// 校验记探活失败、首页显示“运行中”＋拨测失败提示。
  @override
  Future<ProxyDelayResult> proxyDelayDetailed(
    String proxyName, {
    Duration timeout = const Duration(seconds: 5),
  }) async => delayResult;
}

/// 设置桩：初始 tun 可指定（真实现读 SharedPreferences 是异步回落，
/// 同文件多测试共用一个缓存实例时 mock 初值改不进去）；setTun 沿用
/// 真实现（改 state＋写 prefs）。
class _StubSettingsNotifier extends SettingsNotifier {
  _StubSettingsNotifier({required this.initialTun});

  final bool initialTun;

  @override
  SettingsState build() => SettingsState(tun: initialTun);
}

/// 节点列表桩：只返回给定的节点与 userinfo，不拉订阅。
class _StubNodesNotifier extends NodesNotifier {
  _StubNodesNotifier({required this.nodes, this.userinfo, this.selected});

  final List<Node> nodes;
  final SubscriptionUserinfo? userinfo;
  final String? selected;

  @override
  NodesState build() => NodesState(
    nodes: nodes,
    userinfo: userinfo,
    status: NodesStatus.loaded,
    selectedNodeName: selected,
  );
}

/// 节点选择弹窗桩：selectNode / testSingleSpeed 可注入行为，
/// 不走真核心与真 Clash API（问题 5 的弹窗测试用）。
class _PickerStubNodesNotifier extends _StubNodesNotifier {
  _PickerStubNodesNotifier({
    required super.nodes,
    super.selected,
  });

  /// selectNode 返回什么（false 时模拟切换失败）。
  bool selectResult = true;

  /// selectNode 失败时写进 selectionReason 的原因。
  String? selectReason;

  /// testSingleSpeed 被调了几次。
  int testSingleCalls = 0;

  /// testSingleSpeed 测到后给节点写的延迟。
  int singleLatencyMs = 88;

  /// testAllSpeeds 被调了几次。
  int testAllCalls = 0;

  /// testAllSpeeds 测到后给全部节点写的延迟。
  int allLatencyMs = 55;

  /// testAllSpeeds 的门：设了就等它完成才回（测“测速中禁用”用），
  /// 不设就立即完成。
  Completer<bool>? testAllGate;

  @override
  Future<bool> selectNode(
    Node node, {
    String? reason,
    bool auto = false,
  }) async {
    if (!selectResult) {
      state = state.copyWith(
        selectionReason: selectReason ?? '切换失败，核心没有响应',
      );
      return false;
    }
    state = state.copyWith(
      selectedNodeName: node.name,
      selectionReason: '已选择 ${node.name}',
    );
    return true;
  }

  @override
  Future<bool> testSingleSpeed(Node node) async {
    testSingleCalls++;
    final nodes = state.nodes;
    final target = nodes.where((n) => n.name == node.name).firstOrNull;
    if (target != null) {
      target.latencyMs = singleLatencyMs;
      target.latencyFailed = false;
      target.latencyFailureReason = null;
    }
    state = state.copyWith(nodes: List.of(nodes));
    return true;
  }

  @override
  Future<bool> testAllSpeeds() async {
    testAllCalls++;
    if (testAllGate != null) {
      final ok = await testAllGate!.future;
      if (!ok) return false;
    }
    final nodes = state.nodes;
    for (final node in nodes) {
      node.latencyMs = allLatencyMs;
      node.latencyFailed = false;
      node.latencyFailureReason = null;
    }
    state = state.copyWith(nodes: List.of(nodes));
    return true;
  }
}

Node _node(
  String name, {
  NodeSource source = NodeSource.direct,
  String? subscriptionId,
  String? subscriptionName,
}) => Node(
  name: name,
  protocol: NodeProtocol.vless,
  address: '203.0.113.1',
  port: 443,
  source: source,
  uuidOrPassword: '11111111-2222-3333-4444-555555555555',
  tls: true,
  sni: 'example.com',
  subscriptionId: subscriptionId,
  subscriptionName: subscriptionName,
);

/// 远程配置桩：只返回给定的配置与来源，不拉网络、不读缓存。
class _StubRemoteConfigNotifier extends RemoteConfigNotifier {
  _StubRemoteConfigNotifier(this._config, {this.source = RemoteConfigSource.fresh});

  final RemoteConfig _config;
  final RemoteConfigSource source;

  @override
  RemoteConfigState build() => RemoteConfigState(
        config: _config,
        source: source,
      );
}

/// bundled 配置（包内默认值、没拉到远程时）：不强制更新。
RemoteConfig _bundledConfig() => RemoteConfig(
      configVersion: 2,
      minAppVersion: '0.1.0',
      forceUpdate: false,
      brand: BrandConfig.defaults(),
      panelDomain: 'panel.example.com',
      panelApiBase: '',
      minPanelVersion: '1.3.29',
      subscriptionUrl: '',
      subscriptionBackupUrls: const [],
      subscriptionFormat: 'singbox',
      features: const RemoteConfigFeatures(),
    );

/// 强制更新的配置（当前版本 0.1.1 < 最低 0.2.0，带下载地址）。
RemoteConfig _forceUpdateConfig() => RemoteConfig(
      configVersion: 2,
      minAppVersion: '0.2.0',
      forceUpdate: true,
      forceUpdateMessage: '当前版本无法解析新订阅格式，请升级到最新版。',
      downloadUrl: 'https://example.com/download',
      brand: BrandConfig.defaults(),
      panelDomain: 'panel.example.com',
      panelApiBase: '',
      minPanelVersion: '1.3.29',
      subscriptionUrl: '',
      subscriptionBackupUrls: const [],
      subscriptionFormat: 'singbox',
      features: const RemoteConfigFeatures(),
    );

/// 限流测试用的 userinfo：已用 usedMB / 总量 totalMB（MB）。
SubscriptionUserinfo _limitedInfo({required int usedMB, int totalMB = 1024}) {
  final expire = DateTime.now().add(const Duration(days: 45));
  return SubscriptionUserinfo(
    upload: usedMB * 1024 * 1024,
    download: 0,
    total: totalMB * 1024 * 1024,
    expire: expire.millisecondsSinceEpoch ~/ 1000,
  );
}

void main() {
  late Directory tmpDir;
  late String configPath;
  late _FakePlugin plugin;
  late _FakeValidator validator;
  late _FakeClashApi fakeApi;
  late CoreService service;
  late String closedApiBaseUrl;
  var goToMeCalls = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    goToMeCalls = 0;
    tmpDir = await Directory.systemTemp.createTemp('home-page-test-');
    configPath = '${tmpDir.path}/using_config.json';
    plugin = _FakePlugin();
    validator = _FakeValidator();
    fakeApi = _FakeClashApi();
    service = CoreService(
      plugin: plugin,
      validator: validator,
      usingConfigPath: () async => configPath,
      ensureSelectedProfile: (_) async {},
      clashApiClient: fakeApi,
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
    String? selected,
    RemoteConfig? remoteConfig,
    RemoteConfigSource remoteSource = RemoteConfigSource.fresh,
    Size viewSize = const Size(800, 1600),
    NodesNotifier? nodesOverride,
    SettingsNotifier? settingsOverride,
    List<Announcement>? announcements,
  }) async {
    // 公告默认一条（0.1.2：有公告才显示卡片；默认不断言它，
    // 卡片尺寸测试用它当 72 高锚点）。
    announcements ??= [
      Announcement(
        id: 'test-1',
        title: '维护通知',
        body: '今晚维护',
        createdAt: DateTime(2026, 11, 26, 9),
      ),
    ];
    // 首页内容一屏放不下时 ListView 只构建可见子项，到期格与模式段
    // 会在 800x600 默认视口下不可见；测试用高视口一次全渲染。
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreServiceProvider.overrideWithValue(service),
          nodesProvider.overrideWith(
            () =>
                nodesOverride ??
                _StubNodesNotifier(
                  nodes: nodes,
                  userinfo: userinfo,
                  selected: selected,
                ),
          ),
          clashApiClientProvider.overrideWithValue(
            ClashApiClient(baseUrl: closedApiBaseUrl),
          ),
          if (remoteConfig != null)
            remoteConfigProvider.overrideWith(
              () => _StubRemoteConfigNotifier(
                remoteConfig,
                source: remoteSource,
              ),
            ),
          if (settingsOverride != null)
            settingsProvider.overrideWith(() => settingsOverride),
          announcementsProvider.overrideWith((ref) async => announcements!),
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

  /// 手动刷几帧（见 tapSwitch：开态下不用 pumpAndSettle）。
  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 点大开关（按按钮本身点，不按图标：中心图标是可替换组件，
  /// 默认是金色信号弧占位，不写死电源符号）。
  ///
  /// 注意：开关处理里有真异步文件 IO（applyNodes 写配置），在
  /// testWidgets 的 fake 时间下等不到它完成；tap 与等待必须包在
  /// runAsync（真实异步区）里，再手动刷几帧。
  /// 不用 pumpAndSettle：大开关“开”时呼吸动画无限循环，
  /// pumpAndSettle 永远等不到没有帧调度的时刻，会超时。
  Future<void> tapSwitch(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byType(BreathingPowerButton));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await pumpFrames(tester);
  }

  testWidgets('未绑定：静候连接、节点未选择、三格全是“—”、写明全部节点', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(find.text('静候连接'), findsOneWidget);
    expect(find.text('轻触开启'), findsOneWidget);
    expect(find.text('当前节点：未选择'), findsOneWidget);
    // 实时速率、已用 / 总量、剩余流量、到期日四格都是“—”。
    expect(find.text('—'), findsNWidgets(4));
    expect(find.text('全部节点'), findsOneWidget);
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
    expect(find.textContaining('流量口径：全部节点'), findsOneWidget);
  });

  testWidgets('节点页选过的节点：首页当前节点跟着走，显示测到的延迟', (
    tester,
  ) async {
    final selected = _node('乙-中转', source: NodeSource.relay)
      ..latencyMs = 120;
    await pumpHome(
      tester,
      nodes: [_node('甲-直连'), selected],
      selected: '乙-中转',
    );
    // 没选过时默认是第一个直连节点（甲）；选过乙之后首页认乙。
    expect(find.text('当前节点：乙-中转'), findsOneWidget);
    expect(find.text('延迟 120ms'), findsOneWidget);
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

  testWidgets('点开关（有节点）：先写配置再启动，状态变运行中', (tester) async {
    await pumpHome(tester, nodes: [_node('甲-直连'), _node('乙-中转')]);
    await tapSwitch(tester);
    expect(plugin.startCalls, 1);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.textContaining('已连接 '), findsOneWidget);
    // 真文件 IO 也必须在 runAsync 里 await：testWidgets 的 fake 时间
    // 下直接 await File.exists() 永远等不到完成（实测挂 30 秒超时）。
    final configExists = await tester.runAsync(
      () => File(configPath).exists(),
    );
    expect(configExists, isTrue);
    // 再点一次停核心：停也要在 runAsync 里点，不然插件流的第二跳
    // 广播微任务在 fake 时间里赶不上 pumpAndSettle，界面还停在“运行中”。
    await tester.runAsync(() async {
      await tester.tap(find.byType(BreathingPowerButton));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(plugin.stopCalls, 1);
    expect(find.text('静候连接'), findsOneWidget);
  });

  testWidgets('探活失败：首页仍显示运行中＋拨测失败提示＋重新拨测按钮', (
    tester,
  ) async {
    // 2026-11-26 二轮修复（方案 A）：拨测失败不再翻 error——首页
    // 保持“运行中”，副标题写失败原因，另给“重新拨测”按钮；
    // 红字失败区只在真 error 时显示，这里不出现。
    // 注意：不要在这里重建 CoreService 再调 init()——init 内部读盘，
    // testWidgets 的 fake 时间下直接 await 文件 IO 永远等不到完成
    //（见本文件 tapSwitch 上的注释）；复用 setUp 建好的共享 service，
    // 只翻拨测桩的结果。
    fakeApi.delayResult = const ProxyDelayResult(
      failure: ProxyDelayFailure.failed,
    );
    await pumpHome(tester, nodes: [_node('甲-直连')]);
    await tapSwitch(tester);
    expect(plugin.startCalls, 1);
    // 启动校验是 fire-and-forget：预热 2 秒＋重试 2 秒的定时器是在
    // runAsync 真实区里建的，fake 时间的 pump 刷不动它，等 5 秒
    // 真实时间（两次拨测都失败才记探活失败），再刷帧渲染。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 5));
    });
    await pumpFrames(tester);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.textContaining('出站拨测失败'), findsOneWidget);
    expect(find.text('重新拨测'), findsOneWidget);
    expect(find.text('连接失败'), findsNothing);
    // 副标题被失败原因占了，不再是已连接时长。
    expect(find.textContaining('已连接 '), findsNothing);
    // 节点恢复后点“重新拨测”：提示消失，回到已连接时长。
    fakeApi.delayResult = const ProxyDelayResult(delay: 200);
    await tester.runAsync(() async {
      await tester.tap(find.text('重新拨测'));
      // 重测同样要等 2 秒预热（真实区定时器，等 3 秒真实时间）。
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    await pumpFrames(tester);
    expect(find.textContaining('出站拨测失败'), findsNothing);
    expect(find.text('重新拨测'), findsNothing);
    expect(find.textContaining('已连接 '), findsOneWidget);
  });

  testWidgets('点开关（TUN 关着）：自动打开 TUN 再启动，配置里有 tun 入站', (
    tester,
  ) async {
    await pumpHome(
      tester,
      nodes: [_node('甲-直连')],
      settingsOverride: _StubSettingsNotifier(initialTun: false),
    );
    await tapSwitch(tester);
    expect(plugin.startCalls, 1);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('已自动开启 TUN，否则无法代理'), findsOneWidget);
    final decoded =
        jsonDecode((await tester.runAsync<String>(
              () => File(configPath).readAsString(),
            ))!)
            as Map<String, dynamic>;
    final inbounds = decoded['inbounds'] as List;
    expect(inbounds.any((e) => (e as Map)['type'] == 'tun'), isTrue);
  });

  testWidgets('点开关（校验失败）：提示里带真实原因，不启动', (tester) async {
    // 2026-11-26：TUN 的 stack 字段被 schema 拒时这里只弹固定句
    // “配置生成失败，已保持上次连接”，用户完全不知道为什么。
    validator.errors = ['inbounds[1] 的 stack 字段不被允许'];
    await pumpHome(tester, nodes: [_node('甲-直连')]);
    await tapSwitch(tester);
    expect(plugin.startCalls, 0);
    expect(
      find.textContaining('inbounds[1] 的 stack 字段不被允许'),
      findsOneWidget,
    );
    expect(find.text('静候连接'), findsOneWidget);
  });

  testWidgets('点开关（无节点）：不启动，提示先绑定订阅并跳到我的页', (
    tester,
  ) async {
    await pumpHome(tester);
    await tapSwitch(tester);
    expect(plugin.startCalls, 0);
    expect(find.text('请先绑定订阅，再开启代理'), findsOneWidget);
    expect(goToMeCalls, 1);
    expect(find.text('静候连接'), findsOneWidget);
  });

  testWidgets('模式切换（已启动）：重载一次、磁盘配置跟着变', (tester) async {
    await pumpHome(tester, nodes: [_node('甲-直连')]);
    await tapSwitch(tester);
    expect(find.text('运行中'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('全局模式'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await pumpFrames(tester);
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
    await pumpFrames(tester);
    expect(plugin.reloadCalls, 2);
    decoded =
        jsonDecode((await tester.runAsync<String>(
              () => File(configPath).readAsString(),
            ))!)
            as Map<String, dynamic>;
    expect((decoded['route'] as Map)['final'], 'direct');
    // 0.1.6：直连模式只有 2 条前缀（sniff/私网旁路；
    // QUIC 阻断已随 0.1.6 回滚删掉），但没有任何规则引用 Proxy（全直连）。
    final directRules =
        ((decoded['route'] as Map)['rules'] as List)
            .cast<Map<String, dynamic>>();
    expect(directRules.length, 2);
    expect(directRules[0], {'action': 'sniff', 'timeout': '300ms'});
    expect(
      directRules[1],
      {'ip_is_private': true, 'outbound': 'direct'},
    );
    expect(directRules.any((r) => r['outbound'] == 'Proxy'), isFalse);
  });

  testWidgets('模式切换（校验失败）：提示里带真实原因，模式不变', (tester) async {
    // 2026-11-26：以前只弹固定句“切换失败，已保持原模式”。
    validator.errors = ['route 缺少 default_domain_resolver'];
    await pumpHome(tester, nodes: [_node('甲-直连')]);
    await tester.runAsync(() async {
      await tester.tap(find.text('全局模式'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await pumpFrames(tester);
    expect(plugin.reloadCalls, 0);
    expect(
      find.textContaining('route 缺少 default_domain_resolver'),
      findsOneWidget,
    );
    final segmented = tester.widget<SegmentedButton<String>>(
      find.byType(SegmentedButton<String>),
    );
    expect(segmented.selected, {'rule'});
  });

  // 切片 8：限流状态行与强制更新下载地址。
  testWidgets('已用 85%：首页显示接近限额状态行', (tester) async {
    await pumpHome(tester, userinfo: _limitedInfo(usedMB: 870));
    expect(
      find.text('已用 85%，接近限额，超量后节点可能停用'),
      findsOneWidget,
    );
  });

  testWidgets('已超量：首页显示超量状态行', (tester) async {
    await pumpHome(tester, userinfo: _limitedInfo(usedMB: 1100));
    expect(
      find.text('已超量：面板可能已停用该订阅，节点连不上时请联系管理员'),
      findsOneWidget,
    );
  });

  testWidgets('强制更新：升级说明里显示可复制的下载地址', (tester) async {
    await pumpHome(tester, remoteConfig: _forceUpdateConfig());
    expect(find.text('当前版本过低，请升级后使用'), findsOneWidget);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.text('需要升级客户端'), findsOneWidget);
    expect(find.text('下载地址（长按复制）：'), findsOneWidget);
    expect(find.text('https://example.com/download'), findsOneWidget);
  });

  // bundled 配置提示可关闭（第 5 项）：× 关闭、重试保留、持久化后重进不再出现。
  testWidgets('bundled 提示：首次出现，带关闭按钮与重试', (tester) async {
    await pumpHome(
      tester,
      remoteConfig: _bundledConfig(),
      remoteSource: RemoteConfigSource.bundled,
    );
    expect(find.text('首次启动需要联网拉取配置'), findsOneWidget);
    expect(find.text('拉不到配置也能先手动粘贴订阅使用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byTooltip('关闭提示'), findsOneWidget);
    // offline 与强制更新那两条不受影响：这里只出现 bundled 这一条。
    expect(find.text('配置中心暂时连不上，正在用上次的配置'), findsNothing);
    expect(find.text('当前版本过低，请升级后使用'), findsNothing);
  });

  testWidgets('bundled 提示：点 × 后整条消失、标志已持久化、重进不再出现', (
    tester,
  ) async {
    await pumpHome(
      tester,
      remoteConfig: _bundledConfig(),
      remoteSource: RemoteConfigSource.bundled,
    );
    expect(find.text('首次启动需要联网拉取配置'), findsOneWidget);
    // 点 ×：异步持久化走真方法通道，包在 runAsync 里等它完成
    //（见 tapSwitch：fake 时间下直接 await 等不到方法通道回包）。
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('关闭提示'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(find.text('首次启动需要联网拉取配置'), findsNothing);
    expect(find.text('拉不到配置也能先手动粘贴订阅使用'), findsNothing);
    final prefs = await tester.runAsync(
      () => SharedPreferences.getInstance(),
    );
    expect(prefs?.getBool(HomePage.bundledConfigHintDismissedKey), isTrue);
    // 重进首页（新 ProviderScope、新 HomePage 状态）：仍不出现。
    await pumpHome(
      tester,
      remoteConfig: _bundledConfig(),
      remoteSource: RemoteConfigSource.bundled,
    );
    expect(find.text('首次启动需要联网拉取配置'), findsNothing);
  });

  testWidgets('bundled 提示：已关过时源仍是 bundled 也不再出现', (tester) async {
    SharedPreferences.setMockInitialValues({
      HomePage.bundledConfigHintDismissedKey: true,
    });
    await pumpHome(
      tester,
      remoteConfig: _bundledConfig(),
      remoteSource: RemoteConfigSource.bundled,
    );
    expect(find.text('首次启动需要联网拉取配置'), findsNothing);
  });

  testWidgets('强制更新：配置里没给下载地址时只说明原因', (tester) async {
    final config = _forceUpdateConfig();
    final noUrl = RemoteConfig(
      configVersion: config.configVersion,
      minAppVersion: config.minAppVersion,
      forceUpdate: true,
      forceUpdateMessage: config.forceUpdateMessage,
      brand: config.brand,
      panelDomain: config.panelDomain,
      panelApiBase: config.panelApiBase,
      minPanelVersion: config.minPanelVersion,
      subscriptionUrl: config.subscriptionUrl,
      subscriptionBackupUrls: config.subscriptionBackupUrls,
      subscriptionFormat: config.subscriptionFormat,
      features: config.features,
    );
    await pumpHome(tester, remoteConfig: noUrl);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.text('需要升级客户端'), findsOneWidget);
    expect(find.text('下载地址（长按复制）：'), findsNothing);
  });

  // 第 9 项：首页卡片固定尺寸——状态卡与流量格不再随内容长短伸缩。
  //
  // 某张卡片的盒尺寸取 GlassCard 内部 ClipRRect 的尺寸（不含外边距），
  // 这样带 margin bottom spacingXs 的状态卡与无 margin 的当前节点卡
  // 才能直接比高度；宽度同理是卡片本身的宽。
  Size cardBoxSize(WidgetTester tester, String text) {
    final card = find
        .byType(GlassCard)
        .evaluate()
        .map((e) => e.widget)
        .firstWhere(
          (w) =>
              find
                  .descendant(
                    of: find.byWidget(w),
                    matching: find.textContaining(text),
                  )
                  .evaluate()
                  .isNotEmpty,
        );
    return tester.getSize(
      find.descendant(
        of: find.byWidget(card),
        matching: find.byType(ClipRRect),
      ),
    );
  }

  testWidgets('卡片固定尺寸（bundled 场景）：状态卡等高 72、流量格等高 102', (
    tester,
  ) async {
    // 长节点名＋大流量数值：改动前标题换行、数值换行会把卡片撑高，
    // 现在超长文案内部省略，卡片高度不动。
    final expire =
        DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
        1000;
    final info = SubscriptionUserinfo.parse(
      'upload=1610612736; download=0; total=10737418240; expire=$expire',
    );
    await pumpHome(
      tester,
      nodes: [_node('测试机-reality-443-这是一个很长的节点名字')],
      userinfo: info,
      remoteConfig: _bundledConfig(),
      remoteSource: RemoteConfigSource.bundled,
      viewSize: const Size(390, 2000),
    );
    // 状态卡：公告、当前节点——同高同宽、左右对齐；bundled 提示卡不在
    // 72 组里（问题 9：标题副标题完整换行显示，卡片由内容定高）。
    final statusSizes = [
      cardBoxSize(tester, '维护通知'),
      cardBoxSize(tester, '当前节点'),
    ];
    for (final size in statusSizes) {
      expect(size.height, 72);
    }
    expect(
      statusSizes.map((s) => s.width).toSet(),
      hasLength(1),
    );
    // bundled 提示卡：标题副标题完整显示、不省略（390 宽下标题
    // intrinsic 198px、可用只有 148px，单行会被截成“首次启动需要联网…”），
    // 卡片因此比 72 高。
    final hintTitle = tester.widget<Text>(
      find.text('首次启动需要联网拉取配置'),
    );
    expect(hintTitle.maxLines, isNull);
    expect(hintTitle.overflow, isNot(TextOverflow.ellipsis));
    final hintSubtitle = tester.widget<Text>(
      find.text('拉不到配置也能先手动粘贴订阅使用'),
    );
    expect(hintSubtitle.maxLines, isNull);
    expect(hintSubtitle.overflow, isNot(TextOverflow.ellipsis));
    expect(
      cardBoxSize(tester, '首次启动需要联网拉取配置').height,
      greaterThan(72),
    );
    // 流量格：实时速率、已用 / 总量、剩余流量、到期日、流量口径——
    // 同高同宽（数值两行那格不再比单行那格高）。
    final statSizes = [
      cardBoxSize(tester, '实时速率'),
      cardBoxSize(tester, '已用 / 总量'),
      cardBoxSize(tester, '剩余流量'),
      cardBoxSize(tester, '到期日'),
      cardBoxSize(tester, '流量口径'),
    ];
    for (final size in statSizes) {
      expect(size.height, 102);
    }
    expect(
      statSizes.map((s) => s.width).toSet(),
      hasLength(1),
    );
    // 超长节点名被省略显示，没有把卡片撑高（上两组断言已覆盖高度）。
    expect(find.textContaining('当前节点：测试机-reality-443'), findsOneWidget);
  });

  testWidgets('卡片固定尺寸（强制更新＋离线场景）：五张状态卡都等高 72', (
    tester,
  ) async {
    await pumpHome(
      tester,
      nodes: [_node('甲-直连')],
      remoteConfig: _forceUpdateConfig(),
      remoteSource: RemoteConfigSource.cached,
      viewSize: const Size(390, 2000),
    );
    final statusSizes = [
      cardBoxSize(tester, '当前版本过低'),
      cardBoxSize(tester, '配置中心暂时连不上'),
      cardBoxSize(tester, '维护通知'),
      cardBoxSize(tester, '当前节点'),
    ];
    for (final size in statusSizes) {
      expect(size.height, 72);
    }
    expect(
      statusSizes.map((s) => s.width).toSet(),
      hasLength(1),
    );
  });

  // 问题 5：首页当前节点卡片可点，弹节点列表弹窗选节点。
  testWidgets('当前节点卡片可点：点开弹窗，点一行切过去并关闭弹窗', (tester) async {
    final stub = _PickerStubNodesNotifier(
      nodes: [_node('甲-直连'), _node('乙-中转')],
      selected: '甲-直连',
    );
    await pumpHome(tester, nodesOverride: stub);
    expect(find.text('当前节点：甲-直连'), findsOneWidget);
    // 点当前节点卡片：弹窗列出节点、带测速入口。
    await tester.tap(find.text('当前节点：甲-直连'));
    await tester.pumpAndSettle();
    expect(find.text('选择节点'), findsOneWidget);
    expect(find.text('测速全部'), findsOneWidget);
    expect(find.text('测速当前节点'), findsOneWidget);
    // 分组默认全部折叠：组头在、节点不在，点组头展开才看到节点。
    expect(find.text('未命名订阅'), findsOneWidget);
    expect(find.text('甲-直连'), findsNothing);
    expect(find.text('乙-中转'), findsNothing);
    await tester.tap(find.text('未命名订阅'));
    await tester.pumpAndSettle();
    expect(find.text('甲-直连'), findsOneWidget);
    expect(find.text('乙-中转'), findsOneWidget);
    // 点乙：切过去、弹窗关闭、首页当前节点变成乙。
    await tester.tap(find.text('乙-中转'));
    await tester.pumpAndSettle();
    expect(find.text('选择节点'), findsNothing);
    expect(find.text('当前节点：乙-中转'), findsOneWidget);
  });

  testWidgets('节点弹窗：点“测速当前节点”，只测选中节点、延迟就地更新', (
    tester,
  ) async {
    final stub = _PickerStubNodesNotifier(
      nodes: [_node('甲-直连'), _node('乙-中转')],
      selected: '甲-直连',
    );
    await pumpHome(tester, nodesOverride: stub);
    await tester.tap(find.text('当前节点：甲-直连'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未命名订阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测速当前节点'));
    await tester.pumpAndSettle();
    expect(stub.testSingleCalls, 1);
    // 只测了选中的甲：弹窗里甲显示 88ms（绿色），乙还是未测速。
    expect(find.text('88ms'), findsOneWidget);
    expect(find.text('未测速'), findsOneWidget);
    final latencyText = tester.widget<Text>(find.text('88ms'));
    expect(latencyText.style?.color, const Color(0xFF157347));
  });

  testWidgets('节点弹窗：切节点失败时原因留在弹窗里，不静默、不关弹窗', (
    tester,
  ) async {
    final stub = _PickerStubNodesNotifier(
      nodes: [_node('甲-直连'), _node('乙-中转')],
      selected: '甲-直连',
    )
      ..selectResult = false
      ..selectReason = '切换失败，核心没有响应';
    await pumpHome(tester, nodesOverride: stub);
    await tester.tap(find.text('当前节点：甲-直连'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未命名订阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙-中转'));
    await tester.pumpAndSettle();
    expect(find.text('选择节点'), findsOneWidget);
    expect(find.text('切换失败，核心没有响应'), findsOneWidget);
    expect(find.text('当前节点：甲-直连'), findsOneWidget);
  });

  testWidgets('节点弹窗：无节点时点当前节点卡片不弹弹窗、提示去绑定', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.text('当前节点：未选择'));
    await tester.pumpAndSettle();
    expect(find.text('选择节点'), findsNothing);
    expect(find.text('请先绑定订阅，再选择节点'), findsOneWidget);
    expect(goToMeCalls, 1);
  });

  // 问题 8：首页小卡片之间留 8px 缝隙，两行都改，高度与内容不变。
  testWidgets('小卡片间距：两行三格之间各留 8px，流量格仍是 102 高', (
    tester,
  ) async {
    await pumpHome(
      tester,
      nodes: [_node('甲-直连')],
      viewSize: const Size(390, 2000),
    );
    Rect cardRect(String label) {
      final card = find
          .byType(GlassCard)
          .evaluate()
          .map((e) => e.widget)
          .firstWhere(
            (w) =>
                find
                    .descendant(
                      of: find.byWidget(w),
                      matching: find.text(label),
                    )
                    .evaluate()
                    .isNotEmpty,
          );
      return tester.getRect(
        find.descendant(
          of: find.byWidget(card),
          matching: find.byType(ClipRRect),
        ),
      );
    }

    // 第一行：实时速率 | 已用 / 总量 | 剩余流量。
    final rate = cardRect('实时速率');
    final used = cardRect('已用 / 总量');
    final remain = cardRect('剩余流量');
    expect(used.left - rate.right, 8);
    expect(remain.left - used.right, 8);
    // 第二行：到期日 | 流量口径 | 空格。
    final expire = cardRect('到期日');
    final caliber = cardRect('流量口径');
    expect(caliber.left - expire.right, 8);
    // 高度与内容不变：流量格仍是 102。
    expect(rate.height, 102);
    expect(expire.height, 102);
  });

  // 问题 9：360 窄屏下 bundled 提示标题副标题仍完整显示、不省略。
  testWidgets('bundled 提示：360 窄屏下标题副标题完整显示、不省略', (
    tester,
  ) async {
    await pumpHome(
      tester,
      remoteConfig: _bundledConfig(),
      remoteSource: RemoteConfigSource.bundled,
      viewSize: const Size(360, 2000),
    );
    final hintTitle = tester.widget<Text>(
      find.text('首次启动需要联网拉取配置'),
    );
    expect(hintTitle.maxLines, isNull);
    expect(hintTitle.overflow, isNot(TextOverflow.ellipsis));
    final hintSubtitle = tester.widget<Text>(
      find.text('拉不到配置也能先手动粘贴订阅使用'),
    );
    expect(hintSubtitle.maxLines, isNull);
    expect(hintSubtitle.overflow, isNot(TextOverflow.ellipsis));
  });

  // 节点弹窗按订阅分组（2026-11-26）：不同订阅的节点不混在一起，
  // 分组默认折叠，点组头展开/收起；测速全部与单行测速入口。
  testWidgets('节点弹窗分组：默认全部折叠，点组头展开只看到该组节点', (
    tester,
  ) async {
    final stub = _PickerStubNodesNotifier(
      nodes: [
        _node(
          '甲-A',
          subscriptionId: 'sub-a',
          subscriptionName: '自家面板',
        ),
        _node(
          '乙-A',
          subscriptionId: 'sub-a',
          subscriptionName: '自家面板',
        ),
        _node('丙-B', subscriptionId: 'sub-b', subscriptionName: '机场B'),
        _node(
          '丁-手',
          subscriptionId: 'single_nodes',
          subscriptionName: '手动添加',
        ),
      ],
      selected: '甲-A',
    );
    await pumpHome(tester, nodesOverride: stub);
    await tester.tap(find.text('当前节点：甲-A'));
    await tester.pumpAndSettle();
    // 默认全部折叠：三个组头都在，节点一个都不显示。
    expect(find.text('自家面板'), findsOneWidget);
    expect(find.text('机场B'), findsOneWidget);
    expect(find.text('手动添加'), findsOneWidget);
    expect(find.text('甲-A'), findsNothing);
    expect(find.text('乙-A'), findsNothing);
    expect(find.text('丙-B'), findsNothing);
    expect(find.text('丁-手'), findsNothing);
    // 点“自家面板”展开：只看到该组的甲、乙，丙、丁还藏着。
    await tester.tap(find.text('自家面板'));
    await tester.pumpAndSettle();
    expect(find.text('甲-A'), findsOneWidget);
    expect(find.text('乙-A'), findsOneWidget);
    expect(find.text('丙-B'), findsNothing);
    expect(find.text('丁-手'), findsNothing);
    // 再点收起：甲、乙又藏起来。
    await tester.tap(find.text('自家面板'));
    await tester.pumpAndSettle();
    expect(find.text('甲-A'), findsNothing);
    expect(find.text('乙-A'), findsNothing);
    // 另一组独立展开：点“机场B”只看到丙。
    await tester.tap(find.text('机场B'));
    await tester.pumpAndSettle();
    expect(find.text('丙-B'), findsOneWidget);
    expect(find.text('甲-A'), findsNothing);
  });

  testWidgets('节点弹窗分组标题：没订阅名用订阅 id，两者都没有叫未命名订阅', (
    tester,
  ) async {
    final stub = _PickerStubNodesNotifier(
      nodes: [
        _node('甲', subscriptionId: 'sub-x'),
        _node('乙'),
      ],
      selected: '甲',
    );
    await pumpHome(tester, nodesOverride: stub);
    await tester.tap(find.text('当前节点：甲'));
    await tester.pumpAndSettle();
    expect(find.text('sub-x'), findsOneWidget);
    expect(find.text('未命名订阅'), findsOneWidget);
  });

  testWidgets('节点弹窗分组标题：单节点组没名字也叫手动添加', (tester) async {
    final stub = _PickerStubNodesNotifier(
      nodes: [_node('丁-手', subscriptionId: 'single_nodes')],
      selected: '丁-手',
    );
    await pumpHome(tester, nodesOverride: stub);
    await tester.tap(find.text('当前节点：丁-手'));
    await tester.pumpAndSettle();
    expect(find.text('手动添加'), findsOneWidget);
  });

  testWidgets('节点弹窗测速全部：点一次测全部节点，延迟就地更新', (tester) async {
    final stub = _PickerStubNodesNotifier(
      nodes: [
        _node(
          '甲-A',
          subscriptionId: 'sub-a',
          subscriptionName: '自家面板',
        ),
        _node('丙-B', subscriptionId: 'sub-b', subscriptionName: '机场B'),
      ],
      selected: '甲-A',
    );
    await pumpHome(tester, nodesOverride: stub);
    await tester.tap(find.text('当前节点：甲-A'));
    await tester.pumpAndSettle();
    // 折叠时也能测全部：不用先展开。
    await tester.tap(find.text('测速全部'));
    await tester.pumpAndSettle();
    expect(stub.testAllCalls, 1);
    expect(stub.testSingleCalls, 0);
    await tester.tap(find.text('自家面板'));
    await tester.tap(find.text('机场B'));
    await tester.pumpAndSettle();
    expect(find.text('55ms'), findsNWidgets(2));
  });

  testWidgets('节点弹窗测速全部：测速中按钮禁用，测完才恢复', (tester) async {
    final stub = _PickerStubNodesNotifier(
      nodes: [_node('甲-直连'), _node('乙-中转')],
      selected: '甲-直连',
    )..testAllGate = Completer<bool>();
    await pumpHome(tester, nodesOverride: stub);
    await tester.tap(find.text('当前节点：甲-直连'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测速全部'));
    await tester.pump();
    // 测速中：“测速全部”变成“测速中…”且禁用，再点也不会多调一次。
    expect(find.text('测速中…'), findsOneWidget);
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '测速中…'),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.text('测速中…'), warnIfMissed: false);
    await tester.pump();
    expect(stub.testAllCalls, 1);
    stub.testAllGate!.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('测速全部'), findsOneWidget);
    await tester.tap(find.text('未命名订阅'));
    await tester.pumpAndSettle();
    expect(find.text('55ms'), findsNWidgets(2));
  });

  testWidgets('节点弹窗单行测速：点行内延迟处只测这一行', (tester) async {
    final stub = _PickerStubNodesNotifier(
      nodes: [_node('甲-直连'), _node('乙-中转')],
      selected: '甲-直连',
    );
    await pumpHome(tester, nodesOverride: stub);
    await tester.tap(find.text('当前节点：甲-直连'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未命名订阅'));
    await tester.pumpAndSettle();
    // 点甲那行的“未测速”（延迟处）：只测甲，不测乙、不关弹窗。
    final latency = find.descendant(
      of: find.widgetWithText(ListTile, '甲-直连'),
      matching: find.text('未测速'),
    );
    await tester.tap(latency);
    await tester.pumpAndSettle();
    expect(stub.testSingleCalls, 1);
    expect(stub.testAllCalls, 0);
    expect(find.text('选择节点'), findsOneWidget);
    expect(find.text('88ms'), findsOneWidget);
    expect(find.text('未测速'), findsOneWidget);
  });

  testWidgets('节点弹窗选中不挪位置：选了组内第二个，重进后顺序不变', (
    tester,
  ) async {
    final stub = _PickerStubNodesNotifier(
      nodes: [
        _node(
          '甲-A',
          subscriptionId: 'sub-a',
          subscriptionName: '自家面板',
        ),
        _node(
          '乙-A',
          subscriptionId: 'sub-a',
          subscriptionName: '自家面板',
        ),
      ],
      selected: '甲-A',
    );
    await pumpHome(tester, nodesOverride: stub);
    await tester.tap(find.text('当前节点：甲-A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自家面板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙-A'));
    await tester.pumpAndSettle();
    expect(find.text('当前节点：乙-A'), findsOneWidget);
    // 重进弹窗再展开：甲仍在乙上面，没被挪到下面、也没重排。
    await tester.tap(find.text('当前节点：乙-A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自家面板'));
    await tester.pumpAndSettle();
    final topA = tester.getTopLeft(find.text('甲-A')).dy;
    final topB = tester.getTopLeft(find.text('乙-A')).dy;
    expect(topA, lessThan(topB));
  });

  testWidgets('公告：没有公告时公告栏不存在，不留占位', (tester) async {
    await pumpHome(tester, announcements: []);
    expect(find.byType(AnnouncementMarquee), findsNothing);
    expect(find.text('维护通知'), findsNothing);
  });

  testWidgets('公告：有公告时跑马灯出现，点进公告列表页', (tester) async {
    await pumpHome(tester);
    expect(find.byType(AnnouncementMarquee), findsOneWidget);
    expect(find.text('维护通知'), findsOneWidget);
    await tester.tap(find.byType(AnnouncementMarquee));
    await tester.pumpAndSettle();
    // 列表页：标题栏“公告”，列表里有这条的标题＋正文＋时间。
    expect(find.text('公告'), findsOneWidget);
    expect(find.text('维护通知'), findsOneWidget);
    expect(find.text('今晚维护'), findsOneWidget);
    expect(find.textContaining('2026-11-26'), findsOneWidget);
  });

  testWidgets('开关五种状态文案：未连接/连接中/运行中/断开中/失败', (
    tester,
  ) async {
    await pumpHome(tester, nodes: [_node('甲-直连')]);
    // 未连接。
    expect(find.text('静候连接'), findsOneWidget);
    expect(find.text('轻触开启'), findsOneWidget);

    // 连接中。
    await tester.runAsync(() async {
      plugin.emit(const ProxyStarting());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await pumpFrames(tester);
    expect(find.text('正在连接…'), findsOneWidget);
    expect(find.text('稍等片刻'), findsOneWidget);

    // 已连接。
    await tester.runAsync(() async {
      plugin.emit(const ProxyStarted());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await pumpFrames(tester);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.textContaining('已连接'), findsOneWidget);

    // 断开中。
    await tester.runAsync(() async {
      plugin.emit(const ProxyStopping());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await pumpFrames(tester);
    expect(find.text('正在断开…'), findsOneWidget);

    // 失败。
    await tester.runAsync(() async {
      plugin.emit(const ProxyStopped(errMessage: '内核崩了'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('连接失败'), findsOneWidget);
    expect(find.text('轻触重试'), findsOneWidget);
  });
}
