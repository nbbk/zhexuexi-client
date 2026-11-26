import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/clash_api_client.dart';
import '../core/core_provider.dart';
import '../core/direct_ping.dart';
import '../core/node_model.dart';
import '../core/singbox_config.dart';
import '../core/singbox_core.dart';
import '../core/userinfo.dart';
import 'remote_config_notifier.dart';
import 'node_override_store.dart';
import 'single_node_store.dart';
import 'subscription_parser.dart';
import 'subscription_service.dart';
import 'subscription_store.dart';

/// 订阅服务（可注入 fake 做测试）。
final subscriptionServiceProvider = Provider<SubscriptionService>(
  (ref) => SubscriptionService(),
);

/// 直连探测（开关关着时测速用，可注入 fake 做测试，见
/// speed_test_test.dart；生产默认走 [probeDirectLatency] 真 TCP 连接）。
final directProbeProvider =
    Provider<
      Future<DirectProbeResult> Function(
        String host,
        int port, {
        Duration timeout,
      })
    >((ref) => probeDirectLatency);

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
    this.speedTestDirect = false,
    this.speedTestDirectFallback = false,
    this.autoSelectEnabled = false,
    this.addressNotice,
    this.subscriptionSummaries = const [],
    this.testingSingleNodeKey,
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

  /// 测速失败时的提示（如测速本身没跑起来）；单节点测速失败不走这里，
  /// 只标该节点（[Node.latencyFailed]＋[Node.latencyFailureReason]）。
  final String? speedTestError;

  /// 最近一次选择的解释（自动选择：选了谁、为什么；手动选择：
  /// 选了谁）。给用户看的，不含技术细节。
  final String? selectionReason;

  /// 上次测速完成的时间。
  final DateTime? speedTestAt;

  /// 上次测速的口径：true＝开关关着测的直连延迟（到服务器的 TCP 延迟），
  /// false＝开关开着测的代理延迟（走代理的真实延迟）。两种口径不同，
  /// 不能直接比（节点页按这个值写提示文案）。
  final bool speedTestDirect;

  /// 上次测速是不是“开关开着但探活失败、被迫改用直连探测”
  ///（2026-11-26 二轮修复）：true 时节点页的口径提示不能写
  /// “开关关着”，要写明是出站拨测失败后改走直连（结果不代表
  /// 代理延迟）；失败原因同时写进 [speedTestError] 的横幅里，
  /// 两处一起说，不静默切换。
  final bool speedTestDirectFallback;

  /// 是否开着自动选择：用户点过“自动选择”后为 true，手动点节点
  /// 后为 false。true 时后台每 5 分钟重测一次（仅已连接时），
  /// 有明显更快的节点才自动切换。
  final bool autoSelectEnabled;

  /// 订阅地址刚被远程配置换过时的提示（切片 7）：
  /// “订阅地址已变，已自动切换到新地址”，节点页顶部显示一次，
  /// 用户关掉后清空。成功换地址才有，平时为 null。
  final String? addressNotice;

  /// 多订阅：每条订阅的摘要（流量/到期/节点数/报错），管理页按这个
  /// 列表显示各订阅的情况；没有 userinfo 头的订阅对应项为 null，
  /// 界面显示“—”。[userinfo] 仍是主订阅那一份（首页/我的页继续用）。
  final List<SubscriptionSummary> subscriptionSummaries;

  /// 正在单个测速的节点（按内容 key 认行；null 表示没有在测的单节点）。
  /// 测速中芯片转圈用；一键测速进行中、或已有单节点在测时再点直接返回。
  final String? testingSingleNodeKey;

  /// 中转节点（名字以 -中转 或 -B 结尾，见 subscription_parser.dart）。
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
    bool? speedTestDirect,
    bool? speedTestDirectFallback,
    bool? autoSelectEnabled,
    Object? addressNotice = _unset,
    List<SubscriptionSummary>? subscriptionSummaries,
    Object? testingSingleNodeKey = _unset,
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
      speedTestDirect: speedTestDirect ?? this.speedTestDirect,
      speedTestDirectFallback:
          speedTestDirectFallback ?? this.speedTestDirectFallback,
      autoSelectEnabled: autoSelectEnabled ?? this.autoSelectEnabled,
      addressNotice: addressNotice == _unset
          ? this.addressNotice
          : addressNotice as String?,
      subscriptionSummaries:
          subscriptionSummaries ?? this.subscriptionSummaries,
      testingSingleNodeKey: testingSingleNodeKey == _unset
          ? this.testingSingleNodeKey
          : testingSingleNodeKey as String?,
    );
  }
}

