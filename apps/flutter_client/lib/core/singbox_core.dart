import 'dart:async';
import 'dart:io';

import 'package:flutter_sing_box/flutter_sing_box.dart';

import 'config_validator.dart';
import 'node_model.dart';
import 'routing_mode.dart';
import 'singbox_config.dart';

/// 核心状态（界面只认这个枚举，不直接认插件的 [ProxyState]）。
enum CoreStatus { stopped, starting, started, stopping, error }

/// 应用一次配置的结果。
class ConfigApplyResult {
  const ConfigApplyResult({
    required this.ok,
    this.errors = const [],
    this.skipped = const [],
    this.nodeCount = 0,
  });

  /// 是否成功写入并（已运行时）重载。
  final bool ok;

  /// 校验失败时的原因（诊断与日志用，不直接展示给用户）。
  final List<String> errors;

  /// 生成时跳过的节点（`名字：原因`），界面可提示。
  final List<String> skipped;

  /// 成功写入的节点出站数。
  final int nodeCount;
}

/// sing-box 核心的封装（切片 2：配置生成＋接线完成）。
///
/// 插件接线方式（已核对 flutter_sing_box 3.1.0 源码，见
/// docs/api/plugin-decision.md“阶段 1 接线结论”）：
/// - 配置体写插件的 `using_config.json`（`ProfileStorage.getUsingConfig()`），
///   原子写（临时文件＋改名），Android 与 Windows 的原生侧都从这里读配置；
/// - Android 启动要求 MMKV 里有一个已选档案（否则报 EmptyConfiguration），
///   首次启动时建一个名为“哲学系”的本地档案（只写元数据，不动配置体）；
/// - 插件没有“设置配置”的 API：已运行时换配置调 `serviceReload()`，
///   未运行时调 `startVpn()`；`serviceReload()` 在插件里实现为重启
///   （停＋起），换配置会有短暂断开，不是无缝热重载——校验失败时不写文件、
///   不调重载，旧配置继续跑（这就是本片的保证）；
/// - 校验分两层：插件内置的官方 JSON Schema（纯离线）＋结构检查
///   （legacy 写法、tag 重复、default_domain_resolver 缺失等）。
class CoreService {
  CoreService({
    FlutterSingBox? plugin,
    ConfigValidator? validator,
    Future<String> Function()? usingConfigPath,
    Future<void> Function(String configPath)? ensureSelectedProfile,
  }) : _plugin = plugin ?? FlutterSingBox(),
       _validator = validator ?? SingBoxSchemaConfigValidator(),
       _usingConfigPath =
           usingConfigPath ?? _defaultUsingConfigPath,
       _ensureSelectedProfile =
           ensureSelectedProfile ?? _defaultEnsureSelectedProfile;

  final FlutterSingBox _plugin;
  final ConfigValidator _validator;
  final Future<String> Function() _usingConfigPath;
  final Future<void> Function(String configPath) _ensureSelectedProfile;

  CoreStatus _status = CoreStatus.stopped;
  String? _lastError;

  /// 最后一份成功写入的配置 JSON（内存里的一份；重启后由 [init] 从磁盘读回）。
  String? _currentConfigJson;

  /// 最后一份配置里的节点出站数。
  int _appliedNodeCount = 0;

  /// 最后一份配置的写入时间。
  DateTime? _lastAppliedAt;

  final _statusController = StreamController<CoreStatus>.broadcast();
  StreamSubscription<ProxyState>? _pluginSubscription;

  /// 当前核心状态。
  CoreStatus get status => _status;

  /// 最近一次异常停止的原因；正常停止时为 null。
  String? get lastError => _lastError;

  /// 当前生效的配置 JSON（诊断与设置页“DNS 配置查看”用；没有时为 null）。
  String? get currentConfigJson => _currentConfigJson;

  /// 当前生效配置里的节点出站数。
  int get appliedNodeCount => _appliedNodeCount;

  /// 当前生效配置的写入时间。
  DateTime? get lastAppliedAt => _lastAppliedAt;

  /// 状态变化流（界面订阅它刷新大开关）。
  Stream<CoreStatus> get statusStream => _statusController.stream;

