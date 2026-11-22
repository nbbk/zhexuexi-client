import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/clash_api_client.dart';
import '../../core/core_provider.dart';
import '../../core/node_model.dart';
import '../../core/routing_mode.dart';
import '../../core/singbox_core.dart';
import '../../core/userinfo.dart';
import '../../services/nodes_notifier.dart';
import '../../services/routing_mode_notifier.dart';

/// 首页：一个大开关 + 当前节点 + 实时速率 + 流量三格 + 模式切换 + 公告栏。
///
/// 切片 3：开关接真实核心（[CoreService]），速率读 Clash API `/traffic`，
/// 流量三格读订阅 `subscription-userinfo` 头（中转口径），模式三档
/// 切换立即生效（失败回滚旧模式）。
/// 流量口径写在界面上：直连流量不经过中转机，不在 userinfo 头里，
/// 首页三格是“仅中转”，不要把它当成全部流量。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key, required this.onGoToMe});

  /// 跳到“我的”页（绑定订阅）的回调。
  final VoidCallback onGoToMe;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  late CoreStatus _status;
  TrafficSample? _sample;
  bool _busy = false;
  StreamSubscription<CoreStatus>? _statusSub;
  StreamSubscription<TrafficSample>? _trafficSub;

  @override
  void initState() {
    super.initState();
    final core = ref.read(coreServiceProvider);
    _status = core.status;
    _statusSub = core.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _status = status);
      _syncTraffic();
    });
    _syncTraffic();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _trafficSub?.cancel();
    super.dispose();
  }

  /// 核心已启动时订阅 Clash API 实时流量，否则取消订阅、速率回“—”。
  /// 核心停止后 127.0.0.1:9090 连不上，流以错误结束，同样回“—”。
  void _syncTraffic() {
    if (_status == CoreStatus.started && _trafficSub == null) {
      final client = ref.read(clashApiClientProvider);
      _trafficSub = client.trafficStream().listen(
        (sample) {
          if (mounted) setState(() => _sample = sample);
        },
        onError: (_) {
          if (mounted) setState(() => _sample = null);
        },
        onDone: () {
          if (mounted) setState(() => _sample = null);
        },
      );
    } else if (_status != CoreStatus.started && _trafficSub != null) {
      _trafficSub?.cancel();
      _trafficSub = null;
      if (mounted) setState(() => _sample = null);
    }
  }

  /// 大开关：已启动时停核心；未启动时先按当前模式生成配置（校验失败
  /// 保留旧配置、不启动），再启动核心。没有节点时不启动，提示先绑定订阅。
  Future<void> _onToggle() async {
    if (_busy ||
        _status == CoreStatus.starting ||
        _status == CoreStatus.stopping) {
      return;
    }
    final core = ref.read(coreServiceProvider);
    if (_status == CoreStatus.started) {
      setState(() => _busy = true);
      try {
        await core.stop();
      } catch (e) {
        _showSnack('断开失败：$e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    final nodesState = ref.read(nodesProvider);
    if (nodesState.nodes.isEmpty) {
      _showSnack('请先绑定订阅，再开启代理');
      widget.onGoToMe();
      return;
    }
    setState(() => _busy = true);
    try {
      final mode = ref.read(routingModeProvider).mode;
      final result = await core.applyNodes(nodesState.nodes, mode: mode);
      if (!result.ok) {
        _showSnack('配置生成失败，已保持上次连接');
        return;
      }
      if (result.skipped.isNotEmpty) {
        _showSnack('${result.skipped.length} 个节点暂不支持，已跳过');
      }
      await core.start();
    } on StateError catch (e) {
      _showSnack('启动失败：${e.message}');
    } catch (e) {
      _showSnack('启动失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 模式切换：失败时 [RoutingModeNotifier.setMode] 已回滚旧模式，
  /// 这里只提示一句，不再动状态。
  Future<void> _onModeChanged(Set<String> selected) async {
    if (selected.isEmpty) return;
    final next = RoutingMode.fromStorage(selected.first);
    final ok = await ref.read(routingModeProvider.notifier).setMode(next);
    if (!ok && mounted) _showSnack('切换失败，已保持原模式');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 当前节点：selector 的默认节点（第一个直连节点，没有时取第一个），
  /// 与配置生成里的默认选择同一条规则；测速在切片 4，延迟先写“未测速”。
  Node? _currentNode(List<Node> nodes) {
    if (nodes.isEmpty) return null;
    for (final node in nodes) {
      if (node.source == NodeSource.direct) return node;
    }
    return nodes.first;
  }

  String _statusText() {
    final core = ref.read(coreServiceProvider);
    return switch (_status) {
      CoreStatus.stopped => '未连接',
      CoreStatus.starting => '连接中…',
      CoreStatus.started => '已连接',
      CoreStatus.stopping => '断开中…',
      CoreStatus.error =>
        '连接失败${core.lastError == null ? '' : '：${core.lastError}'}',
    };
  }

  /// 已用 / 总量格：没有 userinfo 头或已用未知时显示“—”，不编数据；
  /// 不限量（total 为 null 或 0）时只写已用 + “不限量”。
  String _usedTotalText(SubscriptionUserinfo? info) {
    if (info == null) return '—';
    final used = info.used;
    if (used == null) return '—';
    if (info.isUnlimited) return '${formatBytes(used)} / 不限量';
    return '${formatBytes(used)} / ${formatBytes(info.total!)}';
  }

  /// 剩余格：没有头或已用未知时“—”；不限量时“不限量”；超量时“已超量”。
  String _remainingText(SubscriptionUserinfo? info) {
    if (info == null) return '—';
    if (info.isUnlimited) return '不限量';
    final remaining = info.remaining;
    if (remaining == null) return '—';
    if (remaining < 0) return '已超量';
    if (remaining == 0) return '已用完';
    return formatBytes(remaining);
  }

  /// 到期格：没有头或头里没给 expire 时“—”；expire 为 0 时“永不过期”；
  /// 否则写日期＋剩余天数（当天到期写“今天到期”，已过期写“已到期”）。
  String _expireText(SubscriptionUserinfo? info) {
    if (info == null || info.expire == null) return '—';
    if (info.expire == 0) return '永不过期';
    final date = info.expireDate;
    if (date == null) return '—';
    if (info.isExpired) return '已到期';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = date.difference(today).inDays;
    if (days <= 0) return '${formatDateYmd(date)}（今天到期）';
    return '${formatDateYmd(date)}（剩 $days 天）';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodesState = ref.watch(nodesProvider);
    final modeState = ref.watch(routingModeProvider);
    final info = nodesState.userinfo;
    final currentNode = _currentNode(nodesState.nodes);
    final switching = _status == CoreStatus.starting ||
        _status == CoreStatus.stopping ||
        _busy;
    final rateText = _status == CoreStatus.started && _sample != null
        ? '↑ ${formatSpeed(_sample!.up)}\n↓ ${formatSpeed(_sample!.down)}'
        : '—';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 公告栏（阶段 1 接面板公告；切片 5 前占位）。
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
                backgroundColor: _status == CoreStatus.started
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
              ),
              onPressed: switching ? null : _onToggle,
              child: Icon(
                _status == CoreStatus.started
                    ? Icons.power
                    : Icons.power_settings_new,
                size: 48,
                color: _status == CoreStatus.started
                    ? Colors.white
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(_statusText(), style: theme.textTheme.titleMedium),
        ),
        const SizedBox(height: 24),
        // 当前节点。
        Card(
          child: ListTile(
            leading: const Icon(Icons.public),
            title: Text(
              currentNode == null ? '当前节点：未选择' : '当前节点：${currentNode.name}',
            ),
            subtitle: Text(
              currentNode == null
                  ? '绑定订阅后自动选择最快的节点'
                  : '未测速（切片 4 接测速）',
            ),
            trailing: currentNode == null
                ? TextButton(
                    onPressed: widget.onGoToMe,
                    child: const Text('去订阅'),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 16),
        // 实时速率 + 流量三格（userinfo 头，中转口径）。
        Row(
          children: [
            Expanded(
              child: _StatCell(label: '实时速率', value: rateText),
            ),
            Expanded(
              child: _StatCell(label: '已用 / 总量', value: _usedTotalText(info)),
            ),
            Expanded(
              child: _StatCell(label: '剩余流量', value: _remainingText(info)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StatCell(label: '到期日', value: _expireText(info)),
            ),
            const Expanded(
              child: _StatCell(label: '流量口径', value: '仅中转'),
            ),
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          info == null
              ? '未拉到流量数据，刷新订阅后显示；流量口径仅中转，直连流量不计入'
              : '流量口径：仅中转（直连流量不计入，以面板用量为准）',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        // 模式切换（三档，切换后重载配置，失败回滚旧模式）。
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'rule', label: Text('规则模式')),
            ButtonSegment(value: 'global', label: Text('全局模式')),
            ButtonSegment(value: 'direct', label: Text('直连模式')),
          ],
          selected: {modeState.mode.storageValue},
          onSelectionChanged: modeState.switching ? null : _onModeChanged,
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
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
        child: Column(
          children: [
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
