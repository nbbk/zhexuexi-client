import 'dart:convert';

import 'custom_rule.dart';
import 'node_model.dart';
import 'routing_mode.dart';

/// 一次配置生成的结果。
class SingboxConfigResult {
  const SingboxConfigResult({required this.config, required this.skipped});

  /// 完整 sing-box 配置（可直接喂给核心）。
  final Map<String, dynamic> config;

  /// 生成时跳过的节点（`节点名：原因`），界面可提示“ N 个节点暂不支持”，
  /// 不要静默丢节点。
  final List<String> skipped;

  /// 配置 JSON 字符串。
  String toJsonString() => jsonEncode(config);
}

/// sing-box 配置生成器（切片 2）。
///
/// 约定（见 docs/api/panel-adapter.md §6、docs/mvp-slices.md 切片 2）：
/// - 只认统一节点模型 [Node]，不读面板下发的任何配置段：面板的 `dns` /
///   `route` / `inbounds` / 策略组一律不透传，DNS 与路由由客户端自己生成；
/// - DNS 自生成新格式（sing-box 1.14 已移除 legacy `address` 写法）：
///   DoH 双路（1.1.1.1 直连解析、dns.google 走代理）＋ DoT 8.8.8.8:853 兜底，
///   只解析 IPv4（`strategy: ipv4_only`），不回落明文 UDP 53；
/// - 路由规则与面板 §6.1.2 的域名清单对齐：TikTok / 社交 / 流媒体 /
///   测 IP 走 Proxy，`.cn` 直连，其余直连（规则模式）；全局与直连
///   模式见 [build] 的 `mode` 参数；
/// - 节点为空时仍是合法空配置（不断核心、不引用不存在的 Proxy 组）。
class SingboxConfigBuilder {
  /// 混合入站监听端口（与面板订阅的 mixed 入站一致）。
  static const int mixedPort = 2080;

  /// Clash API 监听地址（切片 3 首页实时速率与测速用）。
  static const String clashApiAddress = '127.0.0.1:9090';

  /// TikTok 后缀组（8 个，见 panel-adapter.md §6.1.2）。
  static const List<String> tiktokSuffixes = [
    'tiktok.com',
    'tiktokv.com',
    'tiktokcdn.com',
    'tiktokcdn-us.com',
    'musical.ly',
    'byteoversea.com',
    'ibytedtos.com',
    'isnssdk.com',
  ];

  /// 社交后缀组（26 个，仅 route 规则用，不进 DNS 规则）。
  static const List<String> socialSuffixes = [
    'facebook.com',
    'fb.com',
    'fbcdn.net',
    'instagram.com',
    'cdninstagram.com',
    'x.com',
    'twitter.com',
    'twimg.com',
    'whatsapp.com',
    'whatsapp.net',
    'telegram.org',
    't.me',
    'snapchat.com',
    'scdn.co',
    'reddit.com',
    'redditmedia.com',
    'redditstatic.com',
    'pinterest.com',
    'pinimg.com',
    'linkedin.com',
    'licdn.com',
    'discord.com',
    'discordapp.com',
    'discord.gg',
    'threads.net',
    'line.me',
  ];

  /// 流媒体后缀组（25 个，仅 route 规则用，不进 DNS 规则）。
  static const List<String> streamSuffixes = [
    'youtube.com',
    'googlevideo.com',
    'ytimg.com',
    'youtu.be',
    'netflix.com',
    'nflxvideo.net',
    'nflxext.com',
    'nflxso.net',
    'disneyplus.com',
    'dssott.com',
    'hulu.com',
    'huluim.com',
    'max.com',
    'hbomax.com',
    'hbo.com',
    'primevideo.com',
    'amazonvideo.com',
    'aiv-cdn.net',
    'tv.apple.com',
    'spotify.com',
    'scdn.co',
    'spotifycdn.com',
    'twitch.tv',
    'twitchcdn.net',
    'jtvnw.net',
  ];

  /// 测 IP 后缀组（15 个，route 与 DNS 规则都用）。
  static const List<String> ipCheckSuffixes = [
    'www.cloudflare.com',
    'api.ip.sb',
    'ipinfo.io',
    'ipwho.is',
    'get.geojs.io',
    'api.country.is',
    'api.ipquery.io',
    'ident.me',
    'ipapi.co',
    'api.ipapi.is',
    'ip.api.skk.moe',
    'api.internetdata.io',
    'ifconfig.co',
    'api.myip.com',
    'ip-api.com',
  ];

