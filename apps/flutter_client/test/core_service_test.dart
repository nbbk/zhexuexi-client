// 切片 2：CoreService 接线的回归测试。
//
// 插件、校验器、配置路径、建档案四处全部可注入 fake，不碰平台通道、
// 不碰 MMKV、不碰 path_provider；配置写临时目录。
import 'dart:async';
import 'dart:convert';
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
  int stopCalls = 0;
  int reloadCalls = 0;

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
  Future<void> stopVpn() async {
    stopCalls++;
    _stateController.add(const ProxyStopped());
  }

  @override
  Future<void> serviceReload() async {
    reloadCalls++;
    _stateController.add(const ProxyStarted());
  }

  @override
  Future<String> getSingBoxVersion() async => '1.14.4';

  void emit(ProxyState state) => _stateController.add(state);

  Future<void> close() => _stateController.close();
}

/// 校验器 fake：按开关返回通过或固定错误。
class _FakeValidator implements ConfigValidator {
  List<String> errors = const [];

  @override
  Future<List<String>> validate(Map<String, dynamic> config) async => errors;
}

Node _node(String name, {NodeSource source = NodeSource.direct}) => Node(
  name: name,
  protocol: NodeProtocol.vless,
  address: '203.0.113.1',
  port: 443,
  source: source,
  uuidOrPassword: '11111111-2222-3333-4444-555555555555',
  tls: true,
  sni: 'example.com',
);

