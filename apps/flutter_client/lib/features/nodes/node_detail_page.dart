import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/app_theme.dart';
import '../../core/app_tokens.dart';
import '../../core/node_model.dart';
import '../../services/node_override_store.dart';
import '../../services/nodes_notifier.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/glass_card.dart';

/// 节点详情页：从节点行进详情（[OpenContainer]，450ms）。
///
/// 只展示与操作，不改订阅与解析逻辑：
/// - 信息：名字、协议、地址:端口、延迟、来源订阅、是否明文；
/// - 操作：设为当前节点、测速（只测这一个）。
/// - 编辑：点 AppBar 上的铅笔进编辑态（同一页内切换，不另开文件），
///   名称、地址、端口、协议、UUID/密码、加密方式、SNI、传输方式、
///   WS 路径/Host、TLS、flow、REALITY 公钥/short id、指纹、ALPN
///   都能改；保存后写进本地改动存储（见 [NodeOverrideStore]），
///   列表与下次启动都用改后的值，刷新订阅也不丢。
///   有改动时显示“已修改（非订阅原始值）”，可一键“恢复默认”。
class NodeDetailPage extends ConsumerStatefulWidget {
  const NodeDetailPage({super.key, required this.node});

  /// 要展示的节点（行上传进来的快照；延迟等易变数据用 select 读）。
  final Node node;

  @override
  ConsumerState<NodeDetailPage> createState() => _NodeDetailPageState();
}

class _NodeDetailPageState extends ConsumerState<NodeDetailPage> {
  /// 当前展示的节点：进页时是行上传进来的快照；保存编辑后换成
  /// 改后的节点，恢复默认后换成订阅/原文解析出的节点。
  /// 延迟、选中态等易变数据仍用 select 从 provider 里读最新值。
  late Node _node;

  bool _editing = false;

  /// 编辑表单的校验/保存错误（就地提示，不保存、不弹框）。
  String? _formError;

  // 编辑态控制器（进编辑态时按当前节点建，退出时释放）。
  TextEditingController? _nameController;
  TextEditingController? _addressController;
  TextEditingController? _portController;
  TextEditingController? _uuidController;
  TextEditingController? _methodController;
  TextEditingController? _sniController;
  TextEditingController? _wsPathController;
  TextEditingController? _wsHostController;
  TextEditingController? _flowController;
  TextEditingController? _realityPublicKeyController;
  TextEditingController? _realityShortIdController;
  TextEditingController? _fingerprintController;
  TextEditingController? _alpnController;
  NodeProtocol? _editProtocol;
  String? _editTransport;
  bool _editTls = false;

  @override
  void initState() {
    super.initState();
    _node = widget.node;
  }

  @override
  void dispose() {
    _disposeEditControllers();
    super.dispose();
  }

  void _disposeEditControllers() {
    for (final c in [
      _nameController,
      _addressController,
      _portController,
      _uuidController,
      _methodController,
      _sniController,
      _wsPathController,
      _wsHostController,
      _flowController,
      _realityPublicKeyController,
      _realityShortIdController,
      _fingerprintController,
      _alpnController,
    ]) {
      c?.dispose();
    }
    _nameController = null;
    _addressController = null;
    _portController = null;
    _uuidController = null;
    _methodController = null;
    _sniController = null;
    _wsPathController = null;
    _wsHostController = null;
    _flowController = null;
    _realityPublicKeyController = null;
    _realityShortIdController = null;
    _fingerprintController = null;
    _alpnController = null;
  }

  /// UUID/密码栏的标题：VLESS/VMess/Trojan 是 UUID，其余是密码。
  String get _uuidLabel {
    switch (_editProtocol) {
      case NodeProtocol.vless:
      case NodeProtocol.vmess:
      case NodeProtocol.trojan:
        return 'UUID';
      default:
        return '密码';
    }
  }

