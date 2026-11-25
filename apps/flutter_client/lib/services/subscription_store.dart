import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条订阅（多订阅：主订阅＋用户手动加的订阅共用这个模型）。
///
/// - 主订阅（自家面板）：id 固定为 [SubscriptionEntry.primaryId]，
///   地址与令牌仍走 [SubscriptionService] 原来的存储（地址进
///   shared_preferences、令牌进系统密钥库），不动；
/// - 手动加的订阅（XBoard 等机场订阅）：整条以 JSON 存进
///   flutter_secure_storage（链接里含令牌，按项目约定“令牌只存
///   系统密钥库、不写明文文件、不进日志”）。
class SubscriptionEntry {
  const SubscriptionEntry({
    required this.id,
    required this.name,
    required this.url,
    required this.enabled,
    required this.isPrimary,
  });

  /// 主订阅的固定 id。
  static const String primaryId = 'primary';

  /// 主订阅的默认显示名。
  static const String primaryDefaultName = '自家面板';

  /// 唯一 id：主订阅是 [primaryId]，手动加的是 `custom_<毫秒时间戳>`。
  final String id;

  /// 显示名：手动加的默认取域名/ host，用户可改；主订阅默认“自家面板”。
  final String name;

  /// 完整订阅地址（手动加的原样存、原样拿去拉，不拆令牌）。
  final String url;

  /// 是否启用：停用的订阅不拉、节点不显示。
  final bool enabled;

  /// 是否主订阅（自家面板）。
  final bool isPrimary;

  /// 地址的 host（管理页显示用；解析不出时回落完整地址）。
  String get host {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.host;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
      };

  factory SubscriptionEntry.fromJson(Map<String, dynamic> json) {
    return SubscriptionEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      isPrimary: false,
    );
  }
}

