import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/node_model.dart';
import '../../services/nodes_notifier.dart';

/// 节点页：搜索框 + 分组 + 一键测速 / 自动选择 + 节点列表。
///
/// 切片 1：真实节点列表（订阅拉取＋三种格式解析）。
/// 搜索框与两个按钮常驻；下方按状态显示：未绑定→粘贴订阅链接入口，
/// 加载中→转圈，失败→原因＋重试，成功→按中转/直连分组的节点行。
/// 测速与自动选择在切片 4 接线，现置灰。
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
                  // 切片 4 接测速，现置灰。
                  onPressed: null,
                  icon: const Icon(Icons.speed),
                  label: const Text('一键测速'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  // 切片 4 接自动选择，现置灰。
                  onPressed: null,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('自动选择'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildBody(state)),
      ],
    );
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
                    ..._buildGroup('中转节点', _filter(state.relayNodes)),
                    ..._buildGroup('直连节点', _filter(state.directNodes)),
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

  List<Widget> _buildGroup(String title, List<Node> nodes) {
    if (nodes.isEmpty) return [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          '$title（${nodes.length}）',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      ...nodes.map(
        (node) => ListTile(
          leading: CircleAvatar(child: Text(node.protocol.label)),
          title: Text(node.name),
          subtitle: Text('${node.address}:${node.port}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (node.isPlainText)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('明文', style: TextStyle(fontSize: 12)),
                ),
              const SizedBox(width: 8),
              Text(
                node.latencyMs == null ? '未测速' : '${node.latencyMs}ms',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    ];
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
