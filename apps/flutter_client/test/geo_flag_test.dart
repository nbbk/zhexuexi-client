// 旗标（第 11 项）：按节点地址离线判断国家/地区。
//
// 不碰网络与 GeoIP 数据库：中转域名写死一张小表，
// 其余域名按国家顶级域认，IP 地址不猜国家。
import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/core/geo_flag.dart';

void main() {
  group('flagForAddress', () {
    test('中转域名 cp.jiankong.cf → 中国香港', () {
      final flag = flagForAddress('cp.jiankong.cf');
      expect(flag.isKnown, isTrue);
      expect(flag.code, 'HK');
      expect(flag.emoji, '🇭🇰');
      expect(flag.label, '中国香港');
    });

    test('域名大小写不敏感', () {
      expect(flagForAddress('CP.JIANKONG.CF').code, 'HK');
      expect(flagForAddress('Node.Example.JP').code, 'JP');
    });

    test('国家顶级域：.jp 日本、.us 美国、.hk 中国香港', () {
      expect(flagForAddress('node.example.jp').code, 'JP');
      expect(flagForAddress('node.example.jp').emoji, '🇯🇵');
      expect(flagForAddress('node.example.us').code, 'US');
      expect(flagForAddress('node.example.hk').code, 'HK');
      expect(flagForAddress('node.example.sg').label, '新加坡');
    });

    test('IP 地址不猜国家：v4 与 v6 都是未知', () {
      expect(flagForAddress('203.0.113.1').isKnown, isFalse);
      expect(flagForAddress('2001:db8::1').isKnown, isFalse);
    });

    test('未知：通用顶级域、无顶级域、空串', () {
      expect(flagForAddress('node.example.com').isKnown, isFalse);
      expect(flagForAddress('localhost').isKnown, isFalse);
      expect(flagForAddress('').isKnown, isFalse);
      expect(flagForAddress('example.xyz').isKnown, isFalse);
    });

    test('未知旗标的 emoji 与 code 为空（界面放 globe 图标）', () {
      final flag = flagForAddress('203.0.113.1');
      expect(flag, CountryFlag.unknown);
      expect(flag.code, isEmpty);
      expect(flag.emoji, isEmpty);
    });
  });
}
