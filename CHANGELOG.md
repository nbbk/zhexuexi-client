# 更新日志

哲学系客户端与节点侧 agent 的版本更新记录（按版本从旧到新）。

### v0.0.1 建仓（2026-11-21）

- 新仓 `nbbk/zhexuexi-client` 建仓首版：只推方案与 Logo，不写应用代码、不打包。
- 首版内容：`README.md`、`DEV-PLAN.md`（完整开发流程与方案，950 行）、`docs/zhexuexi-client-plan.md`（客户端落地方案复制件）、`assets/logo.png`（Logo v1 定稿）+ `assets/logo-v2.png`（负空间版备选）。
- 两条线定稿：A 线节点侧按人计量（方案 2，所有节点都能限流）先行 / 并行，B 线哲学系客户端（Flutter + sing-box，Win + Android）随后，汇合点是客户端首页流量同时含中转和直连、超量停用在直连节点上真实生效。
- 未做：应用代码、打包、真机验证。

### v0.0.2 平台分期与补充项（2026-11-22）

- DEV-PLAN.md 新增 §9 平台分期与补充项（2026-11-22 用户定）：第一期只做 Win + Android（MVP 与发布都只做这两个端）；第二期按需再做，先后顺序建议 macOS → Linux → iOS，并写清每端的额外代价（macOS 需 Mac + Xcode、DMG 官网直发 + 签名公证；iOS 需 Mac + Xcode、苹果开发者账号每年 99 美元、TestFlight / App Store 审核、不能官网直发；Linux 需 Flutter Linux 桌面适配、发行版差异测试）；用户确认“服务器版”就是 Linux 客户端。
- §9 补充项清单 10 项，每项写清“是什么、为什么要、什么时候做、谁决定”：账号与证书前置、分发与更新、用户体系、测速与智能选节点 / 故障自动切换、客服 / 公告 / 反馈通道、安全、隐私、换手机迁移、费用清单、多语言（第一版只中文）。
- 同步改 DEV-PLAN.md §0 与 §8：平台范围从“Win + Android”改成“第一期 Win + Android，第二期 iOS / macOS / Linux 按需”；工期 9–13 周是第一期，两期合计另计，第二期立项时再排工期。
- 未做：应用代码、打包、真机验证。

### v0.0.4 品牌自动发布（2026-11-22）

- DEV-PLAN.md 新增 §11 品牌自动发布（2026-11-22 用户定）：面板“品牌发布”页填表（应用名、Logo、主色、订阅地址、面板域名、公告/客服链接，版本号留空自动+1）→ 点发布 → 自动构建 → 自动签名（§10 助手保管的 Windows OV 证书与 Android keystore，密钥绝不进仓、不进日志）→ 自动生成下载页与更新配置；换品牌不改代码、不手动打包。表单字段表（必填/选填、格式、默认值、校验）、构建触发（点发布 / 推 tag / 手动重跑）与流水线 8 步及每步失败处理、构建机二选一（A 用户 Windows 电脑挂构建器 0 成本但关机不能构建 / B 单独 Windows 构建服务器最低 2 核/4GB/40GB SSD 长期在线，Android 同机编）、发布与回滚（下载页留最近 3 版、一键回滚、灰度衔接、发布后 24 小时观察清单）、安全（仅管理员操作、记审计、输入校验、日志脱敏）、待拍板 D11-1~D11-3（构建机 A/B、下载页三选一、发布频率限制）。
- 硬约束：GitHub Actions 免费额度用户此前已定没有，不能走公有 CI，构建机必须自己解决。
- 未做：应用代码、打包、真机验证。

### v0.0.3 用户拍板定稿（2026-11-22）

