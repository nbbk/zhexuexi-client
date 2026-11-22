import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置页各项开关的状态（切片 6）。
///
/// 全部存在 shared_preferences（只存布尔值，不含订阅与令牌）。
/// 开机自启（Windows）与后台保活（Android）只存偏好：系统级接线
/// （Windows 注册表 / 开机启动项、Android 前台服务保活）随平台适配
/// 做，MVP 先记偏好、界面只在对应平台上显示该行；通知开关同样只存
/// 偏好，通知推送本身后续版本接入。
class SettingsState {
  const SettingsState({
    this.autoUpdate = true,
    this.notifications = true,
    this.autoStart = false,
    this.keepAlive = false,
    this.tun = false,
  });

  /// 订阅自动更新（切片 5）：每天一次、仅 Wi-Fi；关掉后 App 启动
  /// 与我的页打开时都不再自动拉订阅，手动刷新不受影响。
  final bool autoUpdate;

  /// 通知（偏好已存，推送功能后续版本接入）。
  final bool notifications;

  /// 开机自启（Windows，偏好已存，系统级接线随平台适配做）。
  final bool autoStart;

  /// 后台保活（Android，偏好已存，系统级接线随平台适配做）。
  final bool keepAlive;

  /// TUN 模式：开启后配置里加一条 tun 入站（见
  /// [SingboxConfigBuilder.build] 的 `tunEnabled`），下次生成配置
  /// 时生效；核心在跑时切换会立即重载配置。
  final bool tun;

  SettingsState copyWith({
    bool? autoUpdate,
    bool? notifications,
    bool? autoStart,
    bool? keepAlive,
    bool? tun,
  }) {
    return SettingsState(
      autoUpdate: autoUpdate ?? this.autoUpdate,
      notifications: notifications ?? this.notifications,
      autoStart: autoStart ?? this.autoStart,
      keepAlive: keepAlive ?? this.keepAlive,
      tun: tun ?? this.tun,
    );
  }
}

/// 设置页开关的状态管理（切片 6）。
///
/// 读持久化是异步的：先给默认值，再把存过的值读回来覆盖。调用方
/// 读到的默认值与“用户没改过”一致（自动更新与通知默认开），不会
/// 因为读回时机晚了一步就把开关闪成反的。
class SettingsNotifier extends Notifier<SettingsState> {
  static const String _autoUpdateKey = 'settings_auto_update';
  static const String _notificationsKey = 'settings_notifications';
  static const String _autoStartKey = 'settings_auto_start';
  static const String _keepAliveKey = 'settings_keep_alive';
  static const String _tunKey = 'settings_tun';

  @override
  SettingsState build() {
    Future(() async {
      final prefs = await SharedPreferences.getInstance();
      state = SettingsState(
        autoUpdate: prefs.getBool(_autoUpdateKey) ?? true,
        notifications: prefs.getBool(_notificationsKey) ?? true,
        autoStart: prefs.getBool(_autoStartKey) ?? false,
        keepAlive: prefs.getBool(_keepAliveKey) ?? false,
        tun: prefs.getBool(_tunKey) ?? false,
      );
    });
    return const SettingsState();
  }

  Future<void> setAutoUpdate(bool value) async {
    state = state.copyWith(autoUpdate: value);
    await _save(_autoUpdateKey, value);
  }

  Future<void> setNotifications(bool value) async {
    state = state.copyWith(notifications: value);
    await _save(_notificationsKey, value);
  }

  Future<void> setAutoStart(bool value) async {
    state = state.copyWith(autoStart: value);
    await _save(_autoStartKey, value);
  }

  Future<void> setKeepAlive(bool value) async {
    state = state.copyWith(keepAlive: value);
    await _save(_keepAliveKey, value);
  }

  Future<void> setTun(bool value) async {
    state = state.copyWith(tun: value);
    await _save(_tunKey, value);
  }

  Future<void> _save(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {
      // 持久化失败不影响本次操作：下次启动回落默认值。
    }
  }
}

/// 设置页开关（全项目共用这一个 provider，设置页、自动更新、配置
/// 生成都读它）。
final settingsProvider =
    NotifierProvider<SettingsNotifier, SettingsState>(
      SettingsNotifier.new,
    );
