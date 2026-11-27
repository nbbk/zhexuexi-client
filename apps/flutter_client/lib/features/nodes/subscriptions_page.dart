import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/app_motion.dart';
import '../../widgets/app_icon.dart';
import '../../core/app_tokens.dart';

import '../../core/app_theme.dart';
import '../../core/userinfo.dart';
import '../../services/content_intake.dart';
import '../../services/nodes_notifier.dart';
import '../../services/subscription_store.dart';
import '../../services/subscriptions_notifier.dart';
import '../../widgets/glass_card.dart';
import 'scan_page.dart';

/// 订阅管理页：订阅列表（名字、地址 host、启用开关、节点数、
/// 流量/到期摘要、上次刷新/报错）＋添加＋删除＋改名＋启用/停用
/// ＋刷新（单个刷新与全部刷新）。
///
/// 入口在节点页（粘贴入口附近的“管理订阅”按钮）。主订阅在列表里
/// 只支持改名/启用/刷新，不给删除按钮（解绑走现有的“退出登录/
/// 换绑”清除绑定流程，不在这里另起一套，避免跟远程配置打架）。
/// 界面沿用客户端原定的简洁列表风格＋共用毛玻璃卡片与品牌色，
/// 不照抄别的客户端的卡片样式；图标统一用 Material Icons 的
/// outlined 细线型（与客户端现有图标同一套），大小与线条一致。
/// 页面进出走淡入滑动转场（250ms）；列表增删走 AnimatedList
///（250ms），刷新不整列表闪一下。
class SubscriptionsPage extends ConsumerStatefulWidget {
  const SubscriptionsPage({super.key});

