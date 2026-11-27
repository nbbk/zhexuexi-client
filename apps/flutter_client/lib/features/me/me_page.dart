import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/app_motion.dart';
import '../../widgets/app_icon.dart';
import '../../core/app_tokens.dart';

import '../../core/userinfo.dart';
import '../../features/announcements/announcement_list_page.dart';
import '../../services/announcement_service.dart';
import '../../services/auth_notifier.dart';
import '../../services/nodes_notifier.dart';
import '../../services/subscription_auto_refresh.dart';
import '../../widgets/glass_card.dart';
import '../auth/login_page.dart';

/// “我的”页（切片 5）：账号区 + 订阅卡片 + 订阅更新 + 公告列表 +
/// 换绑 / 退出登录。
///
/// 数据全部复用 [nodesProvider]（切片 1 的订阅拉取、切片 3 的
/// userinfo 口径）：不重复拉订阅、不另算口径。
/// - 账号区：已绑定显示订阅地址的 host，到期日与剩余流量大字；
/// - 订阅更新：上次更新时间 + 手动刷新按钮；失败时原因常驻显示，
///   不静默失败；每天自动更新一次（仅 Wi-Fi），见
///   [SubscriptionAutoRefresh]；
/// - 公告：[announcementsProvider] 的多条公告（远程配置 / 面板
///   public-info / 面板公告接口 / login_notice），有公告才显示，
///   没有就隐藏（0.1.2）；
/// - 换绑：粘贴新链接重新绑定；
/// - 账号登录（切片 9，DEV-PLAN §10.2）：未登录时账号区有“账号登录”入口，
///   点进登录页；已登录时账号区显示账号名；退出登录分两路——已登录只清
///   会话、订阅不断线，免登录仍是清绑定与本地配置。
class MePage extends ConsumerStatefulWidget {
  const MePage({super.key});

  @override
  ConsumerState<MePage> createState() => _MePageState();
}

