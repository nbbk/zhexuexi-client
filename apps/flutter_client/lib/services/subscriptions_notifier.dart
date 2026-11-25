import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'nodes_notifier.dart';
import 'subscription_store.dart';

/// 订阅列表的状态管理（多订阅管理页用）。
///
/// 只管订阅条目的增删改名与启用/停用；拉取与合并仍是
/// [NodesNotifier] 的事，改完列表后调一次它的 [NodesNotifier.refresh]
///（或单条 [NodesNotifier.refreshSubscription]），节点列表跟着变。
class SubscriptionsNotifier extends Notifier<List<SubscriptionEntry>> {
  @override
  List<SubscriptionEntry> build() => const [];

  Future<List<SubscriptionEntry>> _entries() async {
    final service = ref.read(subscriptionServiceProvider);
    final store = ref.read(subscriptionStoreProvider);
    final primaryUrl = await service.readSubscriptionUrl();
    return store.listSubscriptions(primaryUrl: primaryUrl);
  }

  /// 读最新列表（管理页打开时调一次）。
  Future<void> load() async {
    state = await _entries();
  }

  /// 手动加一条订阅：链接不对返回原因（给用户看的），成功返回 null。
  /// 加完立刻拉一次，节点列表里马上能看到新订阅的节点。
  Future<String?> add(String url) async {
    final store = ref.read(subscriptionStoreProvider);
    final result = await store.addCustom(url);
    if (result.error != null) return result.error;
    await load();
    await ref.read(nodesProvider.notifier).refresh();
    return null;
  }

  /// 改名（主订阅与手动加的都支持；空名字返回 false）。
  Future<bool> rename(String id, String name) async {
    final store = ref.read(subscriptionStoreProvider);
    final ok = await store.rename(id, name);
    if (ok) await load();
    return ok;
  }

  /// 启用 / 停用；改完立刻重拉，节点列表跟着变。
  Future<bool> setEnabled(String id, bool enabled) async {
    final store = ref.read(subscriptionStoreProvider);
    final ok = await store.setEnabled(id, enabled);
    if (!ok) return false;
    await load();
    await ref.read(nodesProvider.notifier).refresh();
    return true;
  }

  /// 删除一条手动加的订阅（主订阅不给删，返回 false）；
  /// 删完立刻重拉，该订阅的节点不再显示。
  Future<bool> remove(String id) async {
    final store = ref.read(subscriptionStoreProvider);
    final ok = await store.removeCustom(id);
    if (!ok) return false;
    await load();
    await ref.read(nodesProvider.notifier).refresh();
    return true;
  }

  /// 只刷新一条订阅（管理页的单个刷新），返回是否拉成功。
  Future<bool> refreshOne(String id) =>
      ref.read(nodesProvider.notifier).refreshSubscription(id);

  /// 全部刷新。
  Future<void> refreshAll() =>
      ref.read(nodesProvider.notifier).refresh();
}

/// 订阅列表（管理页读它；节点拉取与合并仍走 [nodesProvider]）。
final subscriptionsProvider =
    NotifierProvider<SubscriptionsNotifier, List<SubscriptionEntry>>(
      SubscriptionsNotifier.new,
    );
