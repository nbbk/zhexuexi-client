# 问题 6 / 7 真 sing-box 1.14.4 复现记录（2026-11-26）

复现环境：本机 VM，`~/workspace/toolchains/sing-box/sing-box-1.14.4-linux-amd64/sing-box`
（`sing-box version 1.14.4`），客户端配置由 `SingboxConfigBuilder.build()` 生成
（临时测试 `test/tmp_issue7_dump_test.dart`，跑完已删）。

节点（复现用假地址/假密钥，形状与真订阅一致）：
`测试机-reality-443-A` / `测试机-reality-443-B`（VLESS+REALITY+vision）、
`测试机-hy2-443-A`（HY2）、`测试机-ss-8388-A`（SS aes-256-gcm）。
服务端是本机另起的 sing-box：VLESS REALITY 入站 127.0.0.1:1443、
SS 入站 127.0.0.1:18388（`server.json` 见 /tmp/issue7，已删密钥重生成即失效，
仅作复现用）。

## 问题 7：切换——根因是成组节点的 tag（已证实）

生成配置里 selector `Proxy` 的成员只有组 tag：

```json
{"type": "selector", "tag": "Proxy", "outbounds": ["测试机"], "default": "测试机"}
{"type": "urltest", "tag": "测试机",
 "outbounds": ["测试机-reality-443-A", "测试机-reality-443-B",
               "测试机-hy2-443-A", "测试机-ss-8388-A"]}
```

实测（客户端真核跑起来后打 127.0.0.1:9090）：

| 请求 | 结果 |
|---|---|
| `GET /proxies/Proxy` | `{"now":"测试机","all":["测试机"]}` |
| `PUT /proxies/Proxy {"name":"测试机-reality-443-A"}`（自身 tag） | **400 `{"message":"Selector update error: not found"}`** |
| `PUT /proxies/Proxy {"name":"测试机-ss-8388-A"}`（自身 tag） | **400 同上** |
| `PUT /proxies/Proxy {"name":"测试机"}`（组 tag） | **204** |
| `PUT /proxies/测试机 {"name":"测试机-ss-8388-A"}`（urltest 组不是 selector） | 400 `Must be a Selector` |

结论：`selectNode` 拿 `tagForNode` 的自身 tag 去 PUT，成组节点（面板 twin
双链接的全部节点都成组）必然 400，App 报“切换失败，核心没有响应”是错怪了
核心——核心有响应，只是不认这个名字。修法：切换与落盘认
`SingboxConfigBuilder.selectorTagForNode`（成组取组 tag，未成组取自身 tag），
失败原因按回码分（连不上 / 不在组里 / 被拒绝）。

## 问题 7：测速——VLESS REALITY 配置生成没错（已证实）

同一份配置、同一台真核（DoT 解析，见下）：

| delay 目标 | 结果 |
|---|---|
| `GET /proxies/测试机-reality-443-A/delay` | **200 `{"delay":415}`** |
| `GET /proxies/测试机-reality-443-B/delay` | **200 `{"delay":298}`** |
| `GET /proxies/测试机-ss-8388-A/delay` | **200 `{"delay":403}`** |
| `GET /proxies/测试机-hy2-443-A/delay`（本机无 HY2 服务端） | 503（拨号失败，符合预期） |
| `GET /proxies/不存在的节点/delay` | 404 `Resource not found` |

即：`_nodeOutbound` 生成的 VLESS REALITY 出站（tls.reality 公钥/short_id、
utls chrome、flow xtls-rprx-vision）能正常测速。用户真机上“只有 ss/hy2
能测、VLESS 测不到”不是配置生成问题，待真机 logcat 定位（候选：VLESS
节点服务端/中转路由问题、或手机上 delay 超过 5 秒超时）。

### 沙箱环境坑（复现时踩到的，与 App 无关）

- 本机出站走 egress 代理：`sing-box` 直连 DoH `https://1.1.1.1/dns-query`
  在核内超时（`lookup www.gstatic.com: context deadline exceeded`），
  导致 delay 全员 504、连 `direct` 出站的 delay 也 504。改
  `default_domain_resolver` 为 DoT `dns-dot`（8.8.8.8:853）后
  SS/VLESS delay 立即 200。**这是沙箱网络问题，不是客户端 DNS 设计问题**
  （用户手机上 SS/HY2 delay 能通，说明手机上 DoH 解析正常）。
- `curl` 不加 `-N` 时 `/traffic` 看似不推帧：是 curl 的管道缓冲，
  `curl -sN` 可见空闲时每秒一帧 `{"up":0,"down":0}`。所以启动后
  `trafficSample(5s)` 探活是有效的。

## 问题 6：假运行——配置层面已证实

- `SingboxConfigBuilder.build(nodes)`（tun 关）生成的 inbounds 只有
  `mixed 127.0.0.1:2080` 一条；tun 开时多一条 `tun-in`（gvisor、
  auto_route）。两份配置 `sing-box check -c` 均通过（exit 0）。
- TUN 默认关（`settings_notifier.dart`）时，libbox 永远不会调
  `VPNService.openTun()`（原生侧 `PlatformInterfaceWrapper.openTun` /
  `VPNService.openTun` 只在配置有 tun 入站时由核心调用），无 VPN 标识、
  无流量进核心；但 `:remote` 的 commandServer 照常起来，AIDL 推
  Started，Dart 侧只认 `proxyStateStream`，首页显示“运行中”。
- 修法：TUN 默认开启（新装与从未改过开关的用户）；Started 后再探一次
  Clash API `/traffic` 取一帧（5 秒超时），探不到翻成 error
  “核心已启动但控制接口无响应”。Kotlin 不用动。

## 待真机验证（没拿到用户 logcat）

1. 点开关后首页变“运行中”、顶栏出现 VPN 标识、外网通。
2. 开着开关点 twin 节点（A/B）能切过去；切后读回 `now` 是组 tag。
3. VLESS 节点开着开关测速的结果（若仍失败，抓 logcat 看 delay 侧的
   失败原因：超时 / 拨号失败 / 404）。
