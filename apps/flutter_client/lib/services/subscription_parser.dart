import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../core/node_model.dart';

/// 一次订阅解析的结果。
///
/// 约定（见 docs/api/panel-adapter.md §7 与 docs/mvp-slices.md 切片 1）：
/// - 只取节点模型；`dns` / `route` / `proxy-groups` / `rules` 一律不透传，
///   DNS 与路由由客户端自己生成（切片 2）；
/// - 单个节点解析失败只计入 [failedCount]，不丢整个订阅；
/// - 整个正文完全无法识别（三种格式都不是）时抛 [FormatException]，
///   由调用方按 singbox → base64 → clash 的顺序回退。
class SubscriptionParseResult {
  const SubscriptionParseResult({required this.nodes, required this.failedCount});

  /// 解析出的节点。
  final List<Node> nodes;

  /// 解析失败的节点个数（界面显示“解析失败 N 个”）。
  final int failedCount;
}

/// 订阅格式（只用于回退链与展示，不依赖 UA 嗅探）。
enum SubscriptionFormat { singbox, clash, base64 }

/// 从正文猜格式：JSON 对象 → singbox；含 `proxies:` → clash；否则当链接列表。
SubscriptionFormat detectFormat(String body) {
  final trimmed = body.trimLeft();
  if (trimmed.startsWith('{')) return SubscriptionFormat.singbox;
  if (trimmed.contains('proxies:')) return SubscriptionFormat.clash;
  return SubscriptionFormat.base64;
}

/// 按格式解析订阅正文；[format] 为 null 时先猜格式。
SubscriptionParseResult parseSubscription(String body, [SubscriptionFormat? format]) {
  return switch (format ?? detectFormat(body)) {
    SubscriptionFormat.singbox => parseSingboxJson(body),
    SubscriptionFormat.clash => parseClashYaml(body),
    SubscriptionFormat.base64 => parseLinkList(body),
  };
}

/// 解析 sing-box JSON 订阅（面板 `?format=singbox` 的输出，1.3.37 起 DNS
/// 已是新格式；这里只读 `outbounds` 里的节点出站，`dns` / `route` /
/// `inbounds` 一律不读）。
///
/// 节点出站字段（面板 `singboxOutboundFromLink` 的实际形状）：
/// VLESS：type/server/server_port/uuid，tls.server_name，transport{type:ws,
/// path, headers.Host}；Trojan：password；VMess：uuid/alter_id/security；
/// SS：method/password；AnyTLS：password，tls.server_name；SOCKS5：
/// username/password。REALITY 的 VLESS 出站另带顶层 `flow` 与
/// `tls.reality{public_key, short_id}`、`tls.utls.fingerprint`
/// （见实施方案 §8.2）。selector / urltest / direct / block 按 type 跳过。
SubscriptionParseResult parseSingboxJson(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('sing-box JSON 顶层不是对象');
  }
  final outbounds = decoded['outbounds'];
  if (outbounds is! List) {
    throw const FormatException('sing-box JSON 没有 outbounds 数组');
  }
  final nodes = <Node>[];
  var failed = 0;
  for (final item in outbounds) {
    if (item is! Map<String, dynamic>) {
      failed++;
      continue;
    }
    // selector / urltest / direct / block 等组出站不是节点，直接跳过，不计失败。
    final type = (item['type'] as String?)?.toLowerCase();
    if (type == 'selector' ||
        type == 'urltest' ||
        type == 'direct' ||
        type == 'block' ||
        type == 'dns') {
      continue;
    }
    final node = _nodeFromSingboxOutbound(item);
    if (node == null) {
      failed++;
    } else {
      nodes.add(node);
    }
  }
  return SubscriptionParseResult(nodes: nodes, failedCount: failed);
}

