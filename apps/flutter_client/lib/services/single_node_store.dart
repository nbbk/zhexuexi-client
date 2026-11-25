import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/node_model.dart';
import 'subscription_parser.dart';

/// 手动加的单节点（粘贴/扫码一条节点链接，不走订阅）。
///
/// 存储：原文（一条链接，或扫到的多节点订阅正文）以 JSON 数组存进
/// flutter_secure_storage（链接里含 UUID/密码，按项目约定“令牌只存
/// 系统密钥库、不写明文文件、不进日志”）；读出来时现解析，
/// 解析失败的条目跳过，不拖垮列表。
///
/// 单节点不是订阅：不进订阅列表、不参与订阅拉取；合并时由
/// [NodesNotifier] 把它拼在订阅节点后面（见 nodes_notifier.dart）。
class SingleNodeStore {
  SingleNodeStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// 单节点原文（链接或订阅正文）的存储 key。
  static const String singleNodesKey = 'custom_single_nodes';

  /// 单节点在合并列表里的来源 id（节点行不显示，详情页可认）。
  static const String singleNodesId = 'single_nodes';

  /// 单节点在合并列表里的来源显示名。
  static const String singleNodesName = '手动添加';

  /// 全部原文（按添加顺序）。
  Future<List<String>> listRawTexts() async {
    final raw = await _storage.read(key: singleNodesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final texts = <String>[];
      for (final item in decoded) {
        if (item is String && item.trim().isNotEmpty) {
          texts.add(item);
        }
      }
      return texts;
    } catch (_) {
      // 存坏了按空列表算，不让一条坏数据拖垮节点列表。
      return [];
    }
  }

  /// 全部单节点（原文逐条解析；单条链接解一条，订阅正文解多条；
  /// 解不出来的条目跳过；内容相同的去重，只留第一条）。
  Future<List<Node>> listNodes() async {
    final nodes = <Node>[];
    final seen = <String>{};
    for (final text in await listRawTexts()) {
      for (final node in _parseText(text)) {
        if (seen.add(node.dedupKey)) nodes.add(node);
      }
    }
    return nodes;
  }

  /// 加一条单节点链接：解析不了返回原因；内容已存在返回原因；
  /// 成功返回解析出的节点。
  Future<({Node? node, String? error})> addSingleNode(String link) async {
    final trimmed = link.trim();
    final node = parseNodeLink(trimmed);
    if (node == null) {
      return (node: null, error: '这条节点链接解析不出来，检查是不是复制全了');
    }
    final existing = await listNodes();
    if (existing.any((n) => n.dedupKey == node.dedupKey)) {
      return (node: null, error: '这个节点已经加过了');
    }
    final texts = await listRawTexts();
    texts.add(trimmed);
    await _saveTexts(texts);
    return (node: node, error: null);
  }

  /// 加一段订阅正文（扫码扫到的三种格式正文）：解不出节点返回原因；
  /// 解出的节点全已存在返回原因；否则整段原文存一条，返回新加的节点数。
  Future<({int addedCount, String? error})> addContent(String body) async {
    final trimmed = body.trim();
    List<Node> nodes;
    try {
      nodes = parseSubscription(trimmed).nodes;
    } catch (_) {
      return (addedCount: 0, error: '内容里没有能识别的节点');
    }
    if (nodes.isEmpty) {
      return (addedCount: 0, error: '内容里没有能识别的节点');
    }
    final existing = await listNodes();
    final fresh = nodes
        .where((n) => !existing.any((e) => e.dedupKey == n.dedupKey))
        .toList();
    if (fresh.isEmpty) {
      return (addedCount: 0, error: '这些节点已经加过了');
    }
    final texts = await listRawTexts();
    texts.add(trimmed);
    await _saveTexts(texts);
    return (addedCount: fresh.length, error: null);
  }

  /// 删一个单节点（按内容 key 认）：
  /// 只含这一个节点的原文条目整条删掉；多节点正文里的单个节点
  /// 删不干净（原文是一整段），返回 false、不动数据。
  /// 成功返回 true。
  Future<bool> removeSingleNode(String dedupKey) async {
    final texts = await listRawTexts();
    var removed = false;
    final kept = <String>[];
    for (final text in texts) {
      final nodes = _parseText(text);
      if (nodes.length == 1 && nodes.first.dedupKey == dedupKey) {
        removed = true;
        continue;
      }
      kept.add(text);
    }
    if (!removed) return false;
    await _saveTexts(kept);
    return true;
  }

  /// 一段原文解成节点：单条链接解一条，否则按订阅正文三种格式解。
  List<Node> _parseText(String text) {
    final single = parseNodeLink(text.trim());
    if (single != null) return [single];
    try {
      return parseSubscription(text).nodes;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveTexts(List<String> texts) async {
    await _storage.write(key: singleNodesKey, value: jsonEncode(texts));
  }
}

/// 单节点存储（可注入 fake 做测试）。
final singleNodeStoreProvider = Provider<SingleNodeStore>(
  (ref) => SingleNodeStore(),
);
