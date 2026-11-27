// 更新弹窗“已下载入口”的 widget 测试（单独成文件）。
//
// 必须单独放：flutter_test 的 TestWidgetsFlutterBinding 一旦启用，
// 同文件里所有真实 HttpClient 请求都会被 mock 成 400——回环下载
// 测试在 app_update_test.dart 里，必须和 widget 测试分文件。
//
// 注意：testWidgets 里真实异步 I/O（建临时目录、写文件）必须包在
// tester.runAsync 里，不然假异步区会把它吞掉、永远等不到完成。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhexuexi_client/features/update/app_update_dialog.dart';
import 'package:zhexuexi_client/services/app_update/app_updater.dart';
import 'package:zhexuexi_client/services/app_update/update_source.dart';

/// 记数的 fake 安装器：只记调了几次、最后一次传的文件路径，不调系统安装。
class _FakeInstaller implements AppInstaller {
  int calls = 0;
  String? lastPath;

  @override
  Future<void> installApk(File apk) async {
    calls++;
    lastPath = apk.path;
  }
}

void main() {
  group('更新弹窗：已下载入口（0.1.17）', () {
    testWidgets('已下载时直接显示安装入口，点安装调起安装、不下载',
        (tester) async {
      final installer = _FakeInstaller();
      late Directory tmpDir;
      late File file;
      await tester.runAsync(() async {
        tmpDir =
            await Directory.systemTemp.createTemp('app-update-dialog-test-');
        file = File('${tmpDir.path}/app-arm64-v8a-release.apk');
        await file.writeAsBytes([1, 2, 3, 4]);
      });
      addTearDown(
        () => tester.runAsync(() async {
          if (await tmpDir.exists()) {
            await tmpDir.delete(recursive: true);
          }
        }),
      );
      final apk = DownloadedApk(file: file, sha256Verified: true);
      final updater = AppUpdater(
        sources: const [],
        installer: installer,
        currentVersionReader: () async => '1.0.0',
      );
      const info = UpdateReleaseInfo(
        version: '1.2.3',
        downloadUrl: 'https://example.com/app.apk',
        sourceName: 'GitHub',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () => showAppUpdateDialog(
                  context: context,
                  updater: updater,
                  info: info,
                  alreadyDownloaded: apk,
                ),
                child: const Text('打开更新弹窗'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('打开更新弹窗'));
      // 定长 pump：350ms 入场动画跑完即可；不用 pumpAndSettle
      //（它在 showGeneralDialog 下可能一直等不到 settle）。
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('已下载 v1.2.3'), findsOneWidget);
      expect(find.text('重新下载'), findsOneWidget);
      await tester.tap(find.text('安装'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(installer.calls, 1);
      expect(installer.lastPath, file.path);
    });
  });
}
