// 0.1.14：分应用代理（Android 专属，白名单语义）的回归测试。
//
// 语义只做一种：关闭 = 全部应用走代理；开启 = 仅选中应用走代理。
// 选择存 MMKV（与原生 VPNService.openTun 读的是同一份），
// 改完核心在跑时须重启核心才生效，页面给“立即重启”操作。
// 不碰真机：应用列表走 MethodChannel mock，核心走 fake 插件。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sing_box/flutter_sing_box.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/clash_api_client.dart';
import 'package:zhexuexi_client/core/config_validator.dart';
import 'package:zhexuexi_client/core/core_provider.dart';
import 'package:zhexuexi_client/core/singbox_core.dart';
import 'package:zhexuexi_client/features/per_app_proxy/per_app_proxy_page.dart';
import 'package:zhexuexi_client/services/per_app_proxy_notifier.dart';

/// 1x1 透明 PNG（mock 的应用图标字节，须是合法图片数据）。
final _fakeIcon = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const _appsChannel = MethodChannel('com.zhexuexi.client/installed_apps');

List<Map<String, Object>> _fakeApps() => [
  {
    'packageName': 'com.tencent.mm',
    'label': '微信',
    'icon': _fakeIcon,
  },
  {'packageName': 'com.google.android.youtube', 'label': 'YouTube'},
  {'packageName': 'com.example.app', 'label': '示例应用'},
];

/// 插件 fake：只记 start/stop 调用、推状态，不碰平台通道。
class _FakePlugin extends FlutterSingBox {
  final _stateController = StreamController<ProxyState>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Stream<ProxyState> get proxyStateStream => _stateController.stream;

  @override
  Stream<List<ClientLog>> get logStream => Stream<List<ClientLog>>.empty();

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
  Future<String> getSingBoxVersion() async => '1.14.4';

  void emit(ProxyState state) => _stateController.add(state);

  Future<void> close() => _stateController.close();
}

class _FakeClashApi extends ClashApiClient {
  @override
  Future<TrafficSample> trafficSample({
    Duration timeout = const Duration(seconds: 5),
  }) async => const TrafficSample(up: 0, down: 0);
}

class _FakeValidator implements ConfigValidator {
  @override
  Future<List<String>> validate(Map<String, dynamic> config) async => [];
}

void main() {
  group('PerAppProxyNotifier', () {
    setUp(() {
      CsSettingsStorage.mockInit();
    });

    test('默认关闭、列表为空', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(perAppProxyProvider);
      expect(state.enabled, isFalse);
      expect(state.selected, isEmpty);
    });

    test('空表时开开关失败、不改状态', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(perAppProxyProvider.notifier);
      expect(notifier.setEnabled(true), isFalse);
      expect(container.read(perAppProxyProvider).enabled, isFalse);
    });

    test('选应用后开开关成功；关后列表保留、重开恢复', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(perAppProxyProvider.notifier);
      notifier.togglePackage('com.tencent.mm');
      notifier.togglePackage('com.google.android.youtube');
      expect(notifier.setEnabled(true), isTrue);
      expect(container.read(perAppProxyProvider).enabled, isTrue);
      // 持久化：新容器读回同一份 MMKV（mock 是进程内单例）。
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      expect(container2.read(perAppProxyProvider).enabled, isTrue);
      expect(
        container2.read(perAppProxyProvider).selected,
        {'com.tencent.mm', 'com.google.android.youtube'},
      );
      // 关后列表保留。
      container2.read(perAppProxyProvider.notifier).setEnabled(false);
      expect(container2.read(perAppProxyProvider).enabled, isFalse);
      expect(
        container2.read(perAppProxyProvider).selected,
        {'com.tencent.mm', 'com.google.android.youtube'},
      );
      // 重开恢复，不用重新勾选。
      expect(
        container2.read(perAppProxyProvider.notifier).setEnabled(true),
        isTrue,
      );
      expect(container2.read(perAppProxyProvider).enabled, isTrue);
    });

    test('取消勾选即从列表移除', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(perAppProxyProvider.notifier);
      notifier.togglePackage('com.tencent.mm');
      notifier.togglePackage('com.tencent.mm');
      expect(container.read(perAppProxyProvider).selected, isEmpty);
    });
  });

  group('PerAppProxyPage', () {
    late Directory tmpDir;
    late String configPath;
    late _FakePlugin plugin;
    late CoreService service;

    setUp(() async {
      CsSettingsStorage.mockInit();
      SharedPreferences.setMockInitialValues({});
      tmpDir = await Directory.systemTemp.createTemp('per-app-proxy-test-');
      configPath = '${tmpDir.path}/using_config.json';
      // 核心 start() 要求已有配置：先写一份假配置，init 时读进内存。
      await File(configPath).writeAsString('{}');
      plugin = _FakePlugin();
      service = CoreService(
        plugin: plugin,
        validator: _FakeValidator(),
        usingConfigPath: () async => configPath,
        ensureSelectedProfile: (_) async {},
        clashApiClient: _FakeClashApi(),
      );
      await service.init();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_appsChannel, (call) async {
            if (call.method == 'getLaunchableApps') return _fakeApps();
            return null;
          });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_appsChannel, null);
      service.dispose();
      await plugin.close();
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [coreServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: PerAppProxyPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('列出应用（图标＋名称＋包名），搜索过滤', (tester) async {
      await pumpPage(tester);
      // 行内文本用 ListView 后代找：搜“微信”后搜索框里也有“微信”二字，
      // find.text 会撞上两个。
      Finder appRow(String label) => find.descendant(
        of: find.byType(ListView),
        matching: find.text(label),
      );
      expect(appRow('微信'), findsOneWidget);
      expect(find.text('com.tencent.mm'), findsOneWidget);
      expect(appRow('YouTube'), findsOneWidget);
      expect(appRow('示例应用'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '微信');
      await tester.pump();
      expect(appRow('微信'), findsOneWidget);
      expect(appRow('YouTube'), findsNothing);
      expect(appRow('示例应用'), findsNothing);
    });

    testWidgets('空表时开开关只提示、不开', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('仅选中应用走代理'));
      await tester.pump();
      expect(
        find.text('先选至少一个应用，再开启分应用代理'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SwitchListTile>(find.byType(SwitchListTile))
            .value,
        isFalse,
      );
    });

    testWidgets('勾选后核心没跑：提示下次启动生效，无重启按钮', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('微信'));
      await tester.pump();
      expect(find.text('下次启动核心时生效'), findsOneWidget);
      expect(find.text('立即重启'), findsNothing);
      // 选择已持久化（MMKV）。
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(perAppProxyProvider).selected,
        contains('com.tencent.mm'),
      );
    });

    testWidgets('核心在跑：改完提示重启核心，点立即重启后停再起、横条消失', (
      tester,
    ) async {
      await pumpPage(tester);
      plugin.emit(const ProxyStarted());
      await tester.pump();
      expect(service.status, CoreStatus.started);

      await tester.tap(find.text('微信'));
      await tester.pump();
      expect(find.text('改动在重启核心后生效'), findsOneWidget);
      expect(find.text('立即重启'), findsOneWidget);

      await tester.tap(find.text('立即重启'));
      await tester.pumpAndSettle();
      expect(plugin.stopCalls, 1);
      expect(plugin.startCalls, 1);
      expect(service.status, CoreStatus.started);
      expect(find.text('改动在重启核心后生效'), findsNothing);
      expect(find.text('核心已重启，分应用代理已生效'), findsOneWidget);
    });
  });
}
