import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mmkv/mmkv.dart';

import 'core/app_theme.dart';
import 'core/core_provider.dart';
import 'services/remote_config_notifier.dart';
import 'services/subscription_auto_refresh.dart';
import 'services/theme_notifier.dart';
import 'widgets/app_shell.dart';

/// 哲学系客户端入口（阶段 0：只搭架子 + 最小验证，未接真实面板/节点）。
///
/// 四个 tab：首页（大开关）/ 节点 / 我的 / 设置。
/// 品牌变量来自远程配置（remoteConfigProvider）：启动时先读本地缓存
/// 的最后一份好配置，拉不到用包内 brand.json，再拉不到用代码默认值；
/// 后台拉到新版就换上，界面跟着变，不用重装。
///
/// MMKV 必须在这里先初始化（小米真机教训，2026-11-25）：
/// flutter_sing_box 的 ProfileStorage 经 MmkvStorage 构造 MMKV 实例，
/// 未初始化时 Dart 侧抛 StateError（“forget initialize MMKV first?”），
/// 原生侧 PluginManager.init() 也不调 MMKV.initialize(context)；
/// Dart 的 MMKV.initialize() 经 FFI 调 mmkvInitialize_v2，初始化的是
/// 同一进程内的 native MMKV，所以 Dart 侧先初始化能覆盖两边——
/// 但必须发生在任何 MMKV 访问（ProfileStorage、CoreService.init、
/// _defaultEnsureSelectedProfile）之前，也就是 runApp 之前。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MMKV.initialize();
  runApp(const ProviderScope(child: ZhexuexiApp()));
}

class ZhexuexiApp extends ConsumerStatefulWidget {
  const ZhexuexiApp({super.key});

  @override
  ConsumerState<ZhexuexiApp> createState() => _ZhexuexiAppState();
}

class _ZhexuexiAppState extends ConsumerState<ZhexuexiApp> {
  @override
  void initState() {
    super.initState();
    // 远程配置（切片 7）：先读缓存立刻生效，后台再拉新版；
    // 失败不阻断界面，首页按来源给一句提示。
    unawaited(ref.read(remoteConfigProvider.notifier).init());
    // 核心初始化（订阅插件状态流、把磁盘上最后一份配置读回内存）：
    // 切片 3 首页大开关靠它推状态；失败不阻断界面，大开关点开时
    // 会再报具体原因。
    unawaited(_initCore());
    // 订阅自动更新（切片 5）：每天一次、仅 Wi-Fi；条件不满足时
    // 什么都不做，不阻断界面。
    unawaited(maybeAutoRefreshSubscription(ref));
  }

  Future<void> _initCore() async {
    try {
      await ref.read(coreServiceProvider).init();
    } catch (_) {
      // 初始化失败不抛到界面上：start() 时按“没有可用配置”再报错。
    }
  }

  @override
  Widget build(BuildContext context) {
    final brand = ref.watch(remoteConfigProvider).config.brand;
    // 外观主题（白天/夜晚，可切换的注册表）：设置页切换，
    // 持久化在本地偏好里；主题定义见 AppThemes，页面只读 token。
    final themeId = ref.watch(appThemeProvider);
    final themeDef = AppThemes.byId(themeId);
    return MaterialApp(
      title: brand.appName,
      theme: themeDef.themeData,
      home: AppShell(appName: brand.appName),
    );
  }
}
