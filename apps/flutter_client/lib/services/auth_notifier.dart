import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';
import 'nodes_notifier.dart';
import 'remote_config_notifier.dart';
import 'remote_config_service.dart';
import 'subscription_store.dart';

/// 账号登录服务（可注入 fake 做测试）。
final authServiceProvider = Provider<AuthService>((ref) => AuthService());

/// 账号登录状态。
class AuthState {
  const AuthState({this.username, this.loading = false, this.errorMessage});

  /// 已登录的账号名；null 表示免登录模式。
  final String? username;

  /// 是否正在登录。
  final bool loading;

  /// 最近一次登录失败的原因（给用户看的，常驻显示在登录页）。
  final String? errorMessage;

  bool get loggedIn => username != null;

  AuthState copyWith({
    Object? username = _unset,
    bool? loading,
    Object? errorMessage = _unset,
  }) {
    return AuthState(
      username: username == _unset ? this.username : username as String?,
      loading: loading ?? this.loading,
      errorMessage: errorMessage == _unset
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  static const _unset = Object();
}

/// 账号登录的状态管理（切片 9，DEV-PLAN §10.2）。
///
/// - 登录成功后用面板返回的订阅链接走现有绑定流程（令牌不变、只换身份）；
///   该订阅已经绑过（主订阅或手动加的多订阅里已有同一条）时跳过绑定，
///   不重复拉取、不在订阅列表里多一条重复项；
/// - 绑定失败时回滚本次登录：删会话令牌、恢复登录前的订阅绑定，
///   不留半登录态；
/// - 退出登录只清会话令牌（DEV-PLAN §10.2）：订阅与节点不受影响，
///   免登录时“退出登录”仍是清绑定（我的页按登录态分两路调）。
class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthState();

  /// 启动 / 我的页打开时恢复会话：令牌与账号名都在才算登录态；
  /// 读不到或读失败都当未登录，不抛错、不阻断界面。
  Future<void> restore() async {
    try {
      final session = await ref.read(authServiceProvider).restoreSession();
      if (session != null) {
        state = state.copyWith(username: session.username);
      }
    } catch (_) {
      // 安全存储读失败（如测试环境没配通道）就当未登录。
    }
  }

  /// 登录页域名框的默认值：上次填过的域名优先，其次是远程配置的
  /// panelDomain（占位域名时不填，页面提示“面板地址未配置”）。
  Future<String> defaultPanelDomain() async {
    final service = ref.read(authServiceProvider);
    final last = await service.readLastPanelDomain();
    if (last != null && last.isNotEmpty) return last;
    final domain = ref.read(remoteConfigProvider).config.panelDomain;
    if (RemoteConfigService.isPlaceholderDomain(domain)) return '';
    return domain;
  }

  /// 登录用面板域名的解析顺序（0.1.3）：手填的值优先；没填时用远程配置的
  /// panelDomain；两边都没有（远程是占位域名也算没有）时返回 ''，调用方
  /// 提示手填、不发请求。
  static String resolvePanelDomain({
    required String typed,
    required String remoteDomain,
  }) {
    final t = AuthService.normalizePanelDomain(typed);
    if (t.isNotEmpty) return t;
    final r = AuthService.normalizePanelDomain(remoteDomain);
    if (r.isEmpty || RemoteConfigService.isPlaceholderDomain(r)) return '';
    return r;
  }

  /// 登录：调 AuthService 拿会话令牌，成功后绑定该账号的订阅。
  /// 返回 true 时登录页可以关掉；false 时原因在 [AuthState.errorMessage]。
  Future<bool> login({
    required String panelDomain,
    required String username,
    required String password,
  }) async {
    if (state.loading) return false;
    state = state.copyWith(loading: true, errorMessage: null);
    // 域名按手填 → 远程配置解析；两边都没有就不发请求，直接提示手填。
    final resolvedDomain = resolvePanelDomain(
      typed: panelDomain,
      remoteDomain: ref.read(remoteConfigProvider).config.panelDomain,
    );
    if (resolvedDomain.isEmpty) {
      state = state.copyWith(
        loading: false,
        errorMessage: '请先拉取远程配置或填写面板域名',
      );
      return false;
    }
    final service = ref.read(authServiceProvider);
    // 先记下登录前的订阅绑定：绑定新订阅失败时要恢复它。
    final subscriptionService = ref.read(subscriptionServiceProvider);
    final oldSubscriptionUrl =
        await subscriptionService.readSubscriptionUrl();
    AuthLoginResult result;
    try {
      result = await service.login(
        panelDomain: resolvedDomain,
        username: username,
        password: password,
      );
    } on AuthException catch (e) {
      state = state.copyWith(loading: false, errorMessage: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(loading: false, errorMessage: '登录失败，请稍后再试');
      return false;
    }
    await service.saveLastPanelDomain(resolvedDomain);
    // 账号下没有订阅：登录成功，不绑定，用户可再手动绑链接。
    final subscriptionUrl = result.subscriptionUrl;
    if (subscriptionUrl == null || subscriptionUrl.isEmpty) {
      state = AuthState(username: result.username);
      return true;
    }
    // 该订阅已经绑过：节点已经在列表里，不用再拉一次，订阅列表里
    // 也不再多一条重复项。跳过绑定时登录仍算成功；旧订阅就是当前
    // 订阅，不用回滚。
    if (await _isAlreadyBound(subscriptionUrl)) {
      state = AuthState(username: result.username);
      return true;
    }
    // 绑定该账号的订阅；失败回滚本次登录，不留半登录态。
    await ref.read(nodesProvider.notifier).bindAndRefresh(subscriptionUrl);
    final nodesState = ref.read(nodesProvider);
    if (nodesState.status == NodesStatus.error) {
      await _rollbackLogin(oldSubscriptionUrl);
      state = state.copyWith(
        loading: false,
        errorMessage: _bindErrorMessage(nodesState.errorMessage),
      );
      return false;
    }
    state = AuthState(username: result.username);
    return true;
  }

  /// 登录回包里的订阅是否已经绑过：主订阅是同一条，或手动加的多订阅
  /// 里已有同一条。读现有绑定失败时按“没绑过”算（走正常绑定），
  /// 不让一次去重查询拦住登录。
  Future<bool> _isAlreadyBound(String subscriptionUrl) async {
    final normalized = _normalizeSubscriptionUrl(subscriptionUrl);
    if (normalized.isEmpty) return false;
    try {
      final service = ref.read(subscriptionServiceProvider);
      final primaryUrl = await service.readSubscriptionUrl();
      if (primaryUrl != null &&
          _normalizeSubscriptionUrl(primaryUrl) == normalized) {
        return true;
      }
      final custom = await ref.read(subscriptionStoreProvider).listCustom();
      return custom.any(
        (e) => _normalizeSubscriptionUrl(e.url) == normalized,
      );
    } catch (_) {
      return false;
    }
  }

  /// 订阅链接归一化（去重比对用）：去首尾空白＋去末尾斜杠。
  /// 口径跟 SubscriptionService 现有的 base 处理一致
  /// （updateBaseUrl / baseOf 都去掉末尾斜杠）；http 与 https
  /// 不算同一条、host 大小写不折叠——现有代码保存订阅地址时
  /// 也不换 scheme、不改大小写。
  static String _normalizeSubscriptionUrl(String url) =>
      url.trim().replaceAll(RegExp(r'/+$'), '');

  /// 绑定新订阅失败时的错误文案：订阅本身已失效 / 已退场时按 §10.2
  /// 提示“请重新导入或重新登录”，其它失败原样报绑定原因。
  /// 注意：这里按新版映射文案匹配（订阅服务 2026-11-26 改映射后，
  /// 404 报“令牌不对”、410 报“已退场”；旧文案已不再出现）。
  String _bindErrorMessage(String? nodesError) {
    if (nodesError != null &&
        (nodesError.contains('令牌不对') || nodesError.contains('已退场'))) {
      return '订阅已失效，请重新导入或重新登录';
    }
    if (nodesError == null || nodesError.isEmpty) {
      return '登录成功，但拉取订阅失败，已恢复之前的登录状态';
    }
    return '登录成功，但订阅绑定失败：$nodesError，已恢复之前的登录状态';
  }

  /// 回滚本次登录：删会话令牌、恢复登录前的订阅绑定。
  Future<void> _rollbackLogin(String? oldSubscriptionUrl) async {
    await ref.read(authServiceProvider).logout();
    final subscriptionService = ref.read(subscriptionServiceProvider);
    if (oldSubscriptionUrl == null) {
      await subscriptionService.clearBinding();
      await ref.read(nodesProvider.notifier).clear();
    } else {
      try {
        await subscriptionService.saveSubscriptionLink(oldSubscriptionUrl);
      } catch (_) {
        // 旧链接本身已坏：清绑定，不留半截的旧地址。
        await subscriptionService.clearBinding();
      }
      await ref.read(nodesProvider.notifier).refresh();
    }
  }

  /// 退出登录（已登录时）：只清会话令牌与账号名，订阅与节点不动。
  Future<void> logout() async {
    await ref.read(authServiceProvider).logout();
    state = const AuthState();
  }
}

/// 账号登录（全项目共用这一个 provider，我的页与登录页都读它）。
final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
