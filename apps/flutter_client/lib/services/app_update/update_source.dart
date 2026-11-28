/// 应用内更新：更新源抽象（双通道一次设计到位）。
///
/// 两个实现：
/// - [GitHubUpdateSource]：本轮实现，走公开仓 Release；
/// - [SelfHostedUpdateSource]：本轮只留空实现，未启用时如实报
///   [UpdateFailureKind.notEnabled]，不假装能用。
///
/// 更新器按顺序查：主通道查不到/下不了才走备通道；任一通道成功
/// （哪怕结论是“已是最新”）即停，不再试下一个。
library;

/// 一条更新源查到的新版本信息。
class UpdateReleaseInfo {
  const UpdateReleaseInfo({
    required this.version,
    required this.downloadUrl,
    this.sha256,
    this.sha256Url,
    this.releaseNotes = '',
    required this.sourceName,
    this.openExternally = false,
  });

  /// 已去 `v` 前缀的版本号（如 `1.0.0`、`1.0.0-beta.1`）。
  final String version;

  /// 安装包下载地址。
  final String downloadUrl;

  /// APK 的 SHA-256（小写 hex）；为 null 表示该源没提供校验值，
  /// 下载后须如实告诉用户“无校验值”，由用户决定是否继续安装。
  final String? sha256;

  /// 校验值文件的下载地址（GitHub 通道是同名 `.sha256` 资产）；
  /// 查版时拉到文本后填进 [sha256]，拉不到时 [sha256] 保持 null。
  final String? sha256Url;

  /// Release 说明原文（弹窗里截断显示）。
  final String releaseNotes;

  /// 来源名（`GitHub` / `自托管`），报错与日志里写明走的是哪条通道。
  final String sourceName;

  /// Windows 分支（0.1.22）：不下载、不安装，只给下载链接，
  /// 界面在浏览器里打开它。为 true 时 [downloadUrl] 是下载页
  /// 地址（优先 Windows zip 资产，拿不到时是 Release 页），
  /// [sha256] 与 [sha256Url] 恒为 null；更新器的 download()
  /// 收到这种信息直接报“不支持”，不走应用内下载。
  final bool openExternally;
}

/// 更新失败的原因分类（报错文案按它区分，不笼统说“失败”）。
enum UpdateFailureKind {
  /// 该通道尚未启用/尚未实现（自托管本轮就是这一类）。
  notEnabled,

  /// 无网络、超时、DNS 失败等。
  network,

  /// 该源上没有找到新版本信息（如 GitHub 上还没有 Release）。
  notFound,

  /// 源返回的内容解析不了。
  parse,

  /// 下载失败（断网、404、写盘失败等）。
  download,

  /// SHA-256 对不上（绝不安装）。
  checksum,

  /// 调起系统安装失败。
  install,

  /// 当前平台不支持应用内安装（本轮只接 Android）。
  unsupported,
}

/// 更新流程里抛出的错：带分类与人话原因，调用方按分类给提示。
class UpdateException implements Exception {
  const UpdateException(this.kind, this.message);

  const UpdateException.notEnabled(String message)
      : this(UpdateFailureKind.notEnabled, message);

  const UpdateException.network(String message)
      : this(UpdateFailureKind.network, message);

  const UpdateException.notFound(String message)
      : this(UpdateFailureKind.notFound, message);

  const UpdateException.parse(String message)
      : this(UpdateFailureKind.parse, message);

  const UpdateException.download(String message)
      : this(UpdateFailureKind.download, message);

  const UpdateException.checksum(String message)
      : this(UpdateFailureKind.checksum, message);

  const UpdateException.install(String message)
      : this(UpdateFailureKind.install, message);

  const UpdateException.unsupported(String message)
      : this(UpdateFailureKind.unsupported, message);

  final UpdateFailureKind kind;

  /// 给用户看的原因（一句话，不带堆栈）。
  final String message;

  @override
  String toString() => 'UpdateException($kind): $message';
}

/// 更新源接口：查最新版 + 下安装包由更新器编排，这里只定义查版。
abstract class UpdateSource {
  /// 通道名（`GitHub` / `自托管`）。
  String get name;

  /// 查该源的最新版：有就返回版本信息；查不到按情况抛
  /// [UpdateException]（未启用 / 无网络 / 没找到 / 解析失败）。
  /// 注意：这里只返回源上的最新版，“比本机新还是旧”由更新器比对。
  Future<UpdateReleaseInfo> checkLatest();
}