/// 让广播流的事件送达监听方。
Future<void> _pumpEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late Directory tmpDir;
  late String configPath;
  late _FakePlugin plugin;
  late _FakeValidator validator;
  late List<String> ensureProfileCalls;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('core-service-test-');
    configPath = '${tmpDir.path}/using_config.json';
    plugin = _FakePlugin();
    validator = _FakeValidator();
    ensureProfileCalls = [];
  });

  tearDown(() async {
    await plugin.close();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  CoreService makeService() => CoreService(
    plugin: plugin,
    validator: validator,
    usingConfigPath: () async => configPath,
    ensureSelectedProfile: (path) async {
      ensureProfileCalls.add(path);
    },
  );

  group('applyNodes', () {
    test('停止时应用成功：写盘、不重载、记节点数', () async {
      final service = makeService();
      await service.init();
      final result = await service.applyNodes([_node('甲-直连')]);
      expect(result.ok, isTrue);
      expect(result.nodeCount, 1);
      expect(result.skipped, isEmpty);
      expect(plugin.reloadCalls, 0);

      final file = File(configPath);
      expect(await file.exists(), isTrue);
      final decoded = jsonDecode(await file.readAsString());
      expect(decoded, isA<Map<String, dynamic>>());
      expect((decoded['outbounds'] as List).length, 5);
      expect(service.currentConfigJson, isNotNull);
      expect(service.appliedNodeCount, 1);
      expect(service.lastAppliedAt, isNotNull);
      service.dispose();
    });

    test('校验失败：不写盘、不重载、返回原因', () async {
      validator.errors = ['dns.servers[0] 仍是 legacy address 写法'];
      final service = makeService();
      await service.init();
      final result = await service.applyNodes([_node('甲-直连')]);
      expect(result.ok, isFalse);
      expect(result.errors, ['dns.servers[0] 仍是 legacy address 写法']);
      expect(await File(configPath).exists(), isFalse);
      expect(plugin.reloadCalls, 0);
      expect(service.currentConfigJson, isNull);
      service.dispose();
    });

    test('已运行时应用成功：调一次重载', () async {
      final service = makeService();
      await service.init();
      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      expect(service.status, CoreStatus.started);

      final result = await service.applyNodes([_node('甲-直连')]);
      expect(result.ok, isTrue);
      expect(plugin.reloadCalls, 1);
      service.dispose();
    });

    test('已运行时校验失败：旧文件不动、不重载、状态仍是已启动', () async {
      final service = makeService();
      await service.init();
      final first = await service.applyNodes([_node('甲-直连')]);
      expect(first.ok, isTrue);
      final oldContent = await File(configPath).readAsString();

      plugin.emit(const ProxyStarted());
      await _pumpEvents();
      validator.errors = ['route 缺少 default_domain_resolver'];
      final second = await service.applyNodes([
        _node('甲-直连'),
        _node('乙-直连'),
      ]);
      expect(second.ok, isFalse);
      expect(await File(configPath).readAsString(), oldContent);
      expect(plugin.reloadCalls, 0);
      expect(service.status, CoreStatus.started);
      expect(service.appliedNodeCount, 1);
      service.dispose();
    });
  });

  group('start / stop', () {
    test('没有配置时 start 直接报错，不调插件', () async {
      final service = makeService();
      await service.init();
      await expectLater(service.start(), throwsStateError);
      expect(plugin.startCalls, 0);
      expect(ensureProfileCalls, isEmpty);
      service.dispose();
    });

    test('有配置时 start 先建档案再启动', () async {
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      await service.start();
      expect(ensureProfileCalls, [configPath]);
      expect(plugin.startCalls, 1);
      await _pumpEvents();
      expect(service.status, CoreStatus.started);
      service.dispose();
    });

    test('stop 调插件，状态流回落到已停止', () async {
      final service = makeService();
      await service.init();
      await service.applyNodes([_node('甲-直连')]);
      await service.start();
      await _pumpEvents();
      await service.stop();
      expect(plugin.stopCalls, 1);
      await _pumpEvents();
      expect(service.status, CoreStatus.stopped);
      expect(service.lastError, isNull);
      service.dispose();
    });

    test('init 时把磁盘上最后一份配置读回内存', () async {
      final first = makeService();
      await first.init();
      await first.applyNodes([_node('甲-直连'), _node('乙-中转')]);
      first.dispose();

      // 模拟 App 重启：新实例 init 后不用 applyNodes 也能 start。
      final second = makeService();
      await second.init();
      expect(second.currentConfigJson, isNotNull);
      await second.start();
      expect(plugin.startCalls, 1);
      second.dispose();
    });

    test('异常停止进 error 状态并记原因', () async {
      final service = makeService();
      await service.init();
      plugin.emit(const ProxyStopped(errMessage: '核心崩溃'));
      await _pumpEvents();
      expect(service.status, CoreStatus.error);
      expect(service.lastError, '核心崩溃');
      service.dispose();
    });
  });

  group('updateSelectorDefault（切片 4）', () {
    Future<Map<String, dynamic>> readConfig() async {
      final decoded = jsonDecode(await File(configPath).readAsString());
      return decoded as Map<String, dynamic>;
    }

    String proxyDefault(Map<String, dynamic> config) {
      final outbounds = config['outbounds'] as List;
      final proxy = outbounds.cast<Map<String, dynamic>>().firstWhere(
        (ob) => ob['tag'] == 'Proxy',
      );
      return proxy['default'] as String;
    }

    test('只改 Proxy 的 default，不动其它字段、不重载', () async {
      final service = makeService();
      await service.init();
      final applied = await service.applyNodes([
        _node('甲-直连'),
        _node('乙-中转', source: NodeSource.relay),
      ]);
      expect(applied.ok, isTrue);
      expect(proxyDefault(await readConfig()), '甲-直连');

      expect(await service.updateSelectorDefault('乙-中转'), isTrue);
      final updated = await readConfig();
      expect(proxyDefault(updated), '乙-中转');
      // 其它字段原样：节点出站数、route、dns 都没动。
      expect((updated['outbounds'] as List).length, 6);
      expect(updated['route'], isNotNull);
      expect(updated['dns'], isNotNull);
      // 内存里的配置也跟着变，下次 start 读的就是新默认。
      expect(service.currentConfigJson, contains('"default":"乙-中转"'));
      expect(plugin.reloadCalls, 0);
      service.dispose();
    });

    test('没有配置、没有 Proxy 组、tag 不在成员里时返回 false', () async {
      final service = makeService();
      await service.init();
      // 还没 applyNodes，磁盘上没有配置。
      expect(await service.updateSelectorDefault('甲-直连'), isFalse);

      // 空节点配置里没有 Proxy 组。
      await service.applyNodes([]);
      expect(await service.updateSelectorDefault('甲-直连'), isFalse);

      // tag 不在 Proxy 成员里：不写盘。
      await service.applyNodes([_node('甲-直连')]);
      final before = await File(configPath).readAsString();
      expect(await service.updateSelectorDefault('不存在的节点'), isFalse);
      expect(await File(configPath).readAsString(), before);
      service.dispose();
    });
  });
}