- DEV-PLAN.md 新增 §10 用户拍板定稿（2026-11-22）：证书与密钥全由助手负责（Windows OV 代码签名证书代办、Android keystore 生成并备份两份、配置中心 Ed25519 私钥离线保管，费用明细记账给用户看，用户不用提供任何证书）；登录共存（MVP 免登录默认 + 账号密码登录可选，同一面板用户、同一份流量与到期，切换/登出/令牌撤销流程写死）；安全与隐私决策清单 8 条（助手定，逐条写明）；防报毒与安装顺畅专项（安全让路于安装，OV 签名 + SmartScreen 信誉积累，Android 只申请 VPN + 网络权限）；苹果费用第一期不产生（不做 iOS/macOS，不采购 99 美元账号）；服务器配置表（面板机/中转机/落地机，最低与建议两档，数字是估算、Phase 0 实测后修正）。
- 同步改 §9 相关项：D12/D14 改为助手负责，9.2.1/9.2.3/9.2.7/9.2.9、§4.4 SmartScreen、§6 检查清单、§8 第 7 周同步改成本节口径。
- 未做：应用代码、打包、真机验证。

### v0.0.5 GitHub 免费 CI 与 Windows 一键构建器（2026-11-22）

- DEV-PLAN.md 新增 §12 GitHub 免费 CI 与 Windows 一键构建器（2026-11-22 用户定）：公开仓 GitHub Actions 不计分钟数、免费，默认用 GitHub 托管 runner（windows-latest）编 Win + Android，不用先租服务器；之前 §11.3“没 CI 额度、不能走公有 CI”是错的，那个约束来自私有仓 lottery-4d-quant，不适用于本公开仓，§11.3 与 D11-1 已按 §12 修正，自建构建机降为备选。工作流 `.github/workflows/build.yml`（手动触发 + 推 v* tag 触发，build-windows 与 build-android 并行，6 个 Secrets 签名，产物 upload-artifact）；换仓三步（fork/克隆 → 新仓填 Secrets → 点 Run workflow），工作流与代码绝不写死账号、仓库名、域名、订阅地址。Windows 一键构建器 `windows/setup-builder.ps1` + `setup-builder.bat` + `windows/README.md`：下载后右键以管理员身份运行，自动装 Git、Flutter、JDK 17、Android SDK（自动接受 license）、设环境变量、flutter doctor 校验、可选注册自托管 runner、开机自启（任务计划程序），装完显示“构建器已就绪”并给验证清单；Android SDK 全程助手/脚本搞定，用户不用手动装。
- 本版文件状态：build.yml 与 setup-builder 脚本只做静态核对，未真机跑过；Flutter 工程还没建，build.yml 里的构建命令是标准占位，阶段 0 建工程后接线；CI 未真跑过。
- 未做：应用代码、打包、真机验证。

### v0.1.0-stage0 阶段 0：环境 + 插件最小验证 + 工程架子（2026-11-22）