  /// DNS 配置摘要（设置页“DNS 配置查看”直接渲染这份，不另写一份
  /// 文案：两处写同一份 DNS 说明迟早会写岔）。
  ///
  /// 防泄漏是固定行为不是开关：DNS 只走 DoH / DoT，不回落明文
  /// UDP 53；摘要最后一行写明“不可关闭”，设置页不给关掉它的入口。
  static const List<({String label, String value})> dnsSummary = [
    (label: '直连解析', value: 'DoH https://1.1.1.1/dns-query'),
    (label: '代理 DNS', value: 'DoH https://dns.google/dns-query（经代理出站）'),
    (label: '兜底', value: 'DoT 8.8.8.8:853'),
    (label: '解析策略', value: '仅 IPv4（ipv4_only）'),
    (label: '明文 UDP 53', value: '不回落（无 UDP 服务器）'),
    (label: '防泄漏', value: '已开启，不可关闭'),
  ];

/// 从节点列表生成完整 sing-box 配置。
///
/// [mode] 只改 route 段与 DNS 规则的解析路径，不改节点出站：
/// - 规则模式：TikTok / 社交 / 流媒体 / 测 IP → Proxy，`.cn` → direct，
///   其余直连（route.final = direct）；DNS 规则：`.cn` 直连解析，
///   TikTok 与测 IP 走代理 DNS；
/// - 全局模式：route 无规则，final = 有节点时 `Proxy`、无节点时 `direct`
///   （无节点时没有 Proxy 组，final 不能指不存在的出站）；DNS 规则
///   全部走代理 DNS（有节点时经 detour Proxy，无节点时 dns-proxy 无
///   detour、服务器用 IP 8.8.8.8，与空配置规则一致）；
/// - 直连模式：route 无规则，final = direct；DNS 规则全部走直连解析，
///   不让任何 DNS 查询经代理出站（否则“全部直连”名不副实）。
///
/// [selectedNodeName]（切片 4）：selector `Proxy` 的默认出站。
/// 给了且该节点在配置里时用它；没给、名字不在列表里、或该节点
/// 生成时被跳过时，回落到默认规则（第一个直连节点，没有时第一个）。
/// 注意这里认的是节点名不是 tag：重名节点加 ` (2)` 后缀的去重
/// 在生成时做，调用方不用自己算 tag。
///
/// [customRules]（切片 6）：用户自定义规则（只取已启用的），按
/// 动作插在内置规则前面（先命中先走，用户规则优先）：走代理的域
/// 名 → `Proxy`，直连的域名 → `direct`；DNS 规则同样插在前面
/// （走代理的域名走 `dns-proxy`，直连的域名走 `dns-direct`），
/// 三种模式都生效（全局模式下自定义直连是唯一的例外口，直连模式
/// 下自定义代理是唯一的例外口）。没有节点时走代理的自定义规则
/// 不进配置（没有 `Proxy` 组可指），直连的照常进。
///
/// [tunEnabled]（切片 6）：为 true 时加一条 `tun` 入站（系统级
/// TUN 接管流量，gvisor 栈 + 自动路由）；为 false 时不写 tun 入站。
/// TUN 只改入站，不改出站与规则。
///
/// 同节点多入站 fallback 组（切片 10）：备注名 `<节点名>-<入站 tag>`
/// 归组，≥2 个入站的组出一个 urltest 组（组名就是节点名，成员是该
/// 节点各入站的出站 tag），selector 里该节点只占组 tag 一位，组内
/// 由 urltest 健康检查自动切入站；单个入站的节点不成组。'自动选择'
/// 仍列全部节点自己的 tag。
static SingboxConfigResult build(
  List<Node> nodes, {
  RoutingMode mode = RoutingMode.rule,
  String? selectedNodeName,
  List<CustomRule> customRules = const [],
  bool tunEnabled = false,
}) {
    final skipped = <String>[];
    final outbounds = <Map<String, dynamic>>[];
    final usedTags = <String>{};
    final nodeTags = <String>[];
    final keptNodes = <Node>[];

    for (final node in nodes) {
      final tag = _uniqueTag(node.name, usedTags);
      final outbound = _nodeOutbound(node, tag);
      if (outbound == null) {
        skipped.add('${node.name}：${_skipReason(node)}');
        continue;
      }
      usedTags.add(tag);
      nodeTags.add(tag);
      keptNodes.add(node);
      outbounds.add(outbound);
    }

    // 同节点多入站 fallback 组（切片 10，见契约）：备注名
    // `<节点名>-<入站 tag>` 归组，同一节点名的多个入站为一组，每组
    // 一个 urltest 组，组名就是节点名；只有 ≥2 个入站的组才建组
    // （单个入站的节点不需要组，直接进 selector）。
    // selector 里成组节点只占组 tag 一位（按节点顺序首次出现的位置），
    // 组内由 urltest 健康检查自动切入站；未成组节点占自己的 tag。
    // '自动选择' 仍列全部节点自己的 tag（原有行为，不动）。
    final groupMembers = <String, List<int>>{};
    for (var i = 0; i < keptNodes.length; i++) {
      final group = _groupName(keptNodes[i].name);
      if (group == null) continue;
      groupMembers.putIfAbsent(group, () => []).add(i);
    }
    groupMembers.removeWhere((_, members) => members.length < 2);
    // 每个节点在 selector 里的成员 tag：成组的是组 tag，否则是自己的 tag。
    final memberTagByIndex = List<String>.generate(
      keptNodes.length,
      (i) => nodeTags[i],
    );
    for (final entry in groupMembers.entries) {
      // 组 tag 与出站 tag 同一套去重，避免组名撞上节点名。
      final groupTag = _uniqueTag(entry.key, usedTags);
      usedTags.add(groupTag);
      for (final i in entry.value) {
        memberTagByIndex[i] = groupTag;
      }
      outbounds.add({
        'type': 'urltest',
        'tag': groupTag,
        'outbounds': entry.value.map((i) => nodeTags[i]).toList(),
        'url': 'http://www.gstatic.com/generate_204',
        'interval': '5m',
      });
    }

    if (nodeTags.isNotEmpty) {
      // selector 成员：成组节点只占组 tag 一位，未成组节点占自己的 tag。
      final selectorOutbounds = <String>[];
      for (var i = 0; i < keptNodes.length; i++) {
        final member = memberTagByIndex[i];
        if (!selectorOutbounds.contains(member)) {
          selectorOutbounds.add(member);
        }
      }
      // selector 默认选第一个直连节点，没有直连节点时取第一个节点（面板规则）；
      // 选中的节点成组时默认就是组 tag（组内再自动选入站）。
      final defaultTag = _defaultNodeTag(
        keptNodes,
        memberTagByIndex,
        selectedNodeName: selectedNodeName,
      );
      outbounds.add({
        'type': 'selector',
        'tag': 'Proxy',
        'outbounds': selectorOutbounds,
        'default': defaultTag,
      });
      outbounds.add({
        'type': 'urltest',
        'tag': '自动选择',
        'outbounds': nodeTags,
        'url': 'http://www.gstatic.com/generate_204',
        'interval': '5m',
      });
    }
    outbounds.add({'type': 'direct', 'tag': 'direct'});
    outbounds.add({'type': 'block', 'tag': 'block'});

    // route 规则与 final 按模式走（见 build 的文档注释）。
    final routeRules = <Map<String, dynamic>>[];
    // 自定义规则插在最前面（先命中先走，用户规则优先于内置规则）；
    // 走代理的规则没有节点时不进（没有 Proxy 组可指），直连的照常进。
    for (final rule in customRules) {
      if (!rule.enabled) continue;
      if (rule.action == CustomRuleAction.proxy &&
          nodeTags.isEmpty) {
        continue;
      }
      routeRules.add({
        'domain_suffix': [rule.domain],
        'outbound': rule.action == CustomRuleAction.proxy
            ? 'Proxy'
            : 'direct',
      });
    }
    final String routeFinal;
    switch (mode) {
      case RoutingMode.rule:
        if (nodeTags.isNotEmpty) {
          routeRules.add({
            'domain_suffix': tiktokSuffixes,
            'outbound': 'Proxy',
          });
          routeRules.add({
            'domain_suffix': socialSuffixes,
            'outbound': 'Proxy',
          });
          routeRules.add({
            'domain_suffix': streamSuffixes,
            'outbound': 'Proxy',
          });
          routeRules.add({
            'domain_suffix': ipCheckSuffixes,
            'outbound': 'Proxy',
          });
        }
        routeRules.add({
          'domain_suffix': ['.cn'],
          'outbound': 'direct',
        });
        routeFinal = 'direct';
      case RoutingMode.global:
        // 全部走代理：无规则，final 指 Proxy；无节点时没有 Proxy 组，
        // final 回落 direct（不断核心）。
        routeFinal = nodeTags.isNotEmpty ? 'Proxy' : 'direct';
      case RoutingMode.direct:
        // 全部直连：无规则，final = direct。
        routeFinal = 'direct';
    }

    // DNS 规则的解析路径按模式走：规则模式 `.cn` 直连解析、TikTok 与
    // 测 IP 走代理 DNS；全局模式全部走代理 DNS；直连模式全部走直连解析。
    final String cnDnsServer = mode == RoutingMode.global
        ? 'dns-proxy'
        : 'dns-direct';
    final String proxyDnsServer = mode == RoutingMode.direct
        ? 'dns-direct'
        : 'dns-proxy';

    // 自定义规则的 DNS 映射插在最前面（只按动作分，不按模式分：
    // 用户明确说走代理的域名就走代理 DNS、说直连的就走直连 DNS，
    // 哪怕当前是全局或直连模式——那正是自定义规则存在的意义）。
    // 走代理的自定义规则没有节点时同样不进（dns-proxy 的 detour
    // 指不到 Proxy 组；无节点时 dns-proxy 的 server 是 IP 8.8.8.8，
    // 规则写进去也不会炸，但解析路径会与 route 不一致，故跳过）。
    final dnsRules = <Map<String, dynamic>>[];
    for (final rule in customRules) {
      if (!rule.enabled) continue;
      if (rule.action == CustomRuleAction.proxy &&
          nodeTags.isEmpty) {
        continue;
      }
      dnsRules.add({
        'domain_suffix': [rule.domain],
        'server': rule.action == CustomRuleAction.proxy
            ? 'dns-proxy'
            : 'dns-direct',
      });
    }
    dnsRules.addAll([
      {
        'domain_suffix': ['.cn'],
        'server': cnDnsServer,
      },
      {
        'domain_suffix': tiktokSuffixes,
        'server': proxyDnsServer,
      },
      {
        'domain_suffix': ipCheckSuffixes,
        'server': proxyDnsServer,
      },
    ]);

    return SingboxConfigResult(
      skipped: skipped,
      config: {
        'log': {'level': 'info'},
        'dns': {
          'servers': [
            {
              'tag': 'dns-direct',
              'type': 'https',
              'server': '1.1.1.1',
              'server_port': 443,
              'path': '/dns-query',
              // 直连解析不写 detour：detour 指到 direct 出站时 1.14.4
              // 启动即报 "detour to an empty direct outbound makes no
              // sense"（真机 1.14.4 run 实测）；不写 detour 默认就是直连。
            },
            {
              'tag': 'dns-proxy',
              'type': 'https',
              // 有节点时走域名 dns.google（经 detour Proxy 解析）；节点
              // 为空时没有 detour，域名地址在启动时无人解析（1.14.4 报
              // "missing domain resolver for domain server address"），
              // 改用 IP 8.8.8.8。
              'server': nodeTags.isNotEmpty ? 'dns.google' : '8.8.8.8',
              'server_port': 443,
              'path': '/dns-query',
              // 代理 DNS 走 selector 出站。注意 detour 填的是出站 tag，
              // 必须与 selector 的 tag `Proxy` 逐字一致；面板 1.3.37
              // 写的是小写 `proxy`，没有这个 tag 的出站，run 时报
              // "outbound detour not found: proxy"。节点为空时没有
              // Proxy 组，detour 也不写。
              if (nodeTags.isNotEmpty) 'detour': 'Proxy',
            },
            {
              'tag': 'dns-dot',
              'type': 'tls',
              'server': '8.8.8.8',
              'server_port': 853,
              // DoT 兜底走直连，同样不写 detour。
            },
          ],
          'rules': dnsRules,
          // sing-box 没有 DNS 服务器间的自动故障转移；DoT 服务器挂在 final
          // 上当兜底：规则都不命中时走 DoT 直连解析。
          'final': 'dns-dot',
          // 只解析 IPv4，不回落明文 UDP 53（无 udp 服务器）。
          'strategy': 'ipv4_only',
        },
        'inbounds': [
          {
            'type': 'mixed',
            'tag': 'mixed-in',
            'listen': '127.0.0.1',
            'listen_port': mixedPort,
          },
          // TUN 入站（切片 6，tunEnabled 时才写）：系统级 TUN 接管
          // 流量，gvisor 栈 + 自动路由；不写时就是原来的 mixed 入站。
          // 注意 run 冒烟只跑 tun 关闭的配置：tun 入站启动时要建
          // TUN 设备，没权限的机器上会失败，真机再验。
          if (tunEnabled)
            {
              'type': 'tun',
              'tag': 'tun-in',
              'interface_name': 'tun0',
              'mtu': 9000,
              'address': '172.19.0.1/30',
              'auto_route': true,
              'strict_route': true,
              'stack': 'gvisor',
            },
        ],
        'outbounds': outbounds,
        'route': {
          'rules': routeRules,
          'final': routeFinal,
          'default_domain_resolver': 'dns-direct',
        },
        'experimental': {
          'clash_api': {
            'external_controller': clashApiAddress,
            'secret': '',
          },
        },
      },
    );
  }

