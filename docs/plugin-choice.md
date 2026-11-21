# sing-box 核心插件二选一调研结论

- 核实日期：**2026-11-22**（以下“几天前”均以该日为基准换算）
- 调研范围：只调研、不写代码、不改任何仓库
- 依据：客户端落地方案 `docs/zhexuexi-client-plan.md`（§4 技术选型、§5 订阅兼容）、`DEV-PLAN.md` §4.2 阶段 0 第 3 步
- 核实方法：pub.dev 包页 / 版本页 / 评分页 + GitHub 仓库主页 / Issues 页 + CHANGELOG；未做任何真机安装与代码运行验证

> 脱敏说明：本文示例一律用 `example.com` / `203.0.113.1`，不出现任何真实域名与 IP。

## 0. 结论先行

**选 `flutter_sing_box`，版本 `3.1.0`（2026-11-01 发布）。**

一句话理由：它是本次候选里**唯一同时满足第一期 Win + Android 双端生产就绪、Windows TUN、Clash API（含测延迟 / 选出站 / 实时流量）、订阅三格式导入**的插件；`sing_box` 功能最全但明确不支持 Windows，`sing_box_flutter` 五端都支持但只有 14 天历史、API 太薄，不可作 MVP 主选。

- 选定：`flutter_sing_box: ^3.1.0`，仓库 `github.com/clash-sing/flutter_sing_box`，许可证 GPL-3.0
- 备选（长期观察，不作 MVP 备选切换对象）：`sing_box_flutter: ^0.3.1`，仓库 `github.com/idy/sing-box-flutter`，许可证 GPL-3.0
- 备选（仅 Android 侧参考实现）：`sing_box: ^1.0.0`，仓库 `github.com/QUSAD-prod/sing_box`，许可证 GPL-3.0-or-later——因无 Windows，不能当选型，只能在 Android 端出现问题时对照它的实现思路排查
- 淘汰：`v2ray_box 1.0.1`（无 Windows、核心不内置、近 9 个月未更新）、`singbox_ffi 0.1.3`（README 自述 TUN 未实现）

冻结建议（阶段 0 执行时重核一次再冻结进 `pubspec.lock`）：

```yaml
dependencies:
  flutter_sing_box: ^3.1.0
```

## 1. 对比表

