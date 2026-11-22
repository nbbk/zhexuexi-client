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
        NodeProtocol.unknown => '未知',
      };

  static NodeProtocol fromString(String value) => switch (value
      .toLowerCase()) {
        'vless' => NodeProtocol.vless,
        'vmess' => NodeProtocol.vmess,
        'trojan' => NodeProtocol.trojan,
        'ss' || 'shadowsocks' => NodeProtocol.shadowsocks,
        'hysteria2' || 'hy2' => NodeProtocol.hysteria2,
        'tuic' => NodeProtocol.tuic,
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
  });

  /// 显示名（订阅里的节点名；中转节点名以“-中转”结尾，直连以“-直连”结尾）。
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

  /// 明文节点（无 TLS）：节点页上标“明文”角标。
  final bool isPlainText;

  /// 测速延迟（毫秒）；null 表示未测速。
  int? latencyMs;

  /// 测速失败（核心里没有该出站、超时、目标不可达等）；
  /// 与 [latencyMs] 为 null 的“未测速”区分开：失败的节点标灰、
  /// 不自动选，未测速的只显示“未测速”。
  bool latencyFailed = false;

  @override
  String toString() =>
      'Node($name, ${protocol.label}, $address:$port, ${source.name})';
}
