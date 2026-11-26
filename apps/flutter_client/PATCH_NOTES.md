# 哲学系客户端 PATCH_NOTES

## 2026-11-26：拨测超时第二轮——TUN 环路硬隔离＋探活状态机＋版本号 0.1.1（未推仓）

背景：用户 2026-11-26 15:31 报 fa0c20ae 版真机仍报错——节点页 8 个全红
（7 超时不可达、1 连接失败，含第三方节点）；15:46 补：开着开关 YouTube
打不开、每次开开关上行跑很高、下行没有。上一轮“10 秒＋重试”的探活修法
未解决。另：用户 15:46 亲口定版本号升到 0.1.1（包内仍是 0.1.0 导致
更新器每次都认为 v0.1.1 是新版、反复提示）。

### 根因证据（代码位置＋本地验证结果）

- 定性是代理真断，不是探活误报：两路调查结论一致，详见
  `~/workspace/delay-loop-repro/REPORT.md`——拨测（Clash API delay）
  完全不经过 TUN、也不走客户端 DNS（SS/VLESS 等出站把测速域名透传
  给落地解析；本地真 sing-box 活节点一次就通，组 tag 148ms、叶子
  148–655ms；dns-direct 拉黑仍通）。手机上 8 个全灭，说明核心出站
  的 TCP 拨号/握手本身没完成；故障与 TUN 默认开同时出现，此前 TUN
  关着时手机 REALITY/HY2 是通的。
- **上游 sing-box 1.14.4 源码核实（tarball，关键发现）**：
  - `route/network.go:73`：`auto_detect_interface` 在 Android 上写了
    就启动报错（"`auto_detect_interface` is only supported on Linux,
    Windows and macOS"）——文档 `auto_route` 一节的三选一在 Android
    上全是死路；`default_interface`（:75-79）与出站 `bind_interface`
    （`common/dialer/default.go:73-76`）同样仅限 Linux/macOS/Windows；
    `override_android_vpn` 要求 `auto_detect_interface` 开启，同样死路。
  - `common/dialer/default.go:105-127`：`ProtectFunc()`（调
    `autoDetectInterfaceControl` 即 `protect(fd)`）只在
    `networkManager.AutoDetectInterface()` 为真时才挂到拨号上，
    Android 上恒为假——**插件里 `protect(fd)` 那行代码在 Android
    上根本不会被核心拨号调用**，之前“代码里有 protect 就安全”的
    判断不成立；全仓唯一调用点就是 default.go:123。
  - `SettingsManager.kt` 两处默认值核实：注释掉的旧定义默认 EXCLUDE
    是死代码，生效的 getter 默认 DISABLED；`VPNService.openTun`
    读的是后者——默认不排除任何应用，自家包不在排除列表里。
  - 对照实验（本地验证）：同份配置加 `auto_detect_interface: true`
    在 Linux 上 `sing-box check` 通过——证实门控是平台相关的，
    不是文档推测；Android 上同字段会启动报错（源码行在上）。
- 手机侧 protect 是否生效：**待真机验证**——新包 logcat 里看两行：
  `openTun` 的 `addDisallowedApplication(<包名>)` 结果，以及
  `autoDetectInterfaceControl` 的 protect 调用计数（预期为 0，
  即证明拨号不走 protect；若非 0 且 failures>0，说明这台小米
  的 protect 在失败）。

### 改动

- `packages/flutter_sing_box/.../bg/VPNService.kt`（环路修法，核心）：
  - `openTun` 里 `perAppProxyMode != INCLUDE` 时
    `builder.addDisallowedApplication(自家包名)`——核心跑在 :remote
    进程、与 App 同 UID，排除自家包后核心发出的 socket 直接走物理
    网卡、不进 TUN；与 `protect()` 无关的硬隔离。try/catch 包着，
    万一某机型拒绝排除自家包只记一行 WARN、继续建 TUN（退回今天
    的行为），不炸启动；INCLUDE 模式下跳过（该模式已把自家包写进
    allowed 列表，两边同写会冲突）。
  - `autoDetectInterfaceControl` 记 `protect(fd)` 返回值：成功记
    DEBUG、失败记 WARN，companion 计数 `protectCalls` /
    `protectFailures`（诊断用，见上）。
- `packages/.../utils/SettingsManager.kt`：注释说明两处默认值，
  生效的是 DISABLED（死代码 EXCLUDE 不再误导）。
- `lib/core/singbox_config.dart`：
  - TUN `mtu` 9000 → 1500（远高于手机物理 MTU，顺手修的叠加因素）。
  - route 段注释写明三条配置路在 Android 上不可用的源码依据——
    **字段一个没加**（加了核心起不来）。
- `lib/core/singbox_core.dart`（状态机，方案 A）：
  - 新增 `ProbeState`（failed/error/at）＋ `probeStream`：拨测失败
    只写探活位，不翻 `CoreStatus.error`；`CoreStatus.error` 只留给
    插件原生 `ProxyStopped(err)`。`started` 时清 `_lastError` 与
    探活位，停核心时清探活位；公开 `retryProbe()`（防重入
    `_verifying`）；拨测通过清探活失败；超时文案改提「重新拨测」；
    `dispose` 关探活流。
- `lib/features/home/home_page.dart`：订阅探活流；started+probeFailed
  时主标题仍「运行中」，副标题「出站拨测失败：…（代理可能不通）」；
  「重新拨测」按钮（只重跑拨测，不停核心）；红字失败区只在真 error
  时显示；`_syncTraffic` / `_syncDurationTimer` 不动（status 保持
  started 就不会被取消）；大开关仍是停核心。
- `lib/services/nodes_notifier.dart`：新增 `_speedTestMode()`——只有
  「核心在跑且探活通过」才走代理口径；探活失败改走直连探测，但
  `speedTestError` 横幅写明原因＋新增 `speedTestDirectFallback` 位，
  不静默切换；`testAllSpeeds` / `testSingleSpeed` 共用同一判定。
- `lib/features/nodes/nodes_page.dart`：`_speedHint` 在 fallback 时
  写“开关开着但出站拨测失败，改用直连探测”，不再写“开关关着”。
- 版本号（用户 2026-11-26 15:46 定）：pubspec `0.1.1+2`；
  `lib/brand/remote_config.dart` 的 `appVersion` 常量 `0.1.1`；
  设置页三处硬编码 `0.1.0`（诊断包、检查更新弹窗、关于行）改走
  `appVersion` 常量，以后只改一处；订阅/登录 UA 里的
  `Zhexuexi/0.1.0` 没动（不是版本显示，面板侧不认它作版本）。
- 没动：DNS 配置（dns-direct/dns-proxy/final）与拨测预算/重试
  （10 秒＋重试）——已证明拨测不走 DNS、10 秒仍全灭，再调只是拖时间。

### 测试

- `flutter analyze`：零问题；`flutter test` 全量：**513/513 通过**
  （之前 503；新增 9 项：core_service 4、speed_test 2、
  singbox_config 2、home_page 1；settings_page 补 1 处断言）——
  探活失败不翻 error、started+probeFailed 显示、「重新拨测」恢复、
  测速口径判定（探活失败改走直连＋横幅）都有覆盖。
- 真 sing-box 1.14.4 `check`：VLESS REALITY + SS + HY2、TUN 开着、
  规则模式生成的配置 exit 0；dump 确认 tun mtu 1500、route 里没有
  `auto_detect_interface` / `default_interface`，出站无
  `bind_interface`。`run` 冒烟：mixed 入站起在 127.0.0.1:2080；
  TUN 起不来是沙箱 TUNSETIFF EPERM（沙箱禁建 TUN，调查时已知限制），
  不是配置问题。
- 实施中踩到的两个测试坑（记下来免得后人再踩）：
  ① widget 测试体跑在 FakeAsync 区，直接 await 文件 IO
  （`CoreService.init` 内部读盘）永远等不到完成——测试体里不要
  重建 service 再 init，复用 setUp 的共享 service；
  ② 启动校验的预热/重试定时器是在 runAsync 真实区建的，fake 时间
  的 pump 刷不动它，要等真实时间。
- 构建插曲：第一次 `flutter build apk` 跑到约 7 分钟时被运行时重启
  中断（日志 0 字节、无产物）；重跑一次成功，约 10.6 分钟
  （Gradle daemon 连不上重试一次，自行恢复）。

### 新 APK

- arm64 release（`--split-per-abi`），109,356,177 字节（约 109.4MB）
- SHA-256：`0cb0feb8f8f7f8e859381d47947d4e90e219a7837a006e3f0dc70d02b9a0d4fa`（交付路径、`goals/goal-5/files/`、kit 构建产物三处复核一致）
- apksigner 校验通过（v2 签名，1 个签名者），证书 SHA-256 与上版完全一致：`2e10202c7a2b365aa9fd4438565bd6b0aa8b7054e215cdad008f01cb182a1d8e`，可直接覆盖安装
- aapt2：`versionName='0.1.1'`、`versionCode='2002'`、包名 `com.zhexuexi.client`
- 未推客户端仓；未碰 Release/授权

### 待真机验证（手机侧 protect 是否生效、环路修法是否见效，都在这里）

- ① 开关开着：YouTube / TikTok 通不通、测速出不出绿色数字、拨测还报不报错；设置页应显示 0.1.1，装完不应再重复提示更新到 v0.1.1。
- ② 若还不通：TUN 关掉是否立即恢复（A/B 定罪）；国内直连站如 baidu.com 能不能打开；把 logcat 里 sing-box 与 VPNService 的行发回来（重点看 `addDisallowedApplication` 那行与 `autoDetectInterfaceControl` 的 protect 计数）；点「重新拨测」后有无再次拨测、提示变没变。

## 2026-11-26：1.4.27 上线后用户反馈的客户端侧 9 项修复（未推仓）

背景：用户 2026-11-26 09:32 发来 12 条反馈，其中客户端侧 9 项归本次修复
（面板侧 5 条另走面板 1.4.28，已于 10:40 推 main 1da660c8）。
上一版 APK：2026-11-26 08:08 交付，arm64，SHA-256
`e2d4e6f2db3e7559bf20bd0c69a88f01d520573bf8ac6d0f80ad125018834926`。

### 问题 1：粘贴不了订阅链接，输入框有问题

- 根因：四处粘贴框都只有光秃秃的 `TextField（maxLines 3）`，没有任何“粘贴”按钮，
  用户只能靠长按菜单；且 `_buildBindForm` 与 `_buildError` 共用同一个
  `_linkController`。
- 改动：`lib/services/content_intake.dart:41` 新增共用粘贴函数（读剪贴板、
  去空白、填入、光标到末尾、空剪贴板提示）；四处粘贴框各加“粘贴”按钮；
  失败态粘贴框改独立控制器。
- 测试：粘贴测试改 mock 通道（本机 flutter_tester 不响应真实剪贴板通道，
  `Clipboard.setData` 会挂起）。

### 问题 2：面板订阅链接扫码导入不了，红字“订阅已失效，请重新绑定”

- 根因：导入整条链路的错误映射一刀切，404/410/网络不通/解析失败全报
  “订阅已失效”，误导用户。
- 改动（`lib/services/subscription_service.dart`）：错误映射分四档——
  404→“订阅链接不对或令牌不对，请检查链接或重新获取”；
  410→新增 retired 种“该订阅已退场，请使用订阅用户的新订阅链接”；
  无响应/超时/500→“网络不通，请检查网络后重试”；解析失败统一文案。
  404/410 仍不回退旧订阅。
- 另：`lib/services/nodes_notifier.dart:468` 与 `:608` 两处兜底旧文案
  “网络不通，检查订阅地址”已统一成“网络不通，请检查网络后重试”；
  `lib/services/auth_notifier.dart` 的 `_bindErrorMessage` 已按新文案匹配
  （404“令牌不对”/410“已退场”）。
- 注意：面板侧那条链接本身是否有效是线上数据问题（最可能是 nianba 的
  TokenHash 与 TokenEnc 解密后对不上），代码修不了，面板 1.4.28 已修成
  按对恢复并加启动自检；修法是给 nianba 轮换一次链接再重新扫码/粘贴。
  客户端只负责把原因报对、把能导入的导进来。

### 问题 3：账号登录页的面板域名输入框占位符不要直接填真实域名

- 改动：登录页 hint 与 `auth_service` 报错文案改成通用占位
  `panel.example.com`，不再出现用户真实域名。

### 问题 4：测速延迟——通的延迟数字本身绿色，不通的红色圆点

- 根因：`lib/features/nodes/nodes_page.dart` 的 `_LatencyChip` 原来通了
  显示灰字毫秒数、失败显示灰字“测速失败”。
- 改动：延迟数字本身用绿色——白天 `#157347`（白底约 5.9:1）、夜晚
  `#4ADE80`（墨蓝黑底约 11:1），主题 token 里没有成功/绿色，故直接取
  两端都可读的绿；失败只显示一个 10px 红色圆点（`colorScheme.error`），
  不再写“测速失败”，失败原因留在 tooltip 与长按说明里
  （`测速失败：$failureReason，点一下重测`）；未测速保持灰字“未测速”；
  测速中转圈不变。

### 问题 5：首页当前节点可点击，弹窗选节点切换，测速按选中节点测

- 根因：`lib/features/home/home_page.dart:530` 附近，当前节点卡片
  （`GlassCard + ListTile`）原来没有 `onTap`，不可点。
- 改动：卡片包一层透明 `Material + InkWell`（照节点行 `_NodeRow` 的做法——
  直接给 `ListTile` 加 `onTap` 会触发 Flutter 断言“ListTile 墨水会被
  GlassCard 底色盖住”），`onTap: _showNodePicker`，有节点时尾部加右箭头
  表示可点；新增 `_showNodePicker()`（无节点时不弹弹窗，提示“请先绑定
  订阅，再选择节点”并跳到“我的”页）；新增 `_NodePickerDialog`：列出全部
  节点（名称＋延迟，同一口径），当前选中行用选中底色＋对勾标出，点一行调
  `selectNode`，成功关闭弹窗，失败把原因红字留在弹窗里，不静默；弹窗
  actions 里有“测速当前节点”，调 `testSingleSpeed` 只测当前选中节点。

### 问题 6：首页大开关假运行（最优先）——显示“运行中”，实际没代理

- 根因（已复核确认）：默认配置里根本没有 TUN 入站。
  `lib/core/singbox_config.dart:419-447` 的 inbounds 只有 `127.0.0.1:2080`
  的 mixed 入站，tun 入站只在 `tunEnabled` 时才写；而 TUN 默认是关的
  （`settings_notifier.dart` 原 `tun=false`）。所以 libbox 永远不会调原生
  `VPNService.openTun()`，无 VPN 标识、无流量进核心；但 `:remote` 的
  commandServer 照常起来，AIDL 推 Started，Dart 侧 `CoreService` 只认
  `proxyStateStream`，首页显示“运行中”。Kotlin 不用动。
- 改动：
  - `lib/services/settings_notifier.dart`：TUN 默认改 true（构造默认值与
    持久化读回 `?? true` 两处）。明确关过的用户保持关，不强行改回。
  - `lib/features/home/home_page.dart` 的 `_onToggle`：启动时 TUN 还关着，
    先调 `setTun(true)` 再生成配置，并提示“已自动开启 TUN，否则无法代理”。
  - `lib/features/settings/settings_page.dart:357-361`：TUN 文案补一句
    “不开就没有代理”。
  - `lib/core/singbox_core.dart`：`CoreService` 新增可选注入
    `ClashApiClient clashApiClient`；`ProxyStarted` 后 `_verifyControlApi()`
    去 Clash API 取一帧 `/traffic`（5 秒超时），取不到就把状态翻成 error，
    `lastError='核心已启动但控制接口无响应'`。校验期间用户已手动停止不翻；
    dispose 竞态下不往已关的 controller 写事件（`isClosed` 保护）。
  - `sing-box check -c`：tun 开/关两份生成配置均通过（exit 0）。
- 测试副作用与修复：`_verifyControlApi` 让三个测试文件里没注入 fake Clash
  客户端的用例翻红（`home_page_test` 2 个、`routing_mode_test` 2 个，
  后者第二处“重载抛错返回 false”变 true 是同一根因：状态被翻成 error 后
  `setMode` 走了“未运行只写盘”路径）。已在三个文件的 setUp 给
  `CoreService` 注入 `_FakeClashApi`（`trafficSample` 直接回一帧，不碰网络）；
  `settings_page_test` 同样注入防 latent 失败。

### 问题 7：开着开关切节点报“切换失败，核心没有响应”，测速也失败，只有 ss/hy2 能测

- 根因（已证实，确定性复现）：成组节点的 tag，不是组名、不是核心没响应。
  面板 twin 双链接节点（`测试机-reality-443-A/B` 等）在配置里成一个 urltest
  组，selector `Proxy` 成员只有组 tag `["测试机"]`。`selectNode` 原先拿
  `tagForNode` 的自身 tag 去 PUT，真 sing-box 1.14.4 实测：
  `PUT /proxies/Proxy {"name":"测试机-reality-443-A"}` →
  400 `{"message":"Selector update error: not found"}`，
  `{"name":"测试机"}` → 204。App 把 400 报成“核心没有响应”是错怪核心。
  顺带：`updateSelectorDefault` 校验 `members.contains(tag)`，成组节点落盘
  默认选择以前也必然失败。
