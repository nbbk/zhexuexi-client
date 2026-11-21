# 钉死的版本（阶段 0，2026-11-22 核实）

> 规则：升级任何一项，先在这里改，再改 `pubspec.yaml` / CI，禁止悄悄改。
> 每个版本都写了“为什么选这个”和“从哪核实的”。
> 本机是 Linux VM（沙箱），没有 Win 真机、没有 Android 真机——
> 所有“本机能做的”都已做到，所有“要真机的”都列在文末。

## 工具链

| 工具 | 钉死版本 | 为什么选这个 | 从哪核实的 |
| --- | --- | --- | --- |
| Flutter | **3.50.1**（stable） | 最新稳定版；2026-11-18 发布 | `flutter --version`（本机实测）；`storage.googleapis.com/flutter_infra_release/releases/releases_linux.json` |
| Dart | **3.14.0**（随 Flutter 3.50.1） | Flutter 3.50.1 自带，不单独选 | `flutter --version`：Dart 3.14.0，Engine 51379e6df4，DevTools 2.61.0 |
| JDK | **Temurin 17.0.21.1+2** | Flutter 3.50 与 Gradle 9.5 都要求 JDK 17 | `java -version`（本机实测）；装在 `~/workspace/toolchains/jdk17/` |
| Android SDK | **36**（API 36） | Flutter 3.50.1 的 doctor 明确要求 SDK 36，装 34 时 doctor 报错 | `flutter doctor`（本机实测）；cmdline tools 13114758 |
| Android build-tools | **36.0.0** | 与 SDK 36 配对 | `sdkmanager` 直链下载（本机实测） |
| Android platform-tools | **37.0.3** | 当前最新 | repository2-1.xml 直链下载（本机实测） |
| Gradle | **9.5.0**（wrapper 自带） | Flutter 3.50.1 模板的 `gradle-wrapper.properties` 指定 | `android/gradle/wrapper/gradle-wrapper.properties` |
| sing-box 上游 | **v1.14.4** | 最新稳定版；2026-10-23/24 发布 | 官方 GitHub Release；本机下载官方 `sing-box-1.14.4-linux-amd64` 实测 `sing-box version` |

### 本机装到哪一步（2026-11-22 实测）

- Flutter 3.50.1、Dart 3.14.0、JDK 17、Android SDK 36、cmdline tools：**已装好**，`flutter --version` 与 `flutter doctor` 通过（只剩两项不影响构建的提示：Chrome 缺失、Linux 桌面工具链缺 clang/ninja/GTK）。
- `sdkmanager` 不可用：本机 MITM 代理导致 Java `HttpURLConnection.doTunneling` 报 `NoSuchElementException`；改用 curl 直接下三个 SDK 包的 zip（platform-tools / build-tools / platforms）绕过。
- `flutter doctor` 的 “Android license status unknown” 是同一原因（doctor 要跑 `sdkmanager --licenses`），licenses 文件已手写进 SDK 目录。
- Linux 桌面构建做不了（缺 clang++、ninja、GTK 3.0 开发库）；不要用 apt/sudo 绕过——2026-11-22 一次含 `sudo -n true` 的检查触发审批且超时未批复，须用户重新批复才能再试。
- Windows 包本机编不出来（Flutter 官方规则，只能在 Windows 上编），留给 CI / Windows 真机。

## 依赖（pubspec.yaml → pubspec.lock 锁定值）

| 包 | 锁定版本 | 为什么选这个 | 从哪核实的 |
| --- | --- | --- | --- |
| `flutter_sing_box` | **3.1.0** | 插件二选一结论（见 `docs/api/plugin-decision.md`）：唯一同时满足第一期 Win+Android 双端生产就绪、Windows TUN、Clash API 的候选 | pub.dev；本机 `flutter pub get` 解析通过 |
| `flutter_secure_storage` | **11.2.0** | 9.x 与 `flutter_sing_box` 的 win32 版本冲突（9.x 要 win32 ^5，插件要 ^6），pub 建议升 11.x | 本机 `flutter pub get` 报错原文 + 升级后解析通过 |
| `shared_preferences` | **2.5.6** | 节点缓存、设置、远程配置缓存 | `flutter pub get` 解析通过 |
| `dio` | **5.11.1** | 订阅拉取、远程配置拉取（超时 + 重试） | `flutter pub get` 解析通过 |
| `flutter_riverpod` | **2.6.1** | 状态管理：全项目统一用 riverpod，不混用 bloc | `flutter pub get` 解析通过 |
| `yaml` | **3.1.4** | Clash YAML 订阅解析（只取 proxies 节点） | `flutter pub get` 解析通过 |
| `material_ui` | **1.11.1** | Flutter 3.50 把内置 material 库拆成独立包，新工程模板默认用它 | `flutter create` 生成 + `flutter analyze` 零问题 |
| `cupertino_icons` | **1.0.9** | 模板默认 | `flutter pub get` 解析通过 |

包名（applicationId）：**`com.zhexuexi.client`**（DEV-PLAN §4.2 建议值，阶段 0 拍板定死，不再改；工程生成时的默认值 `com.zhexuexi.zhexuexi_client` 已改掉，含 Linux CMakeLists 的 APPLICATION_ID）。

## 核心版本（实测确认）

