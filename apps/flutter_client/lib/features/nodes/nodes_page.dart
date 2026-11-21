import 'package:material_ui/material_ui.dart';

/// 节点页：搜索框 + 分组 + 一键测速 / 自动选择 + 节点列表。
///
/// 阶段 0 占位：列表为空，测速与自动选择在阶段 1 接节点服务。
/// 列表项规格（阶段 1）：节点名 + 协议 + 分组 + 延迟（未测显示“未测速”）。
class NodesPage extends StatelessWidget {
  const NodesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '搜索节点',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {},
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.speed),
                  label: const Text('一键测速'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('自动选择'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Expanded(
          child: Center(
            child: Text('暂无节点\n绑定订阅后这里会列出节点', textAlign: TextAlign.center),
          ),
        ),
      ],
    );
  }
}