  /// 节点名去重：重名加 ` (2)` / ` (3)`……（面板订阅的同名改写规则）。
  static String _uniqueTag(String name, Set<String> used) {
    if (!used.contains(name)) return name;
    var i = 2;
    while (used.contains('$name ($i)')) {
      i++;
    }
    return '$name ($i)';
  }

  /// selector 的默认节点：[selectedNodeName] 给了且在配置里时用它；
  /// 否则第一个直连节点，没有直连节点时取第一个节点。
  /// [keptNodes] 与 [nodeTags] 一一对应（跳过的节点不在其中）。
  static String _defaultNodeTag(
    List<Node> keptNodes,
    List<String> nodeTags, {
    String? selectedNodeName,
  }) {
    if (selectedNodeName != null) {
      for (var i = 0; i < keptNodes.length; i++) {
        if (keptNodes[i].name == selectedNodeName) return nodeTags[i];
      }
    }
    for (var i = 0; i < keptNodes.length; i++) {
      if (keptNodes[i].source == NodeSource.direct) return nodeTags[i];
    }
    return nodeTags.first;
  }

  /// 默认节点名（与 selector 默认选择同一条规则）：第一个直连节点，
  /// 没有直连节点时取第一个能生成出站的节点，都没有时返回 null。
  /// 首页“当前节点”与节点页“使用中”都认这个，不各写各的规则。
  static String? defaultNodeName(List<Node> nodes) {
    Node? first;
    for (final node in nodes) {
      if (_nodeOutbound(node, node.name) == null) continue;
      first ??= node;
      if (node.source == NodeSource.direct) return node.name;
    }
    return first?.name;
  }