| 维度 | flutter_sing_box 3.1.0（选定） | sing_box 1.0.0 | sing_box_flutter 0.3.1（长期备选） | v2ray_box 1.0.1（淘汰） |
|---|---|---|---|---|
| pub.dev 最新版 / 发布时间 | 3.1.0 / 2026-11-01 | 1.0.0 / 2026-10-28 | 0.3.1 / 2026-11-11 更新 | 1.0.1 / 约 9 个月前 |
| 内置 sing-box 核心 | 1.14.3（CHANGELOG 3.0.1 明确记录；见 §2.1 的版本疑点） | **1.14.4**（与上游最新一致） | **1.14.4**（`native-core.json` 钉死，revision `c005f353…`） | 不内置，须自建核心；文档示例 sing-box 1.12.22（已旧） |
| 与上游最新 1.14.4（2026-10-23/24 发布）的差距 | 最多落后一个补丁版（1.14.3 → 1.14.4），待阶段 0 实测确认 | 无差距 | 无差距 | 落后两个大版本线，且核心版本由使用者自定 |
| Windows TUN | ✅ 有（TUN 默认，系统服务承载） | ❌ 无（pub.dev 评分页明文：不支持 Windows） | ✅ 有（Wintun，需管理员运行） | ❌ 无（仅 Android / iOS / macOS） |
| Windows 系统代理 | ✅ 有（注册表方式，默认 mixed 端口 8890） | ❌ 无 | 未在 README 明确写系统代理模式 | macOS 才有系统代理；Windows 不支持 |
| Android VpnService | ✅ 有 | ✅ 有（前台服务 + 通知 + 快捷设置磁贴） | ✅ 有（前台 VpnService） | ✅ 有（但 Android 端 sing-box 走 Xray-core 做 TUN 桥接，非原生 libbox TUN） |
| iOS / macOS / Linux | 均 Planned（未做） | iOS ✅ / macOS ❌ / Linux ❌ | iOS ✅ / macOS ✅（NE 或 user TUN）/ Linux ✅ | iOS ✅ / macOS ✅（仅代理模式）/ Linux ❌ |
| URLTest 自动选节点 | ✅ 有两条路：① Clash API 测延迟 + 选出站；② 原生 JSON 里直接写 `urltest` 出站（核心原生支持） | ✅ 有（`urlTest()` / `testGroup()` / `auto` 组 + 自动选最快，测速地址默认 `https://www.gstatic.com/generate_204`） | ⚠️ 无 Dart API：只有 `checkConfig` / `start` / `stop` / 状态 / 版本；`urltest` 出站须自己写进 JSON 且无 API 触发与读延迟 | ✅ 有（`ping` / `pingAll` / `watchPingResults`，默认超时 7 秒） |
| Clash API 查流量 | ✅ 有（完整 Clash API：代理与分组管理、选出站、测延迟、日志 WebSocket 自动重连；上下行流量走 `connectedStatusStream` 实时流） | ✅ 有（编译进核心的 `with_clash_api`；`watchConnectionStats()` 给实时速率与累计流量，另有连接列表、Clash 模式切换） | ❌ 无（README 明文：不链接官方 libbox RPC / profile-management 层；API 只有状态流，无流量、无连接、无 Clash 模式） | ✅ 有（sing-box 侧走 Clash API；另有 `watchStats()`） |
| 订阅 / 配置导入 | ✅ 有（原生 JSON、Clash YAML 转 sing-box、Base64 分享链接；Profile 管理：本地 / 远程订阅导入与切换） | ✅ 有（分享链接、base64 / 明文 / JSON / SIP008 订阅；自带配置生成器） | ❌ 无（只接受完整 sing-box JSON；README 明文：不提供 profile 编辑器与订阅管理器） | ✅ 有（链接解析与校验） |
| 核心是否内置 | ✅ 内置（Android 各 ABI + Windows amd64/arm64 双份二进制随包发布） | ⚠️ 半内置（原生库 ~85 MB AAR / ~200 MB XCFramework 不进 pub.dev，首次构建时从 GitHub Releases 自动下载并 SHA-256 校验） | ❌ 不内置预编译件（0.3.0 起无通用预编译 libbox，须用 pinned Tailscale Go 从源码编译） | ❌ 不内置（须按脚本自建 Xray / sing-box 核心） |
| 许可证 | GPL-3.0 | GPL-3.0-or-later | GPL-3.0 | 未核实（见 §5 未核实项） |
| pub.dev 评分 | 150 分，4 likes，周下载 1.38k | **160 / 160 满分**，4 likes，周下载 1.43k | 160 分，1 like，周下载 390 | 未核实 |
| GitHub 活跃度 | 655 commits，17 stars，5 forks，33 releases，0 open issues（2026-11-22 查） | 65 commits，3 stars，2 forks，2 releases，0 open issues；仓库创建于 2025-12-25 | 20 commits，1 star，0 forks，2 releases，0 open issues；仓库创建于 2026-11-08 | 未核实 |
| Flutter 要求 | Flutter `>=3.44.0` / Dart `^3.12.0` | 未在 README 顶部单独列出（pub.dev 分析用 Flutter 3.50.0 / Dart 3.14.0 通过） | **Flutter 3.47.2+**，Android AGP 9.1 + JDK 17 | 未核实 |
| 与本项目第一期（Win + Android）的匹配度 | ✅ 完全匹配 | ❌ Windows 缺失，一票否决 | ⚠️ 平台匹配但成熟度与 API 完整度不匹配 MVP | ❌ 平台与成熟度都不匹配 |

## 2. 逐项核实

### 2.1 flutter_sing_box 3.1.0（选定）