- 测速：同一份配置、同一台真核：VLESS REALITY delay 200（415ms / 298ms）、
  SS 200（403ms）、不存在的节点 404、HY2（本机无服务端）503。
  `_nodeOutbound` 生成的 REALITY 出站（公钥/short_id、utls chrome、flow
  vision）没错。用户真机上 VLESS 测不到，待真机 logcat 定位（候选：节点
  服务端/中转路由问题、或 delay 超过 5 秒超时）。
- 改动：
  - `lib/core/singbox_config.dart`：新增 `selectorTagForNode`（成组取组 tag，
    未成组取自身 tag）；`tagForNode` 与它共用新抽出的 `_nodeTagEntries`
    （与 `build()` 同一套去重/成组规则，测速仍用自身 tag 调 delay）。
  - `lib/core/clash_api_client.dart`：新增 `selectProxyDetailed` /
    `proxyDelayDetailed` + `ProxySelectResult` / `ProxyDelayResult`
    （失败原因：连不上 / 不在组里·404 / 超时 408·504 / 拨号失败 503）；
    老 `selectProxy` / `proxyDelay` 保留作兼容 wrapper。
  - `lib/services/nodes_notifier.dart`：`selectNode` 改用 `selectorTagForNode`，
    失败原因分清“核心没有响应”（连不上）/“节点不在运行配置里”（400/404）/
    “核心拒绝了切换”，PUT 成功后读回 `selectedProxy` 确认；`_testOneNode`
    （Clash 路径）按回码写 `latencyFailureReason`：404“节点不在运行配置里”、
    超时“超时不可达”、连不上“核心没有响应”、503“连接失败”。
- 复现全过程：`docs/validation/issue6-issue7-repro.md`。另：沙箱里 DoH
  `1.1.1.1` 在核内超时致 delay 全员 504，改 DoT 后立即正常——沙箱网络问题，
  与客户端 DNS 设计无关；`/traffic` 空闲每秒推 `{"up":0,"down":0}`，
  所以 `/traffic` 探活有效。

### 问题 8：首页当前节点下面的小卡片相互之间留缝隙

- 根因：`home_page.dart` 里实时速率/已用/总量/剩余流量与到期日/流量口径两行
  `Row`，每行三个 `Expanded` 的 `_StatCell` 直接相连，无间距。
- 改动：两行每格之间各加 `const SizedBox(width: AppTokens.spacingXs)`（8px）。
  卡片高度（102）与内容未动。

### 问题 9：首页顶部提示文案改成用户定的话

- 核对结果：文案本身已逐字一致，无需改词；但窄屏确实被截断，按要求改成
  完整显示。标题“首次启动需要联网拉取配置”、副标题“拉不到配置也能先手动
  粘贴订阅使用”（`home_page.dart:439`）。探针实测：390 宽下标题渲染宽度
  只有 148px、intrinsic 198px，副标题 148px vs 228px，360/320 更窄——
  都会被截成“首次启动需要联网…”。
- 改动：该提示卡去掉 `maxLines: 1 + ellipsis`（标题/副标题均允许换行、
  不省略），`GlassCard` 不再固定 72 高、改由内容定高；出现/关闭逻辑
  （bundled 源＋关闭持久化＋重试）一字未动。

## 测试结果

- `flutter analyze`：**零问题**（全量）。
- `flutter test` 全量：**452/452 通过**（`--concurrency=1`，约 3 分钟）。
  新增用例覆盖：粘贴四处、错误映射四档、TUN 默认开/明确关过保持关、
  Started 后探活成功保持 started/探不到翻 error/校验中停止不翻、成组节点
  取组 tag、select 400/404→notInGroup、delay 404/504/503 各有原因、成组节点
  PUT 与落盘都是组 tag、TUN 关着点开关自动打开且配置里有 tun 入站、
  节点弹窗选择切换/只测选中节点/切失败原因留弹窗/无节点不弹、小卡片间距
  8px、360 窄屏文案完整显示。
- 构建环境：Flutter 3.50.1、JDK 17、NDK 28.2.13676358；
  `/tmp` 只有 512M，每测一个文件约产生 105M dill 拷贝，多文件联跑会报磁盘满，
  全量用 `--concurrency=1` 单文件串行跑。

## 新 APK

- arm64 release（`--split-per-abi`），109,224,237 字节（约 109.2MB），
  SHA-256：`0367f0dfd4cd3057f06f7263fc4d78691b6a7480d8d7075789c3003b0a941fb8`
- apksigner 校验通过（v2 签名，1 个签名者）；证书 SHA-256 与上版一致：
  `2e10202c7a2b365aa9fd4438565bd6b0aa8b7054e215cdad008f01cb182a1d8e`
- 交付路径：`~/workspace/your_files/zhexuexi-client-release-arm64.apk`
  （软链到 `goals/goal-5/files/`），覆盖后两处路径 SHA-256 复核一致
- 构建耗时约 10.5 分钟（Gradle `assembleRelease` 629.5 秒）；未推仓。

## 待真机验证（没拿到 logcat 的部分）

- 问题 6：点开关后手机顶栏出现 VPN 标识（钥匙图标），外网能打开网页/视频，
  首页显示“运行中 · 已连接 HH:MM:SS”；关开关后 VPN 标识消失。
  若仍显示“运行中”但无 VPN 标识/外网不通，抓 logcat（搜 `TrafficSample` /
  `控制接口无响应` / `VPN_ERROR`）再定位。
- 问题 7：开着开关点首页当前节点弹窗切到 VLESS 节点，不应再报“核心没有响应”；
  各协议节点测速：VLESS/SS/HY2 都应出延迟数字。VLESS 真机仍测不到时抓
  logcat（`latencyFailureReason` 会写明是超时/不在配置里/连接失败）。
- 问题 1/2：粘贴订阅链接（点“粘贴”按钮）与扫码导入；nianba 的旧链接
  本身已失效（面板侧数据问题），须先在面板给 nianba 轮换一次链接再重新
  扫码/粘贴，旧链接怎么导都进不去是正常的。
- 问题 5：点首页当前节点弹窗选节点切换，弹窗里“测速当前节点”只测选中节点。
- 问题 4/8/9：肉眼核对即可。

## 遗留（未做）

- `lib/brand/remote_config.dart` 的 `tunDefault` 字段定义了但全仓没人读，
  是死代码；如需品牌配置控制 TUN 默认值，另起接线任务。
- 问题 7 的 VLESS 真机测速失败根因待 logcat（见上）。
- 本次未推客户端仓；打包自助化（GitHub CI）仍在改，未推。

## 2026-11-26：开关“配置生成失败”＋节点列表分组折叠＋应用内更新（未推仓）

用户 2026-11-26 11:34 在 0367f0df 包上真机报：开开关提示“配置生成失败，已保持上次链接”，首页几种模式也切换不了；另要求首页节点弹窗能测全部/单个节点、选中不挪位置、按订阅分组（默认折叠）；同日 11:46 用户拍板应用内更新先做 GitHub 通道。

### 一、配置生成失败根因：tun 入站的 `"stack": "gvisor"` 被插件内置 schema 拒绝

- 0367f0df 把 TUN 改成默认开之后，每份 `applyNodes` 生成的配置都带一条 tun 入站；上一轮 PATCH_NOTES 称“tun 开/关两份配置 sing-box check 均通过”只对了一半：**真 sing-box 1.14.4 `check -c` 通过**（`stack: gvisor`、裸字符串 `address` 都接受），但 **Dart 侧 `SingBoxSchemaConfigValidator.validate` 报 4 条错**，原文：`Expected to match exactly one schema, but matched 0 at path #root["inbounds"]["1"]`；`Additional property "stack" is not allowed. at path #root["inbounds"]["1"]["stack"]`。
- 消融实测（8 个变体逐字段开关）：只要含 `stack`（gvisor/system 皆然、address 用字符串还是数组皆然）就 4 错；去掉 `stack` 就 0 错。`address` 裸字符串是无辜的——schema 的 address 是 Listable 类型，单串与数组都认。
- 为什么 schema 会拒一个真核心接受的字段：插件包内 schema（`flutter_sing_box-3.1.0/assets/schemas/singbox_schema.json`）tun 分支 `additionalProperties: false`，属性表里根本没有 `stack`。e2d4e6f2 版 TUN 默认关、配置里没有 tun 入站，所以校验能过。
- 链路闭合：TUN 默认开 → 每次生成都带 `stack` → 校验恒失败 → `applyNodes` 返回 `ok:false`、不写盘不重载 → 开关只弹固定文案；模式切换走同一条 `applyNodes`，所以开关与模式切换同时卡死。
- 改动：`lib/core/singbox_config.dart` tun 入站删掉 `'stack': 'gvisor'`，其余字段不动（`address: '172.19.0.1/30'` 裸字符串保留）；不写 stack 时 sing-box 用默认栈（带 gvisor 编译时是 `mixed`，否则 `system`，官方默认）。`config_validator.dart` 不用改——校验器按其内置 schema 办事没错，错的是 builder 发出的字段。
- 报错带真实原因：`_onToggle` 的 `!result.ok` 分支改为 `配置生成失败：<errors 第一条>，已保持上次连接`（超 120 字截断，空错误列表时回落固定文案）；`setMode` 失败时 `errorMessage` 同样写进第一条校验错误，界面显示它不再弹固定句。
- 保留意见：去 `stack` 后默认栈是 `mixed`（TCP 走 system、UDP 走 gvisor），与上一轮明确写 `gvisor` 的行为不完全相同；真机上若出现 UDP/TUN 相关异常，`stack` 字段本身是合法的 sing-box 字段，届时应修插件 schema 侧（或校验器白名单）而不是把 `stack` 加回 builder——加回会立刻重现本次故障。
- 测试：`test/singbox_config_test.dart`（tun 入站不含 `stack` 的回归断言——旧断言 `expect(tun['stack'], 'gvisor')` 已改成 `expect(tun.containsKey('stack'), isFalse)`）、`test/config_validator_test.dart`（TUN 开着的配置过 schema 校验）、`test/routing_mode_test.dart`、`test/home_page_test.dart`（失败提示含真实原因）。

### 二、节点列表：按订阅分组、默认折叠、选中不挪位置

- 节点页（`lib/features/nodes/nodes_page.dart`）：删掉 `_buildGroupSlivers` 里的“当前节点置顶”排序（`selectedName` sort），选中只变边框/底色、位置不动；分组从 A 组/B 组（直连/中转）改成按订阅分（`Node.subscriptionId`/`subscriptionName`，组内保持原顺序，分组顺序按订阅首次出现顺序）；组头可点折叠/展开，默认全部折叠（`_expandedGroups` 记在页面 State，不持久化）。
- 首页节点选择弹窗（`lib/features/home/home_page.dart` 的 `_NodePickerDialog`）：同样按订阅分组、默认折叠；加“测速全部”按钮（调 `testAllSpeeds`，测速中禁用防重复点）；每行点延迟处单测该行（调 `testSingleSpeed`，复用节点页 `_LatencyChip` 做法，测速中该行转圈）；原有“测速当前节点”保留。测速口径不变（通的延迟数字绿色、不通红色圆点）。
- 分组标题：`subscriptionName` 非空用订阅名；缺失回落 `subscriptionId`；两者都没有节点页显示“未分组”、弹窗显示“未命名订阅”；单节点组显示“手动添加”（`SingleNodeStore.singleNodesName`）。
- 测试：`test/nodes_page_test.dart` 25 项、`test/home_page_test.dart` 31 项（含分组/折叠/测速全部/单行测速/选中不挪位置）；5 个旧测试因默认折叠改成先点组头展开再断言（`custom_rules_test` 除外，见上）。

### 三、应用内更新：GitHub 通道实现，自托管只留配置位

- 双通道一次设计到位：`UpdateSource` 抽象（`checkLatest()`），`GitHubUpdateSource`（主）与 `SelfHostedUpdateSource`（备，本轮只抛 `notEnabled`“自托管更新通道尚未启用”，不发任何请求）；更新器按顺序查，主通道查不到/下不了走备通道。
- GitHub 通道：启动后（首帧后）安静查一次，设置页“检查应用更新”手动查；`GET /repos/nbbk/zhexuexi-client/releases/latest`（公开仓无鉴权，未鉴权限流 60 次/小时）；取 arm64 资产 `app-arm64-v8a-release.apk`（精确匹配优先，兜底 `-arm64-v8a-release.apk` 后缀）与同名 `.sha256` 资产。版本比对 semver 2.0 口径（去 `v` 前缀、`+build` 忽略、缺段补 0、预发布链 alpha < alpha.1 < alpha.beta < beta < beta.2 < beta.11 < rc.1 < 正式版）；本机版本优先 `package_info_plus` 读 versionName，读不到回退编译常量 `0.1.0`。
- 下载与安装：下载到应用专属目录 `getApplicationDocumentsDirectory()/updates/`（不用存储权限）；下完核 SHA-256，对不上删文件、抛错、绝不安装；源没给校验值时弹窗如实提示、由用户点“仍要安装”或取消。安装用现成插件 `open_filex 5.0.0`（自带 FileProvider，`ACTION_VIEW` 安装 intent；**侧载必须用户在系统界面点确认，做不到静默安装**）。AndroidManifest 补 `REQUEST_INSTALL_PACKAGES` 权限。无网络、已是最新时安静不打扰；下载失败报原因、可重试。Windows 点安装报“当前平台暂不支持应用内安装”。
- 自托管配置位（`RemoteConfig` 顶层 `update` 对象，只加字段与读法、不接线）：`updateServerBaseUrl`（JSON `update.server_base_url`，以后填如 `https://update.example.com`）、`updateVersionPath`（JSON `update.version_path`，以后填如 `/api/v1/client/version`；服务端须按 GitHub 同款字段回 `{version, download_url, sha256, release_notes}`）。以后实现时只换 `SelfHostedUpdateSource.checkLatest` 为真请求，更新器与界面不用改。
- 新依赖：`package_info_plus ^10.2.2`、`open_filex ^5.0.0`、`path_provider ^2.1.6`（`flutter pub add` 加的）。新文件：`lib/services/app_update/`（semver、update_source、github_update_source、self_hosted_update_source、app_updater、app_update_provider）、`lib/features/update/app_update_dialog.dart`。改动：`lib/brand/remote_config.dart`、`lib/main.dart`（首帧后安静查、`build` 里 `ref.listen` 弹一次）、`lib/features/settings/settings_page.dart`（关于区“检查应用更新”，与原有拉远程配置的“检查更新”分开）。
- ⚠️ 发版前置条件：CI 现在只把 APK 上传为 Actions 产物，不建 GitHub Release；更新器查 `/releases/latest`，在有人把 APK 挂到 Release 上之前会 404，客户端如实报“GitHub 上还没有 Release”。发版时须把 `app-arm64-v8a-release.apk` 与同名 `.sha256` 挂到 Release 上（文件名须与 CI 产物一致），见 `docs/release-checklist.md` §2。CI 首次跑本身也尚未验过。
- 测试：`test/app_update_test.dart` 新增 22 项（版本比对、Release JSON 解析 mock dio、`.sha256` 解析、404/断网、自托管未启用、双通道顺序、下载＋SHA-256 本机回环服务器、`checkQuiet` 状态）；`test/settings_page_test.dart` 新增 2 项。

## 测试结果（协调员在合并后的树上重跑）

- `flutter analyze`：零问题
- `flutter test` 全量：**490/490 通过**（之前 452；新增 app_update 22 项＋节点分组/弹窗净增 16 项；另 5 个旧测试因默认折叠/去 stack 改了断言）
- 构建耗时见下节

## 新 APK

- arm64 release（`--split-per-abi`），109,356,181 字节（约 109.4MB），构建约 10.3 分钟
- SHA-256：`33734b74ba3f0793d9b25297c4e7259964414de0811d19fc1d33bfb770d51a23`（交付路径与 `goals/goal-5/files/` 两处复核一致）
- apksigner 校验通过，证书 SHA-256 与上版完全一致：`2e10202c7a2b365aa9fd4438565bd6b0aa8b7054e215cdad008f01cb182a1d8e`，可直接覆盖安装
- 未推客户端仓

## 待真机验证（没拿到 logcat 的部分）

- 开关：点开关应直接进“运行中”，有 VPN 标识、流量进核心；模式三档切换应成功。若仍失败，新版提示里会直接带出校验原因原文，按那句再查。
- 弹窗/节点页：分组默认折叠、点组头展开；弹窗里“测速全部”与单行测速；选中节点位置不动。
- 应用内更新：须等发版把 APK 挂到 GitHub Release 上才能验（见上“发版前置条件”）：有新版时弹提示、下载、安装确认、装完版本号变了；已是最新/断网时安静。

## 遗留（未做）

- 本次未推客户端仓；打包自助化（GitHub CI）仍在改，未推；CI 首次跑尚未验。
- 去 `stack` 后默认栈 `mixed` 与上一轮明确写 `gvisor` 的行为差异见上保留意见。

## 2026-11-26：开关开着没网络、测速全红点＋设置页“后续版本接入”去掉（未推仓）

背景：用户 2026-11-26 12:46 在 33734b74 版上真机报两件事。Release 上传授权用户说午休起床后再做，本轮没碰 Release、没碰授权。

### 问题 1：开关开着测速全红点、也没网络；关着测速正常

