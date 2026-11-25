import 'package:material_ui/material_ui.dart';

import '../core/app_tokens.dart';
import '../features/home/home_page.dart';
import '../features/me/me_page.dart';
import '../features/nodes/nodes_page.dart';
import '../features/settings/settings_page.dart';
import 'app_icon.dart';

/// 多端导航壳：四个 tab（首页 / 节点 / 我的 / 设置），只导航容器分端，
/// 页面内容同一套组件。
///
/// - 窄屏（宽度 < [AppTokens.navBreakpoint]，手机）：底部导航栏；
/// - 宽屏（宽度 ≥ 断点，桌面窗口 / 平板）：左侧导航栏
///  （[NavigationRail]，顶上放品牌 Logo）。
///
/// 用宽度断点、不用平台分支：桌面窗口拉窄了也能用底部栏，
/// 测试里改视口宽度就能覆盖两档。
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.appName});

  /// 品牌名（AppBar 标题用）。
  final String appName;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tabIndex = 0;

  /// 四个 tab 的导航项（底部栏与左侧栏共用同一份定义，
  /// 图标与文案不各写一份）。
  static const List<({IconData icon, String label})> _tabs = [
    (icon: AppIcons.home, label: '首页'),
    (icon: AppIcons.globe, label: '节点'),
    (icon: AppIcons.user, label: '我的'),
    (icon: AppIcons.settings, label: '设置'),
  ];

  void _setTab(int index) => setState(() => _tabIndex = index);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= AppTokens.navBreakpoint;
    final pages = <Widget>[
      HomePage(onGoToMe: () => _setTab(2)),
      const NodesPage(),
      const MePage(),
      const SettingsPage(),
    ];
    final body = IndexedStack(index: _tabIndex, children: pages);
    if (wide) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.appName)),
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _tabIndex,
              onDestinationSelected: _setTab,
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: AppTokens.spacingSm,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
                  child: Image.asset(
                    'assets/logo/logo.png',
                    width: 40,
                    height: 40,
                  ),
                ),
              ),
              destinations: [
                for (final tab in _tabs)
                  NavigationRailDestination(
                    icon: AppIcon(icon: tab.icon),
                    selectedIcon: AppIcon(icon: tab.icon),
                    label: Text(tab.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.appName)),
      body: body,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: _setTab,
        type: BottomNavigationBarType.fixed,
        items: [
          for (final tab in _tabs)
            BottomNavigationBarItem(
              icon: AppIcon(icon: tab.icon),
              label: tab.label,
            ),
        ],
      ),
    );
  }
}
