import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_motion.dart';
import '../../widgets/app_icon.dart';
import '../../core/app_tokens.dart';

import '../../core/clash_api_client.dart';
import '../../core/app_theme.dart';
import '../../core/core_provider.dart';
import '../../core/node_model.dart';
import '../../core/routing_mode.dart';
import '../../core/singbox_core.dart';
import '../../core/userinfo.dart';
import '../../services/announcement_service.dart';
import '../../services/custom_rules_notifier.dart';
import '../../services/nodes_notifier.dart';
import '../../services/remote_config_notifier.dart';
import '../../services/routing_mode_notifier.dart';
import '../../services/settings_notifier.dart';
import '../../services/single_node_store.dart';
import '../../features/announcements/announcement_list_page.dart';
import '../../widgets/announcement_marquee.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/power_button.dart';

/// 首页：一个大开关 + 当前节点 + 实时速率 + 流量三格 + 模式切换 + 公告栏。
///
/// 切片 3：开关接真实核心（[CoreService]），速率读 Clash API `/traffic`，
/// 流量三格读订阅 `subscription-userinfo` 头，模式三档
/// 切换立即生效（失败回滚旧模式）。
/// 流量口径写在界面上：限流按全部节点流量算（切片 10 改口径，旧“仅中转”已取消）。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key, required this.onGoToMe});

  /// bundled 配置提示被用户关掉的持久化标志（SharedPreferences 键）。
  ///
  /// 只记这一条横幅：关过就不再出现，即使远程配置源仍是 bundled；
  /// offline（cached）与强制更新那两条是状态提示，不走这个键、不能关。
  static const bundledConfigHintDismissedKey =
      'dismissed_bundled_config_hint';

  /// 跳到“我的”页（绑定订阅）的回调。
  final VoidCallback onGoToMe;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// 首页卡片固定高度（第 9 项）：卡片不再随内容长短伸缩。
  ///
  /// 状态卡 72 = 两行 ListTile 的标准高度（标题＋副标题各一行）；
  /// 最矮的那张（offline 单行标题 56）往上取整到 72，正常文案
  /// 两行都放得下；标题/副标题超长时内部省略，不把卡片撑高。
  static const double _homeCardHeight = 72;

  /// 流量格固定高度 102 = 内边距 spacingMd 16×2 + 数值两行
  /// （titleMedium 行高 24）×2 + 间隔 4 + 标签（bodySmall 行高 18）；
  /// 按最满的那格（实时速率“↑ x / ↓ y”两行）取，单行数值的格
  /// 内容垂直居中，不留高低差。
  static const double _statCellHeight = 102;

  late CoreStatus _status;
  TrafficSample? _sample;
  bool _busy = false;
  StreamSubscription<CoreStatus>? _statusSub;
  StreamSubscription<TrafficSample>? _trafficSub;

  /// 启动探活位（2026-11-26 二轮修复，方案 A）：核心在跑但出站
  /// 拨测失败时为 true，首页保持“运行中”，另起一行写失败原因＋
  /// “重新拨测”按钮；不翻 CoreStatus.error（翻了会闩锁首页的
  /// 速率与计时，还让节点页误判成“开关关着”）。
  bool _probeFailed = false;
  String? _probeError;
  StreamSubscription<ProbeState>? _probeSub;

  /// 正在手动重新拨测（按钮防重复点）。
  bool _probing = false;

  /// 本轮连接开始的时间（“已连接 HH:MM:SS”用；断开后清掉）。
  DateTime? _connectedSince;

  /// 已连接时每秒刷一次时长（只在运行中跑，断开就停）。
  Timer? _durationTimer;

  /// bundled 配置提示是否已关掉。
  ///
  /// 默认先按已关掉，避免已关过的用户冷启动时横幅闪现一下；
  /// 异步读回真实值后按实际刷新（没关过的随后出现）。
  bool _bundledHintDismissed = true;

  @override
  void initState() {
    super.initState();
    _loadBundledHintDismissed();
    final core = ref.read(coreServiceProvider);
    _status = core.status;
    _probeFailed = core.probeFailed;
    _probeError = core.lastProbeError;
    _probeSub = core.probeStream.listen((probe) {
      if (!mounted) return;
      setState(() {
        _probeFailed = probe.failed;
        _probeError = probe.error;
      });
    });
    _statusSub = core.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _status = status);
      _syncTraffic();
      _syncDurationTimer(status);
      // 异步失败（服务在 :remote 进程里起不来）不同步抛错，只走这条
      // 状态流：转成失败态时把原因弹出来，不然用户只看到干巴巴的
      // “连接失败”，不知道为什么（2026-11-26 真机就是这么丢的）。
      if (status == CoreStatus.error) {
        final reason = core.lastError;
        if (reason != null && reason.isNotEmpty) {
          _showSnack('连接失败：${_readableError(reason)}');
        }
      }
    });
    _syncTraffic();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _probeSub?.cancel();
    _trafficSub?.cancel();
    _durationTimer?.cancel();
    super.dispose();
  }

  /// 手动重新拨测（探活失败提示下的按钮）：只调核心的探活，不动
  /// 大开关（大开关仍是停核心）。跑完后探活流会推新结果，失败
  /// 提示自动刷新或消失；这里不另弹 SnackBar。
  Future<void> _retryProbe() async {
    if (_probing || _status != CoreStatus.started) return;
    setState(() => _probing = true);
    try {
      await ref.read(coreServiceProvider).retryProbe();
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  /// 连接时长计时：运行中开始每秒刷一次，离开运行中就停并清掉起点。
  void _syncDurationTimer(CoreStatus status) {
    if (status == CoreStatus.started) {
      _connectedSince ??= DateTime.now();
      _durationTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _status == CoreStatus.started) setState(() {});
      });
    } else {
      _durationTimer?.cancel();
      _durationTimer = null;
      if (status != CoreStatus.starting) _connectedSince = null;
    }
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
    // TUN 关着时自动打开并提示：没有 TUN 入站就没有 VPN 接口，
    // 核心即使起来了流量也进不去（假运行，问题 6）。
    if (!ref.read(settingsProvider).tun) {
      await ref.read(settingsProvider.notifier).setTun(true);
      _showSnack('已自动开启 TUN，否则无法代理');
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
        // 校验失败要报出真实原因（2026-11-26：TUN 的 stack 字段被
        // schema 拒时这里只剩固定文案，用户完全不知道为什么）：
        // 取第一条错误（通常就是根因那句），太长时截断，SnackBar
        // 里放不下全文；空错误列表时回落固定文案。
        final reason = result.errors.isNotEmpty ? result.errors.first : '';
        _showSnack(
          reason.isEmpty
              ? '配置生成失败，已保持上次连接'
              : '配置生成失败：${_shortReason(reason)}，已保持上次连接',
        );
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
  /// 这里只提示一句，不再动状态；提示里带 setMode 写进
  /// errorMessage 的真实原因（2026-11-26：以前只弹固定句）。
  Future<void> _onModeChanged(Set<String> selected) async {
    if (selected.isEmpty) return;
    final next = RoutingMode.fromStorage(selected.first);
    final ok = await ref.read(routingModeProvider.notifier).setMode(next);
    if (!ok && mounted) {
      final reason = ref.read(routingModeProvider).errorMessage;
      _showSnack(reason ?? '切换失败，已保持原模式');
    }
  }

  /// 校验原因截断：schema 报错带完整路径很长，SnackBar 里只留前
  /// 120 字，根因（字段名/路径）都在前头，截不掉。
  static String _shortReason(String reason) {
    const maxLength = 120;
    if (reason.length <= maxLength) return reason;
    return '${reason.substring(0, maxLength)}…';
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
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('需要升级客户端'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(config.forceUpdateMessage ?? '当前版本无法解析新订阅格式，请升级到最新版。'),
            if (downloadUrl.isNotEmpty) ...[
              const SizedBox(height: AppTokens.spacingSm),
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

  /// 读回 bundled 配置提示的关闭标志：没存过按没关过处理。
  Future<void> _loadBundledHintDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(
        () =>
            _bundledHintDismissed =
                prefs.getBool(HomePage.bundledConfigHintDismissedKey) ??
                false,
      );
    } catch (_) {
      // 读不到就按没关过处理，横幅正常出现，不静默吞掉提示。
      if (mounted) setState(() => _bundledHintDismissed = false);
    }
  }

  /// 关掉 bundled 配置提示：先立即从界面上消失（条件渲染整条移除，
  /// 不留空位），再把标志持久化，下次打开 App 不再出现。
  /// 只关这一条：offline 与强制更新提示不受影响。
  Future<void> _dismissBundledConfigHint() async {
    if (mounted) setState(() => _bundledHintDismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(HomePage.bundledConfigHintDismissedKey, true);
  }

  /// 配置中心重试（离线提示条上的“重试”）：拉一次远程配置，
  /// 拉到了提示条自动消失，拉不到还留着。
  Future<void> _retryConfig() async {
    await ref.read(remoteConfigProvider.notifier).refresh();
  }

  /// 当前节点卡片可点（问题 5）：弹节点列表弹窗，点一行切过去。
  /// 没节点时不弹，只提示去绑定订阅。
  Future<void> _showNodePicker() async {
    if (ref.read(nodesProvider).nodes.isEmpty) {
      _showSnack('请先绑定订阅，再选择节点');
      widget.onGoToMe();
      return;
    }
    await showAppDialog<void>(
      context: context,
      builder: (context) => const _NodePickerDialog(),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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

  /// 大开关状态文案（用户 2026-11-25 定稿，优雅简短、不要说明书口吻）：
  /// 未连接「静候连接 / 轻触开启」，已连接「运行中 / 已连接 HH:MM:SS」
  ///（只写已连接时长，不加操作说明）；连接中/断开中/失败同调子短句。
  ///
  /// 2026-11-26 二轮修复（方案 A）：已连接但探活失败时主标题仍是
  /// 「运行中」（核心在跑），副标题改成拨测失败的原因＋“代理可能不通”；
  /// 红字失败区只在真 error（核心停了/崩了）时显示，不在这里复用。
  (String, String) _statusTexts() {
    if (_status == CoreStatus.started && _probeFailed) {
      final reason = _probeError ?? '出站拨测失败';
      return ('运行中', '出站拨测失败：$reason（代理可能不通）');
    }
    return switch (_status) {
      CoreStatus.stopped => ('静候连接', '轻触开启'),
      CoreStatus.starting => ('正在连接…', '稍等片刻'),
      CoreStatus.started => ('运行中', _connectedDurationText()),
      CoreStatus.stopping => ('正在断开…', '稍等片刻'),
      CoreStatus.error => ('连接失败', '轻触重试'),
    };
  }

  /// 失败原因的人话版：旧版原生告警没带 message 时 Dart 侧只能拼出
  /// "PlatformException(Stopped, null, null, null)"，直接显示等于没说；
  /// 新版原生告警已带人话原因（见 BoxService.stopAndAlert），原样显示。
  String _readableError(String error) {
    if (error.startsWith('PlatformException(Stopped, null')) {
      return '服务启动失败（没有返回原因），请重试或重新拉取订阅';
    }
    return error;
  }

  /// 已连接时长：`已连接 HH:MM:SS`。
  String _connectedDurationText() {
    final since = _connectedSince;
    if (since == null) return '已连接';
    final d = DateTime.now().difference(since);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '已连接 $h:$m:$s';
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
    final announcements = ref.watch(announcementsProvider);
    final announcementList = announcements.valueOrNull;
    final info = nodesState.userinfo;
    final currentNode = nodesState.selectedNode;
    final switching =
        _status == CoreStatus.starting ||
        _status == CoreStatus.stopping ||
        _busy;
    final rateText = _status == CoreStatus.started && _sample != null
        ? '↑ ${formatSpeed(_sample!.up)}\n↓ ${formatSpeed(_sample!.down)}'
        : '—';

    return GlassBackground(
      child: ListView(
        padding: const EdgeInsets.all(AppTokens.spacingMd),
        children: [
          // 远程配置状态条（切片 7）：拉不到配置时给一句提示，不静默；
          // 强制更新时拦住大开关（点开关弹升级说明）。
          if (remoteState.forceUpdateRequired)
            GlassCard(
              height: _homeCardHeight,
              margin: const EdgeInsets.only(bottom: AppTokens.spacingXs),
              child: ListTile(
                leading: const AppIcon(icon: AppIcons.download),
                title: const Text(
                  '当前版本过低，请升级后使用',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '最低可用版本 ${remoteState.config.minAppVersion}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: _showForceUpdateDialog,
                  child: const Text('查看详情'),
                ),
              ),
            ),
          if (remoteState.offline)
            GlassCard(
              height: _homeCardHeight,
              margin: const EdgeInsets.only(bottom: AppTokens.spacingXs),
              child: ListTile(
                leading: const AppIcon(icon: AppIcons.cloudOff),
                title: const Text(
                  '配置中心暂时连不上，正在用上次的配置',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: _retryConfig,
                  child: const Text('重试'),
                ),
              ),
            ),
          // bundled 配置提示：只在仍用包内默认配置、且用户没关过时出现；
          // 点右上角 × 就整条消失并记下来，下次打开不再出现（重试保留）。
          // offline（cached）与强制更新那两条不在这里，不可关闭。
          //
          // 标题与副标题完整显示（问题 9）：实测 390 宽下标题只剩 148px、
          // intrinsic 198px，单行＋省略号会被截成“首次启动需要联网…”；
          // 这里不设 maxLines、不设省略号，允许换行，卡片高度由内容定
          //（不固定 72，见 GlassCard.height 不传即自适应）。
          if (remoteState.source == RemoteConfigSource.bundled &&
              !_bundledHintDismissed)
            GlassCard(
              margin: const EdgeInsets.only(bottom: AppTokens.spacingXs),
              child: ListTile(
                leading: const AppIcon(icon: AppIcons.cloudOff),
                title: const Text('首次启动需要联网拉取配置'),
                subtitle: const Text('拉不到配置也能先手动粘贴订阅使用'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: _retryConfig,
                      child: const Text('重试'),
                    ),
                    IconButton(
                      icon: const AppIcon(
                        icon: AppIcons.x,
                        size: AppIconSize.sm,
                      ),
                      tooltip: '关闭提示',
                      onPressed: _dismissBundledConfigHint,
                    ),
                  ],
                ),
              ),
            ),
          // 公告栏（0.1.2）：有公告才显示，没有就隐藏、不留占位、
          // 布局收起；失败有缓存显示缓存，加载中/失败无缓存时不显示。
          // 有公告时跑马灯只滚标题行（displayLine），全文在列表页看；
          // 整卡可点，进公告列表页。
          if (announcementList != null && announcementList.isNotEmpty)
            GlassCard(
              height: _homeCardHeight,
              margin: const EdgeInsets.only(bottom: AppTokens.spacingXs),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppTokens.radiusLarge),
                  onTap: () => Navigator.push(
                    context,
                    appPageRoute(
                      context,
                      (_) => const AnnouncementListPage(),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const AppIcon(icon: AppIcons.megaphone),
                        const SizedBox(width: AppTokens.spacingSm),
                        Expanded(
                          child: AnnouncementMarquee(
                            lines: announcementList
                                .map((a) => a.displayLine)
                                .toList(),
                          ),
                        ),
                        const AppIcon(icon: AppIcons.chevronRight),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: AppTokens.spacingMd + AppTokens.spacingXs),
          // 大开关：深蓝渐变＋呼吸动效（开）/灰色静态（关），
          // 中心图标是可替换组件（图标方向等 UI 调研回来再定，
          // 现默认放金色信号弧占位，不写死电源符号）。
          Center(
            child: BreathingPowerButton(
              size: MediaQuery.of(context).size.width / 3,
              isOn: _status == CoreStatus.started,
              enabled: !switching,
              onPressed: _onToggle,
            ),
          ),
          const SizedBox(height: AppTokens.spacingXs),
          Center(
            child: Text(_statusTexts().$1, style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: 2),
          Center(
            child: Text(
              _statusTexts().$2,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 探活失败时（核心在跑、出站不通）的“重新拨测”入口
          //（2026-11-26 二轮修复）：只重跑一次拨测，不停核心、
          // 不重建配置；跑完探活流推新结果，上面那行失败提示自动
          // 刷新或消失。大开关仍是停核心，不兼做重测。
          if (_status == CoreStatus.started && _probeFailed)
            TextButton(
              onPressed: _probing ? null : _retryProbe,
              child: Text(_probing ? '拨测中…' : '重新拨测'),
            ),
          // 失败原因常驻显示（2026-11-26）：只在失败态显示 CoreService
          // 记下的最后一次错误原因；只读，不改状态机。
          if (_status == CoreStatus.error) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spacingMd,
              ),
              child: Text(
                _readableError(
                  ref.read(coreServiceProvider).lastError ?? '连接失败，请重试',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const SizedBox(height: AppTokens.spacingMd + AppTokens.spacingXs),
          // 当前节点：点一下弹节点列表弹窗选节点（问题 5）。
          // ListTile 的 onTap 要有 Material 祖先才能画按压墨水，
          // GlassCard 的底色 DecoratedBox 会盖住它（会抛断言）；
          // 照节点行的做法包一层透明 Material＋InkWell（见 _NodeRow）。
          GlassCard(
            height: _homeCardHeight,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppTokens.radiusLarge),
                onTap: _showNodePicker,
                child: ListTile(
                  leading: const AppIcon(icon: AppIcons.globe),
                  title: Text(
                    currentNode == null
                        ? '当前节点：未选择'
                        : '当前节点：${currentNode.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _currentNodeSubtitle(currentNode),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: currentNode == null
                      ? TextButton(
                          onPressed: widget.onGoToMe,
                          child: const Text('去订阅'),
                        )
                      : const AppIcon(icon: AppIcons.chevronRight),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppTokens.spacingMd),
          // 实时速率 + 流量三格（userinfo 头，中转口径）。
          // 格子之间留 8px 缝隙（问题 8），不改卡片高度与内容。
          Row(
            children: [
              Expanded(
                child: _StatCell(label: '实时速率', value: rateText),
              ),
              const SizedBox(width: AppTokens.spacingXs),
              Expanded(
                child: _StatCell(label: '已用 / 总量', value: _usedTotalText(info)),
              ),
              const SizedBox(width: AppTokens.spacingXs),
              Expanded(
                child: _StatCell(label: '剩余流量', value: _remainingText(info)),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spacingXs),
          Row(
            children: [
              Expanded(
                child: _StatCell(label: '到期日', value: _expireText(info)),
              ),
              const SizedBox(width: AppTokens.spacingXs),
              const Expanded(
                child: _StatCell(label: '流量口径', value: '全部节点'),
              ),
              const SizedBox(width: AppTokens.spacingXs),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            info == null
                ? '未拉到流量数据，刷新订阅后显示；流量按全部节点算'
                : '流量口径：全部节点（限流按全部节点流量算，以面板用量为准）',
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
          const SizedBox(height: AppTokens.spacingMd),
          // 模式切换（三档，切换后重载配置，失败回滚旧模式）。
          // 选中态：白天深蓝底白字、夜晚香槟金底墨蓝字（品牌主色）。
          SegmentedButton<String>(
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: appThemeTokensOf(context)
                  .segmentedSelectedBackground,
              selectedForegroundColor: appThemeTokensOf(context)
                  .segmentedSelectedForeground,
            ),
            segments: const [
              ButtonSegment(value: 'rule', label: Text('规则模式')),
              ButtonSegment(value: 'global', label: Text('全局模式')),
              ButtonSegment(value: 'direct', label: Text('直连模式')),
            ],
            selected: {modeState.mode.storageValue},
            onSelectionChanged: modeState.switching ? null : _onModeChanged,
          ),
        ],
      ),
    );
  }
}

/// 节点选择弹窗（问题 5）：按订阅分组列出 [nodesProvider] 的节点
///（名称＋延迟），当前选中的一行标出来（选中底色＋对勾）；点某一行
/// 就调 [NodesNotifier.selectNode] 切过去，成功关弹窗，失败把原因
/// 留在弹窗里（不静默）。
///
/// 分组（2026-11-26）：不同订阅的节点不混在一起，每个订阅一组，
/// 组头是订阅名，组内节点保持 [nodesProvider] 原有顺序、不重排；
/// 选中只变选中态，不挪位置。分组默认全部折叠，点组头展开/收起，
/// 折叠状态只记在弹窗 State 里，不持久化。
///
/// 测速：弹窗里有“测速全部”（[NodesNotifier.testAllSpeeds]）与
/// “测速当前节点”（[NodesNotifier.testSingleSpeed]，只测当前选中
/// 节点）；每行点延迟处只测这一行（复用节点页 `_LatencyChip` 的
/// 做法），测速中该行转圈、其他行不动。测完弹窗里的延迟就地更新。
class _NodePickerDialog extends ConsumerStatefulWidget {
  const _NodePickerDialog();

  @override
  ConsumerState<_NodePickerDialog> createState() => _NodePickerDialogState();
}

/// 一组节点：组 key（折叠状态用）＋组头标题＋组内节点（原顺序）。
typedef _NodeGroup = ({String key, String title, List<Node> nodes});

class _NodePickerDialogState extends ConsumerState<_NodePickerDialog> {
  /// 弹窗内显示的错误（切节点失败的原因 / 测速失败的原因），不关弹窗。
  String? _error;

  /// 正在测当前选中节点（按钮禁用、防重复点）。
  bool _testing = false;

  /// 正在测全部节点（按钮禁用、防重复点）。
  bool _testingAll = false;

  /// 已展开的分组 key；默认空＝全部折叠，只记在弹窗 State 里。
  final Set<String> _expandedGroups = {};

  /// 按订阅分组：组内保持 [nodes] 原有顺序，不重排；组按首次出现
  /// 的顺序排。
  List<_NodeGroup> _groupNodes(List<Node> nodes) {
    final groups = <_NodeGroup>[];
    final byKey = <String, _NodeGroup>{};
    for (final node in nodes) {
      final (key: key, title: title) = _groupOf(node);
      var group = byKey[key];
      if (group == null) {
        group = (key: key, title: title, nodes: <Node>[]);
        byKey[key] = group;
        groups.add(group);
      }
      group.nodes.add(node);
    }
    return groups;
  }

  /// 分组标题取值：单节点那组固定叫“手动添加”（[SingleNodeStore]
  /// 的显示名，见 single_node_store.dart）；其余订阅有订阅名用
  /// 订阅名，没名字用订阅 id，两者都没有叫“未命名订阅”。
  ({String key, String title}) _groupOf(Node node) {
    final id = node.subscriptionId;
    if (id == SingleNodeStore.singleNodesId) {
      return (key: id!, title: SingleNodeStore.singleNodesName);
    }
    final name = node.subscriptionName?.trim();
    if (name != null && name.isNotEmpty) {
      return (key: id ?? name, title: name);
    }
    if (id != null && id.isNotEmpty) {
      return (key: id, title: id);
    }
    return (key: '', title: '未命名订阅');
  }

  /// 点一行：调 selectNode 切过去；成功关弹窗，失败把原因留在弹窗里。
  Future<void> _select(Node node) async {
    final ok = await ref.read(nodesProvider.notifier).selectNode(node);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _error = ref.read(nodesProvider).selectionReason ?? '切换失败，请重试';
    });
  }

  /// 测当前选中节点的连通性（testSingleSpeed 只测这一个，不测全部）；
  /// 测完 nodesProvider 里的延迟已更新，弹窗跟着刷新。
  Future<void> _testSelected() async {
    if (_testing) return;
    final selected = ref.read(nodesProvider).selectedNode;
    if (selected == null) return;
    setState(() {
      _testing = true;
      _error = null;
    });
    final ok = await ref
        .read(nodesProvider.notifier)
        .testSingleSpeed(selected);
    if (!mounted) return;
    setState(() {
      _testing = false;
      if (!ok) {
        _error =
            ref.read(nodesProvider).speedTestError ?? '正在测速，请稍后再试';
      }
    });
  }

  /// 测全部节点（testAllSpeeds 测全部，不只测当前选中节点）；
  /// 测速中按钮禁用、防重复点；失败原因留在弹窗里。
  /// 单节点测速失败不走这里（只标该节点），只有整轮没跑起来
  /// 才留错。
  Future<void> _testAll() async {
    if (_testingAll || ref.read(nodesProvider).testingSpeed) return;
    setState(() {
      _testingAll = true;
      _error = null;
    });
    final ok = await ref.read(nodesProvider.notifier).testAllSpeeds();
    if (!mounted) return;
    setState(() {
      _testingAll = false;
      if (!ok) {
        _error =
            ref.read(nodesProvider).speedTestError ?? '测速失败，请稍后再试';
      }
    });
  }

  /// 只测一行（点行内延迟处触发，复用节点页 `_LatencyChip` 的
  /// 做法）：只改这一行的延迟/失败标记，不碰其他行、不重排；
  /// 一键测速进行中、或已有单节点在测时直接返回（不另起一轮）。
  /// 单节点测速失败只标该行（红点＋原因），不写进弹窗错误行。
  Future<void> _testSingle(Node node) async {
    final state = ref.read(nodesProvider);
    if (state.testingSpeed || state.testingSingleNodeKey != null) return;
    final ok = await ref.read(nodesProvider.notifier).testSingleSpeed(node);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _error =
            ref.read(nodesProvider).speedTestError ?? '正在测速，请稍后再试';
      });
    }
  }

  /// 弹窗里的延迟文案：与节点页延迟芯片同一口径——测到的数字本身绿色，
  /// 失败只显示红色圆点＋原因（不写“测速失败”四个字当标题），没测过灰字。
  /// 绿色与 nodes_page.dart 的 _LatencyChip 是同一对（白天 #157347 /
  /// 夜晚 #4ADE80），主题 token 里没有成功/绿色，见那里的注释。
  Widget _latencyLabel(Node node, bool testingThis) {
    final theme = Theme.of(context);
    // 测速中该行转圈（复用节点页 _LatencyChip 的做法），其他行不动。
    if (testingThis) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (node.latencyMs != null) {
      final okColor = theme.brightness == Brightness.dark
          ? const Color(0xFF4ADE80)
          : const Color(0xFF157347);
      return Text(
        '${node.latencyMs}ms',
        style: TextStyle(color: okColor),
      );
    }
    if (node.latencyFailed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              node.latencyFailureReason ?? '测速失败',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      );
    }
    return const Text('未测速');
  }

  @override
  Widget build(BuildContext context) {
    final nodesState = ref.watch(nodesProvider);
    final nodes = nodesState.nodes;
    final selectedName = nodesState.selectedNodeName;
    final testingKey = nodesState.testingSingleNodeKey;
    final testingAll = _testingAll || nodesState.testingSpeed;
    final theme = Theme.of(context);
    final groups = _groupNodes(nodes);
    return AlertDialog(
      title: const Text('选择节点'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTokens.spacingXs),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final group in groups) ...[
                    _GroupHeader(
                      title: group.title,
                      count: group.nodes.length,
                      expanded: _expandedGroups.contains(group.key),
                      onTap: () {
                        setState(() {
                          if (_expandedGroups.contains(group.key)) {
                            _expandedGroups.remove(group.key);
                          } else {
                            _expandedGroups.add(group.key);
                          }
                        });
                      },
                    ),
                    if (_expandedGroups.contains(group.key))
                      for (final node in group.nodes)
                        _NodeRow(
                          node: node,
                          isSelected: node.name == selectedName,
                          testingThis: testingKey == node.dedupKey,
                          testingAny: testingAll,
                          latencyLabel: _latencyLabel(
                            node,
                            testingKey == node.dedupKey,
                          ),
                          onSelect: () => _select(node),
                          onTestSingle: () => _testSingle(node),
                        ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: testingAll ? null : _testAll,
          child: Text(testingAll ? '测速中…' : '测速全部'),
        ),
        TextButton(
          onPressed:
              _testing ||
                  testingAll ||
                  nodesState.selectedNode == null
              ? null
              : _testSelected,
          child: Text(_testing ? '测速中…' : '测速当前节点'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 订阅分组的组头：点一下展开/收起该组（箭头跟着转）。
/// 标题只写订阅名，节点数另起一格，避免标题带数字后
/// `find.text(订阅名)` 认不出来。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: AppTokens.spacingXs,
          horizontal: AppTokens.spacingXs,
        ),
        child: Row(
          children: [
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: AppIcon(
                icon: AppIcons.chevronRight,
                size: AppIconSize.sm,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: AppTokens.spacingXs),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            Text(
              '$count 个节点',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹窗里的一行节点：名称＋延迟，选中行用选中底色＋对勾。
///
/// 点行本身是选节点（[_NodePickerDialogState._select]）；点行内
/// 延迟处是只测这一行（内层 InkWell，复用节点页 `_LatencyChip`
/// 的做法：手势仲裁内层优先，点延迟不选中）。测速中该行转圈。
class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.isSelected,
    required this.testingThis,
    required this.testingAny,
    required this.latencyLabel,
    required this.onSelect,
    required this.onTestSingle,
  });

  final Node node;
  final bool isSelected;
  final bool testingThis;
  final bool testingAny;
  final Widget latencyLabel;
  final VoidCallback onSelect;
  final VoidCallback onTestSingle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canTestSingle = !testingThis && !testingAny;
    return ListTile(
      selected: isSelected,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
      title: Text(
        node.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Tooltip(
        message: testingThis
            ? '正在测速…'
            : '点一下只测这一个节点',
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: canTestSingle ? onTestSingle : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: latencyLabel,
          ),
        ),
      ),
      trailing: isSelected
          ? AppIcon(
              icon: AppIcons.circleCheck,
              size: AppIconSize.sm,
              color: theme.colorScheme.primary,
            )
          : null,
      onTap: onSelect,
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      height: _HomePageState._statCellHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: AppTokens.spacingMd,
          horizontal: 4,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