/// 一条订阅的拉取摘要（多订阅管理页按这个列表显示各订阅的
/// 流量/到期/节点数/报错；没有 userinfo 头时 [userinfo] 为 null）。
class SubscriptionSummary {
  const SubscriptionSummary({
    required this.id,
    required this.name,
    required this.isPrimary,
    required this.enabled,
    this.nodeCount = 0,
    this.userinfo,
    this.errorMessage,
    this.lastUpdated,
  });

  /// 订阅 id（主订阅是 `primary`，手动加的是 `custom_…`）。
  final String id;

  /// 显示名。
  final String name;

  /// 是否主订阅（自家面板）。
  final bool isPrimary;

  /// 是否启用。
  final bool enabled;

  /// 这次拉到的节点数（停用的、拉失败的都是 0）。
  final int nodeCount;

  /// 流量与到期（该订阅自己的 `subscription-userinfo` 头；
  /// 没有头时为 null，界面显示“—”）。
  final SubscriptionUserinfo? userinfo;

  /// 本次拉取失败的原因（给用户看的；成功时为 null）。
  final String? errorMessage;

  /// 该订阅上次成功拉取的时间。
  final DateTime? lastUpdated;
}

/// 一条订阅最近一次拉取的缓存结果（单条刷新时只换这一条，
/// 其余订阅用缓存重建合并列表，不用全量重拉）。
class _CachedSubscriptionResult {
  const _CachedSubscriptionResult({
    required this.nodes,
    required this.failedCount,
    required this.userinfo,
    required this.format,
    required this.errorMessage,
    required this.lastUpdated,
  });

  final List<Node> nodes;
  final int failedCount;
  final SubscriptionUserinfo? userinfo;
  final SubscriptionFormat? format;

  /// 拉取失败的原因（成功时为 null）。
  final String? errorMessage;

  /// 上次成功拉取的时间（从没成功过时为 null）。
  final DateTime? lastUpdated;

  bool get succeeded => errorMessage == null;
}

/// 节点列表的状态管理（切片 1：拉取＋解析＋列表；切片 4：测速与自动选择）。
class NodesNotifier extends Notifier<NodesState> {
  /// 一轮测速的并发数：2 路并行打 Clash API（2026-11-26 0.1.2
  /// 根因 B：4 路并发下冷拨号互相抢带宽，一次丢包就越线）。
  static const int _speedTestConcurrency = 2;

  /// 单个节点测速的服务端超时（毫秒）；Clash API delay 接口
  /// 按 16 位解析超时，超过 32767 会 400，不要传更大的。
  /// 10 秒（2026-11-26 0.1.2 根因 B：5 秒单次、无预热、无重试，
  /// 冷拨号全链路 3–7 RTT 一次丢包就越线；与启动探活 probeTimeout
  /// 对齐）。
  static const Duration _speedTestTimeout = Duration(seconds: 10);

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

  /// 各订阅最近一次拉取的缓存（单条刷新时只换这一条，
  /// 其余订阅用缓存重建合并列表）。
  final Map<String, _CachedSubscriptionResult> _cachedResults = {};

  /// 读全部订阅条目：主订阅（有绑定才有，在前）＋手动加的（在后）。
  Future<List<SubscriptionEntry>> _loadEntries() async {
    final service = ref.read(subscriptionServiceProvider);
    final store = ref.read(subscriptionStoreProvider);
    final primaryUrl = await service.readSubscriptionUrl();
    return store.listSubscriptions(primaryUrl: primaryUrl);
  }

  /// 拉全部已启用的订阅并合并（多订阅），再拼上手动加的单节点。
  ///
  /// 并行拉（`Future.wait`，各自 try/catch）：一条订阅拉取失败
  /// 只记该条的错误、不影响其他条；有任一条成功就显示合并后的
  /// 节点，全部失败才报错误状态。没有订阅时保持 initial 状态
  ///（界面显示绑定入口）。
  ///
  /// 主订阅 404（令牌查无此人）时不直接报“订阅已失效”：先拉远程配置
  ///（切片 7），配置里有新订阅地址就换地址重试一次（令牌不变，
  /// 只换地址）；新地址也拉不到才报原错。重试成功时节点页顶部
  /// 显示一句“订阅地址已变，已自动切换到新地址”。手动加的订阅
  /// 不参与远程配置更新、不参与 404 重试。
  Future<void> refresh() async {
    final entries = await _loadEntries();
    final singles = await _loadTaggedSingleNodes();
    if (entries.isEmpty && singles.isEmpty) {
      _cachedResults.clear();
      state = state.copyWith(status: NodesStatus.initial);
      return;
    }
    state = state.copyWith(status: NodesStatus.loading);
    final enabled = entries.where((e) => e.enabled).toList();
    await Future.wait(enabled.map(_fetchIntoCache));
    await _rebuildFromCache(entries, singles);
  }

