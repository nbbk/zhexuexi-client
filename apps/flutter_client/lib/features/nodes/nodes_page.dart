import 'dart:math' as math;

import 'package:animations/animations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../widgets/app_icon.dart';

import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/app_tokens.dart';
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
/// 加载中→转圈，失败→原因＋重试，成功→按订阅分组的节点行
/// （每个订阅一组，不同订阅的节点不再混在一起；组头显示订阅名）。
/// 切片 4：一键测速与自动选择已接线（开关开着走 Clash API 测代理延迟，
/// 关着走直连探测测到服务器的延迟，不为测速启动核心，见
/// [NodesNotifier.testAllSpeeds]；两种口径不同，不能直接比）；
/// 测速失败的节点标灰、不自动选；点一行选中该节点（只变选中态，
/// 位置保持不动、不重排）。
///
/// 分组折叠（2026-11-26）：每组默认折叠，点组头展开/收起；
/// 折叠状态只记在页面 State 里（[_expandedGroups]），不持久化。
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
  final _linkFocusNode = FocusNode();
  // 失败态的粘贴框不用 _linkController：两个态各用各的框，
  // 未绑定态输了一半的链接不会带到失败态（反过来也一样）。
  final _errorLinkController = TextEditingController();
  final _errorLinkFocusNode = FocusNode();
  String _query = '';

  /// 已展开的订阅分组（分组键见 [_subscriptionGroupKey]）：
  /// 默认全部折叠（集合初始为空），点组头才展开；只记在页面
  /// State 里，不持久化——新出现的分组默认也是折叠的。
  final Set<String> _expandedGroups = {};

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
    _linkFocusNode.dispose();
    _errorLinkController.dispose();
    _errorLinkFocusNode.dispose();
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
          // 选中态由行自己 select（见 [_NodeRow]），不经过这里：
          // 选中只变该行的边框/背景，整页不重建、列表不重排。
          failed: s.failedCount,
          testing: s.testingSpeed,
          tested: s.speedTestedCount,
          total: s.speedTestTotal,
          notice: s.addressNotice,
          speedError: s.speedTestError,
          reason: s.selectionReason,
          error: s.errorMessage,
          updated: s.lastUpdated,
          testedAt: s.speedTestAt,
          direct: s.speedTestDirect,
          fallback: s.speedTestDirectFallback,
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
                    // 一键测速：开关关着也能测（直连探测，不启动核心），
                    // 开着测的是走代理的真实延迟；测速中禁用防重复点。
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
          // 测速口径提示：开关开着与关着测的不是同一个数，写清楚别让
          // 用户直接比高低；测完后写明上次测的是哪种口径、几点测的、
          // 失败的各是什么原因（超时不可达 vs 其他连接失败）。
          if (hasNodes)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.spacingMd,
                AppTokens.spacingXs,
                AppTokens.spacingMd,
                0,
              ),
              child: Text(
                _speedHint(
                  nodes,
                  structure.testedAt,
                  structure.direct,
                  fallback: structure.fallback,
                ),
                style: TextStyle(
                  fontSize: 12,
                  color: appThemeTokensOf(context).secondaryText,
                ),
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
          // 测速失败的原因与自动选择的解释常驻显示，
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

  /// 测速口径提示文案：没测过时讲清两种口径的区别；测过后写明上次
  /// 测的是哪种口径、几点测的，失败的按原因分开数（超时不可达 vs
  /// 其他连接失败），别让用户以为两个口径的数能直接比。
  /// [fallback] 为 true 时是开关开着但探活失败后改走的直连探测，
  /// 不能写“开关关着”，要写明是被迫改口径（原因在上方的横幅里）。
  String _speedHint(
    List<Node> nodes,
    DateTime? testedAt,
    bool direct, {
    bool fallback = false,
  }) {
    const modes = '开关开着测的是走代理的真实延迟，关着测的是到服务器的'
        '直连延迟；两种延迟口径不同，不能直接比。';
    if (testedAt == null) return modes;
    final mode = fallback
        ? '直连延迟（开关开着但出站拨测失败，改用直连探测）'
        : direct
            ? '直连延迟（开关关着，到服务器的延迟）'
            : '代理延迟（开关开着，走代理的真实延迟）';
    var text = '上次测速 ${_formatTime(testedAt)} · $mode，'
        '与另一种口径不能直接比。';
    final failed = nodes.where((n) => n.latencyFailed).toList();
    if (failed.isNotEmpty) {
      final byReason = <String, int>{};
      for (final node in failed) {
        final reason = node.latencyFailureReason ?? '测速失败';
        byReason[reason] = (byReason[reason] ?? 0) + 1;
      }
      final parts = byReason.entries
          .map((e) => '${e.value} 个${e.key}')
          .join('、');
      text += '失败 ${failed.length} 个（$parts）。';
    }
    return text;
  }

  /// 粘贴框提交：订阅链接、单条节点链接、订阅正文都走 [handleContent]
  /// 分流——自家面板链接进主订阅绑定，其它订阅链接往多订阅列表里
  /// 加一个（不顶掉旧的），节点链接加为单节点。
  /// 默认读未绑定态的框；失败态传它自己的框。
  Future<void> _submitPastedLink([
    TextEditingController? controller,
  ]) async {
    final field = controller ?? _linkController;
    final link = field.text.trim();
    if (link.isEmpty) return;
    final result = await handleContent(ref, link);
    if (!mounted) return;
    if (result.error != null) {
      _showSnack(result.error!);
    } else {
      field.clear();
      _showSnack(result.message ?? '已添加');
    }
  }

  /// “粘贴”按钮：读剪贴板填进 [controller]（去首尾空白），填上就
  /// 给输入框焦点，方便接着改；剪贴板是空的就提示一句，不动输入框。
  /// 长按菜单本身没被遮挡（框上没有 IgnorePointer 之类），这个按钮
  /// 是给长按菜单不好点、或用户不知道能长按时准备的明路。
  Future<void> _pasteInto(
    TextEditingController controller,
    FocusNode focusNode,
  ) async {
    final pasted = await pasteClipboardInto(controller);
    if (!mounted) return;
    if (pasted) {
      focusNode.requestFocus();
    } else {
      _showSnack('剪贴板是空的，先复制链接再粘贴');
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          hintText: '粘贴一条节点链接，如 vless://…',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.done,
                        onSubmitted: submit,
                        maxLines: 3,
                        minLines: 1,
                        autofocus: true,
                      ),
                    ),
                    const SizedBox(width: AppTokens.spacingSm),
                    OutlinedButton(
                      onPressed: () async {
                        final pasted = await pasteClipboardInto(
                          controller,
                        );
                        if (!pasted) {
                          setDialogState(
                            () => error = '剪贴板是空的，先复制链接再粘贴',
                          );
                        }
                      },
                      child: const Text('粘贴'),
                    ),
                  ],
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
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _linkController,
                focusNode: _linkFocusNode,
                decoration: const InputDecoration(
                  hintText: '粘贴订阅链接或单条节点链接',
                  border: OutlineInputBorder(),
                ),
                // 链接是 URL：键盘给 URL 布局；点“粘贴”按钮直接读剪贴板
                // 填入（去首尾空白），不用只靠长按菜单。
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitPastedLink(),
                maxLines: 3,
                minLines: 1,
              ),
            ),
            const SizedBox(width: AppTokens.spacingSm),
            OutlinedButton(
              onPressed: () => _pasteInto(_linkController, _linkFocusNode),
              child: const Text('粘贴'),
            ),
          ],
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _errorLinkController,
                  focusNode: _errorLinkFocusNode,
                  decoration: const InputDecoration(
                    hintText: '粘贴订阅链接或单条节点链接',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) =>
                      _submitPastedLink(_errorLinkController),
                  maxLines: 3,
                  minLines: 1,
                ),
              ),
              const SizedBox(width: AppTokens.spacingSm),
              OutlinedButton(
                onPressed: () => _pasteInto(
                  _errorLinkController,
                  _errorLinkFocusNode,
                ),
                child: const Text('粘贴'),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spacingSm),
          FilledButton(
            onPressed: () => _submitPastedLink(_errorLinkController),
            child: const Text('添加'),
          ),
        ],
      ],
    );
  }

  Widget _buildList(
    List<Node> nodes,
    int failedCount,
    DateTime? lastUpdated,
    String structureKeys,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final filtered = _filter(nodes);
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
                  slivers: _buildSubscriptionSlivers(filtered),
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

  /// 按订阅分组的 sliver：每个订阅一组，组内节点保持原顺序
  /// （不重排——选中节点也不置顶，只变选中态）。
  /// 组头一直可见，点组头展开/收起；默认全部折叠（见 [_expandedGroups]）。
  /// 折叠时整组节点 sliver 不渲染。
  /// 分组顺序按订阅在列表里首次出现的顺序；直连/中转（A/B 后缀）
  /// 不再单独成组，只是节点名的后缀区分。
  List<Widget> _buildSubscriptionSlivers(List<Node> nodes) {
    final groups = <String, List<Node>>{};
    final order = <String>[];
    for (final node in nodes) {
      final key = _subscriptionGroupKey(node);
      if (!groups.containsKey(key)) {
        groups[key] = [];
        order.add(key);
      }
      groups[key]!.add(node);
      // 记下该订阅的显示名（订阅名优先，见 [_subscriptionGroupTitle]）：
      // 同一订阅的节点订阅名一致，取第一个非空的即可。
      final name = node.subscriptionName?.trim();
      if (name != null && name.isNotEmpty) {
        _groupNames[key] = name;
      } else {
        _groupNames.putIfAbsent(key, () => null);
      }
    }
    return [
      for (final key in order)
        ..._buildGroupSlivers(key, groups[key]!),
    ];
  }

  /// 分组键：订阅 id 优先（同名不同订阅不混组）；id 没有时用订阅名；
  /// 两者都没有时归到同一组（标题见 [_subscriptionGroupTitle]）。
  String _subscriptionGroupKey(Node node) {
    final id = node.subscriptionId?.trim();
    if (id != null && id.isNotEmpty) return id;
    final name = node.subscriptionName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return '';
  }

  /// 组头标题：订阅名优先，没有订阅名时回落订阅 id；
  /// 单节点那组自带订阅名“手动添加”（单节点存储里写死的显示名），
  /// 所以直接显示“手动添加”；两者都没有时显示“未分组”。
  ///
  /// 注意：分组键是订阅 id（见 [_subscriptionGroupKey]），标题是
  /// 订阅名——同名不同订阅分属两组，组头标题会相同，这是按订阅
  /// 分组的正常结果（id 不同、名字可以相同）。
  String _subscriptionGroupTitle(String groupKey) {
    if (groupKey.isEmpty) return '未分组';
    // 标题要取订阅名而不是 id：先从组内节点里找订阅名，
    // 找不到（只有 id）时回落 id 本身。
    final name = _groupNames[groupKey];
    if (name != null && name.isNotEmpty) return name;
    return groupKey;
  }

  /// 分组键→订阅名（[_buildSubscriptionSlivers] 分组时顺手记下，
  /// 供 [_subscriptionGroupTitle] 取标题用）。
  final Map<String, String?> _groupNames = {};

  List<Widget> _buildGroupSlivers(String groupKey, List<Node> nodes) {
    if (nodes.isEmpty) return [];
    final title = _subscriptionGroupTitle(groupKey);
    // 展开态按分组键记（不是按标题：同名不同订阅的键不同，
    // 各自独立折叠/展开）。
    final expanded = _expandedGroups.contains(groupKey);
    return [
      SliverToBoxAdapter(
        child: InkWell(
          onTap: () => setState(() {
            if (expanded) {
              _expandedGroups.remove(groupKey);
            } else {
              _expandedGroups.add(groupKey);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spacingMd,
              AppTokens.spacingSm,
              AppTokens.spacingMd,
              4,
            ),
            child: Row(
              children: [
                // 折叠时箭头朝右，展开时朝下（chevronRight 转 90°）。
                Transform.rotate(
                  angle: expanded ? math.pi / 2 : 0,
                  child: const AppIcon(
                    icon: AppIcons.chevronRight,
                    size: AppIconSize.sm,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '$title（${nodes.length}）',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      ),
      if (expanded)
        SliverFixedExtentList(
          // 行高固定 64（见 AppTokens.nodeRowHeight），滚动按行复用。
          itemExtent: AppTokens.nodeRowHeight,
          delegate: SliverChildBuilderDelegate((context, index) {
            final node = nodes[index];
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
          }, childCount: nodes.length),
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

/// 节点行：毛玻璃卡片＋协议简称圆圈＋名称＋延迟＋铅笔详情按钮。
///
/// 圆圈里是协议简称（最多 3 个字符，见 [NodeProtocolLabel.shortLabel]，
/// 放得进 44px 圆圈、不折行、不溢出）；协议全名只在详情页里显示。
/// 国旗显示已去掉（用户 2026-11-25 定：不做国旗显示）。
/// 节点来源（是哪个订阅来的）不在行里显示，只在订阅列表与详情页保留。
/// 卡片上不显示地址与端口（行太挤、地址行会被裁掉一半）：
/// 地址、端口、协议等都在详情页里看、改。
///
/// 选中态不只靠文字变色：边框高亮＋背景加深，不再写“使用中”角标，
/// 切换时 [AnimatedContainer] 250ms 平滑过渡；点一行有 InkWell
/// 按压反馈（splash）；行尾铅笔进详情/编辑页（[OpenContainer] 450ms，
/// 点铅笔只进详情、不选中；点行其他位置选中节点）。
/// 圆圈往左靠、名称留足空间：卡片横向内边距 8、圆圈与名称间距 8，
/// 名称单行省略（maxLines: 1＋ellipsis），再长的名字也不折行、不裁。
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
          failureReason: current.latencyFailureReason,
          selected: s.selectedNodeName == current.name,
          testingThis: s.testingSingleNodeKey == current.dedupKey,
          testingAll: s.testingSpeed,
          direct: s.speedTestDirect,
        );
      }),
    );
    final latencyMs = live?.latencyMs ?? node.latencyMs;
    final failed = live?.failed ?? node.latencyFailed;
    final failureReason = live?.failureReason ?? node.latencyFailureReason;
    final direct = live?.direct ?? false;
    final isSelected = live?.selected ?? false;
    final testingThis = live?.testingThis ?? false;
    final testingAll = live?.testingAll ?? false;
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
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
            // 卡片横向内边距 8（圆圈往左靠，给名称留足空间）。
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spacingXs,
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
                // 协议简称：细线圆圈里放 2–3 个字符的简称（13px 半粗体，
                // 最宽 HY2 也放得进 44px 圆圈，不折行、不溢出）。
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
                  child: Text(
                    node.protocol.shortLabel,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: appThemeTokensOf(context).secondaryText,
                    ),
                  ),
                ),
                const SizedBox(width: AppTokens.spacingXs),
                Expanded(
                  // 名称单行：再长的名字也只占一行，超出省略，
                  // 不折行、不挤占行高（行高固定 64，折行会被裁）。
                  child: Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: failed
                          ? appThemeTokensOf(context).secondaryText
                          : null,
                    ),
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
                  failureReason: failureReason,
                  testingThis: testingThis,
                  testingAll: testingAll,
                  direct: direct,
                ),
                // 详情/编辑：铅笔进详情页（OpenContainer 450ms）；
                // 点铅笔只进详情、不选中（手势仲裁内层优先）。
                // 详情页里能看到地址、端口、协议等，也能改（小火箭同款）。
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
                      icon: AppIcons.pencil,
                      size: AppIconSize.sm,
                    ),
                    tooltip: '查看详情与编辑',
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
/// - 测完：延迟数字本身用绿色（问题 4：通了就是绿字毫秒数）；
/// - 失败：只显示一个红色圆点，不再写“测速失败”四个字；
/// - 没测过：灰字“未测速”；
/// - 长按看 tooltip：测到的写明是哪种口径（直连延迟还是代理延迟，
///   两者不能直接比），失败的写明原因（超时不可达 vs 其他连接失败）；
/// - 开关关着点了一样能测（直连探测，不启动核心）。
/// 只更新这一行的延迟，不重排列表。按压有 InkWell 反馈。
/// 易变数据由 [_NodeRow] 传进来，不自己读整页状态。
class _LatencyChip extends ConsumerWidget {
  const _LatencyChip({
    required this.node,
    required this.latencyMs,
    required this.failed,
    required this.failureReason,
    required this.testingThis,
    required this.testingAll,
    required this.direct,
  });

  final Node node;
  final int? latencyMs;
  final bool failed;

  /// 失败原因（“超时不可达”“连接失败”等，见 [Node.latencyFailureReason]）；
  /// 未失败、或走代理测速失败（不分原因）时为 null。
  final String? failureReason;
  final bool testingThis;
  final bool testingAll;

  /// 这次延迟是哪种口径：true＝直连延迟，false＝代理延迟。
  final bool direct;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 延迟数字本身的绿色（问题 4）：主题 token 里没有成功/绿色
    //（app_theme.dart 只有深蓝/金色等 token），这里按亮度各取一个
    // 两端都可读的绿——白天 #157347（白底对比度约 5.9:1），夜晚
    // #4ADE80（墨蓝黑底对比度约 11:1）；不要写死只在白天可读的深绿。
    // 首页节点弹窗里的延迟数字用同一对绿（见 home_page.dart）。
    final latencyOkColor = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF4ADE80)
        : const Color(0xFF157347);
    final content = testingThis
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : latencyMs != null
        ? Text(
            '${latencyMs}ms',
            style: TextStyle(fontSize: 12, color: latencyOkColor),
          )
        : failed
        // 测速失败只显示一个红色圆点，不再写“测速失败”四个字；
        // 失败原因仍在 tooltip 与长按说明里（见下面的 tooltip）。
        ? Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.error,
            ),
          )
        : Text(
            '未测速',
            style: TextStyle(
              fontSize: 12,
              color: appThemeTokensOf(context).secondaryText,
            ),
          );
    final tooltip = testingThis
        ? '正在测速…'
        : latencyMs != null
        ? direct
              ? '直连延迟：开关关着测的，到服务器的延迟'
              : '代理延迟：开关开着测的，走代理的真实延迟'
        : failed
        ? failureReason != null
              ? '测速失败：$failureReason，点一下重测'
              : '测速失败，点一下重测'
        : '点一下只测这一个节点';
    return Tooltip(
      message: tooltip,
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