- 来源：`https://pub.dev/packages/flutter_sing_box`、`https://pub.dev/packages/flutter_sing_box/versions`、`https://pub.dev/packages/flutter_sing_box/changelog`、`https://github.com/clash-sing/flutter_sing_box`
- 最新版：**3.1.0**，2026-11-01 发布；共 36 个版本，1.1.1 已撤回；4 likes、150 pub points、周下载 1.38k；发布者 unverified uploader。
- 平台：Android ✅ Production Ready（arm64-v8a / armeabi-v7a / x86_64）、Windows ✅ Production Ready（amd64 / arm64）；iOS、macOS、Linux 均为 Planned。**第一期只做 Win + Android，这一点正好够用；第二期要上 iOS / macOS / Linux 时必须换插件或等它补平台。**
- Windows TUN：有。README 明文：Tun 模式（经虚拟网卡做系统级透明代理）为默认，另有 System Proxy 模式（注册表方式，默认 mixed 端口 8890）。Windows 上 sing-box 以系统服务 `clash_sing_service` 承载，提供 `installService()` / `uninstallService()` / `queryServiceStatus()`；`startVpn()` / `stopVpn()` 对应启停服务；2.0.0 起 Windows 启动失败不再抛异常，改为经 `proxyStateStream` 以 `ProxyStopped(errMessage: …)` 上报。
- Android VpnService：有。README 明文：Android 上启停 VPN 服务。
- URLTest 自动选节点：有，分两条路。① Clash API 层：README 称“Full support for the Clash-compatible API — manage proxies and groups, select outbounds, test latency”；CHANGELOG 2.0.0 节明文“Implement proxy group fetching, outbound switching and URL latency testing”。② 配置层：插件接受原生 sing-box JSON，`urltest` 出站是 sing-box 核心原生能力，写进配置即生效。MVP 推荐走第 ① 条（与客户端“测速后选延迟最低”的需求直接对应），第 ② 条作兜底。
- Clash API 查流量：有。README 明文：Clash API 全支持 + “Monitor connection status, traffic (uplink/downlink), and logs in real-time via streams”；`connectedStatusStream` 给上下行流量；另有 Clash 模式读取与切换（`clashModeStream` / `setClashMode`）、日志 WebSocket（`/logs`，自动重连）。
- 内置核心版本（**有疑点，见 §5 第 1 条**）：pub.dev README（含 3.1.0 文档页）写的是 `1.14.1`，但 CHANGELOG 证明 README 滞后——3.0.1 已“Upgrade sing-box core to `1.14.3`”（Android libbox 与 Windows amd64 / arm64 二进制同步升级）。3.1.0 的 CHANGELOG 顶部未记录核心升级，但其“未命名节点自动命名”一条写明“sing-box 1.14.4 rejects duplicate empty tags at config initialization”，说明 3.1.0 是按 1.14.4 的行为做验证的。**结论：3.1.0 实际内置核心为 1.14.3 或 1.14.4，README 的 1.14.1 是过期文字；以阶段 0 实测（Android libbox 版本 + Windows `sing-box.exe --version`）为准。** 最坏情况也只落后上游一个补丁版，不影响选型。
- 订阅兼容（与方案 §5 对得上）：原生 JSON、Clash YAML 转 sing-box、Base64 分享链接三格式全有；Profile 管理（本地 / 远程订阅导入与切换）；新 DNS 格式必填（legacy `dns.servers` 在 1.14.1 已移除）——与方案“客户端自己生成 DNS 配置，不透传面板 legacy DNS 段”的要求一致。另有 JSON Schema 校验（仅诊断、不阻塞导入）与订阅样本回归门（`tool/subcheck/`，三种格式样本经 `sing-box check` 校验）。
- 维护状态：GitHub `clash-sing/flutter_sing_box`，655 commits、17 stars、5 forks、33 releases、0 open issues（2026-11-22 查）；创建于 2025-09-19；最近发布 3.1.0（2026-11-01）。作者自用项目 `clash-sing`（基于 sing-box 与 Clash 的 GUI 客户端）就是该插件的 showcase，插件随客户端持续迭代。
- 许可证：GPL-3.0（pub.dev 与 GitHub 一致）。
- 依赖注意：依赖 `mmkv`（Android 32 位 lane 须降级到 1.3.x，插件约束已放宽到 `>=1.3.17 <3.0.0` 并自动配对同版本 AAR）；依赖 `material_ui`（Flutter 3.50 拆分后的新包，与方案 §4.1 的脚手架提示一致）；Flutter `>=3.44.0` / Dart `^3.12.0`（方案锚定的 Flutter 3.50.1 满足）。

