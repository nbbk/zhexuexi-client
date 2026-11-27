import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/core_provider.dart';
import '../../core/singbox_core.dart';
import '../lan_proxy_notifier.dart';
import '../remote_config_notifier.dart';
import 'app_updater.dart';
import 'github_update_source.dart';
import 'self_hosted_update_source.dart';
import 'update_http.dart';
import 'update_source.dart';

/// 更新器（可注入 fake 做测试）：主通道 GitHub，备通道自托管。
/// 自托管的两个配置位读远程配置（见 `RemoteConfig` 的
/// `updateServerBaseUrl` / `updateVersionPath`）；远程配置更新后
/// 更新器跟着重建，不用重启客户端。
///
/// 更新下载走代理（0.1.16）：GitHub 查版与 APK 下载共用一个
/// [UpdateHttp]——核心开着先走本机 127.0.0.1:2080 代理，代理不通
/// 回落直连，核心没开直接直连。端口与鉴权从局域网代理设置取
/// （端口可改；鉴权开着时 mixed 入站要账号密码），设置变了更新
/// 器跟着重建。备通道自托管不走这个（它的服务器地址是运营方配
/// 的，不一定在公网），仍直连。
final appUpdaterProvider = Provider<AppUpdater>((ref) {
  final config = ref.watch(remoteConfigProvider).config;
  final lan = ref.watch(lanProxyProvider);
  final http = UpdateHttp(
    coreRunning: () =>
        ref.read(coreServiceProvider).status == CoreStatus.started,
    proxyPort: lan.port,
    proxyCredentials: lan.authCredentials,
  );
  return AppUpdater(
    sources: [
      GitHubUpdateSource(http: http),
      SelfHostedUpdateSource(
        baseUrl: config.updateServerBaseUrl,
        versionPath: config.updateVersionPath,
      ),
    ],
    http: http,
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
    this.pendingReady = false,
    this.pendingVersion,
    this.fromManualCheck = false,
  });

  final AppUpdateStatus status;

  /// 有新版时才有值（弹窗用它）。
  final UpdateReleaseInfo? latest;

  /// 已是最新时本机版本号（设置页手动查的提示用）。
  final String? currentVersion;

  /// 失败时的原因 / 已是最新时的说明（设置页手动查的提示用）。
  final String? message;

  final DateTime? lastCheckedAt;

  /// 有新版且安装包已下载好、校验通过（设置页行上显示
  /// “已下载 vX.Y.Z，点击安装”，点一下直接调安装，不用重下）。
  final bool pendingReady;

  /// 待安装的版本号（pendingReady 为真时才有值）。
  final String? pendingVersion;

  /// 这次 available 是不是设置页手动查出来的（是的话由设置页
  /// 自己弹更新弹窗，main.dart 的监听不再弹，不连弹两个）。
  final bool fromManualCheck;

  AppUpdateState copyWith({
    AppUpdateStatus? status,
    UpdateReleaseInfo? latest,
    String? currentVersion,
    String? message,
    DateTime? lastCheckedAt,
    bool? pendingReady,
    String? pendingVersion,
    bool? fromManualCheck,
  }) {
    return AppUpdateState(
      status: status ?? this.status,
      latest: latest ?? this.latest,
      currentVersion: currentVersion ?? this.currentVersion,
      message: message ?? this.message,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      pendingReady: pendingReady ?? this.pendingReady,
      pendingVersion: pendingVersion ?? this.pendingVersion,
      fromManualCheck: fromManualCheck ?? this.fromManualCheck,
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

  /// 查到新版时已下载好的安装包（校验通过的待安装包；没有时为 null）。
  /// 设置页与 main.dart 的监听用它直接调安装，不用重下。
  DownloadedApk? _pendingApk;

  /// 同上（只读）。
  DownloadedApk? get pendingApk => _pendingApk;

  /// 启动时安静查一次：绝不抛错，失败只记状态，不弹框。
  Future<void> checkQuiet() async {
    final result = await checkManual(manual: false);
    // 安静规则：只有“有新版”才留状态给界面弹提示；其余状态
    // （已是最新/失败）不留给界面，避免启动时弹错误框打扰用户。
    if (result.status != AppUpdateCheckStatus.available) {
      state = const AppUpdateState(lastCheckedAt: null);
    }
  }

  /// 只刷新待安装状态（不查版）：设置页打开时调，行上直接显示
  /// “已下载 vX.Y.Z，点击安装”。读记录失败不阻断设置页，
  /// 只是不显示“已下载”。
  Future<void> refreshPending() async {
    try {
      final updater = ref.read(appUpdaterProvider);
      final record = await updater.pendingRecord();
      if (record == null) {
        _pendingApk = null;
        if (state.pendingReady) {
          state = AppUpdateState(
            status: state.status,
            latest: state.latest,
            currentVersion: state.currentVersion,
            message: state.message,
            lastCheckedAt: state.lastCheckedAt,
            fromManualCheck: state.fromManualCheck,
          );
        }
        return;
      }
      final apk = await updater.pendingInstall();
      _pendingApk = apk;
      state = AppUpdateState(
        status: state.status,
        latest: state.latest,
        currentVersion: state.currentVersion,
        message: state.message,
        lastCheckedAt: state.lastCheckedAt,
        pendingReady: apk != null,
        pendingVersion: apk != null ? record.version : null,
        fromManualCheck: state.fromManualCheck,
      );
    } catch (_) {
      // 读记录失败不阻断设置页，只是不显示“已下载”。
    }
  }

  /// 查一次新版（手动入口与安静检查共用）：正在查时再调直接返回
  /// 上次的结果，不开第二轮。
  Future<AppUpdateCheckResult> checkManual({bool manual = true}) async {
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
      // 先清掉旧的待安装包；available 分支有待安装包时再填。
      _pendingApk = null;
      state = switch (result.status) {
        AppUpdateCheckStatus.available => await _availableState(
            result,
            updater,
            manual,
          ),
        AppUpdateCheckStatus.upToDate => AppUpdateState(
            status: AppUpdateStatus.upToDate,
            currentVersion: result.currentVersion,
            message:
                '已是最新版本（v${result.currentVersion}，${result.sourceName} 上最新也是 v${result.latestVersion}）。',
            lastCheckedAt: DateTime.now(),
            fromManualCheck: manual,
          ),
        AppUpdateCheckStatus.failed => AppUpdateState(
            status: AppUpdateStatus.failed,
            message: result.failureMessage,
            lastCheckedAt: DateTime.now(),
            fromManualCheck: manual,
          ),
      };
      return result;
    } finally {
      _checking = false;
    }
  }

  /// 有新版时的状态：先看待安装记录——安装包已下载好、校验通过
  /// 时直接给安装入口，不用重下。
  Future<AppUpdateState> _availableState(
    AppUpdateCheckResult result,
    AppUpdater updater,
    bool manual,
  ) async {
    DownloadedApk? pending;
    try {
      pending = await updater.pendingInstall();
    } catch (_) {
      pending = null;
    }
    _pendingApk = pending;
    return AppUpdateState(
      status: AppUpdateStatus.available,
      latest: result.latest,
      lastCheckedAt: DateTime.now(),
      pendingReady: pending != null,
      pendingVersion: pending != null ? result.latest!.version : null,
      fromManualCheck: manual,
    );
  }
}

final appUpdateProvider =
    NotifierProvider<AppUpdateNotifier, AppUpdateState>(
  AppUpdateNotifier.new,
);
