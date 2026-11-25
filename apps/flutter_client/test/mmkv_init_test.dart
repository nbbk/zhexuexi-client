// MMKV 初始化回归测试（小米真机启动失败，2026-11-25）。
//
// 真原生 MMKV 连不上测试宿主（Linux flutter_tester 上没有 libmmkv.so，
// 构造 MMKV 直接报 Null check，与真机行为不同），所以这里不用真 MMKV：
// 用注入的 usingConfigPath 模拟 Dart MMKV 在两种状态下的行为——
// 未初始化时像 MmkvStorage 那样抛 StateError（“forget initialize MMKV
// first?”，见 mmkv-2.4.3 lib/mmkv.dart 第 320 行），初始化后正常返回路径。
// 证明的是修复的接线：main() 先 `MMKV.initialize()` 再 runApp，
// CoreService.init() 不再把这个致命错吞成“没有可用配置”；
// start() 的建档案（_defaultEnsureSelectedProfile）也只在初始化之后跑。
import 'dart:async';
import 'dart:io';

import 'package:flutter_sing_box/flutter_sing_box.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/core/config_validator.dart';
import 'package:zhexuexi_client/core/node_model.dart';
import 'package:zhexuexi_client/core/singbox_core.dart';

/// 插件 fake：只记调用、不碰平台通道，状态由测试手动推。
class _FakePlugin extends FlutterSingBox {
  final _stateController = StreamController<ProxyState>.broadcast();
  int startCalls = 0;

  @override
  Stream<ProxyState> get proxyStateStream => _stateController.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> startVpn() async {
    startCalls++;
    _stateController.add(const ProxyStarted());
  }

  @override
  Future<String> getSingBoxVersion() async => '1.14.4';

  Future<void> close() => _stateController.close();
}

/// 校验器 fake：永远通过。
class _FakeValidator implements ConfigValidator {
  @override
  Future<List<String>> validate(Map<String, dynamic> config) async => [];
}

Node _node(String name) => Node(
  name: name,
  protocol: NodeProtocol.vless,
  address: '203.0.113.1',
  port: 443,
  source: NodeSource.direct,
  uuidOrPassword: '11111111-2222-3333-4444-555555555555',
  tls: true,
  sni: 'example.com',
);

/// 未初始化的 MMKV 在 Dart 侧抛的错（mmkv-2.4.3 lib/mmkv.dart:320）。
StateError _mmkvNotInitialized() =>
    StateError('Invalid state, forget initialize MMKV first?');

void main() {
  late Directory tmpDir;
  late String configPath;
  late _FakePlugin plugin;
  late List<String> ensureProfileCalls;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('mmkv-init-test-');
    configPath = '${tmpDir.path}/using_config.json';
    plugin = _FakePlugin();
    ensureProfileCalls = [];
  });

  tearDown(() async {
    await plugin.close();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  CoreService makeService({required Future<String> Function() path}) =>
      CoreService(
        plugin: plugin,
        validator: _FakeValidator(),
        usingConfigPath: path,
        ensureSelectedProfile: (p) async {
          ensureProfileCalls.add(p);
        },
      );

  test('MMKV 未初始化：init 抛 StateError，不吞成“没有可用配置”', () async {
    final service = makeService(
      path: () async => throw _mmkvNotInitialized(),
    );
    await expectLater(
      service.init(),
      throwsA(
        isStateError.having(
          (e) => e.message,
          'message',
          contains('forget initialize MMKV first?'),
        ),
      ),
    );
    service.dispose();
  });

  test('MMKV 已初始化：init 正常完成，建档案在启动之前', () async {
    final service = makeService(path: () async => configPath);
    await service.init();
    expect(service.currentConfigJson, isNull);

    final applied = await service.applyNodes([_node('甲-直连')]);
    expect(applied.ok, isTrue);

    await service.start();
    expect(ensureProfileCalls, [configPath]);
    expect(plugin.startCalls, 1);
    service.dispose();
  });
}
