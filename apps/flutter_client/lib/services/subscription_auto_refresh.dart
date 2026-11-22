import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nodes_notifier.dart';

/// 订阅自动更新（切片 5：每天自动更新一次，仅 Wi-Fi 下）。
///
/// 规则（DEV-PLAN §4.3 1-7）：
/// - 上次成功更新不到 24 小时，不拉；
/// - 不在 Wi-Fi 下（流量 / 无网），不拉；
/// - 未绑定订阅，不拉；
/// - 手动刷新成功也算一次（调用 [markRefreshed] 记时间），
///   不会刚手动刷完又自动刷一遍。
///
/// 上次成功时间存在 shared_preferences（`subscription_last_refresh_at_ms`），
/// 重启 App 也认，不会每次启动都拉一次。调用方在 App 启动与我的页打开时
/// 各调一次 [maybeAutoRefresh]（幂等，重复调只拉一次）；
/// 拉取本身复用 [NodesNotifier.refresh]，不另起一套拉取逻辑。
class SubscriptionAutoRefresh {
  SubscriptionAutoRefresh({
    this._prefs,
    this._isWifi,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SharedPreferences? _prefs;
  final Future<bool> Function()? _isWifi;
  final DateTime Function() _clock;

  /// 两次自动更新的最短间隔：24 小时。
  static const Duration interval = Duration(hours: 24);

  /// 上次成功更新的时间（Unix 毫秒）。
  static const String _lastKey = 'subscription_last_refresh_at_ms';

  bool _running = false;

  Future<SharedPreferences> get _prefsInstance async =>
      _prefs ?? await SharedPreferences.getInstance();

  /// 是否在 Wi-Fi 下：默认走 connectivity_plus；拿不到结果按“不在”算，
  /// 不在不确定的网络下偷跑自动更新。
  Future<bool> _onWifi() async {
    final isWifi = _isWifi;
    if (isWifi != null) return isWifi();
    try {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi);
    } catch (_) {
      return false;
    }
  }

  /// 该自动更新时拉一次，返回 true；不该拉（未到时间 / 不在 Wi-Fi /
  /// 未绑定 / 正在拉）返回 false。失败不记时间，下次打开还会在
  /// 条件满足时再试（不静默失败：失败原因由 [NodesNotifier] 的
  /// errorMessage 在我的页显示）。
  Future<bool> maybeRefresh({
    required Future<void> Function() refresh,
    required bool Function() didSucceed,
    required bool hasBinding,
  }) async {
    if (_running || !hasBinding) return false;
    final prefs = await _prefsInstance;
    final lastMs = prefs.getInt(_lastKey);
    final nowMs = _clock().millisecondsSinceEpoch;
    if (lastMs != null && nowMs - lastMs < interval.inMilliseconds) {
      return false;
    }
    if (!await _onWifi()) return false;
    _running = true;
    try {
      await refresh();
      if (didSucceed()) {
        await prefs.setInt(_lastKey, nowMs);
        return true;
      }
      return false;
    } finally {
      _running = false;
    }
  }

  /// 手动刷新成功后调用：记一次成功时间，自动更新 24 小时内不再拉。
  Future<void> markRefreshed() async {
    final prefs = await _prefsInstance;
    await prefs.setInt(_lastKey, _clock().millisecondsSinceEpoch);
  }
}

/// 自动更新服务（可注入 fake 做测试）。
final subscriptionAutoRefreshProvider = Provider<SubscriptionAutoRefresh>(
  (ref) => SubscriptionAutoRefresh(),
);

/// App 启动与我的页打开时各调一次：条件满足就自动拉一次订阅，
/// 不满足什么都不做。`ref` 须是能读 provider 的引用。
Future<void> maybeAutoRefreshSubscription(WidgetRef ref) async {
  final service = ref.read(subscriptionAutoRefreshProvider);
  final notifier = ref.read(nodesProvider.notifier);
  final hasBinding =
      await ref.read(subscriptionServiceProvider).hasBinding();
  await service.maybeRefresh(
    refresh: notifier.refresh,
    didSucceed: () =>
        ref.read(nodesProvider).status == NodesStatus.loaded,
    hasBinding: hasBinding,
  );
}
