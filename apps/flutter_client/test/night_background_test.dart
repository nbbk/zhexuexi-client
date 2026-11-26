// 0.1.2：第 5 条夜晚模式背景统一的回归测试。
//
// 四页（首页、我的、设置、登录）夜晚都要包 GlassBackground、
// 渐变三色一致；我的页 7 张 GlassCard、无原生 Card；
// 卡片夜晚填色白 8%；白天回落象牙白渐变。
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sing_box/flutter_sing_box.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/brand/brand_config.dart';
import 'package:zhexuexi_client/brand/remote_config.dart';
import 'package:zhexuexi_client/core/app_theme.dart';
import 'package:zhexuexi_client/core/clash_api_client.dart';
import 'package:zhexuexi_client/core/config_validator.dart';
import 'package:zhexuexi_client/core/core_provider.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/singbox_core.dart';
import 'package:zhexuexi_client/features/auth/login_page.dart';
import 'package:zhexuexi_client/features/home/home_page.dart';
import 'package:zhexuexi_client/features/me/me_page.dart';
import 'package:zhexuexi_client/features/settings/settings_page.dart';
import 'package:zhexuexi_client/services/announcement_service.dart';
import 'package:zhexuexi_client/services/auth_notifier.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/remote_config_notifier.dart';
import 'package:zhexuexi_client/services/subscription_auto_refresh.dart';
import 'package:zhexuexi_client/services/subscription_service.dart';
import 'package:zhexuexi_client/widgets/glass_card.dart';

class _FakePlugin extends FlutterSingBox {
  final _stateController = StreamController<ProxyState>.broadcast();

  @override
  Stream<ProxyState> get proxyStateStream => _stateController.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> startVpn() async =>
      _stateController.add(const ProxyStarted());

  @override
  Future<void> stopVpn() async =>
      _stateController.add(const ProxyStopped());

  @override
  Future<void> serviceReload() async =>
      _stateController.add(const ProxyStarted());

  @override
  Future<String> getSingBoxVersion() async => '1.14.4';

  Future<void> close() => _stateController.close();
}

class _FakeValidator implements ConfigValidator {
  @override
  Future<List<String>> validate(Map<String, dynamic> config) async => [];
}

class _FakeClashApi extends ClashApiClient {
  @override
  Future<TrafficSample> trafficSample({
    Duration timeout = const Duration(seconds: 5),
  }) async => const TrafficSample(up: 0, down: 0);
}

class _StubNodesNotifier extends NodesNotifier {
  _StubNodesNotifier({required this.nodes});

  final List<Node> nodes;

  @override
  NodesState build() => NodesState(
    nodes: nodes,
    status: NodesStatus.loaded,
  );
}

Node _node(String name) => Node(
  name: name,
  protocol: NodeProtocol.vless,
  address: '203.0.113.1',
  port: 443,
  uuidOrPassword: '11111111-2222-3333-4444-555555555555',
  tls: true,
  sni: 'example.com',
  source: NodeSource.direct,
);

class _StubRemoteConfigNotifier extends RemoteConfigNotifier {
  @override
  RemoteConfigState build() => RemoteConfigState(
    config: RemoteConfig(
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
    ),
    source: RemoteConfigSource.fresh,
  );
}

class _StubAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthState();

  @override
  Future<void> restore() async {}

  @override
  Future<String> defaultPanelDomain() async => 'ccpanel.jiankong.cf';

  @override
  Future<void> logout() async {
    state = const AuthState();
  }
}

class _FakeAnnouncementService extends AnnouncementService {
  _FakeAnnouncementService(this.notice);

  final String? notice;

  @override
  Future<String?> fetchNotice() async => notice;

  @override
  Future<List<Announcement>> fetchAnnouncements() async => notice == null
      ? const []
      : [
          Announcement(
            id: 'test-1',
            title: '',
            body: notice!,
            createdAt: DateTime(2026, 11, 26, 9),
          ),
        ];
}

class _FakeAutoRefresh extends SubscriptionAutoRefresh {
  @override
  Future<bool> maybeRefresh({
    required Future<void> Function() refresh,
    required bool Function() didSucceed,
    required bool hasBinding,
  }) async => false;

  @override
  Future<void> markRefreshed() async {}
}

class _FakeSubscriptionService extends SubscriptionService {
  @override
  Future<bool> hasBinding() async => true;

  @override
  Future<String?> readSubscriptionUrl() async =>
      'https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
}

/// GlassBackground 根 Container 的渐变色列表。
List<Color> _backgroundGradient(WidgetTester tester) {
  final container = tester.widget<Container>(
    find
        .descendant(
          of: find.byType(GlassBackground),
          matching: find.byType(Container),
        )
        .first,
  );
  final decoration = container.decoration as BoxDecoration;
  final gradient = decoration.gradient as LinearGradient;
  return gradient.colors;
}

/// 任意 GlassCard 的内层填色是不是夜晚白 8%。
bool _hasNightCardFill(WidgetTester tester) {
  for (final container in tester.widgetList<Container>(
    find.byType(Container),
  )) {
    final decoration = container.decoration;
    if (decoration is BoxDecoration &&
        decoration.color == Colors.white.withValues(alpha: 0.08)) {
      return true;
    }
  }
  return false;
}

