// 切片 6：诊断包（不含令牌明文）与连接检测的回归测试。
import 'package:flutter_test/flutter_test.dart';
import 'package:zhexuexi_client/services/diagnostics_service.dart';

DiagnosticsReportInput _input({
  String? currentNodeName,
  String? coreLastError,
  String? nodesErrorMessage,
}) {
  return DiagnosticsReportInput(
    appVersion: '0.1.0',
    coreVersion: '1.14.4',
    coreStatusText: '已连接',
    modeLabel: '规则模式',
    hasBinding: true,
    nodeCount: 3,
    currentNodeName: currentNodeName ?? '日本-直连',
    currentLatencyMs: 123,
    lastSpeedTestAt: DateTime(2026, 11, 23, 1, 0, 0),
    lastUpdated: DateTime(2026, 11, 23, 0, 30, 0),
    tunEnabled: false,
    customRulesCount: 2,
    autoUpdateEnabled: true,
    coreLastError: coreLastError,
    nodesErrorMessage: nodesErrorMessage,
  );
}

void main() {
  group('诊断包内容', () {
    test('含版本号、状态、节点名、延迟、DNS 摘要与最近错误', () {
      final report = buildDiagnosticsReport(
        _input(coreLastError: '核心异常停止'),
      );
      expect(report, contains('客户端版本：0.1.0'));
      expect(report, contains('sing-box 核心版本：1.14.4'));
      expect(report, contains('核心状态：已连接'));
      expect(report, contains('分流模式：规则模式'));
      expect(report, contains('订阅：已绑定'));
      expect(report, contains('节点数：3'));
      expect(report, contains('当前节点：日本-直连'));
      expect(report, contains('当前节点延迟：123ms'));
      expect(report, contains('自定义规则：2 条'));
      expect(report, contains('DNS 防泄漏：已开启，不可关闭'));
      expect(report, contains('1.1.1.1'));
      expect(report, contains('dns.google'));
      expect(report, contains('最近错误：核心：核心异常停止'));
    });

    test('没有错误时最近错误写“无”；空值显示“—”', () {
      final report = buildDiagnosticsReport(
        const DiagnosticsReportInput(
          appVersion: '0.1.0',
          coreVersion: '—',
          coreStatusText: '未连接',
          modeLabel: '直连模式',
          hasBinding: false,
          nodeCount: 0,
          tunEnabled: false,
          customRulesCount: 0,
          autoUpdateEnabled: false,
        ),
      );
      expect(report, contains('最近错误：无'));
      expect(report, contains('当前节点：未选择'));
      expect(report, contains('当前节点延迟：—'));
      expect(report, contains('订阅：未绑定'));
      expect(report, contains('订阅自动更新：关闭'));
    });

    test('再真的令牌、订阅链接与节点地址也不会出现在报告里', () {
      // 诊断包的输入结构里根本没有放令牌、链接与地址的地方；
      // 这个测试是护栏：以后谁往输入里加了这些字段还照原样输出，
      // 这里就会先炸。先验证当前报告确实不含这三类字符串。
      const token = '0123456789abcdef0123456789abcdef0123456789abcdef';
      const subUrl = 'https://example.com/x9f2/$token';
      const nodeAddress = '203.0.113.1';
      final report = buildDiagnosticsReport(_input());
      expect(report.contains(token), isFalse);
      expect(report.contains(subUrl), isFalse);
      expect(report.contains(nodeAddress), isFalse);
      expect(report.contains('x9f2'), isFalse);
      expect(report.contains('203.0.113'), isFalse);
      // 节点名本身可以出现（名字不是地址）。
      expect(report, contains('日本-直连'));
    });
  });

  group('连接检测', () {
    test('核心未启动时直接报未启动，不 ping Clash API', () async {
      var pingCalls = 0;
      final service = DiagnosticsService(
        clashApiPing: () async {
          pingCalls++;
          return true;
        },
      );
      final result = await service.checkConnectivity(coreRunning: false);
      expect(result.coreRunning, isFalse);
      expect(result.clashApiReachable, isFalse);
      expect(result.detail, contains('核心未启动'));
      expect(pingCalls, 0);
    });

    test('核心在跑且 Clash API 通时报连通；不通时报连不上', () async {
      final okService = DiagnosticsService(clashApiPing: () async => true);
      final ok = await okService.checkConnectivity(coreRunning: true);
      expect(ok.coreRunning, isTrue);
      expect(ok.clashApiReachable, isTrue);
      expect(ok.detail, contains('连通'));

      final badService = DiagnosticsService(clashApiPing: () async => false);
      final bad = await badService.checkConnectivity(coreRunning: true);
      expect(bad.coreRunning, isTrue);
      expect(bad.clashApiReachable, isFalse);
      expect(bad.detail, contains('连不上'));
    });
  });
}
