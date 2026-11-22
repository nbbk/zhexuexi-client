import 'package:zhexuexi_client/core/userinfo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SubscriptionUserinfo.parse', () {
    test('完整头部正常解析', () {
      final info = SubscriptionUserinfo.parse(
        'upload=100; download=200; total=1000; expire=1890000000',
      )!;
      expect(info.upload, 100);
      expect(info.download, 200);
      expect(info.total, 1000);
      expect(info.expire, 1890000000);
      expect(info.used, 300);
      expect(info.remaining, 700);
      expect(info.usedRatio, closeTo(0.3, 0.001));
    });

    test('total 为 0 表示不限量，remaining 与 usedRatio 为 null', () {
      final info = SubscriptionUserinfo.parse(
        'upload=100; download=200; total=0; expire=0',
      )!;
      expect(info.remaining, isNull);
      expect(info.usedRatio, isNull);
      expect(info.isUnlimited, isTrue);
      expect(info.isExpired, isFalse);
      expect(info.expireDate, isNull);
    });

    test('没有头返回 null：没有头 ≠ 用量为 0，界面显示“—”', () {
      expect(SubscriptionUserinfo.parse(null), isNull);
      expect(SubscriptionUserinfo.parse(''), isNull);
      expect(SubscriptionUserinfo.parse('   '), isNull);
    });

    test('缺字段按该字段缺失处理，不按 0 兜底', () {
      // 管理面板模式：头里只有 expire，没有 upload / download。
      final info = SubscriptionUserinfo.parse('expire=1890000000')!;
      expect(info.upload, isNull);
      expect(info.download, isNull);
      expect(info.used, isNull);
      expect(info.remaining, isNull);
      expect(info.usedRatio, isNull);
      expect(info.total, isNull);
      expect(info.isUnlimited, isTrue);
      expect(info.expire, 1890000000);
      expect(info.isExpired, isFalse);
    });

    test('非法值按该字段缺失处理', () {
      final info = SubscriptionUserinfo.parse('upload=abc; total=1000')!;
      expect(info.upload, isNull);
      expect(info.total, 1000);
      // 已用未知时占比为 null，不是 0。
      expect(info.used, isNull);
      expect(info.usedRatio, isNull);
    });

    test('过期判断：过去的时间戳为已过期', () {
      final info = SubscriptionUserinfo.parse(
        'upload=0; download=0; total=1000; expire=1000000000',
      )!;
      expect(info.isExpired, isTrue);
      expect(info.expireDate, isNotNull);
    });
  });

  group('formatBytes / formatSpeed / formatDateYmd', () {
    test('字节格式化：B / KB / MB / GB 进位', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1048576), '1 MB');
      expect(formatBytes(1073741824), '1 GB');
      expect(formatBytes(107374182400), '100 GB');
    });

    test('速率格式化带 /s 后缀', () {
      expect(formatSpeed(0), '0 B/s');
      expect(formatSpeed(1536), '1.5 KB/s');
    });

    test('日期格式化 yyyy-MM-dd', () {
      expect(formatDateYmd(DateTime(2027, 2, 17)), '2027-02-17');
      expect(formatDateYmd(DateTime(2026, 11, 5)), '2026-11-05');
    });

    test('日期时间格式化 yyyy-MM-dd HH:mm', () {
      expect(
        formatDateTime(DateTime(2026, 11, 23, 8, 30)),
        '2026-11-23 08:30',
      );
      expect(
        formatDateTime(DateTime(2026, 11, 5, 9, 5)),
        '2026-11-05 09:05',
      );
    });
  });

  group('三格共享文案（首页与我的页同一套口径）', () {
    SubscriptionUserinfo info({
      int? upload,
      int? download,
      int? total,
      int? expire,
    }) =>
        SubscriptionUserinfo(
          upload: upload,
          download: download,
          total: total,
          expire: expire,
        );

    test('已用/总量：不限量只写已用 + “不限量”', () {
      expect(
        usedTotalText(info(upload: 100, download: 200, total: 0)),
        '300 B / 不限量',
      );
      expect(
        usedTotalText(
          info(upload: 100, download: 200, total: 1024),
        ),
        '300 B / 1 KB',
      );
    });

    test('剩余：超量写“已超量”，用完写“已用完”', () {
      expect(
        remainingText(info(upload: 600, download: 500, total: 1000)),
        '已超量',
      );
      expect(
        remainingText(info(upload: 600, download: 400, total: 1000)),
        '已用完',
      );
      expect(
        remainingText(info(upload: 100, download: 200, total: 0)),
        '不限量',
      );
    });

    test('到期：永不过期与已到期', () {
      expect(expireText(info(expire: 0)), '永不过期');
      expect(expireText(info(expire: 1000000000)), '已到期');
      expect(expireText(null), '—');
      expect(expireText(info()), '—');
    });

    test('没有头或已用未知：三格都是“—”', () {
      expect(usedTotalText(null), '—');
      expect(remainingText(null), '—');
      expect(expireText(null), '—');
      expect(usedTotalText(info(total: 1000)), '—');
      expect(remainingText(info(total: 1000)), '—');
    });
  });
}
