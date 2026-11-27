import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/app_tokens.dart';
import '../../widgets/app_icon.dart';

/// 扫码页（第 6、7 项）：扫订阅链接或节点链接的二维码。
///
/// 扫到一条就停、把内容原样带回去（`Navigator.pop` 的返回值），
/// 由调用方按内容分流（见 [handleContent]）：单条节点链接走单节点
/// 流程，订阅链接走订阅流程，三种格式的订阅正文逐条加为单节点，
/// 不合法的在调用方提示，不在这里猜。
///
/// 相机权限：只在 AndroidManifest 里声明 CAMERA 权限（mobile_scanner
/// 运行时向系统申请；用户拒绝时扫码区显示去系统设置里开权限的提示，
/// 不静默白屏）。本客户端没有 iOS 端，不用补 Info.plist。
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _controller = MobileScannerController();

  /// 扫到一条就够了：防重复回调导致连弹两次。
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    if (capture.barcodes.isEmpty) return;
    final value = capture.barcodes.first.rawValue?.trim();
    if (value == null || value.isEmpty) return;
    _handled = true;
    if (mounted) Navigator.pop(context, value);
  }

  Widget _errorBuilder(BuildContext context, MobileScannerException error) {
    final denied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(
          AppTokens.spacingMd + AppTokens.spacingXs,
        ),
        child: Text(
          denied
              ? '相机权限未开启：请在系统设置里允许“哲学系”使用相机，然后重新扫码。'
              : '相机启动失败，请重试（${error.errorCode.name}）',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫码添加'),
        actions: [
          IconButton(
            icon: const AppIcon(icon: AppIcons.flashlight),
            tooltip: '手电筒',
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: _errorBuilder,
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(AppTokens.spacingMd),
            child: Text(
              '把订阅链接或节点链接的二维码放进框里',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
