/// 统一节点模型。
///
/// 不管订阅是 sing-box JSON、Clash YAML 还是 base64，也不管面板是 relay、
/// Xboard 还是 V2board，解析后都变成同一个 [Node]。界面、测速、核心配置
/// 生成只认这个模型，面板差异只留在适配层（见客户端方案 §5.2）。
/// 阶段 0 只定模型与解析入口，解析器在阶段 1 按格式逐个实现。
enum NodeProtocol {
  vless,
  vmess,
  trojan,
  shadowsocks,
  hysteria2,
  tuic,
  anytls,
  socks5,
  unknown,
}

extension NodeProtocolLabel on NodeProtocol {
  String get label => switch (this) {
        NodeProtocol.vless => 'VLESS',
        NodeProtocol.vmess => 'VMess',
        NodeProtocol.trojan => 'Trojan',
        NodeProtocol.shadowsocks => 'SS',
        NodeProtocol.hysteria2 => 'Hysteria2',
        NodeProtocol.tuic => 'TUIC',
        NodeProtocol.anytls => 'AnyTLS',
        NodeProtocol.socks5 => 'SOCKS5',
        NodeProtocol.unknown => '未知',
      };

  /// 圆圈里的协议简称：最多 3 个字符，放得进 44px 圆圈、不折行、
  /// 不溢出（全名太长，Hysteria2/SOCKS5 会溢出圆圈）。全名在
  /// 详情页里显示（见 node_detail_page.dart）。
  String get shortLabel => switch (this) {
        NodeProtocol.vless => 'VL',
        NodeProtocol.vmess => 'VM',
        NodeProtocol.trojan => 'TR',
        NodeProtocol.shadowsocks => 'SS',
        NodeProtocol.hysteria2 => 'HY2',
        NodeProtocol.tuic => 'TU',
        NodeProtocol.anytls => 'AT',
        NodeProtocol.socks5 => 'SK',
        NodeProtocol.unknown => '?',
      };

  static NodeProtocol fromString(String value) => switch (value
      .toLowerCase()) {
        'vless' => NodeProtocol.vless,
        'vmess' => NodeProtocol.vmess,
        'trojan' => NodeProtocol.trojan,
        'ss' || 'shadowsocks' => NodeProtocol.shadowsocks,
        'hysteria2' || 'hy2' => NodeProtocol.hysteria2,
        'tuic' => NodeProtocol.tuic,
        'anytls' => NodeProtocol.anytls,
        'socks' || 'socks5' => NodeProtocol.socks5,
        _ => NodeProtocol.unknown,
      };
}

/// 节点来源：中转节点走中转机，直连节点直连落地。
enum NodeSource { relay, direct }

class Node {
  Node({
    required this.name,
    required this.protocol,
    required this.address,
    required this.port,
    required this.source,
    this.uuidOrPassword,
    this.transport = 'tcp',
    this.tls = false,
    this.sni,
    this.wsPath,
    this.wsHost,
    this.method,
    this.group,
    this.isPlainText = false,
    this.username,
    this.realityPublicKey,
    this.realityShortId,
    this.fingerprint,
    this.flow,
    this.alpn,
    this.congestionControl,
    this.subscriptionId,
    this.subscriptionName,
    this.originDedupKey,
  });

  /// 显示名（订阅里的节点名；旧后缀 -中转/-直连，面板 1.4.25 起
  /// twin 双链接用 -A（直连）/-B（中转）后缀区分）。
  final String name;

  final NodeProtocol protocol;

  /// 落地或中转地址（不含协议与端口）。
  final String address;

  final int port;

  final NodeSource source;

  /// UUID（VLESS/VMess/Trojan）或密码（SS/HY2/TUIC）；界面上默认打码。
  final String? uuidOrPassword;

  /// 传输方式：ws / tcp / grpc / h2 等。
  final String transport;

  /// 是否 TLS。
  final bool tls;

  /// TLS SNI（证书域名）。
  final String? sni;

  /// WebSocket 路径。
  final String? wsPath;