### 2.2 sing_box 1.0.0（功能最全，但无 Windows，一票否决）

- 来源：`https://pub.dev/packages/sing_box`、`https://pub.dev/packages/sing_box/score`、`https://pub.dev/packages/sing_box/versions`、`https://github.com/QUSAD-prod/sing_box`
- 最新版：**1.0.0**，2026-10-28 发布；仅 2 个版本（1.0.0、0.0.1）；160 / 160 pub points（满分）、4 likes、周下载 1.43k；发布者 `qusad-prod.tech`。
- 平台：**Android 与 iOS 两个平台**。pub.dev 评分页明文写死：“Package does not support platform `Windows`”，另不支持 Linux、macOS、Web。README 的平台表只有 Android（VpnService，最低 Android 7.0 / API 24）与 iOS（Packet Tunnel Network Extension，最低 iOS 15.0）两列。**第一期必须出 Windows，此项一票否决，无论其他项多好都不能选。**
- URLTest 自动选节点：有，且是三候选里 API 最完整的——配置生成自带 URL test 组与 Clash API；`urlTest()` / `testGroup()` / `pingServers()`；多节点连接时自动建 `auto`（URL test）组，自动选最快；测速用真实 HTTP（默认 `https://www.gstatic.com/generate_204`），与方案 §5.2 的测速地址一致；未连接时用 TCP 握手测延迟。
- Clash API 查流量：有。核心编译时带 `with_clash_api`；`watchConnectionStats()` 给实时速率与累计上下行；另有连接列表（可逐条关闭）、Clash 模式（Rule / Global / Direct）切换、`watchGroups()` 给各组延迟。
- 内置核心：**sing-box 1.14.4**，与上游最新一致；编译标签 `with_gvisor`、`with_quic`、`with_wireguard`、`with_utls`、`with_clash_api`（Apple 侧另加 `with_dhcp`、`with_low_memory`）。协议覆盖 VLESS（含 Reality / Vision）、VMess、Trojan、SS（含 2022）、Hysteria / Hysteria2、TUIC、WireGuard、AnyTLS、ShadowTLS 等，与落地六协议全对得上。
- 订阅兼容：分享链接与订阅导入（vless / vmess / trojan / ss / hysteria2 / tuic / anytls / wireguard / socks / http）、配置生成器（TUN、DNS、路由、URL test 组、缓存、Clash API 一次生成）、分应用代理（Android）、DoH / DoT / DoQ / DoH3 自定义 DNS。另有速度测试与 STUN NAT 测试（MVP 用不上）。
- 维护状态：GitHub `QUSAD-prod/sing_box`，65 commits、3 stars、2 forks、2 releases、0 open issues（2026-11-22 查）；仓库创建于 2025-12-25。社区极小，bus-factor 高。
- 许可证：GPL-3.0-or-later（README 另注：上游 sing-box 核心为 GPL-3.0-or-later 附加命名条款；发布应用须公开完整对应源码并保留声明）。
- 包体注意：原生库不进 pub.dev（~85 MB AAR、~200 MB XCFramework），首次构建时从 GitHub Releases 自动下载并 SHA-256 校验；每 ABI 约 60 MB，须分 ABI 出包。

### 2.3 sing_box_flutter 0.3.1（第三候选：平台最全，但太新、API 太薄）

