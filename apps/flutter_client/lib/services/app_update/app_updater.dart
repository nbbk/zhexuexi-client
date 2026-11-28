import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/app_version.dart';
import 'pending_update_store.dart';
import 'semver.dart';
import 'update_http.dart';
import 'update_source.dart';

/// 一次查版的结果。
class AppUpdateCheckResult {
  const AppUpdateCheckResult.available(this.latest)
      : status = AppUpdateCheckStatus.available,
        currentVersion = null,
        latestVersion = null,
        sourceName = null,
        failures = const [];

  const AppUpdateCheckResult.upToDate({
    required this.currentVersion,
    required this.latestVersion,
    required this.sourceName,
  })  : status = AppUpdateCheckStatus.upToDate,
        latest = null,
        failures = const [];

  const AppUpdateCheckResult.failed(this.failures)
      : status = AppUpdateCheckStatus.failed,
        latest = null,
        currentVersion = null,
        latestVersion = null,
        sourceName = null;

  final AppUpdateCheckStatus status;

  /// 有新版时才有值。
  final UpdateReleaseInfo? latest;

  /// 已是最新时本机版本号。
  final String? currentVersion;

  /// 已是最新时：源上的最新版本号与通道名。
  final String? latestVersion;
  final String? sourceName;

  /// 全部通道都失败时，每条通道的失败原因（按查的顺序）。
  final List<UpdateException> failures;

  /// 全部通道失败时的合并原因（给用户看，一行一条）。
  String get failureMessage =>
      failures.map((f) => '· ${f.message}').join('\n');
}

enum AppUpdateCheckStatus { available, upToDate, failed }

/// 下载好的安装包。
class DownloadedApk {
  const DownloadedApk({
    required this.file,
    required this.sha256Verified,
  });

  final File file;

  /// 是否已按源给的 SHA-256 核对通过；false 表示该源没给校验值，
  /// 安装前须让用户知情并决定是否继续（不要悄悄跳过校验）。
  final bool sha256Verified;
}

/// 调起系统安装的接口（可注入 fake 做测试；真机走 open_filex）。
abstract class AppInstaller {
  Future<void> installApk(File apk);
}

/// Android 安装：用 open_filex 调系统安装确认。
///
/// - APK 存在应用专属目录（不用存储权限），open_filex 自带的
///   FileProvider 覆盖 `files-path`，直接调 `ACTION_VIEW` 安装
///   intent；Android 8+ 须 `REQUEST_INSTALL_PACKAGES` 权限
///   （已在 `AndroidManifest.xml` 里补）。
/// - 侧载必须要点确认，做不到静默安装：这里只负责把安装界面调起来，
///   用户点“安装”才装、点“取消”就不装；`OpenFilex.open` 返回 done
///   只表示 intent 已发出，不表示已装好。
class OpenFilexAppInstaller implements AppInstaller {
  @override
  Future<void> installApk(File apk) async {
    if (!Platform.isAndroid) {
      throw const UpdateException.unsupported(
        '当前平台暂不支持应用内安装（本轮只接 Android）。',
      );
    }
    if (!await apk.exists()) {
      throw const UpdateException.install('安装包找不到了，请重新下载。');
    }
    final result = await OpenFilex.open(apk.path);
    if (result.type != ResultType.done) {
      throw UpdateException.install('调起系统安装失败：${result.message}');
    }
  }
}

/// 应用内更新器：按顺序查双通道 → 下载 → 核 SHA-256 → 调系统安装。
///
/// 查版规则：任一通道成功（哪怕结论是“已是最新”）即停，不再试
/// 下一个；只有失败（无网络 / 没找到 / 未启用 / 解析失败）才走
/// 下一个通道；全部失败时把每条通道的原因都带上，不静默失败。
class AppUpdater {
  /// [http] 不给时用 [dio] 当直连 Dio（核心没开、或测试注入 fake
  /// Dio 时走这条；生产由 provider 传配好代理的 [UpdateHttp]）。
  /// APK 下载走 [UpdateHttp]：核心开着先走本机 127.0.0.1:2080
  /// 代理，代理不通回落直连（见 [UpdateHttp]）；SHA-256 校验
  /// 不变，下载完照旧核对。
  AppUpdater({
    required this.sources,
    Dio? dio,
    UpdateHttp? http,
    AppInstaller? installer,
    Future<String> Function()? currentVersionReader,
    Future<Directory> Function()? downloadDir,
    PendingUpdateStore? pendingStore,
  })  : _http = http ??
            UpdateHttp(coreRunning: () => false, directDio: dio),
        _installer = installer ?? OpenFilexAppInstaller(),
        _currentVersionReader =
            currentVersionReader ?? _readPackageVersion,
        _downloadDir = downloadDir ?? _defaultDownloadDir,
        _pendingStore =
            pendingStore ?? SharedPreferencesPendingUpdateStore();

