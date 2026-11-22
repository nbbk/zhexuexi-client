import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/node_model.dart';
import '../../services/nodes_notifier.dart';

/// 节点页：搜索框 + 分组 + 一键测速 / 自动选择 + 节点列表。
///
/// 切片 1：真实节点列表（订阅拉取＋三种格式解析）。
/// 搜索框与两个按钮常驻；下方按状态显示：未绑定→粘贴订阅链接入口，
/// 加载中→转圈，失败→原因＋重试，成功→按中转/直连分组的节点行。
/// 切片 4：一键测速与自动选择已接线（测速要核心在跑，见
/// [NodesNotifier.testAllSpeeds]）；测速失败的节点标灰、不自动选；
/// 点一行选中该节点（当前节点置顶标“使用中”）。
class NodesPage extends ConsumerStatefulWidget {
  const NodesPage({super.key});

  @override
  ConsumerState<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends ConsumerState<NodesPage> {
  final _searchController = TextEditingController();
  final _linkController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // 首次进入自动拉一次（已绑定才拉；未绑定显示粘贴入口）。
    Future.microtask(() => ref.read(nodesProvider.notifier).refresh());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _linkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(nodesProvider);
    final hasNodes = state.nodes.isNotEmpty;
    final testing = state.testingSpeed;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '搜索节点',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  // 一键测速：核心没启动时点了一样会提示（不在这里置灰，
                  // 提示文案比灰按钮更清楚）；测速中禁用防重复点。
                  onPressed: !hasNodes || testing
                      ? null
                      : () async {
                          final ok = await ref
                              .read(nodesProvider.notifier)
                              .testAllSpeeds();
                          if (!ok && mounted) {
                            final error = ref
                                .read(nodesProvider)
                                .speedTestError;
                            if (error != null) _showSnack(error);
                          }
                        },
                  icon: const Icon(Icons.speed),
                  label: Text(
                    testing
                        ? '测速中 ${state.speedTestedCount}/${state.speedTestTotal}'
                        : '一键测速',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  // 自动选择：延迟最低的可用节点；没测过先测一轮再选。
                  onPressed: !hasNodes || testing
                      ? null
                      : () async {
                          final ok = await ref
                              .read(nodesProvider.notifier)
                              .autoSelect();
                          if (mounted) {
                            final reason = ref
                                .read(nodesProvider)
                                .selectionReason;
                            if (reason != null) _showSnack(reason);
                            if (!ok) {
                              final error = ref
                                  .read(nodesProvider)
                                  .speedTestError;
                              if (error != null) _showSnack(error);
                            }
                          }
                        },
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('自动选择'),
                ),
              ),
            ],
          ),
        ),
        // 订阅地址刚被远程配置换过（切片 7）：顶部显示一句，点叉关掉。
        if (state.addressNotice != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    state.addressNotice!,
                    style: TextStyle(color: Colors.blue.shade900),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '关闭提示',
                  onPressed: () => ref
                      .read(nodesProvider.notifier)
                      .dismissAddressNotice(),
                ),
              ],
            ),
          ),
        // 测速失败的原因（核心未启动等）与自动选择的解释常驻显示，
        // 不只闪一下 SnackBar：用户回来看得到“为什么”。
        if (state.speedTestError != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              state.speedTestError!,
              style: TextStyle(color: Colors.orange.shade900),
            ),
          ),
        if (state.selectionReason != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              state.selectionReason!,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(child: _buildBody(state)),
      ],
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildBody(NodesState state) {
    return switch (state.status) {
      NodesStatus.initial => _buildBindForm(),
      NodesStatus.loading => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在拉取订阅…'),
          ],
        ),
      ),
      NodesStatus.error => _buildError(state),
      NodesStatus.loaded => _buildList(state),
    };
  }

  /// 未绑定：粘贴完整订阅链接的入口（临时入口，切片 5 的“我的”页接管）。
  /// 链接只拆成地址与令牌分开存，令牌进系统密钥库。
  Widget _buildBindForm() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '绑定订阅后这里会列出节点',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _linkController,
          decoration: const InputDecoration(
            hintText: '粘贴完整订阅链接',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
          minLines: 1,
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () {
            final link = _linkController.text.trim();
            if (link.isEmpty) return;
            ref.read(nodesProvider.notifier).bindAndRefresh(link);
          },
          child: const Text('绑定并刷新'),
        ),
        const SizedBox(height: 8),
        const Text(
          '链接只存本机，令牌进系统密钥库，不会明文保存。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildError(NodesState state) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          state.errorMessage ?? '拉取失败',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => ref.read(nodesProvider.notifier).refresh(),
          child: const Text('重新拉取'),
        ),
        // 绑定失败也可能落到这里：留粘贴入口，不用回退到别的页。
        if (state.nodes.isEmpty) ...[
          const SizedBox(height: 24),
          const Text('或重新粘贴订阅链接：', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          TextField(
            controller: _linkController,
            decoration: const InputDecoration(
              hintText: '粘贴完整订阅链接',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
            minLines: 1,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              final link = _linkController.text.trim();
              if (link.isEmpty) return;
              ref.read(nodesProvider.notifier).bindAndRefresh(link);
            },
            child: const Text('绑定并刷新'),
          ),
        ],
      ],
    );
  }

  Widget _buildList(NodesState state) {
    final filtered = _filter(state.nodes);
    return Column(
      children: [
        if (state.failedCount > 0)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.orange.shade50,
            child: Text(
              '解析失败 ${state.failedCount} 个节点（已跳过，其余节点正常）',
              style: TextStyle(color: Colors.orange.shade900),
            ),
          ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('没有符合条件的节点'))
              : ListView(
                  children: [
                    ..._buildGroup(
                      '中转节点',
                      _filter(state.relayNodes),
                      state,
                    ),
                    ..._buildGroup(
                      '直连节点',
                      _filter(state.directNodes),
                      state,
                    ),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '共 ${state.nodes.length} 个节点'
                  '${state.lastUpdated != null ? ' · 上次更新 ${_formatTime(state.lastUpdated!)}' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              TextButton(
                onPressed: () => ref.read(nodesProvider.notifier).refresh(),
                child: const Text('刷新'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildGroup(String title, List<Node> nodes, NodesState state) {
    if (nodes.isEmpty) return [];
    // 当前节点置顶（DEV-PLAN §4.3 1-6），其余按原顺序。
    final ordered = List.of(nodes);
    final selected = state.selectedNodeName;
    if (selected != null) {
      ordered.sort((a, b) {
        if (a.name == selected && b.name != selected) return -1;
        if (b.name == selected && a.name != selected) return 1;
        return 0;
      });
    }
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          '$title（${nodes.length}）',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      ...ordered.map((node) => _buildRow(node, state)),
    ];
  }

  Widget _buildRow(Node node, NodesState state) {
    final isSelected = state.selectedNodeName == node.name;
    final failed = node.latencyFailed;
    return ListTile(
      // 点一行选中该节点；测速失败的节点也能手动点（用户自己负责），
      // 只是自动选择永远不会选它。
      onTap: () async {
        final ok = await ref.read(nodesProvider.notifier).selectNode(node);
        if (!ok && mounted) {
          final reason = ref.read(nodesProvider).selectionReason;
          if (reason != null) _showSnack(reason);
        }
      },
      leading: CircleAvatar(child: Text(node.protocol.label)),
      title: Text(
        node.name,
        style: TextStyle(color: failed ? Colors.grey : null),
      ),
      subtitle: Text(
        '${node.address}:${node.port}',
        style: TextStyle(color: failed ? Colors.grey : null),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSelected)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.shade100,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('使用中', style: TextStyle(fontSize: 12)),
            ),
          if (node.isPlainText)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orange.shade100,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('明文', style: TextStyle(fontSize: 12)),
            ),
          const SizedBox(width: 8),
          Text(
            node.latencyMs != null
                ? '${node.latencyMs}ms'
                : failed
                ? '测速失败'
                : '未测速',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  List<Node> _filter(List<Node> nodes) {
    if (_query.isEmpty) return nodes;
    final q = _query.toLowerCase();
    return nodes.where((n) => n.name.toLowerCase().contains(q)).toList();
  }

  String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
