import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'nodes_notifier.dart';
import 'subscription_parser.dart';
import 'subscriptions_notifier.dart';

/// 粘贴/扫码内容分流（第 6、7 项共用）：扫到的、粘贴的都先过这里，
/// 按内容是订阅还是单条节点链接自动区分，再走对应的流程。
///
/// - 单条节点链接（VLESS/VMess/Trojan/SS/HY2/TUIC/AnyTLS/SOCKS5，
///   复用现有链接解析器）→ 单节点流程；
/// - 自家面板订阅链接（最后一段是 `sub_` 开头的令牌）→ 主订阅绑定
///   （走原来的主订阅单槽位，只认自家面板链接，别处来的链接不进这里）；
/// - 其它 http(s) 订阅链接（XBoard 等机场）→ 往多订阅列表里加一个，
///   不是替换（第 10 项：再加订阅就是往列表里加一个）；
/// - 三种格式的订阅正文（sing-box JSON / Clash YAML / 链接列表，
///   扫码扫到的正文）→ 逐条加为单节点；
/// - 都不是 → 无法识别，界面提示，不写任何东西。
enum ScannedContentKind {
  /// 单条节点链接。
  singleNode,

  /// 自家面板订阅链接（`sub_` 令牌结尾）。
  primarySubscriptionUrl,

  /// 其它 http(s) 订阅链接。
  subscriptionUrl,

  /// 三种格式的订阅正文。
  subscriptionBody,

  /// 无法识别。
  unknown,
}

/// 从剪贴板读一段文本，去首尾空白后填进 [controller]（光标移到末尾）。
/// 调用方填完再走 [handleContent] 分流，与直接粘贴进框再点提交同一条路。
/// 剪贴板为空或只有空白时返回 false，不动输入框。
Future<bool> pasteClipboardInto(TextEditingController controller) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text?.trim() ?? '';
  if (text.isEmpty) return false;
  controller.text = text;
  controller.selection = TextSelection.collapsed(offset: text.length);
  return true;
}

/// 给一段粘贴/扫码内容分类（纯函数，不碰存储、不拉网络）。
ScannedContentKind classifyContent(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return ScannedContentKind.unknown;
  // 单条节点链接只认单行：多行是链接列表正文，走订阅正文分支。
  if (!text.contains('\n') && parseNodeLink(text) != null) {
    return ScannedContentKind.singleNode;
  }
  if (_isHttpUrl(text)) {
    return isPrimarySubscriptionLink(text)
        ? ScannedContentKind.primarySubscriptionUrl
        : ScannedContentKind.subscriptionUrl;
  }
  try {
    if (parseSubscription(text).nodes.isNotEmpty) {
      return ScannedContentKind.subscriptionBody;
    }
  } catch (_) {
    // 三种格式都解不出 → unknown。
  }
  return ScannedContentKind.unknown;
}

/// 是不是合法 http(s) URL（单行；多行正文不算链接）。
bool _isHttpUrl(String text) {
  if (text.contains('\n')) return false;
  final uri = Uri.tryParse(text);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

/// 是不是自家面板订阅链接：最后一段是 `sub_` 开头的令牌
///（与 [SubscriptionService.saveSubscriptionLink] 同一口径）。
bool isPrimarySubscriptionLink(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.pathSegments.isEmpty) return false;
  return uri.pathSegments.last.startsWith('sub_');
}

/// 按分类处理一段粘贴/扫码内容：成功返回要给用户看的一句话，
/// 失败返回原因；成功时 [error] 为 null，失败时 [message] 为 null。
/// 不合法的内容不写任何东西。
Future<({String? error, String? message})> handleContent(
  WidgetRef ref,
  String raw,
) async {
  final text = raw.trim();
  switch (classifyContent(text)) {
    case ScannedContentKind.singleNode:
      final error = await ref
          .read(nodesProvider.notifier)
          .addSingleNode(text);
      if (error != null) return (error: error, message: null);
      return (error: null, message: '已添加节点');
    case ScannedContentKind.primarySubscriptionUrl:
      await ref.read(nodesProvider.notifier).bindAndRefresh(text);
      final state = ref.read(nodesProvider);
      if (state.status == NodesStatus.error) {
        return (error: state.errorMessage ?? '绑定失败', message: null);
      }
      return (error: null, message: '已绑定订阅');
    case ScannedContentKind.subscriptionUrl:
      final error = await ref
          .read(subscriptionsProvider.notifier)
          .add(text);
      if (error != null) return (error: error, message: null);
      return (error: null, message: '已添加订阅');
    case ScannedContentKind.subscriptionBody:
      final result = await ref
          .read(nodesProvider.notifier)
          .addNodesFromContent(text);
      if (result.error != null) {
        return (error: result.error, message: null);
      }
      return (error: null, message: '已添加 ${result.addedCount} 个节点');
    case ScannedContentKind.unknown:
      return (
        error: '内容无法识别：不是节点链接，也不是订阅链接',
        message: null,
      );
  }
}
