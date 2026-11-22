import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/userinfo.dart';
import '../../services/announcement_service.dart';
import '../../services/nodes_notifier.dart';
import '../../services/subscription_auto_refresh.dart';

/// “我的”页（切片 5）：账号区 + 订阅卡片 + 订阅更新 + 公告列表 +
/// 换绑 / 退出登录。
///
/// 数据全部复用 [nodesProvider]（切片 1 的订阅拉取、切片 3 的
/// userinfo 口径）：不重复拉订阅、不另算口径。
/// - 账号区：已绑定显示订阅地址的 host，到期日与剩余流量大字；
/// - 订阅更新：上次更新时间 + 手动刷新按钮；失败时原因常驻显示，
///   不静默失败；每天自动更新一次（仅 Wi-Fi），见
///   [SubscriptionAutoRefresh]；
/// - 公告：面板 `GET /api/v1/public-info` 的 `login_notice`，
///   拉不到显示“暂无公告”；
/// - 换绑：粘贴新链接重新绑定；退出登录：清绑定与本地配置。
/// 账号密码登录在切片 5 还没有（DEV-PLAN §10 是可选登录，
/// 不在 MVP 切片里），这里只做免登录模式。
class MePage extends ConsumerStatefulWidget {
  const MePage({super.key});

  @override
  ConsumerState<MePage> createState() => _MePageState();
}

class _MePageState extends ConsumerState<MePage> {
  String? _notice;
  bool _noticeLoaded = false;
  String? _subscriptionHost;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAnnouncement());
    unawaited(_loadSubscriptionHost());
    // 每天自动更新一次（仅 Wi-Fi）：条件不满足时什么都不做。
    unawaited(maybeAutoRefreshSubscription(ref));
  }

  Future<void> _loadAnnouncement() async {
    final notice =
        await ref.read(announcementServiceProvider).fetchNotice();
    if (mounted) {
      setState(() {
        _notice = notice;
        _noticeLoaded = true;
      });
    }
  }

  Future<void> _loadSubscriptionHost() async {
    final url =
        await ref.read(subscriptionServiceProvider).readSubscriptionUrl();
    final host = url == null ? null : Uri.tryParse(url)?.host;
    if (mounted && host != null && host.isNotEmpty) {
      setState(() => _subscriptionHost = host);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 手动刷新：复用 [NodesNotifier.refresh]；成功记一次时间
  /// （24 小时内自动更新不再拉）；失败原因在更新卡片里常驻显示。
  Future<void> _onRefresh() async {
    if (_refreshing) return;
    final nodesState = ref.read(nodesProvider);
    if (nodesState.status == NodesStatus.initial) {
      _showSnack('请先绑定订阅');
      return;
    }
    setState(() => _refreshing = true);
    try {
      await ref.read(nodesProvider.notifier).refresh();
      final state = ref.read(nodesProvider);
      if (state.status == NodesStatus.loaded) {
        await ref.read(subscriptionAutoRefreshProvider).markRefreshed();
        _showSnack('订阅已更新');
      }
      await _loadAnnouncement();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// 绑定 / 换绑订阅：粘贴完整链接，错了在弹窗里直接显示原因，
  /// 不关弹窗让用户改；成功才关。
  Future<void> _showBindDialog({required bool isRebind}) async {
    final controller = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isRebind ? '换绑订阅' : '绑定订阅'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: '粘贴完整订阅链接',
                  labelText: '订阅链接',
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final link = controller.text.trim();
                if (link.isEmpty) {
                  setDialogState(() => error = '先粘贴订阅链接');
                  return;
                }
                await ref.read(nodesProvider.notifier).bindAndRefresh(link);
                final state = ref.read(nodesProvider);
                if (state.status == NodesStatus.error) {
                  setDialogState(
                    () => error = state.errorMessage ?? '绑定失败',
                  );
                  return;
                }
                if (context.mounted) Navigator.pop(context, true);
              },
              child: const Text('绑定'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      await ref.read(subscriptionAutoRefreshProvider).markRefreshed();
      await _loadSubscriptionHost();
      _showSnack('订阅已绑定');
    }
  }

  /// 退出登录：免登录模式下就是清除绑定（订阅与本地配置一并清除），
  /// 面板侧用户不受影响；要点确认才清。
  Future<void> _onLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后订阅与本地配置一并清除，节点列表也会清空，确定要退出吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(nodesProvider.notifier).clear();
    if (mounted) {
      setState(() => _subscriptionHost = null);
      _showSnack('已退出登录，订阅已清除');
    }
  }

  @override
  Widget build(BuildContext context) {
    final nodesState = ref.watch(nodesProvider);
    final info = nodesState.userinfo;
    final bound = nodesState.status != NodesStatus.initial;
    final loading = nodesState.status == NodesStatus.loading;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 账号区：订阅 host、到期日、剩余流量大字。
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(bound ? '已绑定订阅' : '未登录（免登录模式）'),
            subtitle: Text(
              bound
                  ? (_subscriptionHost ?? '绑定订阅即可使用，无需注册账号')
                  : '绑定订阅即可使用，无需注册账号',
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 订阅卡片：剩余流量大字 + 已用/总量 + 到期日（userinfo 口径）。
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('我的订阅', style: TextStyle(fontSize: 16)),
                const SizedBox(height: 12),
                if (!bound) ...[
                  const Text('未绑定订阅'),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () => _showBindDialog(isRebind: false),
                    child: const Text('绑定订阅'),
                  ),
                ] else ...[
                  Text(
                    remainingText(info),
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 4),
                  const Text('剩余流量'),
                  const SizedBox(height: 12),
                  Text('已用 / 总量：${usedTotalText(info)}'),
                  const SizedBox(height: 4),
                  Text('到期日：${expireText(info)}'),
                  const SizedBox(height: 4),
                  // 限流展示（切片 8）：进度条 + 状态文案，只按 userinfo 头
                  // 里已有的数算；不限量或没拉到用量时不显示这一段。
                  if (info != null && info.usedRatio != null) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: info.usedRatio),
                    if (trafficLimitText(info) != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        trafficLimitText(info)!,
                        style: TextStyle(
                          color: trafficLimitStatus(info) ==
                                  TrafficLimitStatus.exceeded
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '流量口径：仅中转（直连流量不计入）；限流只按中转流量算，'
                    '直连不限流（节点侧按人计量未上线）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 订阅更新：上次更新时间 + 手动刷新；失败原因常驻显示。
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('订阅更新', style: TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                Text(
                  '上次更新：${nodesState.lastUpdated == null ? '尚未更新' : formatDateTime(nodesState.lastUpdated!)}',
                ),
                const SizedBox(height: 4),
                const Text('每天自动更新一次（仅 Wi-Fi）'),
                if (nodesState.status == NodesStatus.error &&
                    nodesState.errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '更新失败：${nodesState.errorMessage}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: (_refreshing || loading)
                          ? null
                          : _onRefresh,
                      child: Text(_refreshing ? '刷新中…' : '刷新订阅'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 公告列表：面板 public-info 的 login_notice。
        Card(
          child: ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: const Text('公告'),
            subtitle: Text(
              !_noticeLoaded
                  ? '加载中…'
                  : (_notice ?? '暂无公告'),
            ),
            trailing: const Icon(Icons.chevron_right),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text('换绑订阅'),
            subtitle: const Text('更换订阅链接或账号'),
            onTap: () => _showBindDialog(isRebind: true),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('退出登录'),
            subtitle: const Text('退出后订阅与本地配置一并清除'),
            onTap: _onLogout,
          ),
        ),
      ],
    );
  }
}
