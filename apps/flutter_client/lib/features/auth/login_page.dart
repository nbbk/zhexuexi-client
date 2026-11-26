import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../widgets/app_icon.dart';
import '../../core/app_tokens.dart';
import '../../widgets/glass_card.dart';

import '../../services/auth_notifier.dart';
import '../../services/remote_config_notifier.dart';
import '../../services/remote_config_service.dart';

/// 账号密码登录页（切片 9，DEV-PLAN §10.2；0.1.3 改域名栏做法）。
///
/// - 远程配置拉到时只留账号、密码两个框：域名栏不渲染、不在屏幕上
///   暴露域名；页面右下角放一个小的“使用其他面板”文字入口，点开后
///   才出现域名输入框（里面预填当前值，可改，自建面板的人用）；
/// - 远程配置拉不到时，域名输入框直接显示出来让用户手填（原来兜底不变）；
/// - 远程配置晚到（打开登录页时还没拉到）时，拉到后把值填进域名框——
///   只要用户还没自己改过域名框；框当时可见且用户没动过，就跟着藏起来；
/// - 面板域名默认填上次填过的，第一次填远程配置的 panelDomain
///   （占位域名时留空，提示“面板地址未配置”），可手动改；
/// - 登录时域名按手填 → 远程配置解析（见 AuthNotifier.resolvePanelDomain），
///   两边都没有时不发请求、提示先拉取配置或手填；
/// - 登录按钮有加载态，登录中防重复点；失败原因常驻显示在页内，
///   不用 SnackBar 一闪而过；
/// - 登录成功回我的页（pop）；密码忘了只给文字提示，客户端不做
///   找回页面（§10.2）。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _domainController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _passwordVisible = false;
  bool _domainLoaded = false;
  // 用户点“使用其他面板”入口后，域名栏才显示出来。
  bool _domainRevealedManually = false;
  // 自动填入过的值（用户清空已填的值后，远程配置晚到也不再重填）。
  String _autoFilledDomain = '';
  // 用户是否亲手改过域名框（程序填入不算）；为真时远程配置晚到也不补填，
  // 框已可见时也不跟着藏起来。
  bool _userEditedDomain = false;
  // 程序正在改框（不计入 _userEditedDomain）。
  bool _settingProgrammatically = false;

  @override
  void initState() {
    super.initState();
    // 域名框内容变了就重建，让“面板地址未配置”的提示实时跟着走。
    _domainController.addListener(_onDomainChanged);
    _loadDefaultDomain();
  }

  void _onDomainChanged() {
    if (!_settingProgrammatically &&
        _domainController.text != _autoFilledDomain) {
      _userEditedDomain = true;
    }
    if (mounted) setState(() {});
  }

  void _fillDomain(String domain) {
    _settingProgrammatically = true;
    _domainController.text = domain;
    _settingProgrammatically = false;
    _autoFilledDomain = domain;
  }

  Future<void> _loadDefaultDomain() async {
    final domain = await ref.read(authProvider.notifier).defaultPanelDomain();
    if (!mounted) return;
    setState(() {
      if (domain.isNotEmpty) _fillDomain(domain);
      _domainLoaded = true;
    });
  }

  @override
  void dispose() {
    _domainController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _onLogin() async {
    final ok = await ref
        .read(authProvider.notifier)
        .login(
          panelDomain: _domainController.text,
          username: _usernameController.text,
          password: _passwordController.text,
        );
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final loading = auth.loading;
    final error = auth.errorMessage;

    // 远程配置里有没有真实的面板域名：有就默认藏起域名栏。
    final remoteDomain = ref.watch(remoteConfigProvider).config.panelDomain;
    final hasRemoteDomain =
        !RemoteConfigService.isPlaceholderDomain(remoteDomain);
    // 远程配置晚到：框还空着、用户也没动过时，把值填进去
    // （框的显隐由下面的 showDomainField 跟着算，不用这里管）。
    ref.listen<RemoteConfigState>(remoteConfigProvider, (prev, next) {
      final domain = next.config.panelDomain;
      if (!mounted || _userEditedDomain) return;
      if (_domainController.text.isNotEmpty || _autoFilledDomain.isNotEmpty) {
        return;
      }
      if (RemoteConfigService.isPlaceholderDomain(domain)) return;
      _fillDomain(domain);
    });
    // 域名栏显隐：用户点过入口、或远程配置没有域名、或用户亲手改过框时显示；
    // 其它情况（远程配置有域名且用户没动过）藏起来。
    final showDomainField =
        _domainRevealedManually || !hasRemoteDomain || _userEditedDomain;

    return Scaffold(
      appBar: AppBar(title: const Text('账号登录')),
      // 夜晚模式（0.1.2）：同款 GlassBackground，顺带修同类黑底问题。
      body: GlassBackground(
        child: ListView(
        padding: const EdgeInsets.all(AppTokens.spacingMd),
        children: [
          const Text(
            '用面板账号登录，登录后自动绑定该账号的订阅；'
            '换设备登上去就回来，不用重新导链接。',
          ),
          const SizedBox(height: AppTokens.spacingMd),
          if (showDomainField) ...[
            TextField(
              controller: _domainController,
              enabled: _domainLoaded,
              decoration: const InputDecoration(
                labelText: '面板域名',
                hintText: '如 panel.example.com',
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.url],
            ),
            if (_domainLoaded && _domainController.text.isEmpty) ...[
              const SizedBox(height: AppTokens.spacingXs),
              Text(
                '面板地址未配置，请填写面板域名',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: AppTokens.spacingXs),
            const Text(
              '登录走 9870–9880 端口，默认 9876，端口被封会自动换端口重试。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: AppTokens.spacingMd),
          ],
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(
              labelText: '账号',
              hintText: '面板登录用户名',
            ),
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
          ),
          const SizedBox(height: AppTokens.spacingMd),
          TextField(
            controller: _passwordController,
            obscureText: !_passwordVisible,
            decoration: InputDecoration(
              labelText: '密码',
              hintText: '面板登录密码',
              suffixIcon: IconButton(
                icon: AppIcon(
                  icon: _passwordVisible ? AppIcons.eyeOff : AppIcons.eye,
                ),
                onPressed: () =>
                    setState(() => _passwordVisible = !_passwordVisible),
              ),
            ),
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _onLogin(),
          ),
          const SizedBox(height: AppTokens.spacingXs),
          const Text('忘记密码？请联系管理员找回，客户端不做找回页面。'),
          if (error != null) ...[
            const SizedBox(height: AppTokens.spacingMd),
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: AppTokens.spacingMd + AppTokens.spacingXs),
          FilledButton(
            onPressed: loading ? null : _onLogin,
            child: loading
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: AppTokens.spacingXs),
                      Text('登录中…'),
                    ],
                  )
                : const Text('登录'),
          ),
          // 域名栏藏起来时，右下角留一个小入口给自建面板的人。
          if (!showDomainField)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () =>
                    setState(() => _domainRevealedManually = true),
                child: const Text('使用其他面板'),
              ),
            ),
        ],
        ),
      ),
    );
  }
}
