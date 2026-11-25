import 'package:animations/animations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../widgets/app_icon.dart';

import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/app_tokens.dart';
import '../../core/geo_flag.dart';
import '../../core/node_model.dart';
import '../../services/content_intake.dart';
import '../../services/nodes_notifier.dart';
import '../../widgets/glass_card.dart';
import 'node_detail_page.dart';
import 'scan_page.dart';
import 'subscriptions_page.dart';

/// 节点页：搜索框 + 分组 + 一键测速 / 自动选择 + 节点列表。
///
/// 切片 1：真实节点列表（订阅拉取＋三种格式解析）。
/// 搜索框与两个按钮常驻；下方按状态显示：未绑定→粘贴订阅链接入口，
/// 加载中→转圈，失败→原因＋重试，成功→按 A 组/B 组分组的节点行
/// （A=直连，B=中转；分组标题不直接写“中转”“直连”，与节点命名
/// 规矩一致；分组按 A/B 后缀认，见 subscription_parser.dart）。
/// 切片 4：一键测速与自动选择已接线（测速要核心在跑，见
/// [NodesNotifier.testAllSpeeds]）；测速失败的节点标灰、不自动选；
/// 点一行选中该节点（当前节点置顶标“使用中”）。
///
/// 性能（UI 优化）：页面只监听结构性数据（状态、节点集合、选中、
/// 失败数、测速进度、提示文案），单个节点的延迟变化不触发整页重建——
/// 延迟由行自己 select（见 [_NodeRow]），只重建该行。
/// 列表是 CustomScrollView + SliverFixedExtentList（行高固定 64，
/// cacheExtent 500），行按内容 key 复用。
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
    // 结构性监听（见文件头注释）：节点集合变化时才重建整页；
    // 延迟/失败/选中等易变数据由行自己 select，不经过这里。
    final structure = ref.watch(
      nodesProvider.select(
        (s) => (
          status: s.status,
          // 节点集合签名（key＋名字＋明文＋来源）：集合变化才重建，
          // 延迟变化不改变签名。
          keys: s.nodes
              .map(
                (n) =>
                    '${n.dedupKey}|${n.name}|${n.isPlainText}|${n.subscriptionName}',
              )
              .join('\n'),
          selected: s.selectedNodeName,
          failed: s.failedCount,
          testing: s.testingSpeed,
          tested: s.speedTestedCount,
          total: s.speedTestTotal,
          notice: s.addressNotice,
          speedError: s.speedTestError,
          reason: s.selectionReason,
          error: s.errorMessage,
          updated: s.lastUpdated,
        ),
      ),
    );
    // 节点列表在结构变化时才读（ref.read）：延迟变化不经过这里。
    final nodes = ref.read(nodesProvider).nodes;
    final hasNodes = nodes.isNotEmpty;
    // 横幅与角标的配色只读主题 token，不写死 Material 原色。
    final tokens = appThemeTokensOf(context);
    final colorScheme = Theme.of(context).colorScheme;
    return GlassBackground(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppTokens.spacingMd),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                prefixIcon: AppIcon(icon: AppIcons.search),
                hintText: '搜索节点',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value.trim()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spacingMd,
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    // 一键测速：核心没启动时点了一样会提示（不在这里置灰，
                    // 提示文案比灰按钮更清楚）；测速中禁用防重复点。
                    onPressed: !hasNodes || structure.testing
                        ? null
                        : () async {
                            final ok = await ref
                                .read(nodesProvider.notifier)
                                .testAllSpeeds();
                            if (!ok && mounted) {
                              final error = ref
                                  .read(nodesProvider)
                                  .speedTestError;
                              if (error != null) _showSnack(error);
                            }
                          },
                    icon: const AppIcon(icon: AppIcons.gauge),
                    label: Text(
                      structure.testing
                          ? '测速中 ${structure.tested}/${structure.total}'
                          : '一键测速',
                    ),
                  ),
                ),
                const SizedBox(width: AppTokens.spacingSm),
                Expanded(
                  child: OutlinedButton.icon(
                    // 自动选择：延迟最低的可用节点；没测过先测一轮再选。
                    onPressed: !hasNodes || structure.testing
                        ? null
                        : () async {
                            final ok = await ref
                                .read(nodesProvider.notifier)
                                .autoSelect();
                            if (mounted) {
                              final reason = ref
                                  .read(nodesProvider)
                                  .selectionReason;
                              if (reason != null) _showSnack(reason);
                              if (!ok) {
                                final error = ref
                                    .read(nodesProvider)
                                    .speedTestError;
                                if (error != null) _showSnack(error);
                              }
                            }
                          },
                    icon: const AppIcon(icon: AppIcons.sparkles),
                    label: const Text('自动选择'),
                  ),
                ),
              ],
            ),
          ),
          // 订阅地址刚被远程配置换过（切片 7）：顶部显示一句，点叉关掉。
          if (structure.notice != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(
                AppTokens.spacingMd,
                AppTokens.spacingXs,
                AppTokens.spacingMd,
                0,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spacingSm,
                vertical: AppTokens.spacingXs,
              ),
              decoration: BoxDecoration(
                // 提示横幅：香槟金浅底＋金色细线边框，文字走 onSurface。
                color: tokens.gold.withValues(alpha: 0.10),
                border: Border.all(
                  color: tokens.gold.withValues(alpha: 0.45),
                ),
                borderRadius: BorderRadius.circular(AppTokens.radiusSmall),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      structure.notice!,
                      style: TextStyle(color: colorScheme.onSurface),
                    ),
                  ),
                  IconButton(
                    icon: const AppIcon(icon: AppIcons.x),
                    tooltip: '关闭提示',
                    onPressed: () =>
                        ref.read(nodesProvider.notifier).dismissAddressNotice(),
                  ),
                ],
              ),
            ),
          // 测速失败的原因（核心未启动等）与自动选择的解释常驻显示，
          // 不只闪一下 SnackBar：用户回来看得到“为什么”。
          if (structure.speedError != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(
                AppTokens.spacingMd,
                AppTokens.spacingXs,
                AppTokens.spacingMd,
                0,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spacingSm,
                vertical: AppTokens.spacingXs,
              ),
              decoration: BoxDecoration(
                // 报错横幅：错误色浅底＋错误色细线边框，文字走错误色
                //（与首页/我的页/登录页的 colorScheme.error 同一口径）。
                color: colorScheme.error.withValues(alpha: 0.08),
                border: Border.all(
                  color: colorScheme.error.withValues(alpha: 0.35),
                ),
                borderRadius: BorderRadius.circular(AppTokens.radiusSmall),
              ),
              child: Text(
                structure.speedError!,
                style: TextStyle(color: colorScheme.error),
              ),
            ),
          if (structure.reason != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.spacingMd,
                AppTokens.spacingXs,
                AppTokens.spacingMd,
                0,
              ),
              child: Text(
                structure.reason!,
                style: TextStyle(
                  fontSize: 12,
                  color: appThemeTokensOf(context).secondaryText,
                ),
              ),
            ),
          const SizedBox(height: AppTokens.spacingXs),
          Expanded(
            child: _buildBody(
              structure.status,
              structure.error,
              nodes,
              structure.selected,
              structure.failed,
              structure.updated,
              structure.keys,
            ),
          ),
        ],
      ),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 粘贴框提交：订阅链接、单条节点链接、订阅正文都走 [handleContent]
  /// 分流——自家面板链接进主订阅绑定，其它订阅链接往多订阅列表里
  /// 加一个（不顶掉旧的），节点链接加为单节点。
  Future<void> _submitPastedLink() async {
    final link = _linkController.text.trim();
    if (link.isEmpty) return;
    final result = await handleContent(ref, link);
    if (!mounted) return;
    if (result.error != null) {
      _showSnack(result.error!);
    } else {
      _linkController.clear();
      _showSnack(result.message ?? '已添加');
    }
  }

  /// 打开扫码页：扫到的内容走 [handleContent] 分流（单节点/订阅/正文），
  /// 合法就直接加上，不合法就提示。
  Future<void> _openScan() async {
    final scanned = await Navigator.push<String>(
      context,
      appPageRoute(context, (_) => const ScanPage()),
    );
    if (scanned == null || scanned.trim().isEmpty || !mounted) return;
    final result = await handleContent(ref, scanned);
    if (!mounted) return;
    _showSnack(result.error ?? result.message ?? '已添加');
  }

  /// 添加单个节点：粘贴一条节点链接，或点扫码扫节点/订阅二维码。
  /// 粘贴/扫码的内容都走 [handleContent] 分流，不用用户自己分清。
  Future<void> _showAddNodeDialog() async {
    final controller = TextEditingController();
    String? error;
    await showAppDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> submit(String raw) async {
            if (raw.trim().isEmpty) return;
            final result = await handleContent(ref, raw);
            if (!dialogContext.mounted) return;
            if (result.error != null) {
              setDialogState(() => error = result.error);
              return;
            }
            Navigator.pop(dialogContext);
            if (mounted) _showSnack(result.message ?? '已添加');
          }

          return AlertDialog(
            title: const Text('添加节点'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: '粘贴一条节点链接，如 vless://…',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                  minLines: 1,
                  autofocus: true,
                ),
                if (error != null) ...[
                  const SizedBox(height: AppTokens.spacingXs),
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
              TextButton.icon(
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  await _openScan();
                },
                icon: const AppIcon(
                  icon: AppIcons.scan,
                  size: AppIconSize.sm,
                ),
                label: const Text('扫码'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => submit(controller.text),
                child: const Text('添加'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
  }

  void _openSubscriptions() {
    Navigator.push(
      context,
      appPageRoute(context, (_) => const SubscriptionsPage()),
    );
  }

  Widget _buildBody(
    NodesStatus status,
    String? errorMessage,
    List<Node> nodes,
    String? selectedName,
    int failedCount,
    DateTime? lastUpdated,
    String structureKeys,
  ) {
    return switch (status) {
      NodesStatus.initial => _buildBindForm(),
      NodesStatus.loading => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: AppTokens.spacingSm),
            Text('正在拉取订阅…'),
          ],
        ),
      ),
      NodesStatus.error => _buildError(errorMessage, nodes.isEmpty),
      NodesStatus.loaded => _buildList(
        nodes,
        selectedName,
        failedCount,
        lastUpdated,
        structureKeys,
      ),
    };
  }

  /// 未绑定：粘贴订阅链接或单条节点链接的入口（自家面板链接进主订阅
  /// 绑定，其它订阅链接往多订阅列表里加，节点链接加为单节点，
  /// 见 [_submitPastedLink]）。
  /// 链接只拆成地址与令牌分开存，令牌进系统密钥库。
  Widget _buildBindForm() {
    return ListView(
      padding: const EdgeInsets.all(AppTokens.spacingMd),
      children: [
        const Text(
          '绑定订阅后这里会列出节点',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: AppTokens.spacingMd),
        TextField(
          controller: _linkController,
          decoration: const InputDecoration(
            hintText: '粘贴订阅链接或单条节点链接',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
          minLines: 1,
        ),
        const SizedBox(height: AppTokens.spacingSm),
        FilledButton(
          onPressed: _submitPastedLink,
          child: const Text('添加'),
        ),
        const SizedBox(height: AppTokens.spacingXs),
        OutlinedButton.icon(
          onPressed: _openScan,
          icon: const AppIcon(icon: AppIcons.scan),
          label: const Text('扫码添加'),
        ),
        const SizedBox(height: AppTokens.spacingXs),
        OutlinedButton.icon(
          onPressed: _openSubscriptions,
          icon: const AppIcon(icon: AppIcons.layers),
          label: const Text('管理订阅'),
        ),
        const SizedBox(height: AppTokens.spacingXs),
        Text(
          '链接只存本机，令牌进系统密钥库，不会明文保存。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: appThemeTokensOf(context).secondaryText,
          ),
        ),
      ],
    );
  }

  Widget _buildError(String? errorMessage, bool noNodes) {
    return ListView(
      padding: const EdgeInsets.all(AppTokens.spacingMd),
      children: [
        Text(
          errorMessage ?? '拉取失败',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16),
        ),
        const SizedBox(height: AppTokens.spacingMd),
        FilledButton(
          onPressed: () => ref.read(nodesProvider.notifier).refresh(),
          child: const Text('重新拉取'),
        ),
        const SizedBox(height: AppTokens.spacingXs),
        OutlinedButton.icon(
          onPressed: _openSubscriptions,
          icon: const AppIcon(icon: AppIcons.layers),
          label: const Text('管理订阅'),
        ),
        // 绑定失败也可能落到这里：留粘贴入口，不用回退到别的页。
        if (noNodes) ...[
          const SizedBox(height: AppTokens.spacingMd + AppTokens.spacingXs),
          const Text('或重新粘贴订阅链接：', textAlign: TextAlign.center),
          const SizedBox(height: AppTokens.spacingXs),
          TextField(
            controller: _linkController,
            decoration: const InputDecoration(
              hintText: '粘贴订阅链接或单条节点链接',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
            minLines: 1,
          ),
          const SizedBox(height: AppTokens.spacingSm),
          FilledButton(
            onPressed: _submitPastedLink,
            child: const Text('添加'),
          ),
        ],
      ],
    );
  }

  Widget _buildList(
    List<Node> nodes,
    String? selectedName,
    int failedCount,
    DateTime? lastUpdated,
    String structureKeys,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final filtered = _filter(nodes);
    final relay = _filter(
      nodes.where((n) => n.source == NodeSource.relay).toList(),
    );
    final direct = _filter(
      nodes.where((n) => n.source == NodeSource.direct).toList(),
    );
    return Column(
      children: [
        if (failedCount > 0)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spacingMd,
              vertical: AppTokens.spacingXs,
            ),
            // 解析失败提示条：错误色浅底，文字走错误色。
            color: colorScheme.error.withValues(alpha: 0.08),
            child: Text(
              '解析失败 $failedCount 个节点（已跳过，其余节点正常）',
              style: TextStyle(color: colorScheme.error),
            ),
          ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('没有符合条件的节点'))
              : CustomScrollView(
                  // 列表缓存区 500px，滚动少白屏；结构签名作 key，
                  // 节点集合变化时列表整体重建。
                  key: ValueKey(structureKeys),
                  scrollCacheExtent: ScrollCacheExtent.pixels(
                    AppTokens.listCacheExtent,
                  ),
                  slivers: [
                    ..._buildGroupSlivers('A 组', direct, selectedName),
                    ..._buildGroupSlivers('B 组', relay, selectedName),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spacingMd,
            vertical: AppTokens.spacingXs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '共 ${nodes.length} 个节点'
                  '${lastUpdated != null ? ' · 上次更新 ${_formatTime(lastUpdated)}' : ''}',
                  style: TextStyle(
                    fontSize: 12,
                    color: appThemeTokensOf(context).secondaryText,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => ref.read(nodesProvider.notifier).refresh(),
                child: const Text('刷新'),
              ),
              TextButton(
                onPressed: _showAddNodeDialog,
                child: const Text('添加节点'),
              ),
              TextButton(
                onPressed: _openSubscriptions,
                child: const Text('管理订阅'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildGroupSlivers(
    String title,
    List<Node> nodes,
    String? selectedName,
  ) {
    if (nodes.isEmpty) return [];
    // 当前节点置顶（DEV-PLAN §4.3 1-6），其余按原顺序。
    final ordered = List.of(nodes);
    if (selectedName != null) {
      ordered.sort((a, b) {
        if (a.name == selectedName && b.name != selectedName) return -1;
        if (b.name == selectedName && a.name != selectedName) return 1;
        return 0;
      });
    }
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spacingMd,
            AppTokens.spacingSm,
            AppTokens.spacingMd,
            4,
          ),
          child: Text(
            '$title（${nodes.length}）',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
      SliverFixedExtentList(
        // 行高固定 64（见 AppTokens.nodeRowHeight），滚动按行复用。
        itemExtent: AppTokens.nodeRowHeight,
        delegate: SliverChildBuilderDelegate((context, index) {
          final node = ordered[index];
          return _StaggeredFadeInRow(
            key: ValueKey(node.dedupKey),
            // 首次入场逐项间隔 80ms（只首次：行按 key 复用，
            // 刷新时没变过的行不重播）。
            delay: AppMotion.stagger * index,
            // 减弱动态时不做入场动画、也不建延迟定时器
            //（initState 里读不到 MediaQuery，定时器由父级开关）。
            animate: !AppMotion.animationsDisabled(context),
            child: _NodeRow(node: node),
          );
        }, childCount: ordered.length),
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

/// 节点行：毛玻璃卡片＋国旗圆圈＋延迟＋清晰选中态。
///
/// 圆圈里是按节点地址判断的国家/地区旗标（离线：中转域名＋国家顶级域，
/// 见 geo_flag.dart；未知国家时放 globe 图标），协议名挪到地址行里，
/// 不再放圆圈里（Hysteria2 太长会折行溢出圆圈）。中转节点显示的是
/// 中转机所在国家的旗，这是正常的，不纠正。
/// 节点来源（是哪个订阅来的）不在行里显示，只在订阅列表与详情页保留。
///
/// 选中态不只靠文字变色：边框高亮＋背景加深＋“使用中”角标带勾选图标，
/// 切换时 [AnimatedContainer] 250ms 平滑过渡；点一行有 InkWell
/// 按压反馈（splash）；行尾小箭头进详情（[OpenContainer] 450ms，
/// 点箭头只进详情、不选中；点行其他位置选中节点）。
///
/// 易变数据（延迟/失败/选中/单测状态）用 select 读：只重建这一行，
/// 不重建整表。行高固定 64（SliverFixedExtentList 的 itemExtent）：
/// 卡片上下边距 4＋内边距 6＋协议圆圈 44＝64。
class _NodeRow extends ConsumerWidget {
  const _NodeRow({required this.node});

  /// 展示用快照（名字/地址/协议/来源）；延迟等易变数据不从它读，
  /// 用下面的 select 读最新值。
  final Node node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(
      nodesProvider.select((s) {
        // 同 dedupKey 的节点可能有多个（名字不同、其余全同，如测试桩）：
        // 同 key 里优先取同名的那条，取不到再取第一条。
        final sameKey = s.nodes.where((n) => n.dedupKey == node.dedupKey);
        final current =
            sameKey.where((n) => n.name == node.name).firstOrNull ??
            sameKey.firstOrNull;
        if (current == null) return null;
        return (
          latencyMs: current.latencyMs,
          failed: current.latencyFailed,
          selected: s.selectedNodeName == current.name,
          testingThis: s.testingSingleNodeKey == current.dedupKey,
          testingAll: s.testingSpeed,
        );
      }),
    );
    final latencyMs = live?.latencyMs ?? node.latencyMs;
    final failed = live?.failed ?? node.latencyFailed;
    final isSelected = live?.selected ?? false;
    final testingThis = live?.testingThis ?? false;
    final testingAll = live?.testingAll ?? false;
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    // 旗标：按节点地址判断国家（离线）；未知国家时放 globe 图标。
    final flag = flagForAddress(node.address);
    return GlassCard(
      margin: const EdgeInsets.symmetric(
        horizontal: AppTokens.spacingMd,
        vertical: 4,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTokens.radiusLarge),
          // 点一行选中该节点；测速失败的节点也能手动点（用户自己负责），
          // 只是自动选择永远不会选它。
          onTap: () async {
            final ok = await ref.read(nodesProvider.notifier).selectNode(node);
            if (!ok && context.mounted) {
              final reason = ref.read(nodesProvider).selectionReason;
              if (reason != null) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(reason)));
              }
            }
          },
          child: AnimatedContainer(
            duration: AppMotion.state,
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spacingSm,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTokens.radiusLarge),
              border: Border.all(
                color: isSelected ? primary : Colors.transparent,
                width: 1.5,
              ),
              color: isSelected
                  ? primary.withValues(alpha: 0.08)
                  : Colors.transparent,
            ),
            child: Row(
              children: [
                // 国旗：细线圆圈里放一个旗标 emoji（24px，完整放进 44px
                // 圆圈，不溢出）；未知国家时放 globe 图标。
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha: 0.5),
                    ),
                  ),
                  child: flag.isKnown
                      ? Text(
                          flag.emoji,
                          style: const TextStyle(fontSize: 24),
                        )
                      : AppIcon(
                          icon: AppIcons.globe,
                          size: AppIconSize.sm,
                          color: appThemeTokensOf(context).secondaryText,
                        ),
                ),
                const SizedBox(width: AppTokens.spacingSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        node.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: failed
                              ? appThemeTokensOf(context).secondaryText
                              : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        // 协议名挪到地址行里（圆圈里不再放协议名）。
                        '${node.address}:${node.port} · ${node.protocol.label}',
                        style: TextStyle(
                          fontSize: 12,
                          color: appThemeTokensOf(context).secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      // 使用中：主色浅底＋金色细线边框，图标与文字走主色
                      //（白天深蓝 / 夜晚香槟金，随主题走）。
                      color: primary.withValues(alpha: 0.12),
                      border: Border.all(
                        color: appThemeTokensOf(context)
                            .gold
                            .withValues(alpha: 0.45),
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon(
                          icon: AppIcons.circleCheck,
                          size: AppIconSize.xs,
                          color: primary,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '使用中',
                          style: TextStyle(fontSize: 12, color: primary),
                        ),
                      ],
                    ),
                  ),
                if (node.isPlainText)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      // 明文角标：香槟金浅底，文字走主色（与“主订阅”
                      // 角标同一套金底语言，不再用橙色）。
                      color: appThemeTokensOf(context)
                          .gold
                          .withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '明文',
                      style: TextStyle(fontSize: 12, color: primary),
                    ),
                  ),
                const SizedBox(width: AppTokens.spacingXs),
                // 延迟芯片可点：点一下只测这一个节点（测速中转圈）。
                // 行本身的 InkWell 是选中节点；芯片是内层 InkWell，
                // 点芯片只测速、不选中（手势仲裁内层优先）。
                _LatencyChip(
                  node: node,
                  latencyMs: latencyMs,
                  failed: failed,
                  testingThis: testingThis,
                  testingAll: testingAll,
                ),
                // 详情：小箭头进详情页（OpenContainer 450ms）；
                // 点箭头只进详情、不选中（手势仲裁内层优先）。
                OpenContainer(
                  transitionDuration: AppMotion.effective(
                    context,
                    AppMotion.detail,
                  ),
                  closedElevation: 0,
                  closedColor: Colors.transparent,
                  openColor: Theme.of(context).scaffoldBackgroundColor,
                  closedShape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
                  ),
                  tappable: false,
                  closedBuilder: (context, openContainer) => IconButton(
                    icon: const AppIcon(
                      icon: AppIcons.chevronRight,
                      size: AppIconSize.sm,
                    ),
                    tooltip: '查看详情',
                    onPressed: openContainer,
                  ),
                  openBuilder: (context, _) => NodeDetailPage(node: node),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 延迟芯片（可点）：点一下只测这一个节点。
///
/// - 测速中：芯片转圈（只这一行转，其他行不动）；
/// - 测完：显示毫秒数（失败标灰写“测速失败”）；
/// - 核心未启动时点了一样给提示（和一键测速同一套提示口径），不发请求；
/// - 一键测速进行中时点不了（直接返回，两轮测速不打架）。
/// 只更新这一行的延迟，不重排列表。按压有 InkWell 反馈。
/// 易变数据由 [_NodeRow] 传进来，不自己读整页状态。
class _LatencyChip extends ConsumerWidget {
  const _LatencyChip({
    required this.node,
    required this.latencyMs,
    required this.failed,
    required this.testingThis,
    required this.testingAll,
  });

  final Node node;
  final int? latencyMs;
  final bool failed;
  final bool testingThis;
  final bool testingAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = testingThis
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(
            latencyMs != null
                ? '${latencyMs}ms'
                : failed
                ? '测速失败'
                : '未测速',
            style: TextStyle(
              fontSize: 12,
              color: appThemeTokensOf(context).secondaryText,
            ),
          );
    return Tooltip(
      message: '点一下只测这一个节点',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: (testingThis || testingAll)
            ? null
            : () async {
                final ok = await ref
                    .read(nodesProvider.notifier)
                    .testSingleSpeed(node);
                if (!ok && context.mounted) {
                  final error = ref.read(nodesProvider).speedTestError;
                  if (error != null) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(error)));
                  }
                }
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: content,
        ),
      ),
    );
  }
}

