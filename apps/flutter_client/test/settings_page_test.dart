// 切片 6：设置页（两层结构、模式切换入口、开关持久化、DNS 查看、
// 自定义规则管理、诊断包、清除缓存）的 Widget 回归测试。插件、校验器、
// 配置路径全部可注入 fake，不碰平台通道、不碰 MMKV、不碰真核心。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sing_box/flutter_sing_box.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/config_validator.dart';
import 'package:zhexuexi_client/core/core_provider.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/singbox_core.dart';
import 'package:zhexuexi_client/features/settings/settings_page.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/remote_config_notifier.dart';
import 'package:zhexuexi_client/services/remote_config_service.dart';

/// 插件 fake：只记调用、不碰平台通道，状态由测试手动推。
class _FakePlugin extends FlutterSingBox {
  final _stateController = StreamController<ProxyState>.broadcast();
  int reloadCalls = 0;

  @override
  Stream<ProxyState> get proxyStateStream => _stateController.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> startVpn() async {
    _stateController.add(const ProxyStarted());
  }

  @override
  Future<void> stopVpn() async {
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

/// 节点列表桩：只返回给定的节点，不拉订阅。
class _StubNodesNotifier extends NodesNotifier {
  _StubNodesNotifier({required this.nodes, this.selected, this.speedTestAt});

  final List<Node> nodes;
  final String? selected;
  final DateTime? speedTestAt;

  @override
  NodesState build() => NodesState(
    nodes: nodes,
    status: NodesStatus.loaded,
    selectedNodeName: selected,
    speedTestAt: speedTestAt,
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('settings-page-test-');
    configPath = '${tmpDir.path}/using_config.json';
    plugin = _FakePlugin();
    service = CoreService(
      plugin: plugin,
      validator: _FakeValidator(),
      usingConfigPath: () async => configPath,
      ensureSelectedProfile: (_) async {},
    );
    await service.init();
  });

  tearDown(() async {
    service.dispose();
    await plugin.close();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    List<Node> nodes = const [],
    String? selected,
    List<Override> extraOverrides = const [],
  }) async {
    // 设置页内容很长（高级展开后更多），用高视口一次全渲染。
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreServiceProvider.overrideWithValue(service),
          nodesProvider.overrideWith(
            () => _StubNodesNotifier(nodes: nodes, selected: selected),
          ),
          ...extraOverrides,
        ],
        child: const MaterialApp(
          home: Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 点一个开关/按钮：处理里有真异步（写配置、写偏好），tap 与等待
  /// 必须包在 runAsync（真实异步区）里，再 pumpAndSettle 刷界面。
  Future<void> tapAsync(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  Future<void> expandAdvanced(WidgetTester tester) async {
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
  }

  /// 读回写盘的配置：真实文件 IO，必须包在 runAsync 里（测试体是
  /// fake-async 区，裸 await 真实 IO 会死锁，见本片模式切换测试
  /// 的定位过程）。
  Future<Map<String, dynamic>> readWrittenConfig(
    WidgetTester tester,
  ) async {
    late final String content;
    await tester.runAsync(() async {
      content = await File(configPath).readAsString();
    });
    return jsonDecode(content) as Map<String, dynamic>;
  }

  testWidgets('两层结构：常用在上、高级默认折叠、关于在下', (tester) async {
    await pumpSettings(tester);
    expect(find.text('常用设置'), findsOneWidget);
    expect(find.text('高级设置'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('规则模式'), findsOneWidget);
    expect(find.text('订阅自动更新'), findsOneWidget);
    expect(find.text('客户端版本'), findsOneWidget);
    // 高级默认折叠：TUN、DNS、诊断都在折叠里，不可见。
    expect(find.text('TUN 模式'), findsNothing);
    expect(find.text('导出诊断包'), findsNothing);

    await expandAdvanced(tester);
    expect(find.text('TUN 模式'), findsOneWidget);
    expect(find.text('DNS 配置'), findsOneWidget);
    expect(find.text('自定义规则'), findsOneWidget);
    expect(find.text('导出诊断包'), findsOneWidget);
    expect(find.text('连接检测'), findsOneWidget);
    expect(find.text('清除缓存'), findsOneWidget);
  });

  testWidgets('模式切换入口：点全局模式，配置写盘 final 指 Proxy', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      nodes: [_node('日本-直连')],
      selected: '日本-直连',
    );
    await tapAsync(tester, find.text('全局模式'));
    final config = await readWrittenConfig(tester);
    expect((config['route'] as Map)['final'], 'Proxy');
  });

  testWidgets('订阅自动更新开关：关掉后偏好持久化', (tester) async {
    await pumpSettings(tester);
    await tapAsync(tester, find.text('订阅自动更新'));
    late final SharedPreferences prefs;
    await tester.runAsync(() async {
      prefs = await SharedPreferences.getInstance();
    });
    expect(prefs.getBool('settings_auto_update'), isFalse);
  });

  testWidgets('DNS 配置查看：DoH 双路与 DoT 兜底可见，写明不可关闭', (
    tester,
  ) async {
    await pumpSettings(tester);
    await expandAdvanced(tester);
    await tester.tap(find.text('DNS 配置'));
    await tester.pumpAndSettle();
    expect(find.text('DoH https://1.1.1.1/dns-query'), findsOneWidget);
    expect(find.text('DoH https://dns.google/dns-query（经代理出站）'), findsOneWidget);
    expect(find.text('DoT 8.8.8.8:853'), findsOneWidget);
    expect(find.text('防泄漏不可关闭'), findsOneWidget);
    // 全配置摘要里没有明文 UDP 服务器写法。
    expect(find.textContaining('udp'), findsNothing);
  });

  testWidgets('自定义规则：添加成功进列表；重复添加提示且不重复', (
    tester,
  ) async {
    await pumpSettings(tester);
    await expandAdvanced(tester);
    expect(find.text('暂无自定义规则，默认按内置规则分流'), findsOneWidget);

    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Example.COM');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('暂无自定义规则，默认按内置规则分流'), findsNothing);

    // 同域名再加一次：提示原因，列表仍只有一条。
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '*.example.com');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('域名不合格或已存在，未添加'), findsOneWidget);
  });

