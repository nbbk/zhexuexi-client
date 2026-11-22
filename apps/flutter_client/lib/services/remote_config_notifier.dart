import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../brand/remote_config.dart';
import 'remote_config_service.dart';

/// 远程配置服务（可注入 fake 做测试）。
final remoteConfigServiceProvider = Provider<RemoteConfigService>(
  (ref) => RemoteConfigService(),
);

/// 当前生效的远程配置的状态。
class RemoteConfigState {
  const RemoteConfigState({
    required this.config,
    required this.source,
    this.lastCheckedAt,
    this.checking = false,
  });

  /// 生效的配置（fresh/cached 时是远程来的，bundled 时是包内默认值）。
  final RemoteConfig config;

  /// 这份配置怎么来的（见 [RemoteConfigSource]）。
  final RemoteConfigSource source;

  /// 上次检查远程配置的时间（手动/自动刷新成功或失败都记）。
  final DateTime? lastCheckedAt;

  /// 是否正在拉远程配置。
  final bool checking;

  /// 正在用本地缓存（配置中心连不上时）：首页给一句提示，不静默。
  bool get offline => source == RemoteConfigSource.cached;

  /// 是否到了强制更新的地步（配置要求强制更新，且当前版本低于最低版本）。
  bool get forceUpdateRequired => config.forceUpdateRequired;

  RemoteConfigState copyWith({
    RemoteConfig? config,
    RemoteConfigSource? source,
    DateTime? lastCheckedAt,
    bool? checking,
  }) {
    return RemoteConfigState(
      config: config ?? this.config,
      source: source ?? this.source,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      checking: checking ?? this.checking,
    );
  }
}

/// 生效配置的来源。
enum RemoteConfigSource {
  /// 上次拉取成功（配置是最新的，或已确认本地缓存就是最新）。
  fresh,

  /// 拉取失败，正在用本地缓存的最后一份好配置。
  cached,

  /// 本地无缓存、远程也拉不到，用包内默认值（全新安装首次失败时）。
  bundled,
}

/// 远程配置的状态管理（切片 7）。
///
/// 启动时 [init]：先读本地缓存（验签通过的最后一份好配置）立刻生效，
/// 再后台拉一次远程；拉到新版就换上并存缓存，拉不到保持缓存并在首页
/// 提示一句。设置页“检查更新”与这里共用同一个 [refresh]。
class RemoteConfigNotifier extends Notifier<RemoteConfigState> {
  @override
  RemoteConfigState build() {
    return RemoteConfigState(
      config: RemoteConfig.defaults(),
      source: RemoteConfigSource.bundled,
    );
  }

  bool _refreshing = false;

  /// App 启动时调一次：缓存先行，后台再拉。
  Future<void> init() async {
    final service = ref.read(remoteConfigServiceProvider);
    final cached = await service.loadCached();
    if (cached != null) {
      state = state.copyWith(
        config: cached,
        source: RemoteConfigSource.cached,
      );
    }
    await refresh();
  }

  /// 刷新一次远程配置，返回刷新结果（设置页“检查更新”按结果给提示）。
  /// 正在刷时再调直接返回上次的结果，不开第二轮。
  Future<RemoteConfigRefreshResult> refresh() async {
    if (_refreshing) {
      return RemoteConfigRefreshResult(
        status: state.source == RemoteConfigSource.cached
            ? RemoteConfigRefreshStatus.offlineCached
            : RemoteConfigRefreshStatus.upToDate,
        config: state.config,
      );
    }
    _refreshing = true;
    state = state.copyWith(checking: true);
    try {
      final service = ref.read(remoteConfigServiceProvider);
      final result = await service.refresh();
      final source = switch (result.status) {
        RemoteConfigRefreshStatus.updated ||
        RemoteConfigRefreshStatus.upToDate =>
          RemoteConfigSource.fresh,
        RemoteConfigRefreshStatus.offlineCached =>
          RemoteConfigSource.cached,
        RemoteConfigRefreshStatus.failed => RemoteConfigSource.bundled,
      };
      state = RemoteConfigState(
        config: result.config,
        source: source,
        lastCheckedAt: DateTime.now(),
        checking: false,
      );
      return result;
    } finally {
      _refreshing = false;
      if (state.checking) {
        state = state.copyWith(checking: false);
      }
    }
  }
}

/// 全项目共用的远程配置（品牌、订阅地址、面板域名、公告、功能开关
/// 都读它；界面、订阅、公告都以它为准，不各读各的）。
final remoteConfigProvider =
    NotifierProvider<RemoteConfigNotifier, RemoteConfigState>(
  RemoteConfigNotifier.new,
);