- 环境搭建（本机 Linux VM 实测）：Flutter **3.50.1**（Dart 3.14.0）、Temurin JDK **17.0.21.1+2**、Android SDK **36**（cmdline tools 13114758，build-tools 36.0.0，platform-tools 37.0.3）已装好，`flutter --version` 与 `flutter doctor` 通过；`sdkmanager` 因本机 MITM 代理的 Java 隧道问题不可用，改 curl 直下 SDK 包绕过；licenses 已手写。钉死版本见 `docs/versions.md`。
- 插件二选一结论：选 **`flutter_sing_box` 3.1.0**（GPL-3.0），唯一同时满足第一期 Win+Android 双端生产就绪、Windows TUN、Clash API 的候选；`sing_box` 1.0.0 不支持 Windows 一票否决，`sing_box_flutter` 0.3.1 太新太薄作备选。实测确认其内置 sing-box 核心是 **1.14.4**（Android libbox 1.14.4、Windows sing-box.exe strings 含 v1.14.4、官方 1.14.4 二进制实测）。决策记录见 `docs/api/plugin-decision.md`，对比全文见 `docs/plugin-choice.md`。
- 最小验证（本机能做的部分，全部通过）：`flutter test` **11/11**、`flutter analyze` 零问题；官方 sing-box 1.14.4 `check`（新格式 DNS 通过、legacy DNS 按预期拒绝）与 `run` 本地回环通过（mixed 入站 1080 转发到本地 HTTP 服务器）；Clash API `/version`（1.14.4）、`/proxies`（GLOBAL/direct/block）、`/traffic` 与 Dart 写的 Clash API 客户端全通过。证据在 `docs/validation/stage0/`。
- 工程架子 `apps/flutter_client/`：包名 **`com.zhexuexi.client`**（已拍板定死）；四个 tab 占位（首页大开关、节点页、我的页、设置页）；品牌变量 `assets/brand.json` 读取（包内默认值，深海蓝 `#16324F` + 琥珀金 `#E8A317`）；远程配置中心拉取占位；统一节点模型 `Node`；`subscription-userinfo` 头解析；sing-box 核心封装 `CoreService` 占位；Logo v1 已接入 `assets/logo/logo.png`。依赖：`flutter_sing_box` 3.1.0、`flutter_secure_storage` 11.2.0（9.x 与插件 win32 冲突，pub 建议升 11.x）、`shared_preferences` 2.5.6、`dio` 5.11.1、`flutter_riverpod` 2.6.1（状态管理全项目统一）、`yaml` 3.1.4。
- CI 接线：`.github/workflows/build.yml` 的 working-directory 已改成 `apps/flutter_client`，Flutter 钉死 3.50.1，品牌注入写 `assets/brand.json`，Windows 签名 `$pfx` 未定义 bug 已修，产物路径已改成工程内相对路径；YAML 解析通过。**CI 真跑留到阶段 1 前再验，不要声称跑过。**
- 本机编不出 APK（已查到根因）：沙箱 MITM 代理与 Java TLS 不兼容——curl 走代理能到 `plugins.gradle.org`（200），Java（`HttpsURLConnection` 与 Gradle 的 Apache HttpClient）握手直接超时/reset；TLS 1.2、导入沙箱 CA 进 JDK cacerts、配 Gradle 代理均无效。排查中修好的本机问题：Gradle 发行版 curl 预置（注意 Java 的 `user.home` 是 `/root` 不是 `$HOME`，哈希目录以 wrapper 实际建出的为准）、Gradle daemon 通信 Broken pipe（两侧加 `-Djava.net.preferIPv4Stack=true`，daemon 侧已写进项目 `android/gradle.properties`）、模板默认堆 8G 改 2G。详见 `docs/versions.md`。
- 未做：真实面板/节点对接（订阅解析、配置生成、核心启动在阶段 1）、Android 真机验证、Windows 真机验证、CI 真跑。
- 待用户拍板：`flutter_sing_box` 是 GPL-3.0，客户端源码公开范围须拍板，拍板前不要对外发布源码。

### MVP 切片 1：订阅拉取＋三种格式解析＋节点列表（2026-11-22）

