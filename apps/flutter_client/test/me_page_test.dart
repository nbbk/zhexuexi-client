// 切片 5：我的页 widget 测试（账号区、订阅大字、手动刷新、公告、
// 换绑、退出登录）。
//
// 不碰真面板：nodesProvider 用桩 notifier 覆盖，公告与自动更新用
// fake 服务覆盖；订阅地址用假服务给定。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/core/userinfo.dart';
import 'package:zhexuexi_client/features/me/me_page.dart';
import 'package:zhexuexi_client/services/announcement_service.dart';
import 'package:zhexuexi_client/services/auth_notifier.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/subscription_auto_refresh.dart';
import 'package:zhexuexi_client/services/subscription_service.dart';

class _StubNodesNotifier extends NodesNotifier {
  _StubNodesNotifier(this._state, {this.bindError});

  NodesState _state;

  /// 绑定失败时要报的原因；为 null 时绑定成功。
  final String? bindError;
  final calls = <String>[];

  @override
  NodesState build() => _state;

  @override
  Future<void> refresh() async {
    calls.add('refresh');
  }

  @override
  Future<void> bindAndRefresh(String link) async {
    calls.add('bind:$link');
    if (bindError != null) {
      _state = _state.copyWith(
        status: NodesStatus.error,
        errorMessage: bindError,
      );
    } else {
      // 桩：绑定成功后状态变 loaded（真实 notifier 会拉订阅），
      // 让页面从“未绑定”切到“已绑定”。
      _state = const NodesState(status: NodesStatus.loaded);
    }
    // 桩直接改状态：测试里用 state setter 同步给 notifier。
    state = _state;
  }

  @override
  Future<void> clear() async {
    calls.add('clear');
    _state = const NodesState();
    state = _state;
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
  int maybeCalls = 0;
  int markCalls = 0;

  @override
  Future<bool> maybeRefresh({
    required Future<void> Function() refresh,
    required bool Function() didSucceed,
    required bool hasBinding,
  }) async {
    maybeCalls++;
    return false;
  }

  @override
  Future<void> markRefreshed() async {
    markCalls++;
  }
}

class _FakeSubscriptionService extends SubscriptionService {
  _FakeSubscriptionService({this.bound = true});

  final bool bound;

  @override
  Future<bool> hasBinding() async => bound;

  @override
  Future<String?> readSubscriptionUrl() async => bound
      ? 'https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
      : null;
}

/// 切片 9：账号登录桩（我的页只调 restore/logout，登录页调
/// defaultPanelDomain；登录本身在 login_page_test 里测）。
class _StubAuthNotifier extends AuthNotifier {
  _StubAuthNotifier({this.initialUsername, this.initialPlanName});

  final String? initialUsername;
  final String? initialPlanName;
  final calls = <String>[];

  @override
  AuthState build() =>
      AuthState(username: initialUsername, planName: initialPlanName);

  @override
  Future<void> restore() async {}

  @override
  Future<String> defaultPanelDomain() async => 'ccpanel.jiankong.cf';

  @override
  Future<void> logout() async {
    calls.add('logout');
    state = const AuthState();
  }
}

SubscriptionUserinfo _info() {
  final expire = DateTime.now().add(const Duration(days: 45));
  return SubscriptionUserinfo(
    upload: 100 * 1024 * 1024,
    download: 200 * 1024 * 1024,
    total: 1024 * 1024 * 1024,
    expire: expire.millisecondsSinceEpoch ~/ 1000,
  );
}

SubscriptionUserinfo _limitedInfo({required int usedMB, int totalMB = 1024}) {
  final expire = DateTime.now().add(const Duration(days: 45));
  return SubscriptionUserinfo(
    upload: usedMB * 1024 * 1024,
    download: 0,
    total: totalMB * 1024 * 1024,
    expire: expire.millisecondsSinceEpoch ~/ 1000,
  );
}

Future<({_StubNodesNotifier nodes, _StubAuthNotifier auth})> _pumpPage(
  WidgetTester tester,
  NodesState state, {
  String? notice,
  String? bindError,
  bool bound = true,
  String? authUsername,
  String? authPlanName,
}) async {
  SharedPreferences.setMockInitialValues({});
  final stub = _StubNodesNotifier(state, bindError: bindError);
  final autoRefresh = _FakeAutoRefresh();
  final authStub = _StubAuthNotifier(
    initialUsername: authUsername,
    initialPlanName: authPlanName,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        nodesProvider.overrideWith(() => stub),
        announcementServiceProvider
            .overrideWithValue(_FakeAnnouncementService(notice)),
        subscriptionAutoRefreshProvider.overrideWithValue(autoRefresh),
        subscriptionServiceProvider
            .overrideWithValue(_FakeSubscriptionService(bound: bound)),
        authProvider.overrideWith(() => authStub),
      ],
      child: const MaterialApp(home: Scaffold(body: MePage())),
    ),
  );
  await tester.pumpAndSettle();
  return (nodes: stub, auth: authStub);
}

