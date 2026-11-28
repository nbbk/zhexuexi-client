import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../brand/remote_config.dart';
import '../../core/app_motion.dart';
import '../../services/app_version.dart';
import '../../widgets/app_icon.dart';
import '../../core/app_tokens.dart';

import '../../core/app_theme.dart';
import '../../core/core_provider.dart';
import '../../core/custom_rule.dart';
import '../../core/routing_mode.dart';
import '../../core/singbox_config.dart';
import '../../core/singbox_core.dart';
import '../../features/update/app_update_dialog.dart';
import '../../features/per_app_proxy/per_app_proxy_page.dart';
import '../../services/app_update/app_update_provider.dart';
import '../../services/app_update/app_updater.dart';
import '../../services/config_rebuild.dart';
import '../../services/custom_rules_notifier.dart';
import '../../services/diagnostics_service.dart';
import '../../services/lan_address.dart';
import '../../services/lan_proxy_notifier.dart';
import '../../services/nodes_notifier.dart';
import '../../services/per_app_proxy_notifier.dart';
import '../../services/remote_config_notifier.dart';
import '../../services/remote_config_service.dart';
import '../../services/routing_mode_notifier.dart';
import '../../services/settings_notifier.dart';
import '../../services/theme_notifier.dart';
import '../../widgets/glass_card.dart';