  /// 节点在配置里的出站 tag（测速与切换认这个 tag，不是节点名）；
  /// 该节点生成时会被跳过（未知协议、缺 UUID、grpc 等）时返回 null，
  /// 测速方把它当“测速失败”标灰，不要拿名字去调 delay 接口
  /// （核心里根本没有这个出站，调了也只是 404）。
  ///
  /// 去重规则与 [build] 完全一致（重名加 ` (2)` 后缀，按列表顺序），
  /// 所以同一个列表算出来的 tag 与配置里的 tag 一一对应。
  /// [target] 必须是 [nodes] 里的同一个对象（按 identity 认）。
  ///
  /// 注意：返回的是节点自己的出站 tag，不是它所属的 fallback 组 tag
  /// （成组节点在 selector 里占组 tag 一位，见 [build]）；测速调
  /// delay 接口必须用节点自己的 tag，组 tag 没有 delay 数据。
  static String? tagForNode(List<Node> nodes, Node target) {
    final usedTags = <String>{};
    for (final node in nodes) {
      final tag = _uniqueTag(node.name, usedTags);
      if (_nodeOutbound(node, tag) == null) continue;
      usedTags.add(tag);
      if (identical(node, target)) return tag;
    }
    return null;
  }

  /// 单个节点转出站；转不了返回 null（原因见 [_skipReason]）。
  static Map<String, dynamic>? _nodeOutbound(Node node, String tag) {
    final credential = node.uuidOrPassword;
    if (credential == null || credential.isEmpty) return null;
    // VLESS/VMess/Trojan 用传输对象；grpc 暂不支持（节点模型没有
    // service_name），不要静默当成裸 TCP——直接跳过节点。
    if ((node.protocol == NodeProtocol.vless ||
            node.protocol == NodeProtocol.vmess ||
            node.protocol == NodeProtocol.trojan) &&
        !_transportSupported(node)) {
      return null;
    }
    return switch (node.protocol) {
      NodeProtocol.vless => {
        'type': 'vless',
        'tag': tag,
        'server': node.address,
        'server_port': node.port,
        'uuid': credential,
        if (node.flow != null) 'flow': node.flow,
        'tls': ?_tlsObjectOrNull(node),
        'transport': ?_transportObject(node),
      },
      NodeProtocol.vmess => {
        'type': 'vmess',
        'tag': tag,
        'server': node.address,
        'server_port': node.port,
        'uuid': credential,
        'alter_id': 0,
        'security': 'auto',
        'tls': ?_tlsObjectOrNull(node),
        'transport': ?_transportObject(node),
      },
      NodeProtocol.trojan => {
        'type': 'trojan',
        'tag': tag,
        'server': node.address,
        'server_port': node.port,
        'password': credential,
        'tls': ?_tlsObjectOrNull(node),
        'transport': ?_transportObject(node),
      },
      NodeProtocol.shadowsocks => node.method == null
          ? null
          : {
              'type': 'shadowsocks',
              'tag': tag,
              'server': node.address,
              'server_port': node.port,
              'method': node.method,
              'password': credential,
            },
      NodeProtocol.hysteria2 => {
        'type': 'hysteria2',
        'tag': tag,
        'server': node.address,
        'server_port': node.port,
        'password': credential,
        // HY2 强制 TLS，节点模型里 tls 恒为 true；这里不依赖 node.tls。
        'tls': _tlsObject(node),
      },
      NodeProtocol.tuic => _tuicOutbound(node, tag, credential),
      // AnyTLS（切片 10，契约形状）：password 就是用户 UUID，TLS 只开
      // enabled + server_name（入站域名）。
      NodeProtocol.anytls => {
        'type': 'anytls',
        'tag': tag,
        'server': node.address,
        'server_port': node.port,
        'password': credential,
        'tls': _tlsObject(node),
      },
      // SOCKS5（切片 10，契约形状）：用户名 + 密码，version 固定 "5"。
      NodeProtocol.socks5 => node.username == null
          ? null
          : {
              'type': 'socks',
              'tag': tag,
              'server': node.address,
              'server_port': node.port,
              'version': '5',
              'username': node.username,
              'password': credential,
            },
      NodeProtocol.unknown => null,
    };
  }

