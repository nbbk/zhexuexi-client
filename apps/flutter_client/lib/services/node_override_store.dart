import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/node_model.dart';

/// 节点本地改动（详情页编辑）的落盘存储。
///
/// 为什么要单独存一份覆盖，而不是改订阅/单节点原文：
/// - 订阅节点每次刷新都由 [subscription_parser] 重新解析拼装，
///   只改内存里的 Node 下次刷新就丢了；
/// - 单节点原文是链接/订阅正文，改动要序列化回链接是脏活，
///   且多节点正文里单条改了也写不回去。
/// 所以改动按“原始节点的稳定键”另存一份覆盖，刷新拼装完节点
/// 列表后盖上去（见 [NodesNotifier] 的 `_applyOverrides`）。
///
/// 存储：整套可编辑字段以 JSON 存进 flutter_secure_storage
/// （改动里含 UUID/密码，按项目约定“令牌只存系统密钥库、
/// 不写明文文件、不进日志”）；一条覆盖一个 key。
class NodeOverrideStore {
  NodeOverrideStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// 全部覆盖的存储 key（值是 `{覆盖键: 字段表}` 的 JSON 对象）。
  static const String overridesKey = 'node_overrides';

  /// 单次密钥库调用的超时：真机上密钥库调用是毫秒级；
  /// 超时只防“调用永远不返回”——没装插件的 widget 测试里
  /// 未处理的方法通道调用会一直挂起（纯 Dart 测试里同样调用
  /// 是立刻抛 MissingPluginException），没超时保护的话一次刷新
  /// 就能把界面卡死。超时按“没有覆盖”算，不拖垮刷新。
  static const Duration _storageTimeout = Duration(seconds: 5);

  /// 覆盖键：订阅 id ＋原始去重键。订阅节点与单节点走同一套：
  /// 订阅节点的订阅 id 是订阅条目 id，单节点是 `single_nodes`
  /// （见 [SingleNodeStore.singleNodesId]，由调用方随节点带来）。
  /// 原始键是改动前节点的 [Node.dedupKey]——改地址/端口/协议后
  /// 新节点的 dedupKey 变了，凭 [Node.originDedupKey] 才能找回
  /// 这条覆盖，所以覆盖键一旦定下来就不跟着改动走。
  static String overrideKey({
    String? subscriptionId,
    required String dedupKey,
  }) => '${subscriptionId ?? ''}|$dedupKey';

  /// 可编辑字段（覆盖里存的就这些；source/subscriptionId/
  /// subscriptionName/group/isPlainText 沿用原节点，不进覆盖）。
  static const List<String> editableFieldNames = [
    'name',
    'protocol',
    'address',
    'port',
    'uuidOrPassword',
    'transport',
    'tls',
    'sni',
    'wsPath',
    'wsHost',
    'method',
    'username',
    'realityPublicKey',
    'realityShortId',
    'fingerprint',
    'flow',
    'alpn',
    'congestionControl',
  ];

  /// 从节点取出一套可编辑字段（写盘与校验前先用它打底，
  /// 再盖上用户改的几项，避免只存改过的几项把其余字段丢了）。
  static Map<String, dynamic> fieldsOf(Node node) => {
    'name': node.name,
    'protocol': node.protocol.name,
    'address': node.address,
    'port': node.port,
    'uuidOrPassword': node.uuidOrPassword,
    'transport': node.transport,
    'tls': node.tls,
    'sni': node.sni,
    'wsPath': node.wsPath,
    'wsHost': node.wsHost,
    'method': node.method,
    'username': node.username,
    'realityPublicKey': node.realityPublicKey,
    'realityShortId': node.realityShortId,
    'fingerprint': node.fingerprint,
    'flow': node.flow,
    'alpn': node.alpn,
    'congestionControl': node.congestionControl,
  };