  void _enterEdit(Node base) {
    _nameController = TextEditingController(text: base.name);
    _addressController = TextEditingController(text: base.address);
    _portController = TextEditingController(text: base.port.toString());
    _uuidController = TextEditingController(text: base.uuidOrPassword ?? '');
    // SS 加密方式：空时默认 aes-256-gcm（保存时也按这个默认值写）。
    _methodController = TextEditingController(
      text: base.method ??
          (base.protocol == NodeProtocol.shadowsocks
              ? 'aes-256-gcm'
              : ''),
    );
    _sniController = TextEditingController(text: base.sni ?? '');
    _wsPathController = TextEditingController(text: base.wsPath ?? '');
    _wsHostController = TextEditingController(text: base.wsHost ?? '');
    _flowController = TextEditingController(text: base.flow ?? '');
    _realityPublicKeyController = TextEditingController(
      text: base.realityPublicKey ?? '',
    );
    _realityShortIdController = TextEditingController(
      text: base.realityShortId ?? '',
    );
    _fingerprintController = TextEditingController(
      text: base.fingerprint ?? '',
    );
    _alpnController = TextEditingController(text: base.alpn ?? '');
    _editProtocol = base.protocol == NodeProtocol.unknown
        ? NodeProtocol.vless
        : base.protocol;
    _editTransport = base.transport;
    _editTls = base.tls;
    setState(() {
      _editing = true;
      _formError = null;
    });
  }

  /// 退出编辑态（不保存）：控制器释放，下次进编辑态重建。
  void _exitEdit() {
    _disposeEditControllers();
    setState(() {
      _editing = false;
      _formError = null;
    });
  }

  String? _trimmedOrNull(TextEditingController? controller) {
    final text = controller?.text.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// 保存编辑：表单值拼成整套字段（协议相关的栏只在对应协议/
  /// 传输方式下才取值，不显示的栏沿用节点原值——协议切走又切回来，
  /// 旧参数还在），先校验再写盘；不合法就地提示、不保存。
  Future<void> _saveEdit() async {
    final protocol = _editProtocol ?? _node.protocol;
    final transport = _editTransport ?? _node.transport;
    final fields = {
      ...NodeOverrideStore.fieldsOf(_node),
      'name': _nameController?.text.trim() ?? '',
      'protocol': protocol.name,
      'address': _addressController?.text.trim() ?? '',
      'port': int.tryParse(_portController?.text.trim() ?? '') ?? -1,
      'uuidOrPassword': _trimmedOrNull(_uuidController),
      'transport': transport,
      'tls': _editTls,
      'sni': _trimmedOrNull(_sniController),
      'fingerprint': _trimmedOrNull(_fingerprintController),
      'alpn': _trimmedOrNull(_alpnController),
      // 加密方式只在 SS 下取表单值（空时默认 aes-256-gcm），
      // 其余协议沿用原值。
      'method': protocol == NodeProtocol.shadowsocks
          ? (_methodController?.text.trim().isEmpty ?? true
                ? 'aes-256-gcm'
                : _methodController!.text.trim())
          : _node.method,
      // WS 路径/Host 只在 ws 下取表单值，其余传输方式沿用原值。
      'wsPath': transport == 'ws'
          ? _trimmedOrNull(_wsPathController)
          : _node.wsPath,
      'wsHost': transport == 'ws'
          ? _trimmedOrNull(_wsHostController)
          : _node.wsHost,
      // flow 与 REALITY 只在 VLESS 下取表单值，其余协议沿用原值。
      'flow': protocol == NodeProtocol.vless
          ? _trimmedOrNull(_flowController)
          : _node.flow,
      'realityPublicKey': protocol == NodeProtocol.vless
          ? _trimmedOrNull(_realityPublicKeyController)
          : _node.realityPublicKey,
      'realityShortId': protocol == NodeProtocol.vless
          ? _trimmedOrNull(_realityShortIdController)
          : _node.realityShortId,
    };
    final error = NodeOverrideStore.validateFields(fields);
    if (error != null) {
      setState(() => _formError = error);
      return;
    }
    final saveError = await ref
        .read(nodesProvider.notifier)
        .updateNodeOverride(_node, fields);
    if (!mounted) return;
    if (saveError != null) {
      setState(() => _formError = saveError);
      return;
    }
    setState(() {
      // 本地换成改后的节点（originDedupKey 记原始键），
      // 详情页立刻回显改后的值，不等下次刷新。
      _node = NodeOverrideStore.applyTo(_node, fields);
      _editing = false;
      _formError = null;
    });
    _disposeEditControllers();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存')));
    }
  }

  /// 恢复默认：删掉这条覆盖，刷新后节点回到订阅/原文解析出的样子。
  Future<void> _restoreDefault() async {
    final originalKey = _node.originDedupKey ?? _node.dedupKey;
    await ref.read(nodesProvider.notifier).clearNodeOverride(_node);
    if (!mounted) return;
    final restored = ref
        .read(nodesProvider)
        .nodes
        .where((n) => n.dedupKey == originalKey)
        .firstOrNull;
    setState(() {
      if (restored != null) _node = restored;
      _editing = false;
      _formError = null;
    });
    _disposeEditControllers();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已恢复默认')));
  }