void main() {
  late Directory tmpDir;
  late String configPath;
  late _FakePlugin plugin;
  late CoreService service;
  late String closedApiBaseUrl;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('night-bg-test-');
    configPath = '${tmpDir.path}/using_config.json';
    plugin = _FakePlugin();
    service = CoreService(
      plugin: plugin,
      validator: _FakeValidator(),
      usingConfigPath: () async => configPath,
      ensureSelectedProfile: (_) async {},
      clashApiClient: _FakeClashApi(),
    );
    await service.init();
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    closedApiBaseUrl = 'http://127.0.0.1:${probe.port}';
    await probe.close();
  });

  tearDown(() async {
    service.dispose();
    await plugin.close();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  Future<void> pumpNight(
    WidgetTester tester,
    Widget page, {
    List<Override> overrides = const [],
    Size viewSize = const Size(800, 1600),
    AppThemeDefinition theme = AppThemes.night,
  }) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: theme.themeData,
          home: Scaffold(body: page),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<Override> coreOverrides() => [
    coreServiceProvider.overrideWithValue(service),
    nodesProvider.overrideWith(
      () => _StubNodesNotifier(nodes: [_node('甲-直连')]),
    ),
    clashApiClientProvider.overrideWithValue(
      ClashApiClient(baseUrl: closedApiBaseUrl),
    ),
    remoteConfigProvider.overrideWith(() => _StubRemoteConfigNotifier()),
    announcementsProvider.overrideWith((ref) async => []),
  ];

  testWidgets('夜晚：首页包 GlassBackground，渐变三色是夜晚 token', (
    tester,
  ) async {
    await pumpNight(
      tester,
      HomePage(onGoToMe: () {}),
      overrides: coreOverrides(),
    );
    expect(find.byType(GlassBackground), findsOneWidget);
    expect(
      _backgroundGradient(tester),
      AppThemes.night.tokens.backgroundGradient,
    );
  });

  testWidgets('夜晚：我的页 7 张 GlassCard、无原生 Card、渐变一致', (
    tester,
  ) async {
    await pumpNight(
      tester,
      const MePage(),
      viewSize: const Size(800, 3000),
      overrides: [
        nodesProvider.overrideWith(
          () => _StubNodesNotifier(nodes: [_node('甲-直连')]),
        ),
        announcementServiceProvider.overrideWithValue(
          _FakeAnnouncementService('面板今晚维护'),
        ),
        subscriptionAutoRefreshProvider.overrideWithValue(_FakeAutoRefresh()),
        subscriptionServiceProvider.overrideWithValue(
          _FakeSubscriptionService(),
        ),
        authProvider.overrideWith(() => _StubAuthNotifier()),
      ],
    );
    expect(find.byType(GlassBackground), findsOneWidget);
    expect(
      _backgroundGradient(tester),
      AppThemes.night.tokens.backgroundGradient,
    );
    expect(find.byType(GlassCard), findsNWidgets(7));
    expect(find.byType(Card), findsNothing);
    expect(_hasNightCardFill(tester), isTrue);
  });

  testWidgets('夜晚：设置页包 GlassBackground，渐变一致', (tester) async {
    await pumpNight(
      tester,
      const SettingsPage(),
      viewSize: const Size(800, 3000),
      overrides: coreOverrides(),
    );
    expect(find.byType(GlassBackground), findsOneWidget);
    expect(
      _backgroundGradient(tester),
      AppThemes.night.tokens.backgroundGradient,
    );
  });

  testWidgets('夜晚：登录页包 GlassBackground，渐变一致', (tester) async {
    await pumpNight(
      tester,
      const LoginPage(),
      overrides: [
        authProvider.overrideWith(() => _StubAuthNotifier()),
      ],
    );
    expect(find.byType(GlassBackground), findsOneWidget);
    expect(
      _backgroundGradient(tester),
      AppThemes.night.tokens.backgroundGradient,
    );
  });

  testWidgets('白天：我的页回归象牙白渐变，不再是夜晚三色', (tester) async {
    await pumpNight(
      tester,
      const MePage(),
      viewSize: const Size(800, 3000),
      theme: AppThemes.day,
      overrides: [
        nodesProvider.overrideWith(
          () => _StubNodesNotifier(nodes: [_node('甲-直连')]),
        ),
        announcementServiceProvider.overrideWithValue(
          _FakeAnnouncementService('面板今晚维护'),
        ),
        subscriptionAutoRefreshProvider.overrideWithValue(_FakeAutoRefresh()),
        subscriptionServiceProvider.overrideWithValue(
          _FakeSubscriptionService(),
        ),
        authProvider.overrideWith(() => _StubAuthNotifier()),
      ],
    );
    expect(find.byType(GlassBackground), findsOneWidget);
    expect(
      _backgroundGradient(tester),
      AppThemes.day.tokens.backgroundGradient,
    );
    expect(_hasNightCardFill(tester), isFalse);
  });
}