Node? _nodeFromSingboxOutbound(Map<String, dynamic> ob) {
  final type = (ob['type'] as String?)?.toLowerCase();
  // selector / urltest / direct / block 等组出站不是节点。
  if (type == null ||
      type == 'selector' ||
      type == 'urltest' ||
      type == 'direct' ||
      type == 'block' ||
      type == 'dns') {
    return null;
  }
  final protocol = NodeProtocolLabel.fromString(type);
  // 面板 sing-box JSON 出 vless / trojan / vmess / ss / anytls / socks
  // （切片 10 起）；
  // HY2 / TUIC 在这里会被面板跳过，只在 base64/plain 里保留。
  if (protocol == NodeProtocol.unknown) return null;
  final tag = ob['tag'] as String?;
  final server = ob['server'] as String?;
  final port = _asInt(ob['server_port']);
  if (tag == null || tag.isEmpty || server == null || server.isEmpty || port == null || port <= 0) {
    return null;
  }
  final tls = ob['tls'] as Map<String, dynamic>?;
  final tlsEnabled = tls?['enabled'] == true;
  final sni = tls?['server_name'] as String?;
  final transport = ob['transport'] as Map<String, dynamic>?;
  final transportType = (transport?['type'] as String?) ?? 'tcp';
  final wsPath = transport?['path'] as String?;
  final transportHeaders = transport?['headers'] as Map<String, dynamic>?;
  final wsHost = transportHeaders?['Host'] as String?;
  final method = ob['method'] as String?;
  final uuidOrPassword = switch (protocol) {
    NodeProtocol.vless || NodeProtocol.vmess => ob['uuid'] as String?,
    NodeProtocol.trojan ||
    NodeProtocol.shadowsocks ||
    NodeProtocol.anytls ||
    NodeProtocol.socks5 => ob['password'] as String?,
    _ => null,
  };
  if (uuidOrPassword == null || uuidOrPassword.isEmpty) return null;
  // REALITY（切片 10）：tls.reality 块。public_key 缺了说明这条 REALITY
  // 出站不完整（面板不会下发这种），按失败计，不静默降级成普通 TLS。
  final reality = tls?['reality'] as Map<String, dynamic>?;
  final realityEnabled = reality?['enabled'] == true;
  final realityPublicKey = reality?['public_key'] as String?;
  if (realityEnabled &&
      (realityPublicKey == null || realityPublicKey.isEmpty)) {
    return null;
  }
  final utls = tls?['utls'] as Map<String, dynamic>?;
  final username = ob['username'] as String?;
  final flow = ob['flow'] as String?;
  // AnyTLS 恒为 TLS：面板的出站即使没写 tls 块也不算明文。
  final nodeTls = protocol == NodeProtocol.anytls || tlsEnabled;
  return Node(
    name: tag,
    protocol: protocol,
    address: server,
    port: port,
    source: _sourceFromName(tag),
    uuidOrPassword: uuidOrPassword,
    transport: transportType,
    tls: nodeTls,
    sni: (sni == null || sni.isEmpty) ? null : sni,
    wsPath: (wsPath == null || wsPath.isEmpty) ? null : wsPath,
    wsHost: (wsHost == null || wsHost.isEmpty) ? null : wsHost,
    method: (method == null || method.isEmpty) ? null : method,
    isPlainText: !nodeTls,
    username: (username == null || username.isEmpty) ? null : username,
    realityPublicKey: (realityPublicKey == null || realityPublicKey.isEmpty)
        ? null
        : realityPublicKey,
    realityShortId: _nonEmptyString(reality?['short_id']),
    fingerprint: _nonEmptyString(utls?['fingerprint']),
    flow: (flow == null || flow.isEmpty) ? null : flow,
  );
}

/// 解析 Clash YAML 订阅（面板 `?format=clash` 的输出）。
///
/// 只读 `proxies` 数组里的节点；`proxy-groups` / `rules` / `dns` 一律不读
/// （规则由客户端自己生成，见 docs/api/panel-adapter.md §6.2）。
/// proxy 字段（面板 `clashProxyFromLink` 的实际形状）：
/// name/type/server/port/uuid 或 password/cipher、tls（bool）、servername、
/// network、ws-opts{path, headers.Host}、udp。REALITY 的 VLESS 另带
/// `reality-opts{public-key, short-id}`、`fingerprint`、`flow`
/// （见实施方案 §8.2）；AnyTLS 带 `password` 与 `sni`；
/// SOCKS5 带 `username` 与 `password`。
SubscriptionParseResult parseClashYaml(String body) {
  final doc = loadYaml(body);
  if (doc is! YamlMap) {
    throw const FormatException('Clash YAML 顶层不是映射');
  }
  final proxies = doc['proxies'];
  if (proxies is! YamlList) {
    throw const FormatException('Clash YAML 没有 proxies 数组');
  }
  final nodes = <Node>[];
  var failed = 0;
  for (final item in proxies) {
    if (item is! YamlMap) {
      failed++;
      continue;
    }
    final node = _nodeFromClashProxy(item);
    if (node == null) {
      failed++;
    } else {
      nodes.add(node);
    }
  }
  return SubscriptionParseResult(nodes: nodes, failedCount: failed);
}