- 根因：DNS 全死路，不是节点不通，也不是 TUN 栈。三处缺陷叠加，TUN 一开（接管全部流量）就全网断网；关着时直连 TCP 探测只连 IP 端口、不需要 DNS，所以测速正常：
  1. 代理 DNS 有引导解析死循环：`dns-proxy` 的服务器是域名 `dns.google`，解析它本身要走 `default_domain_resolver` = `dns-direct`（DoH `1.1.1.1`），国内直连境外解析被拦，`dns-proxy` 永远建不起连接。
  2. DNS final 是直连 DoT `8.8.8.8:853`：未列入规则的域名（包括测速地址 `www.gstatic.com`）都走它，同样被拦，全部解析失败。
  3. 社交 / 流媒体 DNS 与路由不同路：route 把 Facebook / YouTube 指给 Proxy，DNS 规则里却没有这两组，落到 final 走直连解析，死在直连上。
  为什么恰好这一版才爆：TUN 默认开是 33734b74 才落地的，TUN 关着时 App 流量不进核心、走系统 DNS，死 DNS 一直 invisible。
  已排除：TUN 栈（不写 `stack` 是对的，默认 mixed）；节点本身（上轮实测 VLESS 415ms/298ms、SS 通）；测速链路（开着走 Clash API delay 是对的，失败是 DNS 死的后果）。
- 改动（`lib/core/singbox_config.dart`）：
  - `dns-direct`：`1.1.1.1` → 阿里云 DoH `223.5.5.5`（IP 直连，国内可达，无需引导解析）。
  - `dns-proxy`：`dns.google` → `8.8.8.8`（DoH 按 IP + detour Proxy，彻底去掉域名引导依赖）；无节点时同样是 `8.8.8.8` 不写 detour。
  - 删掉 `dns-dot`；`dns.final` 改为：有节点且非直连模式 → `dns-proxy`，直连模式 / 无节点 → `dns-direct`。未列入规则的境外域名也经代理解析，流量本身仍按 route 分流不变。
  - DNS 规则补上社交、流媒体两组，与 route 同路。`dnsSummary` 同步更新。
- 防线（`lib/core/config_validator.dart`）：结构检查新增——带 `detour` 的 DNS 服务器必须写 IP 字面量，用域名就报错，旧写法再出现会在 `applyNodes` 就被拦住。
- 探活加强（`lib/core/singbox_core.dart` `_verifyControlApi`）：`/traffic` 取到帧后，再对当前默认出站做一次真实拨测（`proxyDelayDetailed`，与开着开关测速同一条路；组 tag 沿成员表解到第一个叶子出站）。拨测失败翻成 error，`lastError` 写真实原因；无配置 / 无 Proxy 组时跳过拨测，不误报。旧探活只取 `/traffic` 帧——空闲核心每秒也推 `{"up":0,"down":0}`，只证明控制接口在监听，不证明 DNS / 出站能出网，所以 DNS 全死时首页照样显示“运行中”。
- 测试：`test/singbox_config_test.dart`（DNS 断言同步新口径；新增“DNS 根因回归（2026-11-26）”组 3 项）；`test/config_validator_test.dart`（detour+域名报错 1 项）；`test/core_service_test.dart`（fake 补 `proxyDelayDetailed` 默认测通；新增探活 4 项）；`test/settings_page_test.dart`、`test/diagnostics_test.dart`、`test/custom_rules_test.dart`（仅 DNS 摘要旧字符串同步）。
- 收尾回归（协调员修）：新探活让 `home_page_test` 3 项与 `routing_mode_test` 2 项翻红——两文件的 `_FakeClashApi` 只桩了 `trafficSample`，没桩 `proxyDelayDetailed`，真实现去连 127.0.0.1:9090，widget 测试里 HttpClient 一律回 400，校验把状态翻成 error；首页那 3 项还连带一个未捕获的 `HttpException（/traffic 400）`：探活翻 error 后首页取消流量订阅，恰好撞上 `/traffic` 请求在途，生成器事后抛错时已无监听者。修法是两个 fake 各补 `proxyDelayDetailed` 桩（默认测通）。已知遗留：`trafficStream` 非 200 仍以流错误结束（现有测试 `'/traffic 非 200 时流以错误结束'` 钉死该契约），取消订阅撞上在途请求时仍可能有一条未捕获错误进日志，真机上只记日志、不崩溃；要根治须改该契约，另起任务。

### 问题 2：设置页新版本提醒后面的“后续版本接入”去掉

- 定位：不是自托管通道占位——设置页上根本没有自托管通道的 UI 入口。用户说的那处是 `lib/features/settings/settings_page.dart:354`，「通知」开关行的副标题 `新版本提醒（后续版本接入）` → 改为 `新版本提醒`，只去了括号里 8 个字；「通知」开关、「检查应用更新」、版本号、其他设置项全部保留。高级设置里「分应用代理」的 `Android 专属，后续版本`（第 465 行）不是同一处，没动。
- `RemoteConfig` 的 `update` 配置位与更新器双通道设计原封不动，自托管以后还能接。
- 测试：`test/settings_page_test.dart` 新增「通知行：副标题只写新版本提醒，不再写后续版本接入」。

### 测试结果（协调员在合并后的树上重跑）

- `flutter analyze`：零问题
- `flutter test` 全量：**499/499 通过**（之前 490；新增 DNS 回归 3＋校验 1＋探活 4＋设置通知 1）
- 真 sing-box 1.14.4 `check`：VLESS REALITY + SS + HY2、TUN 开着、规则模式生成的配置 exit 0；dump 确认 dns servers `[dns-direct 223.5.5.5, dns-proxy 8.8.8.8]`、final `dns-proxy`、5 条 DNS 规则。

### 新 APK

- arm64 release（`--split-per-abi`），109,356,181 字节（约 109.4MB），构建约 11.6 分钟（Gradle daemon 连不上重试一次，自行恢复）
- SHA-256：`6fff37cca7df296f723dd04053f2a4d50956be5ef9cd725b11b8e36b4328125e`（交付路径、`goals/goal-5/files/`、kit 构建产物三处复核一致）
- apksigner 校验通过（v2 签名，1 个签名者），证书 SHA-256 与上版完全一致：`2e10202c7a2b365aa9fd4438565bd6b0aa8b7054e215cdad008f01cb182a1d8e`，可直接覆盖安装
- 未推客户端仓；未碰 Release/授权

### 待真机验证（没拿到 logcat 的部分）

- 开关：点开关应直接进“运行中”，顶栏出现 VPN 标识、外网能打开（TikTok、YouTube 分属不同 DNS 规则组，都打开才算全通）；节点页测速应出绿色延迟数字。若仍不通，探活失败会直接显示“代理出站拨测失败：…”而不再是假“运行中”，把这句原样报回来即可定位是 DNS 还是节点问题；另抓 logcat 里含 `sing-box` / `tun` / `dns` 的报错行。
- 设置页：通知行副标题只剩“新版本提醒”，“后续版本接入”已去掉。

## 2026-11-26：启动拨测超时误报修复（未推仓）

背景：用户 2026-11-26 14:14 在 6fff37cc 版上真机报，开开关提示“代理出站拨测失败：拨测超时（5秒无响应）”。

### 根因：5 秒预算不够冷握手走完，不是节点不通、不是客户端 DNS

- 该文案只对应 sing-box Clash API 对 delay 请求回 408/504，即 5 秒等满、不是快失败（快失败是 503，文案会是“拨测失败，可能是 DNS 或节点不通”）。
- 旧探针（`lib/core/singbox_core.dart` `_verifyControlApi`）：ProxyStarted 一到就立即单次拨测、无重试、无预热；`/traffic` 取到一帧就放行，空闲 0/0 也算通过；失败翻 error 且不可逆，须重新点开关；翻 error 并不停核心，VPN 实际还在跑。
- 5 秒预算内要串行完成：冷 VLESS/REALITY 首次握手（手机→中转→落地多段 RTT）＋落地侧解析 www.gstatic.com＋到 Google 的 TLS＋GET；健康 <2 秒，一次丢包重传或落地 DNS 一慢就越线——是误报。
- **修正上一轮的错误说法**：VLESS/VMess/Trojan/HY2/TUIC 类出站的 delay 根本不走客户端本地 DNS，测速域名透传给出站、由落地服务器解析；客户端 DNS（dns-direct/dns-proxy/final）只影响 direct 出站、节点 server 地址是域名时的解析（`default_domain_resolver=dns-direct`）、以及 TUN 真实流量。上一轮“DNS 修好测速”的叙事在这条路上不成立，本轮没有往客户端 DNS 方向修，`_verifyControlApi` 的注释已按此更正。

### 改动

- `lib/core/singbox_core.dart`：
  - `_verifyControlApi` 加容错：取到 `/traffic` 帧后先等 2 秒预热再拨；拨测预算从 5 秒放宽到 10 秒（sing-box 按 16 位解析超时毫秒数，10000 合法）；失败后隔 2 秒重试一次，仍失败才翻 error；重试期间保持 started，不闪 error。预热/重试等待后都重查状态与 controller 是否已关，用户中途点了关或 service 已 dispose 时不翻 error。
  - 容错参数可注入（`probeTimeout`/`probeWarmup`/`probeRetryDelay`，默认 10 秒/2 秒/2 秒），只为测试缩短等待，线上值就是默认值。
  - `_egressProbeTag` 改成组 tag 直接拨：真 sing-box 1.14.4 本地实测（见下），`GET /proxies/{组 tag}/delay` 返回组内当前选用（urltest 的 `now` / selector 的 `now`）的延迟；旧写法拨 `members.first`，成组（twin）节点时它不一定是组实际选用的入站，测的不是当前生效的路。沿成员表解到叶子的循环已删掉。
  - `_delayFailureText`：超时改成“拨测超时（10 秒无响应，已重试一次）：节点响应慢或不通，建议换个节点或再点一次开关”；503 类快失败与控制接口无响应保持原有区分。
  - 新增 `_probeOnce`：每次启动拨测记一行 `debugPrint`（`[CoreService] 启动拨测 tag=… delay=… failure=… …ms`），以后不用 logcat 也能定位。
- `lib/core/clash_api_client.dart`：`proxyDelayDetailed` 的 Dart 侧 getUrl/等响应超时改成拨测预算＋5 秒（启动拨测 10 秒→15 秒；节点页手动测速仍是 5 秒预算→10 秒，与原来一致，各走各的预算）。Dart 超时必须大于服务端预算，否则 Dart 先超时会误报成 apiUnreachable。
- 节点页手动测速的 5 秒（`_speedTestTimeout`）与关开关直连探测的 5 秒都没动。

### 组 tag delay 本地验证（真 sing-box 1.14.4）

- 配置：两个 direct 叶子 `leaf-a`/`leaf-b`、urltest 组 `group-test`、selector `Proxy`（默认 `group-test`），Clash API 监听 127.0.0.1:19090。
- 实测：`leaf-a` delay 175ms；`group-test` delay 263ms；`Proxy` delay 258ms；`GET /proxies/group-test` 的 `now` 是 `leaf-a`、`history` 与组 delay 一致——组 tag 返回的是组内实选的延迟，采用组 tag 拨测。

### 测试

- `test/core_service_test.dart`：fake 补 `delayQueue`（按顺序出队，模拟首次超时、重试后通过）、`delayCalls`/`delayTags`/`lastDelayTimeout`；`makeService` 的预热/重试等待默认传 0，拨测类测试不用等真 2 秒。
- 新增 5 项、改 2 项断言（净增 4 项）：拨测预算 10 秒；首次超时、重试后通过保持 started；两次超时都失败才翻 error（文案含“10 秒无响应，已重试一次”与“换个节点或再点一次开关”，`delayCalls` 为 2）；重试期间保持 started（500ms 重试等待内仍是 started，跑完才翻 error）；预热 2 秒内不拨测（真值，单独一项）；成组节点直接拨组 tag `测试`（旧断言 `测试-reality-443` 已改）；拨测失败（503 类）仍是两次都失败才翻 error。
- `flutter analyze`：零问题；`flutter test` 全量：**503/503 通过**（之前 499）。

### 新 APK

- arm64 release（`--split-per-abi`），109,356,181 字节（约 109.4MB），构建约 4.3 分钟（中途服务重启一次，已重跑成功）
- SHA-256：`fa0c20ae827dcacb93f75261be1de7fcd64d432004d12a20c2093e16aca0e7e3`（交付路径、`goals/goal-5/files/`、kit 构建产物三处复核一致）
- apksigner 校验通过（v2 签名，1 个签名者），证书 SHA-256 与上版完全一致：`2e10202c7a2b365aa9fd4438565bd6b0aa8b7054e215cdad008f01cb182a1d8e`，可直接覆盖安装
- 未推客户端仓；未碰 Release；pubspec 版本仍是 0.1.0+1，没改

### 待真机验证

- 开关：点开关应直接进“运行中”，顶栏出现 VPN 标识，TikTok/YouTube 能打开；节点页测速应出绿色延迟数字。
- 拨测还报不报错：若仍报，把原样文案报回来，并说明报错时 YouTube/TikTok 通不通（通就是拨测本身还误报，不通就是节点/链路真有问题）。
- 注意：新版拨测要等 2 秒预热＋最多两次 10 秒预算，冷节点首次开开关后“运行中”的确认最多比原来晚约 20 秒，期间首页保持“运行中”不闪 error，是正常的。

## 2026-11-26：0.1.2——用户真机反馈 6 条全修（未推仓）

背景：用户 2026-11-26 17:45 在 0.1.1 版上报 5 条（开关开着只有 SS 能测延迟、规则模式没网＋全局慢、公告栏要对接面板、设置页检查更新总失败、夜晚模式我的/设置黑底），17:48 再补第 6 条（开关中心图案按 Logo 原形重画），17:50 再补（公告栏无公告隐藏、有公告跑马灯）。按一单全修。版本 0.1.2+3（versionCode 2003）。

### 第 1 条：开关开着只有 SS 能测延迟

- 根因 A（确定性）：Xray ≥26.9.8 的 REALITY 服务端要求 ClientHello 带 X25519MLKEM768 份额，sing-box 1.14.4 客户端发包前无条件删掉该份额且无配置项可改；落地装 Xray v26.11.9。已查实 JitPack 上 libbox 最新只有 1.14.4（GitHub 最新正式版 v1.14.4，2026-10-24；#4520 在 2026-11-01 仍 open，1.15.0-alpha 也受影响）——**本轮不升级 libbox、不打 fork 补丁**。路线待拍板：客户端打补丁 vs 落地换 fork/降级。
  - 已做：`lib/core/singbox_config.dart` 的 `_realityTlsObject`，`fingerprint` 强制 `'chrome'`（firefox/safari 预设本身不带 MLKEM768 份额）；未加 `support_x25519mlkem768`（1.14.4 schema 无此字段）。
- 根因 B（概率性）：节点页测速 5 秒单次、无预热、无重试、4 路并发；一次 delay 是冷拨号全链路，SS 只需 1 RTT 所以总能挤进 5 秒，其他协议 3–7 RTT，丢一次包就越线。
  - 已做 `lib/services/nodes_notifier.dart`：`_speedTestTimeout` 5→10 秒；`_speedTestConcurrency` 4→2；`_testOneNode` 只在超时失败时重试一次（立即重试；快速 503 不重试）；`testAllSpeeds` 开批前对当前默认出站做一次预热拨测（复用 proxyDelayDetailed，10 秒预算；预热失败只记日志、不阻塞）；失败原因映射：`failed` 且节点是 REALITY 节点（`realityPublicKey != null`）且本次耗时 <1 秒时，原因写“REALITY 握手失败（核心版本问题，可能）”。

### 第 2 条：规则模式没网、全局慢

- 根因 R1：TUN 下流量只有目标 IP，无任何 sniff/fake-ip/reverse_mapping，全部 `domain_suffix` 规则匹配不上，落到 `final=direct` 直连被墙。
  - 已做 `lib/core/singbox_config.dart`：`routeRules` 最前面按顺序加 ① `{'network': 'udp', 'port': 443, 'outbound': 'block'}` ② `{'action': 'sniff', 'timeout': '300ms'}` ③ `{'protocol': 'dns', 'action': 'hijack-dns'}` ④ `{'ip_is_private': true, 'outbound': 'direct'}`；自定义规则排在其后、内置规则之前；三种模式都加。
- 根因 R2：清单缺 Google 基础域。新增 `googleInfraSuffixes`（20 个）；route 与 DNS 规则里与现有 4 组并列各加一条（Proxy / dns-proxy）。DNS 段加 `"reverse_mapping": true`；TUN 入站显式写 `"dns_mode": "hijack"`。
- 全局慢 P1-1：`cnDnsServer` 改为恒为 `dns-direct`（全局模式 `.cn` 也走直连解析；route final 仍为 Proxy，`dns.final` 仍为 dns-proxy）；`dnsSummary` 文案同步改限定。
- P0-4 诊断可见性：`lib/core/clash_api_client.dart` 补 `getConnections()`（GET /connections，返回 chain 拼串列表；失败返回空列表不抛错）；`lib/services/diagnostics_service.dart` 的 `DiagnosticsReportInput` 新增 `configSnapshot` 与 `connectionChains`，设置页 `_exportDiagnostics` 接上（现场 build 当前配置取 route/dns 快照＋调 getConnections）。
- 不做：fake-ip、模式切换改运行时 clash_mode、不要为全局加规则。
- 真 sing-box check（1.14.4，本地）：规则/全局/直连三份生成配置全部通过（exit 0）；TUN `dns_mode: hijack` 被 1.14.4 schema 接受；规则模式 10 条规则、全局/直连各 4 条（前缀），DNS 均有 reverse_mapping。

