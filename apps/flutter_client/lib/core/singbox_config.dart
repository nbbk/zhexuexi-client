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
///   DoH 双路（223.5.5.5 直连解析、8.8.8.8 经代理出站），只解析 IPv4
///   （`strategy: ipv4_only`），不回落明文 UDP 53；
///   两台服务器都必须写 IP、不能写域名：域名要先经
///   `default_domain_resolver` 解析才能建连，直连解析一死、代理
///   DNS 跟着死（2026-11-26 根因：`dns.google` 的引导解析依赖
///   直连 1.1.1.1，国内直连境外解析被拦，代理 DNS 从未成功过）；
///   直连解析不用 1.1.1.1（国内直连被拦），用阿里云 223.5.5.5；
/// - 路由规则与面板 §6.1.2 的域名清单对齐：TikTok / 社交 / 流媒体 /
///   测 IP / Google 基础域走 Proxy，`.cn` 直连，其余直连（规则模式）；全局与直连
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

  /// Google 基础域后缀组（20 个，2026-11-26 0.1.2 根因 R2 补齐：
  /// 清单里缺 Google 基础域，测速地址 www.gstatic.com 与
  /// Google 服务域名在规则模式下落到 final=direct 直连被墙；
  /// route 与 DNS 规则里与现有 4 组并列各加一条）。
  static const List<String> googleInfraSuffixes = [
    'google.com',
    'googleapis.com',
    'gstatic.com',
    'ggpht.com',
    'googleusercontent.com',
    'gvt1.com',
    'gvt2.com',
    'gvt3.com',
    'play.google.com',
    'accounts.google.com',
    'android.clients.google.com',
    'android.apis.google.com',
    'dl.google.com',
    'dl-ssl.google.com',
    'm.google.com',
    'android.com',
    'googleplay.com',
    'google-analytics.com',
    'xn--ngstr-lra8j.com',
    'youtube-nocookie.com',
  ];

  /// DNS 配置摘要（设置页“DNS 配置查看”直接渲染这份，不另写一份
  /// 文案：两处写同一份 DNS 说明迟早会写岔）。
  ///
  /// 防泄漏是固定行为不是开关：DNS 只走 DoH / DoT，不回落明文
  /// UDP 53；摘要最后一行写明“不可关闭”，设置页不给关掉它的入口。
  static const List<({String label, String value})> dnsSummary = [
    (label: '直连解析', value: 'DoH https://223.5.5.5/dns-query'),
    (label: '代理 DNS', value: 'DoH https://8.8.8.8/dns-query（经代理出站）'),
    (label: '默认解析', value: '规则模式默认走代理 DNS；.cn 始终直连解析'),
    (label: '解析策略', value: '仅 IPv4（ipv4_only）'),
    (label: '明文 UDP 53', value: '不回落（无 UDP 服务器）'),
    (label: '防泄漏', value: '已开启，不可关闭'),
  ];