- 来源：`https://pub.dev/packages/sing_box_flutter`、`https://pub.dev/packages/sing_box_flutter/versions`、`https://github.com/idy/sing-box-flutter`
- 最新版：**0.3.1**，2026-11-11 更新；首版 0.1.0 发布于 2026-11-08；1 like、160 pub points、周下载 390；发布者 unverified uploader。
- 平台：**五端全支持**，是三候选里平台面最广的——Android（前台 VpnService，API 24+）、iOS（NEPacketTunnelProvider，iOS 15+）、macOS（NE 或 user TUN，macOS 12+）、Windows（Wintun，需管理员运行，x64 / ARM64）、Linux（原生 TUN，x86_64 / arm64）。这一点对第二期（iOS / macOS / Linux）最有吸引力。
- 内置核心：**sing-box 1.14.4**（`native-core.json` 钉死，revision `c005f35300ce76427dc285481ec5695f5b179cd2`；Tailscale Go 与 SagerNet gomobile 版本同样钉死），与上游最新一致。另支持按需选协议编译（`sing_box_flutter.core` 块）与 Tailscale / WGC 端点。
- URLTest 自动选节点：**无 Dart API**。README 明文：“The first release provides core version lookup, configuration validation, explicit VPN consent, start/stop, and connection status. It accepts complete sing-box JSON; it does not provide a profile editor, subscription manager, or Tailscale account UI.”`urltest` 出站只能由使用者自己写进 JSON，且无 API 触发测试、无 API 读延迟——自动选节点要全部自己在 Dart 侧另写（调 Clash API 或自己发测速请求），等于 MVP 的核心功能之一没有现成支撑。
- Clash API 查流量：**无**。README 明文：“It does not link the official libbox RPC/profile-management layer.”Dart API 只有 `checkConfig` / `start` / `stop` / `getStatus` / `getVersion` 与状态 / 事件 / 日志流；无流量统计、无连接列表、无 Clash 模式。首页实时速率与 P1 本机流量统计都要另起炉灶。
- 核心交付方式：**0.3.0 起不提供通用预编译 libbox**，须用 pinned Tailscale Go 从源码编译（`dart run sing_box_flutter build --target android|windows|…`），构建机须装 Python 3.11+、Git、Android SDK + NDK `28.0.13004108`（Windows 另须 VS C++ 工作负载 + CMake 3.27+）。首次构建成本高，且与“GitHub 无 CI 额度、测试全本地”的现状叠加后风险更大。
- 维护状态：GitHub `idy/sing-box-flutter`，20 commits、1 star、0 forks、2 releases、0 open issues（2026-11-22 查）；仓库创建于 2026-11-08。**满打满算 14 天历史**，无任何外部用户验证记录。
- 许可证：GPL-3.0。
- 结论：作长期备选。等它到 1.0 且补齐 Clash API / 测速 / 流量 API、或第二期要上 iOS / macOS / Linux 时再重新评估；MVP 不选。

### 2.4 其他候选（已查，已淘汰）

- **Hiddify**：Hiddify-app 是完整客户端（33.9K stars），不是可复用的 Flutter 插件；其 sing-box 集成在 `hiddify-app` / `hiddify-core` 仓库内部，没有发布到 pub.dev 的插件包，无法作为依赖引入。已排除。
- **v2ray_box 1.0.1**（pub.dev）：双核心（Xray-core + sing-box）插件，有测速与流量统计，但**无 Windows**（仅 Android / iOS / macOS），核心不内置（须按脚本自建），文档示例 sing-box 版本为 1.12.22（已旧），最近更新约 9 个月前。平台与新鲜度双不达标，已淘汰。
- **singbox_ffi 0.1.3**（pub.dev）：Flutter FFI 绑定，README 自述“TUN mode (`OpenTun` returns an unsupported error)”——TUN 未实现；原生库须另行下载。已淘汰。

## 3. 风险与备选

### 3.1 选定插件的风险（按严重程度排）