class _MePageState extends ConsumerState<MePage> {
  String? _subscriptionHost;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSubscriptionHost());
    // 账号登录态恢复（切片 9）：令牌与账号名都在才算登录态，
    // 读不到就当免登录，不阻断界面。
    unawaited(ref.read(authProvider.notifier).restore());
    // 每天自动更新一次（仅 Wi-Fi）：条件不满足时什么都不做。
    unawaited(maybeAutoRefreshSubscription(ref));
  }

  Future<void> _loadSubscriptionHost() async {
    final url = await ref
        .read(subscriptionServiceProvider)
        .readSubscriptionUrl();
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
      // 手动刷新订阅时公告也重拉一次（共用 provider）。
      ref.invalidate(announcementsProvider);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// 绑定 / 换绑订阅：粘贴完整链接，错了在弹窗里直接显示原因，
  /// 不关弹窗让用户改；成功才关。
  Future<void> _showBindDialog({required bool isRebind}) async {
    final controller = TextEditingController();
    String? error;
    final ok = await showAppDialog<bool>(
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
                const SizedBox(height: AppTokens.spacingXs),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                  setDialogState(() => error = state.errorMessage ?? '绑定失败');
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

  /// 退出登录（DEV-PLAN §10.2）：分两路——
  /// 已登录只清会话令牌，订阅与节点不受影响；
  /// 免登录时就是清除绑定（订阅与本地配置一并清除）。
  /// 两路都要点确认才执行。
  Future<void> _onLogout() async {
    final loggedIn = ref.read(authProvider).loggedIn;
    if (loggedIn) {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('退出登录'),
          content: const Text('退出后只清除本地登录会话，订阅与节点不受影响，确定要退出吗？'),
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
      await ref.read(authProvider.notifier).logout();
      if (mounted) _showSnack('已退出登录，订阅不受影响');
      return;
    }
    final confirmed = await showAppDialog<bool>(
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
    final auth = ref.watch(authProvider);
    final username = auth.username;
    final planName = auth.planName;
    final announcementList = ref.watch(announcementsProvider).valueOrNull;

    return GlassBackground(
      child: ListView(
      padding: const EdgeInsets.all(AppTokens.spacingMd),
      children: [
        // 账号区：已登录显示账号名；未登录显示绑定状态。
        GlassCard(
          child: ListTile(
            leading: const CircleAvatar(child: AppIcon(icon: AppIcons.user)),
            title: Text(
              username != null
                  ? '已登录：$username'
                  : (bound ? '已绑定订阅' : '未登录（免登录模式）'),
            ),
            subtitle: Text(
              username != null
                  ? '账号登录'
                  : (bound
                        ? (_subscriptionHost ?? '绑定订阅即可使用，无需注册账号')
                        : '绑定订阅即可使用，无需注册账号'),
            ),
          ),
        ),
        // 账号登录入口（切片 9）：只在未登录时显示。
        if (username == null) ...[
          const SizedBox(height: AppTokens.spacingMd),
          GlassCard(
            child: ListTile(
              leading: const AppIcon(icon: AppIcons.logIn),
              title: const Text('账号登录'),
              subtitle: const Text('用面板账号登录，换设备不用重新导链接'),
              onTap: () => Navigator.push(
                context,
                appPageRoute(context, (_) => const LoginPage()),
              ),
            ),
          ),
        ],
        const SizedBox(height: AppTokens.spacingMd),
        // 订阅卡片：剩余流量大字 + 已用/总量 + 到期日（userinfo 口径）。
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spacingMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('我的订阅', style: TextStyle(fontSize: 16)),
                const SizedBox(height: AppTokens.spacingSm),
                if (!bound) ...[
                  const Text('未绑定订阅'),
                  const SizedBox(height: AppTokens.spacingSm),
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
                  const SizedBox(height: AppTokens.spacingSm),
                  Text('已用 / 总量：${usedTotalText(info)}'),
                  const SizedBox(height: 4),
                  Text('到期日：${expireText(info)}'),
                  // 套餐档位名（0.1.12）：登录回包 plan_name / plan.name；
                  // 未登录或没有档位时这一行不显示，不留占位。
                  if (planName != null && planName.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('套餐：$planName'),
                  ],
                  const SizedBox(height: 4),
                  // 限流展示（切片 8）：进度条 + 状态文案，只按 userinfo 头
                  // 里已有的数算；不限量或没拉到用量时不显示这一段。
                  if (info != null && info.usedRatio != null) ...[
                    const SizedBox(height: AppTokens.spacingXs),
                    LinearProgressIndicator(value: info.usedRatio),
                    if (trafficLimitText(info) != null) ...[
                      const SizedBox(height: AppTokens.spacingXs),
                      Text(
                        trafficLimitText(info)!,
                        style: TextStyle(
                          color:
                              trafficLimitStatus(info) ==
                                  TrafficLimitStatus.exceeded
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '限流按全部节点流量算',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: AppTokens.spacingMd),
        // 订阅更新：上次更新时间 + 手动刷新；失败原因常驻显示。
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spacingMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('订阅更新', style: TextStyle(fontSize: 16)),
                const SizedBox(height: AppTokens.spacingXs),
                Text(
                  '上次更新：${nodesState.lastUpdated == null ? '尚未更新' : formatDateTime(nodesState.lastUpdated!)}',
                ),
                const SizedBox(height: 4),
                const Text('每天自动更新一次（仅 Wi-Fi）'),
                if (nodesState.status == NodesStatus.error &&
                    nodesState.errorMessage != null) ...[
                  const SizedBox(height: AppTokens.spacingXs),
                  Text(
                    '更新失败：${nodesState.errorMessage}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: AppTokens.spacingSm),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: (_refreshing || loading) ? null : _onRefresh,
                      child: Text(_refreshing ? '刷新中…' : '刷新订阅'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppTokens.spacingMd),
        // 公告（0.1.2）：有公告才渲染，副标题“共 N 条，点击查看”，
        // chevron 变活、点进列表页；空/加载中整个 Card＋其后
        // SizedBox 都不渲染。
        if (announcementList != null && announcementList.isNotEmpty) ...[
          GlassCard(
            child: ListTile(
              leading: const AppIcon(icon: AppIcons.megaphone),
              title: const Text('公告'),
              subtitle: Text('共 ${announcementList.length} 条，点击查看'),
              trailing: const AppIcon(icon: AppIcons.chevronRight),
              onTap: () => Navigator.push(
                context,
                appPageRoute(
                  context,
                  (_) => const AnnouncementListPage(),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppTokens.spacingMd),
        ],
        GlassCard(
          child: ListTile(
            leading: const AppIcon(icon: AppIcons.swap),
            title: const Text('换绑订阅'),
            subtitle: const Text('更换订阅链接或账号'),
            onTap: () => _showBindDialog(isRebind: true),
          ),
        ),
        const SizedBox(height: AppTokens.spacingMd),
        GlassCard(
          child: ListTile(
            leading: const AppIcon(icon: AppIcons.logOut),
            title: const Text('退出登录'),
            subtitle: Text(
              username != null ? '只清除本地登录会话，订阅与节点不受影响' : '退出后订阅与本地配置一并清除',
            ),
            onTap: _onLogout,
          ),
        ),
      ],
      ),
    );
  }
}
