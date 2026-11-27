import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sing_box/flutter_sing_box.dart';

/// 分应用代理状态（Android 专属）。
///
/// 语义（只做一种：白名单，市面客户端的常规做法）：
/// - 关闭：全部应用走代理（mode 0 DISABLED，原生默认）；
/// - 开启：仅选中应用走代理（mode 1 INCLUDE），其余直连。
/// 黑名单（mode 2 EXCLUDE）原生与存储层都有，但本版 UI 不开放，
/// 不要两种都做一半。
/// 存取走 [CsSettingsStorage]（MMKV `cs_settings` 实例，与原生
/// VPNService.openTun 读的是同一份）：TUN 建起来时就生效，改选择后
/// 须重启核心（或等下次启动）才生效，页面里有“重启核心”操作。
class PerAppProxyState {
  const PerAppProxyState({required this.enabled, required this.selected});

  /// 是否仅选中应用走代理。
  final bool enabled;

  /// 选中的应用包名（如 `com.tencent.mm`）。
  final Set<String> selected;

  PerAppProxyState copyWith({bool? enabled, Set<String>? selected}) {
    return PerAppProxyState(
      enabled: enabled ?? this.enabled,
      selected: selected ?? this.selected,
    );
  }
}

class PerAppProxyNotifier extends Notifier<PerAppProxyState> {
  @override
  PerAppProxyState build() {
    final storage = CsSettingsStorage.instance;
    final mode = storage.getPerAppProxyMode();
    // 只认白名单模式；其他模式（关闭/黑名单）在本 UI 里都算关闭，
    // 已存的白名单列表照常读回，重开时恢复。
    final selected = storage.getAppList(1).toSet();
    return PerAppProxyState(enabled: mode == 1, selected: selected);
  }

  /// 开关：开时必须已选至少一个应用（白名单空表时原生等于全走代理，
  /// 开了也白开）；关时只改模式，白名单留着，下次重开恢复。
  /// 返回是否成功打开。
  bool setEnabled(bool value) {
    if (value && state.selected.isEmpty) return false;
    _persist(enabled: value);
    return true;
  }

  /// 勾选/取消一个应用，立即持久化。
  void togglePackage(String packageName) {
    final next = Set<String>.of(state.selected);
    if (next.contains(packageName)) {
      next.remove(packageName);
    } else {
      next.add(packageName);
    }
    _persist(selected: next);
  }

  void _persist({bool? enabled, Set<String>? selected}) {
    final next = state.copyWith(enabled: enabled, selected: selected);
    state = next;
    final storage = CsSettingsStorage.instance;
    // 列表永远写白名单那把 key：setAppList(list, 0) 不写列表
    //（只改模式），开关关着时勾选会丢；模式另外单写。
    storage.setAppList(next.selected.toList(), 1);
    storage.setPerAppProxyMode(next.enabled ? 1 : 0);
  }
}

/// 当前分应用代理状态（设置页摘要与选择页共用这一个 provider）。
final perAppProxyProvider =
    NotifierProvider<PerAppProxyNotifier, PerAppProxyState>(
  PerAppProxyNotifier.new,
);