- 切片规划见 `docs/mvp-slices.md`（共 8 片，按依赖排：1 订阅解析＋列表 → 2 配置生成＋核心接线 → 3 首页大开关＋流量三格 → 4 测速＋自动选节点 → 5 我的页 → 6 设置页＋规则＋DNS → 7 远程配置中心＋品牌替换 → 8 限流展示＋打包验收）。
- 新增 `lib/services/subscription_parser.dart`：sing-box JSON（只读 `outbounds` 节点出站，selector/urltest/direct/block 跳过不计失败）、Clash YAML（只读 `proxies`，proxy-groups/rules/dns 不读）、base64/plain 链接列表（vless/vmess/trojan/ss/hysteria2/tuic；HY2/TUIC 只在 base64/plain 里保留，面板 sing-box/Clash 里没有）。单个节点解析失败只计 `failedCount`，不丢整个订阅；整段正文无法识别抛 `FormatException`。
- `SubscriptionService` 加 `fetchNodes`：拉取回退链 singbox → base64 → clash（0 节点且有解析失败算该格式没读懂，继续回退；合法空订阅是 0 节点 0 失败）；状态码映射 404→“订阅已失效，请重新绑定”、410→“订阅已到期”、429→退避（Retry-After，默认 600 秒）、400→开发侧问题；404/410/429/400 不回退。`saveSubscriptionLink` 把完整链接拆成地址（shared_preferences）与令牌（系统密钥库）分开存。
- 新增 `lib/services/nodes_notifier.dart`（Riverpod `nodesProvider`，全项目共用）：拉取、绑定并刷新、清除；节点按名字后缀分中转/直连两组。
- 节点页改成真实列表：搜索框与两个按钮常驻；未绑定显示粘贴订阅链接入口（临时入口，切片 5 的“我的”页接管）；加载/失败/成功三种状态；失败横条“解析失败 N 个”；明文节点标“明文”角标；未测速显示“未测速”（测速在切片 4）。测速与自动选择按钮现置灰。
- 文档：`docs/api/panel-adapter.md` §6.1.1 加 1.3.37 补记（面板 DNS 已是新格式；客户端仍自己生成 DNS，不透传面板 DNS 段）。
- 测试：新增 `test/subscription_parser_test.dart`、`test/subscription_service_test.dart`（Dio 拦截器伪造响应、内存假安全存储）、`test/nodes_page_test.dart`（provider 桩覆盖）与 4 个 fixture（singbox_137.json / clash.yaml / links_base64.txt / links_plain.txt，全部脱敏数据）。基线 11/11 保持。
- 未做：配置生成与核心启动（切片 2）、首页大开关与流量三格（切片 3）、测速（切片 4）、真面板联调（等用户给测试订阅）、真机、APK、Win 构建。

### MVP 切片 3：首页大开关＋流量三格＋模式切换（2026-11-23）