/// 从节点列表生成完整 sing-box 配置。
///
/// [mode] 只改 route 段与 DNS 规则的解析路径，不改节点出站：
/// - 规则模式：TikTok / 社交 / 流媒体 / 测 IP / Google 基础域 → Proxy，
///   `.cn` → direct，其余直连（route.final = direct）；DNS 规则：
///   `.cn` 直连解析，TikTok 与测 IP / 社交 / 流媒体 / Google 基础域
///   走代理 DNS；
/// - 全局模式：route 无规则，final = 有节点时 `Proxy`、无节点时 `direct`
///   （无节点时没有 Proxy 组，final 不能指不存在的出站）；DNS 规则
///   全部走代理 DNS（有节点时经 detour Proxy，无节点时 dns-proxy 无
///   detour、服务器是 IP 8.8.8.8，与空配置规则一致），final 同样走
///   代理 DNS（有节点时）；
/// - 直连模式：route 无规则，final = direct；DNS 规则全部走直连解析，
///   不让任何 DNS 查询经代理出站（否则“全部直连”名不副实），final
///   同样走直连解析。
///
/// DNS final 的口径（2026-11-26 根因修复）：规则都不命中时走的解析
/// 路径。有节点且不是直连模式时走 `dns-proxy`——未列入规则的境外
/// 域名也经代理解析，避开国内对境外解析的拦截与污染；流量本身仍按
/// route 走直连还是代理，DNS 走代理不改变分流。之前 final 是
/// `dns-dot`（DoT 8.8.8.8:853 直连），国内直连 8.8.8.8 被拦，所有
/// 未列入规则的域名（包括测速地址 www.gstatic.com）都解析失败——
/// 开关开着没网络、测速全红点的根因就在这里，不是节点不通。
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
/// TUN 接管流量，gvisor 栈 + 自动路由，0.1.10 起写 `stack: gvisor`）；
/// 为 false 时不写 tun 入站。TUN 只改入站，不改出站与规则。
///
/// [lanProxy]（0.1.14）：为 true 时 mixed 入站监听 0.0.0.0（局域网
/// 可连），否则只听 127.0.0.1；[lanProxyPort] 是 mixed 入站的端口
/// （默认 [mixedPort]）；鉴权开着时 [lanProxyUsername] /
/// [lanProxyPassword] 非空才写 `users`（sing-box mixed 入站支持
/// `users` 字段，见 schema；空值不写，不留半截鉴权）。只改入站，
/// 不改出站与规则：局域网进来的流量走同一套分流。
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
  bool lanProxy = false,
  int lanProxyPort = mixedPort,
  String? lanProxyUsername,
  String? lanProxyPassword,
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
    // 最前面的两条（2026-11-26 0.1.2 根因 R1，顺序即语义，
    // 三种模式都加）：
    // ① sniff：TUN 下流量只有目标 IP，没有域名就没有任何
    //    domain_suffix 规则能命中，全部落到 final=direct 直连
    //    被墙；先嗅探出域名，后面的规则才有东西可匹配；
    // ② 私网旁路：局域网地址直连，不走代理。
    // QUIC 阻断（UDP 443 全部 block）曾经是第 ① 条：0.1.2 有、
    // 0.1.4 删、0.1.5 加回、0.1.6 回滚删掉（见下文 0.1.6 段）。
    //
    // 0.1.3（D 路第 1 步，须真机验证的定罪步骤）：原来第 ③ 条
    // DNS 劫持（{'protocol': 'dns', 'action': 'hijack-dns'}）与
    // TUN 入站的 'dns_mode': 'hijack' 一起删掉——两者是同一机制
    // 的两端，必须一起开关，只去其一更差。D 路沙箱复现不出手机
    // 故障（TUN/UDP 测不到），劫持对是 0.1.2 里唯一同时满足三点
    // 的改动：全模式生效、能杀死一切域名解析、0.1.1 没有它；
    // 真机验证恢复即定罪情况 B，仍断则按 PATCH_NOTES 的预案
    // 第 2 步删 QUIC 阻断、第 3 步删 sniff（不要一次全做完）。
    //
    // 0.1.4（D 路第 2 步，须真机验证的定罪步骤）：删掉原来第 ① 条
    // QUIC 阻断（{'network': 'udp', 'port': 443, 'outbound':
    // 'block'}）——规则与全局两份配置一起删。B 路已核 sing-box
    // 源码：路由规则只对入站连接求值，不可能误伤 HY2 出站自身的
    // UDP 443；沙箱 48 次 curl 也复现不出断网，删与不删在 SOCKS
    // 路径上无差别，只能由真机 A/B 定罪。sniff 是第 3 步，这次
    // 不删（删了规则模式的域规则全部失效，退回 0.1.2 之前的状态），
    // 留待真机验证第 2 步后再定。
    //
    // 0.1.5（把 QUIC 阻断加回来，规则与全局两份配置一起加）：
    // 0.1.4 真机验证（用户 2026-11-26 22:32/22:37）：“有点网络了，
    // 但卡得几乎不能用，YouTube 页面加载不全”，几个节点都一样慢；
    // 0.1.4 诊断包（开关开着）核心 1.14.4-patched、已连接、探活带
    // 真实时间通过、无错误——核心与节点侧已排除，慢在客户端共有
    // 通路。分析员（~/workspace/015-invest/slowness-analysis.md）
    // 定性：0.1.2 的黑断与 0.1.4 的慢是两个故障，黑断元凶是劫持对
    // （微信是 TCP，QUIC 阻断拦不到它），QUIC 阻断在黑断上无辜、
    // 只在“慢”上有嫌疑；P0-1 是 QUIC 走隧道（REALITY/TCP 节点上
    // UDP QUIC 装进 TCP 流＝双重丢包恢复＋队头阻塞；HY2 上 QUIC
    // 套 QUIC＝双重拥塞控制），P0-2 是 sniff 失败→落 final=direct；
    // 加回 QUIC 阻断是唯一同时掐断这两条 YouTube 慢路径的单变量
    // 改动，QUIC 被拦后回落 TCP，而 TCP 出站已被探活验证健康。
    // 实测员（~/workspace/015-invest/sandbox-measurements.md）：
    // 沙箱里隧道不慢（经 reality-443 吞吐中位 9.27 vs 直连 8.81
    // MB/s，比值 1.05）、两路 DoH 都快、sniff 开关无可测代价、
    // QUIC 阻断开/关对 TCP 无影响——节点、REALITY、DNS、sniff
    // 全部洗脱，慢在沙箱测不到的手机侧。弱信号备查：75 次代理
    // curl 里 2 次单次 TLS stall（5.48s、6.02s），直连 15 次里
    // 0 次超 1.03s，样本太少不定罪。
    // 回滚条件：真机验证 0.1.5 后 YouTube 仍卡、微信/百度无改善
    // → 回滚这条规则，进 P1（sniff 诊断，0.1.6 再做），不要叠加
    // 其它改动。其余一切不动：sniff 300ms、私网旁路、两路 DoH、
    // MTU 1500、reverse_mapping、final 全不动；不加回 hijack-dns、
    // 不动 DNS、不动栈、不加 fake-ip。
    //
    // 0.1.6（执行 0.1.5 的回滚条件，规则与全局两份配置一起回滚）：
    // 0.1.5 真机验证结论是 V1 无效而且更差：0.1.4 是“有点网络但
    // 极慢”，0.1.5 是手机全没有网络，关开关即恢复正常。0.1.4→
    // 0.1.5 唯一的变量就是 QUIC 阻断加回——“QUIC 阻断拦不到 TCP
    // 所以黑断上无辜”的判断被推翻（见 ~/workspace/016-invest/
    // mechanism-blackout.md）。0.1.5 诊断包（开关开着，23:24）：
    // 核心 1.14.4-patched、已连接、启动探活通过（23:23:34）、
    // 最近错误无、当前节点测试机-hy2-443-A 延迟 524ms、路由首条
    // QUIC 阻断已在 live 配置里——核心自认完全正常，数据面却
    // 全断且静默无错误，与 0.1.2 的翻版（核心已连接、延迟 604ms、
    // 订阅能更新，仍全断）一致：探活与延迟测的是控制面，数据面
    // 死了核心也不报错。回滚即把本条从前缀拿掉，恢复 0.1.4 的
    // 两条前缀（sniff、私网旁路）；sniff 不动（P1 诊断见
    // ~/workspace/016-invest/p1-sniff.md，0.1.6 不叠加 sniff
    // 改动）；不加回 hijack-dns、不动 DNS、不动栈、不加 fake-ip。
    routeRules.addAll([
      {'action': 'sniff', 'timeout': '300ms'},
      {'ip_is_private': true, 'outbound': 'direct'},
    ]);
    // 自定义规则插在两条之后、内置规则之前（先命中先走，
    // 用户规则优先于内置规则）；走代理的规则没有节点时不进
    // （没有 Proxy 组可指），直连的照常进。
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
          routeRules.add({
            'domain_suffix': googleInfraSuffixes,
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

    // DNS 规则的解析路径按模式走：规则模式 `.cn` 直连解析、TikTok /
    // 社交 / 流媒体 / 测 IP / Google 基础域走代理 DNS；全局模式
    // 全部走代理 DNS；直连模式全部走直连解析。
    // `.cn` 恒走直连解析（2026-11-26 0.1.2 全局慢 P1-1：全局
    // 模式 `.cn` 也走直连解析；route final 仍为 Proxy，
    // `dns.final` 仍为 dns-proxy，变的只是 `.cn` 的解析路径）。
    final String cnDnsServer = 'dns-direct';
    final String proxyDnsServer = mode == RoutingMode.direct
        ? 'dns-direct'
        : 'dns-proxy';

    // 自定义规则的 DNS 映射插在最前面（只按动作分，不按模式分：
    // 用户明确说走代理的域名就走代理 DNS、说直连的就走直连 DNS，
    // 哪怕当前是全局或直连模式——那正是自定义规则存在的意义）。
    // 走代理的自定义规则没有节点时同样不进（dns-proxy 的 detour
    // 指不到 Proxy 组；规则写进去也不会炸，但解析路径会与 route
    // 不一致，故跳过）。
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
      // 社交与流媒体的 DNS 必须与 route 同路（都走代理）：
      // 之前 DNS 规则里没有这两组，它们落到 final 上走直连解析，
      // route 却把流量指给 Proxy——DNS 死在直连上，代理的流量
      // 拿不到地址，YouTube / Facebook 这类站开着开关也打不开。
      {
        'domain_suffix': socialSuffixes,
        'server': proxyDnsServer,
      },
      {
        'domain_suffix': streamSuffixes,
        'server': proxyDnsServer,
      },
      {
        'domain_suffix': googleInfraSuffixes,
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
              // 直连解析走阿里云 DoH（223.5.5.5，IP 直连、无需先解析
              // 服务器域名）：之前是 1.1.1.1，国内直连境外解析被拦，
              // .cn 解析与 dns.google 的引导解析都死在这里。
              'server': '223.5.5.5',
              'server_port': 443,
              'path': '/dns-query',
              // 直连解析不写 detour：detour 指到 direct 出站时 1.14.4
              // 启动即报 "detour to an empty direct outbound makes no
              // sense"（真机 1.14.4 run 实测）；不写 detour 默认就是直连。
            },
            {
              'tag': 'dns-proxy',
              'type': 'https',
              // 服务器必须写 IP 不能写域名：之前是 dns.google，解析它
              // 本身要走 default_domain_resolver（dns-direct）；直连
              // 解析一死，代理 DNS 跟着死，TikTok / 测 IP 的 DNS 全灭。
              // 8.8.8.8 经 detour Proxy 出站建连，不需要本地先解析。
              'server': '8.8.8.8',
              'server_port': 443,
              'path': '/dns-query',
              // 代理 DNS 走 selector 出站。注意 detour 填的是出站 tag，
              // 必须与 selector 的 tag `Proxy` 逐字一致；面板 1.3.37
              // 写的是小写 `proxy`，没有这个 tag 的出站，run 时报
              // "outbound detour not found: proxy"。节点为空时没有
              // Proxy 组，detour 也不写。
              if (nodeTags.isNotEmpty) 'detour': 'Proxy',
            },
          ],
          'rules': dnsRules,
          // sing-box 没有 DNS 服务器间的自动故障转移；final 是规则都
          // 不命中时的解析路径：有节点且不是直连模式时走代理 DNS，
          // 否则走直连解析（见 build 的文档注释）。
          // 之前 final 是 DoT 8.8.8.8:853 直连——国内直连 8.8.8.8
          // 被拦，未列入规则的域名（包括测速地址 www.gstatic.com）
          // 全部解析失败：开关开着没网络、测速全红点的根因。
          'final': mode != RoutingMode.direct && nodeTags.isNotEmpty
              ? 'dns-proxy'
              : 'dns-direct',
          // 只解析 IPv4，不回落明文 UDP 53（无 udp 服务器）。
          'strategy': 'ipv4_only',
          // 反向映射（2026-11-26 0.1.2 根因 R1）：TUN 下只有目标
          // IP 时，靠反向映射把解析过的域名找回来，route 的
          // domain_suffix 规则才能命中。
          'reverse_mapping': true,
        },
        'inbounds': [
          {
            'type': 'mixed',
            'tag': 'mixed-in',
            'listen': lanProxy ? '0.0.0.0' : '127.0.0.1',
            'listen_port': lanProxyPort,
            // 鉴权（0.1.14）：账号密码都有才写 users，缺一个都不写。
            if (lanProxy &&
                lanProxyUsername != null &&
                lanProxyUsername.isNotEmpty &&
                lanProxyPassword != null &&
                lanProxyPassword.isNotEmpty)
              'users': [
                {
                  'username': lanProxyUsername,
                  'password': lanProxyPassword,
                },
              ],
          },
          // TUN 入站（切片 6，tunEnabled 时才写）：系统级 TUN 接管
          // 流量，自动路由；不写时就是原来的 mixed 入站。
          // 注意 run 冒烟只跑 tun 关闭的配置：tun 入站启动时要建
          // TUN 设备，没权限的机器上会失败，真机再验。
          //
          // 0.1.10：TUN 栈改成 `gvisor`（单变量，TUN 路径只改这一处）。
          // 0.1.9 死态诊断包已定案：核心是好的（DNS 两路通、探活通、
          // 微信/QQ 的包已到核心），死的是 TUN 到 App 的回包——App
          // 的包到了核心但响应回不来（全局与规则都整机没网、关开关
          // 马上恢复）。system 栈（默认 mixed 的 TCP 一半）的回包链
          // 是：内核 TCP 监听器发包 → 内核路由进 tun0 → sing-tun
          // NAT LookupBack 改写 → 写回 TUN fd → 内核本地投递给
          // App；这条链全程依赖内核路由与 NAT 会话，在这台小米上
          // 断了（0.1.6 同配置能跑、0.1.8/0.1.9 不能，状态相关）。
          // gvisor 栈把 TCP 全收进用户态 netstack 处理：没有内核
          // 监听器、没有 NAT 改写，响应直接由 sing-tun 写回 TUN
          // fd，整条脆弱链一次绕过。UDP 本来就走 gvisor（mixed
          // 的 UDP 一半），且 libbox 以 with_gvisor 编译（三种栈
          // 都已编进二进制，不用重编）。
          //
          // 为什么现在能写 stack（2026-11-26 的禁令已解除）：
          // 插件内置 schema 的 tun 分支本来就没有 `stack` 属性且
          // `additionalProperties: false`，写了就被 Dart 校验以
          // "Additional property stack is not allowed" 拒掉；0.1.10
          // 把上游 option/tun.go:52 的 Stack 字段（enum
          // system,gvisor,mixed）补进本地 schema 快照
          // （singbox_schema.json），再用 gen_models.dart 重生成
          // TunInbound 模型（+ build_runner 重生成 .g.dart），
          // 校验放行后 builder 才能写。只动这三件套，不动别的。
          if (tunEnabled)
            {
              'type': 'tun',
              'tag': 'tun-in',
              'interface_name': 'tun0',
              // MTU 1500（2026-11-26 二轮修复：之前是 9000，远高于
              // 手机物理 MTU 约 1500，大包分片/黑洞风险；拨测不走
              // TUN 所以它不是拨测全灭的主因，只是叠加因素，顺手修）。
              'mtu': 1500,
              'address': '172.19.0.1/30',
              'stack': 'gvisor',
              'auto_route': true,
              'strict_route': true,
              // 0.1.3（D 路第 1 步）：原来这里写 'dns_mode': 'hijack'
              //（2026-11-26 0.1.2 根因 R1，TUN 接管的 DNS 查询劫持
              // 进本地 DNS，与 route 的 hijack-dns 规则配套），与
              // 路由那条 hijack-dns 一起删掉——劫持对是同一机制的两
              // 端，必须一起开关。不写即默认，恢复 0.1.1 行为：
              // App DNS 恢复成普通 UDP 53 流量走路由规则。
            },
        ],
        'outbounds': outbounds,
        // route：0.1.9 只加 `auto_detect_interface: true`（单变量，
        // 其余一行不动：不加 `default_interface` /
        // `override_android_vpn` / 出站 `bind_interface`，不改
        // sniff/DNS/MTU/栈、不加回 QUIC 阻断、不动 HY2 出站）。
        //
        // 为什么加（2026-11-27，016 机制报告已证，0.1.8 真机又把
        // Brutal 与节点双双脱罪，TUN 环路黑断成头号嫌疑）：
        // - `route/network.go:73-74` 的 guard 是
        //   `options.AutoDetectInterface && !(C.IsLinux || C.IsDarwin
        //   || C.IsWindows)`，而 `constant/os.go:23` 规定
        //   `IsLinux = goos.IsLinux == 1 || goos.IsAndroid == 1`——
        //   Android 上 `C.IsLinux` 为真，guard 不触发，写了不报错。
        //   2026-11-26 二轮修复的注释把 `goos.IsLinux`（Android 上
        //   为 0）与 `constant.IsLinux`（Android 上为真）混为一谈，
        //   “Android 上开就会报错”是错的，本次一并纠正。
        // - 写上后 `NewNetworkManager` 挂载 `ProtectFunc()`：拨号走
        //   `protect(fd)` 绕过 TUN（`common/dialer/default.go:105-127`，
        //   只在 `AutoDetectInterface()` 为真时挂载；Kotlin 侧
        //   `PlatformInterfaceWrapper.usePlatformAutoDetectInterfaceControl()
        //   = true`，`VPNService.autoDetectInterfaceControl` 即
        //   `protect(fd)`）。`addDisallowedApplication` 仍保留作
        //   插件层隔离，两道隔离并存。
        //
        // 残余风险（已复核，任务书原说法有误，此处以源码为准）：
        // - libbox 侧 `platformInterfaceWrapper
        //   .UsePlatformDefaultInterfaceMonitor()` 恒为 true
        //   （`experimental/libbox/service.go:107`），所以
        //   `NewNetworkManager` 走平台监视器分支
        //   （`platformDefaultInterfaceMonitor`，`monitor.go`），
        //   不走 `tun.NewNetworkUpdateMonitor` →
        //   `NewDefaultInterfaceMonitor` 分支——任务书说的“插件侧未实现”
        //   不成立；那条分支只在非 libbox 的独立 sing-box 上才走，
        //   且 `sing-tun` 的 `NewDefaultInterfaceMonitor`
        //   （`monitor_shared.go:58`）本身恒返回成功，不会报
        //   `auto_detect_interface unsupported on current platform`。
        // - 真正的残余风险在平台分支：`platformDefaultInterfaceMonitor
        //   .Start()` 调 Kotlin 的 `StartDefaultInterfaceMonitor`，
        //   若该回调在真机上建不起来/不回调，核心启动即失败——
        //   `sing-box check` 验不到这一层（check 不启动监视器），
        //   真机启动才是最终裁决；0.1.9 的采样时序会把它记下来
        //   （核心起不来 → 无采样、诊断包印“无”）。
        // - 另：`NewNetworkUpdateMonitor` 在 Android 上若被走到，
        //   netlink 被禁会直接报 `ErrNetlinkBanned`；libbox 路径下
        //   走不到它，记在这里防以后有人换路径时踩坑。
        'route': {
          'auto_detect_interface': true,
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

  /// 节点在配置里的出站 tag（测速认这个 tag，不是节点名）；
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
  /// 切换节点不要用这个：见 [selectorTagForNode]。
  static String? tagForNode(List<Node> nodes, Node target) {
    for (final entry in _nodeTagEntries(nodes)) {
      if (identical(entry.node, target)) return entry.ownTag;
    }
    return null;
  }

  /// 节点在 selector `Proxy` 里占的那一位 tag（切换节点与落盘默认
  /// 选择认这个，不是 [tagForNode] 的出站 tag）；该节点生成时会被
  /// 跳过时返回 null。
  ///
  /// 成组节点（同名多入站，如 `测试机-reality-443-A` /
  /// `测试机-hy2-443-A`）在 selector 里只占组 tag 一位（见 [build]），
  /// 拿自身 tag 去 PUT `/proxies/Proxy` 时 Clash API 回 400
  /// "Selector update error: not found"（真 sing-box 1.14.4 实测），
  /// 这就是开着开关切节点报“核心没有响应”的根因——不是核心没响应，
  /// 是名字不在组里。未成组节点返回自己的出站 tag。
  static String? selectorTagForNode(List<Node> nodes, Node target) {
    for (final entry in _nodeTagEntries(nodes)) {
      if (identical(entry.node, target)) return entry.memberTag;
    }
    return null;
  }

  /// （节点，出站 tag，selector 成员 tag）三元组：与 [build] 同一套
  /// 去重与成组规则（重名加 ` (2)`、同节点多入站成 urltest 组、
  /// selector 里成组节点只占组 tag 一位），[tagForNode] 与
  /// [selectorTagForNode] 都从这里取，算出来的 tag 不会与配置脱节。
  /// 跳过的节点不在其中；[Node] 按 identity 认。
  static List<({Node node, String ownTag, String memberTag})>
  _nodeTagEntries(List<Node> nodes) {
    final usedTags = <String>{};
    final keptNodes = <Node>[];
    final nodeTags = <String>[];
    for (final node in nodes) {
      final tag = _uniqueTag(node.name, usedTags);
      if (_nodeOutbound(node, tag) == null) continue;
      usedTags.add(tag);
      keptNodes.add(node);
      nodeTags.add(tag);
    }
    final groupMembers = <String, List<int>>{};
    for (var i = 0; i < keptNodes.length; i++) {
      final group = _groupName(keptNodes[i].name);
      if (group == null) continue;
      groupMembers.putIfAbsent(group, () => []).add(i);
    }
    groupMembers.removeWhere((_, members) => members.length < 2);
    final memberTagByIndex = List<String>.generate(
      keptNodes.length,
      (i) => nodeTags[i],
    );
    for (final entry in groupMembers.entries) {
      final groupTag = _uniqueTag(entry.key, usedTags);
      usedTags.add(groupTag);
      for (final i in entry.value) {
        memberTagByIndex[i] = groupTag;
      }
    }
    return List.generate(
      keptNodes.length,
      (i) => (
        node: keptNodes[i],
        ownTag: nodeTags[i],
        memberTag: memberTagByIndex[i],
      ),
    );
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
        // 0.1.8：删掉 0.1.7 加的两行（回 BBR，单变量）。美国01那条线
        // 366ms → 804ms → 全死，3 分钟内单调爬升——Brutal 固定速率
        // pacer 按 100Mbps 硬发、链路真实容量不足时丢包爆炸的预测形态
        // （sing-quic BrutalSender：拥塞事件空实现不降速，pacer 速率 =
        // bps/ackRate 且 ackRate 下限钳 0.8，丢包反而发得更快最高 1.25
        // 倍；窗口 = bps×RTT×2/ackRate，RTT 一涨窗口跟着涨；三条正反馈
        // 串起来正是爬升曲线）。100 是按测试机那条路取的测试值（节点侧
        // 512Mbps），美国01真实容量未知、现存唯一容量信号是 015 沙箱经
        // REALITY 的 TCP 约 74Mbps < 100。删行即回 0.1.6 状态（有网但
        // 慢）；在美国01上恢复即定罪 Brutal，仍死即定罪节点。调低到 50
        // 是 0.1.9 的事，不在本版。
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
      // 拥塞控制（如 `bbr`，解析时取回来的原样写回去；没有就不写）。
      if (node.congestionControl != null &&
          node.congestionControl!.isNotEmpty)
        'congestion_control': node.congestionControl,
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

  /// REALITY tls 块（切片 10，实施方案 §8.2）：
  /// server_name 是 SNI 目标，utls 指纹强制 `chrome`，reality 块带
  /// 公钥与 short id。
  ///
  /// 指纹强制 chrome（2026-11-26 0.1.2 根因 A）：Xray ≥26.9.8 的
  /// REALITY 服务端要求 ClientHello 带 X25519MLKEM768 份额，
  /// sing-box 1.14.4 客户端发包前无条件删掉该份额且无配置项可改；
  /// firefox/safari 预设本身不带 MLKEM768 份额，chrome 是唯一
  /// 可能带该份额的预设（见 sing-box#4520），所以不要
  /// `node.fingerprint ?? 'chrome'`——节点自带 firefox/safari
  /// 指纹时也强制改成 chrome。注意：这只是提高握手成功率的
  /// 兜底，不是根治（1.14.4 的 chrome 预设同样可能被删份额，
  /// 见 PATCH_NOTES 0.1.2 的 REALITY 路线说明）。
  /// 不要往 reality 块加 `support_x25519mlkem768`：1.14.4 的
  /// schema 没有这个字段，会拒整份配置。
  static Map<String, dynamic> _realityTlsObject(Node node) {
    final tls = <String, dynamic>{'enabled': true};
    if (node.sni != null && node.sni!.isNotEmpty) {
      tls['server_name'] = node.sni;
    }
    tls['utls'] = {
      'enabled': true,
      'fingerprint': 'chrome',
    };
    tls['reality'] = {
      'enabled': true,
      'public_key': node.realityPublicKey,
      if (node.realityShortId != null) 'short_id': node.realityShortId,
    };
    return tls;
  }

  /// TLS 对象：有 SNI 时写 server_name，没有时只开 enabled；
  /// 有 ALPN 时写 `alpn`（HY2/TUIC 的 `h3`，解析时取回来的原样写回去）。
  static Map<String, dynamic> _tlsObject(Node node) {
    final tls = <String, dynamic>{'enabled': true};
    if (node.sni != null && node.sni!.isNotEmpty) {
      tls['server_name'] = node.sni;
    }
    if (node.alpn != null && node.alpn!.isNotEmpty) {
      tls['alpn'] = [node.alpn];
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
