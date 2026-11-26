import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_config_notifier.dart';
import 'subscription_service.dart';

/// 一条公告（面板 1.4.29 契约，见
/// `~/workspace/goals/goal-6/announcement-contract.md`）：
/// 字段是 `{id, title, body, pinned, created_at, updated_at}`，
/// 注意是 `body` 不是 `content`（fromJson 里 `body ?? content` 容错）。
class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    this.pinned = false,
    this.createdAt,
    this.updatedAt,
  });

  factory Announcement.fromJson(Map<String, dynamic> json) {
    DateTime? parseTime(Object? value) {
      if (value is! String || value.isEmpty) return null;
      return DateTime.tryParse(value);
    }

    return Announcement(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      body: (json['body'] as String?) ?? (json['content'] as String?) ?? '',
      pinned: json['pinned'] as bool? ?? false,
      createdAt: parseTime(json['created_at']),
      updatedAt: parseTime(json['updated_at']),
    );
  }

  final String id;
  final String title;
  final String body;

  /// 是否置顶。
  final bool pinned;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 跑马灯只滚这一行：标题为空取正文首行，否则取标题。
  String get displayLine {
    if (title.isNotEmpty) return title;
    final first = body.split('\n').first.trim();
    return first.isEmpty ? body.trim() : first;
  }

  /// 全文（标题＋正文；标题为空时只显示正文）。
  /// 与远程配置 `RemoteConfigAnnouncement.displayText` 同口径。
  String get displayText => title.isEmpty ? body : '$title\n$body';

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'pinned': pinned,
    if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
    if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
  };

  /// 列表页排序：置顶在前（多条置顶按创建时间倒序），其余按
  /// `created_at` 倒序（新的在前）；没有时间的排最后。
  static List<Announcement> sortForDisplay(List<Announcement> list) {
    final sorted = List<Announcement>.of(list);
    int timeCompare(Announcement a, Announcement b) {
      final at = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    }

    sorted.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return timeCompare(a, b);
    });
    return sorted;
  }
}

/// 公告服务（切片 5：我的页公告列表；切片 7：远程配置公告优先；
/// 0.1.2：多条公告＋跑马灯＋隐藏规则）。
///
/// 公告来源按顺序取（契约优先级）：
/// 1. 远程配置里的 `announcement`（带唯一 id；配置换了公告跟着换，
///    用户不用重装）；
/// 2. 面板公开接口 `GET /api/v1/public-info` 的 `announcements`
///    字段（同一份列表）；
/// 3. 面板公开接口 `GET /api/v1/announcements`（直连面板时；
///    经旧版 Worker 可能 404，404 就往下走）；
/// 4. `public-info` 的 `login_notice`（字符串，折成单条）。
///
/// 三者都没有返回 `[]`，不返回 null。服务端明确返回 `[]` 时清
/// 缓存返回 `[]`；拉取失败返回缓存，无缓存返回 `[]`。
///
/// 请求走订阅地址的 origin（[SubscriptionService.readPanelOrigin]），
/// 令牌绝不拼进公告请求里。
class AnnouncementService {
  AnnouncementService({
    Dio? dio,
    SubscriptionService? subscriptionService,
    this._prefs,
    this.remoteAnnouncement,
    this.remoteAnnouncementObject,
  })  : _dio = dio ?? Dio(),
        _subscriptionService = subscriptionService ?? SubscriptionService();

  final Dio _dio;
  final SubscriptionService _subscriptionService;
  final SharedPreferences? _prefs;

  /// 远程配置里的公告文本（标题＋正文）；没有远程公告时返回 null，
  /// 由调用方（provider）从 remoteConfigProvider 里读。
  final String? Function()? remoteAnnouncement;

  /// 远程配置里的公告对象（带 id；没有时返回 null）。
  /// 有它时优先用它，[remoteAnnouncement] 只作后备。
  final Announcement? Function()? remoteAnnouncementObject;

  /// 上次拉到的公告（shared_preferences 缓存，单条文本，旧版口径）。
  static const String _cacheKey = 'last_announcement_notice';

  /// 上次拉到的公告列表（shared_preferences 缓存，JSON 列表，0.1.2）。
  static const String _listCacheKey = 'announcements_list_cache';

  static const Duration _fetchTimeout = Duration(seconds: 10);

  Future<SharedPreferences> get _prefsInstance async =>
      _prefs ?? await SharedPreferences.getInstance();

  Options get _jsonOptions => Options(
    responseType: ResponseType.json,
    sendTimeout: _fetchTimeout,
    receiveTimeout: _fetchTimeout,
  );