  static Map<String, dynamic>? _tuicOutbound(
    Node node,
    String tag,
    String credential,
  ) {
    // TUIC 链接的 userInfo 是 `uuid:password`，拆不开的跳过。
    final colon = credential.indexOf(':');
    if (colon <= 0) return null;
    return {
      'type': 'tuic',
      'tag': tag,
      'server': node.address,
      'server_port': node.port,
      'uuid': credential.substring(0, colon),
      'password': credential.substring(colon + 1),
      'tls': _tlsObject(node),
    };
  }

  /// TLS 对象；不启用 TLS 时返回 null（配合 null-aware 入口省略该键）。
  /// REALITY 节点（realityPublicKey 非空）一定走 REALITY tls 块，
  /// 不依赖 node.tls（解析器对 security=reality 本来就会置 tls=true，
  /// 这里再兜底一次，避免手工构造的节点漏写 tls 标志就丢了 reality 块）。
  static Map<String, dynamic>? _tlsObjectOrNull(Node node) {
    if (node.realityPublicKey != null) return _realityTlsObject(node);
    return node.tls ? _tlsObject(node) : null;
  }

  /// REALITY tls 块（切片 10，实施方案 §8.2 一字不差）：
  /// server_name 是 SNI 目标，utls 指纹缺省 `chrome`，reality 块带
  /// 公钥与 short id。
  static Map<String, dynamic> _realityTlsObject(Node node) {
    final tls = <String, dynamic>{'enabled': true};
    if (node.sni != null && node.sni!.isNotEmpty) {
      tls['server_name'] = node.sni;
    }
    tls['utls'] = {
      'enabled': true,
      'fingerprint': node.fingerprint ?? 'chrome',
    };
    tls['reality'] = {
      'enabled': true,
      'public_key': node.realityPublicKey,
      if (node.realityShortId != null) 'short_id': node.realityShortId,
    };
    return tls;
  }

