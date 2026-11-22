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

SubscriptionUserinfo _info() {
  final expire = DateTime.now().add(const Duration(days: 45));
  return SubscriptionUserinfo(
    upload: 100 * 1024 * 1024,
    download: 200 * 1024 * 1024,
    total: 1024 * 1024 * 1024,
    expire: expire.millisecondsSinceEpoch ~/ 1000,
  );
}

Future<_StubNodesNotifier> _pumpPage(
  WidgetTester tester,
  NodesState state, {
  String? notice,
  String? bindError,
  bool bound = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final stub = _StubNodesNotifier(state, bindError: bindError);
  final autoRefresh = _FakeAutoRefresh();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        nodesProvider.overrideWith(() => stub),
        announcementServiceProvider
            .overrideWithValue(_FakeAnnouncementService(notice)),
        subscriptionAutoRefreshProvider.overrideWithValue(autoRefresh),
        subscriptionServiceProvider
            .overrideWithValue(_FakeSubscriptionService(bound: bound)),
      ],
      child: const MaterialApp(home: Scaffold(body: MePage())),
    ),
  );
  await tester.pumpAndSettle();
  return stub;
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
    expect(find.text('暂无公告'), findsOneWidget);
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
    expect(find.text('流量口径：仅中转（直连流量不计入）'), findsOneWidget);
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
    expect(stub.calls, contains('refresh'));
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

  testWidgets('公告：有公告显示公告，没有显示“暂无公告”', (tester) async {
    await _pumpPage(
      tester,
      const NodesState(status: NodesStatus.loaded),
      notice: '面板今晚维护',
    );
    expect(find.text('面板今晚维护'), findsOneWidget);
    expect(find.text('暂无公告'), findsNothing);
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
    expect(stub.calls.first, startsWith('bind:https://example.com/'));
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
    expect(stub.calls, contains('clear'));
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
    expect(stub.calls, isNot(contains('clear')));
  });
}
