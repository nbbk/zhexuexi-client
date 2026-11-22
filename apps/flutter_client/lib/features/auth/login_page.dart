import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/auth_notifier.dart';

/// 账号密码登录页（切片 9，DEV-PLAN §10.2）。
///
/// - 三个输入框：面板域名、账号、密码（密码可切换可见）；
/// - 面板域名默认填上次填过的，第一次填远程配置的 panelDomain
///   （占位域名时留空，提示“面板地址未配置”），可手动改；
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

  @override
  void initState() {
    super.initState();
    // 域名框内容变了就重建，让“面板地址未配置”的提示实时跟着走。
    _domainController.addListener(_onDomainChanged);
    _loadDefaultDomain();
  }

  void _onDomainChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDefaultDomain() async {
    final domain =
        await ref.read(authProvider.notifier).defaultPanelDomain();
    if (!mounted) return;
    setState(() {
      if (domain.isNotEmpty) _domainController.text = domain;
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
    final ok = await ref.read(authProvider.notifier).login(
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

    return Scaffold(
      appBar: AppBar(title: const Text('账号登录')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '用面板账号登录，登录后自动绑定该账号的订阅；'
            '换设备登上去就回来，不用重新导链接。',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _domainController,
            enabled: _domainLoaded,
            decoration: const InputDecoration(
              labelText: '面板域名',
              hintText: '如 ccpanel.jiankong.cf',
            ),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.url],
          ),
          if (_domainLoaded && _domainController.text.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '面板地址未配置，请填写面板域名',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            '登录走 9870–9880 端口，默认 9876，端口被封会自动换端口重试。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(
              labelText: '账号',
              hintText: '面板登录用户名',
            ),
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            obscureText: !_passwordVisible,
            decoration: InputDecoration(
              labelText: '密码',
              hintText: '面板登录密码',
              suffixIcon: IconButton(
                icon: Icon(
                  _passwordVisible
                      ? Icons.visibility_off
                      : Icons.visibility,
                ),
                onPressed: () => setState(
                  () => _passwordVisible = !_passwordVisible,
                ),
              ),
            ),
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _onLogin(),
          ),
          const SizedBox(height: 8),
          const Text('忘记密码？请联系管理员找回，客户端不做找回页面。'),
          if (error != null) ...[
            const SizedBox(height: 16),
            Text(
              error,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 24),
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
                      SizedBox(width: 8),
                      Text('登录中…'),
                    ],
                  )
                : const Text('登录'),
          ),
        ],
      ),
    );
  }
}