  /// 拉一次公告列表（见类文档的优先级）。绝不返回 null。
  Future<List<Announcement>> fetchAnnouncements() async {
    // 1. 远程配置单条公告优先。
    final remoteObject = remoteAnnouncementObject?.call();
    if (remoteObject != null) {
      final list = [remoteObject];
      await _saveListCache(list);
      return list;
    }
    final remote = remoteAnnouncement?.call()?.trim();
    if (remote != null && remote.isNotEmpty) {
      final list = [
        Announcement(id: 'remote-config', title: '', body: remote),
      ];
      await _saveListCache(list);
      return list;
    }
    final origin = await _subscriptionService.readPanelOrigin();
    if (origin == null) return _cachedList();
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$origin/api/v1/public-info',
        options: _jsonOptions,
      );
      final data = response.data;
      if (data == null) return await _cachedList();
      // 2. public-info.announcements（同一份列表；明确的 [] 也是
      // 有效回答，清缓存返回 []）。
      if (data.containsKey('announcements')) {
        final list = _parseList(data['announcements']);
        await _saveListCache(list);
        return list;
      }
      // 3. GET /api/v1/announcements（直连面板时；404 就往下走）。
      try {
        final annResponse = await _dio.get<dynamic>(
          '$origin/api/v1/announcements',
          options: _jsonOptions,
        );
        if (annResponse.data is List) {
          final list = _parseList(annResponse.data);
          await _saveListCache(list);
          return list;
        }
      } on DioException {
        // 旧版 Worker 404 / 网络问题：往 login_notice 回落。
      }
      // 4. login_notice 折单条。
      final notice = (data['login_notice'] as String?)?.trim();
      if (notice != null && notice.isNotEmpty) {
        final list = [
          Announcement(id: 'login-notice', title: '', body: notice),
        ];
        await _saveListCache(list);
        return list;
      }
      // 面板明确回包了，但哪路公告都没有：权威的空，清缓存返回 []。
      await _saveListCache(const []);
      return const [];
    } on DioException {
      return _cachedList();
    }
  }

  /// 拉一次公告：首条的全文（薄壳过渡，旧调用方用）。
  /// 没有公告返回 null。
  Future<String?> fetchNotice() async {
    final list = await fetchAnnouncements();
    if (list.isEmpty) return null;
    return list.first.displayText;
  }

  /// 上次缓存的公告；没有返回 null。
  Future<String?> lastCachedNotice() async {
    final prefs = await _prefsInstance;
    final notice = prefs.getString(_cacheKey);
    if (notice == null || notice.trim().isEmpty) return null;
    return notice;
  }

  /// 上次缓存的公告列表；没有返回 []（不返回 null）。
  Future<List<Announcement>> lastCachedList() => _cachedList();

  List<Announcement> _parseList(Object? raw) {
    if (raw is! List) return const [];
    final list = <Announcement>[];
    for (final entry in raw) {
      if (entry is Map<String, dynamic>) {
        list.add(Announcement.fromJson(entry));
      } else if (entry is Map) {
        list.add(
          Announcement.fromJson(Map<String, dynamic>.from(entry)),
        );
      }
    }
    return Announcement.sortForDisplay(list);
  }

  Future<List<Announcement>> _cachedList() async {
    final prefs = await _prefsInstance;
    final raw = prefs.getString(_listCacheKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return _parseList(decoded);
      } catch (_) {
        // 缓存坏了当作没有，往下走旧版单条缓存。
      }
    }
    // 旧版单条缓存兜底（0.1.2 之前只存一条文本）。
    final legacy = prefs.getString(_cacheKey);
    if (legacy != null && legacy.trim().isNotEmpty) {
      return [
        Announcement(id: 'legacy-cache', title: '', body: legacy.trim()),
      ];
    }
    return const [];
  }

  Future<void> _saveListCache(List<Announcement> list) async {
    final prefs = await _prefsInstance;
    if (list.isEmpty) {
      // 服务端明确返回 []：清缓存。
      await prefs.remove(_listCacheKey);
      await prefs.remove(_cacheKey);
      return;
    }
    await prefs.setString(
      _listCacheKey,
      jsonEncode(list.map((a) => a.toJson()).toList()),
    );
    // 单条缓存同步写首条全文（旧版 fetchNotice / lastCachedNotice
    // 的调用方与测试仍认它）。
    await prefs.setString(_cacheKey, list.first.displayText);
  }
}

/// 公告服务（可注入 fake 做测试）。
/// 远程公告从 remoteConfigProvider 里读：配置换了公告跟着换。
final announcementServiceProvider = Provider<AnnouncementService>(
  (ref) => AnnouncementService(
    remoteAnnouncement: () =>
        ref.read(remoteConfigProvider).config.announcement?.displayText,
    remoteAnnouncementObject: () {
      final a = ref.read(remoteConfigProvider).config.announcement;
      if (a == null) return null;
      return Announcement(id: a.id, title: a.title, body: a.body);
    },
  ),
);

/// 首页与“我的”页共用的公告列表：首次被 watch 即拉取；
/// 空列表 / 加载中 / 失败无缓存时调用方按“没有就隐藏”处理。
final announcementsProvider = FutureProvider<List<Announcement>>((ref) {
  final service = ref.watch(announcementServiceProvider);
  return service.fetchAnnouncements();
});
