/// 分流模式（三档，见 DEV-PLAN.md §4.3 1-9 与客户端方案 §7）。
///
/// - [rule] 规则模式（默认）：TikTok / 社交 / 流媒体 / 测 IP 走代理，
///   `.cn` 直连，其余直连；
/// - [global] 全局模式：全部流量走代理；
/// - [direct] 直连模式：全部流量直连，不走任何节点。
///
/// 模式只改 sing-box 配置的 route 段（规则与 final）与 DNS 规则的解析
/// 路径（见 [SingboxConfigBuilder.build]），不改节点出站本身；切换后
/// 重新生成配置并重载核心（见 `RoutingModeNotifier.setMode`），校验失败
/// 时回滚到旧模式。
enum RoutingMode {
  rule,
  global,
  direct;

  /// 界面上的三段式标签。
  String get label => switch (this) {
    rule => '规则模式',
    global => '全局模式',
    direct => '直连模式',
  };

  /// 持久化用的值（shared_preferences 里只存这个短串）。
  String get storageValue => name;

  /// 从持久化值恢复；未知或空值回落默认规则模式。
  static RoutingMode fromStorage(String? value) => switch (value) {
    'global' => global,
    'direct' => direct,
    _ => rule,
  };
}