  /// 只刷新一条订阅（管理页的单个刷新）：重拉这一条，
  /// 其余订阅用缓存重建合并列表，不全量重拉。
  /// 返回 true 表示这条拉成功了。
  Future<bool> refreshSubscription(String id) async {
    final entries = await _loadEntries();
    SubscriptionEntry? entry;
    for (final e in entries) {
      if (e.id == id) entry = e;
    }
    if (entry == null || !entry.enabled) return false;
    await _fetchIntoCache(entry);
    await _rebuildFromCache(entries, await _loadTaggedSingleNodes());
    return _cachedResults[id]?.succeeded ?? false;
  }

  /// 拉一条订阅进缓存（失败也记进缓存，不抛到调用方）。
  /// 拉到的节点打上订阅来源（[Node.subscriptionId]/[subscriptionName]）。
  Future<void> _fetchIntoCache(SubscriptionEntry entry) async {
    final service = ref.read(subscriptionServiceProvider);
    try {
      final result = await service.fetchNodes(subscriptionUrl: entry.url);
      _cachedResults[entry.id] = _CachedSubscriptionResult(
        nodes: _tagNodes(result.nodes, entry),
        failedCount: result.failedCount,
        userinfo: result.userinfo,
        format: result.format,
        errorMessage: null,
        lastUpdated: DateTime.now(),
      );
    } on SubscriptionException catch (e) {
      if (entry.isPrimary && e.kind == SubscriptionErrorKind.invalid) {
        final retried = await _retryPrimaryWithRemoteConfig(entry.url);
        if (retried != null) {
          _cachedResults[entry.id] = retried;
          state = state.copyWith(
            addressNotice: '订阅地址已变，已自动切换到新地址',
          );
          return;
        }
      }
      _cachedResults[entry.id] = _CachedSubscriptionResult(
        nodes: const [],
        failedCount: 0,
        userinfo: null,
        format: null,
        errorMessage: e.message,
        lastUpdated: null,
      );
    } catch (_) {
      // 兜底：任何未预料的异常都记成该条的错误，不让 Future 炸掉界面。
      _cachedResults[entry.id] = _CachedSubscriptionResult(
        nodes: const [],
        failedCount: 0,
        userinfo: null,
        format: null,
        errorMessage: '网络不通，请检查网络后重试',
        lastUpdated: null,
      );
    }
  }

  /// 给拉到的节点打上订阅来源（返回新列表，原节点对象不动）。
  List<Node> _tagNodes(List<Node> nodes, SubscriptionEntry entry) {
    return nodes
        .map(
          (n) => Node(
            name: n.name,
            protocol: n.protocol,
            address: n.address,
            port: n.port,
            source: n.source,
            uuidOrPassword: n.uuidOrPassword,
            transport: n.transport,
            tls: n.tls,
            sni: n.sni,
            wsPath: n.wsPath,
            wsHost: n.wsHost,
            method: n.method,
            group: n.group,
            isPlainText: n.isPlainText,
            username: n.username,
            realityPublicKey: n.realityPublicKey,
            realityShortId: n.realityShortId,
            fingerprint: n.fingerprint,
            flow: n.flow,
            alpn: n.alpn,
            congestionControl: n.congestionControl,
            subscriptionId: entry.id,
            subscriptionName: entry.name,
          ),
        )
        .toList();
  }