- 大开关接真实核心（`lib/features/home/home_page.dart`，ConsumerStatefulWidget）：未连接时点开关先按当前模式 `applyNodes`（校验失败提示“配置生成失败，已保持上次连接”、不启动），再 `start()`；已连接时点开关停核心；无节点时不启动，提示“请先绑定订阅”并跳我的页。状态文案：未连接 / 连接中… / 已连接 / 断开中… / 连接失败：原因。当前节点＝第一个直连节点否则第一个（与配置生成默认选择同一规则），延迟格写“未测速（切片 4 接测速）”。另补了切片 2 的遗留缺口：应用内之前没有任何地方调 `CoreService.init()`（只测试调过），`main.dart` 改成 ConsumerStatefulWidget，`initState` 里 `unawaited(_initCore())`（失败吞掉，点开关时再报错）。
- 流量三格按 userinfo 口径（`lib/core/userinfo.dart` 重写）：字段改为可空 `int?`；无头（null/空串）返回 null，缺字段/非法值按该字段缺失（不按 0 兜底）；`used`/`remaining`/`usedRatio` 任一分量缺失时为 null；`total` 为 null 或 0＝不限量；`expire` 为 null 或 0＝永不过期。无头/缺字段显示“—”，不限量写“不限量”，剩余＜0 写“已超量”、＝0 写“已用完”，到期写日期＋剩 N 天/今天到期/已到期/永不过期。另有一格“流量口径：仅中转”＋说明“流量口径：仅中转（直连流量不计入，以面板用量为准）”，无头时说明为“未拉到流量数据，刷新订阅后显示；流量口径仅中转，直连流量不计入”。**来源只能是订阅响应的 `subscription-userinfo` 头**（面板无用户自查接口；upload/download/total 为字节、expire 为 Unix 秒）；直连流量不在 userinfo 里，不算进去也不显示成 0。
- 实时速率读 Clash API（`lib/core/clash_api_client.dart` 新建）：默认 `http://127.0.0.1:9090`，`trafficStream()` 逐行读流式 `/traffic`（坏行跳过，核心未启动时流以错误结束）；`trafficSample()` 用手动 `Timer` 实现超时。已启动且有帧时显示 `↑ x / ↓ y`，否则“—”。
- 模式切换三档（`lib/core/routing_mode.dart` 新建，`RoutingMode {rule, global, direct}`）：规则（TikTok/社交/流媒体/测 IP 走代理，.cn 直连，其余直连，默认）、全局（全部走代理）、直连（全部直连）。`lib/core/singbox_config.dart` 的 `build` 加 `mode` 参数（默认规则，老调用兼容）；全局＝route 无规则、final 有节点时 `Proxy`、无节点时 `direct`，DNS 规则全部走 dns-proxy；直连＝route 无规则、final direct，DNS 规则全部走 dns-direct。`RoutingModeNotifier`（`lib/services/routing_mode_notifier.dart`）：`setMode` 重新生成配置并（已运行时）重载，成功才提交＋持久化到 shared_preferences（键 `proxy_mode`）；校验失败或重载抛错时保持旧模式、把磁盘配置用旧模式重写回滚，返回 false；启动时异步读回持久化值。
- 测试：`flutter test` 93/93 全过（基线 65＋新增 28：配置生成模式组 5、Clash API 5、模式切换 7、首页 7、userinfo 更新 4），`flutter analyze` 零问题。真 1.14.4 校验：6 份配置（rule/global/direct × 有节点/空配置）`check` 全过；`run` 冒烟 4 份（rule/global/direct 有节点＋rule 空配置）均起得来，Clash API 返回 `{"meta":true,"premium":true,"version":"sing-box 1.14.4"}`，无 FATAL/ERROR；`/traffic` 真流出帧（`{"up":0,"down":0}`）。
- 测试里修了一个真坑（与切片 2 同类坑的第三处）：**testWidgets 的 fake 时间下，直接 await 真 dart:io（`File.exists()` / `readAsString()`）永远等不到完成**，开关测试因此挂 10 分钟超时；须把 tap 与所有真文件 IO 都包进 `tester.runAsync`（真实异步区）再 `pumpAndSettle`。另：停核心的 tap 也须在 runAsync 里点，否则插件流第二跳广播微任务在 fake 时间里赶不上 pumpAndSettle，界面还停在“已连接”（service.status 已是 stopped）。`runAsync<T>` 返回 `Future<T?>`，await 后须 `!` 解包。另发现本机 `/tmp`（512M tmpfs）曾被两个被杀掉的 flutter 测试残留目录占到 78%，编译拷 dill 报 No space，已清掉（`/tmp/flutter_tools.*` 是按次生成的临时目录，杀掉的残留可删）。
- 未做：测速/自动选节点（切片 4）、真面板联调（等用户给测试订阅）、真机、APK、Win 构建。

### MVP 切片 2：sing-box 配置生成＋CoreService 接线（2026-11-22）

