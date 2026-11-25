import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_theme.dart';

/// 当前主题（主题注册表里的 id，如 `day` / `night`）。
///
/// 主题系统做成可切换的架子：现在先注册白天/夜晚两档，后面再加
/// 更多风格主题时只在 [AppThemes] 里加一个主题定义，不用改页面代码。
/// 选择存在 shared_preferences（`app_theme_id`），重启后还保持；
/// 默认主题是定好的那套（墨蓝＋香槟金＋象牙白）。
/// 切换后全端生效：入口 [MaterialApp] 读这个 provider，
/// 按 id 取 [AppThemeDefinition.themeData]。
class ThemeNotifier extends Notifier<String> {
  static const String _themeIdKey = 'app_theme_id';

  @override
  String build() {
    Future(() async {
      final prefs = await SharedPreferences.getInstance();
      state = AppThemes.byId(prefs.getString(_themeIdKey)).id;
    });
    return AppThemes.defaultId;
  }

  /// 当前主题定义。
  AppThemeDefinition get current => AppThemes.byId(state);

  /// 是否夜晚主题。
  bool get isNight => state == AppThemes.night.id;

  /// 切换白天 / 夜晚（两档切换的快捷方式）。
  Future<void> toggle() async {
    await setTheme(isNight ? AppThemes.day.id : AppThemes.night.id);
  }

  /// 切到指定主题（id 必须在注册表里，不在的忽略、不写坏偏好）。
  Future<void> setTheme(String id) async {
    if (!AppThemes.all.any((t) => t.id == id)) return;
    state = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_themeIdKey, id);
    } catch (_) {
      // 持久化失败不影响本次切换：下次启动回落默认主题。
    }
  }
}

/// 当前主题 id（全项目共用这一个 provider，入口与设置页都读它）。
final appThemeProvider = NotifierProvider<ThemeNotifier, String>(
  ThemeNotifier.new,
);
