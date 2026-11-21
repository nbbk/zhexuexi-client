import 'dart:async';

import 'package:flutter_sing_box/flutter_sing_box.dart';

/// 核心状态（界面只认这个枚举，不直接认插件的 [ProxyState]）。
enum CoreStatus { stopped, starting, started, stopping, error }

/// sing-box 核心的封装（阶段 0 占位实现）。
///
/// 职责边界：
/// - 只负责“启动 / 停止 / 读状态 / 读日志 / 读核心版本号”；
/// - 配置生成（订阅 → sing-box JSON）归阶段 1 的配置生成器；
/// - 节点选择、测速归阶段 1 的节点服务。
/// 插件 API 细节见 docs/api/plugin-decision.md（flutter_sing_box 3.1.0，
/// 内置 sing-box 1.14.4）。
class CoreService {
  CoreService({FlutterSingBox? plugin}) : _plugin = plugin ?? FlutterSingBox();

  final FlutterSingBox _plugin;

  CoreStatus _status = CoreStatus.stopped;
  String? _lastError;

  final _statusController = StreamController<CoreStatus>.broadcast();

  /// 当前核心状态。
  CoreStatus get status => _status;

  /// 最近一次异常停止的原因；正常停止时为 null。
  String? get lastError => _lastError;

  /// 状态变化流（界面订阅它刷新大开关）。
  Stream<CoreStatus> get statusStream => _statusController.stream;

  /// 初始化插件（阶段 1：同时把上次的配置写回核心）。
  Future<void> init() async {
    await _plugin.init();
    _plugin.proxyStateStream.listen((state) {
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
  }

  /// 启动代理（阶段 0：无配置可启动，调用方须先有配置；失败时抛错）。
  Future<void> start() async {
    await _plugin.startVpn();
  }

  /// 停止代理。
  Future<void> stop() async {
    await _plugin.stopVpn();
  }

  /// 读底层 sing-box 内核版本号（阶段 0 用于“关于”页展示）。
  Future<String> coreVersion() => _plugin.getSingBoxVersion();

  /// 释放流控制器。
  void dispose() {
    _statusController.close();
  }
}
