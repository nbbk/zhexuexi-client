// 订阅管理页 widget 测试：顶部粘贴框的“粘贴”按钮。
//
// 不碰真面板：subscriptionsProvider 与 nodesProvider 都用桩覆盖，
// 添加只记调用、不发请求。
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhexuexi_client/features/nodes/subscriptions_page.dart';
import 'package:zhexuexi_client/services/nodes_notifier.dart';
import 'package:zhexuexi_client/services/subscription_store.dart';
import 'package:zhexuexi_client/services/subscriptions_notifier.dart';

class _StubSubscriptionsNotifier extends SubscriptionsNotifier {
  final calls = <String>[];

  @override
  List<SubscriptionEntry> build() => const [];

  @override
  Future<void> load() async {}

  @override
  Future<String?> add(String url) async {
    calls.add('add:$url');
    return null;
  }
}

class _StubNodesNotifier extends NodesNotifier {
  @override
  NodesState build() => const NodesState();

  @override
  Future<void> refresh() async {}
}

Future<_StubSubscriptionsNotifier> _pumpPage(WidgetTester tester) async {
  final subsStub = _StubSubscriptionsNotifier();
  final nodesStub = _StubNodesNotifier();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subscriptionsProvider.overrideWith(() => subsStub),
        nodesProvider.overrideWith(() => nodesStub),
      ],
      child: const MaterialApp(home: SubscriptionsPage()),
    ),
  );
  await tester.pumpAndSettle();
  return subsStub;
}

/// 伪造剪贴板内容：mock 住平台通道的 Clipboard.getData，
/// 让“粘贴”按钮读到给定文本。真实 Clipboard.setData 在测试环境里
/// 不返回（会一直挂起），所以不直接用它。
void _mockClipboard(String text) {
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': text};
        }
        return null;
      });
}

void _unmockClipboard() {
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}

void main() {
  setUp(() => addTearDown(_unmockClipboard));

  testWidgets('点“粘贴”把剪贴板内容（去首尾空白）填进输入框', (tester) async {
    const link = 'https://airport.example.com/sub/abcdef123456';
    _mockClipboard('  $link  ');
    await _pumpPage(tester);
    expect(find.text('粘贴'), findsOneWidget);
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller?.text, link);
    expect(field.keyboardType, TextInputType.url);
  });

  testWidgets('粘贴后点“添加订阅”提交，去首尾空白后的链接', (tester) async {
    const link = 'https://airport.example.com/sub/abcdef123456';
    _mockClipboard(link);
    final subsStub = await _pumpPage(tester);
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加订阅'));
    await tester.pumpAndSettle();
    expect(subsStub.calls, ['add:$link']);
    expect(find.text('已添加订阅'), findsOneWidget);
  });

  testWidgets('剪贴板是空的：点“粘贴”提示，不动输入框', (tester) async {
    _mockClipboard('   ');
    await _pumpPage(tester);
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();
    expect(find.text('剪贴板是空的，先复制订阅链接再粘贴'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller?.text, '');
  });
}
