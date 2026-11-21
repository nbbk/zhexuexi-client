import 'package:zhexuexi_client/core/userinfo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SubscriptionUserinfo.parse', () {
    test('完整头部正常解析', () {
      final info = SubscriptionUserinfo.parse(
        'upload=100; download=200; total=1000; expire=1790000000',
      );
      expect(info.upload, 100);
      expect(info.download, 200);
      expect(info.total, 1000);
      expect(info.expire, 1790000000);
      expect(info.used, 300);
      expect(info.remaining, 700);
      expect(info.usedRatio, closeTo(0.3, 0.001));
    });

    test('total 为 0 表示不限量，remaining 与 usedRatio 为 null', () {
      final info = SubscriptionUserinfo.parse(
        'upload=100; download=200; total=0; expire=0',
      );
      expect(info.remaining, isNull);
      expect(info.usedRatio, isNull);
      expect(info.isExpired, isFalse);
      expect(info.expireDate, isNull);
    });

    test('空头部全按 0 兜底，不崩', () {
      final info = SubscriptionUserinfo.parse(null);
      expect(info.used, 0);
      expect(info.total, 0);
      expect(info.isExpired, isFalse);
    });

    test('缺字段与非法值按 0 兜底', () {
      final info = SubscriptionUserinfo.parse('upload=abc; total=1000');
      expect(info.upload, 0);
      expect(info.total, 1000);
      expect(info.usedRatio, 0);
    });

    test('过期判断：过去的时间戳为已过期', () {
      final info = SubscriptionUserinfo.parse(
        'upload=0; download=0; total=1000; expire=1000000000',
      );
      expect(info.isExpired, isTrue);
      expect(info.expireDate, isNotNull);
    });
  });
}