1. **GPL-3.0 传染性（三个候选全是 GPL，躲不掉）。**`flutter_sing_box` 为 GPL-3.0；sing-box 核心同样 GPL。发布客户端即须按 GPL 要求公开完整对应源码并保留声明。这与“自研闭源客户端”的默认假设冲突，**须用户在阶段 0 拍板**：接受开源客户端源码，或接受 GPL 义务的其他合规做法。三个候选全是 GPL，换插件解决不了这个问题；只有备选 A（Go 常驻核心服务，见方案 §4.3）且同样用 sing-box 核心时也一样。
2. **社区极小，bus-factor 高。** 上游作者 essentially 一人维护（17 stars、5 forks、0 open issues——0 不是没问题，是用的人太少还没攒出 issue 池）。插件一旦停更，核心升级（例如 sing-box 1.15）与 Flutter 大版本适配都要自己 fork 接手。缓解：阶段 0 即 fork 一份到自有账号作镜像（只读备份，不改代码），并把“插件可替换”写进架构——核心调用集中在一个 `CoreService` 封装层里，不要让插件 API 漏进界面层。
3. **Windows 以系统服务承载，安装与卸载路径比常规插件复杂。** 首次安装须调 `installService()`（弹 UAC），卸载须调 `uninstallService()`；服务残留、helper 崩溃、`.old` 文件残留都是 CHANGELOG 里反复修过的点（3.1.0 刚加了 helper 更新检测与 crash 探测）。最小验证必须覆盖“安装 → 启动 → 杀进程 → 重启 → 卸载”全链路，不能只验启动成功。
4. **核心版本比上游落后一个补丁版（疑似）。** 3.1.0 疑似内置 1.14.3 而非 1.14.4（见 §2.1）。1.14.3 → 1.14.4 的差异须在阶段 0 对照上游 release notes 确认是否影响本项目（重点看 Reality / QUIC / DNS 相关修复）；若有影响，等插件跟进或自行评估是否接受。
5. **iOS / macOS / Linux 全是 Planned。** 第二期要上这些平台时，`flutter_sing_box` 大概率仍不可用，届时要么换 `sing_box_flutter`（若其时已成熟），要么为第二期平台另写核心接入层。MVP 架构里不要把“以后全平台都用这一个插件”写死。
6. **包体偏大。** Windows 双架构二进制（amd64 + arm64 的 `sing-box.exe` / `libcronet.dll` / `clash_sing_helper.exe`）随包发布，安装包会比纯 Dart 应用大一截；Android 三 ABI 同理。分发页上写清包体大小预期，不要让用户以为下载卡住了。

### 3.2 备选方案

| 备选 | 触发条件 | 代价 |
|---|---|---|
| `sing_box_flutter`（长期备选） | `flutter_sing_box` 在最小验证中 Windows 服务或 Clash API 实测不通过；或第二期要上 iOS / macOS / Linux | 须自写 Clash API 客户端、测速调度、流量统计、订阅导入四层；须从源码编译核心，构建链重搭 |
| `sing_box`（仅 Android 参考） | Android 端出现 `flutter_sing_box` 解释不了的行为时，对照它的实现与文档排查；不作切换对象 | 无切换成本（只读参考）；切换本身不可行（无 Windows） |
| 方案 §4.3 备选 A：Flutter 界面 + Go 常驻核心服务 | 两个 Flutter 插件在最小验证中全部不通过 | 多一个进程、安装包变大、Windows 服务安装更麻烦；但核心完全可控，且与 A 线 `node-agent` 的 Go 技术栈复用 |

## 4. 最小验证清单

> 原则：只写能做的事，不写没做的事。本机（Linux VM）无 Flutter / Dart / Android SDK / Windows 环境，**本机能做的只有纯 Dart 层与官方 sing-box 二进制校验**；凡是带“真机”字样的，一律须在真机上跑，不许在本机声称通过。

### 4.1 本机 Linux 上能做的部分（阶段 0 先做）

1. **装环境并确认基线**：装 Flutter 最新稳定版（执行时重核，不要沿用方案里的 3.50.1）+ Dart SDK + JDK 17/21 + Android SDK + NDK；跑 `flutter doctor -v` 全绿才算过。
2. **核实 3.1.0 的实际内置核心版本**：解压 pub 缓存里的 `flutter_sing_box-3.1.0`，查 Android 侧 libbox 依赖版本（`android/build.gradle.kts`）与 Windows 侧 `assets/windows/amd64/sing-box.exe --version`（须在 Windows 上跑 `--version`；Linux 上可用 `strings` 辅助看版本号，但不作最终结论）。输出写进 `docs/api/plugin-decision.md`：实测核心版本号。
3. **纯 Dart 层单测（`flutter test`，本机可跑）**：订阅解析（sing-box JSON / Clash YAML / Base64 三格式 → 统一 `Node` 模型，含 VLESS+WS+TLS、SS2022、HY2、TUIC 用例）→ 节点模型生成 sing-box JSON（新 DNS 格式，DoH 双路，只解析 IPv4，不回落明文 UDP 53）→ 生成的 JSON 用 JSON Schema 校验。断言：三种订阅解析成同一模型；HY2 / TUIC 节点带“须 TUN”标记；明文节点带“明文”标记。
4. **官方 sing-box 二进制校验（本机可跑，不依赖插件）**：下载官方 sing-box 1.14.4 Linux 二进制，对第 3 步生成的配置跑 `sing-box check -c config.json`；再以该配置跑 `sing-box run`（本地 mixed 入站 + 一个 `direct` 出站，不连真实节点），确认配置能启动、无报错。另起一个带 `experimental.clash_api` 的本地实例，用 Dart 写的 Clash API 客户端调 `/proxies`（取分组与延迟字段）、`/traffic`（取上下行）、`PUT /proxies/{group}/{proxy}`（切换出站），证明 Dart 侧 Clash API 调用链本身是通的——插件只是把这条链包了一层。
5. **脱敏检查**：示例节点一律 `example.com:443` / `203.0.113.1:8388`、假 UUID `11111111-2222-3333-4444-555555555555`、WS 路径 `/example-path`；提交前跑一遍脱敏 grep，零命中才算过。

