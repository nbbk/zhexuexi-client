import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'brand/brand_config.dart';
import 'features/home/home_page.dart';
import 'features/me/me_page.dart';
import 'features/nodes/nodes_page.dart';
import 'features/settings/settings_page.dart';
import 'services/remote_config_service.dart';

/// 哲学系客户端入口（阶段 0：只搭架子 + 最小验证，未接真实面板/节点）。
///
/// 四个 tab：首页（大开关）/ 节点 / 我的 / 设置。
/// 品牌变量来自远程配置，拉不到用包内 brand.json，再拉不到用代码默认值。
void main() {
  runApp(const ProviderScope(child: ZhexuexiApp()));
}

class ZhexuexiApp extends StatefulWidget {
  const ZhexuexiApp({super.key});

  @override
  State<ZhexuexiApp> createState() => _ZhexuexiAppState();
}

class _ZhexuexiAppState extends State<ZhexuexiApp> {
  late final Future<BrandConfig> _brandFuture =
      RemoteConfigService().loadEffective();

  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<BrandConfig>(
      future: _brandFuture,
      builder: (context, snapshot) {
        final brand = snapshot.data ?? BrandConfig.defaults();
        final primary = Color(brand.primaryColor);
        final accent = Color(brand.accentColor);
        return MaterialApp(
          title: brand.appName,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: primary,
              primary: primary,
              secondary: accent,
            ),
            useMaterial3: true,
          ),
          home: Scaffold(
            appBar: AppBar(title: Text(brand.appName)),
            body: IndexedStack(
              index: _tabIndex,
              children: [
                HomePage(onGoToMe: () => setState(() => _tabIndex = 2)),
                const NodesPage(),
                const MePage(),
                const SettingsPage(),
              ],
            ),
            bottomNavigationBar: BottomNavigationBar(
              currentIndex: _tabIndex,
              onTap: (index) => setState(() => _tabIndex = index),
              type: BottomNavigationBarType.fixed,
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.home), label: '首页'),
                BottomNavigationBarItem(
                  icon: Icon(Icons.public),
                  label: '节点',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person),
                  label: '我的',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.settings),
                  label: '设置',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
