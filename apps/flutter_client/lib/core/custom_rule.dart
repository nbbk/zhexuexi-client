/// 自定义分流规则（切片 6：设置页“自定义规则”管理）。
///
/// 一条规则 = 一个域名后缀 + 一个动作（走代理 / 直连），插在内置
/// 规则前面（sing-box route 按顺序先命中先走，用户规则优先于内置
/// 规则）。域名只存后缀（`example.com` 匹配自身与全部子域名），
/// 不存 IP、端口、协议与路径；`enabled` 为 false 的规则保留在列表
/// 里但不进配置。
enum CustomRuleAction {
  proxy,
  direct;

  /// 界面上的动作标签。
  String get label => switch (this) {
    proxy => '走代理',
    direct => '直连',
  };

  /// 持久化用的值（shared_preferences 里只存这个短串）。
  String get storageValue => name;

  static CustomRuleAction fromStorage(String? value) =>
      value == 'direct' ? direct : proxy;
}

class CustomRule {
  const CustomRule({
    required this.id,
    required this.domain,
    required this.action,
    this.enabled = true,
  });

  /// 唯一标识（新建时用时间戳毫秒生成，持久化后原样读回）。
  final String id;

  /// 已规整过的域名后缀（小写、无前导 `*.` / `.`、无端口与路径）。
  final String domain;

  final CustomRuleAction action;

  /// 关闭的规则保留在列表里但不进配置。
  final bool enabled;

  /// 规整用户输入的域名后缀；不合格返回 null（调用方据此提示原因，
  /// 不把脏数据写进规则表）。
  ///
  /// 接受 `example.com`、`*.example.com`、`.example.com`、大小写混写；
  /// 拒绝空串、带空格、`://`（带了协议）、`/`（带了路径）、`:`（带了
  /// 端口）、`*`（通配整个域名没有意义）、首尾是 `-` 或 `.` 的。
  static String? normalizeDomain(String input) {
    var domain = input.trim().toLowerCase();
    if (domain.isEmpty) return null;
    // 前导 `*.` 是“含全部子域名”的写法，剥掉再校验；其余位置的
    // `*`（如 `foo.*.com`）没有意义，直接拒绝。
    if (domain.startsWith('*.')) domain = domain.substring(2);
    if (domain.contains('://') ||
        domain.contains('/') ||
        domain.contains(':') ||
        domain.contains(' ') ||
        domain.contains('*')) {
      return null;
    }
    while (domain.startsWith('.')) {
      domain = domain.substring(1);
    }
    if (domain.isEmpty) return null;
    if (domain.startsWith('-') || domain.endsWith('-')) return null;
    if (domain.startsWith('.') || domain.endsWith('.')) return null;
    // 至少要有一个点（`com` 这种顶级域当规则没有意义）、每段非空、
    // 每段只含字母数字与连字符。
    final labels = domain.split('.');
    if (labels.length < 2) return null;
    for (final label in labels) {
      if (label.isEmpty) return null;
      if (!RegExp(r'^[a-z0-9-]+$').hasMatch(label)) return null;
      if (label.startsWith('-') || label.endsWith('-')) return null;
    }
    return domain;
  }

  CustomRule copyWith({
    String? id,
    String? domain,
    CustomRuleAction? action,
    bool? enabled,
  }) {
    return CustomRule(
      id: id ?? this.id,
      domain: domain ?? this.domain,
      action: action ?? this.action,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'domain': domain,
    'action': action.storageValue,
    'enabled': enabled,
  };

  static CustomRule? fromJson(Map<String, dynamic> json) {
    final domain = json['domain'];
    final id = json['id'];
    if (domain is! String || id is! String) return null;
    final normalized = normalizeDomain(domain);
    if (normalized == null) return null;
    return CustomRule(
      id: id,
      domain: normalized,
      action: CustomRuleAction.fromStorage(json['action'] as String?),
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}
