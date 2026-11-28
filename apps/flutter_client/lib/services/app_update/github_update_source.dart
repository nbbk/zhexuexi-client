import 'package:dio/dio.dart';

import 'semver.dart';
import 'update_http.dart';
import 'update_source.dart';

/// GitHub 通道：调公开仓最新 Release 取 arm64 APK。
///
/// - 接口：`GET https://api.github.com/repos/nbbk/zhexuexi-client/releases/latest`
///   （公开仓，不用鉴权；未鉴权限流 60 次/小时，启动时查一次够用）。
/// - APK 资产名按 CI（`.github/workflows/build.yml`，`--split-per-abi`）
///   的产物名匹配：`app-arm64-v8a-release.apk`（精确匹配优先；
///   兜底匹配以 `-arm64-v8a-release.apk` 结尾的资产，防包名前缀改名）。
/// - 校验值取同名 `.sha256` 资产（CI 里每个 APK 都带一个同名
///   `.sha256` 文件，内容是 hash 单行，也可能写成 `hash  文件名`
///   两列，都只取第一列）；没有该资产时 [UpdateReleaseInfo.sha256]
///   为 null，下载后须让用户决定是否继续，不悄悄跳过校验。
///
/// Windows 分支（0.1.22，`windows: true`）：同一接口、不下 APK。
/// 取 `windows-<版本号>.zip` 资产的下载地址给界面在浏览器里打开
/// （拿不到 zip 资产时给 Release 页地址）；不拉 `.sha256`、不校验，
/// 用户在浏览器里自己下载。版本号比对与代理回落与安卓同一套。
///
/// 注意（发版前置条件）：CI 现在只把 APK 上传为 Actions 产物，
/// 不建 GitHub Release；`releases/latest` 在有人把 APK 挂到 Release
/// 上之前会 404，更新器会如实报“GitHub 上还没有 Release”。
/// 发版时须把 `app-arm64-v8a-release.apk` 与同名 `.sha256` 挂到
/// Release 上（见 docs/release-checklist.md §2）。
class GitHubUpdateSource implements UpdateSource {
  /// [http] 不给时用 [dio] 当直连 Dio（核心没开、或测试注入 fake
  /// Dio 时走这条；生产由 provider 传配好代理的 [UpdateHttp]）。
  /// 查版与 .sha256 拉取都走 [UpdateHttp]：核心开着先走本机
  /// 127.0.0.1:2080 代理，代理不通回落直连（见 [UpdateHttp]）。
  /// [windows] 为真时走 Windows 分支（取 zip 下载链接、不下载）。
  GitHubUpdateSource({UpdateHttp? http, Dio? dio, this.windows = false})
      : _http = http ??
            UpdateHttp(coreRunning: () => false, directDio: dio);

  final UpdateHttp _http;

  /// Windows 分支开关（provider 按 Platform.isWindows 传；测试注入）。
  final bool windows;

  static const String repoOwner = 'nbbk';
  static const String repoName = 'zhexuexi-client';

  /// CI 产出的 arm64 APK 文件名。
  static const String arm64ApkName = 'app-arm64-v8a-release.apk';

  /// Release 页地址（Windows 分支拿不到 zip 资产时的兜底下载链接）。
  static const String releasesPageUrl =
      'https://github.com/nbbk/zhexuexi-client/releases/latest';

  static const Duration requestTimeout = Duration(seconds: 10);

  @override
  String get name => 'GitHub';

