import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subscription_service.dart';

/// 公告服务（切片 5：我的页公告列表）。
///
/// 公告的唯一来源是面板公开接口 `GET /api/v1/public-info`
/// （见 docs/api/panel-adapter.md §1）：无需认证，只返回
/// `login_notice`（登录页公告，纯文本，最多 500 字）与
/// `login_signature`。流量、到期、分组一概没有，不能当自查接口用。
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
  })  : _dio = dio ?? Dio(),
        _subscriptionService = subscriptionService ?? SubscriptionService();

  final Dio _dio;
  final SubscriptionService _subscriptionService;
  final SharedPreferences? _prefs;

  /// 上次拉到的公告（shared_preferences 缓存）。
  static const String _cacheKey = 'last_announcement_notice';

  Future<SharedPreferences> get _prefsInstance async =>
      _prefs ?? await SharedPreferences.getInstance();

  /// 拉一次公告：有网就取最新的并缓存；拉不到返回缓存；都没有返回 null。
  Future<String?> fetchNotice() async {
    final cached = await lastCachedNotice();
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
final announcementServiceProvider = Provider<AnnouncementService>(
  (ref) => AnnouncementService(),
);