  testWidgets('自定义规则：不合格域名不添加', (tester) async {
    await pumpSettings(tester);
    await expandAdvanced(tester);
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not a domain');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('域名不合格或已存在，未添加'), findsOneWidget);
    expect(find.text('暂无自定义规则，默认按内置规则分流'), findsOneWidget);
  });

  testWidgets('TUN 开关：打开后配置里出现 tun 入站', (tester) async {
    await pumpSettings(
      tester,
      nodes: [_node('日本-直连')],
      selected: '日本-直连',
    );
    await expandAdvanced(tester);
    await tapAsync(tester, find.text('TUN 模式'));
    final config = await readWrittenConfig(tester);
    final inbounds = config['inbounds'] as List;
    expect(inbounds.length, 2);
    expect((inbounds[1] as Map)['type'], 'tun');
    expect((inbounds[1] as Map)['tag'], 'tun-in');
  });

  testWidgets('导出诊断包：弹窗显示报告，不含节点地址', (tester) async {
    final node = _node('日本-直连');
    await pumpSettings(tester, nodes: [node], selected: '日本-直连');
    await expandAdvanced(tester);
    await tester.tap(find.text('导出诊断包'));
    await tester.pumpAndSettle();
    expect(find.text('诊断包'), findsOneWidget);
    expect(find.textContaining('日本-直连'), findsWidgets);
    expect(find.textContaining('203.0.113.1'), findsNothing);
    expect(find.textContaining('x9f2'), findsNothing);
  });

  testWidgets('连接检测：核心未启动时直接报未启动', (tester) async {
    await pumpSettings(tester);
    await expandAdvanced(tester);
    await tester.tap(find.text('连接检测'));
    await tester.pumpAndSettle();
    // 弹窗标题与设置行标题都是“连接检测”，断言弹窗里的结论文案。
    expect(find.textContaining('核心未启动'), findsOneWidget);
  });

