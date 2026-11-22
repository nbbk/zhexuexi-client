// 切片 5：订阅自动更新测试（每天一次，仅 Wi-Fi）。
//
// 不碰真网络：SharedPreferences 用 mock，Wi-Fi 用注入的假函数，
// 时钟可拨；刷新本身是注入的假函数，成功与否由调用方判定。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/services/subscription_auto_refresh.dart';

void main() {
  const lastKey = 'subscription_last_refresh_at_ms';
  final now = DateTime(2026, 11, 23, 8, 0, 0);

  Future<SubscriptionAutoRefresh> make({
    Map<String, Object> prefs = const {},
    bool wifi = true,
    DateTime? clock,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();
    return SubscriptionAutoRefresh(
      prefs: sp,
      isWifi: () async => wifi,
      clock: () => clock ?? now,
    );
  }

  test('超过 24 小时 + Wi-Fi + 已绑定：拉一次，记时间', () async {
    var refreshed = 0;
    final service = await make(
      prefs: {
        lastKey: now.millisecondsSinceEpoch -
            const Duration(hours: 25).inMilliseconds,
      },
    );
    final did = await service.maybeRefresh(
      refresh: () async => refreshed++,
      didSucceed: () => true,
      hasBinding: true,
    );
    expect(did, isTrue);
    expect(refreshed, 1);
    // 记了时间：紧接着再调一次就不拉了。
    final again = await service.maybeRefresh(
      refresh: () async => refreshed++,
      didSucceed: () => true,
      hasBinding: true,
    );
    expect(again, isFalse);
    expect(refreshed, 1);
  });

  test('不到 24 小时：不拉', () async {
    var refreshed = 0;
    final service = await make(
      prefs: {
        lastKey: now.millisecondsSinceEpoch -
            const Duration(hours: 23).inMilliseconds,
      },
    );
    final did = await service.maybeRefresh(
      refresh: () async => refreshed++,
      didSucceed: () => true,
      hasBinding: true,
    );
    expect(did, isFalse);
    expect(refreshed, 0);
  });

  test('不在 Wi-Fi 下：不拉', () async {
    var refreshed = 0;
    final service = await make(wifi: false);
    final did = await service.maybeRefresh(
      refresh: () async => refreshed++,
      didSucceed: () => true,
      hasBinding: true,
    );
    expect(did, isFalse);
    expect(refreshed, 0);
  });

  test('未绑定订阅：不拉', () async {
    var refreshed = 0;
    final service = await make();
    final did = await service.maybeRefresh(
      refresh: () async => refreshed++,
      didSucceed: () => true,
      hasBinding: false,
    );
    expect(did, isFalse);
    expect(refreshed, 0);
  });

  test('刷新失败：不记时间，下次条件满足时再试', () async {
    var refreshed = 0;
    final service = await make();
    final did = await service.maybeRefresh(
      refresh: () async => refreshed++,
      didSucceed: () => false,
      hasBinding: true,
    );
    expect(did, isFalse);
    expect(refreshed, 1);
    // 没记时间：再调一次还会拉。
    final again = await service.maybeRefresh(
      refresh: () async => refreshed++,
      didSucceed: () => true,
      hasBinding: true,
    );
    expect(again, isTrue);
    expect(refreshed, 2);
  });

  test('markRefreshed 后 24 小时内不自动拉', () async {
    var refreshed = 0;
    final service = await make();
    await service.markRefreshed();
    final did = await service.maybeRefresh(
      refresh: () async => refreshed++,
      didSucceed: () => true,
      hasBinding: true,
    );
    expect(did, isFalse);
    expect(refreshed, 0);
  });

  test('正好 24 小时：拉', () async {
    var refreshed = 0;
    final service = await make(
      prefs: {
        lastKey: now.millisecondsSinceEpoch -
            const Duration(hours: 24).inMilliseconds,
      },
    );
    final did = await service.maybeRefresh(
      refresh: () async => refreshed++,
      didSucceed: () => true,
      hasBinding: true,
    );
    expect(did, isTrue);
    expect(refreshed, 1);
  });
}