  /// TLS 对象：有 SNI 时写 server_name，没有时只开 enabled。
  static Map<String, dynamic> _tlsObject(Node node) {
    final tls = <String, dynamic>{'enabled': true};
    if (node.sni != null && node.sni!.isNotEmpty) {
      tls['server_name'] = node.sni;
    }
    return tls;
  }

  /// 传输对象：tcp 不用写；ws / h2（HTTP/2）按 sing-box 字段写。
  /// 不支持的传输（grpc 等）返回 null，调用方 [_nodeOutbound] 已提前
  /// 把这类节点跳过，不会走到这里。
  static Map<String, dynamic>? _transportObject(Node node) {
    return switch (node.transport.toLowerCase()) {
      'tcp' => null,
      'ws' => {
        'type': 'ws',
        if (node.wsPath != null) 'path': node.wsPath,
        if (node.wsHost != null)
          'headers': {'Host': node.wsHost},
      },
      'h2' => {
        'type': 'http',
        if (node.wsHost != null) 'host': node.wsHost,
        if (node.wsPath != null) 'path': node.wsPath,
      },
      _ => null,
    };
  }

  /// 该节点的传输方式是否受支持（grpc 暂不支持：节点模型没有 service_name）。
  static bool _transportSupported(Node node) {
    return switch (node.transport.toLowerCase()) {
      'tcp' || 'ws' || 'h2' => true,
      _ => false,
    };
  }