  /// 把一套覆盖字段盖到节点上，返回新节点（原节点不动）。
  /// 只换可编辑字段；来源、订阅、分组、明文标记沿用原节点；
  /// [Node.originDedupKey] 记原始键（已有就保留，没有就取当前
  /// 节点的 dedupKey），供再次编辑/删除时找回原始记录。
  /// 测速结果（latencyMs 等）也带过去，别让盖覆盖清掉刚测的延迟。
  static Node applyTo(Node node, Map<String, dynamic> fields) {
    final protocol = NodeProtocolLabel.fromString(
      (fields['protocol'] as String?) ?? node.protocol.name,
    );
    final portRaw = fields['port'];
    final port = portRaw is num
        ? portRaw.toInt()
        : int.tryParse('${portRaw ?? ''}') ?? node.port;
    final applied = Node(
      name: (fields['name'] as String?) ?? node.name,
      protocol: protocol,
      address: (fields['address'] as String?) ?? node.address,
      port: port,
      source: node.source,
      uuidOrPassword: fields.containsKey('uuidOrPassword')
          ? fields['uuidOrPassword'] as String?
          : node.uuidOrPassword,
      transport: (fields['transport'] as String?) ?? node.transport,
      tls: (fields['tls'] as bool?) ?? node.tls,
      sni: fields.containsKey('sni')
          ? fields['sni'] as String?
          : node.sni,
      wsPath: fields.containsKey('wsPath')
          ? fields['wsPath'] as String?
          : node.wsPath,
      wsHost: fields.containsKey('wsHost')
          ? fields['wsHost'] as String?
          : node.wsHost,
      method: fields.containsKey('method')
          ? fields['method'] as String?
          : node.method,
      group: node.group,
      isPlainText: node.isPlainText,
      username: fields.containsKey('username')
          ? fields['username'] as String?
          : node.username,
      realityPublicKey: fields.containsKey('realityPublicKey')
          ? fields['realityPublicKey'] as String?
          : node.realityPublicKey,
      realityShortId: fields.containsKey('realityShortId')
          ? fields['realityShortId'] as String?
          : node.realityShortId,
      fingerprint: fields.containsKey('fingerprint')
          ? fields['fingerprint'] as String?
          : node.fingerprint,
      flow: fields.containsKey('flow')
          ? fields['flow'] as String?
          : node.flow,
      alpn: fields.containsKey('alpn')
          ? fields['alpn'] as String?
          : node.alpn,
      congestionControl: fields.containsKey('congestionControl')
          ? fields['congestionControl'] as String?
          : node.congestionControl,
      subscriptionId: node.subscriptionId,
      subscriptionName: node.subscriptionName,
      originDedupKey: node.originDedupKey ?? node.dedupKey,
    );
    applied.latencyMs = node.latencyMs;
    applied.latencyFailed = node.latencyFailed;
    applied.latencyFailureReason = node.latencyFailureReason;
    return applied;
  }

  /// 校验一套字段（详情页保存前与 [NodesNotifier.updateNodeOverride]
  /// 里各校验一次）：不合法返回给用户看的原因，合法返回 null。
  /// 协议切换后旧参数保留在字段表里，不参与新协议的校验
  /// （只按当前协议要求必填项）。
  static String? validateFields(Map<String, dynamic> fields) {
    final name = (fields['name'] as String? ?? '').trim();
    if (name.isEmpty) return '名称不能为空';
    final address = (fields['address'] as String? ?? '').trim();
    if (address.isEmpty) return '地址不能为空';
    final portRaw = fields['port'];
    final port = portRaw is num
        ? portRaw.toInt()
        : int.tryParse('${portRaw ?? ''}');
    if (port == null || port < 1 || port > 65535) {
      return '端口须是 1–65535 的整数';
    }
    final protocol = NodeProtocolLabel.fromString(
      '${fields['protocol'] ?? ''}',
    );
    final secret = (fields['uuidOrPassword'] as String? ?? '').trim();
    if ((protocol == NodeProtocol.vless ||
            protocol == NodeProtocol.vmess ||
            protocol == NodeProtocol.trojan) &&
        secret.isEmpty) {
      return 'VLESS/VMess/Trojan 需要填写 UUID';
    }
    if ((protocol == NodeProtocol.hysteria2 ||
            protocol == NodeProtocol.tuic) &&
        secret.isEmpty) {
      return 'Hysteria2/TUIC 需要填写密码';
    }
    return null;
  }

  /// 全部覆盖（`{覆盖键: 字段表}`）；读不到、超时、存坏了都按空表算，
  /// 不让一条坏数据或一次挂起的调用拖垮节点列表。
  Future<Map<String, Map<String, dynamic>>> readAll() async {
    try {
      final raw = await _storage
          .read(key: overridesKey)
          .timeout(_storageTimeout);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, Map<String, dynamic>>{};
      for (final entry in decoded.entries) {
        if (entry.value is Map) {
          result['${entry.key}'] = Map<String, dynamic>.from(
            entry.value as Map,
          );
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  /// 读一条覆盖（没有时为 null）。
  Future<Map<String, dynamic>?> readOverride({
    String? subscriptionId,
    required String dedupKey,
  }) async {
    final all = await readAll();
    return all[overrideKey(
      subscriptionId: subscriptionId,
      dedupKey: dedupKey,
    )];
  }

  /// 写一条覆盖（字段表先由调用方拼全：[fieldsOf] 打底＋改动覆盖）。
  /// 写调用也加超时：超时时抛给调用方（updateNodeOverride 会
  /// 把它转成“保存失败，请重试”，不静默丢改动）。
  Future<void> saveOverride({
    String? subscriptionId,
    required String dedupKey,
    required Map<String, dynamic> fields,
  }) async {
    final all = await readAll();
    all[overrideKey(subscriptionId: subscriptionId, dedupKey: dedupKey)] =
        Map<String, dynamic>.from(fields);
    await _storage
        .write(key: overridesKey, value: jsonEncode(all))
        .timeout(_storageTimeout);
  }

  /// 删一条覆盖（恢复默认用；没有这条时不报错）。
  Future<void> clearOverride({
    String? subscriptionId,
    required String dedupKey,
  }) async {
    final all = await readAll();
    if (all.remove(
          overrideKey(subscriptionId: subscriptionId, dedupKey: dedupKey),
        ) ==
        null) {
      return;
    }
    await _storage
        .write(key: overridesKey, value: jsonEncode(all))
        .timeout(_storageTimeout);
  }
}

/// 节点本地改动存储（可注入 fake 做测试）。
final nodeOverrideStoreProvider = Provider<NodeOverrideStore>(
  (ref) => NodeOverrideStore(),
);