/// 多订阅的存储（主订阅＋手动加的订阅）。
///
/// 迁移：老用户原先存的单个订阅就是主订阅，不用搬数据（它本来就
/// 在 [SubscriptionService] 的现有存储里）；列表 = [主订阅（从现有
/// 存储读）] + [手动加的订阅]。没有主订阅时列表只有手动加的。
class SubscriptionStore {
  SubscriptionStore({
    FlutterSecureStorage? storage,
    SharedPreferences? prefs,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _prefsOverride = prefs;

  final FlutterSecureStorage _storage;
  final SharedPreferences? _prefsOverride;

  /// 手动加的订阅整条 JSON（安全存储）。
  static const String customSubscriptionsKey = 'custom_subscriptions';

  /// 主订阅改名（shared_preferences；只存名字，不含令牌）。
  static const String _primaryNameKey = 'primary_subscription_name';

  /// 主订阅启用开关（shared_preferences；默认启用）。
  static const String _primaryEnabledKey = 'primary_subscription_enabled';

  Future<SharedPreferences> get _prefsInstance async =>
      _prefsOverride ?? await SharedPreferences.getInstance();

  /// 全部订阅：主订阅在前（有绑定才有），手动加的按列表顺序在后。
  /// [primaryUrl] 是主订阅的完整地址（由 [SubscriptionService]
  /// 读出；未绑定传 null）。
  Future<List<SubscriptionEntry>> listSubscriptions({
    String? primaryUrl,
  }) async {
    final entries = <SubscriptionEntry>[];
    if (primaryUrl != null && primaryUrl.isNotEmpty) {
      final prefs = await _prefsInstance;
      entries.add(
        SubscriptionEntry(
          id: SubscriptionEntry.primaryId,
          name:
              prefs.getString(_primaryNameKey) ??
              SubscriptionEntry.primaryDefaultName,
          url: primaryUrl,
          enabled: prefs.getBool(_primaryEnabledKey) ?? true,
          isPrimary: true,
        ),
      );
    }
    entries.addAll(await listCustom());
    return entries;
  }

  /// 手动加的订阅列表（按添加顺序）。
  Future<List<SubscriptionEntry>> listCustom() async {
    final raw = await _storage.read(key: customSubscriptionsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final entries = <SubscriptionEntry>[];
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        final entry = SubscriptionEntry.fromJson(item);
        if (entry.id.isEmpty || entry.url.isEmpty) continue;
        entries.add(entry);
      }
      return entries;
    } catch (_) {
      // 存坏了按空列表算，不让一条坏数据拖垮整个订阅列表。
      return [];
    }
  }

  Future<void> _saveCustom(List<SubscriptionEntry> entries) async {
    await _storage.write(
      key: customSubscriptionsKey,
      value: jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  /// 手动加一条订阅：校验合法 http(s) URL；不要求令牌以 `sub_` 开头
  ///（XBoard 等机场的令牌格式不一样，整条链接原样存）。
  /// 同一条链接加过就不再加（多订阅列表里不出现重复条目）。
  /// 成功返回新条目；不合法返回错误文案（给用户看的）。
  Future<({SubscriptionEntry? entry, String? error})> addCustom(
    String url,
  ) async {
    final trimmed = url.trim();
    final error = validateCustomUrl(trimmed);
    if (error != null) return (entry: null, error: error);
    final entries = await listCustom();
    if (entries.any((e) => e.url == trimmed)) {
      return (entry: null, error: '这个订阅已经加过了');
    }
    var id = 'custom_${DateTime.now().millisecondsSinceEpoch}';
    while (entries.any((e) => e.id == id)) {
      id = '${id}_1';
    }
    final entry = SubscriptionEntry(
      id: id,
      name: defaultNameFor(trimmed),
      url: trimmed,
      enabled: true,
      isPrimary: false,
    );
    entries.add(entry);
    await _saveCustom(entries);
    return (entry: entry, error: null);
  }

  /// 改名（主订阅与手动加的都支持；空名字不接受）。
  /// 返回 false 表示 id 不存在或名字为空。
  Future<bool> rename(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    if (id == SubscriptionEntry.primaryId) {
      final prefs = await _prefsInstance;
      await prefs.setString(_primaryNameKey, trimmed);
      return true;
    }
    final entries = await listCustom();
    final index = entries.indexWhere((e) => e.id == id);
    if (index < 0) return false;
    entries[index] = SubscriptionEntry(
      id: entries[index].id,
      name: trimmed,
      url: entries[index].url,
      enabled: entries[index].enabled,
      isPrimary: false,
    );
    await _saveCustom(entries);
    return true;
  }

  /// 启用 / 停用（主订阅与手动加的都支持）。
  /// 返回 false 表示 id 不存在（主订阅一定存在，恒为 true）。
  Future<bool> setEnabled(String id, bool enabled) async {
    if (id == SubscriptionEntry.primaryId) {
      final prefs = await _prefsInstance;
      await prefs.setBool(_primaryEnabledKey, enabled);
      return true;
    }
    final entries = await listCustom();
    final index = entries.indexWhere((e) => e.id == id);
    if (index < 0) return false;
    entries[index] = SubscriptionEntry(
      id: entries[index].id,
      name: entries[index].name,
      url: entries[index].url,
      enabled: enabled,
      isPrimary: false,
    );
    await _saveCustom(entries);
    return true;
  }

  /// 删除一条手动加的订阅；主订阅不给删（返回 false），解绑走
  /// 现有的“退出登录 / 换绑”清除绑定流程。
  Future<bool> removeCustom(String id) async {
    if (id == SubscriptionEntry.primaryId) return false;
    final entries = await listCustom();
    final kept = entries.where((e) => e.id != id).toList();
    if (kept.length == entries.length) return false;
    await _saveCustom(kept);
    return true;
  }

  /// 手动加的订阅链接校验：必须是合法 http(s) URL。
  /// 合法返回 null，不合法返回给用户看的原因。
  static String? validateCustomUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return '订阅链接不对，要以 http:// 或 https:// 开头';
    }
    return null;
  }

  /// 手动加的订阅默认名：取域名 / host。
  static String defaultNameFor(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return url.trim();
    return uri.host;
  }
}

/// 订阅存储（可注入 fake 做测试）。
final subscriptionStoreProvider = Provider<SubscriptionStore>(
  (ref) => SubscriptionStore(),
);