### 第 3 条：公告栏对接面板

- 契约：`~/workspace/goals/goal-6/announcement-contract.md`（面板 1.4.29；字段 `{id, title, body, pinned, created_at, updated_at}`，`body` 不是 `content`；排序置顶在前、其余 created_at 倒序；空列表返回 `[]` 不返回 null）。
- 已重写 `lib/services/announcement_service.dart`：新增 `Announcement` 模型（`displayLine`＝标题为空取正文首行否则取标题；`fromJson` 里 `body ?? content` 容错；`sortForDisplay` 置顶在前）；`fetchAnnouncements()`（优先级：远程配置单条 → public-info.announcements → GET /api/v1/announcements → login_notice 折单条；三者都没有返回 `[]`；缓存改存列表 JSON 新键 `announcements_list_cache`，服务端明确返回 `[]` 时清缓存，拉取失败返回缓存、无缓存返回 `[]`；`fetchNotice()` 改为首条薄壳过渡）；新增共用 `announcementsProvider`（首页与“我的”页共用）。
- 新建 `lib/widgets/announcement_marquee.dart`（自研不引包；多条逐条滚完切下一条，每条静止 1.2 秒→滚动→末尾静止 1.2 秒→淡出切换 250ms；短文本宽≤可视宽不滚动、静止 3 秒后切下一条；单条长文本在文本后拼一份副本＋48px 间隔无缝循环；速度 50 px/s；切后台停、恢复续跑；减弱动态时静态显示首条标题；语义给完整标题）。
- 首页 `lib/features/home/home_page.dart`：公告栏改为有公告才显示（无公告/加载中/失败无缓存时整卡不存在、不留占位）；内容为单行 megaphone 图标＋Expanded 跑马灯＋chevronRight，整卡 onTap 推公告列表页；跑马灯只滚标题行。
- 新建 `lib/features/announcements/announcement_list_page.dart`（置顶在前、其余 created_at 倒序；每行标题＋正文全文＋时间＋置顶角标；空态“暂无公告”只在页内出现；下拉刷新）。
- “我的”页 `lib/features/me/me_page.dart`：删 `_notice/_noticeLoaded/_loadAnnouncement`，改 watch provider；公告卡有公告才渲染，副标题“共 N 条，点击查看”，chevron 变活、onTap 进列表页；最外层包 GlassBackground；7 处 `Card(` 全换成 `GlassCard`。
- 测试里发现的两个真 bug（已修，见“测试中发现”）。

### 第 4 条：设置页检查更新总失败

- 根因：服务端从未发布 client-config.json（Worker 与 GitHub Raw 都 404）；用户看到的 `failed` 而非 `notPublished`，最可能是 GitHub Raw 在手机直连上超时（两次检查都走裸 Dio 直连、不走代理）。
- 4A（服务端补发布）：payload 按 `docs/api/remote-config.md §1` 写（品牌哲学系 #082E63/#EEC362、面板域名 ccpanel.jiankong.cf、订阅地址模板 `https://cc.jiankong.cf/x9f2/sub_AAA…` 占位令牌、功能开关；`config_version: 1`；无公告、无自托管更新字段），`tools/remote-config/sign.py` 签名并 verify 通过（公钥与客户端编译进的一致），推到客户端仓根目录 main 分支；Raw 验 200 且验签通过（见“发布”）。
- 4B（客户端兜底）：`lib/services/remote_config_service.dart`——`RefreshResult` 加 `failures` 列表（url、kind：notFound/timeout/connectionError/httpStatus/invalidEnvelope、message）；`attempted++` 提到每次尝试前；`validateStatus: (_) => true` 单路径收 404；`refresh()` 每条地址结局打一行 debugPrint；`notPublished` 判定不变。404 计数两路都保留（生产 Dio 开了 validateStatus 后 404 走 Response 分支计数，测试 mock 的拦截器 reject 仍以 DioException 走 catch 分支计数；每次尝试只数一次）。
- 设置页 `lib/features/settings/settings_page.dart` 的 `_checkUpdate()` 的 `failed` 分支改文案：先一句定性再逐条列原因，并注明“检查走手机直连，不走代理，开关开了也帮不上”；`notPublished` 文案不动。“检查应用更新”失败弹窗里同样注明走手机直连。
- 用户点的到底是哪一项：用户原话“设置页检查更新（拉取远程配置）每次都失败”，对应 `_checkUpdate`（标题“检查更新”），与 `_checkAppUpdate`（标题“检查应用更新”，查 GitHub Release）是两个入口；按括号里的“拉取远程配置”定为前者。

### 第 5 条：夜晚模式“我的/设置”黑底

- 根因：首页/节点包了 GlassBackground（夜晚渐变 #070F1C→#082E63→#0B3D84），我的/设置是裸 ListView 露出 Scaffold 纯色 #070F1C（肉眼近黑）；我的页 7 张原生 Card 走 M3 默认深色 surface；设置页无卡片全裸 ListTile。
- 已做：me_page 最外层包 GlassBackground，7 处 Card 全换 GlassCard；settings_page.dart:354 只包一层 GlassBackground 其余不动；app_theme.dart 的 themeData 里补 cardTheme（夜晚白 8%、白天象牙白 60%、surfaceTintColor 透明）与 dialogTheme（夜晚 #082E63、白天象牙白）；login_page.dart:78-83 同样包 GlassBackground（同类问题顺带修）。不改 token 值本身。

### 第 6 条：开关中心图案按 Logo v1 原形重画

- v1 定稿是金色实心哲人脸（`assets/logo/logo.png`），“留白脸”是 v2 备选；按 v1 做。只改 `lib/widgets/power_button.dart` 的 SignalPhilosopherPainter.paint 及注释；不动 home_page、app_theme、app_tokens、app_motion，不动点击区域与交互逻辑。
- 脸：实心填充剪影（锚点按清单）；眉眼用 PathFillType.evenOdd 镂空进同一条脸路径。胡子：3 股填充须片。月桂：茎＋7 片填充椭圆叶。信号弧：弧心 (0.59,0.48)，半径 0.13/0.24/0.34，起角 -1.22 扫角 2.44，逐圈点亮 alpha 公式与错开量一字不动。颜色：脸/须/叶/弧继续共用传入 color（开态 goldHighlight #F4D89A）；透明度沿用现状。动效全部不动。
- golden 肉眼验收后调了一处（DEV-PLAN.md 同步更新）：眉底与眼顶原先重叠（0.33/0.313），镂空连成一个深色团；眉收窄到 y 0.28–0.315、眼下移到圆心 (0.49,0.36) 半径 0.027，两者分开才像 Logo（眉是斜杠、眼是圆点）。其余锚点不动。
- 文档同步：power_button.dart 注释、app_theme.dart:6、DEV-PLAN.md（§14.5 与 1392 行附近）、CHANGELOG.md 旧几何记录已同步更新；home_page.dart:551-552 的过期“蓝→紫渐变”注释顺手改掉。

### 测试中发现（本轮修掉的两个真 bug）

- GlassCard 里 ListTile 断言报错：我的页 7 张原生 Card 换成 GlassCard 后，GlassCard 是 Container＋BackdropFilter、没有 Material 祖先，里面的 ListTile 在 debug 下直接断言“ink splashes may be invisible”（我的页全部测试＋导航测试共 20 多例因此失败；release 下不崩但水波纹画不出来）。修法：`lib/widgets/glass_card.dart` 内包一层透明 Material（`MaterialType.transparency`＋圆角裁剪），全端受益；不是测试问题。
- 跑马灯滚动位移恒为 0：`AnnouncementMarquee` 的 `distance` 是 build 时捕获的旧值（首次 build 时 `_textWidth` 还是 0，distance=0），而 `_startItem/_startScroll` 不触发 setState、build 永不重跑——控制器在转、位移恒 0，生产环境也一样不滚。修法：AnimatedBuilder 的 builder 里实时读 `_scrollDistance`；另补 ClipRect＋OverflowBox（长文本 Row 原先报 overflow 错误）。测试里还发现 flutter_test 的帧时间 quirks：在测试体里调 `forward()` 后第一次 `pump(duration)` 不推进 ticker（生产环境帧连续跑，不受影响），恢复续跑测试里先热身一帧。

### 测试

- `flutter analyze`：零问题。
- `flutter test` 全量：**565/565 通过**（之前 521；新增/改动约 44 项，含新建 announcement_marquee_test、announcement_list_page_test、night_background_test、power_button_logo_test）。
- 真 sing-box 1.14.4 `check`：规则/全局/直连三份生成配置全部通过（exit 0）。
- golden：`test/goldens/` 7 张（48px 开/关态×日/夜、动画进度 0/0.5/1 三帧、120px 大档）；首次生成后人工对照 `assets/logo/logo.png` 肉眼验收通过（48px 与 120px 两档；眉眼分离那处按上文调过并重新生成）。

### 新 APK

- arm64 release（`--split-per-abi`），109,421,717 字节（约 109.4MB），构建 602 秒
- SHA-256：`58da41d57aa9d58a4cfb8e726aa596e29a8302148f7bc383a1371bdeb7ccb72e`（交付路径、`goals/goal-5/files/`、构建产物三处复核一致）
- apksigner 校验通过（1 个签名者），证书 SHA-256 与上版完全一致：`2e10202c7a2b365aa9fd4438565bd6b0aa8b7054e215cdad008f01cb182a1d8e`，可直接覆盖安装
- aapt2 核实：versionCode='2003' versionName='0.1.2'
- 未推客户端仓；Release 见“发布”。

### 发布

- Release v0.1.2（新建 tag，旧 v0.1.1 不动）：https://github.com/nbbk/zhexuexi-client/releases/tag/v0.1.2（Release id 459305129）。资产核对通过：`app-arm64-v8a-release.apk`（资产 795528214，109,421,717 字节，digest sha256:58da41d5…b72e 与本地一致）、`app-arm64-v8a-release.apk.sha256`（资产 795528007，65 字节）；说明含“本包 versionName 0.1.2”。
- client-config.json：已推客户端仓根目录 main 分支（提交 a54869007012860c9a05c91870a232c5373371b3，父提交 65473362）；Raw 验 200（801 字节）、验签通过、与签名文件逐字节一致；config_version 1，panel_domain ccpanel.jiankong.cf。

### 待真机验证（没拿到 logcat 的部分）

- 开关开着各协议测速：节点页 8 个节点应出绿色延迟（REALITY 节点若仍 1 秒内失败，看失败原因是不是“REALITY 握手失败（核心版本问题，可能）”——是则说明仍是 libbox 缺 MLKEM768，走待拍板路线；不是则按新失败原因继续查）。
- 规则模式 YouTube：应能打开（sniff＋Google 组＋.cn 直连解析）；全局模式应比原来快（.cn 直连解析）。
- 设置页检查更新：4A 发布后应不再失败（若仍失败，看弹窗里逐条列的原因，区分是 Worker 404、Raw 超时还是验签失败）。
- 夜晚模式四个页面：首页、我的、设置、登录的背景应都是同一套深蓝渐变，不再有纯黑页；我的页卡片应是毛玻璃。
- 公告栏：无公告时首页不留占位；有公告时跑马灯滚动，点进列表页看全文。
- 开关新图案：中心应是金色实心哲人脸＋月桂＋三道信号弧，开/关状态一眼分清，动效与原来一致。

## 2026-11-26：0.1.3——libbox REALITY 补丁版核心＋登录页域名栏隐藏＋D 路 P0 修复（未推仓）

背景：用户 2026-11-26 19:35 拍板 REALITY 走客户端打 libbox 补丁（不降级、不换服务端 Xray、不换核心）；19:43 问“既然客户端能拿远程配置，登录为什么还要输面板域名”，19:46 再定域名栏隐藏＋“使用其他面板”入口（覆盖 19:43 的“自动填入并显示”做法，以隐藏为准）；20:26 D 路 P0 调查结论派发，并入同一版（第 3 条）。版本 0.1.3+4（versionCode 2004）。

### 第 1 条：libbox 打补丁（REALITY 握手带 X25519MLKEM768 份额）

- 根因（A 路实测，见 `~/workspace/libbox-patch/PATCH_DESIGN.md`）：Xray ≥26.9.8（XTLS/REALITY `8cdf7bf9`）拒收没有 X25519MLKEM768 份额且排在 X25519 之前的 ClientHello；sing-box 1.14.4 在 `common/tls/reality_client.go` 里发包前无条件删掉该份额，session id 里写的客户端版本还是 1.8.1（Xray 26.7.11/26.7.28 默认 minClientVer 26.3.27）；utls v1.8.7 里只有 Chrome 133 预设带混合份额，firefox/safari 预设没有。
- 补丁（Tunl 原样复用，不自己重写）：`patches/reality-xray.patch`（94 行，改 sing-box 本体：份额保留＋会话 ID 版本 26.3.27＋无 plain X25519 份额时 auth key 回退到混合份额的 X25519 一半＋randomized hello 改 `HelloRandomizedALPN` 并强制每次带份额与 ALPN）与 `patches/utls-presets.patch`（579 行，改 metacubex/utls v1.8.7：加 Firefox 148 / Safari 26.3 hello 预设，`HelloFirefox_Auto`/`HelloSafari_Auto` 改指新版）。两份补丁 SHA-256 与 Tunl 原文一致（见 PATCH_DESIGN §7）。
- 应用结果：reality 补丁应用成功，3 处 hunk 各偏移 1 行（A 路 dry-run 已记录，属正常行号漂移，无失败）；utls 补丁应用成功，无偏移；utls 自带测试通过（`ok github.com/metacubex/utls`）；`go.mod` 用 `go mod edit -replace github.com/metacubex/utls=../work/utls` 指到打好补丁的 utls 副本（没改 module cache）；`go version -m` 核对产物显示 `metacubex/utls v1.8.7 => ../work/utls`，replace 生效。
- 没走的路线：MarbleNG 的 `support_x25519mlkem768` 配置开关——上游 1.14.4 的 `OutboundRealityOptions` 只有 Enabled/PublicKey/ShortID 三个字段，无此开关（PATCH_DESIGN §2.3），不另加字段；无条件补丁已覆盖全部 REALITY 出站。
- 构建：Go 1.26.10（`~/workspace/toolchains/go-1.26.10/`，取自该 tag 的 `.github/workflows/build.yml`，不是 go.mod 最低版 1.25.5）、gomobile/gobind v0.1.13（sing-box Makefile `lib_install` 的版本）、官方 `cmd/internal/build_libbox`（`-target android -platform android/arm64`，tag 含 `with_utls`，主变体 API 24）。构建脚本 `tools/build-patched-libbox.sh`（幂等：补丁已打过自动跳过；正反都贴不上就报错停下，不硬改），只跑它就能复现。
- 坑：`/tmp` 只有 512M tmpfs，Go 构建临时目录默认走 `/tmp`，编 sing-box 编到一半报 `no space left on device`；脚本里 `GOTMPDIR`/`GOCACHE` 一律走 workspace（`~/.tmp/go-build`、`~/.cache/go-build`）。
- 接线：`packages/flutter_sing_box/android/build.gradle.kts` 第 89 行 `implementation("com.github.singbox-android:libbox:1.14.4")` 改为 `implementation("io.nekohasekai:libbox:1.14.4-patched")`，仓库声明在根 `android/build.gradle.kts` 的 `allprojects` 里（插件模块自己的 `allprojects` 声明不会进 `:app` 的解析，实测连败两次都是在这里没声明），JitPack 仓库一并移除；AAR 在 `packages/flutter_sing_box/android/libs/maven-repo/io/nekohasekai/libbox/1.14.4-patched/libbox-1.14.4-patched.aar`（只含 arm64，客户端只发 arm64 APK；换 ABI 要重编 AAR）。不要改回 `files("libs/*.aar")`：AGP 禁止 library 模块直接依赖本地 .aar（`bundleReleaseAar` 的 `hasLocalAarDeps` 检查，0.1.3 首版构建即因此失败）。AAR 的 javapkg 仍是 `io.nekohasekai`，Kotlin 侧 import 不动；AAR 不提交进任何 git 仓（kit 本身不是 git 仓，放 kit 内即可）。副产物 `libbox-legacy.aar`（API 21、无 naive）不接进插件。
- REALITY 指纹仍强制 chrome（`lib/core/singbox_config.dart` 的 `_realityTlsObject` 不动；不要加 `support_x25519mlkem768`，1.14.4 schema 没有这个字段）。
- 对照的上游与出处：上游 issue SagerNet/sing-box#4520（截至 2026-11-01 仍开着，1.15.0 alpha 同样删份额）；Tunl `packaging/sing-box/reality-xray.patch` 与 `utls-presets.patch`（dbelokursky/tunl）；MarbleNG `docs/REALITY_MLKEM_HANDSHAKE_V194.md`（开关路线，本轮未采用）。
- 长期：libbox fork 当正式组件养（CI 定期跟进上游发版、rebase 补丁）；上游 #4520 修好之日 `reality-xray.patch` 即可丢弃，metacubex/utls 自带 Firefox 148 / Safari 26.3 hello 之日 `utls-presets.patch` 即可丢弃；每次升 sing-box 大版本都要重跑 `--check`。