`flutter_sing_box` 3.1.0 内置的 sing-box 核心是 **1.14.4**，与上游最新稳定版一致：

- Android 端：插件 `android/build.gradle.kts` 引用 `com.github.singbox-android:libbox:1.14.4`。
- Windows 端：插件包内 `assets/windows/amd64/sing-box.exe` 的 strings 含 `mod github.com/sagernet/sing-box v1.14.4`。
- 官方 1.14.4 Linux 二进制本机实测：`sing-box version 1.14.4`，带 `with_clash_api` 标签。
- 插件 CHANGELOG 的疑点已消除：3.0.1 升到 1.14.3，3.1.0 未写核心升级，但实测两端都是 1.14.4。

sing-box 1.14 的两个破坏性变化，客户端必须遵守（本机实测确认）：

1. **legacy DNS 格式已移除**：`dns.servers` 用 `address` 字符串或 `{"address": ...}` 对象都会被 `check` 拒绝（报错 `legacy DNS server formats are deprecated in sing-box 1.12.0 and removed in sing-box 1.14.0`）。新格式必须用 `type` / `server` / `server_port` / `path`（见 `docs/validation/stage0/sing-box-1.14.4-config.json`）。面板 1.3.29 下发的 sing-box JSON 仍是 legacy 格式，客户端绝不能原样透传，须自己生成新格式 DNS（见 `docs/api/panel-adapter.md` §2.2）。
2. **`route.default_domain_resolver` 必填**：不填时 `check` 报错（须 `ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true` 才能继续用旧写法，客户端不走这条路）。

## Android APK 本机编不出来（已查到根因，2026-11-22）

`flutter build apk --debug` 在本机走到了 Gradle 构建，但卡在下载 Gradle 插件依赖（`org.gradle.kotlin.kotlin-dsl:6.5.7`），根因是**沙箱 MITM 代理与 Java TLS 不兼容**：

- curl 走同一代理能到 `plugins.gradle.org`（200），Java（`HttpsURLConnection` 与 Gradle 的 Apache HttpClient）握手直接超时/reset。
- 已试过且无效：只用 TLS 1.2（`-Djdk.tls.client.protocols=TLSv1.2`）、把沙箱 CA（`hatch-egress-ca.pem`）导入 JDK cacerts、Gradle 代理配置（`systemProp.http(s).proxy*` 已配进 `/root/.gradle/gradle.properties`，不进仓）。
- 这是本机沙箱的问题，不是项目的问题：CI（GitHub Actions）与 Windows 构建机没有这个代理，构建应能正常跑。**APK 真编出来留到阶段 1 前在 CI 上验，不要声称本机编过。**

排查路上修好的三个本机问题（都已落进项目或写进文档，不用再踩）：

1. **Gradle wrapper 发行版下不下来**（Java 经 MITM 代理下 `services.gradle.org` 失败）：用 curl 下 `gradle-9.5.0-all.zip`（240MB），预置到 wrapper 的 dist 目录。注意两点：Java 的 `user.home` 是 `/root`（uid 0 的家目录），不是 shell 的 `$HOME`（`/home/hatch`），预置位置是 `/root/.gradle/wrapper/dists/...`；哈希目录名不是 URL 的 MD5，是 wrapper 自己算的 `aca6g93cdtcf0oapcfka748qh`（以第一次运行后实际建出的目录为准）。
2. **Gradle daemon 通信 Broken pipe**：Java 默认走 IPv6 映射回环，本机沙箱里握手通了但数据到不了监听进程（curl→回环正常，Java→回环不通，实测确认）。解法：daemon 与客户端两侧都加 `-Djava.net.preferIPv4Stack=true`——daemon 侧已写进项目 `android/gradle.properties`（正常机器上无害），客户端侧靠 `GRADLE_OPTS` 环境变量（`flutter build apk` 会透传给 gradlew）。
3. **模板默认堆 8G 太大**：Flutter 模板的 `gradle.properties` 写 `-Xmx8G`，§11 构建机最低只要 2 核/4GB，8G 会 OOM；已改成 `-Xmx2G -XX:MaxMetaspaceSize=512m`（写进项目 `android/gradle.properties`）。

## 面板版本

- 客户端原生适配的面板版本：**relay-node 面板 1.3.29**（DEV-PLAN 定）；包内 `assets/brand.json` 的 `min_panel_version` 仍为 `1.3.29`。
- 注意：阶段 0 进行期间面板已推到 **1.3.30**（main 894f9a9，2026-11-22：加三个 agent 接口 `GET /api/v1/node/users`、`POST /api/v1/node/push`、`GET /api/v1/node/config`，只收数不执法）。1.3.30 的订阅接口与 1.3.29 兼容，客户端阶段 0 不依赖 agent 接口，不跟进改版；阶段 1 再确认 `min_panel_version` 是否提到 1.3.30。

## 还没钉死的（阶段 1 再定）

- iOS / macOS / Linux 客户端的 Flutter 与 SDK 版本（第二期平台分期时定）。
- Windows 签名证书（DEV-PLAN §10 D12：助手负责，阶段 1 落地；CI 的 6 个 Secrets 须在真构建前填好）。
- `flutter_sing_box` 是 GPL-3.0：客户端源码公开范围须用户拍板（见 `docs/api/plugin-decision.md` §6），拍板前不要对外发布源码。
