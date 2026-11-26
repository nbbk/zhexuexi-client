// 应用内更新（双通道：GitHub 主通道＋自托管备通道）的单元测试。
// 不碰真网络：GitHub 用拦截器 fake Dio，下载用本机回环 HttpServer。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/services/app_update/app_update_provider.dart';
import 'package:zhexuexi_client/services/app_update/app_updater.dart';
import 'package:zhexuexi_client/services/app_update/github_update_source.dart';
import 'package:zhexuexi_client/services/app_update/self_hosted_update_source.dart';
import 'package:zhexuexi_client/services/app_update/semver.dart';
import 'package:zhexuexi_client/services/app_update/update_source.dart';

/// APK 测试字节（内容固定，SHA-256 用系统 sha256sum 算好写死，
/// 不用被测的库自证）：
/// `printf 'zhexuexi-update-test-apk' | sha256sum` =
/// 3642405d4aaa43c829c74f5269b48bf6249fee7d950d4e064881a3717082a582
final _apkBytes = utf8.encode('zhexuexi-update-test-apk');
const _apkSha256 =
    '3642405d4aaa43c829c74f5269b48bf6249fee7d950d4e064881a3717082a582';

class _StubSource implements UpdateSource {
  _StubSource({this.name = 'Stub', this.info, this.error});

  @override
  final String name;
  final UpdateReleaseInfo? info;
  final UpdateException? error;
  int calls = 0;

  @override
  Future<UpdateReleaseInfo> checkLatest() async {
    calls++;
    if (error != null) throw error!;
    return info!;
  }
}

Dio _fakeGitHubDio({
  required Map<String, dynamic> releaseJson,
  String? sha256Text,
  int statusCode = 200,
  DioExceptionType? failWith,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (failWith != null) {
          handler.reject(
            DioException(requestOptions: options, type: failWith),
          );
          return;
        }
        if (options.path.contains('releases/latest')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: statusCode,
              data: releaseJson,
            ),
          );
        } else if (sha256Text != null) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: sha256Text,
            ),
          );
        } else {
          handler.resolve(
            Response(requestOptions: options, statusCode: 404, data: ''),
          );
        }
      },
    ),
  );
  return dio;
}

Map<String, dynamic> _releaseJson({
  String tag = 'v1.2.3',
  String body = '新版说明',
  bool withApk = true,
  bool withSha256 = true,
}) {
  final assets = <Map<String, dynamic>>[];
  if (withApk) {
    assets.add({
      'name': 'app-arm64-v8a-release.apk',
      'browser_download_url':
          'https://github.com/nbbk/zhexuexi-client/releases/download/v1.2.3/app-arm64-v8a-release.apk',
    });
  }
  if (withSha256) {
    assets.add({
      'name': 'app-arm64-v8a-release.apk.sha256',
      'browser_download_url':
          'https://github.com/nbbk/zhexuexi-client/releases/download/v1.2.3/app-arm64-v8a-release.apk.sha256',
    });
  }
  return {'tag_name': tag, 'body': body, 'assets': assets};
}