### 第 2 条：登录页域名栏隐藏（最终做法，19:46 定）

- 远程配置拉到时：登录页只留账号＋密码两个框，域名栏不渲染、不在屏幕上暴露域名；页面右下角放一个小的“使用其他面板”文字入口，点开后才出现域名输入框（里面预填当前值，可改，自建面板的人用）。
- 远程配置拉不到时：域名输入框直接显示出来让用户手填（原来的兜底不变，占位符仍是 `panel.example.com`，不出现真实域名）。
- 远程配置晚到（打开登录页时还没拉到）时：拉到后把值填进域名框（用户没动过框才填）；框当时可见且用户没动过，就跟着藏起来；用户亲手改过框或点过入口的，不动。
- 解析顺序不变：手填值优先 → 远程配置 panel_domain → 两边都没有时不发请求、提示“请先拉取远程配置或填写面板域名”。实现：`lib/services/auth_notifier.dart` 新增纯函数 `AuthNotifier.resolvePanelDomain`（手填归一化后非空就用它；否则远程归一化后非占位就用它；否则 `''`），`login()` 开头先解析、空值直接置错返回（不调登录服务），`saveLastPanelDomain` 存解析后的值。登录的其他逻辑（账号密码、订阅绑定、管理员兜底）一律不动。
- 改动位置：`lib/services/auth_notifier.dart`（`resolvePanelDomain`＋`login()`），`lib/features/auth/login_page.dart`（显隐＋入口＋晚到补填）。
- 测试（共 4 条，见“测试”）：解析顺序 3 条（远程有值→用它；手填优先；两边都没有→提示手填且不发请求）＋域名栏显隐 1 条（拉到配置时不显示、点入口后才出现）。

### 第 3 条：D 路 P0 修复（断网＋远程配置，20:26 派发并入 0.1.3）

背景：用户 2026-11-26 19:54 报 0.1.2 还是没网络（规则和全局两个模式都没网、相对 0.1.1 退化，远程配置也拉取不到），20:03 发来诊断包（核心已连接、当前节点测试机-hy2-443-A 延迟 604ms、订阅 19:49 能更新、TUN 开、DNS 直连 DoH 223.5.5.5、代理 DNS DoH 8.8.8.8（经 Proxy）、策略 ipv4_only、reverse_mapping 开、无 UDP 53 回落、最近错误：无），20:17 再补“开开关后手机完全没网，微信都连不上”。D 路调查完整报告见 `~/workspace/d-route-invest/REPORT.md`。

- 调查结论（D 路）：沙箱复现不出来——诊断包原样配置在真 sing-box 1.14.4 上 SOCKS 路径 6/6 全通，逐条关 QUIC 阻断/sniff/hijack-dns/私网旁路/reverse_mapping/全部前缀也全通；两条 DNS 腿分开测都通。证据链把故障段锁定在 TUN 入口 → DNS：开关一开全断、一关全好；微信域名不在任何分流组、规则模式流量走 final=direct 根本不碰节点——它死说明死在出站之前；HY2 延迟 604ms 证明出站是好的；订阅能拉证明手机直连通。五项逐一排除后，只剩 DNS 劫持对（hijack-dns 路由规则＋TUN dns_mode: hijack）与 TUN 本身，而这两样沙箱恰恰测不到（禁建 TUN、禁全部 UDP）。手机上只剩两种子情况：A）本地 DNS 两腿在手机上都不通；B）劫持在 TUN+UDP 路径上不触发或应答回不去。须用户真机验证第 1 步才能定。
- “运行中”为什么没翻 error：0.1.2 启动探活只拨 Clash API delay，直拨出站，绕过 TUN、绕过路由规则、绕过客户端 DNS；且探活失败只写探活位，不翻 CoreStatus.error、不进“最近错误”。注意：PATCH_NOTES 里 fa0c20ae 一节写的“仍失败才翻 error”与现行代码不符，以代码为准，本轮不再抄那句。App 自身流量因 UID 排除根本不走 TUN，应用内任何探针都测不到 TUN 那条路，唯一应用内信号是 Clash API /connections 的实时连接链。
- 远程配置（D 路核实）：三个端只有一个能 served——Raw 200（801 字节，唯一可用）；Worker 404 "client-config.json upstream not configured"（路由在、只缺上游配置）；面板 :11111/client-config.json 404（同机 /api/v1/public-info 200）；面板 443 根本不通。另有客户端 bug：`remote_config_service.dart` 用 `https://$panelDomain/client-config.json` 拼地址，panel_domain 无端口→打到 443，即使面板 1.4.29 加了路由也打不到。已核代码：启动 unawaited(init())、登录只读缓存域名、失败回退缓存/默认值——远程配置失败不可能拖垮联网，两个 P0 是独立故障。
- 修复 1（断网第 1 步，`lib/core/singbox_config.dart`）：删路由前缀里的 `{'protocol': 'dns', 'action': 'hijack-dns'}`，并删 TUN 入站的 `'dns_mode': 'hijack'`——两者是同一机制的两端，必须一起开关，只去其一更差；其余（sniff、QUIC 阻断、私网旁路、Google 组、reverse_mapping、两路 DoH）不动。这是“须真机验证的定罪步骤”：恢复→情况 B；仍断→第 2 步删 QUIC 阻断→第 3 步删 sniff（这三步不要一次全做完，要留给真机逐级验证；第 2、3 步只写在这里作预案，不要现在就删）。不为修 DNS 加 fake-ip（0.1.2 已定 P2 不做）、不加明文 UDP 53 回落、不动两路 DoH 服务器地址。
- 修复 2（“运行中”说真话）：诊断导出加探活状态行（`lib/services/diagnostics_service.dart`：`DiagnosticsReportInput` 加 probeFailed/probeError/probeAt，`buildDiagnosticsReport` 加“启动探活：…”行；设置页 `_exportDiagnostics` 从 `core.probeState` 传入）；启动探活（Clash delay）通过后再加一次经本地 mixed 入站（127.0.0.1:2080）的 HTTPS GET 拨测（`lib/core/singbox_core.dart`：`_probeRealTrafficAfterDelay`＋`_probeRealTraffic`，GET `https://www.gstatic.com/generate_204`，10 秒超时，收到任何 HTTP 响应即算通；失败只写探活位，文案“真实流量不通：DNS 或路由可能有问题”），并在注释写明应用内探针永远测不到 TUN 入口（只能看 /connections）。首页探活失败副标题自动带出新文案，无需另改。真实流量复核做成可注入的构造器参数（`realTrafficProbe`，默认走真实现），测试注入 fake。
- 修复 3（远程配置客户端侧，`lib/services/remote_config_service.dart`）：面板 URL 改从 panel_api_base 派生（`cached?.panelApiBaseOrDerived`，去末尾斜杠后加 `/client-config.json`；panel_api_base 为空时回落 `https://$panelDomain`）；已核实已发布配置含 `"panel_api_base": "https://ccpanel.jiankong.cf:11111"`，派生在生产上能生效。每地址网络失败后重试一次（只重试没收到任何 HTTP 响应的网络层失败；404 与其他 HTTP 状态码是服务器明确回答，不重试），并显式设 connectTimeout（以前只设了 send/receive）；开关已开时经本地 mixed 入站再试一轮（`createProxyDio`：`IOHttpClientAdapter.createHttpClient` 设 `findProxy` 到 `PROXY 127.0.0.1:2080`；接线在 `remote_config_notifier.dart` 的 provider，`coreStarted` 回调读 `coreServiceProvider`，无 import 环路）；`RemoteConfigAttemptFailure` 加 `viaProxy` 标记，`failureMessage` 里代理轮的失败带“（经代理）”。notPublished 判定按“每个地址至少有一轮回 404”算（两轮都跑时不按尝试次数算）。
- 不归本轮的两项（不要做，协调员另行处理）：服务端 Worker 填 CONFIG_UPSTREAM（环境变量）、面板 1.4.29 加公开 GET /client-config.json（与面板公告协调员协调）。
- 测试（见“测试”）：劫持对一起开关的回归断言（三种模式＋TUN 开/关全查）、探活状态进诊断导出 2 条、真实流量不通 1 条（delay 通但复核失败→只记探活失败不翻 error）、面板 URL 派生用 :11111、三源回退顺序、每地址重试一次（404 不重试）、代理轮（开关开/关、两轮都败标“经代理”）。

### 测试

- `flutter analyze`：零问题（最后一次复核含 3 条 info 已清：`createHttpClient` 替代已废弃的 `onHttpClientCreate`、两处 `prefer_initializing_formals` 用 ignore 注明原因）。
- `flutter test` 全量：577/577 通过（0.1.2 是 565/565；新增 12 条：登录 4 条——`auth_notifier_test.dart` 解析顺序 3 条、`login_page_test.dart` 域名栏显隐 1 条；D 路 8 条——`diagnostics_test.dart` 探活进诊断包 2 条、`core_service_test.dart` 真实流量不通 1 条、`remote_config_test.dart` 面板 URL 派生/重试/代理轮 5 条；劫持对回归是改写 `singbox_config_test.dart` 原有 1 条，不新增计数；临时导出测试 `tmp_check_dump_test.dart` 只用来打 check 配置，跑完即删，不进套件。）
- 真 sing-box `check`（打好补丁的 sing-box 二进制，Go 1.26.10 编）：0.1.3 生成配置（VLESS REALITY＋SS＋HY2、TUN 开、规则模式）exit 0。配置由 `SingboxConfigBuilder.build(..., mode: rule, tunEnabled: true)` 生成（`~/workspace/libbox-patch/work/check-config-0.1.3.json`，D 路修复后重生成：route 规则 9 条、无 hijack-dns、TUN 无 dns_mode）。

### 新 APK

- 产物：`~/workspace/goals/goal-5/files/zhexuexi-client-release-arm64.apk`（`~/workspace/your_files/` 下同名文件是软链，两处 SHA 一致），旁有同名 `.sha256` 文件。
- SHA-256：`1f70b3a16d71afa75902b7f3860536f2582374b1cd5ce6e01f2e1317464100a2`，109,454,481 字节（比 0.1.2 的 109,421,717 字节大 32,764 字节）。
- `apksigner verify`：exit 0（1 个签名者）；证书 SHA-256 `2e10202c7a2b365aa9fd4438565bd6b0aa8b7054e215cdad008f01cb182a1d8e`，与上版一致（同一把 release 签名，可直接覆盖安装）。
- `aapt2 dump badging`：`package: name='com.zhexuexi.client' versionCode='2004' versionName='0.1.3'`，label「哲学系」。
- APK 内 libbox 核对：`lib/arm64-v8a/libbox.so` 80,954,824 字节，与 AAR 内 .so（80,954,832 字节）逐字节比只差 891 字节（全在 ELF 头与尾部元数据区，AGP 重打包所致），代码段一致，确为补丁版（不是 JitPack 旧版）。
- 构建波折（本轮新增）：首版 `implementation(files("libs/libbox.aar"))` 被 AGP 拒绝（`bundleReleaseAar` 的 `hasLocalAarDeps` 检查，library 模块不能直接依赖本地 .aar，首版构建 9m39s 后失败）；改本地 Maven 仓坐标 `io.nekohasekai:libbox:1.14.4-patched` 后，插件模块自己的 `allprojects` 声明又不进 `:app` 的解析（两次 18 秒快失败，`Could not find` 且搜索列表里没有 file 仓）；最后改根 `android/build.gradle.kts` 的 `allprojects` 声明、uri 先在根 project 算好绝对地址，才通过。仓库位置：`packages/flutter_sing_box/android/libs/maven-repo/io/nekohasekai/libbox/1.14.4-patched/`（aar＋pom＋metadata，由 `tools/build-patched-libbox.sh` 第 7 步生成，只跑脚本就能复现）。

### 待真机验证（没拿到 logcat 的部分）

- REALITY 节点：试点 REALITY 入站＋chrome 指纹应通（补丁前后对照：0.1.2 包失败、0.1.3 包成功）；firefox/safari 指纹也应通（两份补丁都打才过）；randomized 多重启几次客户端，每次都应通。
- 登录页：有远程配置时只见账号密码、没有域名栏；点“使用其他面板”出现域名框（预填当前值）；自建面板改地址后登录走改后的地址；远程配置拉不到时域名框直接显示。
- D 路第 1 步（定罪步骤，必验）：开开关后微信/YouTube 是否恢复——恢复即定罪情况 B（劫持对是元凶，0.1.3 已去掉它）；仍断则按第 2 步删 QUIC 阻断、第 3 步删 sniff 逐级验证（不要一次全做）。同时确认：设置页“检查更新”是否拉通（面板 :11111 派生＋代理轮）、诊断包里“启动探活”一行是否如实反映状态、远程配置失败时设置页是否逐条列出各地址原因（含“（经代理）”标记）。
- 0.1.2 的待真机验证项仍有效（规则模式 YouTube、设置页检查更新、夜晚模式、公告栏、开关新图案）。

## 2026-11-26：0.1.4——删 QUIC 阻断（D 路第 2 步）＋补丁版 libbox 打版本戳＋远程配置三处死代码修复（未推仓）

背景：用户 2026-11-26 21:39 发来 0.1.3 诊断包（核心版本 unknown、核心状态未连接、当前节点测试机-hy2-443-B 延迟 1041ms、hijack-dns 已删但还是没网、启动探活通过、最近错误无），21:40 再强调规则和全局两个模式都没有网络、远程配置也拉取不到。三路调查并行（报告见 `~/workspace/014-invest/`）：A 路（AAR 取证）、B 路（路由/DNS 复现＋全局核对）、C 路（远程配置）。

### 证据链（三个“以为是故障、其实不是”的定性，0.1.4 的改动全从这里来）

- **0.1.2 与 0.1.3 两份诊断包的对比**：0.1.2 诊断包是开关开着时导出的（核心已连接、延迟 604ms、订阅能更新）——它证明的是“核心在跑、仍全断”的真故障；0.1.3 诊断包是开关关着时导出的（核心未连接＋最近错误无＝干净停止态，测速 1041ms 走的是核心停着时的直连 TCP 回落口径，探活“通过”是 `probeFailed` 默认 false 的谎言）——它对“开关开着通不通”这个问题是沉默的，既不能证明补丁版核心起不来，也不能证明删 hijack-dns 的第 1 步失败。结论：不要因为 0.1.3 诊断包就认定第 1 步失败、也不要回头怀疑补丁；断网仍按 D 路预案逐级验证。
- **补丁版 AAR 核查结果（A 路）**：0.1.3 APK 内 `libbox.so` 与补丁版 AAR 内 `.so` 代码段逐字节一致（891 个差异字节全在 ELF 节头表与 `.shstrtab` 元数据区，AGP 重打包所致），无 JitPack 旧版残留、无第二份 libbox；诊断包能印出字面量 `unknown` 而不是 `—`，证明 `Libbox.version()` 的 JNI 调用在真机上成功执行、`.so` 已加载。`unknown` 本身是构建缺陷：补丁源码树不是 git 仓，`build_libbox` 靠 `git describe --tags` 读 tag 读不到，默认值就是 `unknown`。
- **真 sing-box 复现结果（B 路）**：上游 1.14.4 与补丁版两份配置、原样／去 QUIC／去 sniff 各变体合计 48 次 curl 零失败；两条 DNS 腿分开测都通；QUIC 阻断经核 sing-box 源码不可能误伤 HY2（路由规则只对入站连接求值，HY2 出站直接拨号）。沙箱复现不出，删 QUIC/删 sniff 在沙箱里是无效果改动，只能由真机 A/B 定罪。
- **远程配置三处死代码（C 路）**：① 面板地址首跑根本不进地址链（`defaultConfigUrls` 只在已有缓存且 `panel_domain` 非占位时才加；用户从未成功缓存过，包内默认 `panel.example.com` → 面板 URL 整段跳过；0.1.3 的派生修复只在第二份及以后的拉取生效，首跑是死代码）；② 代理轮被静默跳过（门是 `CoreStatus.started` 不是“开关开着”；0.1.3 诊断包未连接＝stopped，代理轮不跑且 `failures` 里不留任何痕迹；App 无任何自动起核心逻辑，启动时后台拉取永远跑不到代理轮）；③ “启动探活：通过”是默认值谎言（`probeFailed` 初始 false，一次没探过也印通过）。另有：设置页 failed 尾注仍写“开关开了也帮不上”（与代理轮矛盾）；启动拉取未跑完时点检查更新返回合成的“已是最新配置（v0）”；检查更新全程无进度提示。远程配置失败不可能拖垮联网（0.1.3 代码再核，结论不变）。服务端现状：面板 1.4.29 已推（main 5eaa6390），公开 `GET /client-config.json` 已有，但须管理员升完后在设置页粘贴已签名信封发布才回 200；Worker `CONFIG_UPSTREAM` 仍未填。**更新（2026-11-26 22:01，用户回报）：已签名信封粘贴发布后远程配置可以获取了，面板 1.4.29 的 `GET /client-config.json` 已确认通；真机验证远程配置时不再有“面板源仍 404 是预期内”的前提——0.1.4 上还拉不到，直接按客户端侧查。**