Node? _nodeFromClashProxy(YamlMap proxy) {
  final type = (proxy['type'] as String?)?.toLowerCase();
  if (type == null) return null;
  final protocol = NodeProtocolLabel.fromString(type);
  // 面板 Clash 里出 vless / trojan / vmess / ss / anytls / socks5
  // （切片 10 起）；
  // HY2 / TUIC 在这里会被面板跳过，只在 base64/plain 里保留。
  if (protocol == NodeProtocol.unknown) return null;
  final name = proxy['name'] as String?;
  final server = proxy['server'] as String?;
  final port = _asInt(proxy['port']);
  if (name == null || name.isEmpty || server == null || server.isEmpty || port == null || port <= 0) {
    return null;
  }
  final uuidOrPassword = switch (protocol) {
    NodeProtocol.vless || NodeProtocol.vmess => proxy['uuid'] as String?,
    NodeProtocol.trojan ||
    NodeProtocol.shadowsocks ||
    NodeProtocol.anytls ||
    NodeProtocol.socks5 => proxy['password'] as String?,
    _ => null,
  };
  if (uuidOrPassword == null || uuidOrPassword.isEmpty) return null;
  // AnyTLS 恒为 TLS：面板的 proxy 即使没写 tls 字段也不算明文。
  final tls = protocol == NodeProtocol.anytls || proxy['tls'] == true;
  var sni = proxy['servername'] as String?;
  // AnyTLS 的 SNI 在 Clash 里写 `sni` 字段，不写 `servername`。
  if ((sni == null || sni.isEmpty) && protocol == NodeProtocol.anytls) {
    sni = proxy['sni'] as String?;
  }
  final network = (proxy['network'] as String?) ?? 'tcp';
  String? wsPath;
  String? wsHost;
  final wsOpts = proxy['ws-opts'];
  if (wsOpts is YamlMap) {
    wsPath = wsOpts['path'] as String?;
    final headers = wsOpts['headers'];
    if (headers is YamlMap) wsHost = headers['Host'] as String?;
  }
  final method = proxy['cipher'] as String?;
  // REALITY（切片 10）：reality-opts 块。public-key 缺了说明这条 REALITY
  // 节点不完整，按失败计，不静默降级成普通 TLS。
  final realityOpts = proxy['reality-opts'];
  String? realityPublicKey;
  String? realityShortId;
  if (realityOpts is YamlMap) {
    realityPublicKey = realityOpts['public-key'] as String?;
    realityShortId = realityOpts['short-id'] as String?;
    if (realityPublicKey != null && realityPublicKey.isEmpty) {
      realityPublicKey = null;
    }
    if (realityShortId != null && realityShortId.isEmpty) {
      realityShortId = null;
    }
  }
  if (realityOpts is YamlMap &&
      (realityPublicKey == null || realityPublicKey.isEmpty)) {
    return null;
  }
  final username = proxy['username'] as String?;
  final flow = proxy['flow'] as String?;
  final fingerprint = proxy['fingerprint'] as String?;
  return Node(
    name: name,
    protocol: protocol,
    address: server,
    port: port,
    source: _sourceFromName(name),
    uuidOrPassword: uuidOrPassword,
    transport: network,
    tls: tls,
    sni: (sni == null || sni.isEmpty) ? null : sni,
    wsPath: (wsPath == null || wsPath.isEmpty) ? null : wsPath,
    wsHost: (wsHost == null || wsHost.isEmpty) ? null : wsHost,
    method: (method == null || method.isEmpty) ? null : method,
    isPlainText: !tls,
    username: (username == null || username.isEmpty) ? null : username,
    realityPublicKey: realityPublicKey,
    realityShortId: realityShortId,
    fingerprint: (fingerprint == null || fingerprint.isEmpty)
        ? null
        : fingerprint,
    flow: (flow == null || flow.isEmpty) ? null : flow,
  );
}

