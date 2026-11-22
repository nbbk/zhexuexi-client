import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_provider.dart';
import '../core/node_model.dart';
import '../core/singbox_config.dart';
import '../core/singbox_core.dart';
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
    this.selectedNodeName,
    this.testingSpeed = false,
    this.speedTestedCount = 0,
    this.speedTestTotal = 0,
    this.speedTestError,
    this.selectionReason,
    this.speedTestAt,
    this.autoSelectEnabled = false,
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

  /// 当前选中的节点名（selector `Proxy` 的当前出站）。
  /// null 表示还没选过，界面按默认规则（第一个直连节点，没有时
  /// 第一个）显示；节点刷新后若名字还在就保留，不在了回落默认。
  final String? selectedNodeName;

  /// 是否正在测速。
  final bool testingSpeed;

  /// 本轮测速已测完的节点数（进度显示“测速中 X/Y”用）。
  final int speedTestedCount;

  /// 本轮测速的总节点数。
  final int speedTestTotal;

  /// 测速失败时的提示（如“核心未启动，先在首页打开开关再测速”）。
  final String? speedTestError;

  /// 最近一次选择的解释（自动选择：选了谁、为什么；手动选择：
  /// 选了谁）。给用户看的，不含技术细节。
  final String? selectionReason;

  /// 上次测速完成的时间。
  final DateTime? speedTestAt;

  /// 是否开着自动选择：用户点过“自动选择”后为 true，手动点节点
  /// 后为 false。true 时后台每 5 分钟重测一次（仅已连接时），
  /// 有明显更快的节点才自动切换。
  final bool autoSelectEnabled;

  /// 中转节点（名字以 -中转结尾）。
  List<Node> get relayNodes =>
      nodes.where((n) => n.source == NodeSource.relay).toList();

  /// 直连节点。
  List<Node> get directNodes =>
      nodes.where((n) => n.source == NodeSource.direct).toList();

  /// 当前选中的节点对象；没选过或名字不在列表里时按默认规则取。
  Node? get selectedNode {
    if (nodes.isEmpty) return null;
    if (selectedNodeName != null) {
      for (final node in nodes) {
        if (node.name == selectedNodeName) return node;
      }
    }
    final defaultName = SingboxConfigBuilder.defaultNodeName(nodes);
    if (defaultName == null) return null;
    for (final node in nodes) {
      if (node.name == defaultName) return node;
    }
    return null;
  }

  static const _unset = Object();

  NodesState copyWith({
    List<Node>? nodes,
    int? failedCount,
    SubscriptionUserinfo? userinfo,
    NodesStatus? status,
    String? errorMessage,
    DateTime? lastUpdated,
    SubscriptionFormat? format,
    Object? selectedNodeName = _unset,
    bool? testingSpeed,
    int? speedTestedCount,
    int? speedTestTotal,
    Object? speedTestError = _unset,
    Object? selectionReason = _unset,
    Object? speedTestAt = _unset,
    bool? autoSelectEnabled,
  }) {
    return NodesState(
      nodes: nodes ?? this.nodes,
      failedCount: failedCount ?? this.failedCount,
      userinfo: userinfo ?? this.userinfo,
      status: status ?? this.status,
      // errorMessage 沿用旧模式：不传就清掉（调用方刷新/成功时清提示）。
      errorMessage: errorMessage,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      format: format ?? this.format,
      selectedNodeName: selectedNodeName == _unset
          ? this.selectedNodeName
          : selectedNodeName as String?,
      testingSpeed: testingSpeed ?? this.testingSpeed,
      speedTestedCount: speedTestedCount ?? this.speedTestedCount,
      speedTestTotal: speedTestTotal ?? this.speedTestTotal,
      speedTestError: speedTestError == _unset
          ? this.speedTestError
          : speedTestError as String?,
      selectionReason: selectionReason == _unset
          ? this.selectionReason
          : selectionReason as String?,
      speedTestAt: speedTestAt == _unset
          ? this.speedTestAt
          : speedTestAt as DateTime?,
      autoSelectEnabled: autoSelectEnabled ?? this.autoSelectEnabled,
    );
  }
}

/// 节点列表的状态管理（切片 1：拉取＋解析＋列表；切片 4：测速与自动选择）。
class NodesNotifier extends Notifier<NodesState> {
  /// 一轮测速的并发数：4 路并行打 Clash API，既不太慢，
  /// 也不一次把核心打满。
  static const int _speedTestConcurrency = 4;

  /// 单个节点测速的服务端超时（毫秒）；Clash API delay 接口
  /// 按 16 位解析超时，超过 32767 会 400，不要传更大的。
  static const Duration _speedTestTimeout = Duration(seconds: 5);

  /// 后台重测的间隔（DEV-PLAN §4.3 1-6：每 5 分钟，仅已连接时）。
  static const Duration _retestInterval = Duration(minutes: 5);