  @override
  Widget build(BuildContext context) {
    // 易变数据用 select 读：延迟更新只重建本页，不重建节点列表。
    final live = ref.watch(
      nodesProvider.select((s) {
        // 同 dedupKey 的节点可能有多个（名字不同、其余全同）：
        // 同 key 里优先取同名的那条，取不到再取第一条。
        final sameKey = s.nodes.where((n) => n.dedupKey == _node.dedupKey);
        final current =
            sameKey.where((n) => n.name == _node.name).firstOrNull ??
            sameKey.firstOrNull;
        if (current == null) return null;
        return (
          node: current,
          latencyMs: current.latencyMs,
          failed: current.latencyFailed,
          selected: s.selectedNodeName == current.name,
          testing: s.testingSingleNodeKey == current.dedupKey,
          testingAll: s.testingSpeed,
        );
      }),
    );
    // 展示用最新节点（刷新/改动后 provider 里的那条），
    // provider 里没有时（刚删掉等）退回进页时的快照。
    final display = live?.node ?? _node;
    final latencyMs = live?.latencyMs ?? _node.latencyMs;
    final failed = live?.failed ?? _node.latencyFailed;
    final isSelected = live?.selected ?? false;
    final testing = (live?.testing ?? false) || (live?.testingAll ?? false);
    final tokens = appThemeTokensOf(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? '编辑节点' : display.name),
        actions: [
          if (_editing)
            IconButton(
              icon: const AppIcon(icon: AppIcons.x),
              tooltip: '取消编辑',
              onPressed: _exitEdit,
            )
          else
            IconButton(
              icon: const AppIcon(icon: AppIcons.pencil),
              tooltip: '编辑',
              onPressed: () => _enterEdit(display),
            ),
        ],
      ),
      body: GlassBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spacingMd),
          children: [
            if (_editing)
              _buildEditForm()
            else ...[
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(AppTokens.spacingMd),
                  child: Column(
                    children: [
                      _InfoRow(
                        icon: AppIcons.globe,
                        label: '地址',
                        value: '${display.address}:${display.port}',
                      ),
                      const SizedBox(height: AppTokens.spacingSm),
                      _InfoRow(
                        icon: AppIcons.layers,
                        label: '协议',
                        value: display.protocol.label,
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
                      if (display.subscriptionName != null) ...[
                        const SizedBox(height: AppTokens.spacingSm),
                        _InfoRow(
                          icon: AppIcons.layers,
                          label: '来源订阅',
                          value: display.subscriptionName!,
                        ),
                      ],
                      if (display.isPlainText) ...[
                        const SizedBox(height: AppTokens.spacingSm),
                        _InfoRow(
                          icon: AppIcons.network,
                          label: '传输',
                          value: '明文',
                        ),
                      ],
                      // 有本地改动：标出来，并给“恢复默认”。
                      if (display.originDedupKey != null) ...[
                        const SizedBox(height: AppTokens.spacingSm),
                        Row(
                          children: [
                            AppIcon(
                              icon: AppIcons.pencil,
                              size: AppIconSize.sm,
                              color: tokens.gold,
                            ),
                            const SizedBox(width: AppTokens.spacingSm),
                            const Expanded(
                              child: Text('已修改（非订阅原始值）'),
                            ),
                            TextButton(
                              onPressed: _restoreDefault,
                              child: const Text('恢复默认'),
                            ),
                          ],
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
                        AppIcon(
                          icon: AppIcons.circleCheck,
                          color: tokens.gold,
                        ),
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
                        .selectNode(display);
                    if (!context.mounted) return;
                    if (ok) {
                      Navigator.of(context).pop();
                    } else {
                      final reason = ref.read(nodesProvider).selectionReason;
                      if (reason != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(reason)),
                        );
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
                            .testSingleSpeed(display);
                        if (!ok && context.mounted) {
                          final error = ref.read(nodesProvider).speedTestError;
                          if (error != null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error)),
                            );
                          }
                        }
                      },
                icon: const AppIcon(
                  icon: AppIcons.gauge,
                  size: AppIconSize.sm,
                ),
                label: Text(testing ? '测速中…' : '测速'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 编辑表单：名称、地址、端口、协议、UUID/密码、加密方式（仅 SS）、
  /// SNI、传输方式、WS 路径/Host（仅 ws）、TLS、flow（仅 VLESS）、
  /// REALITY 公钥/short id（仅 VLESS）、指纹、ALPN。
  /// 不合法就地提示、不保存（见 [_saveEdit]）。
  Widget _buildEditForm() {
    final protocol = _editProtocol ?? _node.protocol;
    final transport = _editTransport ?? _node.transport;
    // 传输方式下拉：tcp/ws/grpc/h2；原值不在这四项里时
    // （如 HY2 的 udp）也留着，别一切换就把原值丢了。
    final transportOptions = ['tcp', 'ws', 'grpc', 'h2'];
    if (!transportOptions.contains(transport)) {
      transportOptions.add(transport);
    }
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spacingMd),
        child: Column(
          children: [
            _EditField(controller: _nameController, label: '名称'),
            const SizedBox(height: AppTokens.spacingSm),
            _EditField(controller: _addressController, label: '地址'),
            const SizedBox(height: AppTokens.spacingSm),
            _EditField(
              controller: _portController,
              label: '端口',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: AppTokens.spacingSm),
            DropdownButtonFormField<NodeProtocol>(
              // 协议一变就重建下拉框（initialValue 只在首次建时生效，
              // 不换 key 的话下拉框里还显示旧协议）。
              key: ValueKey(protocol),
              initialValue: protocol,
              decoration: const InputDecoration(labelText: '协议'),
              items: NodeProtocol.values
                  .where((p) => p != NodeProtocol.unknown)
                  .map(
                    (p) => DropdownMenuItem(value: p, child: Text(p.label)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _editProtocol = value);
              },
            ),
            const SizedBox(height: AppTokens.spacingSm),
            _EditField(
              controller: _uuidController,
              label: _uuidLabel,
              obscureText: true,
            ),
            if (protocol == NodeProtocol.shadowsocks) ...[
              const SizedBox(height: AppTokens.spacingSm),
              _EditField(controller: _methodController, label: '加密方式'),
            ],
            const SizedBox(height: AppTokens.spacingSm),
            _EditField(controller: _sniController, label: 'SNI'),
            const SizedBox(height: AppTokens.spacingSm),
            DropdownButtonFormField<String>(
              // 传输方式一变就重建下拉框（initialValue 只在首次建时生效）。
              key: ValueKey(transport),
              initialValue: transport,
              decoration: const InputDecoration(labelText: '传输方式'),
              items: transportOptions
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _editTransport = value);
              },
            ),
            if (transport == 'ws') ...[
              const SizedBox(height: AppTokens.spacingSm),
              _EditField(controller: _wsPathController, label: 'WS 路径'),
              const SizedBox(height: AppTokens.spacingSm),
              _EditField(controller: _wsHostController, label: 'WS Host'),
            ],
            const SizedBox(height: AppTokens.spacingSm),
            // 不用 SwitchListTile：它在 GlassCard 的 DecoratedBox
            // 里会触发 ListTile 背景断言（按压涟漪会被卡片底色盖住）。
            Row(
              children: [
                const Expanded(child: Text('TLS')),
                Switch(
                  value: _editTls,
                  onChanged: (value) => setState(() => _editTls = value),
                ),
              ],
            ),
            if (protocol == NodeProtocol.vless) ...[
              const SizedBox(height: AppTokens.spacingSm),
              _EditField(controller: _flowController, label: 'flow'),
              const SizedBox(height: AppTokens.spacingSm),
              _EditField(
                controller: _realityPublicKeyController,
                label: 'REALITY 公钥',
              ),
              const SizedBox(height: AppTokens.spacingSm),
              _EditField(
                controller: _realityShortIdController,
                label: 'REALITY short id',
              ),
            ],
            const SizedBox(height: AppTokens.spacingSm),
            _EditField(controller: _fingerprintController, label: '指纹'),
            const SizedBox(height: AppTokens.spacingSm),
            _EditField(controller: _alpnController, label: 'ALPN'),
            if (_formError != null) ...[
              const SizedBox(height: AppTokens.spacingSm),
              Text(
                _formError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: AppTokens.spacingMd),
            FilledButton(
              onPressed: _saveEdit,
              child: const Text('保存'),
            ),
            const SizedBox(height: AppTokens.spacingSm),
            TextButton(onPressed: _exitEdit, child: const Text('取消')),
          ],
        ),
      ),
    );
  }
}

class _EditField extends StatelessWidget {
  const _EditField({
    required this.controller,
    required this.label,
    this.keyboardType,
    this.obscureText = false,
  });

  final TextEditingController? controller;
  final String label;
  final TextInputType? keyboardType;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      keyboardType: keyboardType,
      obscureText: obscureText,
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
