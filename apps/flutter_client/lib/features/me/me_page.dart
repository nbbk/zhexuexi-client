import 'package:material_ui/material_ui.dart';

/// “我的”页：账号区 + 订阅卡片 + 公告入口 + 换绑 / 退出登录。
///
/// 阶段 0 占位：账号显示“未登录（免登录模式）”，订阅卡片显示“未绑定”，
/// 刷新按钮点后提示阶段 1 接线。账号密码登录与免登录共存（DEV-PLAN §10）。
class MePage extends StatelessWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: ListTile(
            leading: CircleAvatar(child: Icon(Icons.person)),
            title: Text('未登录（免登录模式）'),
            subtitle: Text('绑定订阅即可使用，无需注册账号'),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('我的订阅', style: TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                const Text('未绑定订阅'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('阶段 0 占位：订阅绑定在阶段 1 接线'),
                          ),
                        );
                      },
                      child: const Text('绑定订阅'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: null,
                      child: const Text('刷新订阅'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Card(
          child: ListTile(
            leading: Icon(Icons.campaign_outlined),
            title: Text('公告'),
            subtitle: Text('暂无公告'),
            trailing: Icon(Icons.chevron_right),
          ),
        ),
        const SizedBox(height: 16),
        const Card(
          child: ListTile(
            leading: Icon(Icons.swap_horiz),
            title: Text('换绑订阅'),
            subtitle: Text('更换订阅链接或账号'),
          ),
        ),
        const SizedBox(height: 16),
        const Card(
          child: ListTile(
            leading: Icon(Icons.logout),
            title: Text('退出登录'),
            subtitle: Text('退出后订阅与本地配置一并清除'),
          ),
        ),
      ],
    );
  }
}