/// 解析 base64 / plain 节点链接列表（面板 `?format=base64` 或 `plain`）。
///
/// 每行一条链接：vless://、vmess://、trojan://、ss://、hysteria2://、
/// tuic://、anytls://、socks5://。
/// 正文若不含 `://`，先当 base64 解一次再按行解析；解不开就按明文行解析。
/// 空行跳过（不计失败）；垃圾行计入 failedCount。
SubscriptionParseResult parseLinkList(String body) {
  var text = body;
  if (!body.contains('://')) {
    final decoded = _tryBase64Decode(body.trim());
    if (decoded != null) text = decoded;
  }
  final nodes = <Node>[];
  var failed = 0;
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final node = parseNodeLink(line);
    if (node == null) {
      failed++;
    } else {
      nodes.add(node);
    }
  }
  return SubscriptionParseResult(nodes: nodes, failedCount: failed);
}

/// 解析一条节点链接（vless / vmess / trojan / ss / hysteria2 / tuic /
/// anytls / socks5）。解析不了返回 null（调用方计入失败数）。
Node? parseNodeLink(String link) {
  final trimmed = link.trim();
  final schemeEnd = trimmed.indexOf('://');
  if (schemeEnd <= 0) return null;
  final scheme = trimmed.substring(0, schemeEnd).toLowerCase();
  return switch (scheme) {
    'vless' || 'trojan' => _nodeFromUriLink(trimmed, scheme),
    'vmess' => _nodeFromVmessLink(trimmed),
    'ss' => _nodeFromSsLink(trimmed),
    'hysteria2' || 'hy2' => _nodeFromHy2Link(trimmed),
    'tuic' => _nodeFromTuicLink(trimmed),
    'anytls' => _nodeFromAnytlsLink(trimmed),
    'socks5' || 'socks' => _nodeFromSocks5Link(trimmed),
    _ => null,
  };
}

Node? _nodeFromUriLink(String link, String scheme) {
  final uri = Uri.tryParse(link);
  if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;
  final id = uri.userInfo.isEmpty ? null : _decodeComponentSafe(uri.userInfo);
  if (id == null || id.isEmpty) return null;
  // 查询参数按名取，不依赖顺序；`encryption=none` 有无都不影响解析
  // （VLESS 固定不加密，这里不校验它）。
  final query = uri.queryParameters;
  final security = query['security']?.toLowerCase();
  final isReality = security == 'reality';
  final tls = security == 'tls' || isReality;
  var sni = query['sni'];
  if (sni == null || sni.isEmpty) sni = query['host'];
  final network = query['type'] ?? 'ws';
  final name = _linkName(uri);
  if (name.isEmpty) return null;
  // REALITY（切片 10，实施方案 §8.2）：pbk / sid / fp / flow。
  // security=reality 但没给 pbk 时解析失败，不静默降级成普通 TLS。
  final realityPublicKey = _nonEmptyString(query['pbk']);
  if (isReality && realityPublicKey == null) return null;
  return Node(
    name: name,
    protocol: scheme == 'vless' ? NodeProtocol.vless : NodeProtocol.trojan,
    address: uri.host,
    port: uri.port,
    source: _sourceFromName(name),
    uuidOrPassword: id,
    transport: network,
    tls: tls,
    sni: (sni == null || sni.isEmpty) ? null : sni,
    wsPath: _queryPath(query['path']),
    // host 参数是 WS Host 头（同时也是 sni 为空时的回退，见上）。
    wsHost: (network == 'ws' || network == 'h2') ? query['host'] : null,
    isPlainText: !tls,
    realityPublicKey: realityPublicKey,
    realityShortId: _nonEmptyString(query['sid']),
    fingerprint: _nonEmptyString(query['fp']),
    flow: _nonEmptyString(query['flow']),
  );
}

Node? _nodeFromVmessLink(String link) {
  final payload = link.substring('vmess://'.length);
  final decoded = _tryBase64Decode(payload.trim());
  if (decoded == null) return null;
  final json = jsonDecode(decoded);
  if (json is! Map<String, dynamic>) return null;
  final name = (json['ps'] as String?) ?? '';
  final address = json['add'] as String?;
  final port = _asInt(json['port']);
  final id = json['id'] as String?;
  if (name.isEmpty || address == null || address.isEmpty || port == null || port <= 0 || id == null || id.isEmpty) {
    return null;
  }
  final tls = json['tls'] == 'tls';
  var sni = json['sni'] as String?;
  if (sni == null || sni.isEmpty) sni = json['host'] as String?;
  final network = (json['net'] as String?) ?? 'tcp';
  final wsHost = json['host'] as String?;
  return Node(
    name: name,
    protocol: NodeProtocol.vmess,
    address: address,
    port: port,
    source: _sourceFromName(name),
    uuidOrPassword: id,
    transport: network,
    tls: tls,
    sni: (sni == null || sni.isEmpty) ? null : sni,
    wsPath: _queryPath(json['path'] as String?),
    wsHost: (network == 'ws' || network == 'h2') && wsHost != null && wsHost.isNotEmpty ? wsHost : null,
    isPlainText: !tls,
  );
}

