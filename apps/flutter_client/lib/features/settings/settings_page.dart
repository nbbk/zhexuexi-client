import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/app_motion.dart';
import '../../widgets/app_icon.dart';
import '../../core/app_tokens.dart';

import '../../core/app_theme.dart';
import '../../core/core_provider.dart';
import '../../core/custom_rule.dart';
import '../../core/routing_mode.dart';
import '../../core/singbox_config.dart';
import '../../core/singbox_core.dart';
import '../../services/custom_rules_notifier.dart';
import '../../services/diagnostics_service.dart';
import '../../services/nodes_notifier.dart';
import '../../services/remote_config_notifier.dart';
import '../../services/remote_config_service.dart';
import '../../services/routing_mode_notifier.dart';
import '../../services/settings_notifier.dart';
import '../../services/theme_notifier.dart';

/// 设置页：常用在上、高级默认折叠在下，底部是“关于”（切片 6）。
///
/// - 常用：分流模式（三段式，与首页同一套 [RoutingModeNotifier]）、
///   订阅自动更新、通知、语言（暂只简体中文，置灰）、开机自启
///   （Windows 才显示）/ 后台保活（Android 才显示）；
/// - 高级（默认折叠）：TUN 开关、DNS 配置查看（防泄漏已开启、不可
///   关闭）、自定义规则、分应用代理（Android 专属，后续版本，置灰）、
///   诊断（导出诊断包、连接检测）、清除缓存；
/// - 关于：客户端版本、sing-box 核心版本、面板版本要求、远程配置版本、
///   检查更新（切片 7 接远程配置中心：拉到新版就换品牌与订阅地址）。
///
/// 开关只记本地状态的是两处（通知、开机自启 / 后台保活）：偏好已
/// 存 shared_preferences，功能本身后续版本接入，行内副标题写明，
/// 不让用户以为点了就有用。其余开关都真实生效。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String _coreVersion = '—';

  @override
  void initState() {
    super.initState();
    _loadCoreVersion();
  }

  Future<void> _loadCoreVersion() async {
    try {
      final version = await ref.read(coreServiceProvider).coreVersion();
      if (mounted) setState(() => _coreVersion = version);
    } catch (_) {
      // 插件未初始化时读不到版本号，显示“—”即可。
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

  /// TUN 开关：先记偏好，再把新值写进配置（有节点时；没节点时只记
  /// 偏好，下次生成配置时生效）。核心在跑时换配置会重载（短暂断开，
  /// 与模式切换同一行为）。写配置失败时把开关拨回去，不留“界面
  /// 开着、配置没开”的两张皮。
  Future<void> _onTunChanged(bool value) async {
    final settings = ref.read(settingsProvider.notifier);
    final prev = ref.read(settingsProvider).tun;
    if (value == prev) return;
    await settings.setTun(value);
    final nodesState = ref.read(nodesProvider);
    if (nodesState.nodes.isEmpty) {
      if (mounted) {
        _showSnack(value ? 'TUN 已开启，下次启动核心时生效' : 'TUN 已关闭，下次启动核心时生效');
      }
      return;
    }
    final core = ref.read(coreServiceProvider);
    final result = await core.applyNodes(
      nodesState.nodes,
      mode: ref.read(routingModeProvider).mode,
      selectedNodeName: nodesState.selectedNodeName,
      customRules: ref.read(customRulesProvider.notifier).activeRules,
      tunEnabled: value,
    );
    if (!result.ok && mounted) {
      await settings.setTun(prev);
      _showSnack('TUN 切换失败，已保持原设置');
    }
  }

  /// 导出诊断包：生成报告文本，放弹窗里给用户看与复制。
  /// 报告里没有订阅链接、令牌与节点地址（见 diagnostics_service.dart）。
  Future<void> _exportDiagnostics() async {
    final core = ref.read(coreServiceProvider);
    final nodesState = ref.read(nodesProvider);
    final modeState = ref.read(routingModeProvider);
    final settings = ref.read(settingsProvider);
    final rules = ref.read(customRulesProvider);
    final current = nodesState.selectedNode;
    final report = buildDiagnosticsReport(
      DiagnosticsReportInput(
        appVersion: '0.1.0',
        coreVersion: _coreVersion,
        coreStatusText: _coreStatusText(core),
        modeLabel: modeState.mode.label,
        hasBinding: nodesState.status != NodesStatus.initial,
        nodeCount: nodesState.nodes.length,
        currentNodeName: current?.name,
        currentLatencyMs: current?.latencyMs,
        lastSpeedTestAt: nodesState.speedTestAt,
        lastUpdated: nodesState.lastUpdated,
        tunEnabled: settings.tun,
        customRulesCount: rules.length,
        autoUpdateEnabled: settings.autoUpdate,
        coreLastError: core.lastError,
        nodesErrorMessage: nodesState.errorMessage,
      ),
    );
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('诊断包'),
        content: SingleChildScrollView(child: SelectableText(report)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (context.mounted) Navigator.of(context).pop();
              _showSnack('诊断包已复制');
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }

  /// 连接检测：只查本机核心与 Clash API，不发外网请求。
  Future<void> _checkConnectivity() async {
    final core = ref.read(coreServiceProvider);
    final result = await ref
        .read(diagnosticsServiceProvider)
        .checkConnectivity(coreRunning: core.status == CoreStatus.started);
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('连接检测'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('核心'),
              trailing: Text(result.coreRunning ? '在跑' : '未启动'),
            ),
            ListTile(
              title: const Text('Clash API'),
              trailing: Text(result.clashApiReachable ? '连通' : '不通'),
            ),
            Text(result.detail),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 清除缓存：只清已测的节点延迟结果（节点列表与配置不动）。
  Future<void> _clearCache() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除缓存'),
        content: const Text('清除已测的节点延迟结果？节点列表与配置不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    ref.read(nodesProvider.notifier).clearSpeedResults();
    _showSnack('已清除测速缓存');
  }

  /// 检查更新（切片 7）：拉一次远程配置，按结果给提示。
  /// - 有新版：品牌已同步，订阅地址下次更新时生效；
  /// - 已是最新：报当前配置版本；
  /// - 拉不到：用上次的配置，不报错、不静默。
  Future<void> _checkUpdate() async {
    final result = await ref.read(remoteConfigProvider.notifier).refresh();
    if (!mounted) return;
    final message = switch (result.status) {
      RemoteConfigRefreshStatus.updated =>
        '已更新到配置 v${result.config.configVersion}。品牌已同步，订阅地址下次更新时生效。',
      RemoteConfigRefreshStatus.upToDate =>
        '已是最新配置（v${result.config.configVersion}）。',
      RemoteConfigRefreshStatus.offlineCached =>
        '配置中心暂时连不上，正在用上次的配置（v${result.config.configVersion}）。',
      RemoteConfigRefreshStatus.failed => '检查失败，请检查网络后重试。',
      RemoteConfigRefreshStatus.notPublished =>
        '远程配置暂未发布（配置中心还未上线），请稍后再试。',
    };
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('检查更新'),
        content: Text('当前版本 0.1.0。\n$message'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  String _coreStatusText(CoreService core) {
    return switch (core.status) {
      CoreStatus.stopped => '未连接',
      CoreStatus.starting => '连接中…',
      CoreStatus.started => '已连接',
      CoreStatus.stopping => '断开中…',
      CoreStatus.error =>
        '连接失败${core.lastError == null ? '' : '：${core.lastError}'}',
    };
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final modeState = ref.watch(routingModeProvider);
    final rules = ref.watch(customRulesProvider);
    final remoteState = ref.watch(remoteConfigProvider);

    return ListView(
      padding: const EdgeInsets.all(AppTokens.spacingMd),
      children: [
        const Text('常用设置', style: TextStyle(fontSize: 16)),
        const SizedBox(height: AppTokens.spacingXs),
        // 分流模式：与首页同一套 provider，改一处两处都变。
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
          onSelectionChanged: _onModeChanged,
        ),
        SwitchListTile(
          title: const Text('订阅自动更新'),
          subtitle: const Text('每天自动拉一次订阅，仅 Wi-Fi 下'),
          value: settings.autoUpdate,
          onChanged: (value) =>
              ref.read(settingsProvider.notifier).setAutoUpdate(value),
        ),
        SwitchListTile(
          title: const Text('通知'),
          subtitle: const Text('新版本提醒（后续版本接入）'),
          value: settings.notifications,
          onChanged: (value) =>
              ref.read(settingsProvider.notifier).setNotifications(value),
        ),
        // 外观主题：可切换的注册表（现在白天/夜晚两档，后面再加更多
        // 风格主题时只在 AppThemes 里加定义，不用改页面）；
        // 切换后全端生效，存在本地偏好里，重启后还保持。
        const ListTile(title: Text('主题'), subtitle: Text('白天 / 夜晚，后面还会加更多风格')),
        SegmentedButton<String>(
          style: SegmentedButton.styleFrom(
            selectedBackgroundColor: appThemeTokensOf(context)
                .segmentedSelectedBackground,
            selectedForegroundColor: appThemeTokensOf(context)
                .segmentedSelectedForeground,
          ),
          segments: [
            for (final theme in AppThemes.all)
              ButtonSegment(value: theme.id, label: Text(theme.name)),
          ],
          selected: {ref.watch(appThemeProvider)},
          onSelectionChanged: (selected) {
            if (selected.isEmpty) return;
            ref.read(appThemeProvider.notifier).setTheme(selected.first);
          },
        ),
        const ListTile(
          title: Text('语言'),
          subtitle: Text('暂只支持简体中文'),
          trailing: Text('简体中文'),
          enabled: false,
        ),
        if (Platform.isWindows)
          SwitchListTile(
            title: const Text('开机自启'),
            subtitle: const Text('偏好已保存，系统级接线随平台适配做'),
            value: settings.autoStart,
            onChanged: (value) =>
                ref.read(settingsProvider.notifier).setAutoStart(value),
          ),
        if (Platform.isAndroid)
          SwitchListTile(
            title: const Text('后台保活'),
            subtitle: const Text('偏好已保存，系统级接线随平台适配做'),
            value: settings.keepAlive,
            onChanged: (value) =>
                ref.read(settingsProvider.notifier).setKeepAlive(value),
          ),
        const SizedBox(height: AppTokens.spacingMd),
        ExpansionTile(
          title: const Text('高级设置'),
          children: [
            SwitchListTile(
              title: const Text('TUN 模式'),
              subtitle: const Text('系统级 TUN 接管流量，切换后重载配置'),
              value: settings.tun,
              onChanged: _onTunChanged,
            ),
            ExpansionTile(
              title: const Text('DNS 配置'),
              subtitle: const Text('防泄漏已开启，不可关闭'),
              children: [
                for (final entry in SingboxConfigBuilder.dnsSummary)
                  ListTile(
                    title: Text(entry.label),
                    subtitle: Text(entry.value),
                  ),
                const ListTile(
                  title: Text('防泄漏不可关闭'),
                  subtitle: Text('DNS 查询只走 DoH / DoT，不回落明文 UDP 53。'),
                ),
              ],
            ),
            ListTile(
              title: const Text('自定义规则'),
              subtitle: Text(
                rules.isEmpty
                    ? '暂无自定义规则，默认按内置规则分流'
                    : '${rules.length} 条规则（优先于内置规则）',
              ),
            ),
            for (final rule in rules)
              ListTile(
                title: Text(rule.domain),
                subtitle: Text(rule.action.label),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: rule.enabled,
                      onChanged: (value) => ref
                          .read(customRulesProvider.notifier)
                          .setEnabled(rule.id, value),
                    ),
                    IconButton(
                      icon: const AppIcon(icon: AppIcons.trash),
                      tooltip: '删除规则',
                      onPressed: () => ref
                          .read(customRulesProvider.notifier)
                          .removeRule(rule.id),
                    ),
                  ],
                ),
              ),
            ListTile(
              title: const Text('添加规则'),
              leading: const AppIcon(icon: AppIcons.plus),
              onTap: () => _showAddRuleDialog(),
            ),
            const ListTile(
              title: Text('分应用代理'),
              subtitle: Text('Android 专属，后续版本'),
              enabled: false,
            ),
            ListTile(
              title: const Text('导出诊断包'),
              subtitle: const Text('版本号、状态、节点名、DNS 配置与最近错误；不含订阅链接、令牌与节点地址'),
              leading: const AppIcon(icon: AppIcons.bug),
              onTap: _exportDiagnostics,
            ),
            ListTile(
              title: const Text('连接检测'),
              subtitle: const Text('只查本机核心与 Clash API，不发外网请求'),
              leading: const AppIcon(icon: AppIcons.network),
              onTap: _checkConnectivity,
            ),
            ListTile(
              title: const Text('清除缓存'),
              subtitle: const Text('清除已测的节点延迟结果'),
              leading: const AppIcon(icon: AppIcons.trash),
              onTap: _clearCache,
            ),
          ],
        ),
        const SizedBox(height: AppTokens.spacingMd),
        const Text('关于', style: TextStyle(fontSize: 16)),
        const SizedBox(height: AppTokens.spacingXs),
        const ListTile(title: Text('客户端版本'), trailing: Text('0.1.0')),
        ListTile(
          title: const Text('sing-box 核心版本'),
          trailing: Text(_coreVersion),
        ),
        const ListTile(title: Text('面板版本要求'), trailing: Text('≥ 1.3.29')),
        ListTile(
          title: const Text('远程配置版本'),
          trailing: Text(
            'v${remoteState.config.configVersion}'
            '${remoteState.offline ? '（上次的配置）' : ''}',
          ),
        ),
        ListTile(
          title: const Text('检查更新'),
          subtitle: const Text('拉一次远程配置，品牌与订阅地址跟着换'),
          onTap: _checkUpdate,
        ),
      ],
    );
  }

  /// 添加自定义规则的弹窗：域名 + 动作；域名不合格或已存在时
  /// 提示原因、不关弹窗、不写规则。
  Future<void> _showAddRuleDialog() async {
    final domainController = TextEditingController();
    var action = CustomRuleAction.proxy;
    final saved = await showAppDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('添加规则'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: domainController,
                decoration: const InputDecoration(
                  labelText: '域名后缀',
                  hintText: '例如 example.com',
                ),
              ),
              const SizedBox(height: AppTokens.spacingSm),
              SegmentedButton<CustomRuleAction>(
                segments: const [
                  ButtonSegment(
                    value: CustomRuleAction.proxy,
                    label: Text('走代理'),
                  ),
                  ButtonSegment(
                    value: CustomRuleAction.direct,
                    label: Text('直连'),
                  ),
                ],
                selected: {action},
                onSelectionChanged: (selected) {
                  if (selected.isEmpty) return;
                  setDialogState(() => action = selected.first);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    final ok = await ref
        .read(customRulesProvider.notifier)
        .addRule(domainController.text, action);
    if (!ok && mounted) {
      _showSnack('域名不合格或已存在，未添加');
    }
  }
}
