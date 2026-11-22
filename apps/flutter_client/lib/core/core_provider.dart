import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'clash_api_client.dart';
import 'singbox_core.dart';

/// 全项目共用的 [CoreService]（单例；切片 3 首页大开关订阅它的
/// [CoreService.statusStream]，切片 4 测速用它的 Clash API 客户端）。
final coreServiceProvider = Provider<CoreService>((ref) {
  final service = CoreService();
  ref.onDispose(service.dispose);
  return service;
});

/// 全项目共用的 [ClashApiClient]（切片 3 首页实时速率读它；
/// 核心没启动时 127.0.0.1:9090 连不上，流以错误结束）。
final clashApiClientProvider = Provider<ClashApiClient>((ref) {
  return ClashApiClient();
});