Node? _nodeFromSsLink(String link) {
  // 三种写法：ss://<base64(method:password@host:port)>#name、
  // ss://<base64(method:password)>@host:port#name、
  // ss://method:password@host:port#name。
  final withoutScheme = link.substring('ss://'.length);
  final hashIndex = withoutScheme.indexOf('#');
  final name = hashIndex >= 0
      ? _decodeComponentSafe(withoutScheme.substring(hashIndex + 1))
      : '';
  final body = hashIndex >= 0
      ? withoutScheme.substring(0, hashIndex)
      : withoutScheme;
  if (name.isEmpty || body.isEmpty) return null;
  String? method;
  String? password;
  String? host;
  int? port;
  final atIndex = body.lastIndexOf('@');
  if (atIndex >= 0) {
    final left = body.substring(0, atIndex);
    final right = body.substring(atIndex + 1);
    final hostPort = _splitHostPort(right);
    if (hostPort == null) return null;
    host = hostPort.$1;
    port = hostPort.$2;
    final leftDecoded = _tryBase64Decode(left) ?? _decodeComponentSafe(left);
    final colon = leftDecoded.indexOf(':');
    if (colon <= 0) return null;
    method = leftDecoded.substring(0, colon);
    password = leftDecoded.substring(colon + 1);
  } else {
    final decoded = _tryBase64Decode(body);
    if (decoded == null) return null;
    final at = decoded.lastIndexOf('@');
    if (at < 0) return null;
    final methodPass = decoded.substring(0, at);
    final colon = methodPass.indexOf(':');
    if (colon <= 0) return null;
    method = methodPass.substring(0, colon);
    password = methodPass.substring(colon + 1);
    final hostPort = _splitHostPort(decoded.substring(at + 1));
    if (hostPort == null) return null;
    host = hostPort.$1;
    port = hostPort.$2;
  }
  // 两条分支里 method/password/host/port 要么已赋值，要么已提前返回；
  // 这里只剩“空串 / 非正端口”的检查。
  if (method.isEmpty || password.isEmpty || host.isEmpty || port <= 0) {
    return null;
  }
  return Node(
    name: name,
    protocol: NodeProtocol.shadowsocks,
    address: host,
    port: port,
    source: _sourceFromName(name),
    uuidOrPassword: password,
    transport: 'tcp',
    tls: false,
    method: method,
    isPlainText: true,
  );
}

Node? _nodeFromHy2Link(String link) {
  final uri = Uri.tryParse(link);
  if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;
  final password = uri.userInfo.isEmpty
      ? null
      : _decodeComponentSafe(uri.userInfo);
  if (password == null || password.isEmpty) return null;
  final name = _linkName(uri);
  if (name.isEmpty) return null;
  final sni = uri.queryParameters['sni'];
  return Node(
    name: name,
    protocol: NodeProtocol.hysteria2,
    address: uri.host,
    port: uri.port,
    source: _sourceFromName(name),
    uuidOrPassword: password,
    transport: 'udp',
    tls: true,
    sni: (sni == null || sni.isEmpty) ? null : sni,
    isPlainText: false,
  );
}

Node? _nodeFromTuicLink(String link) {
  final uri = Uri.tryParse(link);
  if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;
  final userInfo = uri.userInfo.isEmpty
      ? null
      : _decodeComponentSafe(uri.userInfo);
  if (userInfo == null || userInfo.isEmpty) return null;
  final name = _linkName(uri);
  if (name.isEmpty) return null;
  final sni = uri.queryParameters['sni'];
  return Node(
    name: name,
    protocol: NodeProtocol.tuic,
    address: uri.host,
    port: uri.port,
    source: _sourceFromName(name),
    uuidOrPassword: userInfo,
    transport: 'udp',
    tls: true,
    sni: (sni == null || sni.isEmpty) ? null : sni,
    isPlainText: false,
  );
}

