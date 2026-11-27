// 0.1.14：版本号防线。
//
// 0.1.11–0.1.13 只升了 pubspec，没升 `appVersion` 常量，关于页与
// 诊断包一路显示 0.1.10。防线：测试里断言常量与 pubspec 的 version
// 一致——以后再有只升一处的情况，测试先红，不会再偷偷过期。
// 关于页与诊断包改读真实安装版本（PackageInfo 优先、常量回退），
// 与更新器同源；测试环境读不到 PackageInfo 时回退到常量。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/brand/remote_config.dart';
import 'package:zhexuexi_client/services/app_version.dart';

void main() {
  test('appVersion 常量与 pubspec 的 version 一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec 里找不到 version: x.y.z+n');
    expect(appVersion, match!.group(1));
  });

  test('resolveAppVersion：读不到 PackageInfo 时回退到常量', () async {
    expect(await resolveAppVersion(), appVersion);
  });
}
