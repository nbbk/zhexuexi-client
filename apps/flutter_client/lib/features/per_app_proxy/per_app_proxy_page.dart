import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/app_tokens.dart';
import '../../core/core_provider.dart';
import '../../core/singbox_core.dart';
import '../../services/installed_apps_service.dart';
import '../../services/per_app_proxy_notifier.dart';
import '../../widgets/app_icon.dart';

/// 分应用代理选择页（Android 专属）。
///
/// 只有一种语义（白名单）：开 = 仅选中应用走代理，其余直连；
/// 关 = 全部应用走代理。黑名单模式原生有，但本版 UI 不开放。
/// 选择立即持久化（MMKV，与原生 TUN 读的是同一份），但 TUN 是
/// 建起来时才读这份配置，所以改完若核心在跑，须重启核心才生效：
/// 页面底部有“重启核心”操作，不静默不生效；核心没跑时下次启动生效。
class PerAppProxyPage extends ConsumerStatefulWidget {
  const PerAppProxyPage({super.key});

  @override
  ConsumerState<PerAppProxyPage> createState() => _PerAppProxyPageState();
}

class _PerAppProxyPageState extends ConsumerState<PerAppProxyPage> {
  late final Future<List<InstalledApp>> _appsFuture;
  String _query = '';
  bool _dirty = false;
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
    _appsFuture = ref.read(installedAppsServiceProvider).loadApps();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  /// 开关：开时必须已选至少一个应用，否则只提示、不开。
  void _onEnabledChanged(bool value) {
    if (value) {
      final ok = ref.read(perAppProxyProvider.notifier).setEnabled(true);
      if (!ok) {
        _showSnack('先选至少一个应用，再开启分应用代理');
        return;
      }
    } else {
      ref.read(perAppProxyProvider.notifier).setEnabled(false);
    }
    _markDirty();
  }

  /// 重启核心让改动生效（停再起；配置已在盘上，start 不会报没配置）。
  Future<void> _restartCore() async {
    setState(() => _restarting = true);
    final core = ref.read(coreServiceProvider);
    try {
      await core.stop();
      await core.start();
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _restarting = false;
      });
      _showSnack('核心已重启，分应用代理已生效');
    } catch (e) {
      if (!mounted) return;
      setState(() => _restarting = false);
      _showSnack('重启核心失败：$e');
    }
  }

  List<InstalledApp> _filtered(List<InstalledApp> apps) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return apps;
    return apps
        .where(
          (app) =>
              app.label.toLowerCase().contains(q) ||
              app.packageName.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final proxy = ref.watch(perAppProxyProvider);
    final coreRunning =
        ref.read(coreServiceProvider).status == CoreStatus.started;
    return Scaffold(
      appBar: AppBar(title: const Text('分应用代理')),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text('仅选中应用走代理'),
            subtitle: const Text('开启后只有选中的应用走代理，其他应用直连；关闭则全部走代理'),
            value: proxy.enabled,
            onChanged: _onEnabledChanged,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spacingMd,
            ),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: AppIcon(icon: AppIcons.search),
                hintText: '搜索应用名或包名',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          const SizedBox(height: AppTokens.spacingSm),
          Expanded(
            child: FutureBuilder<List<InstalledApp>>(
              future: _appsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('应用列表加载失败'),
                        const SizedBox(height: AppTokens.spacingSm),
                        FilledButton(
                          onPressed: () => setState(() {
                            _appsFuture = ref
                                .read(installedAppsServiceProvider)
                                .loadApps(refresh: true);
                          }),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  );
                }
                final apps = _filtered(snapshot.data ?? const []);
                if (apps.isEmpty) {
                  return const Center(child: Text('没有找到匹配的应用'));
                }
                return ListView.builder(
                  itemCount: apps.length,
                  itemBuilder: (context, index) {
                    final app = apps[index];
                    final checked = proxy.selected.contains(app.packageName);
                    return CheckboxListTile(
                      value: checked,
                      onChanged: (_) {
                        ref
                            .read(perAppProxyProvider.notifier)
                            .togglePackage(app.packageName);
                        _markDirty();
                      },
                      secondary: _appIcon(app),
                      title: Text(app.label),
                      subtitle: Text(app.packageName),
                    );
                  },
                );
              },
            ),
          ),
          if (_dirty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spacingMd,
                vertical: AppTokens.spacingSm,
              ),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      coreRunning ? '改动在重启核心后生效' : '下次启动核心时生效',
                    ),
                  ),
                  if (coreRunning)
                    FilledButton(
                      onPressed: _restarting ? null : _restartCore,
                      child: _restarting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('立即重启'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 应用图标（有图标字节就显示，没有用名称首字母兜底）。
  Widget _appIcon(InstalledApp app) {
    if (app.iconBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(app.iconBytes!, width: 40, height: 40),
      );
    }
    return CircleAvatar(
      child: Text(app.label.isEmpty ? '?' : app.label.characters.first),
    );
  }
}
