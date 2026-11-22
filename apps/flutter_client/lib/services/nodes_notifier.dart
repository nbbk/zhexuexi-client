import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/node_model.dart';
import '../core/userinfo.dart';
import 'subscription_parser.dart';
import 'subscription_service.dart';

/// 订阅服务（可注入 fake 做测试）。
final subscriptionServiceProvider = Provider<SubscriptionService>(
  (ref) => SubscriptionService(),
);

/// 节点列表状态。
enum NodesStatus {
  /// 未绑定订阅。
  initial,

  /// 正在拉取。
  loading,

  /// 已拉到节点（可能为 0 个，见 [NodesState.nodes]）。
  loaded,

  /// 拉取失败（见 [NodesState.errorMessage]）。
  error,
}

class NodesState {
  const NodesState({
    this.nodes = const [],
    this.failedCount = 0,
    this.userinfo,
    this.status = NodesStatus.initial,
    this.errorMessage,
    this.lastUpdated,
    this.format,
  });

  /// 节点列表。
  final List<Node> nodes;

  /// 解析失败的节点个数。
  final int failedCount;

  /// 流量与到期（中转口径；没有 userinfo 头时为 null）。
  final SubscriptionUserinfo? userinfo;

  final NodesStatus status;

  /// 失败时的提示（给用户看的，不含技术细节）。
  final String? errorMessage;

  /// 上次成功更新的时间。
  final DateTime? lastUpdated;

  /// 最终生效的订阅格式。
  final SubscriptionFormat? format;

  /// 中转节点（名字以 -中转结尾）。
  List<Node> get relayNodes =>
      nodes.where((n) => n.source == NodeSource.relay).toList();

  /// 直连节点。
  List<Node> get directNodes =>
      nodes.where((n) => n.source == NodeSource.direct).toList();

  NodesState copyWith({
    List<Node>? nodes,
    int? failedCount,
    SubscriptionUserinfo? userinfo,
    NodesStatus? status,
    String? errorMessage,
    DateTime? lastUpdated,
    SubscriptionFormat? format,
  }) {
    return NodesState(
      nodes: nodes ?? this.nodes,
      failedCount: failedCount ?? this.failedCount,
      userinfo: userinfo ?? this.userinfo,
      status: status ?? this.status,
      errorMessage: errorMessage,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      format: format ?? this.format,
    );
  }
}

/// 节点列表的状态管理（切片 1：拉取＋解析＋列表；测速与自动选择在切片 4）。
class NodesNotifier extends Notifier<NodesState> {
  @override
  NodesState build() => const NodesState();

  /// 拉一次订阅并更新列表。未绑定时保持 initial 状态（界面显示绑定入口）。
  Future<void> refresh() async {
    final service = ref.read(subscriptionServiceProvider);
    final url = await service.readSubscriptionUrl();
    if (url == null) {
      state = state.copyWith(status: NodesStatus.initial);
      return;
    }
    state = state.copyWith(status: NodesStatus.loading);
    try {
      final result = await service.fetchNodes(subscriptionUrl: url);
      state = NodesState(
        nodes: result.nodes,
        failedCount: result.failedCount,
        userinfo: result.userinfo,
        status: NodesStatus.loaded,
        lastUpdated: DateTime.now(),
        format: result.format,
      );
    } on SubscriptionException catch (e) {
      state = state.copyWith(
        status: NodesStatus.error,
        errorMessage: e.message,
      );
    } catch (_) {
      // 兜底：任何未预料的异常都变成错误状态，不让 Future 带着异常炸掉界面。
      state = state.copyWith(
        status: NodesStatus.error,
        errorMessage: '网络不通，检查订阅地址',
      );
    }
  }

  /// 粘贴一条完整订阅链接后绑定并刷新。链接不对时直接报原因，不刷新。
  Future<void> bindAndRefresh(String link) async {
    final service = ref.read(subscriptionServiceProvider);
    try {
      await service.saveSubscriptionLink(link);
    } on SubscriptionException catch (e) {
      state = state.copyWith(
        status: NodesStatus.error,
        errorMessage: e.message,
      );
      return;
    }
    await refresh();
  }

  /// 退出登录 / 换绑时清除绑定与列表。
  Future<void> clear() async {
    final service = ref.read(subscriptionServiceProvider);
    await service.clearBinding();
    state = const NodesState();
  }
}

/// 节点列表（全项目共用这一个 provider，界面、测速、核心配置生成都读它）。
final nodesProvider = NotifierProvider<NodesNotifier, NodesState>(
  NodesNotifier.new,
);