  /// 用缓存重建合并后的状态。
  ///
  /// 合并：按订阅顺序拼接（主订阅在前，手动加的按列表顺序）；
  /// 去重按节点内容（[Node.dedupKey]），内容相同的只留第一条；
  /// 手动加的单节点拼在最后（内容与订阅节点相同时订阅优先）。
  /// [NodesState.userinfo] 仍是主订阅那一份（首页/我的页继续用，
  /// 不改那两处）；各订阅的 userinfo 在 [subscriptionSummaries] 里。
  /// 单节点不进 [subscriptionSummaries]（它不是订阅）。
  Future<void> _rebuildFromCache(
    List<SubscriptionEntry> entries,
    List<Node> singles,
  ) async {
    final merged = <Node>[];
    final seen = <String>{};
    var failedCount = 0;
    var anySuccess = false;
    String? firstError;
    SubscriptionFormat? format;
    SubscriptionUserinfo? primaryUserinfo;
    final summaries = <SubscriptionSummary>[];
    for (final entry in entries) {
      final cached = _cachedResults[entry.id];
      if (!entry.enabled || cached == null) {
        summaries.add(
          SubscriptionSummary(
            id: entry.id,
            name: entry.name,
            isPrimary: entry.isPrimary,
            enabled: entry.enabled,
          ),
        );
        continue;
      }
      failedCount += cached.failedCount;
      if (cached.succeeded) {
        anySuccess = true;
        format ??= cached.format;
        if (entry.isPrimary) primaryUserinfo = cached.userinfo;
        for (final node in cached.nodes) {
          if (seen.add(node.dedupKey)) merged.add(node);
        }
      } else {
        firstError ??= cached.errorMessage;
      }
      summaries.add(
        SubscriptionSummary(
          id: entry.id,
          name: entry.name,
          isPrimary: entry.isPrimary,
          enabled: entry.enabled,
          nodeCount: cached.nodes.length,
          userinfo: cached.userinfo,
          errorMessage: cached.errorMessage,
          lastUpdated: cached.lastUpdated,
        ),
      );
    }
    // 手动加的单节点拼在最后（内容与订阅节点相同时订阅优先）。
    for (final node in singles) {
      if (seen.add(node.dedupKey)) merged.add(node);
    }
    // 本地改动（详情页编辑）盖在重新解析出的节点上：刷新重建
    // Node 对象也不会丢改动（见 node_override_store.dart）。
    // 盖完再算选中：改名后选中按新名字认。
    final nodes = await _applyOverrides(merged);
    // 刷新后节点是新对象，延迟清零重测；选中名字还在就保留，
    // 不在了回落默认规则；自动选择开关保持。
    final prevSelected = state.selectedNodeName;
    final stillThere =
        prevSelected != null && nodes.any((n) => n.name == prevSelected);
    final selected = stillThere
        ? prevSelected
        : SingboxConfigBuilder.defaultNodeName(nodes);
    if (anySuccess || singles.isNotEmpty) {
      state = NodesState(
        nodes: nodes,
        failedCount: failedCount,
        userinfo: primaryUserinfo,
        status: NodesStatus.loaded,
        lastUpdated: DateTime.now(),
        format: format,
        selectedNodeName: selected,
        autoSelectEnabled: state.autoSelectEnabled,
        addressNotice: state.addressNotice,
        subscriptionSummaries: summaries,
      );
    } else if (entries.every((e) => !e.enabled)) {
      // 全都停用了：不是失败，显示空列表（管理页可再打开）。
      state = NodesState(
        nodes: const [],
        failedCount: 0,
        status: NodesStatus.loaded,
        lastUpdated: state.lastUpdated,
        selectedNodeName: null,
        autoSelectEnabled: state.autoSelectEnabled,
        addressNotice: state.addressNotice,
        subscriptionSummaries: summaries,
      );
    } else {
      state = state.copyWith(
        status: NodesStatus.error,
        errorMessage: firstError ?? '网络不通，请检查网络后重试',
        subscriptionSummaries: summaries,
      );
    }
  }

  /// 主订阅 404 后的重试：拉远程配置，按“主订阅地址 → 备用地址”
  /// 的顺序试新地址（只换 base、令牌不变），第一个拉通的返回结果；
  /// 都没拉通返回 null，本地绑定换回旧地址，别留一个半截的新地址。
  /// 只针对主订阅，手动加的订阅不走这里。
  Future<_CachedSubscriptionResult?> _retryPrimaryWithRemoteConfig(
    String oldUrl,
  ) async {
    // 走 notifier 的 refresh：缓存与界面上的品牌/订阅地址一起换，
    // 不只换 service 里的缓存。
    final configResult =
        await ref.read(remoteConfigProvider.notifier).refresh();
    final config = configResult.config;
    final oldBase = SubscriptionService.baseOf(oldUrl);
    final service = ref.read(subscriptionServiceProvider);
    final candidates = <String>[
      config.subscriptionUrl,
      ...config.subscriptionBackupUrls,
    ];
    for (final candidate in candidates) {
      final base = SubscriptionService.baseOf(candidate);
      if (base.isEmpty || base == oldBase) continue;
      await service.updateBaseUrl(base);
      try {
        final url = await service.readSubscriptionUrl();
        if (url == null) continue;
        final result = await service.fetchNodes(subscriptionUrl: url);
        // 换地址后主订阅的显示名不变（仍是“自家面板”或用户改过的名）。
        final entries = await _loadEntries();
        var entry = const SubscriptionEntry(
          id: SubscriptionEntry.primaryId,
          name: SubscriptionEntry.primaryDefaultName,
          url: '',
          enabled: true,
          isPrimary: true,
        );
        for (final e in entries) {
          if (e.isPrimary) entry = e;
        }
        return _CachedSubscriptionResult(
          nodes: _tagNodes(result.nodes, entry),
          failedCount: result.failedCount,
          userinfo: result.userinfo,
          format: result.format,
          errorMessage: null,
          lastUpdated: DateTime.now(),
        );
      } on SubscriptionException {
        continue;
      } catch (_) {
        continue;
      }
    }
    // 候选地址都没拉通：把本地绑定换回旧地址，别留一个半截的新地址。
    await service.updateBaseUrl(oldBase);
    return null;
  }