/// 设置页：常用在上、高级默认折叠在下，底部是“关于”（切片 6）。
///
/// - 常用：分流模式（三段式，与首页同一套 [RoutingModeNotifier]）、
///   订阅自动更新、通知、语言（暂只简体中文，置灰）、开机自启
///   （Windows 才显示）/ 后台保活（Android 才显示）；
/// - 高级（默认折叠）：TUN 开关、DNS 配置查看（防泄漏已开启、不可
///   关闭）、自定义规则、分应用代理（Android 专属，仅选中应用走代理）、
///   局域网代理（开关＋端口＋鉴权＋风险提示，与首页格子同一份状态）、
///   诊断（导出诊断包、连接检测）、清除缓存；
/// - 关于：客户端版本、sing-box 核心版本、面板版本要求、远程配置版本、
///   检查更新（切片 7 接远程配置中心：拉到新版就换品牌与订阅地址）。
///
/// 开关只记本地状态的是两处（通知、开机自启 / 后台保活）：偏好已
/// 存 shared_preferences，推送功能本身后续版本接入。其余开关都
/// 真实生效。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String _coreVersion = '—';

  /// 真实安装版本（PackageInfo 读到的 versionName，与 pubspec 同步；
  /// 读不到时回退到 appVersion 常量）。0.1.10–0.1.13 的教训：
  /// 关于页直接用常量，pubspec 升了常量没升，装上的明明是 0.1.13，
  /// 显示的却是 0.1.10。
  String _appVersion = appVersion;

  /// 密码行是否明文显示密码（默认打码）。
  bool _showLanPassword = false;

  @override
  void initState() {
    super.initState();
    _loadCoreVersion();
    _loadAppVersion();
    // 待安装状态：打开设置页就刷新一次，有已下载没装的版本时
    // “检查应用更新”那行直接显示“已下载 vX.Y.Z，点击安装”。
    unawaited(ref.read(appUpdateProvider.notifier).refreshPending());
  }

  Future<void> _loadAppVersion() async {
    final version = await resolveAppVersion();
    if (mounted) setState(() => _appVersion = version);
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
      // 局域网代理跟着 TUN 一起进配置：切 TUN 不能悄悄关了它。
      lanProxy: ref.read(lanProxyProvider).enabled,
      lanProxyPort: ref.read(lanProxyProvider).port,
      lanProxyUsername: ref.read(lanProxyProvider).authCredentials?.username,
      lanProxyPassword: ref.read(lanProxyProvider).authCredentials?.password,
    );
    if (!result.ok && mounted) {
      await settings.setTun(prev);
      _showSnack('TUN 切换失败，已保持原设置');
    }
  }

  /// 局域网代理开关：先记偏好，再把新值写进配置（有节点时；没节点时
  /// 只记偏好，下次生成配置时生效）。核心在跑时换配置会重载（短暂断开，
  /// 与 TUN 切换同一行为）。写配置失败时把开关拨回去。
  Future<void> _onLanProxyChanged(bool value) async {
    final notifier = ref.read(lanProxyProvider.notifier);
    final prev = ref.read(lanProxyProvider).enabled;
    if (value == prev) return;
    await notifier.setEnabled(value);
    final ok = await rebuildConfigWithCurrentSettings(ref);
    if (!mounted) return;
    if (!ok) {
      await notifier.setEnabled(prev);
      _showSnack('局域网代理切换失败，已保持原设置');
      return;
    }
    if (ref.read(nodesProvider).nodes.isEmpty) {
      _showSnack(
        value ? '局域网代理已开启，下次启动核心时生效' : '局域网代理已关闭，下次启动核心时生效',
      );
    }
  }

  /// 局域网代理的端口/鉴权/账号改动：先记偏好（[persist] 返回 false
  /// 表示没存上，直接停）；代理开着时重建配置让它生效，关着时只记
  /// 偏好（下次开开关时生效，不为此断一次网）。写配置失败时把改动
  /// 拨回去（[revert]）。
  Future<void> _onLanFieldChanged({
    required Future<bool> Function() persist,
    required Future<void> Function() revert,
  }) async {
    final saved = await persist();
    if (!saved) return;
    if (!ref.read(lanProxyProvider).enabled) return;
    final ok = await rebuildConfigWithCurrentSettings(ref);
    if (!ok && mounted) {
      await revert();
      _showSnack('保存失败，已保持原设置');
    }
  }

  Future<void> _onLanAuthChanged(bool value) async {
    final prev = ref.read(lanProxyProvider).authEnabled;
    await _onLanFieldChanged(
      persist: () async {
        await ref.read(lanProxyProvider.notifier).setAuthEnabled(value);
        return true;
      },
      revert: () =>
          ref.read(lanProxyProvider.notifier).setAuthEnabled(prev),
    );
  }

  Future<void> _saveLanPort(int port) async {
    final prev = ref.read(lanProxyProvider).port;
    await _onLanFieldChanged(
      persist: () async {
        await ref.read(lanProxyProvider.notifier).setPort(port);
        return true;
      },
      revert: () => ref.read(lanProxyProvider.notifier).setPort(prev),
    );
  }

  Future<void> _saveLanUsername(String username) async {
    final prev = ref.read(lanProxyProvider).username;
    await _onLanFieldChanged(
      persist: () =>
          ref.read(lanProxyProvider.notifier).setUsername(username),
      revert: () => ref.read(lanProxyProvider.notifier).setUsername(prev),
    );
  }

  Future<void> _saveLanPassword(String password) async {
    final prev = ref.read(lanProxyProvider).password;
    await _onLanFieldChanged(
      persist: () =>
          ref.read(lanProxyProvider.notifier).setPassword(password),
      revert: () => ref.read(lanProxyProvider.notifier).setPassword(prev),
    );
  }

  /// 局域网代理的文本编辑弹窗（端口/用户名/密码共用）：输入框＋保存；
  /// 校验不过在弹窗里提示，不关弹窗。密码弹窗多一个“随机生成”按钮。
  Future<void> _showLanEditDialog({
    required String title,
    required String initialValue,
    required TextInputType keyboardType,
    bool showGenerate = false,
    String? Function(String value)? validator,
    required Future<void> Function(String value) onSave,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final formKey = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            keyboardType: keyboardType,
            autofocus: true,
            validator: (value) => validator?.call(value ?? ''),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          if (showGenerate)
            TextButton(
              onPressed: () {
                controller.text = LanProxyNotifier.generatePassword();
              },
              child: const Text('随机生成'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              if (!(formKey.currentState?.validate() ?? false)) return;
              await onSave(controller.text);
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _showLanPortDialog() async {
    final lan = ref.read(lanProxyProvider);
    await _showLanEditDialog(
      title: '端口',
      initialValue: '${lan.port}',
      keyboardType: TextInputType.number,
      validator: (value) {
        final port = int.tryParse(value.trim());
        if (port == null || port < 1 || port > 65535) return '端口须是 1–65535';
        return null;
      },
      onSave: (value) => _saveLanPort(int.parse(value.trim())),
    );
  }

  Future<void> _showLanUsernameDialog() async {
    final lan = ref.read(lanProxyProvider);
    await _showLanEditDialog(
      title: '用户名',
      initialValue: lan.username,
      keyboardType: TextInputType.text,
      validator: (value) => value.trim().isEmpty ? '用户名不能为空' : null,
      onSave: _saveLanUsername,
    );
  }

  Future<void> _showLanPasswordDialog() async {
    final lan = ref.read(lanProxyProvider);
    await _showLanEditDialog(
      title: '密码',
      initialValue: lan.password,
      keyboardType: TextInputType.text,
      showGenerate: true,
      validator: (value) => value.isEmpty ? '密码不能为空' : null,
      onSave: _saveLanPassword,
    );
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
    // P0-4 诊断可见性（2026-11-26 0.1.2）：诊断包里带当前生成配置的
    // route/dns 段快照＋实时连接 chain 列表；核心没跑时连接列表
    // 为空，不阻塞导出。
    final configResult = SingboxConfigBuilder.build(
      nodesState.nodes,
      mode: modeState.mode,
      selectedNodeName: nodesState.selectedNodeName,
      customRules: ref.read(customRulesProvider.notifier).activeRules,
      tunEnabled: settings.tun,
      // 诊断快照要忠实于当前生成配置，局域网代理也带上。
      lanProxy: ref.read(lanProxyProvider).enabled,
      lanProxyPort: ref.read(lanProxyProvider).port,
      lanProxyUsername: ref.read(lanProxyProvider).authCredentials?.username,
      lanProxyPassword: ref.read(lanProxyProvider).authCredentials?.password,
    );
    final configSnapshot = jsonEncode({
      'route': configResult.config['route'],
      'dns': configResult.config['dns'],
    });
    final connectionChains = await ref
        .read(clashApiClientProvider)
        .getConnections();
    final report = buildDiagnosticsReport(
      DiagnosticsReportInput(
        appVersion: _appVersion,
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
        // 0.1.3 D 路修复 2：探活状态进诊断包（core.probeState；
        // 失败只写探活位、不翻状态，状态仍显示“运行中”）。
        probeFailed: core.probeState.failed,
        probeError: core.probeState.error,
        probeAt: core.probeState.at,
        nodesErrorMessage: nodesState.errorMessage,
        configSnapshot: configSnapshot,
        connectionChains: connectionChains,
        // 0.1.9 采样时序＋黑断时刻＋核心日志尾巴（CoreService 的
        // 内存环形缓冲；核心停即清空，导出时没跑就是空，不编造）。
        timeline: core.samplingTimeline,
        blackoutAt: core.blackoutAt,
        coreLogTail: core.coreLogTail,
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
    // failed 时先一句定性、再逐条列原因（与 _checkAppUpdate 的
    // failureMessage 模式一致）。0.1.4 C 路 P0-3：删掉 0.1.2 的过时
    // 尾注“检查走手机直连，不走代理，开关开了也帮不上”——0.1.3
    // 已加代理轮，那句与失败行里的“（经代理）”标记直接矛盾；
    // 改按实际写：直连失败后开关已开且核心已连接时会经代理再试
    // 一轮，开关没开时代理轮不跑（失败行里会有一行“代理轮未跑”）。
    final failedDetail = result.failures.isEmpty
        ? '检查失败，请检查网络后重试。'
        : '检查失败，请检查网络后重试。\n${result.failureMessage}';
    final message = switch (result.status) {
      RemoteConfigRefreshStatus.updated =>
        '已更新到配置 v${result.config.configVersion}。品牌已同步，订阅地址下次更新时生效。',
      RemoteConfigRefreshStatus.upToDate =>
        '已是最新配置（v${result.config.configVersion}）。',
      RemoteConfigRefreshStatus.offlineCached =>
        '配置中心暂时连不上，正在用上次的配置（v${result.config.configVersion}）。',
      RemoteConfigRefreshStatus.failed =>
        '$failedDetail\n直连失败后，开关已开且核心已连接时会经代理再试一轮；开关没开时代理轮不跑，开着开关再点一次会经代理再试。',
      RemoteConfigRefreshStatus.notPublished =>
        '远程配置暂未发布（配置中心还未上线），请稍后再试。',
    };
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('检查更新'),
        content: Text('当前版本 $_appVersion。\n$message'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 检查应用更新：查 GitHub 最新 Release（主通道；失败走备通道
  /// 自托管，本轮备通道未启用时如实报原因）。
  /// - 安卓：有新版弹更新弹窗（版本号＋Release 说明，点“立即更新”
  ///   下载安装）；同一版本已下载好时弹窗直接给“安装”入口，
  ///   不用重新下载；
  /// - Windows（0.1.22）：有新版只弹提示，点“去下载”在浏览器里
  ///   打开 Windows 安装包下载页，不下载、不安装；
  /// - 已是最新：报当前版本号；
  /// - 查不到：报每条通道的原因，不说“已是最新”，不静默。
  /// 与上面那个“检查更新”（拉远程配置、换品牌与订阅地址）是两回事，
  /// 入口分开写，不共用。
  Future<void> _checkAppUpdate() async {
    final result = await ref.read(appUpdateProvider.notifier).checkManual();
    if (!mounted) return;
    switch (result.status) {
      case AppUpdateCheckStatus.available:
        await showAppUpdateDialog(
          context: context,
          updater: ref.read(appUpdaterProvider),
          info: result.latest!,
          alreadyDownloaded:
              ref.read(appUpdateProvider.notifier).pendingApk,
        );
      case AppUpdateCheckStatus.upToDate:
        await showAppDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('检查应用更新'),
            content: Text('已是最新版本（v${result.currentVersion}）。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      case AppUpdateCheckStatus.failed:
        await showAppDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('检查应用更新'),
            content: Text(
              '检查失败，请检查网络后重试。\n${result.failureMessage}'
              '\n核心开着时先走本机代理，代理不通回落直连；核心没开时直接直连。',
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
    final lan = ref.watch(lanProxyProvider);
    final lanIp = ref.watch(lanIpProvider).valueOrNull;
    final updateState = ref.watch(appUpdateProvider);

    // 夜晚模式（0.1.2）：包一层 GlassBackground，与首页/节点页同款
    // 渐变底（#070F1C→#082E63→#0B3D84），不再露 Scaffold 纯色底。
    return GlassBackground(
      child: ListView(
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
          subtitle: const Text('新版本提醒'),
          value: settings.notifications,
          onChanged: (value) =>
              ref.read(settingsProvider.notifier).setNotifications(value),
        ),
        // 外观主题：可切换的注册表（加风格主题时只在 AppThemes 里
        // 加定义，不用改页面）；切换后全端生效，存在本地偏好里，
        // 重启后还保持。十个主题全展开放不下，默认折叠，点开再选
        //（与“高级设置”同一折叠模式）。
        ExpansionTile(
          title: const Text('主题'),
          subtitle: Text(
            '五套皮肤，各有白天 / 夜晚 · 当前：'
            '${AppThemes.byId(ref.watch(appThemeProvider)).name}',
          ),
          children: [
            for (final theme in AppThemes.all)
              ListTile(
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: theme.tokens.powerGradient,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(
                      color: theme.tokens.gold,
                      width: 2,
                    ),
                  ),
                ),
                title: Text(theme.name),
                trailing: ref.watch(appThemeProvider) == theme.id
                    ? Icon(
                        Icons.check,
                        color: appThemeTokensOf(
                          context,
                        ).segmentedSelectedBackground,
                      )
                    : null,
                onTap: () =>
                    ref.read(appThemeProvider.notifier).setTheme(theme.id),
              ),
          ],
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
              subtitle: const Text('系统级 TUN 接管流量，不开就没有代理；切换后重载配置'),
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
            if (Platform.isAndroid)
              ListTile(
                title: const Text('分应用代理'),
                subtitle: Text(
                  ref.watch(perAppProxyProvider).enabled
                      ? '仅 ${ref.watch(perAppProxyProvider).selected.length} 个应用走代理'
                      : '全部应用走代理',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PerAppProxyPage(),
                  ),
                ),
              ),
            // 局域网代理（0.1.14）：开关＋端口＋鉴权＋风险提示。
            // 与首页统计格里的格子是同一份状态（lanProxyProvider），
            // 两处互相实时同步。
            SwitchListTile(
              title: const Text('局域网代理'),
              subtitle: Text(
                !lan.enabled
                    ? '同一 Wi-Fi 下的其他设备可用手机做代理'
                    : lanIp == null
                        ? '已开启'
                        : '已开启 · $lanIp:${lan.port}',
              ),
              value: lan.enabled,
              onChanged: lan.switching ? null : _onLanProxyChanged,
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '家里 Wi-Fi 可用，公共 Wi-Fi 有风险：同一 Wi-Fi 下任何人都能连这个代理、走你的流量；建议保持鉴权开启。',
              ),
            ),
            ListTile(
              title: const Text('端口'),
              subtitle: const Text('混合代理（HTTP+SOCKS5）监听端口'),
              trailing: Text('${lan.port}'),
              onTap: _showLanPortDialog,
            ),
            SwitchListTile(
              title: const Text('用户名密码鉴权'),
              subtitle: const Text('开启后连接代理须输用户名和密码'),
              value: lan.authEnabled,
              onChanged: _onLanAuthChanged,
            ),
            ListTile(
              title: const Text('用户名'),
              trailing: Text(lan.username),
              onTap: _showLanUsernameDialog,
            ),
            ListTile(
              title: const Text('密码'),
              subtitle: const Text('连接代理时用，点一下查看或修改'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_showLanPassword ? lan.password : '••••••••'),
                  IconButton(
                    icon: AppIcon(
                      icon: _showLanPassword
                          ? AppIcons.eyeOff
                          : AppIcons.eye,
                    ),
                    tooltip: _showLanPassword ? '隐藏密码' : '显示密码',
                    onPressed: () => setState(
                      () => _showLanPassword = !_showLanPassword,
                    ),
                  ),
                ],
              ),
              onTap: _showLanPasswordDialog,
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
        ListTile(title: const Text('客户端版本'), trailing: Text(_appVersion)),
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
          // 0.1.4 C 路 P0-3：拉取最坏要几十秒，检查中给进度提示
          // （RemoteConfigState.checking），避免用户以为没反应而
          // 重复点；检查中再点也不开第二轮（notifier 等同一轮）。
          trailing: remoteState.checking
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: remoteState.checking ? null : _checkUpdate,
        ),
        ListTile(
          title: const Text('检查应用更新'),
          subtitle: Text(
            updateState.pendingReady && updateState.pendingVersion != null
                ? '已下载 v${updateState.pendingVersion}，点击安装'
                // Windows 上不下 APK、不安装：副标题按 Windows 口径写
                //（0.1.22；安卓那行还是“可下载安装”）。
                : Platform.isWindows
                    ? '检查 Windows 新版本，有新版打开下载页'
                    : '从 GitHub 检查新版本，可下载安装',
          ),
          onTap: _checkAppUpdate,
        ),
      ],
      ),
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
