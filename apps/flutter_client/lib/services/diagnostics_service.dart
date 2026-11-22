import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/singbox_config.dart';

/// 诊断包的输入（切片 6：设置页“导出诊断包”）。
///
/// 只含定位问题要的摘要：版本号、核心状态、模式、节点名（不是节点
/// 地址）、延迟、DNS 配置摘要、错误摘要。诊断包绝不含订阅链接、
/// 订阅令牌、节点 IP——这三样根本不进这个结构，调用方想塞也塞不进来
/// （见 [buildDiagnosticsReport] 的测试：给再真的令牌与地址也不会
/// 出现在报告里）。
class DiagnosticsReportInput {
  const DiagnosticsReportInput({
    required this.appVersion,
    required this.coreVersion,
    required this.coreStatusText,
    required this.modeLabel,
    required this.hasBinding,
    required this.nodeCount,
    this.currentNodeName,
    this.currentLatencyMs,
    this.lastSpeedTestAt,
    this.lastUpdated,
    required this.tunEnabled,
    required this.customRulesCount,
    required this.autoUpdateEnabled,
    this.coreLastError,
    this.nodesErrorMessage,
  });

  /// 客户端版本（如 `0.1.0`）。
  final String appVersion;

  /// sing-box 核心版本（读不到时传 `—`）。
  final String coreVersion;

  /// 核心状态文案（未连接 / 已连接 / 连接失败：原因……）。
  final String coreStatusText;

  /// 分流模式文案（规则模式 / 全局模式 / 直连模式）。
  final String modeLabel;

  /// 是否已绑定订阅（只给布尔值，不给订阅链接与令牌）。
  final bool hasBinding;

  /// 节点总数。
  final int nodeCount;

  /// 当前节点名（只给名字，不给节点地址与端口）。
  final String? currentNodeName;

  /// 当前节点的延迟（毫秒，测过才有）。
  final int? currentLatencyMs;

  /// 上次测速完成的时间。
  final DateTime? lastSpeedTestAt;

  /// 上次订阅更新成功的时间。
  final DateTime? lastUpdated;

  /// TUN 是否开启。
  final bool tunEnabled;

  /// 自定义规则条数。
  final int customRulesCount;

  /// 订阅自动更新开关是否开启。
  final bool autoUpdateEnabled;

  /// 核心最近一次异常停止的原因（没有时为 null）。
  final String? coreLastError;

  /// 节点列表最近一次拉取失败的原因（没有时为 null）。
  final String? nodesErrorMessage;
}

/// 生成诊断包文本（纯函数，可单测）。
///
/// 格式是给人看的纯文本：版本号、状态、节点名、DNS 摘要、最近错误，
/// 一行一项。调用方只负责展示与复制，不再往里拼东西。
String buildDiagnosticsReport(DiagnosticsReportInput input) {
  String timeOrDash(DateTime? t) => t == null ? '—' : t.toString();
  final latency = input.currentLatencyMs == null
      ? '—'
      : '${input.currentLatencyMs}ms';
  final errors = [
    if (input.coreLastError != null) '核心：${input.coreLastError}',
    if (input.nodesErrorMessage != null) '订阅：${input.nodesErrorMessage}',
  ];
  final lines = [
    '哲学系客户端诊断包',
    '客户端版本：${input.appVersion}',
    '系统版本：${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'sing-box 核心版本：${input.coreVersion}',
    '核心状态：${input.coreStatusText}',
    '分流模式：${input.modeLabel}',
    '订阅：${input.hasBinding ? '已绑定' : '未绑定'}',
    '节点数：${input.nodeCount}',
    '当前节点：${input.currentNodeName ?? '未选择'}',
    '当前节点延迟：$latency',
    '上次测速：${timeOrDash(input.lastSpeedTestAt)}',
    '上次订阅更新：${timeOrDash(input.lastUpdated)}',
    'TUN：${input.tunEnabled ? '开启' : '关闭'}',
    '自定义规则：${input.customRulesCount} 条',
    '订阅自动更新：${input.autoUpdateEnabled ? '开启' : '关闭'}',
    'DNS 防泄漏：已开启，不可关闭',
    for (final entry in SingboxConfigBuilder.dnsSummary)
      'DNS ${entry.label}：${entry.value}',
    '最近错误：${errors.isEmpty ? '无' : errors.join('；')}',
  ];
  return lines.join('\n');
}

/// 连接检测的结果（切片 6：设置页“连接检测”）。
class ConnectivityCheckResult {
  const ConnectivityCheckResult({
    required this.coreRunning,
    required this.clashApiReachable,
    required this.detail,
  });

  /// 核心是否在跑。
  final bool coreRunning;

  /// Clash API（127.0.0.1:9090）是否能连上。
  final bool clashApiReachable;

  /// 给用户看的一行结论。
  final String detail;
}

/// 连接检测（切片 6）。
///
/// 只查本机两件事：核心在跑没跑、Clash API 通不通。不发任何外网
/// 请求，不碰订阅与令牌。Clash API 的 ping 可注入 fake 做测试。
class DiagnosticsService {
  DiagnosticsService({Future<bool> Function()? clashApiPing})
    : _clashApiPing = clashApiPing ?? _defaultClashApiPing;

  final Future<bool> Function() _clashApiPing;

  /// 核心在跑时 Clash API 才通；核心没跑时直接报“核心未启动”，
  /// 不发请求（127.0.0.1:9090 没人听，请求只会超时）。
  Future<ConnectivityCheckResult> checkConnectivity({
    required bool coreRunning,
  }) async {
    if (!coreRunning) {
      return const ConnectivityCheckResult(
        coreRunning: false,
        clashApiReachable: false,
        detail: '核心未启动，先在首页打开开关再检测',
      );
    }
    final reachable = await _clashApiPing();
    return ConnectivityCheckResult(
      coreRunning: true,
      clashApiReachable: reachable,
      detail: reachable ? '核心在跑，Clash API 连通' : '核心在跑，但 Clash API 连不上（127.0.0.1:9090 无响应）',
    );
  }

  /// 默认的 Clash API ping：GET /version，3 秒超时；200 算通，
  /// 其他状态码与异常都算不通。
  static Future<bool> _defaultClashApiPing() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:9090/version'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}

/// 连接检测服务（可注入 fake 做测试）。
final diagnosticsServiceProvider = Provider<DiagnosticsService>(
  (ref) => DiagnosticsService(),
);
