import 'package:material_ui/material_ui.dart';

import '../../core/app_motion.dart';
import '../../services/app_update/app_updater.dart';
import '../../services/app_update/external_link_opener.dart';
import '../../services/app_update/update_source.dart';

/// 新版提示弹窗（启动安静查与设置页手动查共用）。
///
/// 安卓流程：显示新版本号 + Release 说明（截断 500 字）→ 点“立即更新”
/// 自动下载（带进度条）→ 下完核 SHA-256（对不上不安装、报错；
/// 源没给校验值时先如实提示“无校验值”，由用户决定是否继续）
/// → 调系统安装确认（侧载必须要点确认，做不到静默安装）。
///
/// Windows 流程（0.1.22）：只弹提示，不下载、不安装。点“去下载”
/// 在系统浏览器里打开下载页（优先 Windows zip 资产，拿不到时是
/// Release 页）；打不开时把下载地址原样显示出来，让用户手动打开。
///
/// 已下载过同一版本时（[alreadyDownloaded] 非空，安卓才有）：直接进
/// “已下载”相，点“安装”直接调起系统安装，不用重新下载；
/// 点“重新下载”才走下载流程。下载完校验通过后待安装记录已
/// 持久化，弹窗关了、安装提示错过了也能在设置页重调安装。
Future<void> showAppUpdateDialog({
  required BuildContext context,
  required AppUpdater updater,
  required UpdateReleaseInfo info,
  DownloadedApk? alreadyDownloaded,
  ExternalLinkOpener? linkOpener,
}) {
  return showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _AppUpdateDialog(
      updater: updater,
      info: info,
      alreadyDownloaded: alreadyDownloaded,
      linkOpener: linkOpener ?? const WindowsExternalLinkOpener(),
    ),
  );
}

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({
    required this.updater,
    required this.info,
    this.alreadyDownloaded,
    required this.linkOpener,
  });

  final AppUpdater updater;
  final UpdateReleaseInfo info;

  /// 已下载好的安装包（校验通过）；非空时弹窗直接给安装入口。
  final DownloadedApk? alreadyDownloaded;

  /// Windows 分支开下载页的接口（可注入 fake 做测试）。
  final ExternalLinkOpener linkOpener;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

enum _Phase {
  prompt,
  downloading,
  noChecksumConfirm,
  installing,
  done,
  error,

  /// 安装包已下载好（不用重下）：给“安装 / 重新下载”两个选择。
  readyToInstall,
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  _Phase _phase = _Phase.prompt;
  double _progress = 0;
  String? _error;
  DownloadedApk? _downloaded;

  @override
  void initState() {
    super.initState();
    if (widget.alreadyDownloaded != null) {
      _downloaded = widget.alreadyDownloaded;
      _phase = _Phase.readyToInstall;
    }
  }

  String get _notes {
    final notes = widget.info.releaseNotes.trim();
    if (notes.isEmpty) return '本次更新没有附说明。';
    if (notes.length <= 500) return notes;
    return '${notes.substring(0, 500)}……';
  }

  Future<void> _startDownload() async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _error = null;
    });
    try {
      final apk = await widget.updater.download(
        widget.info,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      if (!apk.sha256Verified) {
        // 源没给校验值：如实提示，由用户决定是否继续，不悄悄跳过校验。
        setState(() {
          _downloaded = apk;
          _phase = _Phase.noChecksumConfirm;
        });
        return;
      }
      await _install(apk);
    } on UpdateException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _phase = _Phase.error;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '下载失败：$e';
          _phase = _Phase.error;
        });
      }
    }
  }

  /// Windows 分支（0.1.22）：在系统浏览器里打开下载页，不下载。
  /// 打开成功进 done 相；打不开进 error 相，错误里带上下载地址
  /// 原文，让用户手动打开。打开中按钮不可点（_openingLink）。
  bool _openingLink = false;

  Future<void> _openDownloadPage() async {
    setState(() {
      _openingLink = true;
      _error = null;
    });
    try {
      await widget.linkOpener.open(widget.info.downloadUrl);
      if (!mounted) return;
      setState(() {
        _openingLink = false;
        _phase = _Phase.done;
      });
    } on UpdateException catch (e) {
      if (mounted) {
        setState(() {
          _openingLink = false;
          _error = e.message;
          _phase = _Phase.error;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _openingLink = false;
          _error = '打不开浏览器，请手动打开：${widget.info.downloadUrl}';
          _phase = _Phase.error;
        });
      }
    }
  }

  Future<void> _install(DownloadedApk apk) async {
    setState(() => _phase = _Phase.installing);
    try {
      await widget.updater.install(apk);
      if (mounted) setState(() => _phase = _Phase.done);
    } on UpdateException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _phase = _Phase.error;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '调起安装失败：$e';
          _phase = _Phase.error;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return AlertDialog(
      title: Text('发现新版本 v${info.version}'),
      content: switch (_phase) {
        _Phase.prompt => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.openExternally
                      ? '来自${info.sourceName}，点“去下载”在浏览器里打开 Windows 安装包下载页。'
                      : '来自${info.sourceName}，点“立即更新”下载安装。',
                ),
                const SizedBox(height: 8),
                Text(_notes),
              ],
            ),
          ),
        _Phase.downloading => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text('正在下载… ${(_progress * 100).toStringAsFixed(0)}%'),
            ],
          ),
        _Phase.noChecksumConfirm => const Text(
            '这个版本没有提供校验值（SHA-256），无法核对安装包有没有被'
            '改过。确定要继续安装吗？',
          ),
        _Phase.installing => const Text('正在调起系统安装…'),
        _Phase.readyToInstall => Text(
            '已下载 v${info.version}，无需重新下载。\n点“安装”直接调起系统安装。',
          ),
        _Phase.done => Text(
            info.openExternally
                ? '已在浏览器打开下载页，下载 Windows 安装包后解压，'
                    '双击 哲学系.exe 即可运行。'
                : '已调起系统安装，请在系统安装界面点“安装”完成更新。'
                    '安装完成后重新打开客户端即可。',
          ),
        _Phase.error => Text(_error ?? '更新失败，请稍后重试。'),
      },
      actions: switch (_phase) {
        _Phase.prompt => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('稍后'),
            ),
            if (info.openExternally)
              TextButton(
                onPressed: _openingLink ? null : _openDownloadPage,
                child: const Text('去下载'),
              )
            else
              TextButton(
                onPressed: _startDownload,
                child: const Text('立即更新'),
              ),
          ],
        _Phase.downloading || _Phase.installing => const [],
        _Phase.readyToInstall => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: _startDownload,
              child: const Text('重新下载'),
            ),
            TextButton(
              onPressed: () => _install(_downloaded!),
              child: const Text('安装'),
            ),
          ],
        _Phase.noChecksumConfirm => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => _install(_downloaded!),
              child: const Text('仍要安装'),
            ),
          ],
        _Phase.done => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        _Phase.error => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
            TextButton(
              // Windows 分支重试是再开一次下载页，不是重新下载。
              onPressed:
                  info.openExternally ? _openDownloadPage : _startDownload,
              child: const Text('重试'),
            ),
          ],
      },
    );
  }
}
