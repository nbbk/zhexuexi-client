import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 一个已装应用（分应用代理的选择页用）。
class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.label,
    this.iconBytes,
  });

  /// 应用包名（分应用代理存的就是这个，如 `com.tencent.mm`）。
  final String packageName;

  /// 桌面显示名。
  final String label;

  /// 图标 PNG 字节（96x96，原生侧压好再传；没有时 UI 用首字母兜底）。
  final Uint8List? iconBytes;
}

/// 已装应用列表（Android 专属）：经 MainActivity 的 MethodChannel
/// `com.zhexuexi.client/installed_apps` 查 `getLaunchableApps`
///（ACTION_MAIN + CATEGORY_LAUNCHER，Android 11+ 不用
/// QUERY_ALL_PACKAGES）。一次全量加载后缓存，页面内搜索只过滤内存
/// 里的列表，不重复调通道。
class InstalledAppsService {
  static const _channel = MethodChannel(
    'com.zhexuexi.client/installed_apps',
  );

  List<InstalledApp>? _cache;

  /// 列出全部可启动应用（按名称排好序）；已缓存时直接返回缓存。
  Future<List<InstalledApp>> loadApps({bool refresh = false}) async {
    if (_cache != null && !refresh) return _cache!;
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'getLaunchableApps',
    );
    final apps = (raw ?? []).map((entry) {
      final icon = entry['icon'];
      return InstalledApp(
        packageName: entry['packageName'] as String? ?? '',
        label: entry['label'] as String? ?? '',
        iconBytes: icon is Uint8List ? icon : null,
      );
    }).where((app) => app.packageName.isNotEmpty).toList();
    _cache = apps;
    return apps;
  }
}

/// 全项目共用的 [InstalledAppsService]。
final installedAppsServiceProvider = Provider<InstalledAppsService>((_) {
  return InstalledAppsService();
});