  @override
  Future<UpdateReleaseInfo> checkLatest() async {
    final Map<String, dynamic> json;
    try {
      final response = await _http.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$repoOwner/$repoName/releases/latest',
        options: Options(
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'zhexuexi-client',
          },
          sendTimeout: requestTimeout,
          receiveTimeout: requestTimeout,
        ),
      );
      if (response.statusCode != 200 || response.data == null) {
        throw const UpdateException.notFound('GitHub 上还没有发布新版本。');
      }
      json = response.data!;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw const UpdateException.notFound(
          'GitHub 上还没有 Release（发版时须把 APK 挂到 Release 上）。',
        );
      }
      throw UpdateException.network('连不上 GitHub：${_dioErrorReason(e)}');
    } on UpdateException {
      rethrow;
    } catch (e) {
      throw UpdateException.network('连不上 GitHub：$e');
    }
    if (windows) {
      // Windows 分支：只取版本号＋下载链接，不拉 .sha256、不校验。
      final info = parseReleaseJsonWindows(json);
      if (info == null) {
        throw const UpdateException.parse(
          'GitHub Release 里没有找到 Windows 版本信息。',
        );
      }
      return info;
    }
    final info = parseReleaseJson(json);
    if (info == null) {
      throw const UpdateException.parse(
        'GitHub Release 里没有找到 arm64 安装包。',
      );
    }
    // .sha256 资产有地址时拉一次文本（很小，10 秒超时）；
    // 拉不到、格式不对都不阻断查版，校验值按“没给”处理，
    // 下载完如实告诉用户，由用户决定是否继续安装。
    if (info.sha256Url != null) {
      final sha = await _fetchSha256(info.sha256Url!);
      if (sha != null) {
        return UpdateReleaseInfo(
          version: info.version,
          downloadUrl: info.downloadUrl,
          sha256: sha,
          sha256Url: info.sha256Url,
          releaseNotes: info.releaseNotes,
          sourceName: info.sourceName,
        );
      }
    }
    return info;
  }

  Future<String?> _fetchSha256(String url) async {
    try {
      final response = await _http.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          sendTimeout: requestTimeout,
          receiveTimeout: requestTimeout,
        ),
      );
      if (response.statusCode != 200 || response.data == null) return null;
      return parseSha256Text(response.data!);
    } catch (_) {
      return null;
    }
  }

  /// 从 `/releases/latest` 的 JSON 解析出版本信息（纯函数，可单测，
  /// 不碰网络）。没找到 arm64 APK 资产时返回 null。
  static UpdateReleaseInfo? parseReleaseJson(Map<String, dynamic> json) {
    final tag = json['tag_name'] as String?;
    if (tag == null || tag.isEmpty) return null;
    final assets = json['assets'];
    if (assets is! List) return null;
    Map<String, dynamic>? apkAsset;
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      final name = asset['name'] as String?;
      if (name == null) continue;
      if (name == arm64ApkName) {
        apkAsset = asset;
        break;
      }
      if (apkAsset == null && name.endsWith('-arm64-v8a-release.apk')) {
        apkAsset = asset;
      }
    }
    if (apkAsset == null) return null;
    final downloadUrl = apkAsset['browser_download_url'] as String?;
    if (downloadUrl == null || downloadUrl.isEmpty) return null;
    final apkName = apkAsset['name'] as String;
    String? sha256Url;
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      if (asset['name'] == '$apkName.sha256') {
        final url = asset['browser_download_url'] as String?;
        if (url != null && url.isNotEmpty) sha256Url = url;
        break;
      }
    }
    return UpdateReleaseInfo(
      version: normalizeSemver(tag),
      downloadUrl: downloadUrl,
      sha256Url: sha256Url,
      releaseNotes: json['body'] as String? ?? '',
      sourceName: 'GitHub',
    );
  }

  /// Windows 分支（0.1.22）：从 `/releases/latest` 的 JSON 解析出
  /// 版本信息（纯函数，可单测，不碰网络）。不找 APK，只找 Windows
  /// zip 资产：`windows-<版本号>.zip` 精确匹配优先，兜底匹配
  /// `windows-*.zip`；都没有时下载链接给 Release 页地址（用户
  /// 自己在页上找 zip 下）。tag 缺失时返回 null。
  /// 返回的 [UpdateReleaseInfo] 一律 `openExternally: true`，
  /// sha256/sha256Url 恒为 null（不下载、不校验）。
  static UpdateReleaseInfo? parseReleaseJsonWindows(
    Map<String, dynamic> json,
  ) {
    final tag = json['tag_name'] as String?;
    if (tag == null || tag.isEmpty) return null;
    final version = normalizeSemver(tag);
    final assets = json['assets'];
    String? zipUrl;
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map<String, dynamic>) continue;
        if (asset['name'] == 'windows-$version.zip') {
          final url = asset['browser_download_url'] as String?;
          if (url != null && url.isNotEmpty) {
            zipUrl = url;
            break;
          }
        }
      }
      zipUrl ??= () {
        for (final asset in assets) {
          if (asset is! Map<String, dynamic>) continue;
          final name = asset['name'] as String?;
          if (name == null) continue;
          if (name.startsWith('windows-') && name.endsWith('.zip')) {
            final url = asset['browser_download_url'] as String?;
            if (url != null && url.isNotEmpty) return url;
          }
        }
        return null;
      }();
    }
    return UpdateReleaseInfo(
      version: version,
      downloadUrl: zipUrl ?? releasesPageUrl,
      openExternally: true,
      releaseNotes: json['body'] as String? ?? '',
      sourceName: 'GitHub',
    );
  }

  /// 解析下载到的 `.sha256` 文件文本：取第一列，须是 64 位 hex，
  /// 否则返回 null（当作没给校验值，不拿脏值去比对）。
  static String? parseSha256Text(String text) {
    final first = text.trim().split(RegExp(r'\s+')).firstOrNull;
    if (first == null) return null;
    final hex = first.toLowerCase();
    if (hex.length != 64 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
      return null;
    }
    return hex;
  }

  static String _dioErrorReason(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '连接超时';
    }
    if (e.type == DioExceptionType.connectionError) return '网络不通';
    final code = e.response?.statusCode;
    if (code == 403) return 'GitHub 限流（未鉴权每小时 60 次），请稍后再试';
    if (code != null) return 'GitHub 返回 $code';
    return e.message ?? e.toString();
  }
}
