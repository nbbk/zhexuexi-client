import 'package:zhexuexi_client/brand/brand_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BrandConfig.fromJson', () {
    test('完整 JSON 正常解析', () {
      final config = BrandConfig.fromJson({
        'brand': {
          'app_name': '测试品牌',
          'primary_color': '#112233',
          'accent_color': '#AABBCC',
          'logo_url': 'https://example.com/logo.png',
          'support_url': 'https://example.com/help',
        },
        'panel': {
          'subscription_url': 'https://example.com/sub',
          'panel_domain': 'panel.example.com',
          'min_panel_version': '1.3.29',
        },
      });
      expect(config.appName, '测试品牌');
      expect(config.primaryColor, 0xFF112233);
      expect(config.accentColor, 0xFFAABBCC);
      expect(config.logoUrl, 'https://example.com/logo.png');
      expect(config.panelDomain, 'panel.example.com');
      expect(config.minPanelVersion, '1.3.29');
    });

    test('缺字段时用默认值兜底，不崩', () {
      final config = BrandConfig.fromJson({});
      expect(config.appName, '哲学系');
      expect(config.primaryColor, 0xFF082E63);
      expect(config.accentColor, 0xFFEEC362);
    });

    test('颜色写错时用默认值兜底，不崩', () {
      final config = BrandConfig.fromJson({
        'brand': {'primary_color': '不是颜色', 'accent_color': '#123'},
      });
      expect(config.primaryColor, 0xFF082E63);
      expect(config.accentColor, 0xFFEEC362);
    });
  });

  group('BrandConfig.defaults', () {
    test('默认值与方案一致', () {
      final config = BrandConfig.defaults();
      expect(config.appName, '哲学系');
      expect(config.minPanelVersion, '1.3.29');
    });
  });
}
