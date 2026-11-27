import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_provider.dart';
import '../core/singbox_core.dart';
import 'custom_rules_notifier.dart';
import 'lan_proxy_notifier.dart';
import 'nodes_notifier.dart';
import 'routing_mode_notifier.dart';
import 'settings_notifier.dart';

/// 用当前全部设置重建配置并写盘（核心在跑时重载，短暂断开 1-2 秒，
/// 与 TUN 切换、模式切换同一行为）。
///
/// 调用点：局域网代理的开关/端口/鉴权改动（设置页与首页格子共用）。
/// 模式切换与切节点不走这里——它们要传自己的 mode/节点，仍直接调
/// [CoreService.applyNodes]，但也要把局域网代理的四个值带上
/// （不带就回落默认值，等于悄悄关了局域网代理）。
///
/// 有节点时才写配置；没节点时只记偏好、返回 true（下次生成配置时
/// 生效，与 TUN 开关同一口径）。校验失败或重载抛错返回 false，
/// 调用方回滚偏好。
Future<bool> rebuildConfigWithCurrentSettings(WidgetRef ref) async {
  final nodesState = ref.read(nodesProvider);
  if (nodesState.nodes.isEmpty) return true;
  final lan = ref.read(lanProxyProvider);
  final creds = lan.authCredentials;
  ref.read(lanProxyProvider.notifier).setSwitching(true);
  try {
    final result = await ref.read(coreServiceProvider).applyNodes(
      nodesState.nodes,
      mode: ref.read(routingModeProvider).mode,
      selectedNodeName: nodesState.selectedNodeName,
      customRules: ref.read(customRulesProvider.notifier).activeRules,
      tunEnabled: ref.read(settingsProvider).tun,
      lanProxy: lan.enabled,
      lanProxyPort: lan.port,
      lanProxyUsername: creds?.username,
      lanProxyPassword: creds?.password,
    );
    return result.ok;
  } catch (_) {
    return false;
  } finally {
    ref.read(lanProxyProvider.notifier).setSwitching(false);
  }
}