  /// 同节点多入站的组名（切片 10）：备注名 `<节点名>-<入站 tag>` 里去掉
  /// 末尾的入站 tag（以后端入站 tag 为准：reality-443、xhttp-443、
  /// hy2-443、tuic-443、anytls-443、ss-8388、ss2022-*、socks-1080 等，
  /// 另含 trojan/vless/vmess 以备面板以后按同规矩起名）。
  /// 不带入站 tag 后缀的名字不成组，返回 null（例如 `智利-直连`）。
  static String? _groupName(String name) {
    final match = _inboundTagSuffix.firstMatch(name);
    if (match == null) return null;
    final group = match.group(1)!;
    return group.isEmpty ? null : group;
  }

  static final _inboundTagSuffix = RegExp(
    r'^(.+)-(ss2022|reality|xhttp|hy2|tuic|anytls|trojan|vless|vmess|ss|socks)-(.+)$',
  );

  /// 跳过原因（与 [_nodeOutbound] 的 null 分支一一对应）。
  static String _skipReason(Node node) {
    if (node.protocol == NodeProtocol.unknown) return '未知协议';
    if (node.uuidOrPassword == null || node.uuidOrPassword!.isEmpty) {
      return '缺少 UUID 或密码';
    }
    if (node.protocol == NodeProtocol.shadowsocks && node.method == null) {
      return '缺少加密方式';
    }
    if (node.protocol == NodeProtocol.socks5 && node.username == null) {
      return '缺少 SOCKS5 用户名';
    }
    if (node.protocol == NodeProtocol.tuic &&
        !node.uuidOrPassword!.contains(':')) {
      return 'TUIC 账号格式不对';
    }
    if (!_transportSupported(node)) return '不支持的传输方式 ${node.transport}';
    return '无法生成出站';
  }
}
