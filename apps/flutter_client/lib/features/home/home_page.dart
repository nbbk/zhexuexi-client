import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/clash_api_client.dart';
import '../../core/core_provider.dart';
import '../../core/node_model.dart';
import '../../core/routing_mode.dart';
import '../../core/singbox_core.dart';
import '../../core/userinfo.dart';
import '../../services/custom_rules_notifier.dart';
import '../../services/nodes_notifier.dart';
import '../../services/remote_config_notifier.dart';
import '../../services/routing_mode_notifier.dart';
import '../../services/settings_notifier.dart';

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
  /// 强制更新时（切片 7）不启动，只弹升级说明。
  Future<void> _onToggle() async {
    if (_busy ||
        _status == CoreStatus.starting ||
        _status == CoreStatus.stopping) {
      return;
    }
    if (ref.read(remoteConfigProvider).forceUpdateRequired) {
      await _showForceUpdateDialog();
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
      final result = await core.applyNodes(
        nodesState.nodes,
        mode: mode,
        // 带着当前选中的节点生成配置：节点页选过的节点，启动后还用它，
        // 不然每次启动都回到默认规则（第一个直连节点）。
        selectedNodeName: nodesState.selectedNodeName,
        // 自定义规则与 TUN 开关跟着一起进配置（切片 6）：启动不能把
        // 设置页配好的规则与 TUN 丢掉。
        customRules: ref.read(customRulesProvider.notifier).activeRules,
        tunEnabled: ref.read(settingsProvider).tun,
      );
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

  /// 强制更新说明（切片 7）：配置要求强制更新，且当前版本低于最低版本。
  /// 只用于旧版解析不了新订阅格式这种真断裂场景，不拿来当日常推送。
  /// 下载地址（切片 8）：远程配置的 `download_url`，有就显示成可复制
  /// 的文本（不引 url_launcher，不在本机假装能打开浏览器）；
  /// 配置里没给时不写地址，只说明原因。
  Future<void> _showForceUpdateDialog() async {
    final config = ref.read(remoteConfigProvider).config;
    final downloadUrl = config.downloadUrl;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('需要升级客户端'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              config.forceUpdateMessage ??
                  '当前版本无法解析新订阅格式，请升级到最新版。',
            ),
            if (downloadUrl.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('下载地址（长按复制）：'),
              const SizedBox(height: 4),
              SelectableText(downloadUrl),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 配置中心重试（离线提示条上的“重试”）：拉一次远程配置，
  /// 拉到了提示条自动消失，拉不到还留着。
  Future<void> _retryConfig() async {
    await ref.read(remoteConfigProvider.notifier).refresh();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 当前节点：节点页选中的节点（[NodesState.selectedNode]），没选过
  /// 时按默认规则（第一个直连节点，没有时第一个）；测速在切片 4，
  /// 测过的节点在这里显示延迟。
  String _currentNodeSubtitle(Node? currentNode) {
    if (currentNode == null) return '绑定订阅后自动选择最快的节点';
    if (currentNode.latencyMs != null) {
      return '延迟 ${currentNode.latencyMs}ms';
    }
    if (currentNode.latencyFailed) return '测速失败';
    return '未测速';
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

  /// 已用 / 总量格、剩余格、到期格的文案见 `userinfo.dart` 的同名
  /// 公共函数（首页与我的页共用同一套口径，不各写一份）。
  String _usedTotalText(SubscriptionUserinfo? info) => usedTotalText(info);

  String _remainingText(SubscriptionUserinfo? info) => remainingText(info);

  String _expireText(SubscriptionUserinfo? info) => expireText(info);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodesState = ref.watch(nodesProvider);
    final modeState = ref.watch(routingModeProvider);
    final remoteState = ref.watch(remoteConfigProvider);
    final info = nodesState.userinfo;
    final currentNode = nodesState.selectedNode;
    final switching = _status == CoreStatus.starting ||
        _status == CoreStatus.stopping ||
        _busy;
    final rateText = _status == CoreStatus.started && _sample != null
        ? '↑ ${formatSpeed(_sample!.up)}\n↓ ${formatSpeed(_sample!.down)}'
        : '—';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 远程配置状态条（切片 7）：拉不到配置时给一句提示，不静默；
        // 强制更新时拦住大开关（点开关弹升级说明）。
        if (remoteState.forceUpdateRequired)
          Card(
            child: ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: const Text('当前版本过低，请升级后使用'),
              subtitle: Text(
                '最低可用版本 ${remoteState.config.minAppVersion}',
              ),
              trailing: TextButton(
                onPressed: _showForceUpdateDialog,
                child: const Text('查看详情'),
              ),
            ),
          ),
        if (remoteState.offline)
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_off_outlined),
              title: const Text('配置中心暂时连不上，正在用上次的配置'),
              trailing: TextButton(
                onPressed: _retryConfig,
                child: const Text('重试'),
              ),
            ),
          ),
        if (remoteState.source == RemoteConfigSource.bundled)
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_off_outlined),
              title: const Text('首次启动需要联网拉取配置'),
              subtitle: const Text('拉不到配置也能先手动粘贴订阅使用'),
              trailing: TextButton(
                onPressed: _retryConfig,
                child: const Text('重试'),
              ),
            ),
          ),
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
            subtitle: Text(_currentNodeSubtitle(currentNode)),
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
        // 限流状态行（切片 8）：只在接近限额 / 已超量时出现，
        // 文案与我的页订阅卡片同一套口径。
        if (trafficLimitText(info) != null) ...[
          const SizedBox(height: 4),
          Text(
            trafficLimitText(info)!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: trafficLimitStatus(info) == TrafficLimitStatus.exceeded
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
        ],
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