  /// 后台重测时自动切换的门槛：新最快节点要比当前节点快 50ms 以上
  /// 才切，避免两个节点延迟来回抖就反复横跳。
  static const int _reselectMarginMs = 50;

  Timer? _retestTimer;

  @override
  NodesState build() {
    ref.onDispose(() {
      _retestTimer?.cancel();
      _retestTimer = null;
    });
    return const NodesState();
  }

  /// 懒启动后台重测定时器：只有用户真的用过测速/自动选择才启动，
  /// 不用的用户不为此多一个定时器；测试里用完要 dispose container。
  void _ensureRetestTimer() {
    _retestTimer ??= Timer.periodic(_retestInterval, (_) {
      unawaited(_onRetestTick());
    });
  }

  /// 后台重测的一次 tick：只在“开着自动选择＋已连接＋有节点＋
  /// 不在测速中”时才测；测完有明显更快的节点才自动切换。
  Future<void> _onRetestTick() async {
    if (!state.autoSelectEnabled) return;
    if (state.nodes.isEmpty || state.testingSpeed) return;
    final core = ref.read(coreServiceProvider);
    if (core.status != CoreStatus.started) return;
    final ok = await testAllSpeeds();
    if (!ok || !state.autoSelectEnabled) return;
    final candidates = state.nodes
        .where((n) => n.latencyMs != null)
        .toList();
    if (candidates.isEmpty) return;
    candidates.sort(_compareByLatency);
    final best = candidates.first;
    final current = state.selectedNode;
    if (current != null && current.name == best.name) return;
    if (current != null &&
        current.latencyMs != null &&
        !current.latencyFailed &&
        best.latencyMs! >= current.latencyMs! - _reselectMarginMs) {
      return; // 新最快没快够 50ms，不折腾。
    }
    final currentText = current == null
        ? '未选'
        : current.latencyFailed || current.latencyMs == null
        ? '${current.name}（测速失败）'
        : '${current.name} ${current.latencyMs}ms';
    await selectNode(
      best,
      reason: '后台重测：${best.name} 更快（${best.latencyMs}ms，'
          '当前 $currentText），已自动切换',
      auto: true,
    );
  }