### 4.2 Android 真机上验证什么（须真机，不许声称本机已做）

1. 首次启动弹 VpnService 授权 → 点允许 → 核心启动 → 首页开关变绿。
2. 拉一次真实订阅（三种格式各一次），节点列表出现，分组（中转 / 直连）分开展示；点一个 VLESS+WS+TLS 节点，3 秒内生效，能打开 `https://www.gstatic.com/generate_204`（返回 204）。
3. 一键全部测速：每个节点出现真实延迟（非 ICMP）；自动选节点选中延迟最低的可用节点；5 分钟后台重测一次。
4. HY2 / TUIC 节点在 TUN 下连通；切到系统代理模式时界面提示“UDP 协议需开 TUN 模式才完整可用”。
5. 首页实时速率跳动；`subscription-userinfo` 头解析出已用 / 总量 / 到期日三格。
6. 杀进程重进：核心状态恢复正确（不出现“已断但显示已连”）；断网重连后自动恢复。
7. 卸载重装后订阅令牌仍在（安全存储），不用重新绑定。

### 4.3 Windows 真机上验证什么（须真机，不许声称本机已做）

1. 首次启动调 `installService()` 弹 UAC → 点是 → 服务 `clash_sing_service` 出现在服务列表；`queryServiceStatus()` 返回 running。
2. TUN 模式默认开：启动后全局流量走代理（含不走系统代理的应用）；系统代理模式：注册表代理被设置，浏览器走代理。
3. 连一个 VLESS+WS+TLS 节点，能打开 `https://www.gstatic.com/generate_204`；测速与自动选节点与 Android 侧行为一致。
4. 异常链路：任务管理器杀掉 sing-box 子进程 → 界面在 3 秒探测后报“代理内核已停止运行”，不出现假连接；服务崩溃重启后状态恢复。
5. 升级链路：装新版客户端覆盖旧版 → helper `.old` 残留被清理，服务正常重启（3.1.0 新加的逻辑，须实测）。
6. 卸载：调 `uninstallService()` 后服务消失、注册表代理恢复、无残留进程占用 TUN 设备与端口。
7. 无管理员权限启动时：界面给明确提示，不静默失败、不假装已连接。

### 4.4 通过标准

- 4.1 全部通过 + 4.2 全部通过 + 4.3 全部通过，才算“插件选型验证通过”，结论写入 `docs/api/plugin-decision.md`（DEV-PLAN §4.2 第 3 步要求的书面结论），并把实测核心版本号、测速结果、包体大小补进本文 §2.1。
- 任一真机项不通过：先定位是插件问题还是自家配置问题；插件问题且无法绕过时，切 §3.2 的备选并重新跑本清单，不要带着已知失败进阶段 1。

## 5. 未核实项

1. **`flutter_sing_box` 3.1.0 实际内置的 sing-box 核心版本。** README 写 1.14.1（已证实过期），CHANGELOG 最后一次明确升级是 3.0.1 的 1.14.3，3.1.0 未记录核心升级但引用了 1.14.4 的行为。须在阶段 0 按 §4.1 第 2 步实测确认（Android libbox 版本 + Windows `sing-box.exe --version`）。
   - **阶段 0 已确认（2026-11-22）：是 1.14.4。**Android 端 `libbox:1.14.4`，Windows 端 `sing-box.exe` strings 含 `mod github.com/sagernet/sing-box v1.14.4`，官方 1.14.4 Linux 二进制本机实测 `sing-box version 1.14.4`。详见 `docs/api/plugin-decision.md`。
