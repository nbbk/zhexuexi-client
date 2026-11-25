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
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/remote_config_notifier.dart';
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

/// 强制更新的配置（当前版本 0.1.0 < 最低 0.2.0，带下载地址）。
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
    String? selected,
    RemoteConfig? remoteConfig,
    RemoteConfigSource remoteSource = RemoteConfigSource.fresh,
    Size viewSize = const Size(800, 1600),
  }) async {
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
            () => _StubNodesNotifier(
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
    expect(((decoded['route'] as Map)['rules'] as List), isEmpty);
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
    // 状态卡：bundled 提示、公告、当前节点——同高同宽、左右对齐。
    final statusSizes = [
      cardBoxSize(tester, '首次启动需要联网拉取配置'),
      cardBoxSize(tester, '暂无公告'),
      cardBoxSize(tester, '当前节点'),
    ];
    for (final size in statusSizes) {
      expect(size.height, 72);
    }
    expect(
      statusSizes.map((s) => s.width).toSet(),
      hasLength(1),
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
      cardBoxSize(tester, '暂无公告'),
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
}