  final List<UpdateSource> sources;
  final UpdateHttp _http;
  final AppInstaller _installer;
  final Future<String> Function() _currentVersionReader;
  final Future<Directory> Function() _downloadDir;

  /// 待安装记录（下载完校验通过后持久化；弹窗关了也能重调安装）。
  final PendingUpdateStore _pendingStore;

  static Future<Directory> _defaultDownloadDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/updates');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 读本机版本号：优先 package_info_plus（与 pubspec 的 version
  /// 同步的 versionName）；读不到（如测试环境没插件）回退到编译进
  /// 代码的 [appVersion] 常量，不让查版因读不到版本而崩。
  /// 与关于页、诊断包同一源（见 [resolveAppVersion]）。
  static Future<String> _readPackageVersion() => resolveAppVersion();

  Future<String> currentVersion() => _currentVersionReader();

  /// 按顺序查各通道的最新版。
  Future<AppUpdateCheckResult> checkLatest() async {
    // 先对账：本机版本已追上待安装记录（装上了，或装了更新的版）
    // 时删包清记录，别长期占地方；对账失败不阻断查版。
    try {
      await reconcilePending();
    } catch (_) {}
    final current = await currentVersion();
    final failures = <UpdateException>[];
    for (final source in sources) {
      try {
        final info = await source.checkLatest();
        if (compareSemver(info.version, current) > 0) {
          // 出了更新的版本：旧待安装记录作废（删包清记录），
          // 以最新版为准；版本一致的记录留着（还能重调安装）。
          try {
            final record = await _pendingStore.read();
            if (record != null &&
                compareSemver(record.version, info.version) < 0) {
              await _discardPending(record);
            }
          } catch (_) {}
          return AppUpdateCheckResult.available(info);
        }
        return AppUpdateCheckResult.upToDate(
          currentVersion: current,
          latestVersion: info.version,
          sourceName: source.name,
        );
      } on UpdateException catch (e) {
        failures.add(
          UpdateException(e.kind, '${source.name}：${e.message}'),
        );
      } catch (e) {
        failures.add(
          UpdateException.network('${source.name}：检查失败：$e'),
        );
      }
    }
    return AppUpdateCheckResult.failed(failures);
  }

