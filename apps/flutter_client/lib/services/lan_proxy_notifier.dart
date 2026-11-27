import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 局域网代理设置（0.1.14）。
///
/// 开关默认关闭；开的时候 mixed 入站监听 0.0.0.0（见
/// [SingboxConfigBuilder.build] 的 `lanProxy`），同一 Wi-Fi 下的
/// 其他设备可用手机做代理，走同一套出站与分流规则。
///
/// 鉴权默认开启：用户名默认 `zhexuexi`，密码首次访问时自动生成
/// 12 位并持久化（设置页可见、可改、可重新生成）——开开关就有
/// 鉴权，不做无鉴权裸奔；用户也可以在设置页把鉴权关掉（同一处
/// 有公共 Wi-Fi 风险提示）。
///
/// 本文件只管偏好持久化（不调配置、不碰核心）：开关/端口/鉴权
/// 的生效（重建配置＋重载核心）由调用方经
/// `rebuildConfigWithCurrentSettings` 做，与 TUN 开关同一套路；
/// 配置生成时各处（模式切换、切节点、启动）读这个 provider，
/// 别各记一份。
class LanProxyState {
  const LanProxyState({
    this.enabled = false,
    this.port = LanProxyNotifier.defaultPort,
    this.authEnabled = true,
    this.username = LanProxyNotifier.defaultUsername,
    this.password = '',
    this.switching = false,
  });

  /// 局域网代理是否开启（默认关闭）。
  final bool enabled;

  /// mixed 入站监听端口（默认 2080）。
  final int port;

  /// 用户名密码鉴权是否开启（默认开启）。
  final bool authEnabled;

  /// 鉴权用户名（默认 `zhexuexi`）。
  final String username;

  /// 鉴权密码（首次访问时自动生成并持久化）。
  final String password;

  /// 正在切换开关（防重复点，照路由模式 `switching` 的套路）。
  final bool switching;

  /// 写进配置的鉴权账号：鉴权关着时返回 null（builder 不写
  /// `users`）；鉴权开着时用户名与密码都有值（密码首次访问即
  /// 生成，见 [LanProxyNotifier]）。
  ({String username, String password})? get authCredentials =>
      authEnabled ? (username: username, password: password) : null;

  LanProxyState copyWith({
    bool? enabled,
    int? port,
    bool? authEnabled,
    String? username,
    String? password,
    bool? switching,
  }) {
    return LanProxyState(
      enabled: enabled ?? this.enabled,
      port: port ?? this.port,
      authEnabled: authEnabled ?? this.authEnabled,
      username: username ?? this.username,
      password: password ?? this.password,
      switching: switching ?? this.switching,
    );
  }
}

class LanProxyNotifier extends Notifier<LanProxyState> {
  /// 默认端口（与 [SingboxConfigBuilder.mixedPort] 一致）。
  static const int defaultPort = 2080;

  /// 默认鉴权用户名。
  static const String defaultUsername = 'zhexuexi';

  static const String _enabledKey = 'lan_proxy_enabled';
  static const String _portKey = 'lan_proxy_port';
  static const String _authKey = 'lan_proxy_auth_enabled';
  static const String _usernameKey = 'lan_proxy_username';
  static const String _passwordKey = 'lan_proxy_password';

  @override
  LanProxyState build() {
    Future(() async {
      final prefs = await SharedPreferences.getInstance();
      var password = prefs.getString(_passwordKey) ?? '';
      if (password.isEmpty) {
        password = generatePassword();
        await prefs.setString(_passwordKey, password);
      }
      state = LanProxyState(
        enabled: prefs.getBool(_enabledKey) ?? false,
        port: prefs.getInt(_portKey) ?? defaultPort,
        authEnabled: prefs.getBool(_authKey) ?? true,
        username: prefs.getString(_usernameKey) ?? defaultUsername,
        password: password,
      );
    });
    return const LanProxyState();
  }

  /// 生成 12 位随机密码（去掉了易混淆的 0/O/1/l）。
  static String generatePassword() {
    const chars =
        'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final random = math.Random.secure();
    return List.generate(
      12,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  /// 开关（只记偏好；生效由调用方重建配置，见文件头注释）。
  Future<void> setEnabled(bool value) async {
    state = state.copyWith(enabled: value);
    await _saveBool(_enabledKey, value);
  }

  /// 端口：钳在 1–65535（设置页对话框也校验一遍）。
  Future<void> setPort(int value) async {
    final port = value.clamp(1, 65535);
    state = state.copyWith(port: port);
    await _saveInt(_portKey, port);
  }

  /// 鉴权开关。打开时若密码还是空（首次打开的瞬间点开关的极端
  /// 情况），先生成一个再开，不开无鉴权的口子。
  Future<void> setAuthEnabled(bool value) async {
    if (value && state.password.isEmpty) {
      final password = generatePassword();
      state = state.copyWith(password: password);
      await _saveString(_passwordKey, password);
    }
    state = state.copyWith(authEnabled: value);
    await _saveBool(_authKey, value);
  }

  /// 用户名：空串不收（鉴权开着时用户名不能为空，留旧值）。
  Future<bool> setUsername(String value) async {
    final username = value.trim();
    if (username.isEmpty) return false;
    state = state.copyWith(username: username);
    await _saveString(_usernameKey, username);
    return true;
  }

  /// 密码：空串不收，留旧值。
  Future<bool> setPassword(String value) async {
    if (value.isEmpty) return false;
    state = state.copyWith(password: value);
    await _saveString(_passwordKey, value);
    return true;
  }

  /// 重新生成密码并持久化。
  Future<void> regeneratePassword() async {
    final password = generatePassword();
    state = state.copyWith(password: password);
    await _saveString(_passwordKey, password);
  }

  /// 切换中标志（调用方在重建配置前后置位，防重复点）。
  void setSwitching(bool value) {
    state = state.copyWith(switching: value);
  }

  Future<void> _saveBool(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {
      // 持久化失败不影响本次操作：下次启动回落默认值。
    }
  }

  Future<void> _saveInt(String key, int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, value);
    } catch (_) {}
  }

  Future<void> _saveString(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {}
  }
}

/// 局域网代理设置（全项目共用这一个 provider，设置页、首页格子、
/// 配置生成都读它）。
final lanProxyProvider =
    NotifierProvider<LanProxyNotifier, LanProxyState>(
      LanProxyNotifier.new,
    );