- 新增 `lib/core/singbox_config.dart`（`SingboxConfigBuilder`）：从统一节点模型生成完整 sing-box 配置 JSON。DNS 客户端自生成新格式：DoH 双路（1.1.1.1 直连、dns.google 走代理）＋ DoT 8.8.8.8:853 兜底，只解析 IPv4（`strategy: ipv4_only`），不回落明文 UDP 53；`route.default_domain_resolver` 必填。route 规则按 panel-adapter.md §6.1.2 的域名清单：TikTok / 社交 / 流媒体 / 测 IP 走 Proxy，`.cn` 直连，其余直连。出站：节点出站＋selector `Proxy`（默认第一个直连节点）＋urltest `自动选择`＋direct＋block；重名节点加 ` (2)` 后缀；节点为空仍是合法空配置。Clash API（127.0.0.1:9090）预留给切片 3 的实时速率。
- 节点模型补两个字段（不然配置会缺东西）：`method`（SS 加密方式）、`wsHost`（WS Host 头），三个解析器都填上。
- 转不了的节点不静默丢弃也不静默降级：grpc 传输（模型没有 service_name）、缺 SS 加密方式、TUIC 账号拆不开的，都进 `skipped`（`名字：原因`），界面可提示；其余节点照常出配置。
- 新增 `lib/core/config_validator.dart`：插件内置的官方 sing-box 1.14 JSON Schema（纯离线）＋结构检查（legacy `address` 写法、tag 重复、`default_domain_resolver` 缺失、`strategy` 不是 ipv4_only 等）。
- `CoreService` 接线完成（`lib/core/singbox_core.dart`）：`applyNodes` 按“生成 → 校验 → 写盘 →（已运行时）重载”的顺序，校验失败不写文件、不调重载，旧配置继续跑；配置写插件的 `using_config.json`（原子写）；`start()` 要求先有配置（没有直接报错），首次启动自动建一个名为“哲学系”的本地档案（Android 启动要求 MMKV 里有已选档案）；`init()` 把磁盘上最后一份配置读回内存，App 重启后不用重新拉订阅也能启动。新增 `lib/core/core_provider.dart`（Riverpod 单例，切片 3 首页大开关用）。
- 插件接线结论（已核对 flutter_sing_box 3.1.0 源码，记进 `docs/api/plugin-decision.md`）：插件没有“设置配置”的 API，配置靠写 `using_config.json` 文件；`serviceReload()` 在插件里实现为重启（停＋起），换配置有短暂断开，不是无缝热重载。
- 真 1.14.4 二进制校验：生成的 4 份配置（面板 fixture 全协议、链接列表含 HY2、TUIC、空配置）`check -c` 与 `run`（3 秒启动冒烟）全部通过；legacy DNS 对照配置按预期被拒。**run 冒烟抓到两个真问题并已修**：① `detour: direct` 在 1.14.4 启动时被拒（"detour to an empty direct outbound makes no sense"），直连 DNS 与 DoT 不再写 detour；② `detour: proxy` 指向的出站 tag 不存在（面板 selector 叫 `Proxy`，大小写敏感），代理 DNS 的 detour 改成 `Proxy`；③ 节点为空时 `dns.google` 域名在启动时无人解析，空配置的代理 DNS 服务器改用 IP 8.8.8.8。**顺带发现面板 1.3.37 自身的问题**：面板下发的 sing-box JSON（detour direct＋小写 proxy）`check` 能过但 `run` 起不来，须面板侧修（见 `docs/api/panel-adapter.md` §6.1.1 补记）；客户端不受影响（客户端从不透传面板 DNS 段）。
- 测试：`flutter test` 65/65 全过（基线 38 个＋新增 27 个：配置生成 12、校验器 6、CoreService 9），`flutter analyze` 零问题。测试中抓到并修了一个真 bug：`CoreService.dispose()` 没取消插件状态流的订阅，dispose 后插件再推状态会往已关闭的控制器里写而抛错。
- 未做：首页大开关与流量三格（切片 3）、测速（切片 4）、真面板联调（等用户给测试订阅）、真机、APK、Win 构建。

### MVP 切片 4：节点页测速＋自动选节点（2026-11-23）

