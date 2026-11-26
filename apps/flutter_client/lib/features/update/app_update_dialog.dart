import 'package:material_ui/material_ui.dart';

import '../../core/app_motion.dart';
import '../../services/app_update/app_updater.dart';
import '../../services/app_update/update_source.dart';

/// 新版提示弹窗（启动安静查与设置页手动查共用）。
///
/// 流程：显示新版本号 + Release 说明（截断 500 字）→ 点“立即更新”
/// 自动下载（带进度条）→ 下完核 SHA-256（对不上不安装、报错；
/// 源没给校验值时先如实提示“无校验值”，由用户决定是否继续）
/// → 调系统安装确认（侧载必须要点确认，做不到静默安装）。
///
/// Release 说明截断口径：只显示前 500 字，超了末尾加“……”，
/// 全文不贴（Release 说明可能很长，弹窗里放不下）。
Future<void> showAppUpdateDialog({
  required BuildContext context,
  required AppUpdater updater,
  required UpdateReleaseInfo info,
}) {
  return showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _AppUpdateDialog(updater: updater, info: info),
  );
}

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({required this.updater, required this.info});

  final AppUpdater updater;
  final UpdateReleaseInfo info;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

enum _Phase { prompt, downloading, noChecksumConfirm, installing, done, error }

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  _Phase _phase = _Phase.prompt;
  double _progress = 0;
  String? _error;
  DownloadedApk? _downloaded;

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
                Text('来自${info.sourceName}，点“立即更新”下载安装。'),
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
        _Phase.done => const Text(
            '已调起系统安装，请在系统安装界面点“安装”完成更新。'
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
            TextButton(
              onPressed: _startDownload,
              child: const Text('立即更新'),
            ),
          ],
        _Phase.downloading || _Phase.installing => const [],
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
              onPressed: _startDownload,
              child: const Text('重试'),
            ),
          ],
      },
    );
  }
}