### 第 1 条：路由第 2 步——删 QUIC 阻断（唯一的一条路由改动）

- 删 route 前缀里的 `{'network': 'udp', 'port': 443, 'outbound': 'block'}`，规则与全局两份配置一起删（`lib/core/singbox_config.dart`，前缀从 3 条变 2 条：sniff、私网旁路）。sniff（第 3 步）这次不删，留待真机验证第 2 步后再定。其余路由/DNS（Google 组、reverse_mapping、两路 DoH、.cn 口径）不动；不加 fake-ip、不加明文 UDP 53 回落。
- 生成配置核对：规则模式 8 条（首条 sniff）、全局模式 2 条；两份都无 QUIC 阻断、无 hijack-dns、TUN 无 dns_mode。

### 第 2 条：补丁版 libbox 打版本戳（A 路 P0-1，硬门槛：真机版本行须变成 1.14.4-patched）

- `tools/build-patched-libbox.sh`：第 5 步之前给源码树打 tag 再编（`git init` + commit + `git tag v1.14.4-patched`，`ReadTag()` 读到 `v1.14.4-patched` 后去 `v` 前缀、`LinkerFlags` 钉进 `1.14.4-patched`）。脚本幂等（tag 已存在就跳过，补丁已打过也跳过，两者互不干扰）。坑：不要写 `git add -A -- ':!libbox.aar'`——树自带的 `.gitignore` 已有 `/*.aar`，带 `:!` 排除的 pathspec 会把被忽略文件当显式指定而报错退出（exit 1）；直接 `git add -A` 就会按 `.gitignore` 跳过两个 `.aar`。第 5b 步的 Linux 校验二进制也加了 `-ldflags "-X ...constant.Version=1.14.4-patched"`。
- 验法（以真机版本行为准，`go version -m` 本次连 `-ldflags` 都没印出，只看它不够——gomobile 的 c-shared 构建不把 `-ldflags` 写进 build 设置）：重编后 `sing-box-patched version` 印 `sing-box version 1.14.4-patched`；新 AAR 内 `.so` 含 `1.14.4-patched` 字面量 1 处（旧版 0 处）；新旧 `.so` 逐节比对：`.text` 仅 103 字节差、`.rodata` 177 字节差（全是版本串 `unknown`→`1.14.4-patched` 换来的布局位移）、`.rela.dyn` 2 字节、`.data` 1 字节——补丁代码本身未动。APK 内 `.so` 与新 AAR 内 `.so` 各节逐字节一致，`cmp` 只差 891 字节（与 0.1.3 同数，全在 ELF 元数据区）。
- REALITY 握手对照重跑（试点美国01 23.129.180.189，reality-443，`verify/patched/run-one.sh`）：新补丁版两次 curl 200（0.68s / 0.46s），随后未补丁版对照仍 `reality verification failed`（exit 97，0.48s）——补丁未退化。

### 第 3 条：诊断包诚实化（A 路 P0-2＋B 路）

- `lib/services/diagnostics_service.dart`：`probeAt == null` 时探活行印“启动探活：未探活（核心未启动或尚未拨测）”，不再印“通过”；只有 `probeAt != null && !probeFailed` 才印“通过（最近结果：<时间>）”。最近结果无时间戳时同样标明未跑过。

### 第 4 条：远程配置 P0-1——修鸡生蛋（C 路 §5）

- `lib/services/remote_config_service.dart`：新增包内品牌 fallback `bundledPanelApiBase = 'https://ccpanel.jiankong.cf:11111'`（与已发布 `client-config.json` 的 `panel_api_base` 同值；只用在地址链内部取值，登录页占位符仍是 `panel.example.com`，不向用户暴露真实域名）。无缓存时面板地址也要进链（链首），不再等 Raw/Worker 先成功一次把 `panel_api_base` 写进缓存。有缓存时仍走缓存的 `panelApiBaseOrDerived`（:11111 派生不变）。

### 第 5 条：远程配置 P0-2——代理轮跳过留痕＋核心起来后重拉＋跳过已知 404（C 路 §5）

- 新增失败 kind `proxySkipped`：注入了代理 Dio 但核心未启动时，`failures` 里记一条“代理轮未跑：核心未启动，开关没开或核心未连接”（`failureMessage` 里单独成行，不拼 URL）；不参与 `notPublished` 判定（`attempted` 只计直连轮，`notFoundUrls` 不动）。未注入代理 Dio 的调用（如旧测试）不记这条。
- 代理轮跳过直连已 404 的地址：直连轮已回 404 的 URL，代理轮再试也只会是 404，跳过它们把等待时间省下来给 Raw。
- `lib/services/remote_config_notifier.dart`：核心 `statusStream` 推 started 后，若上次拉取失败了（`source != fresh`），再触发一次 `refresh`——这回代理轮能跑。注意不能 `ref.listen(coreServiceProvider)`：它是普通 Provider，返回的 `CoreService` 对象身份不变，状态变化只走 `statusStream`，listen 永远不会触发（本轮测试先写错后纠正，见“测试”）。

### 第 6 条：远程配置 P0-3——过时尾注＋合成 upToDate＋进度提示（C 路 §5）

- `lib/features/settings/settings_page.dart`：failed 尾注删掉“检查走手机直连，不走代理，开关开了也帮不上”，改按实际写：“直连失败后，开关已开且核心已连接时会经代理再试一轮；开关没开时代理轮不跑，开着开关再点一次会经代理再试。”（`_checkAppUpdate` 里同款尾注不要动，应用内更新本来就只走直连。）
- `lib/services/remote_config_notifier.dart`：`_refreshing` 合成结果改成 `_inFlight` 等同一轮——进行中再调不再返回合成的 `upToDate`（全新安装从未拉到过配置却显示“已是最新配置（v0）”），而是等正在跑的那轮出结果，不开第二轮。
- 设置页“检查更新”行加进度提示：检查中（`RemoteConfigState.checking`）行尾显示转圈、行不可点，避免用户以为没反应而重复点。

### 版本

- 0.1.4+5（versionCode 2005，versionName 0.1.4；`pubspec.yaml` 与 `lib/brand/remote_config.dart` 的 `appVersion` 同步）。

### 测试

- `flutter analyze`：零问题。
- `flutter test` 全量：582/582 通过（0.1.3 是 577/577；新增 5 条：无缓存时面板地址进链、代理轮跳过已知 404、refresh 进行中再调等同一轮、核心起来后重拉、probeAt 为空印“未探活”）。另改写 10 余处旧断言（前缀 3 条→2 条后规则下标与条数全移一位；“开关没开”测试的 failures 从 2 条变 3 条，多的一条是 proxySkipped；“探活通过”测试须传真实 probeAt；设置页版本断言 0.1.3→0.1.4）。
- 真 sing-box `check`：0.1.4 生成配置（规则/全局，TUN 开）上游 1.14.4 与补丁版各跑一遍，4 项全 rc=0。

### 新 APK

- 产物：`~/workspace/goals/goal-5/files/zhexuexi-client-release-arm64.apk`（`~/workspace/your_files/` 下同名文件是软链，两处 SHA 一致），旁有同名 `.sha256` 文件。
- SHA-256：`19bad97c35fb64a248332ccc683ab097e356fb9c4ba228af8b6ac995d4244492`，109,454,485 字节（比 0.1.3 的 109,454,481 字节大 4 字节）。
- `apksigner verify`：exit 0（1 个签名者）；证书 SHA-256 `2e10202c7a2b365aa9fd4438565bd6b0aa8b7054e215cdad008f01cb182a1d8e`，与上版一致（同一把 release 签名，可直接覆盖安装）。
- `aapt2 dump badging`：`package: name='com.zhexuexi.client' versionCode='2005' versionName='0.1.4'`。
- APK 内 libbox 核对：`lib/arm64-v8a/libbox.so` 80,954,824 字节，与新 AAR 内 `.so`（80,954,832 字节）逐字节比只差 891 字节（全在 ELF 头与尾部元数据区，AGP 重打包所致），代码段一致，确为新编补丁版（含版本戳）。
- 未推客户端仓；未推上游 PR（用户 2026-11-26 21:35 已叫停，等客户端真正没问题再说）。

### 发布

- Release v0.1.4（新建 tag，旧 v0.1.3 不动）：https://github.com/nbbk/zhexuexi-client/releases/tag/v0.1.4（Release id 459504373）。资产核对通过：`app-arm64-v8a-release.apk`（资产 796210795，109,454,485 字节，digest sha256:19bad97c…4492 与本地一致）、`app-arm64-v8a-release.apk.sha256`（资产 796218898，100 字节，digest sha256:a4943b7b…f6a13 与本地 `.sha256` 文件的 SHA 一致）；说明含“本包 versionName 0.1.4”。

### 待真机验证（没拿到开关开着的诊断包与 logcat 的部分）

- **先验核心状态与版本号是否恢复正常（每次必做的前置）**：开开关等 30 秒后、**不要关开关**，立刻导出诊断包。核心状态必须是“已连接”（不是“未连接”）、核心版本应是 `1.14.4-patched`（不再是 unknown）、启动探活一行必须带真实时间（“最近结果：—”= 没跑过，作废重验）。三行不对，先查核心为什么没起来/又停了，不要直接验断网。
- **D 路第 2 步（定罪步骤，必验）**：开开关，微信（TCP 为主、规则模式 final=direct）、百度（`.cn` 直连）、YouTube（规则/全局）三者是否恢复；再切全局模式重验一遍。恢复 → 定罪 QUIC 阻断（报回哪台机型、哪个模式先恢复）；仍全断 → 进第 3 步删 sniff（0.1.5 再做，不要一次全删）。
- **REALITY 节点是否仍绿**：试点 REALITY 入站＋chrome 指纹应通；firefox/safari 指纹也应通。
- **远程配置**：面板源已通（用户 22:01 确认），设置页“检查更新”应直接拉通；若 0.1.4 上还拉不到，直接按客户端侧查（看弹窗逐条：有没有“代理轮未跑”那行、Raw 是 timeout 还是 connectionError、有没有“（经代理）”标记）。开关开着时点的检查更新，失败行里应有“（经代理）”标记；开关关着时点，应有一行“代理轮未跑”。
- 0.1.2/0.1.3 的待真机验证项仍有效（规则模式 YouTube、夜晚模式、公告栏、开关新图案、登录页域名栏隐藏）。

## 2026-11-26：0.1.5——把 QUIC 阻断加回来（只做这一件事，未推仓）

背景：用户 2026-11-26 22:32 报 0.1.4 上“有点网络了，但卡得几乎不能用，YouTube 页面加载不全”，22:37 再补“测试了几个节点，都一样慢——节点侧原因基本排除，慢在客户端共有通路上”。两份调查报告见 `~/workspace/015-invest/`：`slowness-analysis.md`（分析员）与 `sandbox-measurements.md`（实测员）。

### 证据链

- **0.1.2 的黑断与 0.1.4 的慢是两个故障，不要互相归因。** 黑断元凶是劫持对（hijack-dns＋`dns_mode: hijack`）：微信是 TCP、规则模式走 final=direct 根本不碰节点，它死只能死在出站之前——QUIC 阻断拦不到 TCP，所以黑断那笔账算不到 QUIC 阻断头上。0.1.2 时 QUIC 阻断＋劫持对＋dns_mode 三项同在，黑断的归因从来没分开过；QUIC 阻断在黑断上是无辜的，只在“慢”上有嫌疑。
- **0.1.4 诊断包（开关开着，22:34 左右）把“核心没起来 / 配置不对”两条线彻底关掉了。** 核心 `1.14.4-patched`、已连接、探活带真实时间 `22:34:46` 通过、无错误、订阅 22:34:35 刚更新、配置 JSON 与 0.1.4 预期逐字一致、实时连接里确有 Proxy 流量。故障段只剩数据通路：TUN → 路由/sniff/DNS → 出站（REALITY/TCP）→ 节点 → 互联网。关开关即恢复正常，手机本身网络没问题。
- **P0-1 QUIC 走隧道（分析员，最优先）。** 当前节点是 REALITY（TCP），YouTube 的 QUIC（UDP）全程被装进 TCP 流里走：双重丢包恢复＋队头阻塞；HY2 节点上则是 QUIC 套 QUIC，双重拥塞控制。最能解释“多个节点都一样慢”——机制在客户端共有通路上，不在节点上。B 路已证它不可能误伤 HY2 出站自身的 UDP 443（路由规则只对入站连接求值）。
- **P0-2 sniff 失败→落 final=direct（分析员，次优先）。** 0.1.3 删劫持后 `reverse_mapping` 断粮，域规则只剩 sniff 一条域名来源；QUIC ClientHello 常跨多个包，300ms 内嗅探失败即无域名 → 规则模式落 final=direct → YouTube 直连被墙，表现为“加载不全/极慢”。只解释规则模式的慢。
- **沙箱实测（实测员）：隧道在沙箱里不慢。** 经 reality-443 代理/直连吞吐比 1.05（9.27 vs 8.81 MB/s 中位），两路 DoH 都快（代理 8.8.8.8 约 53–58ms，直连 223.5.5.5 约 136–140ms），sniff 开关无可测代价（3–6ms），QUIC 阻断开/关对 TCP 无影响。节点、REALITY、DNS、sniff 全部洗脱；慢在沙箱测不到的地方（手机 TUN/MTU/UDP 路径、手机网络环境）。
- **弱信号（备查，不定罪）。** 75 次代理 curl 里 2 次单次 TLS stall（5.48s、6.02s），直连 15 次里 0 次超 1.03s——样本太少不定罪，若真机抓包/日志里也出现零星数秒 stall，值得单独立项追踪。
- **P1 栈 mixed（放大器，不做）。** 补丁版 libbox 带 `with_gvisor` 编译，默认栈即 mixed（TCP 系统栈＋UDP gVisor 栈）；配置层改不了栈（插件 schema 拒 `stack`），改栈须动插件层，不在 0.1.5 做。

### 改动：只加回 QUIC 阻断

- `lib/core/singbox_config.dart`：路由前缀恢复为 3 条，把 `{'network': 'udp', 'port': 443, 'outbound': 'block'}` 加回最前面（sniff 之前，与 0.1.2 的顺序一致）；规则与全局两份配置一起改。注释同步更新：0.1.4 段保留，新增 0.1.5 段写清为什么加回来（证据链）与回滚条件。
- 其余一切不动：sniff 300ms、私网旁路、两路 DoH、MTU 1500、reverse_mapping、final 全不动；不加回 hijack-dns、不动 DNS、不动栈、不加 fake-ip。
- **回滚条件**：真机验证 0.1.5 后 YouTube 仍卡、微信/百度无改善 → 回滚这条规则，进 P1（sniff 诊断，0.1.6 再做），不要叠加其它改动。

### 版本

- 0.1.5+6（versionCode 2006，versionName 0.1.5；`pubspec.yaml` 与 `lib/brand/remote_config.dart` 的 `appVersion` 同步）。

### 测试

- `flutter analyze`：零问题。
- `flutter test` 全量：582/582 通过（与 0.1.4 同数；本轮未新增测试，只改写断言：路由前缀 2→3 条，规则下标与条数全移一位——规则模式 8→9 条、全局/直连模式 2→3 条、无节点 3→4 条、自定义规则下标 [2][3][4]→[3][4][5]；设置页版本断言 0.1.4→0.1.5；未放宽任何断言）。
- 真 sing-box `check`：0.1.5 生成配置（规则 9 条、全局 3 条，首条均为 QUIC 阻断）上游 1.14.4 与补丁版各跑一遍，4 项全 rc=0（`~/workspace/015-invest/check-015.sh`，日志 `runs/check-015-*.log`）。
- REALITY 握手对照重跑（试点美国01 23.129.180.189，reality-443，`~/workspace/libbox-patch/verify/patched/run-one.sh`，配置沿用 `reality-test.json`）：补丁版两次 curl 200（0.55s / 0.53s），随后未补丁版对照仍 `reality verification failed`（curl exit 97）——补丁未退化。日志 `verify/patched/reality-015-patched-run{1,2}.log`、`reality-015-unpatched-control.log`。
- 临时导出测试 `test/tmp_check_dump_test.dart`（只用来打 builder 配置到 `~/workspace/015-invest/cfg/builder-015-{rule,global}.json`）跑完即删，不进套件。

### 新 APK

- 产物：`~/workspace/goals/goal-5/files/zhexuexi-client-release-arm64.apk`（`~/workspace/your_files/` 下同名文件是软链，两处 SHA 一致），旁有同名 `.sha256` 文件。
- SHA-256：`18c55bda575525d49ec46efd0d6adc880ed3b9350c6f46930d33779d747ab3cc`，109,454,485 字节（与 0.1.4 同字节数）。
- `apksigner verify`：exit 0（1 个签名者）；证书 SHA-256 `2e10202c7a2b365aa9fd4438565bd6b0aa8b7054e215cdad008f01cb182a1d8e`，与上版一致（同一把 release 签名，可直接覆盖安装）。注：裸跑 `apksigner` 报 `java: not found`，须把 `~/workspace/toolchains/jdk17/bin` 加进 PATH 再跑。
- `aapt2 dump badging`：`package: name='com.zhexuexi.client' versionCode='2006' versionName='0.1.5'`。
- APK 内 libbox 核对：`lib/arm64-v8a/libbox.so` 80,954,824 字节，与 AAR 内 `.so`（80,954,832 字节）逐字节比只差 891 字节（1 字节在 ELF 头 offset 40，其余 890 字节全在尾部节头表/`.shstrtab` 元数据区，`.text`/`.rodata` 代码段零差异），与 0.1.4 同数，确为补丁版；`.so` 内 `1.14.4-patched` 字面量 1 处。
- 构建：`flutter build apk --split-per-abi --release`，601.6s，`~/workspace/015-invest/build-apk-015.log`。补丁版 libbox 未重编，复用本地 Maven 仓 `io.nekohasekai:libbox:1.14.4-patched`。
- 未推客户端仓；未推上游 PR（仍暂停）；未动面板与服务端。

