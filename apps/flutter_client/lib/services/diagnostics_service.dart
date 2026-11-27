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
    this.probeFailed = false,
    this.probeError,
    this.probeAt,
    this.nodesErrorMessage,
    this.configSnapshot,
    this.connectionChains,
    this.timeline,
    this.blackoutAt,
    this.coreLogTail,
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

  /// 启动探活状态：true=最后一次拨测失败（0.1.3 D 路修复 2：
  /// 0.1.2 只拨 Clash API delay、绕过 TUN/路由/客户端 DNS，
  /// 且失败只写探活位、不翻 CoreStatus.error——诊断包不写这一
  /// 行就看不出“运行中但流量不通”）。
  final bool probeFailed;

  /// 探活失败原因（probeFailed 为 true 时才有内容）。
  final String? probeError;

  /// 探活最近一次结果的时间。
  final DateTime? probeAt;

  /// 节点列表最近一次拉取失败的原因（没有时为 null）。
  final String? nodesErrorMessage;

  /// 当前生成配置的 route/dns 段快照（JSON 文本，2026-11-26 0.1.2
  /// P0-4 诊断可见性；拿不到时为 null，不在报告里占行）。
  final String? configSnapshot;

  /// 实时连接的 chain 列表（`GET /connections` 的 chain 拼串；
  /// 核心没跑或拿不到时为空，不在报告里占行）。
  final List<String>? connectionChains;

  /// 采样时序（0.1.9：开开关后每 20 秒采一次，格式化好的行；核心
  /// 没跑或尚未采样时为空/为 null，报告里印“无”，绝不编造）。
  final List<String>? timeline;

  /// 疑似黑断时刻（代理路 DNS 探针从通过变失败的那一次采样）；
  /// 没标过时为 null。
  final DateTime? blackoutAt;

  /// 核心日志尾巴（0.1.9：Dart 侧 `FlutterSingBox.logStream`
  /// 取到的最近若干行；没取到行时为空/为 null）。
  final List<String>? coreLogTail;
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
    if (input.configSnapshot != null)
      '当前配置 route/dns：${input.configSnapshot}',
    if (input.connectionChains != null && input.connectionChains!.isNotEmpty)
      '实时连接：${input.connectionChains!.join('；')}',
    '最近错误：${errors.isEmpty ? '无' : errors.join('；')}',
    // 0.1.3 D 路修复 2：启动探活状态单列一行——探活失败不翻
    // CoreStatus.error，状态仍显示“运行中”，不写这一行就看不
    // 出“运行中但流量不通”。
    // 0.1.4（A/B 路）：probeAt == null 说明探活一次也没跑过
    // （核心没启动过，或启动后还没拨测），此时绝不能印“通过”——
    // 0.1.3 诊断包的“启动探活：通过（最近结果：—）”就是默认值
    // 谎言，核心停着时也印通过，误导过一次定罪。
    if (input.probeAt == null)
      '启动探活：未探活（核心未启动或尚未拨测）'
    else if (input.probeFailed)
      '启动探活：失败（${input.probeError ?? '未知原因'}；最近结果：${timeOrDash(input.probeAt)}）'
    else
      '启动探活：通过（最近结果：${timeOrDash(input.probeAt)}）',
    // 0.1.9 采样时序：每行含自开开关起的相对秒数、两路 DNS 各自成败
    // 与延迟、各出站连接数与流量、黑断标记（有时才有）。无采样时印
    // “无”，绝不编造；黑断时刻另单列一行，方便一眼看到。
    if (input.timeline == null || input.timeline!.isEmpty)
      '采样时序：无（核心未启动或尚未采样）'
    else ...[
      '采样时序（开开关后每 20 秒采一次）：',
      ...input.timeline!,
      if (input.blackoutAt != null)
        '疑似黑断时刻：${input.blackoutAt}',
    ],
    // 0.1.9 核心日志尾巴：Dart 侧经插件 logStream 取到才印行；
    // 没取到行时如实写“暂无日志行”，不要编造、不要留空让人以为有。
    if (input.coreLogTail == null || input.coreLogTail!.isEmpty)
      '核心日志：暂无日志行（核心未启动或尚未产生日志）'
    else ...[
      '核心日志尾巴（最近 ${input.coreLogTail!.length} 行）：',
      ...input.coreLogTail!,
    ],
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
