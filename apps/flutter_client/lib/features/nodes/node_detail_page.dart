import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/app_theme.dart';
import '../../core/app_tokens.dart';
import '../../core/node_model.dart';
import '../../services/nodes_notifier.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/glass_card.dart';

/// 节点详情页：从节点行进详情（[OpenContainer]，450ms）。
///
/// 只展示与操作，不改订阅与解析逻辑：
/// - 信息：名字、协议、地址:端口、延迟、来源订阅、是否明文；
/// - 操作：设为当前节点、测速（只测这一个）。
class NodeDetailPage extends ConsumerWidget {
  const NodeDetailPage({super.key, required this.node});

  /// 要展示的节点（行上传进来的快照；延迟等易变数据用 select 读）。
  final Node node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 易变数据用 select 读：延迟更新只重建本页，不重建节点列表。
    final live = ref.watch(
      nodesProvider.select((s) {
        // 同 dedupKey 的节点可能有多个（名字不同、其余全同）：
        // 同 key 里优先取同名的那条，取不到再取第一条。
        final sameKey = s.nodes.where((n) => n.dedupKey == node.dedupKey);
        final current =
            sameKey.where((n) => n.name == node.name).firstOrNull ??
            sameKey.firstOrNull;
        if (current == null) return null;
        return (
          latencyMs: current.latencyMs,
          failed: current.latencyFailed,
          selected: s.selectedNodeName == current.name,
          testing: s.testingSingleNodeKey == current.dedupKey,
          testingAll: s.testingSpeed,
        );
      }),
    );
    final latencyMs = live?.latencyMs ?? node.latencyMs;
    final failed = live?.failed ?? node.latencyFailed;
    final isSelected = live?.selected ?? false;
    final testing = (live?.testing ?? false) || (live?.testingAll ?? false);
    final tokens = appThemeTokensOf(context);
    return Scaffold(
      appBar: AppBar(title: Text(node.name)),
      body: GlassBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spacingMd),
          children: [
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(AppTokens.spacingMd),
                child: Column(
                  children: [
                    _InfoRow(
                      icon: AppIcons.globe,
                      label: '地址',
                      value: '${node.address}:${node.port}',
                    ),
                    const SizedBox(height: AppTokens.spacingSm),
                    _InfoRow(
                      icon: AppIcons.layers,
                      label: '协议',
                      value: node.protocol.label,
                    ),
                    const SizedBox(height: AppTokens.spacingSm),
                    _InfoRow(
                      icon: AppIcons.gauge,
                      label: '延迟',
                      value: latencyMs != null
                          ? '${latencyMs}ms'
                          : failed
                          ? '测速失败'
                          : '未测速',
                    ),
                    if (node.subscriptionName != null) ...[
                      const SizedBox(height: AppTokens.spacingSm),
                      _InfoRow(
                        icon: AppIcons.layers,
                        label: '来源订阅',
                        value: node.subscriptionName!,
                      ),
                    ],
                    if (node.isPlainText) ...[
                      const SizedBox(height: AppTokens.spacingSm),
                      _InfoRow(
                        icon: AppIcons.network,
                        label: '传输',
                        value: '明文',
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppTokens.spacingMd),
            if (isSelected)
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(AppTokens.spacingMd),
                  child: Row(
                    children: [
                      AppIcon(icon: AppIcons.circleCheck, color: tokens.gold),
                      const SizedBox(width: AppTokens.spacingXs),
                      const Text('正在使用这个节点'),
                    ],
                  ),
                ),
              )
            else
              FilledButton.icon(
                onPressed: () async {
                  final ok = await ref
                      .read(nodesProvider.notifier)
                      .selectNode(node);
                  if (!context.mounted) return;
                  if (ok) {
                    Navigator.of(context).pop();
                  } else {
                    final reason = ref.read(nodesProvider).selectionReason;
                    if (reason != null) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(reason)));
                    }
                  }
                },
                icon: const AppIcon(
                  icon: AppIcons.circleCheck,
                  size: AppIconSize.sm,
                ),
                label: const Text('设为当前节点'),
              ),
            const SizedBox(height: AppTokens.spacingSm),
            OutlinedButton.icon(
              onPressed: testing
                  ? null
                  : () async {
                      final ok = await ref
                          .read(nodesProvider.notifier)
                          .testSingleSpeed(node);
                      if (!ok && context.mounted) {
                        final error = ref.read(nodesProvider).speedTestError;
                        if (error != null) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text(error)));
                        }
                      }
                    },
              icon: const AppIcon(icon: AppIcons.gauge, size: AppIconSize.sm),
              label: Text(testing ? '测速中…' : '测速'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AppIcon(icon: icon, size: AppIconSize.sm),
        const SizedBox(width: AppTokens.spacingSm),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: AppTokens.spacingSm),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