### 发布

- Release v0.1.5（新建 tag，旧 v0.1.4 不动）：https://github.com/nbbk/zhexuexi-client/releases/tag/v0.1.5（Release id 459566208）。资产核对通过：`app-arm64-v8a-release.apk`（资产 796419651，109,454,485 字节，digest sha256:18c55bda…ab3cc 与本地一致）、`app-arm64-v8a-release.apk.sha256`（资产 796419329，100 字节，digest sha256:3fef1dc7…04e87 与本地 `.sha256` 文件的 SHA 一致）；说明含“本包 versionName 0.1.5”与回滚条件。

### 待真机验证

- **先验核心三行（每次必做的前置）**：开开关等 30 秒后、**不要关开关**，立刻导出诊断包——核心状态“已连接”、核心版本 `1.14.4-patched`、启动探活带真实时间；三行不对先查核心。
- **再验速度**：YouTube 首屏/首帧、微信、百度，规则与全局各测 3 次取中位，与 0.1.4 的“卡得几乎不能用、页面加载不全”对照；关开关基线也要测一次。
- **定罪判定**：若 YouTube 恢复流畅 → 定罪 QUIC 隧道路径（0.1.5 即此版）；若仍卡 → 回报“V1 无效”，进 P1（sniff 诊断，0.1.6 做），不要自己再加改动。
- 0.1.2/0.1.3/0.1.4 的待真机验证项仍有效（规则模式 YouTube、夜晚模式、公告栏、开关新图案、登录页域名栏隐藏、远程配置）。

## 2026-11-26：0.1.6——回滚 QUIC 阻断＋P1 sniff 诊断（未推仓）

背景：0.1.5 真机验证结论——V1 无效，而且更差。用户 2026-11-26 23:24 发来 0.1.5 诊断包（开开关时导的，用户 23:26 确认）：核心 1.14.4-patched、已连接、启动探活通过（23:23:34）、当前节点测试机-hy2-443-A、延迟 524ms、路由首条 QUIC 阻断已在 live 配置里、最近错误无；用户 23:25 报“手机全没有网络了”，随后确认关掉开关网络就恢复——全断只发生在开关开着时，TUN 能干净拆掉，手机本身的网没问题。0.1.4 是“有点网络但极慢”，0.1.5 是全断，0.1.4→0.1.5 唯一变量就是 QUIC 阻断加回。按 0.1.5 报告写的回滚条件执行：回滚 QUIC 阻断，进 P1（sniff 诊断）。两份调查报告见 `~/workspace/016-invest/`：`p1-sniff.md`（P1 sniff 诊断）与黑断机制调查（另一路，结论待补入本节）。

### 证据链：0.1.5 的“全断”推翻了什么

- **“QUIC 阻断在黑断上无辜”的判断正式推翻。** 0.1.5 报告曾以“微信 TCP 死是硬证据，QUIC 阻断拦不到 TCP”为由判它无辜；但 0.1.4→0.1.5 唯一的变量就是 QUIC 阻断加回，症状却从“慢”变“全断”。0.1.2 时 QUIC 阻断与劫持对三项同在、归因从未分开过，这次单变量对照把账算清了：一条 UDP 443 阻断规则能拖垮整机联网，机制见下节。
- **核心的自检与真实流量是脱节的，全断是静默的。** 0.1.5 诊断包里核心自认完全正常（已连接、1.14.4-patched、启动探活通过、当前节点延迟 524ms、最近错误无），手机却全没有网络——探活与延迟测的是控制面，数据面死了核心也不报错。这是 0.1.2 的翻版（核心已连接、延迟 604ms、订阅能更新，仍全断）。以后“核心正常”不能作为“网络正常”的证据。
- **劫持对仍是黑断的共犯嫌疑，不因 QUIC 阻断定罪而脱罪。** 0.1.2 的微信 TCP 死仍只能死在出站之前，QUIC 阻断拦不到 TCP 这一点没变；0.1.2 时三项同在，0.1.5 单变量只证明了 QUIC 阻断这一条能单独致断，没证明劫持对无辜。

### 全断机制（`~/workspace/016-invest/mechanism-blackout.md`，黑断机制调查员）

- **一句话**：QUIC 阻断规则本身伤不到任何出站拨号（路由只对入站求值，B 路结论复核成立），但它能通过 **TUN 环路** 间接杀死一切：核心自己的拨号 socket 在 Android 上没有任何 protect（配置没开 `auto_detect_interface`，`ProtectFunc()` 从未挂载），唯一的隔离是 `VPNService.openTun` 里的一行 `addDisallowedApplication(自家包名)`，而它的失败路径是静默记一行 WARN 然后继续建 TUN；一旦这行隔离失效，核心拨号的包就被内核路由进自家 TUN，在 sing-tun 里先经 Stage-1 快筛放行、再经 Stage-2 NAT 重生为一条新的入站连接走全量路由——此时 HY2 的 UDP 443 拨号包恰好命中首条 QUIC 阻断规则、被 `block` 出站以 `EPERM` 掐死，HY2 会话永远建不起来；而 TCP 节点（REALITY/VLESS）的拨号包不命中 UDP 规则、sniff 出 SNI（`microsoft.com`，不在任何域组内）后落 `final`，却因为 `direct`/`Proxy` 出站的再拨号用的是同一个未 protect 的拨号器、新 socket 再进 TUN，于是逐层递归、每层空耗一次 300ms sniff 超时和一次 5 秒 TCP 连接超时，同样永远到不了节点。**在环路存在的前提下，QUIC 阻断杀 HY2、递归杀 TCP，全断是这条规则与环路叠加的必然结果。**
- **证据链（每步带文件:行号）**：路由只对入站求值（`route/route.go:72,248,620`；`protocol/tun/inbound.go:583,604`；`protocol/hysteria2/outbound.go:189-207` 出站拨号全程无 `Router`/`matchRule` 调用）；HY2 是 QUIC/UDP 443（`protocol/hysteria2/outbound.go:19-22,55-57,150-159`；`singbox_config.dart:816-823`，测试机 HY2 节点端口即 443，拨号包五元组与 App 的 YouTube QUIC 包在 TUN 里不可区分）；核心拨号无 protect（`common/dialer/default.go:105-127`，`ProtectFunc()` 只在 `AutoDetectInterface()` 时挂载，kit 配置没开，`singbox_config.dart:607-630`）；唯一隔离 `addDisallowedApplication` 且失败静默继续（`VPNService.kt:195-230`，成功记 `Log.i "…: ok, core sockets bypass TUN"`，失败记 `Log.w "… failed, core sockets may loop through TUN"` 然后继续建 TUN；默认 `perAppProxyMode` 是 DISABLED，`SettingsManager.kt:55-76`）；Stage-1 快筛拦不住 block（`route/route.go:347,482`，`preMatchFlow` 见 block 不是 `FlowOutbound` 即返回 Continue；`protocol/direct/outbound.go:186-194`）；TCP 走系统栈 Stage-2（`sing-tun/stack_system.go:208,385,438`）、UDP 走 gVisor 转发器（`sing-tun/stack_gvisor_udp.go:52,80`；`udp_nat.go:416`）；环路 HY2 拨号死在 Stage-2 首条规则，`block` 报 `EPERM`（`protocol/block` 全文，`ListenPacket` 直接返回 `syscall.EPERM` 并记 Info 日志 `"blocked packet connection to "`）；环路 TCP 拨号 sniff 超时、无域规则、落 `final`、再拨号递归（`route/route.go:736`；`constant/timeout.go:8`，TCP 连接超时 5s）。
- **没有定罪——悬而未决的矛盾必须如实写**：这条链与 0.1.5 诊断包里 23:23:28 的 524ms 延迟和 23:23:34 通过的启动探活直接矛盾——两者都要求 HY2 拨号在当时到达了节点（探活/延迟都依赖 HY2 会话本身，`lib/core/singbox_core.dart:360-430,460-500`；`common/urltest/urltest.go:83`），即当时没有环路。所以现有证据只能定罪到“环路＋阻断是唯一代码成立的杀伤链，触发环路的状态变化发生在 23:23:34 之后、触发器未知”（候选：切节点、网络切换、TUN 重建，均无证据）。23:23 的“活”与 23:25 的“死”不能并存于静态机制，没有带时间戳的操作记录，这个口子合不上。
- **对协调员前提的三处纠正**：① “拨号挂 ProtectFunc 的分支在 Android 上恒为假”理由是错的——`route/network.go:73-74` 的 guard 是 `options.AutoDetectInterface && !(C.IsLinux || …)`，而 `constant/os.go:23` 规定 `IsLinux = goos.IsLinux == 1 || goos.IsAndroid == 1`，Android 上 `C.IsLinux` 为 true，guard 不触发，`auto_detect_interface` 在 Android 上是允许写的；kit 注释（`singbox_config.dart:607-630`、`VPNService.kt:30-40,208`）把 `goos.IsLinux`（Android 上为 0）与 `constant.IsLinux`（Android 上为 true）混为一谈。推论：若配置写上 `auto_detect_interface: true`，`NewDefault` 就会挂载 `ProtectFunc()`，Kotlin 的 `autoDetectInterfaceControl` 就会被调、`protect(fd)` 就会生效——这是 0.1.6 之后修环路的一条现成路（须另验证 `UsePlatformNetworkInterfaces()` 一路）；另 `route/network.go:75-76` 还有一条 Android 专属选项 `override_android_vpn`（kit 未写），sing-tun 里它控制“带 protect 标记（`0x20000`）的流量绕过 VPN 路由”，是第二条现成路，同样待验证。② 任务书提示链“环进 TUN 的拨号被当作新入站连接路由，sniff 出 SNI 后无域规则命中、落 final=direct 直连节点”在源码里只成立到 `final=direct` 为止，“直连节点”一步不成立——`direct` 出站的拨号走的是同一个未 protect 的 `DefaultDialer`，新 socket 的 SYN 同样进 TUN，不存在“某层拨号突然绕过 TUN”的出口，正确的链是“落 final=direct → direct 出站再拨号 → 新 socket 再进 TUN → 递归”。③ (g) 的归属纠正：实时连接出现 4 次与当前节点不一致的观察出自 **0.1.4 诊断包（23:17）**，不是 0.1.5 的；且 chain 不是健康检查流量——`chains` 只由路由追踪生成（`common/trafficcontrol/tracker.go:70-72`），urltest 健康检查是出站直拨、不经过路由器、不进 `GET /connections`（`protocol/group/urltest.go:380-503`；`experimental/clashapi/connections.go:36-40`）；4 次相同 chain = 4 条真实路由连接，与当前节点不一致的唯一合理解释是时序差（连接建立时 selector 的实际选用就是测试机组）。教训：切节点后必须等旧连接自然消亡（或重启核心）再导诊断包，否则 chain 反映的是建立时的选择。
- **0.1.4 的慢与 0.1.2 的黑断不受影响**：若 0.1.4 时环路存在，HY2 拨号在 Stage-2 会落 `final` → direct 再拨号 → 递归 → 全断，不是慢；0.1.4 实际是“有点网络但极慢”，与环路预测矛盾，所以 0.1.4 时没有环路，015 的 P0-1/P0-2/P1 仍成立。0.1.2 的黑断仍更可能由劫持对主导（微信 TCP 死的硬证据不受本次调查影响）；QUIC 阻断＋环路至多是叠加因素。0.1.2 黑断与 0.1.4 慢是两个故障的判断维持不变。
- **其余候选全部排除为主因**：DNS（规则不碰 UDP 53；两路 DoH 是 TCP 443；只保留为下游放大器——HY2 死后规则模式下嗅出流媒体/Google 域的 DNS 查询本身也被路由进 Proxy 而死，但解释不了微信 TCP `.cn` 直连的死）；sniff（失败只记 `SniffError`、继续匹配，`route/route.go:736`；0.1.4 有 sniff 无阻断是慢不是断；环路链里每层递归烧 300ms 超时，是放大器不是元凶）；gVisor 栈（不区分端口，0.1.4 同样 mixed 栈却能部分通；是环路杀伤的载体，不是开关）；`block` 出站（只对路由到它的连接回 `EPERM`，无全局副作用；PreMatch 阶段不产生 Reject，杀伤只在 Stage-2）；MTU/订阅/远程配置（0.1.4→0.1.5 未变）。
- **E1 决定性实验的解读必须反转（原解读是错的）**：任务书原解读是“TCP 节点恢复 ⇒ 环路假说大胜；TCP 也断 ⇒ 环路假说被削弱”。递归分析证明该解读是反的——在环路假说下，E1 的正确预测就是 TCP 也断（direct 再拨号同样进 TUN）；TCP 恢复只能由“非环路的 UDP 专属杀伤”解释。修正版：在 0.1.5 上只切节点到 TCP 节点（首选 `美国01-reality-443-A`），其它一律不动，每项指标测 3 次取中位（M1–M5），切节点前后各做一次 delay 测速与启动探活并记时间戳，每次测完立即导出诊断包并抓 logcat。结果 A：TCP 节点下网络恢复 → 杀伤是 HY2/UDP 特异 → **环路假说被证伪** → 转向 UDP 专属机制专项调查；结果 B：TCP 节点也全断 → 杀伤不分协议 → **环路假说保持为头号嫌疑，但未定罪** → 必须结合 logcat 定罪（`ok` 行在 ⇒ 环路假说死；WARN 行或缺失 ⇒ 环路假说定罪）。
- **备用实验**：E0（零改动，先做，优先级高于 E1）——0.1.5 上直接抓 logcat 复现一次全断；`ok` 行在且无 `inbound … to <节点 IP>:443` 行，环路假说当场死亡；WARN/缺失且有 `blocked` 行，环路假说当场定罪。E2（TUN 层定位）——0.1.5 上保持 HY2 节点，只关 TUN 用 mixed 入站本地代理测探活/延迟与 YouTube；关 TUN 后恢复 ⇒ 杀伤在 TUN 层；关 TUN 也断 ⇒ 杀伤在核心出站/节点侧，与 TUN 无关。E3（必要条件验证）——0.1.6（已回滚 QUIC 规则）上重测 HY2 节点；恢复 ⇒ QUIC 规则是黑断的必要条件；仍全断 ⇒ QUIC 规则不是必要条件，“0.1.5 唯一变量”的叙事破产，须查构建/安装差异。
- **logcat 一锤定音的行**（抓取：开关开着，`adb logcat` 过滤 `VPNService` / `sing-box` / `Libbox` / `BoxService`；核心日志级别须为 debug 才能看到 router 的 `match` 行，`block` 的 Info 行默认级别即可见；复现动作：刷一次微信、刷一次 YouTube、切一次节点 HY2 ↔ REALITY，全程抓）：`addDisallowedApplication(com.zhexuexi.client): ok, core sockets bypass TUN`（`VPNService.kt:221-230` 的 `Log.i`）——有 = 排除生效，环路假说死；缺失或 WARN 行 = 排除失败，环路假说活，这是第一行，先看它；`inbound packet connection to <节点 IP>:443`（`protocol/tun/inbound.go:586-604`）——环路的直接证据；`blocked packet connection to <节点 IP>:443`（`protocol/block`）——阻断的直接证据，与上一行同时出现 = 环路＋阻断链条闭环；`inbound connection to <节点 IP>:443` 反复出现伴随 `connection closed`/dial 超时——TCP 递归的证据；`match[0] … => block`（debug 级，`route/route.go:620`）——Stage-2 首条命中 block 的直接记录。
- **尚缺**：0.1.5 诊断包原文仍未见到文件（本节依赖诊断包的判断以 MEMORY 原始记录为准，待原文到达后复核）；小米 test-keys ROM 因素（诊断包系统版本 `TKQ1.221114.001 test-keys` 是测试签名 ROM，`addDisallowedApplication` 在该 ROM 上的行为是环路假说的最大未知数，只能由 logcat 裁决）；23:23:34→23:25 的状态变化触发器（须带时间戳的操作记录）。

### P1 sniff 诊断结论（`~/workspace/016-invest/p1-sniff.md`）

