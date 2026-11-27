import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/core_provider.dart';
import '../core/routing_mode.dart';
import 'custom_rules_notifier.dart';
import 'lan_proxy_notifier.dart';
import 'nodes_notifier.dart';
import 'settings_notifier.dart';

/// 模式状态：当前模式＋是否正在切换＋最近一次切换失败的原因。
class RoutingModeState {
  const RoutingModeState({
    this.mode = RoutingMode.rule,
    this.switching = false,
    this.errorMessage,
  });

  final RoutingMode mode;
  final bool switching;
  final String? errorMessage;

  RoutingModeState copyWith({
    RoutingMode? mode,
    bool? switching,
    String? errorMessage,
  }) {
    return RoutingModeState(
      mode: mode ?? this.mode,
      switching: switching ?? this.switching,
      errorMessage: errorMessage,
    );
  }
}

/// 分流模式的状态管理（切片 3：首页三段式切换）。
///
/// 切换流程：用新模式重新生成配置 → 校验 → 写盘 →（已运行时）重载核心。
/// 只有成功才提交新模式并持久化；校验失败或重载抛错时保持旧模式，
/// 并把磁盘配置用旧模式重写一份回滚（新配置已写盘、核心未重载的
/// 中间态不能留），返回 false，界面据此提示“切换失败，已保持原模式”。
/// 模式持久化在 shared_preferences（只存 `rule` / `global` / `direct`
/// 短串，不含订阅与令牌）；读失败时回落默认规则模式。
class RoutingModeNotifier extends Notifier<RoutingModeState> {
  static const String _prefsKey = 'proxy_mode';

  @override
  RoutingModeState build() {
    // 读持久化是异步的：先给默认规则模式，再把存过的值读回来覆盖。
    Future(() async {
      final prefs = await SharedPreferences.getInstance();
      final saved = RoutingMode.fromStorage(prefs.getString(_prefsKey));
      if (saved != state.mode) {
        state = state.copyWith(mode: saved);
      }
    });
    return const RoutingModeState();
  }

  /// 切换到 [next]；成功返回 true，失败保持旧模式并返回 false。
  Future<bool> setMode(RoutingMode next) async {
    final prev = state.mode;
    if (next == prev) return true;
    if (state.switching) return false;
    state = state.copyWith(switching: true, errorMessage: null);
    final nodes = ref.read(nodesProvider).nodes;
    final selected = ref.read(nodesProvider).selectedNodeName;
    final core = ref.read(coreServiceProvider);
    // 自定义规则与 TUN 开关跟着模式一起进配置：模式切换不能把
    // 设置页配好的规则与 TUN 丢掉；回滚那次同样要带。
    final customRules = ref.read(customRulesProvider.notifier).activeRules;
    final tunEnabled = ref.read(settingsProvider).tun;
    // 局域网代理同样要带上（不带就回落默认值，等于悄悄关了它）。
    final lan = ref.read(lanProxyProvider);
    final lanCreds = lan.authCredentials;
    try {
      final result = await core.applyNodes(
        nodes,
        mode: next,
        // 带着当前选中的节点生成配置：模式切换不能把节点页选过的节点
        // 换回默认规则；回滚那次同样要带。
        selectedNodeName: selected,
        customRules: customRules,
        tunEnabled: tunEnabled,
        lanProxy: lan.enabled,
        lanProxyPort: lan.port,
        lanProxyUsername: lanCreds?.username,
        lanProxyPassword: lanCreds?.password,
      );
      if (!result.ok) {
        // 校验失败要把真实原因写进 errorMessage（2026-11-26：以前
        // 只剩固定句，首页弹的也是固定句，用户不知道为什么切不了）：
        // 取第一条错误（通常就是根因那句），太长时截断；空错误列表
        // 时回落固定文案。界面直接显示这条 errorMessage。
        final reason = result.errors.isNotEmpty ? result.errors.first : '';
        state = state.copyWith(
          switching: false,
          errorMessage: reason.isEmpty
              ? '配置校验失败，已保持原模式'
              : '配置校验失败：${_shortReason(reason)}，已保持原模式',
        );
        return false;
      }
    } catch (_) {
      // 重载抛错：磁盘已是新模式配置，立即用旧模式重写一份回滚；
      // 回滚本身失败也不再抛，状态仍是旧模式，界面提示失败。
      try {
        await core.applyNodes(
          nodes,
          mode: prev,
          selectedNodeName: selected,
          customRules: customRules,
          tunEnabled: tunEnabled,
          lanProxy: lan.enabled,
          lanProxyPort: lan.port,
          lanProxyUsername: lanCreds?.username,
          lanProxyPassword: lanCreds?.password,
        );
      } catch (_) {}
      state = state.copyWith(
        switching: false,
        errorMessage: '切换失败，已保持原模式',
      );
      return false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, next.storageValue);
    } catch (_) {
      // 持久化失败不影响本次切换：下次启动回落规则模式。
    }
    state = RoutingModeState(mode: next);
    return true;
  }
}

/// 分流模式（全项目共用这一个 provider，首页切换、核心配置生成都读它）。
final routingModeProvider =
    NotifierProvider<RoutingModeNotifier, RoutingModeState>(
      RoutingModeNotifier.new,
    );

/// 校验原因截断（与首页 `_shortReason` 同一条规则：只留前 120 字，
/// 根因字段名/路径都在前头，截不掉）。
String _shortReason(String reason) {
  const maxLength = 120;
  if (reason.length <= maxLength) return reason;
  return '${reason.substring(0, maxLength)}…';
}