void main() {
  testWidgets('未绑定：账号区、订阅卡片与绑定入口', (tester) async {
    await _pumpPage(
      tester,
      const NodesState(status: NodesStatus.initial),
      bound: false,
    );
    expect(find.text('未登录（免登录模式）'), findsOneWidget);
    expect(find.text('未绑定订阅'), findsOneWidget);
    expect(find.text('绑定订阅'), findsOneWidget);
    expect(find.text('上次更新：尚未更新'), findsOneWidget);
    // 没有公告时公告卡整个不渲染（0.1.2 隐藏规则）。
    expect(find.text('公告'), findsNothing);
  });

  testWidgets('已绑定有流量：剩余流量大字 + 已用/总量 + 到期日', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        status: NodesStatus.loaded,
        userinfo: _info(),
        lastUpdated: DateTime(2026, 11, 23, 8, 30),
      ),
    );
    expect(find.text('已绑定订阅'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('724 MB'), findsOneWidget);
    expect(find.text('已用 / 总量：300 MB / 1 GB'), findsOneWidget);
    expect(find.textContaining('（剩'), findsOneWidget);
    expect(find.text('上次更新：2026-11-23 08:30'), findsOneWidget);
    expect(find.text('限流按全部节点流量算'), findsOneWidget);
  });

  testWidgets('已绑定有档位：订阅卡片显示套餐名（0.1.12）', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        status: NodesStatus.loaded,
        userinfo: _info(),
        lastUpdated: DateTime(2026, 11, 23, 8, 30),
      ),
      authUsername: 'nianba',
      authPlanName: '标准版',
    );
    expect(find.text('套餐：标准版'), findsOneWidget);
  });

  testWidgets('已绑定无档位：不显示套餐行，不留占位（0.1.12）', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        status: NodesStatus.loaded,
        userinfo: _info(),
        lastUpdated: DateTime(2026, 11, 23, 8, 30),
      ),
      authUsername: 'nianba',
    );
    expect(find.textContaining('套餐：'), findsNothing);
  });

  testWidgets('无 userinfo 头：三格显示“—”不编数据', (tester) async {
    await _pumpPage(
      tester,
      const NodesState(status: NodesStatus.loaded),
    );
    expect(find.text('—'), findsOneWidget);
    expect(find.text('已用 / 总量：—'), findsOneWidget);
    expect(find.text('到期日：—'), findsOneWidget);
  });

  testWidgets('点刷新订阅：调 notifier.refresh', (tester) async {
    final stub = await _pumpPage(
      tester,
      NodesState(status: NodesStatus.loaded, userinfo: _info()),
    );
    await tester.tap(find.text('刷新订阅'));
    await tester.pumpAndSettle();
    expect(stub.nodes.calls, contains('refresh'));
  });

  testWidgets('更新失败：原因常驻显示', (tester) async {
    await _pumpPage(
      tester,
      const NodesState(
        status: NodesStatus.error,
        errorMessage: '订阅已失效，请重新绑定',
      ),
    );
    expect(find.text('更新失败：订阅已失效，请重新绑定'), findsOneWidget);
  });

  testWidgets('公告：有公告显示“共 N 条，点击查看”，点进列表页', (tester) async {
    await _pumpPage(
      tester,
      const NodesState(status: NodesStatus.loaded),
      notice: '面板今晚维护',
    );
    // 公告卡在 ListView 下方（切片 9 加了登录入口卡片后更靠下），
    // 视口外不构建，先滚到可见再断言。
    await tester.scrollUntilVisible(find.text('公告'), 200.0);
    await tester.pumpAndSettle();
    expect(find.text('共 1 条，点击查看'), findsOneWidget);
    await tester.tap(find.text('公告'));
    await tester.pumpAndSettle();
    // 列表页里有这条：标题为空时行标题取正文首行，
    // 所以同一串字出现两次（行标题＋正文全文）。
    expect(find.text('面板今晚维护'), findsWidgets);
  });

  testWidgets('公告：没有公告时公告卡不存在', (tester) async {
    await _pumpPage(
      tester,
      const NodesState(status: NodesStatus.loaded),
    );
    expect(find.text('公告'), findsNothing);
    expect(find.text('共 1 条，点击查看'), findsNothing);
  });

  testWidgets('绑定订阅：粘贴链接后调 bindAndRefresh，成功关弹窗', (tester) async {
    final stub = await _pumpPage(
      tester,
      const NodesState(status: NodesStatus.initial),
      bound: false,
    );
    await tester.tap(find.text('绑定订阅'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://example.com/x9f2/sub_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );
    await tester.tap(find.text('绑定'));
    await tester.pumpAndSettle();
    expect(stub.nodes.calls.first, startsWith('bind:https://example.com/'));
    expect(find.text('绑定订阅'), findsNothing);
  });

  testWidgets('换绑失败：原因显示在弹窗里，弹窗不关', (tester) async {
    await _pumpPage(
      tester,
      NodesState(status: NodesStatus.loaded, userinfo: _info()),
      bindError: '订阅链接不对，令牌应以 sub_ 开头',
    );
    await tester.scrollUntilVisible(find.text('换绑订阅'), 200.0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('换绑订阅'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com/bad');
    await tester.tap(find.text('绑定'));
    await tester.pumpAndSettle();
    expect(find.text('订阅链接不对，令牌应以 sub_ 开头'), findsOneWidget);
    // 弹窗还在：标题还在。
    expect(find.text('换绑订阅'), findsWidgets);
  });

  testWidgets('退出登录：点确认后调 clear', (tester) async {
    final stub = await _pumpPage(
      tester,
      NodesState(status: NodesStatus.loaded, userinfo: _info()),
    );
    await tester.scrollUntilVisible(find.text('退出登录'), 200.0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(stub.nodes.calls, contains('clear'));
  });

  testWidgets('退出登录：点取消不清', (tester) async {
    final stub = await _pumpPage(
      tester,
      NodesState(status: NodesStatus.loaded, userinfo: _info()),
    );
    await tester.scrollUntilVisible(find.text('退出登录'), 200.0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(stub.nodes.calls, isNot(contains('clear')));
  });

  // 切片 8：限流展示（进度条 + 状态文案），只按 userinfo 头算。
  testWidgets('已用 85%：进度条 + 接近限额提示', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        status: NodesStatus.loaded,
        userinfo: _limitedInfo(usedMB: 870),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      find.text('已用 85%，接近限额，超量后节点可能停用'),
      findsOneWidget,
    );
  });

  testWidgets('已超量：超量提示，不写成“已停用”定论', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        status: NodesStatus.loaded,
        userinfo: _limitedInfo(usedMB: 1100),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      find.text('已超量：面板可能已停用该订阅，节点连不上时请联系管理员'),
      findsOneWidget,
    );
  });

  testWidgets('不限量：不显示进度条与限流提示', (tester) async {
    await _pumpPage(
      tester,
      NodesState(
        status: NodesStatus.loaded,
        userinfo: _limitedInfo(usedMB: 100, totalMB: 0),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('接近限额'), findsNothing);
    expect(find.textContaining('已超量'), findsNothing);
  });

  testWidgets('无 userinfo 头：不显示进度条与限流提示', (tester) async {
    await _pumpPage(
      tester,
      const NodesState(status: NodesStatus.loaded),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('接近限额'), findsNothing);
    expect(find.textContaining('已超量'), findsNothing);
  });

  // 切片 9：账号密码登录接线（DEV-PLAN §10.2）。
  testWidgets('未登录：显示账号登录入口，点进去是登录页', (tester) async {
    await _pumpPage(
      tester,
      NodesState(status: NodesStatus.loaded, userinfo: _info()),
    );
    expect(find.text('账号登录'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('账号登录'), 200.0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('账号登录'));
    await tester.pumpAndSettle();
    expect(find.text('面板域名'), findsOneWidget);
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
  });

  testWidgets('已登录：账号区显示账号名，登录入口消失', (tester) async {
    await _pumpPage(
      tester,
      NodesState(status: NodesStatus.loaded, userinfo: _info()),
      authUsername: 'nianba',
    );
    expect(find.text('已登录：nianba'), findsOneWidget);
    // 登录入口卡片消失（副标题“用面板账号登录…”只在入口卡片上有；
    // 账号区副标题也是“账号登录”四个字，不能拿它断言入口消失）。
    expect(find.text('用面板账号登录，换设备不用重新导链接'), findsNothing);
    // 退出登录卡在列表底部，视口外不构建，先滚到可见再断言。
    await tester.scrollUntilVisible(find.text('退出登录'), 200.0);
    await tester.pumpAndSettle();
    expect(
      find.text('只清除本地登录会话，订阅与节点不受影响'),
      findsOneWidget,
    );
  });

  testWidgets('已登录退出：只清会话不清订阅', (tester) async {
    final pumped = await _pumpPage(
      tester,
      NodesState(status: NodesStatus.loaded, userinfo: _info()),
      authUsername: 'nianba',
    );
    await tester.scrollUntilVisible(find.text('退出登录'), 200.0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(pumped.auth.calls, contains('logout'));
    expect(pumped.nodes.calls, isNot(contains('clear')));
    expect(find.text('已退出登录，订阅不受影响'), findsOneWidget);
  });

  testWidgets('未登录退出：仍是清绑定', (tester) async {
    final pumped = await _pumpPage(
      tester,
      NodesState(status: NodesStatus.loaded, userinfo: _info()),
    );
    await tester.scrollUntilVisible(find.text('退出登录'), 200.0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(pumped.auth.calls, isNot(contains('logout')));
    expect(pumped.nodes.calls, contains('clear'));
  });
}