void main() {
  group('版本号比对（semver 口径）', () {
    test('相等：同版 / 缺段补 0 / v 前缀 / +build 忽略', () {
      expect(compareSemver('1.0.0', '1.0.0'), 0);
      expect(compareSemver('1.0', '1.0.0'), 0);
      expect(compareSemver('v1.2.3', '1.2.3'), 0);
      expect(compareSemver('1.0.0+2', '1.0.0'), 0);
      expect(compareSemver('1.0.0+2', '1.0.0+5'), 0);
    });

    test('更新：大版本 / 小版本 / 补丁 / 1.10 > 1.9（不是字典序）', () {
      expect(compareSemver('1.0.1', '1.0.0'), greaterThan(0));
      expect(compareSemver('1.2.0', '1.1.9'), greaterThan(0));
      expect(compareSemver('2.0.0', '1.9.9'), greaterThan(0));
      expect(compareSemver('1.10.0', '1.9.0'), greaterThan(0));
    });

    test('更旧：反向比对为负', () {
      expect(compareSemver('1.0.0', '1.0.1'), lessThan(0));
      expect(compareSemver('0.9.9', '1.0.0'), lessThan(0));
    });

    test('预发布：alpha < alpha.1 < alpha.beta < beta < beta.2 < beta.11 < rc.1 < 正式版', () {
      const ordered = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ];
      for (var i = 0; i < ordered.length - 1; i++) {
        expect(
          compareSemver(ordered[i], ordered[i + 1]),
          lessThan(0),
          reason: '${ordered[i]} 应小于 ${ordered[i + 1]}',
        );
      }
    });
  });

  group('GitHub Release JSON 解析', () {
    test('取 arm64 APK 与 .sha256 资产地址，tag 去 v 前缀', () {
      final info = GitHubUpdateSource.parseReleaseJson(_releaseJson());
      expect(info, isNotNull);
      expect(info!.version, '1.2.3');
      expect(info.downloadUrl, contains('app-arm64-v8a-release.apk'));
      expect(info.sha256Url, contains('.sha256'));
      expect(info.sha256, isNull); // 文本还没拉，校验值先是 null
      expect(info.releaseNotes, '新版说明');
      expect(info.sourceName, 'GitHub');
    });

    test('没有 arm64 APK 资产时返回 null', () {
      expect(
        GitHubUpdateSource.parseReleaseJson(_releaseJson(withApk: false)),
        isNull,
      );
    });

    test('没有 .sha256 资产时 sha256Url 为 null（下载后走“无校验值”分支）', () {
      final info =
          GitHubUpdateSource.parseReleaseJson(_releaseJson(withSha256: false));
      expect(info, isNotNull);
      expect(info!.sha256Url, isNull);
    });

    test('.sha256 文本解析：单行 / 两列取第一列 / 脏值返回 null', () {
      expect(GitHubUpdateSource.parseSha256Text('$_apkSha256\n'), _apkSha256);
      expect(
        GitHubUpdateSource.parseSha256Text(
          '$_apkSha256  app-arm64-v8a-release.apk\n',
        ),
        _apkSha256,
      );
      expect(
        GitHubUpdateSource.parseSha256Text(_apkSha256.toUpperCase()),
        _apkSha256,
      );
      expect(GitHubUpdateSource.parseSha256Text('不是哈希'), isNull);
      expect(GitHubUpdateSource.parseSha256Text(''), isNull);
    });
  });

  group('GitHub 通道查版（fake Dio，不碰真网）', () {
    test('拉到 Release＋.sha256 文本时 sha256 填好', () async {
      final source = GitHubUpdateSource(
        dio: _fakeGitHubDio(
          releaseJson: _releaseJson(),
          sha256Text: '$_apkSha256\n',
        ),
      );
      final info = await source.checkLatest();
      expect(info.version, '1.2.3');
      expect(info.sha256, _apkSha256);
    });

    test('.sha256 拉不到时 sha256 保持 null，不阻断查版', () async {
      final source = GitHubUpdateSource(
        dio: _fakeGitHubDio(releaseJson: _releaseJson()),
      );
      final info = await source.checkLatest();
      expect(info.version, '1.2.3');
      expect(info.sha256, isNull);
    });

    test('404 时报 notFound（GitHub 上还没有 Release）', () async {
      final source = GitHubUpdateSource(
        dio: _fakeGitHubDio(releaseJson: {}, statusCode: 404),
      );
      await expectLater(
        source.checkLatest(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateFailureKind.notFound,
          ),
        ),
      );
    });

    test('断网时报 network', () async {
      final source = GitHubUpdateSource(
        dio: _fakeGitHubDio(
          releaseJson: {},
          failWith: DioExceptionType.connectionError,
        ),
      );
      await expectLater(
        source.checkLatest(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateFailureKind.network,
          ),
        ),
      );
    });
  });

  group('自托管通道（本轮未启用）', () {
    test('没配地址也报“尚未启用”，不崩、不发请求', () async {
      final source = SelfHostedUpdateSource(baseUrl: '', versionPath: '');
      await expectLater(
        source.checkLatest(),
        throwsA(
          isA<UpdateException>()
              .having((e) => e.kind, 'kind', UpdateFailureKind.notEnabled)
              .having((e) => e.message, 'message', contains('尚未启用')),
        ),
      );
    });

    test('配了地址也一样报“尚未启用”（只留配置位，不假装能用）', () async {
      final source = SelfHostedUpdateSource(
        baseUrl: 'https://update.example.com',
        versionPath: '/api/v1/client/version',
      );
      await expectLater(
        source.checkLatest(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateFailureKind.notEnabled,
          ),
        ),
      );
    });
  });

  group('更新器：双通道顺序', () {
    AppUpdater updaterWith({
      required List<UpdateSource> sources,
      String current = '1.0.0',
    }) {
      return AppUpdater(
        sources: sources,
        currentVersionReader: () async => current,
      );
    }

    UpdateReleaseInfo info(String version, {String sourceName = 'Stub'}) =>
        UpdateReleaseInfo(
          version: version,
          downloadUrl: 'https://example.com/app.apk',
          sourceName: sourceName,
        );

    test('主通道有新版 → available，不再试备通道', () async {
      final github = _StubSource(name: 'GitHub', info: info('1.2.3'));
      final selfHosted = _StubSource(
        name: '自托管',
        error: const UpdateException.notEnabled('尚未启用'),
      );
      final result = await updaterWith(
        sources: [github, selfHosted],
      ).checkLatest();
      expect(result.status, AppUpdateCheckStatus.available);
      expect(result.latest!.version, '1.2.3');
      expect(selfHosted.calls, 0);
    });

    test('主通道已是最新 → upToDate，备通道也不试', () async {
      final github = _StubSource(name: 'GitHub', info: info('1.0.0'));
      final selfHosted = _StubSource(name: '自托管', info: info('9.9.9'));
      final result = await updaterWith(
        sources: [github, selfHosted],
      ).checkLatest();
      expect(result.status, AppUpdateCheckStatus.upToDate);
      expect(result.currentVersion, '1.0.0');
      expect(selfHosted.calls, 0);
    });

    test('主通道失败 → 走备通道；备通道也失败时两条原因都带上', () async {
      final github = _StubSource(
        name: 'GitHub',
        error: const UpdateException.notFound('GitHub 上还没有 Release。'),
      );
      final selfHosted = SelfHostedUpdateSource(
        baseUrl: '',
        versionPath: '',
      );
      final result = await updaterWith(
        sources: [github, selfHosted],
      ).checkLatest();
      expect(result.status, AppUpdateCheckStatus.failed);
      expect(result.failures, hasLength(2));
      expect(result.failureMessage, contains('GitHub'));
      expect(result.failureMessage, contains('自托管'));
    });

    test('主通道失败、备通道有新版 → 用备通道的结果', () async {
      final github = _StubSource(
        name: 'GitHub',
        error: const UpdateException.network('网络不通'),
      );
      final selfHosted = _StubSource(
        name: '自托管',
        info: info('1.1.0', sourceName: '自托管'),
      );
      final result = await updaterWith(
        sources: [github, selfHosted],
      ).checkLatest();
      expect(result.status, AppUpdateCheckStatus.available);
      expect(result.latest!.sourceName, '自托管');
    });
  });

  group('更新器：下载与 SHA-256 校验（本机回环服务器）', () {
    late HttpServer server;
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('app-update-test-');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType =
            ContentType('application', 'octet-stream');
        request.response.add(_apkBytes);
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    test('校验对得上 → 下好文件，sha256Verified 为真', () async {
      final apkUrl = 'http://127.0.0.1:${server.port}/app.apk';
      final updater = AppUpdater(
        sources: const [],
        currentVersionReader: () async => '1.0.0',
        downloadDir: () async => tmpDir,
      );
      final apk = await updater.download(
        UpdateReleaseInfo(
          version: '1.2.3',
          downloadUrl: apkUrl,
          sha256: _apkSha256,
          sourceName: 'GitHub',
        ),
      );
      expect(apk.sha256Verified, isTrue);
      expect(await apk.file.readAsBytes(), _apkBytes);
    });

    test('校验对不上 → 抛 checksum，文件已删，不安装', () async {
      final apkUrl = 'http://127.0.0.1:${server.port}/app.apk';
      final updater = AppUpdater(
        sources: const [],
        currentVersionReader: () async => '1.0.0',
        downloadDir: () async => tmpDir,
      );
      await expectLater(
        updater.download(
          UpdateReleaseInfo(
            version: '1.2.3',
            downloadUrl: apkUrl,
            sha256: '0' * 64,
            sourceName: 'GitHub',
          ),
        ),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateFailureKind.checksum,
          ),
        ),
      );
      expect(await tmpDir.list().toList(), isEmpty);
    });

    test('源没给校验值 → 下好文件，sha256Verified 为假（由界面让用户决定）', () async {
      final apkUrl = 'http://127.0.0.1:${server.port}/app.apk';
      final updater = AppUpdater(
        sources: const [],
        currentVersionReader: () async => '1.0.0',
        downloadDir: () async => tmpDir,
      );
      final apk = await updater.download(
        UpdateReleaseInfo(
          version: '1.2.3',
          downloadUrl: apkUrl,
          sourceName: 'GitHub',
        ),
      );
      expect(apk.sha256Verified, isFalse);
      expect(await apk.file.exists(), isTrue);
    });
  });

  group('更新状态管理（Provider）', () {
    test('checkQuiet：有新版时状态为 available；已是最新时不留状态', () async {
      final withUpdate = ProviderContainer(
        overrides: [
          appUpdaterProvider.overrideWithValue(
            AppUpdater(
              sources: [
                _StubSource(
                  name: 'GitHub',
                  info: const UpdateReleaseInfo(
                    version: '1.2.3',
                    downloadUrl: 'https://example.com/app.apk',
                    sourceName: 'GitHub',
                  ),
                ),
              ],
              currentVersionReader: () async => '1.0.0',
            ),
          ),
        ],
      );
      addTearDown(withUpdate.dispose);
      await withUpdate.read(appUpdateProvider.notifier).checkQuiet();
      expect(
        withUpdate.read(appUpdateProvider).status,
        AppUpdateStatus.available,
      );
      expect(withUpdate.read(appUpdateProvider).latest!.version, '1.2.3');

      final upToDate = ProviderContainer(
        overrides: [
          appUpdaterProvider.overrideWithValue(
            AppUpdater(
              sources: [
                _StubSource(
                  name: 'GitHub',
                  info: const UpdateReleaseInfo(
                    version: '1.0.0',
                    downloadUrl: 'https://example.com/app.apk',
                    sourceName: 'GitHub',
                  ),
                ),
              ],
              currentVersionReader: () async => '1.0.0',
            ),
          ),
        ],
      );
      addTearDown(upToDate.dispose);
      await upToDate.read(appUpdateProvider.notifier).checkQuiet();
      // 安静规则：已是最新时不留“有新版”状态，也不留失败状态。
      expect(upToDate.read(appUpdateProvider).status, AppUpdateStatus.idle);
    });
  });
}