- **对 0.1.4 的“慢/加载不全”**：P0-2 机制成立，待真机分流证据定罪。9 步链条里 8 步是代码实锤，只剩“直连被墙的具体形态”与“多包 ClientHello 的频率”待真机证实。
- **对 0.1.5 / 0.1.2 的“全断”**：sniff 脱罪，有不在场证明——0.1.5 里 QUIC 被首条 block 规则拦在 sniff 之前，sniff 对 UDP 443 没有作案机会；TCP sniff 只能延迟（≤300ms）、从不杀死连接；0.1.2 全断时 sniff 还不存在（它是 R1 修复时才加进来的）。
- **对 0.1.6 是否动 sniff**：不动。sniff 是规则模式唯一的域名来源，拿掉它就是主动复现 0.1.2 R1；且全断未解之前任何 sniff A/B 的数据都是被污染的。
- **新发现 1——reverse_mapping 的断粮比“断粮”更彻底，是零喂养。** 写缓存的只有 `Exchange` 路径（`dns/router.go:1212,1245`），而核心内部全部解析（出站拨号、urltest、`default_domain_resolver`）走的 `Lookup` 路径全程不写缓存；劫持死后唯一剩下的 `Exchange` 调用方是 ECH 取配置（`common/tls/ech.go:150`），且它查 HTTPS 记录、应答无 A/AAAA 可供记录。所以 `reverse_mapping: true` 是个空开关。
- **新发现 2——DNS 包不受 sniff 影响。** `common/sniff/dns.go` 的 DNS 嗅探器只置 `Protocol=dns`、不置 `Domain`，DNS 查询包永远落 final；sniff 开关不改变任何 DNS 包去向。
- **对 015 的三处纠正**：UDP 的 300ms 是“等下一片分片”的单步时限（`route.go:848-853` 每读一包重设）、不是总预算，TCP 才是 300ms 总时限；超时也不是主要失败模式——ECH（SNI 为空、静默失败）、非 QUIC 的 UDP 443、版本/令牌异常都比超时更值得查；015 提到的“UDP `udp_timeout` 30s”是路由完成后的会话存活时间，不是嗅探超时；多包 ClientHello 有外部依据（Chrome 124+ 默认 X25519MLKEM768，密钥份额 1,184 字节，ClientHello 约 1,700 字节，QUIC Initial 下限 1,200 字节——首个 Initial 数据报装不下完整 CH），但本机频率仍待 logcat 计数。
- **fake-ip 简要评估**：只加 fake-ip 无效（App DNS 不进 sing-box DNS，store 永远是空的），必须与劫持对一起回来——而劫持对正是黑断头号嫌疑；另有 `experimental.cache_file` 持久化要求与“missing fakeip record”硬失败模式。结论：不是 0.1.6 的动作。
- **区分实验矩阵**（报告 §4，精确到 `singbox_config.dart:344-347` 改哪条、规则/全局分开测、M1–M5 取中位）：V0 模式分离先做；实验 (a) 只关 sniff；实验 (b) 加回 QUIC 阻断但关 sniff；附 2×2 交叉读数表与可选 V2c（超时 300ms→1000ms），实验顺序是先等黑断机制一路确认基线恢复非全断。
- **logcat 证据清单**（报告 §5，10 条必看行）：其中 `attempt to sniff fragmented QUIC client hello`（`route.go:836,895`）是多包 CH 的直接计数器。**关键前置条件**：当前生成配置日志级别是 `info`（`singbox_config.dart:512`），所有关键行都是 `DebugContext`，info 级下一条都看不到——实验包必须临时改成 `debug`（测试包专用，不进发版）；日志通道已核实为 `Log.d("sing-box", …)`（`BoxService.kt:500-502`），抓 `adb logcat -s sing-box`。
- **尚缺**：logcat 未到——报告里标记“待证”的两项（多包 CH 频率、直连被墙形态）都等它；V0 模式分离（只量秒数、不用日志）现在就可以做。

### 改动：只回滚 QUIC 阻断

- `lib/core/singbox_config.dart`：路由前缀从 3 条恢复为 0.1.4 的 2 条，删 `{'network': 'udp', 'port': 443, 'outbound': 'block'}`，首条恢复为 sniff（规则与全局两份配置一起回滚）；0.1.5 的注释段保留，新增 0.1.6 段写清回滚原因（单变量对照＋回滚条件触发）与 P1 结论（sniff 不动）。
- 其余一切不动：sniff 300ms、私网旁路、两路 DoH、MTU 1500、reverse_mapping、final 全不动；不加回 hijack-dns、不动 DNS、不动栈、不加 fake-ip。
- `pubspec.yaml` 与 `lib/brand/remote_config.dart` 的 `appVersion` 同步到 0.1.6。

### 版本

- 0.1.6+7（versionCode 2007，versionName 0.1.6；`pubspec.yaml` 与 `lib/brand/remote_config.dart` 的 `appVersion` 同步）。

### 测试

- `flutter analyze`：零问题。
- `flutter test` 全量：582/582 通过（与 0.1.5 同数；本轮未新增测试，只改写断言：路由前缀 3→2 条，规则下标与条数全移一位——规则模式 9→8 条、无节点 4→3 条、全局/直连模式 3→2 条、自定义规则下标 [3][4][5]→[2][3][4]；设置页版本断言 0.1.5→0.1.6；未放宽任何断言。中间一轮曾出现 581/582——`test/custom_rules_test.dart` 的“不传 customRules 时老调用不受影响”一例漏改下标 [3]→[2]，补改后全过）。
- 真 sing-box `check`：0.1.6 生成配置（规则 8 条、全局 2 条，首条均为 sniff、无 QUIC 阻断）上游 1.14.4 与补丁版各跑一遍，4 项全 rc=0（`~/workspace/016-invest/check-016.sh`，日志 `runs/check-016-*.log`，配置 `cfg/builder-016-{rule,global}.json`）。
- REALITY 握手对照重跑（试点美国01 23.129.180.189，reality-443，`~/workspace/libbox-patch/verify/patched/run-one.sh`，配置沿用 `reality-test.json`）：补丁版两次 curl 200（0.54s / 0.57s），随后未补丁版对照仍 `reality verification failed`（curl exit 97）——补丁未退化。日志 `verify/patched/reality-016-patched-run{1,2}.log`、`reality-016-unpatched-control.log`。
- 临时导出测试 `test/dump_config_016_test.dart`（只用来打 builder 配置到 `~/workspace/016-invest/cfg/builder-016-{rule,global}.json`）跑完即删，不进套件。

### 新 APK

- 产物：`~/workspace/goals/goal-5/files/zhexuexi-client-release-arm64.apk`（`~/workspace/your_files/` 下同名文件是软链，两处 SHA 一致），旁有同名 `.sha256` 文件。
- SHA-256：`4f24ec5b29ce53bd1ff20050b845e9349a32d8980977574b9f9c855a7e4020a9`，109,454,485 字节（与 0.1.4/0.1.5 同字节数）。
- `apksigner verify`：exit 0（1 个签名者）；证书 SHA-256 `2e10202c7a2b365aa9fd4438565bd6b0aa8b7054e215cdad008f01cb182a1d8e`，与上版一致（同一把 release 签名，可直接覆盖安装）。注：裸跑 `apksigner` 报 `java: not found`，须把 `~/workspace/toolchains/jdk17/bin` 加进 PATH 再跑。
- `aapt2 dump badging`：`package: name='com.zhexuexi.client' versionCode='2007' versionName='0.1.6'`。
- APK 内 libbox 核对：`lib/arm64-v8a/libbox.so` 80,954,824 字节，与 0.1.5 同数，确为补丁版；`.so` 内 `1.14.4-patched` 字面量 1 处。
- 构建：`flutter build apk --split-per-abi --release`，309s，`~/workspace/016-invest/build-apk-016.log`。补丁版 libbox 未重编，复用本地 Maven 仓 `io.nekohasekai:libbox:1.14.4-patched`。
- 未推客户端仓；未推上游 PR（仍暂停）；未动面板与服务端。

### 发布

- Release v0.1.6（新建 tag，旧 v0.1.5 不动）：https://github.com/nbbk/zhexuexi-client/releases/tag/v0.1.6（Release id 459616557）。资产核对通过：`app-arm64-v8a-release.apk`（资产 796592549，109,454,485 字节，digest sha256:4f24ec5b…20a9 与本地一致）、`app-arm64-v8a-release.apk.sha256`（资产 796592410，92 字节，digest sha256:98643c1e…b936 与本地 `.sha256` 文件的 SHA 一致）；说明含“本包 versionName 0.1.6”与回滚说明。

### 待真机验证

- **先验核心三行（每次必做的前置）**：开开关等 30 秒后、**不要关开关**，立刻导出诊断包——核心状态“已连接”、核心版本 `1.14.4-patched`、启动探活带真实时间；三行不对先查核心。
- **再验速度**：YouTube 首屏/首帧、微信、百度，规则与全局各测 3 次取中位，与 0.1.5 的“全没有网络”与 0.1.4 的“卡得几乎不能用、页面加载不全”对照；关开关基线也要测一次。
- **必答项**：关开关后网是否恢复（0.1.5 的全断是关开关即恢复；0.1.6 若仍全断，先报这项再报别的）。
- **定罪判定**：若恢复到 0.1.4 的“有网但慢” → 定罪 QUIC 阻断（0.1.6 即此版，慢的问题进 P1 继续查）；若仍全断 → 回报“回滚无效”，黑断另有主因，不要自己再加改动。
- 0.1.2/0.1.3/0.1.4 的待真机验证项仍有效（规则模式 YouTube、夜晚模式、公告栏、开关新图案、登录页域名栏隐藏、远程配置）。

---

## 2026-11-27：0.1.7——HY2 出站填 up_mbps / down_mbps（单变量，未推仓）

背景：0.1.6 真机验证结论——回滚后网络恢复、全断消失，QUIC 阻断正式定罪为 0.1.5 全断元凶；但慢还在，是 0.1.4 的老问题。用户 2026-11-27 00:07 回：开全局也一样慢，规则和全局都一样——P1 sniff 脱罪（它只影响规则模式，全局也慢说明慢在两模式共用的通路上）。本版只做这一件事：HY2 出站填带宽、两端切 Brutal。

### 根因与证据链

- **全局也慢 ⇒ P1 sniff 脱罪。** sniff 失败落 final=direct 只影响规则模式（全局模式无域规则可落）；0.1.7 之前用户已确认全局模式同样慢，慢在两模式共用的通路上，sniff 不是慢的主因。0.1.7 不动 sniff。
- **头号嫌疑：QUIC 走隧道。** REALITY 节点上 YouTube 的 UDP QUIC 被装进 TCP 流（双重丢包恢复＋队头阻塞）；HY2 节点上 QUIC 套 QUIC（双重拥塞控制）。但 0.1.5 已证明“阻断修法”本身会致断，不能再用阻断修，只能改拥塞控制。
- **两端 BBR 的源码证据（已逐项核实，不用重查）**：今天客户端 `up_mbps`/`down_mbps` 都不填 → `protocol/hysteria2/outbound.go:138-139` 的 SendBPS/ReceiveBPS 都是 0 → sing-quic `hysteria2/client.go` 握手分支 `actualTx=0` 恒走 BBR；服务端 agent 的 HY2 入站同样不填且没开 `ignore_client_bandwidth`，服务端也是 BBR——今天是两端 BBR，内层 YouTube QUIC 与外层 HY2 QUIC 各一套拥塞控制，正是“QUIC 套 QUIC＝双重拥塞控制”。插件 schema 已核实放行（hysteria2 出站变体白名单含 up_mbps/down_mbps/brutal_debug/bbr_profile，additionalProperties: false）。
- **修法机理**：填上后两端一起切到 Brutal（固定速率 pacer，丢包不降速），外层变成按固定速率发的管道，内层成为唯一做丢包恢复的控制器。

### 改动：只给 HY2 出站加两行

- `lib/core/singbox_config.dart`：HY2 出站（约 816 行）加 `'up_mbps': 100`、`'down_mbps': 100`。两项必须一起填（只填一项只修一半：只填 down，上传仍是 BBR；只填 up，下载仍是 BBR）。
- 其余一行不动：不加回全局 QUIC 阻断、不动 sniff、不动 DNS/栈/MTU、不加 fake-ip/hijack-dns、不动 REALITY/VLESS/TUIC 等其它出站；不加 `brutal_debug` 进发版（那是测试包附加）。

### 数值依据与风险（100/100 是测试值，不是最终值）

- 依据：节点侧 10MB 下载实测约 512Mbps（测试机 166.0.17.193，noisy 但明确 ≥100Mbps），沙箱经隧道 TCP 实测约 74Mbps，上游文档示例就是 100——100 是合理的测试值。
- 风险：Brutal 不探测带宽，填高了会洪泛瓶颈、填低了等于人为限速；且 builder 里这个值是写死一个数、所有 HY2 节点共用（Node 模型无带宽字段）。真机 A/B 变好就留，变差就按实测重填。
- 回滚办法：删掉这两行。

### HY2-only 边界

- 本修法只影响 HY2 节点。REALITY/VLESS/TUIC 节点不受影响——切到 REALITY 后慢会回来是设计边界、不是失败信号（REALITY 上 QUIC 装进 TCP 的问题本版没动）。
- 0.1.7 不动栈（schema＋模型＋builder 三件套另立项）、不动 MTU、不动按域名限定的 QUIC 阻断（备选，未采用）。

### 版本

- 0.1.7+8（versionCode 2008，versionName 0.1.7；`pubspec.yaml` 与 `lib/brand/remote_config.dart` 的 `appVersion` 同步）。

### 测试

- `flutter analyze`：零问题。
- `flutter test` 全量：582/582 通过（与 0.1.6 同数；新增 HY2 出站 up/down_mbps 断言 2 处——链接列表 HY2 出站与无 alpn 的 HY2 出站各一处；设置页版本断言 0.1.6→0.1.7；未放宽任何断言）。
- 真 sing-box `check`：0.1.7 生成配置（规则/全局，上游 1.14.4 与补丁版各跑一遍）4 项全 rc=0（`~/workspace/017-invest/check-017.sh`，日志 `runs/check-017-*.log`，配置 `cfg/builder-017-{rule,global}.json`）。
- REALITY 握手对照重跑（试点美国01 23.129.180.189，reality-443，`~/workspace/libbox-patch/verify/patched/run-one.sh`，配置沿用 `reality-test.json`）：补丁版两次 curl 200，未补丁版对照仍 `reality verification failed`——补丁未退化。日志 `verify/patched/reality-017-patched-run{1,2}.log`、`reality-017-unpatched-control.log`。
- 临时导出测试 `test/dump_config_017_test.dart`（只用来打 builder 配置到 `~/workspace/017-invest/cfg/builder-017-{rule,global}.json`）跑完即删，不进套件。

### 新 APK

- 产物：`~/workspace/goals/goal-5/files/zhexuexi-client-release-arm64.apk`（`~/workspace/your_files/` 下同名文件是软链，两处 SHA 一致），旁有同名 `.sha256` 文件。
- SHA-256：`b8d08a29c6c22bb599dd3d84e9b53c51065017b8b03d979350658923f0a2d863`，109,454,485 字节（与 0.1.4/0.1.5/0.1.6 同字节数）。
- `apksigner verify`：exit 0（1 个签名者）；证书 SHA-256 `2e10202c7a2b365aa9fd4438565bd6b0aa8b7054e215cdad008f01cb182a1d8e`，与上版一致（同一把 release 签名，可直接覆盖安装）。注：裸跑 `apksigner` 报 `java: not found`，须把 `~/workspace/toolchains/jdk17/bin` 加进 PATH 再跑。
- `aapt2 dump badging`：`package: name='com.zhexuexi.client' versionCode='2008' versionName='0.1.7'`。
- APK 内 libbox 核对：`lib/arm64-v8a/libbox.so` 80,954,824 字节，与 0.1.6 同字节，确为补丁版；`.so` 内 `1.14.4-patched` 字面量 1 处。
- 构建：`flutter build apk --split-per-abi --release`，238s，`~/workspace/017-invest/build-apk-017.log`。补丁版 libbox 未重编，复用本地 Maven 仓 `io.nekohasekai:libbox:1.14.4-patched`。
- 未推客户端仓；未推上游 PR（仍暂停）；未动面板与服务端。

### 发布

- Release v0.1.7（新建 tag，旧 v0.1.6 不动）：https://github.com/nbbk/zhexuexi-client/releases/tag/v0.1.7（Release id 459653457）。资产核对通过：`app-arm64-v8a-release.apk`（资产 796727188，109,454,485 字节，digest sha256:b8d08a29…2d863 与本地一致）、`app-arm64-v8a-release.apk.sha256`（资产 796726991，100 字节，digest sha256:80b8dded…d62a5 与本地 `.sha256` 文件的 SHA 一致）；说明含“本包 versionName 0.1.7”与 Brutal 修法说明。

### 待真机验证

- **先验核心三行（每次必做的前置）**：开开关等 30 秒后、**不要关开关**，立刻导出诊断包——核心状态“已连接”、核心版本 `1.14.4-patched`、启动探活带真实时间；三行不对先查核心。
- **再验速度**：YouTube 首屏/首帧、微信、百度，规则与全局各测 3 次取中位，与 0.1.6 的“有网但慢”对照；关开关基线也要测一次。
- **定罪判定**：HY2 节点上 M1/M2 改善 ⇒ Brutal 定罪（慢的主因就是双重拥塞控制）；变差 ⇒ 报“数值要调”，不要自己再改一版。切到 REALITY 后慢会回来是设计边界、不是失败信号。
- 0.1.2/0.1.3/0.1.4 的待真机验证项仍有效（规则模式 YouTube、夜晚模式、公告栏、开关新图案、登录页域名栏隐藏、远程配置）。
