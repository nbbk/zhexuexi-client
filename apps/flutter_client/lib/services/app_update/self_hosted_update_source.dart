import 'update_source.dart';

/// 自托管通道（本轮只留空实现，不接线）。
///
/// 配置位在远程配置里（`RemoteConfig.updateServerBaseUrl` /
/// `updateVersionPath`，见 `lib/brand/remote_config.dart`）：
/// - `updateServerBaseUrl`：自托管更新服务器基地址，
///   如 `https://update.example.com`；
/// - `updateVersionPath`：版本描述接口路径，
///   如 `/api/v1/client/version`，以后自托管服务端须按
///   `GitHubUpdateSource.parseReleaseJson` 同款字段回
///   `{version, download_url, sha256, release_notes}`。
///
/// 基地址没配、或配了，都抛“尚未启用”：本轮只留配置位与接口，
/// 不发任何请求，不假装能用。以后实现时把这里的抛错换成真请求，
/// 更新器与界面不用改。
class SelfHostedUpdateSource implements UpdateSource {
  SelfHostedUpdateSource({
    required this.baseUrl,
    required this.versionPath,
    this.enabled = false,
  });

  /// 自托管更新服务器基地址（远程配置 `update.server_base_url`）。
  final String baseUrl;

  /// 版本描述接口路径（远程配置 `update.version_path`）。
  final String versionPath;

  /// 预留的启用开关：本轮恒为 false（不接线）；以后服务端就绪后
  /// 由更新器按“基地址配了”置 true，再把 [checkLatest] 换成真请求。
  final bool enabled;

  @override
  String get name => '自托管';

  @override
  Future<UpdateReleaseInfo> checkLatest() async {
    throw const UpdateException.notEnabled(
      '自托管更新通道尚未启用（本轮只留配置位，未接线；国内用户'
      '没有外网时走这条通道，待服务端就绪后再启用）。',
    );
  }
}
