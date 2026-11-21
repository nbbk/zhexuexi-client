import 'package:material_ui/material_ui.dart';

import '../../core/singbox_core.dart';

/// 设置页：常用设置在上，高级设置折叠在下，底部是“关于”。
///
/// 阶段 0 占位：开关只记本地状态不生效；“关于”页显示客户端版本与核心版本
/// （核心版本读插件的 getSingBoxVersion，读不到显示“—”）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _autoSelect = true;
  bool _autoUpdate = true;
  String _coreVersion = '—';

  @override
  void initState() {
    super.initState();
    _loadCoreVersion();
  }

  Future<void> _loadCoreVersion() async {
    try {
      final version = await CoreService().coreVersion();
      if (mounted) setState(() => _coreVersion = version);
    } catch (_) {
      // 插件未初始化时读不到版本号，显示“—”即可。
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('常用设置', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('自动选择最快节点'),
          value: _autoSelect,
          onChanged: (value) => setState(() => _autoSelect = value),
        ),
        SwitchListTile(
          title: const Text('自动更新订阅'),
          subtitle: const Text('每天自动拉一次订阅'),
          value: _autoUpdate,
          onChanged: (value) => setState(() => _autoUpdate = value),
        ),
        const SizedBox(height: 16),
        const ExpansionTile(
          title: Text('高级设置'),
          children: [
            ListTile(title: Text('DNS 设置（阶段 1）')),
            ListTile(title: Text('分流规则（阶段 1）')),
            ListTile(title: Text('日志（阶段 1）')),
          ],
        ),
        const SizedBox(height: 16),
        const Text('关于', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        ListTile(
          title: const Text('客户端版本'),
          trailing: const Text('0.1.0-stage0'),
        ),
        ListTile(
          title: const Text('sing-box 核心版本'),
          trailing: Text(_coreVersion),
        ),
        const ListTile(
          title: Text('面板版本要求'),
          trailing: Text('≥ 1.3.29'),
        ),
      ],
    );
  }
}