  /// 延迟从小到大；相同延迟时直连优先，再按列表顺序（结果可复现）。
  int _compareByLatency(Node a, Node b) {
    final byLatency = a.latencyMs!.compareTo(b.latencyMs!);
    if (byLatency != 0) return byLatency;
    if (a.source != b.source) {
      return a.source == NodeSource.direct ? -1 : 1;
    }
    return state.nodes.indexOf(a).compareTo(state.nodes.indexOf(b));
  }

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
      // 刷新后节点是新对象，延迟清零重测；选中名字还在就保留，
      // 不在了回落默认规则；自动选择开关保持。
      final prevSelected = state.selectedNodeName;
      final stillThere = prevSelected != null &&
          result.nodes.any((n) => n.name == prevSelected);
      final selected = stillThere
          ? prevSelected
          : SingboxConfigBuilder.defaultNodeName(result.nodes);
      state = NodesState(
        nodes: result.nodes,
        failedCount: result.failedCount,
        userinfo: result.userinfo,
        status: NodesStatus.loaded,
        lastUpdated: DateTime.now(),
        format: result.format,
        selectedNodeName: selected,
        autoSelectEnabled: state.autoSelectEnabled,
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

  /// 清除测速缓存（切片 6 设置页“清除缓存”）：全部节点的延迟与
  /// 失败标记清零，上次测速时间清掉；节点列表本身不动。后台重测
  /// 开关保持（下次重测 tick 还会再测一轮）。
  void clearSpeedResults() {
    final nodes = state.nodes;
    for (final node in nodes) {
      node.latencyMs = null;
      node.latencyFailed = false;
    }
    state = state.copyWith(
      nodes: List.of(nodes),
      speedTestedCount: 0,
      speedTestTotal: 0,
      speedTestError: null,
      speedTestAt: null,
    );
  }

  /// 退出登录 / 换绑时清除绑定与列表。
  Future<void> clear() async {
    final service = ref.read(subscriptionServiceProvider);
    await service.clearBinding();
    state = const NodesState();
  }

  /// 一键测速：全部节点逐个调 Clash API delay 接口测延迟。
  ///
  /// 测速要核心在跑（delay 接口是核心的 Clash API）：核心未启动时
  /// 不发请求，直接报“核心未启动，先在首页打开开关再测速”。
  /// 测到的写进节点的 [Node.latencyMs]；测不到的标
  /// [Node.latencyFailed]（标灰、不自动选），不丢节点。
  /// 正在测速时再点直接返回，不开第二轮。
  Future<bool> testAllSpeeds() async {
    if (state.nodes.isEmpty || state.testingSpeed) return false;
    final core = ref.read(coreServiceProvider);
    if (core.status != CoreStatus.started) {
      state = state.copyWith(
        speedTestError: '核心未启动，先在首页打开开关再测速',
      );
      return false;
    }
    _ensureRetestTimer();
    final api = ref.read(clashApiClientProvider);
    final nodes = state.nodes;
    for (final node in nodes) {
      node.latencyMs = null;
      node.latencyFailed = false;
    }
    state = state.copyWith(
      nodes: List.of(nodes),
      testingSpeed: true,
      speedTestedCount: 0,
      speedTestTotal: nodes.length,
      speedTestError: null,
    );
    var tested = 0;
    for (var i = 0; i < nodes.length; i += _speedTestConcurrency) {
      final batch = nodes.skip(i).take(_speedTestConcurrency).toList();
      await Future.wait(
        batch.map((node) async {
          final tag = SingboxConfigBuilder.tagForNode(nodes, node);
          if (tag == null) {
            // 配置里根本没有这个出站（未知协议、缺 UUID、grpc 等），
            // 不调接口，直接标失败。
            node.latencyFailed = true;
          } else {
            final delay = await api.proxyDelay(
              tag,
              timeout: _speedTestTimeout,
            );
            if (delay == null) {
              node.latencyFailed = true;
            } else {
              node.latencyMs = delay;
            }
          }
          tested++;
          state = state.copyWith(
            nodes: List.of(nodes),
            speedTestedCount: tested,
          );
        }),
      );
    }
    state = state.copyWith(
      testingSpeed: false,
      speedTestAt: DateTime.now(),
    );
    return true;
  }

  /// 自动选择：延迟最低的可用节点。
  ///
  /// 还没测过时先测一轮再选；已有结果直接选，省时间。
  /// 全部测速失败时不选，原因写进 [NodesState.selectionReason]。
  /// 选上后打开自动选择开关（后台每 5 分钟重测，仅已连接时）。
  Future<bool> autoSelect() async {
    if (state.nodes.isEmpty) return false;
    if (!state.nodes.any((n) => n.latencyMs != null)) {
      final ok = await testAllSpeeds();
      if (!ok) return false;
    }
    final candidates = state.nodes
        .where((n) => n.latencyMs != null)
        .toList();
    if (candidates.isEmpty) {
      state = state.copyWith(
        selectionReason: '全部节点测速失败，无法自动选择',
      );
      return false;
    }
    candidates.sort(_compareByLatency);
    final best = candidates.first;
    final failed = state.nodes.where((n) => n.latencyFailed).length;
    final reason = '已选 ${best.name}：延迟最低 ${best.latencyMs}ms'
        '（共测 ${state.nodes.length} 个，$failed 个失败）';
    return selectNode(best, reason: reason, auto: true);
  }

  /// 手动点一个节点选中它（[auto] 为 true 时是自动选择触发的，
  /// 打开后台重测开关；手动点时关掉后台重测）。
  ///
  /// 核心在跑时先调 Clash API 切 selector，核心没响应就不切，
  /// 不把界面上的“使用中”和实际跑的节点搞成两张皮；
  /// 切成功后把默认选择写进磁盘配置（只改 `default` 字段，
  /// 不重载），下次启动还用它；核心没启动时只落盘。
  /// 已经是当前节点时直接返回 true，不重复切。
  Future<bool> selectNode(
    Node node, {
    String? reason,
    bool auto = false,
  }) async {
    final nodes = state.nodes;
    // 不设“已是当前节点就直接返回”的短路：点一个节点 = 核心切过去 + 落盘，
    // 每次都走完这一遍，界面上的“使用中”和核心实际跑的节点永远是一张皮。
    // PUT 是幂等的本地调用，重复点一次的代价可以忽略；短路反而会在
    // 配置重载后留下“记的是它、跑的不是它”的不同步。
    final tag = SingboxConfigBuilder.tagForNode(nodes, node);
    if (tag == null) {
      state = state.copyWith(selectionReason: '该节点暂不支持，无法选择');
      return false;
    }
    final core = ref.read(coreServiceProvider);
    if (core.status == CoreStatus.started) {
      final api = ref.read(clashApiClientProvider);
      final switched = await api.selectProxy('Proxy', tag);
      if (!switched) {
        state = state.copyWith(selectionReason: '切换失败，核心没有响应');
        return false;
      }
    }
    final persisted = await core.updateSelectorDefault(tag);
    var finalReason = reason ?? '已选择 ${node.name}';
    if (!persisted) finalReason += '（下次启动的默认选择未保存）';
    state = state.copyWith(
      selectedNodeName: node.name,
      autoSelectEnabled: auto,
      selectionReason: finalReason,
    );
    return true;
  }
}

/// 节点列表（全项目共用这一个 provider，界面、测速、核心配置生成都读它）。
final nodesProvider = NotifierProvider<NodesNotifier, NodesState>(
  NodesNotifier.new,
);
