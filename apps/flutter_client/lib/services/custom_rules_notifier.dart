import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/custom_rule.dart';

/// 自定义分流规则的状态管理（切片 6：设置页“自定义规则”）。
///
/// 规则存在 shared_preferences（`custom_rules`，JSON 列表），只含
/// 域名后缀与动作，不含订阅、令牌与节点地址。调用方（配置生成与
/// 模式切换）只读 [activeRules]（已启用的规则）；界面管理整张表。
class CustomRulesNotifier extends Notifier<List<CustomRule>> {
  static const String _prefsKey = 'custom_rules';

  var _idCounter = 0;

  @override
  List<CustomRule> build() {
    // 读持久化是异步的：先给空表，再把存过的规则读回来覆盖。
    Future(() async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List) return;
        final rules = <CustomRule>[];
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final rule = CustomRule.fromJson(item);
            if (rule != null) rules.add(rule);
          }
        }
        // 读回时按域名去重（同域名只留第一条），脏数据不进表。
        final seen = <String>{};
        rules.retainWhere((r) => seen.add(r.domain));
        state = rules;
      } catch (_) {
        // 存坏了就当没有规则，不让脏数据炸掉设置页。
      }
    });
    return const [];
  }

  /// 已启用的规则（配置生成只认这些）。
  List<CustomRule> get activeRules =>
      state.where((r) => r.enabled).toList();

  /// 加一条规则；域名不合格或已存在时返回 false（界面据此提示原因）。
  Future<bool> addRule(String domainInput, CustomRuleAction action) async {
    final domain = CustomRule.normalizeDomain(domainInput);
    if (domain == null) return false;
    if (state.any((r) => r.domain == domain)) return false;
    final rule = CustomRule(
      // 微秒时间戳 + 自增序号：两次快速连续添加也不会撞 id
      //（只用毫秒时间戳时，同毫秒内建的两条规则 id 相同，删一条
      // 会把两条都删掉）。
      id: '${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}',
      domain: domain,
      action: action,
    );
    state = [...state, rule];
    await _persist();
    return true;
  }

  /// 删一条规则；不存在时返回 false。
  Future<bool> removeRule(String id) async {
    if (!state.any((r) => r.id == id)) return false;
    state = state.where((r) => r.id != id).toList();
    await _persist();
    return true;
  }

  /// 开关一条规则；不存在时返回 false。
  Future<bool> setEnabled(String id, bool enabled) async {
    if (!state.any((r) => r.id == id)) return false;
    state = state
        .map((r) => r.id == id ? r.copyWith(enabled: enabled) : r)
        .toList();
    await _persist();
    return true;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(state.map((r) => r.toJson()).toList()),
      );
    } catch (_) {
      // 持久化失败不影响本次操作：下次启动读不到就回落空表。
    }
  }
}

/// 自定义规则（全项目共用这一个 provider，设置页管理、配置生成读它）。
final customRulesProvider =
    NotifierProvider<CustomRulesNotifier, List<CustomRule>>(
      CustomRulesNotifier.new,
    );