  /// WebSocket Host 头（面板 sing-box JSON 的 transport.headers.Host、
  /// Clash 的 ws-opts.headers.Host、链接的 host 参数；没有时不写）。
  final String? wsHost;

  /// Shadowsocks 加密方式（如 aes-256-gcm；VLESS/VMess/Trojan 不用）。
  final String? method;

  /// 分组名（面板分组只决定包含哪些落地，订阅正文里没有分组名）。
  final String? group;

  /// 明文节点（无 TLS）：详情页显示“明文”，节点行上不再标角标。
  final bool isPlainText;

  /// SOCKS5 用户名（uuidOrPassword 存密码；其余协议不用）。
  final String? username;

  /// REALITY 公钥（链接 `pbk` 参数 / sing-box `tls.reality.public_key` /
  /// Clash `reality-opts.public-key`）；非空即该 VLESS 节点走 REALITY。
  final String? realityPublicKey;

  /// REALITY short id（链接 `sid` 参数 / `tls.reality.short_id` /
  /// Clash `reality-opts.short-id`）。
  final String? realityShortId;

  /// TLS 指纹（链接 `fp` 参数 / sing-box `tls.utls.fingerprint` /
  /// Clash `fingerprint`；缺省时配置生成按 `chrome` 写）。
  final String? fingerprint;

  /// VLESS flow（链接 `flow` 参数，如 `xtls-rprx-vision`；没有时不写）。
  final String? flow;

  /// TLS ALPN（如 `h3`，HY2/TUIC 链接的 `alpn` 参数 / sing-box
  /// `tls.alpn` / Clash `alpn`）；配置生成时写回 `tls.alpn`。
  final String? alpn;

  /// 拥塞控制（如 `bbr`，TUIC 链接的 `congestion_control` 参数 /
  /// sing-box `congestion_control` / Clash `congestion-controller`）；
  /// 配置生成时写回 TUIC 出站的 `congestion_control`。
  final String? congestionControl;

  /// 多订阅：这条节点来自哪个订阅（合并时赋值；单订阅的老数据为 null）。
  final String? subscriptionId;

  /// 多订阅：来源订阅的显示名（节点页来源小标签用）。
  final String? subscriptionName;

  /// 本地改动所基于的原始去重键（见 node_override_store.dart）：
  /// 有本地改动时是改动前节点的 [dedupKey]，刷新后凭它找回覆盖；
  /// 没改动时为 null。不参与 [dedupKey] 计算。
  final String? originDedupKey;

  /// 去重键：节点内容相同即同一条（名字不同也算同一条，去重只看内容，
  /// 不看名字与订阅来源）。多订阅合并时内容相同的只留第一条。
  String get dedupKey => [
        protocol.name,
        address,
        port.toString(),
        uuidOrPassword ?? '',
        sni ?? '',
        transport,
        wsPath ?? '',
        method ?? '',
        realityPublicKey ?? '',
        flow ?? '',
        username ?? '',
        alpn ?? '',
        congestionControl ?? '',
      ].join('|');

  /// 测速延迟（毫秒）；null 表示未测速。
  ///
  /// 开关开着时是 Clash API 测的走代理的延迟，关着时是直连探测到服务器
  /// 的延迟（见 direct_ping.dart）：两种口径不同，不能直接比。
  int? latencyMs;

  /// 测速失败（核心里没有该出站、超时、目标不可达等）；
  /// 与 [latencyMs] 为 null 的“未测速”区分开：失败的节点标灰、
  /// 不自动选，未测速的只显示“未测速”。
  bool latencyFailed = false;

  /// 测速失败的原因（给用户看的短句，如“超时不可达”“连接失败”，
  /// 节点行 tooltip 与测速汇总用）；未失败、或失败原因未知
  /// （走代理测速只回成功/失败、不分原因）时为 null。
  String? latencyFailureReason;

  @override
  String toString() =>
      'Node($name, ${protocol.label}, $address:$port, ${source.name})';
}