/// 首次入场逐项淡入上滑（250ms/项，间隔 80ms）：行按内容 key 复用，
/// 没变过的行不重播，刷新时不整列表闪一下；新行出现时播一次。
/// 减弱动态时不做入场动画，直接显示。
class _StaggeredFadeInRow extends StatefulWidget {
  const _StaggeredFadeInRow({
    super.key,
    required this.child,
    required this.delay,
    this.animate = true,
  });

  final Widget child;

  /// 本行比上一行晚多久出现（组内序号 × 80ms）。
  final Duration delay;

  /// 是否做入场动画：减弱动态时为 false，行直接显示、
  /// 也不建延迟定时器（initState 里读不到 MediaQuery）。
  final bool animate;

  @override
  State<_StaggeredFadeInRow> createState() => _StaggeredFadeInRowState();
}

class _StaggeredFadeInRowState extends State<_StaggeredFadeInRow> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    if (!widget.animate || widget.delay == Duration.zero) {
      _visible = true;
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) setState(() => _visible = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate || AppMotion.animationsDisabled(context)) {
      return widget.child;
    }
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: AppMotion.list,
      curve: Curves.easeOut,
      child: AnimatedSlide(
        offset: _visible ? Offset.zero : const Offset(0, 0.12),
        duration: AppMotion.list,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
