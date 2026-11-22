// 切片 5：公告服务测试（面板 public-info 的 login_notice）。
//
// 不碰真面板：Dio 用拦截器伪造响应；订阅地址 origin 用假服务给定；
// 缓存用 SharedPreferences mock。
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/services/announcement_service.dart';
import 'package:zhexuexi_client/services/subscription_service.dart';

class _FakeSubscriptionService extends SubscriptionService {
  _FakeSubscriptionService(this._origin);

  final String? _origin;

  @override
  Future<String?> readPanelOrigin() async => _origin;
}

/// 按 URL 返回固定 JSON 或抛错的假 Dio。
Dio _fakeDio({
  Map<String, dynamic>? body,
  int status = 200,
  bool throwNetworkError = false,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (throwNetworkError) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            ),
          );
          return;
        }
        final response = Response<Map<String, dynamic>>(
          requestOptions: options,
          statusCode: status,
          data: body,
        );
        if (status >= 200 && status < 300) {
          handler.resolve(response);
        } else {
          handler.reject(
            DioException(
              requestOptions: options,
              response: response,
              type: DioExceptionType.badResponse,
            ),
          );
        }
      },
    ),
  );
  return dio;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('200 有公告：返回公告并缓存', () async {
    final service = AnnouncementService(
      dio: _fakeDio(
        body: {'login_notice': '面板今晚维护', 'login_signature': '客服'},
      ),
      subscriptionService: _FakeSubscriptionService('https://example.com'),
    );
    expect(await service.fetchNotice(), '面板今晚维护');
    // 缓存进了 prefs：新服务实例不联网也能读到。
    final again = AnnouncementService(
      dio: _fakeDio(throwNetworkError: true),
      subscriptionService: _FakeSubscriptionService('https://example.com'),
    );
    expect(await again.fetchNotice(), '面板今晚维护');
  });

  test('404：返回 null，不缓存', () async {
    final service = AnnouncementService(
      dio: _fakeDio(status: 404, body: {'error': 'not found'}),
      subscriptionService: _FakeSubscriptionService('https://example.com'),
    );
    expect(await service.fetchNotice(), isNull);
    expect(await service.lastCachedNotice(), isNull);
  });

  test('公告为空串：按没有公告处理', () async {
    final service = AnnouncementService(
      dio: _fakeDio(body: {'login_notice': '   ', 'login_signature': ''}),
      subscriptionService: _FakeSubscriptionService('https://example.com'),
    );
    expect(await service.fetchNotice(), isNull);
  });

  test('网络不通：返回上次缓存的公告', () async {
    SharedPreferences.setMockInitialValues({
      'last_announcement_notice': '上次的公告',
    });
    final service = AnnouncementService(
      dio: _fakeDio(throwNetworkError: true),
      subscriptionService: _FakeSubscriptionService('https://example.com'),
    );
    expect(await service.fetchNotice(), '上次的公告');
  });

  test('未绑定订阅：没有 origin，返回缓存；没有缓存返回 null', () async {
    final service = AnnouncementService(
      dio: _fakeDio(body: {'login_notice': '不该被用到'}),
      subscriptionService: _FakeSubscriptionService(null),
    );
    expect(await service.fetchNotice(), isNull);
  });

  test('请求地址是 origin + /api/v1/public-info，不带令牌', () async {
    String? requested;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requested = options.uri.toString();
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {'login_notice': '公告'},
            ),
          );
        },
      ),
    );
    final service = AnnouncementService(
      dio: dio,
      subscriptionService:
          _FakeSubscriptionService('https://example.com:11111'),
    );
    await service.fetchNotice();
    expect(requested, 'https://example.com:11111/api/v1/public-info');
    expect(requested, isNot(contains('sub_')));
  });
}