  /// 初始化插件，并把磁盘上最后一份配置读回内存（App 重启后 start 能用）。
  Future<void> init() async {
    await _plugin.init();
    _pluginSubscription = _plugin.proxyStateStream.listen((state) {
      _status = switch (state) {
        ProxyStarted() => CoreStatus.started,
        ProxyStarting() => CoreStatus.starting,
        ProxyStopping() => CoreStatus.stopping,
        ProxyStopped(:final errMessage) => errMessage == null
            ? CoreStatus.stopped
            : CoreStatus.error,
      };
      if (state is ProxyStopped) _lastError = state.errMessage;
      _statusController.add(_status);
    });
    try {
      final path = await _usingConfigPath();
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) _currentConfigJson = content;
      }
    } catch (_) {
      // 磁盘配置读不到不影响启动：start 时会因无配置而明确报错。
      _currentConfigJson = null;
    }
  }

  /// 用节点列表生成配置并应用。
  ///
  /// 顺序：生成 → 校验 → 写盘 →（已运行时）重载。校验失败时不写文件、
  /// 不调重载，旧配置继续跑，返回 [ConfigApplyResult.ok] = false 与原因。
  /// [mode] 只改 route 与 DNS 规则的解析路径（见
  /// [SingboxConfigBuilder.build]），默认规则模式。
  Future<ConfigApplyResult> applyNodes(
    List<Node> nodes, {
    RoutingMode mode = RoutingMode.rule,
  }) async {
    final built = SingboxConfigBuilder.build(nodes, mode: mode);
    final errors = await _validator.validate(built.config);
    if (errors.isNotEmpty) {
      return ConfigApplyResult(
        ok: false,
        errors: errors,
        skipped: built.skipped,
      );
    }
    final json = built.toJsonString();
    final path = await _usingConfigPath();
    await _writeAtomically(path, json);
    _currentConfigJson = json;
    _appliedNodeCount = nodes.length - built.skipped.length;
    _lastAppliedAt = DateTime.now();
    // 只在已运行时重载；停止状态下只写盘，等 start() 时再读。
    if (_status == CoreStatus.started) {
      await _plugin.serviceReload();
    }
    return ConfigApplyResult(
      ok: true,
      skipped: built.skipped,
      nodeCount: _appliedNodeCount,
    );
  }

  /// 启动代理。没有可用配置时直接报错，不让核心空跑。
  Future<void> start() async {
    if (_currentConfigJson == null) {
      throw StateError('没有可用配置：请先拉取订阅生成配置再启动');
    }
    final path = await _usingConfigPath();
    await _ensureSelectedProfile(path);
    await _plugin.startVpn();
  }

  /// 停止代理。
  Future<void> stop() async {
    await _plugin.stopVpn();
  }

  /// 读底层 sing-box 内核版本号（“关于”页展示用）。
  Future<String> coreVersion() => _plugin.getSingBoxVersion();

  /// 释放流控制器与插件状态流的订阅（订阅不取消时，dispose 后插件再推
  /// 状态会往已关闭的控制器里写，直接抛错）。
  void dispose() {
    _pluginSubscription?.cancel();
    _statusController.close();
  }

  /// 原子写盘：先写同目录临时文件，再改名覆盖（Windows 上改名覆盖会
  /// 失败，失败时删旧文件再改名）。
  static Future<void> _writeAtomically(String path, String content) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(content);
    try {
      await tmp.rename(path);
    } on FileSystemException {
      await File(path).delete();
      await tmp.rename(path);
    }
  }

  static Future<String> _defaultUsingConfigPath() async {
    return (await ProfileStorage().getUsingConfig()).path;
  }

  /// 默认的建档案逻辑：MMKV 里没有已选档案时，建一个名为“哲学系”的
  /// 本地档案并选中（只写元数据，配置体仍是 using_config.json）。
  static Future<void> _defaultEnsureSelectedProfile(
    String configPath,
  ) async {
    final storage = ProfileStorage();
    if (storage.getSelectedProfile() != null) return;
    final id = storage.generateProfileId;
    final profile = Profile(
      id: id,
      order: 0,
      name: '哲学系',
      outboundsCount: null,
      typed: TypedProfile(
        type: ProfileType.local,
        path: configPath,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    storage.updateProfile(profile);
    storage.setSelectedProfile(id);
  }
}
