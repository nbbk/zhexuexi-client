import 'package:package_info_plus/package_info_plus.dart';

import '../brand/remote_config.dart';

/// 读真实安装版本：优先 PackageInfo（与 pubspec 的 version 同步的
/// versionName），读不到（如测试环境没插件）回退到编译进代码的
/// [appVersion] 常量。
///
/// 关于页、诊断包、更新器都走这里同一源，不要各自读一份——
/// 0.1.10–0.1.13 的教训：关于页直接用常量，pubspec 升了常量没升，
/// 装上的明明是 0.1.13，显示的却是 0.1.10。
Future<String> resolveAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) return info.version;
  } catch (_) {
    // 测试环境 / 插件未注册时走回退值。
  }
  return appVersion;
}
