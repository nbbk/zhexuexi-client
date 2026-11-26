// 切片 3：模式切换（成功重载 / 校验失败不回滚磁盘 / 重载失败回滚旧模式 /
// 持久化恢复）的回归测试。插件、校验器、配置路径全部可注入 fake，
// 不碰平台通道、不碰 MMKV；配置写临时目录。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sing_box/flutter_sing_box.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/clash_api_client.dart';
import 'package:zhexuexi_client/core/config_validator.dart';
import 'package:zhexuexi_client/core/core_provider.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/routing_mode.dart';
import 'package:zhexuexi_client/core/singbox_core.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/routing_mode_notifier.dart';

/// 插件 fake：只记调用、不碰平台通道，状态由测试手动推。
class _FakePlugin extends FlutterSingBox {
  final _stateController = StreamController<ProxyState>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int reloadCalls = 0;
  bool throwOnReload = false;

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
    if (throwOnReload) throw StateError('重载失败');
    _stateController.add(const ProxyStarted());
  }

  @override
  Future<String> getSingBoxVersion() async => '1.14.4';

  void emit(ProxyState state) => _stateController.add(state);

  Future<void> close() => _stateController.close();
}

/// Clash API fake：启动后校验（`CoreService._verifyControlApi`）取一帧
/// 就回，不碰真网络。widget 测试里 HttpClient 一律回 400，不注入
/// 这个 fake 时校验会把状态翻成 error（问题 6 的探活副作用）。
class _FakeClashApi extends ClashApiClient {
  @override
  Future<TrafficSample> trafficSample({
    Duration timeout = const Duration(seconds: 5),
  }) async => const TrafficSample(up: 0, down: 0);

  /// 启动后校验的拨测桩：默认测通；不桩它时真实现会去连
  /// 127.0.0.1:9090，widget 测试里 HttpClient 一律回 400，
  /// 校验把状态翻成 error（与 home_page_test 同款回归）。
  @override
  Future<ProxyDelayResult> proxyDelayDetailed(
    String proxyName, {
    Duration timeout = const Duration(seconds: 5),
  }) async => const ProxyDelayResult(delay: 100);
}

/// 校验器 fake：按开关返回通过或固定错误。
class _FakeValidator implements ConfigValidator {
  List<String> errors = const [];

  @override
  Future<List<String>> validate(Map<String, dynamic> config) async => errors;
}

/// 节点列表桩：只返回给定的节点，不拉订阅。
class _StubNodesNotifier extends NodesNotifier {
  _StubNodesNotifier(this._nodes);

  final List<Node> _nodes;

  @override
  NodesState build() =>
      NodesState(nodes: _nodes, status: NodesStatus.loaded);
}

Node _node(String name) => Node(
  name: name,
  protocol: NodeProtocol.vless,
  address: '203.0.113.1',
  port: 443,
  source: NodeSource.direct,
  uuidOrPassword: '11111111-2222-3333-4444-555555555555',
  tls: true,
  sni: 'example.com',
);

/// 让广播流的事件与 Notifier 里读持久化的 Future 送达。
/// SharedPreferences 读回要走一趟方法通道，只靠零延迟等不到，
/// 补一段真实延迟（普通 test 里真实时间可用）。
Future<void> _pumpEvents() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

