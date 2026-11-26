import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote_config_notifier.dart';
import 'app_updater.dart';
import 'github_update_source.dart';
import 'self_hosted_update_source.dart';
import 'update_source.dart';

/// 更新器（可注入 fake 做测试）：主通道 GitHub，备通道自托管。
/// 自托管的两个配置位读远程配置（见 `RemoteConfig` 的
/// `updateServerBaseUrl` / `updateVersionPath`）；远程配置更新后
/// 更新器跟着重建，不用重启客户端。
final appUpdaterProvider = Provider<AppUpdater>((ref) {
  final config = ref.watch(remoteConfigProvider).config;
  return AppUpdater(
    sources: [
      GitHubUpdateSource(),
      SelfHostedUpdateSource(
        baseUrl: config.updateServerBaseUrl,
        versionPath: config.updateVersionPath,
      ),
    ],
  );
});

/// 查版状态（启动安静查与设置页手动查共用）。
enum AppUpdateStatus { idle, checking, available, upToDate, failed }

class AppUpdateState {
  const AppUpdateState({
    this.status = AppUpdateStatus.idle,
    this.latest,
    this.currentVersion,
    this.message,
    this.lastCheckedAt,
  });

  final AppUpdateStatus status;

  /// 有新版时才有值（弹窗用它）。
  final UpdateReleaseInfo? latest;

  /// 已是最新时本机版本号（设置页手动查的提示用）。
  final String? currentVersion;

  /// 失败时的原因 / 已是最新时的说明（设置页手动查的提示用）。
  final String? message;

  final DateTime? lastCheckedAt;

  AppUpdateState copyWith({
    AppUpdateStatus? status,
    UpdateReleaseInfo? latest,
    String? currentVersion,
    String? message,
    DateTime? lastCheckedAt,
  }) {
    return AppUpdateState(
      status: status ?? this.status,
      latest: latest ?? this.latest,
      currentVersion: currentVersion ?? this.currentVersion,
      message: message ?? this.message,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    );
  }
}

/// 应用内更新的状态管理。
///
/// - 启动时 [checkQuiet]：安静查一次；无网络、已是最新、全部通道
///   失败时都不弹任何东西，只有查到新版才把状态置为 available，
///   由 main.dart 的监听弹一次提示。
/// - 设置页手动查 [checkManual]：返回结果，设置页按结果给提示
///   （已是最新 / 失败原因 / 有新版弹更新弹窗）。
class AppUpdateNotifier extends Notifier<AppUpdateState> {
  @override
  AppUpdateState build() => const AppUpdateState();

  bool _checking = false;
  AppUpdateCheckResult? _lastResult;

  /// 启动时安静查一次：绝不抛错，失败只记状态，不弹框。
  Future<void> checkQuiet() async {
    final result = await checkManual();
    // 安静规则：只有“有新版”才留状态给界面弹提示；其余状态
    // （已是最新/失败）不留给界面，避免启动时弹错误框打扰用户。
    if (result.status != AppUpdateCheckStatus.available) {
      state = const AppUpdateState(lastCheckedAt: null);
    }
  }

  /// 查一次新版（手动入口与安静检查共用）：正在查时再调直接返回
  /// 上次的结果，不开第二轮。
  Future<AppUpdateCheckResult> checkManual() async {
    if (_checking) {
      // 正在查时再调直接返回上次的结果，不开第二轮。
      return _lastResult ?? const AppUpdateCheckResult.failed([]);
    }
    _checking = true;
    state = state.copyWith(status: AppUpdateStatus.checking);
    try {
      final updater = ref.read(appUpdaterProvider);
      final result = await updater.checkLatest();
      _lastResult = result;
      state = switch (result.status) {
        AppUpdateCheckStatus.available => AppUpdateState(
            status: AppUpdateStatus.available,
            latest: result.latest,
            lastCheckedAt: DateTime.now(),
          ),
        AppUpdateCheckStatus.upToDate => AppUpdateState(
            status: AppUpdateStatus.upToDate,
            currentVersion: result.currentVersion,
            message:
                '已是最新版本（v${result.currentVersion}，${result.sourceName} 上最新也是 v${result.latestVersion}）。',
            lastCheckedAt: DateTime.now(),
          ),
        AppUpdateCheckStatus.failed => AppUpdateState(
            status: AppUpdateStatus.failed,
            message: result.failureMessage,
            lastCheckedAt: DateTime.now(),
          ),
      };
      return result;
    } finally {
      _checking = false;
    }
  }
}

final appUpdateProvider =
    NotifierProvider<AppUpdateNotifier, AppUpdateState>(
  AppUpdateNotifier.new,
);
