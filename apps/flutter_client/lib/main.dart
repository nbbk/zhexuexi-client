import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mmkv/mmkv.dart';

import 'core/app_theme.dart';
import 'core/core_provider.dart';
import 'features/update/app_update_dialog.dart';
import 'services/app_update/app_update_provider.dart';
import 'services/app_update/app_updater.dart';
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
/// 未初始化时 Dart 侧抛 StateError（“forget initialize MMKV first?”）。
/// 注意：这里的初始化只覆盖 Dart 侧——它经 FFI 调 mmkvInitialize_v2，
/// 不置 Java 包装类的静态 rootDir；原生侧（SettingsManager /
/// ProfileManager 走 com.tencent.mmkv.MMKV）必须另在
/// PluginManager.init() 里调 MMKV.initialize(context, 与 Dart
/// 同一根目录）——Java 默认根目录与 Dart 的不一样
/// （`filesDir/mmkv` 对 `filesDir/app_flutter/mmkv`），
/// 不显式传同一目录原生侧会读到空库。2026-11-26 真机就是栽在这里：
/// Java 侧从未初始化，点开关时 SettingsManager 类初始化失败被毒化，
/// 之后每次访问只剩 NoClassDefFoundError。
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
  /// 启动安静查已为哪个版本弹过新版提示（同一版本只弹一次，
  /// 避免状态重建时重复弹）。
  String? _updatePromptedVersion;

  @override
  void initState() {
    super.initState();
    // 远程配置（切片 7）：先读缓存立刻生效，后台再拉新版；
    // 失败不阻断界面，首页按来源给一句提示。
    unawaited(ref.read(remoteConfigProvider.notifier).init());
    // 应用内更新：启动后安静查一次（GitHub → 自托管）；无网络、
    // 已是最新、全部通道失败时都不弹任何东西，只有查到新版才
    // 经 build 里的监听弹一次提示。
    // 必须等首帧后再查：checkManual 会立刻置状态为 checking，
    // 在 initState 里同步调会打断首帧挂载（`!_dirty` 断言）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(appUpdateProvider.notifier).checkQuiet());
    });
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
    // 新版提示监听（ref.listen 只能在 build 里用）：状态变成
    // available 时弹一次更新弹窗，同一版本只弹一次。
    // 手动查出来的新版（设置页点的“检查应用更新”）由设置页自己弹，
    // 这里跳过，不然同一版本会连弹两个弹窗。
    ref.listen<AppUpdateState>(appUpdateProvider, (_, next) {
      final latest = next.latest;
      if (next.status != AppUpdateStatus.available || latest == null) return;
      if (next.fromManualCheck) return;
      if (_updatePromptedVersion == latest.version) return;
      _updatePromptedVersion = latest.version;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final updater = ref.read(appUpdaterProvider);
        final pendingApk = ref.read(appUpdateProvider.notifier).pendingApk;
        DownloadedApk? alreadyDownloaded;
        if (next.pendingReady && pendingApk != null) {
          // 待安装提醒：一天只提醒一次；当天已提醒过就不弹，
          // 用户想装时去设置页点“已下载，点击安装”。
          if (await updater.wasRemindedToday(latest.version)) return;
          await updater.markRemindedToday(latest.version);
          alreadyDownloaded = pendingApk;
        }
        if (!mounted) return;
        // 用 State 的 context（this.context）：build 参数的 context
        // 不认 State 的 mounted 检查，跨异步间隙用它会被 lint 拦。
        unawaited(
          showAppUpdateDialog(
            context: this.context,
            updater: updater,
            info: latest,
            alreadyDownloaded: alreadyDownloaded,
          ),
        );
      });
    });
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