void main() {
  late Directory tmpDir;
  late String configPath;
  late _FakePlugin plugin;
  late _FakeValidator validator;
  late CoreService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('proxy-mode-test-');
    configPath = '${tmpDir.path}/using_config.json';
    plugin = _FakePlugin();
    validator = _FakeValidator();
    service = CoreService(
      plugin: plugin,
      validator: validator,
      usingConfigPath: () async => configPath,
      ensureSelectedProfile: (_) async {},
      clashApiClient: _FakeClashApi(),
    );
    await service.init();
  });

  tearDown(() async {
    service.dispose();
    await plugin.close();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  ProviderContainer makeContainer({List<Node> nodes = const []}) {
    return ProviderContainer(
      overrides: [
        coreServiceProvider.overrideWithValue(service),
        nodesProvider.overrideWith(() => _StubNodesNotifier(nodes)),
      ],
    );
  }

  Future<String> readConfig() => File(configPath).readAsString();

  test('默认规则模式；已运行时切全局：重载一次、持久化、状态变全局', () async {
    final container = makeContainer(nodes: [_node('甲-直连')]);
    addTearDown(container.dispose);
    await _pumpEvents();
    expect(container.read(routingModeProvider).mode, RoutingMode.rule);

    // 先让核心跑起来（规则模式配置已写盘）。
    final applied = await service.applyNodes([_node('甲-直连')]);
    expect(applied.ok, isTrue);
    plugin.emit(const ProxyStarted());
    await _pumpEvents();
    expect(service.status, CoreStatus.started);

    final ok = await container
        .read(routingModeProvider.notifier)
        .setMode(RoutingMode.global);
    expect(ok, isTrue);
    expect(plugin.reloadCalls, 1);
    expect(container.read(routingModeProvider).mode, RoutingMode.global);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('proxy_mode'), 'global');
    // 磁盘配置已是全局模式：route.final 指 Proxy。
    final decoded = jsonDecode(await readConfig()) as Map<String, dynamic>;
    expect((decoded['route'] as Map)['final'], 'Proxy');
  });

  test('停止时切换：写盘、不重载、持久化', () async {
    final container = makeContainer(nodes: [_node('甲-直连')]);
    addTearDown(container.dispose);
    await _pumpEvents();

    final ok = await container
        .read(routingModeProvider.notifier)
        .setMode(RoutingMode.direct);
    expect(ok, isTrue);
    expect(plugin.reloadCalls, 0);
    expect(container.read(routingModeProvider).mode, RoutingMode.direct);
    final decoded = jsonDecode(await readConfig()) as Map<String, dynamic>;
    expect((decoded['route'] as Map)['final'], 'direct');
    // 直连模式 route 只有前两条基础规则（都不引用 Proxy），切换后仍含
    // sniff（劫持 DNS 已随 0.1.3 D 路第 1 步去掉，QUIC 阻断已随
    // 0.1.4 D 路第 2 步去掉、0.1.5 加回、0.1.6 回滚删掉）。
    final rules = ((decoded['route'] as Map)['rules'] as List)
        .cast<Map<String, dynamic>>();
    expect(rules.length, 2);
    expect(rules[0], {'action': 'sniff', 'timeout': '300ms'});
    expect(rules[1], {'ip_is_private': true, 'outbound': 'direct'});
  });

  test('切到同一模式是空操作，不重载、不写盘', () async {
    final container = makeContainer(nodes: [_node('甲-直连')]);
    addTearDown(container.dispose);
    await _pumpEvents();

    final ok = await container
        .read(routingModeProvider.notifier)
        .setMode(RoutingMode.rule);
    expect(ok, isTrue);
    expect(plugin.reloadCalls, 0);
    expect(await File(configPath).exists(), isFalse);
  });

  test('校验失败：模式不变、磁盘旧配置不动、不重载、返回 false', () async {
    final container = makeContainer(nodes: [_node('甲-直连')]);
    addTearDown(container.dispose);
    await _pumpEvents();
    final first = await service.applyNodes([_node('甲-直连')]);
    expect(first.ok, isTrue);
    final oldContent = await readConfig();
    plugin.emit(const ProxyStarted());
    await _pumpEvents();

    validator.errors = ['route 缺少 default_domain_resolver'];
    final ok = await container
        .read(routingModeProvider.notifier)
        .setMode(RoutingMode.global);
    expect(ok, isFalse);
    expect(container.read(routingModeProvider).mode, RoutingMode.rule);
    // 失败原因要进 errorMessage（2026-11-26：以前只剩固定句，
    // 首页弹的也是固定句）；界面直接显示这条。
    expect(
      container.read(routingModeProvider).errorMessage,
      contains('route 缺少 default_domain_resolver'),
    );
    expect(await readConfig(), oldContent);
    expect(plugin.reloadCalls, 0);
    // 校验失败不持久化：下次启动仍是规则模式。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('proxy_mode'), isNull);
  });

  test('重载抛错：回滚旧模式配置、模式不变、返回 false', () async {
    final container = makeContainer(nodes: [_node('甲-直连')]);
    addTearDown(container.dispose);
    await _pumpEvents();
    final first = await service.applyNodes([_node('甲-直连')]);
    expect(first.ok, isTrue);
    plugin.emit(const ProxyStarted());
    await _pumpEvents();

    plugin.throwOnReload = true;
    final ok = await container
        .read(routingModeProvider.notifier)
        .setMode(RoutingMode.global);
    expect(ok, isFalse);
    expect(container.read(routingModeProvider).mode, RoutingMode.rule);
    // 磁盘配置已回滚成规则模式那份（final 是 direct，不是 Proxy）。
    final decoded = jsonDecode(await readConfig()) as Map<String, dynamic>;
    expect((decoded['route'] as Map)['final'], 'direct');
  });

  test('启动时读回持久化的模式（上次切到全局）', () async {
    SharedPreferences.setMockInitialValues({'proxy_mode': 'global'});
    final container = makeContainer(nodes: [_node('甲-直连')]);
    addTearDown(container.dispose);
    // 先读一次触发 build（读持久化是 build 里排的异步任务），
    // 再等它读回来覆盖默认值。
    expect(container.read(routingModeProvider).mode, RoutingMode.rule);
    await _pumpEvents();
    expect(container.read(routingModeProvider).mode, RoutingMode.global);
  });

  test('持久化值非法时回落规则模式', () async {
    SharedPreferences.setMockInitialValues({'proxy_mode': 'bogus'});
    final container = makeContainer(nodes: [_node('甲-直连')]);
    addTearDown(container.dispose);
    expect(container.read(routingModeProvider).mode, RoutingMode.rule);
    await _pumpEvents();
    expect(container.read(routingModeProvider).mode, RoutingMode.rule);
  });
}