/// AnyTLS 链接（切片 10）：`anytls://<uuid>@<host>:<port>?sni=<域名>#<名字>`。
/// 凭证口径与 HY2/TUIC 一致：password 就是用户 UUID（见实施方案 §12
/// 切片 5 实施细化）；SNI 是入站域名。
Node? _nodeFromAnytlsLink(String link) {
  final uri = Uri.tryParse(link);
  if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;
  final password = uri.userInfo.isEmpty
      ? null
      : _decodeComponentSafe(uri.userInfo);
  if (password == null || password.isEmpty) return null;
  final name = _linkName(uri);
  if (name.isEmpty) return null;
  final sni = uri.queryParameters['sni'];
  return Node(
    name: name,
    protocol: NodeProtocol.anytls,
    address: uri.host,
    port: uri.port,
    source: _sourceFromName(name),
    uuidOrPassword: password,
    transport: 'tcp',
    tls: true,
    sni: (sni == null || sni.isEmpty) ? null : sni,
    isPlainText: false,
  );
}

/// SOCKS5 链接（切片 10）：`socks5://<用户名>:<密码>@<host>:<port>#<名字>`。
/// 用户名进 [Node.username]、密码进 `uuidOrPassword`；账号缺一半
/// （无用户名、无密码）时解析失败，不生成无认证的出站。
Node? _nodeFromSocks5Link(String link) {
  final uri = Uri.tryParse(link);
  if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;
  final userInfo = uri.userInfo.isEmpty
      ? null
      : _decodeComponentSafe(uri.userInfo);
  if (userInfo == null || userInfo.isEmpty) return null;
  final colon = userInfo.indexOf(':');
  if (colon <= 0) return null;
  final username = userInfo.substring(0, colon);
  final password = userInfo.substring(colon + 1);
  if (username.isEmpty || password.isEmpty) return null;
  final name = _linkName(uri);
  if (name.isEmpty) return null;
  return Node(
    name: name,
    protocol: NodeProtocol.socks5,
    address: uri.host,
    port: uri.port,
    source: _sourceFromName(name),
    uuidOrPassword: password,
    transport: 'tcp',
    tls: false,
    username: username,
    isPlainText: true,
  );
}

/// 空串当 null：可选字段统一用它归一化，避免空串进模型。
String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  return value.isEmpty ? null : value;
}

/// 节点名后缀决定来源：`-中转` → 中转，`-直连` → 直连；无后缀默认直连
/// （面板 sing-box/Clash 订阅的节点名都带后缀，见 panel-adapter.md §6）。
NodeSource _sourceFromName(String name) {
  if (name.endsWith('-中转')) return NodeSource.relay;
  if (name.endsWith('-直连')) return NodeSource.direct;
  return NodeSource.direct;
}

/// 链接 `#` 后面的名字（URL 解码；没有名字返回空串）。
String _linkName(Uri uri) {
  if (uri.fragment.isEmpty) return '';
  return _decodeComponentSafe(uri.fragment);
}

/// WS 路径：面板把 `/` 写成 `%2F` 时先解码；空串返回 null。
String? _queryPath(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return _decodeComponentSafe(raw);
}


/// 安全的 percent 解码：Uri.decodeComponent 碰到 raw 非 ASCII（如中文名字）
/// 会抛错，解不开就原样返回（名字里本就允许中文）。
String _decodeComponentSafe(String raw) {
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

/// 宽松 base64 解码：补齐 `=`、同时接受标准与 url-safe 两种字母表。
/// 解不出来返回 null。解出的内容须是合法 UTF-8 文本，否则也返回 null。
String? _tryBase64Decode(String input) {
  final cleaned = input.replaceAll(RegExp(r'\s'), '');
  if (cleaned.isEmpty) return null;
  try {
    final normalized = base64.normalize(
      cleaned.replaceAll('-', '+').replaceAll('_', '/'),
    );
    return utf8.decode(base64.decode(normalized));
  } catch (_) {
    return null;
  }
}

/// `host:port` 拆分；端口不是正整数返回 null。
(String, int)? _splitHostPort(String hostPort) {
  final colon = hostPort.lastIndexOf(':');
  if (colon <= 0) return null;
  final host = hostPort.substring(0, colon);
  final port = int.tryParse(hostPort.substring(colon + 1));
  if (host.isEmpty || port == null || port <= 0) return null;
  return (host, port);
}

/// int 或数字字符串 → int；其他返回 null。
int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  return null;
}