  /// 关掉节点页顶部的“订阅地址已变”提示。
  void dismissAddressNotice() {
    if (state.addressNotice != null) {
      state = state.copyWith(addressNotice: null);
    }
  }

  /// 手动加的单节点（粘贴/扫码一条链接）：不走订阅拉取，
  /// 直接读存储、打上“手动添加”来源（与 [_tagNodes] 同一套字段复制，
  /// 只换来源）；刷新时拼在订阅节点后面。
  /// 存储读失败时按空列表算：单节点是附加的，读不到它不能拖垮
  /// 整轮订阅刷新（订阅节点照常显示）。
  Future<List<Node>> _loadTaggedSingleNodes() async {
    List<Node> nodes;
    try {
      final store = ref.read(singleNodeStoreProvider);
      nodes = await store.listNodes();
    } catch (_) {
      return const [];
    }
    return nodes
        .map(
          (n) => Node(
            name: n.name,
            protocol: n.protocol,
            address: n.address,
            port: n.port,
            source: n.source,
            uuidOrPassword: n.uuidOrPassword,
            transport: n.transport,
            tls: n.tls,
            sni: n.sni,
            wsPath: n.wsPath,
            wsHost: n.wsHost,
            method: n.method,
            group: n.group,
            isPlainText: n.isPlainText,
            username: n.username,
            realityPublicKey: n.realityPublicKey,
            realityShortId: n.realityShortId,
            fingerprint: n.fingerprint,
            flow: n.flow,
            alpn: n.alpn,
            congestionControl: n.congestionControl,
            subscriptionId: SingleNodeStore.singleNodesId,
            subscriptionName: SingleNodeStore.singleNodesName,
          ),
        )
        .toList();
  }

  /// 加一个单节点（粘贴/扫码一条节点链接）：链接不对返回原因，
  /// 成功返回 null（加完立刻刷新，节点列表里马上能看到）。
  Future<String?> addSingleNode(String link) async {
    final store = ref.read(singleNodeStoreProvider);
    final result = await store.addSingleNode(link);
    if (result.error != null) return result.error;
    await refresh();
    return null;
  }

  /// 加一段订阅正文（扫码扫到的三种格式正文）：逐条加为单节点，
  /// 返回新加的节点数；解不出节点、或全已存在时返回原因。
  Future<({int addedCount, String? error})> addNodesFromContent(
    String body,
  ) async {
    final store = ref.read(singleNodeStoreProvider);
    final result = await store.addContent(body);
    if (result.error != null) {
      return (addedCount: 0, error: result.error);
    }
    await refresh();
    return (addedCount: result.addedCount, error: null);
  }

  /// 删一个单节点（多节点正文里的单个节点删不干净，返回 false）。
  /// 节点被本地改动过时按原始键删：改地址/端口后新 dedupKey 变了，
  /// 只有 [Node.originDedupKey] 还指着原文解析出的那条。
  Future<bool> removeSingleNode(Node node) async {
    final store = ref.read(singleNodeStoreProvider);
    final ok = await store.removeSingleNode(
      node.originDedupKey ?? node.dedupKey,
    );
    if (!ok) return false;
    await refresh();
    return true;
  }

  /// 把详情页的编辑落盘：先校验（不合法返回原因、不写盘），
  /// 再写覆盖、刷新列表。成功返回 null。
  /// [editedFields] 只含改过的几项也行：先用节点现有字段打底
  /// 再盖上改动，整套字段一起存。
  /// 覆盖键用原始键（[Node.originDedupKey]，没有就是当前 dedupKey），
  /// 不是改后的 dedupKey：改地址/端口后新键变了，刷新时凭原始键
  /// 才能找回这条覆盖。
  Future<String?> updateNodeOverride(
    Node node,
    Map<String, dynamic> editedFields,
  ) async {
    final merged = {
      ...NodeOverrideStore.fieldsOf(node),
      ...editedFields,
    };
    final error = NodeOverrideStore.validateFields(merged);
    if (error != null) return error;
    final store = ref.read(nodeOverrideStoreProvider);
    final originalKey = node.originDedupKey ?? node.dedupKey;
    final wasSelected = state.selectedNodeName == node.name;
    final newName = (merged['name'] as String?)?.trim() ?? node.name;
    try {
      await store.saveOverride(
        subscriptionId: node.subscriptionId,
        dedupKey: originalKey,
        fields: merged,
      );
    } catch (_) {
      return '保存失败，请重试';
    }
    await refresh();
    // 改名后选中跟着新名字走，不然刷新后选中回落到默认节点。
    // （核心配置里的默认选择仍是旧名对应的 tag，见回报里的边界。）
    if (wasSelected && newName != node.name) {
      state = state.copyWith(selectedNodeName: newName);
    }
    return null;
  }

