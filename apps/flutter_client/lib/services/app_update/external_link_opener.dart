import 'dart:io';

import 'update_source.dart';

/// 在系统浏览器里打开链接（可注入 fake 做测试；真机走平台实现）。
///
/// 只给 Windows 更新弹窗用：不引 url_launcher（项目既有约定，
/// 见首页强制更新弹窗的注释），Windows 上用 `cmd /c start` 调
/// 系统默认浏览器。安卓不用这条（走应用内下载安装）。
abstract class ExternalLinkOpener {
  Future<void> open(String url);
}

/// Windows 实现：`cmd /c start "" <url>` 调系统默认浏览器。
///
/// `start` 的第一个引号参数是窗口标题占位（不给时 URL 会被当成
/// 标题、浏览器打不开）；exitCode 非 0 即抛错，由弹窗把 URL 原样
/// 显示出来，让用户手动打开。
class WindowsExternalLinkOpener implements ExternalLinkOpener {
  const WindowsExternalLinkOpener();

  @override
  Future<void> open(String url) async {
    if (!Platform.isWindows) {
      throw const UpdateException.unsupported(
        '当前平台不支持在浏览器里打开下载页。',
      );
    }
    final result = await Process.run('cmd', ['/c', 'start', '', url]);
    if (result.exitCode != 0) {
      throw UpdateException.install(
        '打不开浏览器，请手动打开：$url',
      );
    }
  }
}