  testWidgets('清除缓存：确认后提示已清除，节点延迟清零', (tester) async {
    final node = _node('日本-直连');
    node.latencyMs = 123;
    await pumpSettings(tester, nodes: [node], selected: '日本-直连');
    await expandAdvanced(tester);
    await tester.tap(find.text('清除缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(find.text('已清除测速缓存'), findsOneWidget);
    expect(node.latencyMs, isNull);
  });

  testWidgets('检查更新：拉不到配置时报检查失败，不假装已检查', (
    tester,
  ) async {
    // 地址链为空：一次都不拉，直接 failed。
    final failing = RemoteConfigService(configUrls: const []);
    await pumpSettings(
      tester,
      extraOverrides: [
        remoteConfigServiceProvider.overrideWithValue(failing),
      ],
    );
    await tapAsync(tester, find.text('检查更新'));
    expect(find.textContaining('当前版本 0.1.0'), findsOneWidget);
    expect(find.textContaining('检查失败，请检查网络后重试'), findsOneWidget);
  });

  testWidgets('检查更新：全部地址都 404 时报远程配置暂未发布，不说网络问题', (
    tester,
  ) async {
    // 假 Dio：任何地址都直接回 404（服务端缺口：配置还没发布）。
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 404,
              data: '',
            ),
          );
        },
      ),
    );
    final service = RemoteConfigService(
      dio: dio,
      configUrls: const ['http://127.0.0.1:18081/client-config.json'],
    );
    await pumpSettings(
      tester,
      extraOverrides: [
        remoteConfigServiceProvider.overrideWithValue(service),
      ],
    );
    await tapAsync(tester, find.text('检查更新'));
    expect(find.textContaining('当前版本 0.1.0'), findsOneWidget);
    expect(find.textContaining('远程配置暂未发布'), findsOneWidget);
    expect(find.textContaining('请检查网络后重试'), findsNothing);
  });

  testWidgets('检查更新：拉到新版时报已更新到配置版本', (tester) async {
    // 真密钥签名的 fixture（test/fixtures/remote_config_v1.json，
    // v1）：假 Dio 返回它，服务用编译进客户端的公钥验签。
    // 读文件是真实 IO，必须包进 runAsync（假异步区里裸 await
    // 真实 IO 永远等不到完成，见 readWrittenConfig 的注释）。
    late final String envelope;
    await tester.runAsync(() async {
      envelope = await File(
        'test/fixtures/remote_config_v1.json',
      ).readAsString();
    });
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: envelope,
            ),
          );
        },
      ),
    );
    final service = RemoteConfigService(
      dio: dio,
      configUrls: const ['http://127.0.0.1:18081/client-config.json'],
    );
    await pumpSettings(
      tester,
      extraOverrides: [
        remoteConfigServiceProvider.overrideWithValue(service),
      ],
    );
    await tapAsync(tester, find.text('检查更新'));
    expect(find.textContaining('当前版本 0.1.0'), findsOneWidget);
    expect(find.textContaining('已更新到配置 v1'), findsOneWidget);
  });

  test('清除测速缓存（Notifier 层）：延迟与上次测速时间清零，节点不动', () {
    SharedPreferences.setMockInitialValues({});
    final node = _node('日本-直连');
    node.latencyMs = 123;
    final node2 = _node('韩国-直连');
    node2.latencyFailed = true;
    final container = ProviderContainer(
      overrides: [
        nodesProvider.overrideWith(
          () => _StubNodesNotifier(
            nodes: [node, node2],
            speedTestAt: DateTime(2026, 11, 23, 1, 0, 0),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(nodesProvider.notifier).clearSpeedResults();
    final state = container.read(nodesProvider);
    expect(state.nodes.length, 2);
    expect(state.nodes[0].latencyMs, isNull);
    expect(state.nodes[1].latencyFailed, isFalse);
    expect(state.speedTestAt, isNull);
  });

  testWidgets('主题切换：白天/夜晚分段选，切换后持久化', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpSettings(tester);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('白天'), findsOneWidget);
    expect(find.text('夜晚'), findsOneWidget);
    // 设置页有两个 SegmentedButton（分流模式＋主题）：
    // 按段值认主题那组（含 'night' 段）。
    SegmentedButton<String> themeSegmented() {
      final all = tester.widgetList<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      return all.firstWhere(
        (s) => s.segments.any((seg) => seg.value == 'night'),
      );
    }

    expect(themeSegmented().selected, {'day'});
    await tapAsync(tester, find.text('夜晚'));
    expect(themeSegmented().selected, {'night'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_theme_id'), 'night');
    await tapAsync(tester, find.text('白天'));
    expect(themeSegmented().selected, {'day'});
    expect(prefs.getString('app_theme_id'), 'day');
  });
}