  /// 下载安装包（带进度回调，0.0–1.0；总大小未知时 onProgress 不调），
  /// 下完核 SHA-256：有校验值且对不上就删文件并抛错，绝不安装；
  /// 源没给校验值时返回 `sha256Verified: false`，由界面让用户决定。
  Future<DownloadedApk> download(
    UpdateReleaseInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    // Windows 分支（0.1.22）：这种信息只给下载链接，不走应用内下载。
    // 正常流程下 Windows 弹窗不会调 download，这里是防线——万一
    // 哪路误调了也别悄悄下一个 zip 回来当 APK 装。
    if (info.openExternally) {
      throw const UpdateException.unsupported(
        'Windows 版更新请在浏览器下载页手动下载，不走应用内下载。',
      );
    }
    final dir = await _downloadDir();
    final fileName = Uri.parse(info.downloadUrl).pathSegments.lastOrNull;
    final safeName = fileName != null && fileName.endsWith('.apk')
        ? fileName
        : 'app-arm64-v8a-release.apk';
    final file = File('${dir.path}/$safeName');
    try {
      await _http.download(
        info.downloadUrl,
        file.path,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
        options: Options(
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 10),
        ),
      );
    } on DioException catch (e) {
      throw UpdateException.download('下载失败：${_dioErrorReason(e)}');
    } catch (e) {
      throw UpdateException.download('下载失败：$e');
    }
    if (info.sha256 != null) {
      final actual = await _sha256Hex(file);
      if (actual != info.sha256!.toLowerCase()) {
        try {
          await file.delete();
        } catch (_) {}
        throw const UpdateException.checksum(
          '安装包校验没通过（SHA-256 对不上），已删除，不安装。',
        );
      }
      // 校验通过：把待安装记录持久化（版本号＋文件路径＋期望 SHA），
      // 弹窗关了、安装提示错过了也能在设置页重调安装，不用重下。
      // 存记录失败不阻断本次安装（本次弹窗里照样能装）。
      try {
        await _pendingStore.save(
          PendingUpdate(
            version: info.version,
            filePath: file.path,
            sha256: info.sha256!.toLowerCase(),
          ),
        );
      } catch (_) {}
      return DownloadedApk(file: file, sha256Verified: true);
    }
    return DownloadedApk(file: file, sha256Verified: false);
  }

  /// 调系统安装确认（用户须在系统界面点确认；做不到静默安装）。
  Future<void> install(DownloadedApk apk) => _installer.installApk(apk.file);

  /// 读待安装记录（不校验文件；给设置页刷新行状态用）。
  Future<PendingUpdate?> pendingRecord() => _pendingStore.read();

  /// 校验通过的待安装包（可直接调安装，不用重下）：
  /// - 没有记录 → null；
  /// - 版本已追上（已装上，或装了更新的版）→ 删包清记录，返回 null；
  /// - 文件没了 → 清记录，返回 null；
  /// - 重核 SHA 对不上 → 删包清记录，返回 null（坏包不留、不装）。
  Future<DownloadedApk?> pendingInstall() async {
    final record = await _pendingStore.read();
    if (record == null) return null;
    if (await _isInstalledOrNewer(record.version)) {
      await _discardPending(record);
      return null;
    }
    final file = File(record.filePath);
    if (!await file.exists()) {
      try {
        await _pendingStore.clear();
      } catch (_) {}
      return null;
    }
    final actual = await _sha256Hex(file);
    if (actual != record.sha256.toLowerCase()) {
      await _discardPending(record);
      return null;
    }
    return DownloadedApk(file: file, sha256Verified: true);
  }

  /// 对账：本机版本已追上待安装记录时删包清记录，别长期占地方。
  /// 查版开头调（启动安静查与设置页手动查都走这里）；更新还没装
  /// 上之前文件必须一直留着，不然“错过提示重装”就没法用。
  Future<void> reconcilePending() async {
    final record = await _pendingStore.read();
    if (record == null) return;
    if (await _isInstalledOrNewer(record.version)) {
      await _discardPending(record);
    }
  }

  /// 今天有没有提醒过装这个版本（启动提醒一天只弹一次用）。
  Future<bool> wasRemindedToday(String version) async {
    try {
      return await _pendingStore.remindedToday(version);
    } catch (_) {
      return false;
    }
  }

  /// 记下“今天已提醒过装这个版本”。
  Future<void> markRemindedToday(String version) async {
    try {
      await _pendingStore.markRemindedToday(version);
    } catch (_) {}
  }

  /// 本机版本是否已追上待安装记录的版本（相等＝已装上；
  /// 更大＝装了更新的版；两种情况下记录里的包都已无用）。
  Future<bool> _isInstalledOrNewer(String version) async {
    final current = await currentVersion();
    return compareSemver(current, version) >= 0;
  }

  /// 删待安装的 APK 文件＋清记录（各步都 best-effort，一步失败
  /// 不拦另一步）。
  Future<void> _discardPending(PendingUpdate record) async {
    try {
      final file = File(record.filePath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    try {
      await _pendingStore.clear();
    } catch (_) {}
  }

  /// 流式算文件 SHA-256（不整包读进内存）。
  static Future<String> _sha256Hex(File file) async {
    final sink = Sha256().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final digest = await sink.hash();
    return digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static String _dioErrorReason(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '连接超时';
    }
    if (e.type == DioExceptionType.connectionError) return '网络不通';
    final code = e.response?.statusCode;
    if (code == 404) return '安装包找不到了（404）';
    if (code != null) return '服务器返回 $code';
    return e.message ?? e.toString();
  }
}