2. **三家插件的真实 issue / PR 处理速度。** 三仓 2026-11-22 查到的 open issues 均为 0，但三仓社区都极小（17 / 3 / 1 stars），0 open 更多反映用的人少而非质量无瑕；closed issue 数与平均响应时间未拉取（GitHub 页面提取未渲染该数字），未作为选型依据。
3. **`flutter_sing_box` 的 Windows 服务在不同 Windows 版本上的表现。** README 只写 Windows amd64 / arm64，未注明最低 Windows 版本（Win 10 还是 Win 11）；UAC、服务安装、Wintun 驱动在 Win 10 / Win 11 各版本上的差异须真机覆盖。
4. **`flutter_sing_box` 的 Clash API 在 Android 与 Windows 上行为是否一致。** README 与 CHANGELOG 分别描述了两端实现（Android 经 libbox，Windows 经 helper HTTP + Clash HTTP 客户端），但未声明两端 API 语义完全一致；测速、选出站、流量流须在双端各验一次。
5. **`sing_box_flutter` 的 Windows Wintun 实测表现与构建耗时。** 只有文档声称支持，未见任何外部实测记录；从源码编译核心的耗时与失败率未知。仅作备选观察，未深入核实。
6. **`v2ray_box` 的许可证与最新版发布时间。** 仅确认其无 Windows、核心不内置、文档示例核心版本旧，未拉取其许可证与版本页精确日期；已淘汰，不影响结论。
7. **GPL 合规的具体做法。** 三个候选全是 GPL-3.0 系，客户端源码公开范围、声明保留方式、官网直发安装包的源码提供方式，须用户拍板后由阶段 0 写进发布清单；本文不替用户定。
8. **Flutter 版本。** 方案锚定的 Flutter 3.50.1（2026-11-20 发布）未在本机实测；`flutter_sing_box` 要求 Flutter `>=3.44.0`，`sing_box_flutter` 要求 Flutter 3.47.2+，两者在 3.50.1 上理论上都满足，但须 `flutter doctor -v` 全绿后才算数。
   - **阶段 0 已确认（2026-11-22）：Flutter 3.50.1 本机已装，`flutter --version` 通过，`flutter doctor` 仅剩 Chrome 缺失与 Linux 桌面工具链缺失两项不影响构建的提示。** 详见 `docs/versions.md`。
9. **本文未做任何代码运行与真机验证。** 全部结论来自公开文档与包页；插件的真实行为以 §4 最小验证的实测结果为准，实测不通过时结论作废、按 §3.2 切备选。
   - **阶段 0 已做 §4.1 本地验证（2026-11-22）：全部通过。**`flutter test` 11/11、`flutter analyze` 零问题、官方 sing-box 1.14.4 `check`/`run` 本地回环通过、Clash API `/version`、`/proxies`、`/traffic` 与 Dart 客户端全通过。§4.2（Android）与 §4.3（Windows）须真机，未做。详见 `docs/api/plugin-decision.md`，证据在 `docs/validation/stage0/`。

---

- 核实人：助手（子代理调研）
- 核实日期：2026-11-22
- 来源链接：
  - `https://pub.dev/packages/flutter_sing_box`
  - `https://pub.dev/packages/flutter_sing_box/versions`
  - `https://pub.dev/packages/flutter_sing_box/changelog`
  - `https://github.com/clash-sing/flutter_sing_box`
  - `https://pub.dev/packages/sing_box`
  - `https://pub.dev/packages/sing_box/score`
  - `https://pub.dev/packages/sing_box/versions`
  - `https://github.com/QUSAD-prod/sing_box`
  - `https://pub.dev/packages/sing_box_flutter`
  - `https://pub.dev/packages/sing_box_flutter/versions`
  - `https://github.com/idy/sing-box-flutter`
  - `https://pub.dev/packages/v2ray_box`
  - `https://pub.dev/packages/singbox_ffi`