- 测速走 Clash API（`lib/core/clash_api_client.dart` 新增）：`GET /proxies/{name}/delay?url=<https://www.gstatic.com/generate_204>&timeout=5000`，200 且 `delay > 0` 才算成功，其余（404/503/0/连不上）一律返回 null 不抛错；切换走 `PUT /proxies/Proxy`（body `{"name": tag}`，204/200 成功）；`selectedProxy()` 读 `GET /proxies` 的 `now` 字段。**delay 接口只认 https**：上游源码 `experimental/clashapi/proxies.go` 的 `getProxyDelay` 里 `http://` 开头的 url 会被直接清空，所以测速地址必须用 `https://www.gstatic.com/generate_204`（配置里 urltest 组的 `http://` 自测不受影响）；超时按 16 位解析，超 32767 会 400，单节点超时定 5 秒。
- 节点模型加 `latencyFailed`（`lib/core/node_model.dart`）：测速失败与“未测速”区分开，失败节点标灰不丢。
- 配置生成（`lib/core/singbox_config.dart`）：`build()` 加 `selectedNodeName` 参数（指定 selector 默认；名字不在列表或节点被跳过时回落默认规则）；新增 `tagForNode()`（节点→配置 tag，重名加 ` (2)`，与 build 同一套去重；被跳过节点返回 null）与 `defaultNodeName()`（第一个直连节点，没有时第一个）。
- `CoreService` 加 `updateSelectorDefault(tag)`（`lib/core/singbox_core.dart`）：只改磁盘配置里 Proxy 的 `default` 字段，不校验、不重载；没有配置/没有 Proxy 组/tag 不在成员里返回 false 不写盘。`applyNodes()` 接 `selectedNodeName`。
- `NodesNotifier` 重写测速与选择（`lib/services/nodes_notifier.dart`）：`testAllSpeeds()`（核心未启动直接报“核心未启动，先在首页打开开关再测速”不发请求；4 路并发；被跳过节点不调接口直接标失败；逐批更新进度 `speedTestedCount/speedTestTotal`）；`autoSelect()`（没测过先测一轮，已有结果直接选；延迟相同直连优先再按列表顺序；全部失败不选、原因写清；选上后开自动选择开关）；`selectNode()`（核心在跑先调 API 切 selector，失败不切；再落盘默认选择；点一个节点＝核心切过去＋落盘，每次都走完，PUT 是幂等本地调用，不设“已是当前节点就短路”，避免配置重载后“记的是它、跑的不是它”）；后台 5 分钟重测定时器（懒启动，只在用户用过测速后才启动；仅 autoSelectEnabled＋已连接＋有节点＋不在测速中才测；新最快节点要比当前快 50ms 以上才切换；`ref.onDispose` 取消）。`refresh()` 保留仍在列表里的选中节点，不在了回落默认。
- 节点页（`lib/features/nodes/nodes_page.dart`）：一键测速（测速中显示“测速中 X/Y”且禁用）与自动选择两个按钮接线；`speedTestError` 横条与 `selectionReason` 常驻显示（不只 SnackBar）；失败节点标灰写“测速失败”；当前节点“使用中”角标且组内置顶；点一行选中该节点。
- 首页（`lib/features/home/home_page.dart`）：当前节点改认 `nodesState.selectedNode`（没选过仍按默认规则）；副标题显示测到的延迟/测速失败/未测速；大开关生成配置时带上 `selectedNodeName`。模式切换（`lib/services/routing_mode_notifier.dart`）：`setMode` 主调与回滚重写都带上 `selectedNodeName`，模式切换不把选过的节点换回默认。
- 测试里修了两个真坑：① 假服务器里对 `pathSegments`（已 percent 解码）再调 `Uri.decodeComponent`，会对 raw 中文名抛 `Illegal percent encoding in URI`（Dart 的 decodeComponent 不接受 raw 非 ASCII），导致 delay 请求挂 10 秒超时——`pathSegments` 直接用，不再二次解码（`subscription_parser.dart` 里已有同款 `_decodeComponentSafe`）；② `trafficSample` 超时测试的竞态：服务器 30 秒后才关响应，tearDown 强关时错误在测试结束后才冒出来、被算成“测试完成后失败”——改成服务器 500ms 后自己关响应、测试里等 1 秒再结束。
- 测试：`flutter test` 123/123 全过（基线 93＋新增 30：Clash API 延迟/切换组、配置生成 selector 组、CoreService `updateSelectorDefault` 组、测速 notifier 组、节点页组、首页组），`flutter analyze` 零问题。真 1.14.4 校验：生成的配置（Proxy default=日本-直连）`check` 过、`run` 冒烟起得来（Clash API 在 127.0.0.1:9090 监听）。
- 未核实：真面板联调（等用户给测试订阅）、真机、APK、Win 构建。**delay 接口成功路径在真机/真节点上尚未验过**：沙箱 MITM 拦截 sing-box 的 DoH 与对外 TLS，sing-box 内 DNS 与对外 TLS 全失败，拿不到成功的 `{"delay": N}`；但回环 204 服务器证明底层测量本身工作（urltest 组 history 出 5ms、3ms），成功路径靠 Dart 假服务器测试覆盖、行为按上游源码核对（200 返回 delay；404 未知出站；408 超时；503 测速失败；delay==0 视为失败）。一键测速要立即出数，不用 urltest 组 history 回退（只能等组内 5 分钟一轮）。
- 未做：我的页（切片 5）、设置页＋规则＋DNS 防泄漏（切片 6）、远程配置中心＋品牌替换（切片 7）、限流展示＋打包验收（切片 8）。

