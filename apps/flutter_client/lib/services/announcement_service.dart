import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_config_notifier.dart';
import 'subscription_service.dart';

/// 公告服务（切片 5：我的页公告列表；切片 7：远程配置公告优先）。
///
/// 公告来源按顺序取：
/// 1. 远程配置里的 `announcement`（带唯一 id；配置换了公告跟着换，
///    用户不用重装）；
/// 2. 面板公开接口 `GET /api/v1/public-info` 的 `login_notice`
///    （见 docs/api/panel-adapter.md §1）：无需认证，只返回登录页
///    公告与签名。
///
/// 请求走订阅地址的 origin（[SubscriptionService.readPanelOrigin]），
/// 令牌绝不拼进公告请求里。拉不到（未绑定 / 网络不通 / 接口不存在，
/// 例如订阅走了只转 /sub/ 的 Worker）时返回上次缓存的公告，
/// 没有缓存返回 null，界面显示“暂无公告”，不报错、不静默丢数据。
class AnnouncementService {
  AnnouncementService({
    Dio? dio,
    SubscriptionService? subscriptionService,
    this._prefs,
    this.remoteAnnouncement,
  })  : _dio = dio ?? Dio(),
        _subscriptionService = subscriptionService ?? SubscriptionService();

  final Dio _dio;
  final SubscriptionService _subscriptionService;
  final SharedPreferences? _prefs;

  /// 远程配置里的公告文本（标题＋正文）；没有远程公告时返回 null，
  /// 由调用方（provider）从 remoteConfigProvider 里读。
  final String? Function()? remoteAnnouncement;

  /// 上次拉到的公告（shared_preferences 缓存）。
  static const String _cacheKey = 'last_announcement_notice';

  Future<SharedPreferences> get _prefsInstance async =>
      _prefs ?? await SharedPreferences.getInstance();

  /// 拉一次公告：远程配置公告优先；没有再取面板 public-info；
  /// 拉不到返回缓存；都没有返回 null。
  Future<String?> fetchNotice() async {
    final cached = await lastCachedNotice();
    // 远程配置公告优先（切片 7）：配置里的公告换了，这里跟着换。
    final remote = remoteAnnouncement?.call()?.trim();
    if (remote != null && remote.isNotEmpty) {
      if (remote != cached) {
        final prefs = await _prefsInstance;
        await prefs.setString(_cacheKey, remote);
      }
      return remote;
    }
    final origin = await _subscriptionService.readPanelOrigin();
    if (origin == null) return cached;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$origin/api/v1/public-info',
        options: Options(
          responseType: ResponseType.json,
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      final notice = (response.data?['login_notice'] as String?)?.trim();
      if (notice == null || notice.isEmpty) return cached;
      final prefs = await _prefsInstance;
      await prefs.setString(_cacheKey, notice);
      return notice;
    } on DioException {
      return cached;
    }
  }

  /// 上次缓存的公告；没有返回 null。
  Future<String?> lastCachedNotice() async {
    final prefs = await _prefsInstance;
    final notice = prefs.getString(_cacheKey);
    if (notice == null || notice.trim().isEmpty) return null;
    return notice;
  }
}

/// 公告服务（可注入 fake 做测试）。
/// 远程公告从 remoteConfigProvider 里读：配置换了公告跟着换。
final announcementServiceProvider = Provider<AnnouncementService>(
  (ref) => AnnouncementService(
    remoteAnnouncement: () =>
        ref.read(remoteConfigProvider).config.announcement?.displayText,
  ),
);
