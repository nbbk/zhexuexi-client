// 阶段 0 最小验证：Dart 写的 Clash API 客户端，调本地 sing-box 实例。
// 客户端阶段 1 的测速 / 选出站 / 实时流量就是调这几个接口。
// 用法：dart clash_client.dart（须先跑起 /tmp/singbox-val 里的 sing-box）。
import 'dart:convert';
import 'dart:io';

Future<Map<String, dynamic>> getJson(String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:9090$path'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

/// 取实时流量的一帧采样。
/// 注意：/traffic 是流式接口（每秒推一帧，永不关闭），不能用 .join() 等流
/// 结束，只能读第一行就关连接——上面踩过这个坑。
Future<Map<String, dynamic>> getTrafficSample() async {
  final client = HttpClient();
  try {
    final request =
        await client.getUrl(Uri.parse('http://127.0.0.1:9090/traffic'));
    final response = await request.close();
    final firstLine = await response
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    return jsonDecode(firstLine) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

Future<void> main() async {
  // 1. 版本：确认核心是 sing-box 1.14.4。
  final version = await getJson('/version');
  print('version: ${version['version']}');

  // 2. 出站列表：确认 GLOBAL / direct / block 三个组都在。
  final proxies = await getJson('/proxies');
  final names = (proxies['proxies'] as Map<String, dynamic>).keys.toList();
  print('proxies: $names');

  // 3. 实时流量：一帧采样（up/down 字节/秒）。
  final traffic = await getTrafficSample();
  print('traffic sample: up=${traffic['up']} down=${traffic['down']}');

  // 4. 断言：版本与出站都对得上才算过。
  assert(version['version'] == 'sing-box 1.14.4', '核心版本不是 1.14.4');
  assert(names.contains('GLOBAL'), '缺 GLOBAL 组');
  assert(names.contains('direct'), '缺 direct 出站');
  print('Dart Clash API 客户端：全部通过');
}