### MVP 切片 5：我的页（2026-11-23）

- 我的页（`lib/features/me/me_page.dart`，占位改成真实页）：账号区（已绑定显示订阅地址 host，未绑定显示“未登录（免登录模式）”）、订阅卡片（剩余流量大字 + 已用/总量 + 到期日 + “流量口径：仅中转”）、订阅更新卡（上次更新时间 + 手动刷新按钮）、公告卡、换绑订阅、退出登录。数据全部复用 `nodesProvider`，不重复拉订阅。
- 三格文案抽成公共函数（`lib/core/userinfo.dart` 新增 `usedTotalText` / `remainingText` / `expireText` / `formatDateTime`，首页改调同一套）：无头/缺字段显示“—”不显示 0，不限量写“不限量”，超量写“已超量”，直连流量不计入。
- 手动刷新：复用 `NodesNotifier.refresh()`；成功记一次时间并提示“订阅已更新”，失败原因（网络不通/订阅 404/令牌失效）在更新卡片里常驻显示，不静默失败。
- 每天自动更新一次，仅 Wi-Fi（`lib/services/subscription_auto_refresh.dart`，新增 `connectivity_plus 7.3.2` 依赖）：上次成功不到 24 小时不拉、不在 Wi-Fi 下不拉、未绑定不拉、失败不记时间；上次成功时间存 shared_preferences，重启也认；App 启动与我的页打开时各调一次（幂等）；手动刷新成功也算一次。
- 公告（`lib/services/announcement_service.dart`）：面板公开接口 `GET /api/v1/public-info` 的 `login_notice`，请求走订阅地址 origin，令牌绝不拼进去；拉不到返回上次缓存，没有缓存显示“暂无公告”。
- 换绑：弹窗粘贴新链接调 `bindAndRefresh`，错了原因显示在弹窗里、不关弹窗；退出登录：确认后调 `clear()` 清绑定与本地配置（面板侧用户不受影响）。
- 测试：`flutter test` 151/151 全过（基线 123＋新增 28：我的页 10、自动更新 7、公告 6、三格共享文案 5），`flutter analyze` 零问题。测试里修了一个真坑：ListView 下面的卡片在测试视口外不会构建，点之前要用 `scrollUntilVisible` 滚到可见（`ensureVisible` 找不到未构建的 widget）。未改 sing-box 配置生成逻辑，不用真 sing-box 冒烟。
- 未核实：真面板联调（等用户给测试订阅）、真机、APK、Win 构建；Wi-Fi 检测（connectivity_plus）在真机上尚未验过；公告接口经 Worker 域名是否通尚未验过（拉不到时回退缓存/“暂无公告”）。
- 未做：设置页＋规则＋DNS 防泄漏（切片 6）、远程配置中心＋品牌替换（切片 7）、限流展示＋打包验收（切片 8）。