  @override
  ConsumerState<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends ConsumerState<SubscriptionsPage> {
  final _addController = TextEditingController();
  final _addFocusNode = FocusNode();
  final _listKey = GlobalKey<AnimatedListState>();
  String? _addError;
  final _refreshingIds = <String>{};

  /// 本地列表副本（AnimatedList 的增删动画靠它与 provider 列表做 diff）。
  List<SubscriptionEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(subscriptionsProvider.notifier).load());
  }

  @override
  void dispose() {
    _addController.dispose();
    _addFocusNode.dispose();
    super.dispose();
  }

  /// provider 列表变了：与本地副本 diff，增删走 AnimatedList 动画，
  /// 改名/启用只更新本地副本（不走增删动画、不闪）。
  void _syncList(
    List<SubscriptionEntry> oldList,
    List<SubscriptionEntry> newList,
  ) {
    final listState = _listKey.currentState;
    if (listState == null) {
      // AnimatedList 还没建出来（首次加载）：直接同步，不做动画。
      setState(() => _entries = List.of(newList));
      return;
    }
    // 先删（从后往前，索引不乱），退出动画 250ms。
    for (var i = oldList.length - 1; i >= 0; i--) {
      if (!newList.any((e) => e.id == oldList[i].id)) {
        final removed = oldList[i];
        final summary = _summaryFor(removed.id);
        _entries.removeAt(i);
        listState.removeItem(
          i,
          (context, animation) =>
              _buildAnimatedItem(removed, summary, animation),
        );
      }
    }
    // 再加（按新顺序插），进入动画 250ms。
    for (var i = 0; i < newList.length; i++) {
      if (!_entries.any((e) => e.id == newList[i].id)) {
        _entries.insert(i, newList[i]);
        listState.insertItem(i);
      }
    }
    // 同 id 的改名/启用变化：更新本地副本。
    var changed = false;
    for (var i = 0; i < _entries.length; i++) {
      for (final updated in newList) {
        if (updated.id == _entries[i].id &&
            (updated.name != _entries[i].name ||
                updated.enabled != _entries[i].enabled ||
                updated.url != _entries[i].url)) {
          _entries[i] = updated;
          changed = true;
        }
      }
    }
    if (changed) setState(() {});
  }

  SubscriptionSummary? _summaryFor(String id) {
    final summaries = ref.read(nodesProvider).subscriptionSummaries;
    for (final s in summaries) {
      if (s.id == id) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // 监听列表变化做 AnimatedList diff（回调在 build 外触发）。
    ref.listen<List<SubscriptionEntry>>(subscriptionsProvider, (prev, next) {
      _syncList(prev ?? const [], next);
    });
    final nodesState = ref.watch(nodesProvider);
    final summaries = {
      for (final s in nodesState.subscriptionSummaries) s.id: s,
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('管理订阅'),
        actions: [
          IconButton(
            icon: const AppIcon(icon: AppIcons.refresh),
            tooltip: '全部刷新',
            onPressed: () async {
              await ref.read(subscriptionsProvider.notifier).refreshAll();
              if (mounted) _showSnack('已刷新全部订阅');
            },
          ),
        ],
      ),
      body: GlassBackground(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spacingMd),
          child: Column(
            children: [
              _buildAddCard(),
              const SizedBox(height: AppTokens.spacingXs),
              Expanded(
                child: _entries.isEmpty
                    ? Center(
                        child: Text(
                          '还没有订阅，在上面粘贴订阅链接或扫码添加，\n或在节点页绑定自家面板的订阅。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: appThemeTokensOf(context).secondaryText,
                          ),
                        ),
                      )
                    : AnimatedList(
                        key: _listKey,
                        initialItemCount: _entries.length,
                        itemBuilder: (context, index, animation) {
                          final entry = _entries[index];
                          return _buildAnimatedItem(
                            entry,
                            summaries[entry.id],
                            animation,
                          );
                        },
                      ),
              ),
              const SizedBox(height: AppTokens.spacingXs),
              Text(
                '订阅链接只存本机，令牌进系统密钥库，不会明文保存。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: appThemeTokensOf(context).secondaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// “添加订阅”按钮与输入框回车共用：去首尾空白后走订阅添加，
  /// 失败原因显示在粘贴框下面（走映射后的原因，见 subscription_service）。
  Future<void> _submitAdd() async {
    final link = _addController.text.trim();
    if (link.isEmpty) return;
    final error = await ref.read(subscriptionsProvider.notifier).add(link);
    if (!mounted) return;
    if (error != null) {
      setState(() => _addError = error);
    } else {
      setState(() => _addError = null);
      _addController.clear();
      _showSnack('已添加订阅');
    }
  }

  /// “粘贴”按钮：读剪贴板填进输入框（去首尾空白），填上就给输入框
  /// 焦点，方便接着改；剪贴板是空的就把原因显示在框下面。
  Future<void> _pasteAdd() async {
    final pasted = await pasteClipboardInto(_addController);
    if (!mounted) return;
    if (pasted) {
      _addFocusNode.requestFocus();
    } else {
      setState(() => _addError = '剪贴板是空的，先复制订阅链接再粘贴');
    }
  }

  /// AnimatedList 的一项：淡入＋高度展开（250ms）。
  Widget _buildAnimatedItem(
    SubscriptionEntry entry,
    SubscriptionSummary? summary,
    Animation<double> animation,
  ) {
    return SizeTransition(
      sizeFactor: animation,
      child: FadeTransition(
        opacity: animation,
        child: _buildEntryCard(entry, summary),
      ),
    );
  }

  Widget _buildAddCard() {
    return GlassCard(
      padding: const EdgeInsets.all(AppTokens.spacingSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _addController,
                  focusNode: _addFocusNode,
                  decoration: const InputDecoration(
                    hintText: '粘贴完整订阅链接（如机场订阅）',
                    border: OutlineInputBorder(),
                  ),
                  // 链接是 URL：键盘给 URL 布局；点“粘贴”按钮直接读剪贴板
                  // 填入（去首尾空白），不用只靠长按菜单。
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submitAdd(),
                  maxLines: 3,
                  minLines: 1,
                ),
              ),
              const SizedBox(width: AppTokens.spacingSm),
              OutlinedButton(
                onPressed: _pasteAdd,
                child: const Text('粘贴'),
              ),
            ],
          ),
          if (_addError != null) ...[
            const SizedBox(height: AppTokens.spacingXs),
            // 报错文字走统一错误色（与首页/我的页/登录页同一口径）；
            // 项目里没有单独的错误色 token，不在这里写死红色。
            Text(
              _addError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: AppTokens.spacingSm),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _submitAdd,
                  icon: const AppIcon(icon: AppIcons.plus, size: AppIconSize.sm),
                  label: const Text('添加订阅'),
                ),
              ),
              const SizedBox(width: AppTokens.spacingSm),
              // 扫码添加（第 6 项）：扫订阅链接或节点链接的二维码，
              // 内容分流见 [handleContent]，扫到节点链接走单节点流程。
              OutlinedButton.icon(
                onPressed: _scanAndAdd,
                icon: const AppIcon(icon: AppIcons.scan, size: AppIconSize.sm),
                label: const Text('扫码'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 扫码添加：扫到的内容走 [handleContent] 分流，合法就直接加上，
  /// 不合法就把原因显示在粘贴框下面。
  Future<void> _scanAndAdd() async {
    final scanned = await Navigator.push<String>(
      context,
      appPageRoute(context, (_) => const ScanPage()),
    );
    if (scanned == null || scanned.trim().isEmpty || !mounted) return;
    final result = await handleContent(ref, scanned);
    if (!mounted) return;
    if (result.error != null) {
      setState(() => _addError = result.error);
    } else {
      setState(() => _addError = null);
      _showSnack(result.message ?? '已添加');
    }
  }

  Widget _buildEntryCard(
    SubscriptionEntry entry,
    SubscriptionSummary? summary,
  ) {
    final refreshing = _refreshingIds.contains(entry.id);
    return GlassCard(
      margin: const EdgeInsets.only(bottom: AppTokens.spacingXs),
      padding: const EdgeInsets.all(AppTokens.spacingSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (entry.isPrimary)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: appThemeTokensOf(context).gold
                        .withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(
                      AppTokens.radiusSmall,
                    ),
                  ),
                  child: Text(
                    '主订阅',
                    style: TextStyle(
                      fontSize: 12,
                      // 夜晚主色在深色底上只有 1.45:1 看不清，夜晚改走
                      // 点缀色（各皮肤夜晚都在 7.5:1 以上）；白天主色
                      // 在浅金底上可读，保持原样。
                      color:
                          Theme.of(context).brightness == Brightness.dark
                              ? appThemeTokensOf(context).gold
                              : appThemeTokensOf(context).deepBlue,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              Switch(
                value: entry.enabled,
                onChanged: (value) => _onToggle(entry, value),
              ),
            ],
          ),
          Text(
            entry.host,
            style: TextStyle(
              fontSize: 12,
              color: appThemeTokensOf(context).secondaryText,
            ),
          ),
          const SizedBox(height: 4),
          Text(_summaryLine(entry, summary)),
          if (summary?.errorMessage != null) ...[
            const SizedBox(height: 4),
            Text(
              summary!.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (summary?.lastUpdated != null)
            Text(
              '上次更新 ${formatDateTime(summary!.lastUpdated!)}',
              style: TextStyle(
                fontSize: 12,
                color: appThemeTokensOf(context).secondaryText,
              ),
            ),
          Row(
            children: [
              TextButton.icon(
                onPressed: refreshing ? null : () => _onRefreshOne(entry),
                icon: refreshing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const AppIcon(
                        icon: AppIcons.refresh,
                        size: AppIconSize.sm,
                      ),
                label: const Text('刷新'),
              ),
              TextButton.icon(
                onPressed: () => _onRename(entry),
                icon: const AppIcon(
                  icon: AppIcons.pencil,
                  size: AppIconSize.sm,
                ),
                label: const Text('改名'),
              ),
              // 主订阅不给删除按钮：解绑走现有的退出登录/换绑流程。
              if (!entry.isPrimary)
                TextButton.icon(
                  onPressed: () => _onDelete(entry),
                  icon: const AppIcon(
                    icon: AppIcons.trash,
                    size: AppIconSize.sm,
                  ),
                  label: const Text('删除'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 摘要行：节点数 · 已用/总量 · 到期；没拉到 userinfo 头时对应项是“—”。
  String _summaryLine(SubscriptionEntry entry, SubscriptionSummary? summary) {
    if (!entry.enabled) return '已停用';
    if (summary == null) return '还没拉过';
    final info = summary.userinfo;
    return '${summary.nodeCount} 个节点 · ${usedTotalText(info)} · ${expireText(info)}';
  }

  Future<void> _onToggle(SubscriptionEntry entry, bool value) async {
    if (!value) {
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('停用这个订阅？'),
          content: Text('停用后暂时不拉取「${entry.name}」，它的节点会从列表里消失，随时可以再打开。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('停用'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await ref.read(subscriptionsProvider.notifier).setEnabled(entry.id, value);
  }

  Future<void> _onRefreshOne(SubscriptionEntry entry) async {
    setState(() => _refreshingIds.add(entry.id));
    final ok = await ref
        .read(subscriptionsProvider.notifier)
        .refreshOne(entry.id);
    if (!mounted) return;
    setState(() => _refreshingIds.remove(entry.id));
    if (!ok) _showSnack('「${entry.name}」刷新失败，原因见列表');
  }

  Future<void> _onRename(SubscriptionEntry entry) async {
    final controller = TextEditingController(text: entry.name);
    final name = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('改名'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '订阅名字',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == entry.name) return;
    await ref.read(subscriptionsProvider.notifier).rename(entry.id, name);
  }

  Future<void> _onDelete(SubscriptionEntry entry) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个订阅？'),
        content: Text('删除后「${entry.name}」的节点不再显示，订阅链接也会一起删掉。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(subscriptionsProvider.notifier).remove(entry.id);
  }
}
