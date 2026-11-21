import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../brand/brand_config.dart';

/// 远程配置中心（阶段 0 占位实现）。
///
/// 目标形态（见客户端方案 §6.2 与 DEV-PLAN §11）：
///   1. 远程配置 JSON 放在三个地址，客户端按顺序取，取到第一个可用的；
///   2. 配置带 Ed25519 签名，验签失败当作没拉到；
///   3. 拉到后立即存本地缓存，下次启动先用缓存、后台再拉；
///   4. 拉不到也不崩：继续用包内 brand.json / 上次缓存。
///
/// 阶段 0 只实现第 4 步的兜底（读包内 brand.json），第 1–3 步在阶段 1
/// 接面板新增的 `GET /client-config.json`（路由目前不存在，见
/// docs/api/panel-adapter.md §5.2）与签名校验后落地。
class RemoteConfigService {
  RemoteConfigService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// 三地址优先级（阶段 1 填真实地址；阶段 0 全部留空，只走兜底）。
  static const List<String> configUrls = <String>[];

  /// 拉远程配置；拉不到 / 验签失败返回 null，调用方用包内默认值。
  Future<BrandConfig?> fetchRemote() async {
    for (final url in configUrls) {
      try {
        final response = await _dio.get<String>(
          url,
          options: Options(responseType: ResponseType.plain),
        );
        if (response.statusCode == 200 && response.data != null) {
          // 阶段 1：这里先验 Ed25519 签名再解析。
          return BrandConfig.fromJson(
            jsonDecode(response.data!) as Map<String, dynamic>,
          );
        }
      } catch (e) {
        debugPrint('远程配置拉取失败（$url）：$e');
        continue;
      }
    }
    return null;
  }

  /// 当前生效的品牌配置：远程优先，拉不到用包内默认值。
  Future<BrandConfig> loadEffective() async {
    final remote = await fetchRemote();
    if (remote != null) return remote;
    return BrandConfig.loadBundled();
  }
}