  /// 恢复默认：删掉该节点的覆盖，再刷新——节点回到订阅/原文
  /// 解析出的样子（名字、地址、端口、协议全部还原）。
  Future<void> clearNodeOverride(Node node) async {
    final store = ref.read(nodeOverrideStoreProvider);
    try {
      await store.clearOverride(
        subscriptionId: node.subscriptionId,
        dedupKey: node.originDedupKey ?? node.dedupKey,
      );
    } catch (_) {
      // 删覆盖失败也刷新一次：列表按现有覆盖重算，不炸界面。
    }
    await refresh();
  }

  /// 把本地改动盖到刚拼装好的节点列表上（订阅节点＋单节点都走）。
  /// 覆盖读失败时按没有覆盖算：改动是附加的，读不到它不能拖垮
  /// 整轮订阅刷新（订阅节点照常显示）。
  Future<List<Node>> _applyOverrides(List<Node> nodes) async {
    Map<String, Map<String, dynamic>> all;
    try {
      all = await ref.read(nodeOverrideStoreProvider).readAll();
    } catch (_) {
      return nodes;
    }
    if (all.isEmpty) return nodes;
    return nodes.map((node) {
      final fields = all[NodeOverrideStore.overrideKey(
        subscriptionId: node.subscriptionId,
        dedupKey: node.dedupKey,
      )];
      if (fields == null) return node;
      return NodeOverrideStore.applyTo(node, fields);
    }).toList();
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
      node.latencyFailureReason = null;
    }
    state = state.copyWith(
      nodes: List.of(nodes),
      speedTestedCount: 0,
      speedTestTotal: 0,
      speedTestError: null,
      speedTestAt: null,
      speedTestDirect: false,
      speedTestDirectFallback: false,
    );
  }

  /// 退出登录 / 换绑时清除绑定与列表（只清主订阅绑定，
  /// 手动加的订阅不动；缓存一起清掉）。
  Future<void> clear() async {
    final service = ref.read(subscriptionServiceProvider);
    await service.clearBinding();
    _cachedResults.clear();
    state = const NodesState();
  }

  /// 测速口径判定（2026-11-26 二轮修复）：只认“核心在跑且探活通过”
  /// 才走代理口径——以前只认 `status == started`，首页闩锁成 error
  /// 时节点页会静默切回直连 TCP 探测，两边失败文案还相同（“超时不可达”
  /// vs “核心没有响应”分不清），用户无法区分是代理不通还是直连不通。
  /// 核心在跑但探活失败时改走直连探测，但必须明确提示（[speedTestError]
  /// 横幅＋[NodesState.speedTestDirectFallback]），不静默切换。
  /// 返回（是否走直连，写进横幅的提示——不走直连时为 null）。
  (bool, String?) _speedTestMode() {
    final core = ref.read(coreServiceProvider);
    if (core.status != CoreStatus.started) return (true, null);
    if (!core.probeFailed) return (false, null);
    final reason = core.lastProbeError ?? '出站拨测失败';
    return (
      true,
      '开关开着但$reason，本次改用直连探测（结果不代表代理延迟，'
          '请先去首页点「重新拨测」或换节点）',
    );
  }

  /// 一键测速：全部节点逐个测延迟，开关开不开都能测。
  ///
  /// - 开关开着（核心在跑）且探活通过：走 Clash API delay 接口，
  ///   测的是走代理的真实延迟；
  /// - 开关关着：走直连探测（对节点地址做 TCP 连通测延迟，见
  ///   direct_ping.dart），不为测速启动核心；
  /// - 开关开着但探活失败（控制接口无响应或出站拨测失败）：
  ///   改走直连探测，但横幅写明原因（见 [_speedTestMode]），
  ///   不静默切换。
  /// 两种口径不同，不能直接比（口径记在 [NodesState.speedTestDirect]，
  /// 节点页按它写提示）。测到的写进节点的 [Node.latencyMs]；测不到的
  /// 标 [Node.latencyFailed]、原因写 [Node.latencyFailureReason]
  /// （超时不可达 vs 其他连接失败），不丢节点。
  /// 正在测速时再点直接返回，不开第二轮。
  Future<bool> testAllSpeeds() async {
    if (state.nodes.isEmpty || state.testingSpeed) return false;
    final (direct, fallbackNotice) = _speedTestMode();
    _ensureRetestTimer();
    final nodes = state.nodes;
    for (final node in nodes) {
      node.latencyMs = null;
      node.latencyFailed = false;
      node.latencyFailureReason = null;
    }
    state = state.copyWith(
      nodes: List.of(nodes),
      testingSpeed: true,
      speedTestedCount: 0,
      speedTestTotal: nodes.length,
      speedTestError: fallbackNotice,
      speedTestDirect: direct,
      speedTestDirectFallback: fallbackNotice != null,
    );
    var tested = 0;
    // 预热（2026-11-26 0.1.2 根因 B）：开批前先对当前默认出站
    // （selector `Proxy`）做一次拨测，把冷拨号的首次握手＋落地
    // 解析＋TLS 提前暖起来，后面的单节点测速就不用全走冷链路。
    // 只在走代理口径时做；预热失败不阻塞测速，只记一行日志。
    if (!direct) {
      final api = ref.read(clashApiClientProvider);
      final warmup = await api.proxyDelayDetailed(
        'Proxy',
        timeout: _speedTestTimeout,
      );
      debugPrint(
        '[NodesNotifier] 测速预热 Proxy：delay=${warmup.delay} '
        'failure=${warmup.failure}',
      );
    }
    for (var i = 0; i < nodes.length; i += _speedTestConcurrency) {
      final batch = nodes.skip(i).take(_speedTestConcurrency).toList();
      await Future.wait(
        batch.map((node) async {
          await _testOneNode(node, nodes, direct: direct);
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

  /// 只测一个节点（节点行延迟芯片点一下触发）。
  ///
  /// 复用 [_testOneNode] 与一键测速同一套逻辑与超时：只改这一行的
  /// 延迟/失败标记，不碰其他行、不重排列表；测速中只这一行的芯片
  /// 转圈。开关关着时走直连探测，不为测速启动核心；
  /// 开关开着且探活通过时走 Clash API；开关开着但探活失败时改走
  /// 直连探测并写横幅提示（见 [_speedTestMode]）。一键测速进行中、
  /// 或已有单节点在测时直接返回 false（两轮测速不打架）；
  /// 后台重测定时器不由单测启动。
  Future<bool> testSingleSpeed(Node node) async {
    if (state.nodes.isEmpty ||
        state.testingSpeed ||
        state.testingSingleNodeKey != null) {
      return false;
    }
    final (direct, fallbackNotice) = _speedTestMode();
    final nodes = state.nodes;
    node.latencyMs = null;
    node.latencyFailed = false;
    node.latencyFailureReason = null;
    state = state.copyWith(
      nodes: List.of(nodes),
      testingSingleNodeKey: node.dedupKey,
      speedTestDirect: direct,
      speedTestDirectFallback: fallbackNotice != null,
      speedTestError: fallbackNotice,
    );
    await _testOneNode(node, nodes, direct: direct);
    state = state.copyWith(
      nodes: List.of(nodes),
      testingSingleNodeKey: null,
      speedTestAt: DateTime.now(),
    );
    return true;
  }

  /// 测一个节点的延迟，测到的写进 [Node.latencyMs]，测不到的标
  /// [Node.latencyFailed]、原因写 [Node.latencyFailureReason]。
  ///
  /// - [direct] 为 true（开关关着，或开关开着但探活失败改走直连）：
  ///   直连探测节点地址，不看配置里有没有这个出站（grpc 等暂不
  ///   支持进配置的节点也能测连通性）；
  /// - [direct] 为 false（开关开着）：调 Clash API delay 接口；
  ///   配置里根本没有这个出站（未知协议、缺 UUID、grpc 等）时
  ///   不调接口，直接标失败。失败原因按 Clash API 的回码分
  ///   （404 没有这个出站、408/504 超时、503 拨号失败、连不上是
  ///   核心没有响应），不要只标失败不写原因。
  Future<void> _testOneNode(
    Node node,
    List<Node> nodes, {
    required bool direct,
  }) async {
    if (direct) {
      final probe = ref.read(directProbeProvider);
      final result = await probe(
        node.address,
        node.port,
        timeout: _speedTestTimeout,
      );
      if (result.isReachable) {
        node.latencyMs = result.latencyMs;
      } else {
        node.latencyFailed = true;
        node.latencyFailureReason = result.failure?.label;
      }
      return;
    }
    final tag = SingboxConfigBuilder.tagForNode(nodes, node);
    if (tag == null) {
      node.latencyFailed = true;
      node.latencyFailureReason = '暂不支持测速';
      return;
    }
    final api = ref.read(clashApiClientProvider);
    // 计时（2026-11-26 0.1.2 根因 A）：REALITY 节点 1 秒内就
    // 503，说明握手根本没建起来（核心版本问题），不是节点慢。
    final stopwatch = Stopwatch()..start();
    var result = await api.proxyDelayDetailed(
      tag,
      timeout: _speedTestTimeout,
    );
    // 只在超时失败时重试一次（立即重试）：冷拨号一次丢包就越线，
    // 第二次往往能通；快速 503（拨号失败）不重试——重试也一样失败。
    if (result.failure == ProxyDelayFailure.timeout) {
      result = await api.proxyDelayDetailed(
        tag,
        timeout: _speedTestTimeout,
      );
    }
    stopwatch.stop();
    if (result.delay == null) {
      node.latencyFailed = true;
      node.latencyFailureReason = switch (result.failure) {
        ProxyDelayFailure.notFound => '节点不在运行配置里',
        ProxyDelayFailure.timeout => '超时不可达',
        ProxyDelayFailure.apiUnreachable => '核心没有响应',
        // REALITY 节点 1 秒内就 503：握手瞬间被拒，极可能是
        // sing-box 1.14.4 的 REALITY ClientHello 缺
        // X25519MLKEM768 份额（sing-box#4520），不是节点慢。
        ProxyDelayFailure.failed
            when node.realityPublicKey != null &&
                stopwatch.elapsed < const Duration(seconds: 1) =>
          'REALITY 握手失败（核心版本问题，可能）',
        _ => '连接失败',
      };
    } else {
      node.latencyMs = result.delay;
    }
  }

  /// 自动选择：延迟最低的可用节点。
  ///
  /// 还没测过时先测一轮再选；已有结果直接选，省时间。
  /// 全部测速失败时不选，原因写进 [NodesState.selectionReason]。
  /// 选上后打开自动选择开关（后台每 5 分钟重测，仅已连接时）。
  /// 直连测速时配置里没有出站的节点（如 grpc）也能测到延迟，但它
  /// 选不了：候选只取“测到了＋配置里有出站”的节点。
  Future<bool> autoSelect() async {
    if (state.nodes.isEmpty) return false;
    if (!state.nodes.any((n) => n.latencyMs != null)) {
      final ok = await testAllSpeeds();
      if (!ok) return false;
    }
    final candidates = state.nodes
        .where((n) => n.latencyMs != null)
        .where(
          (n) => SingboxConfigBuilder.tagForNode(state.nodes, n) != null,
        )
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
    // 口径写清楚：直连延迟与代理延迟不能直接比，别让用户拿关着测的
    // 数去跟开着测的数比高低。
    final mode = state.speedTestDirect ? '直连延迟' : '代理延迟';
    final reason = '已选 ${best.name}：延迟最低 ${best.latencyMs}ms'
        '（$mode，共测 ${state.nodes.length} 个，$failed 个失败）';
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
  ///
  /// 切换认的是节点在 selector 里占的那一位 tag（见
  /// [SingboxConfigBuilder.selectorTagForNode]）：成组节点（同名
  /// 多入站）切的是组 tag，拿自身 tag 去 PUT 时 Clash API 回 400，
  /// 不是核心没响应——失败原因要分清这两者。
  /// PUT 成功后读回 `now` 确认：读不到不推翻 PUT 的结果，只在读回
  /// 的名字明确不是要切的节点时才报失败。
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
    final tag = SingboxConfigBuilder.selectorTagForNode(nodes, node);
    if (tag == null) {
      state = state.copyWith(selectionReason: '该节点暂不支持，无法选择');
      return false;
    }
    final core = ref.read(coreServiceProvider);
    if (core.status == CoreStatus.started) {
      final api = ref.read(clashApiClientProvider);
      final switched = await api.selectProxyDetailed('Proxy', tag);
      if (!switched.ok) {
        state = state.copyWith(
          selectionReason: switch (switched.failure) {
            ProxySelectFailure.notInGroup => '切换失败，节点不在运行配置里',
            ProxySelectFailure.apiUnreachable => '切换失败，核心没有响应',
            _ => '切换失败，核心拒绝了切换',
          },
        );
        return false;
      }
      final now = await api.selectedProxy('Proxy');
      if (now != null && now != tag) {
        state = state.copyWith(selectionReason: '切换失败，核心未确认切换');
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
