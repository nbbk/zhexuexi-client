import 'package:material_ui/material_ui.dart';

/// 首页：一个大开关 + 当前节点 + 实时速率 + 流量三格 + 模式切换 + 公告栏。
///
/// 阶段 0 占位：开关可点但不接真实核心（核心启动要等阶段 1 的配置生成），
/// 速率与流量显示“—”，点“去订阅”跳到“我的”页绑定订阅。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.onGoToMe});

  /// 跳到“我的”页（绑定订阅）的回调。
  final VoidCallback onGoToMe;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _enabled = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 公告栏（阶段 1 接面板公告；阶段 0 占位）。
        const Card(
          child: ListTile(
            leading: Icon(Icons.campaign_outlined),
            title: Text('暂无公告'),
            subtitle: Text('面板公告会在这里显示'),
          ),
        ),
        const SizedBox(height: 24),
        // 大开关：直径约为屏幕宽度的三分之一。
        Center(
          child: SizedBox(
            width: MediaQuery.of(context).size.width / 3,
            height: MediaQuery.of(context).size.width / 3,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                shape: const CircleBorder(),
                backgroundColor: _enabled
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
              ),
              onPressed: () {
                setState(() => _enabled = !_enabled);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('阶段 0 占位：核心启动在阶段 1 接线'),
                  ),
                );
              },
              child: Icon(
                _enabled ? Icons.power : Icons.power_settings_new,
                size: 48,
                color: _enabled
                    ? Colors.white
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            _enabled ? '已开启（占位）' : '未连接',
            style: theme.textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 24),
        // 当前节点。
        Card(
          child: ListTile(
            leading: const Icon(Icons.public),
            title: const Text('当前节点：未选择'),
            subtitle: const Text('绑定订阅后自动选择最快的节点'),
            trailing: TextButton(
              onPressed: widget.onGoToMe,
              child: const Text('去订阅'),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 实时速率 + 流量三格（阶段 0 显示“—”）。
        Row(
          children: const [
            Expanded(
              child: _StatCell(label: '实时速率', value: '—'),
            ),
            Expanded(
              child: _StatCell(label: '已用流量', value: '—'),
            ),
            Expanded(
              child: _StatCell(label: '剩余流量', value: '—'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // 模式切换（阶段 1 生效）。
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'rule', label: Text('规则模式')),
            ButtonSegment(value: 'global', label: Text('全局模式')),
            ButtonSegment(value: 'direct', label: Text('直连模式')),
          ],
          selected: const {'rule'},
          onSelectionChanged: (_) {},
        ),
      ],
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Text(value, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
