# 插件决策记录（阶段 0，2026-11-22）

> DEV-PLAN §4.2 第 3 步要求的书面结论。二选一对比全文见 `docs/plugin-choice.md`；
> 这里只记拍板结论、实测验证结果与待用户拍板的事。

## 结论：选 `flutter_sing_box` 3.1.0

- 包：`flutter_sing_box` **3.1.0**（2026-11-01 发布，仓库 `github.com/clash-sing/flutter_sing_box`）。
- 许可证：**GPL-3.0**。
- 选它的理由：候选里唯一同时满足第一期 Win+Android 双端生产就绪、Windows TUN、Clash API（含测延迟/选出站/实时流量）、订阅三格式导入。
- 淘汰：`sing_box` 1.0.0（功能最全但 pub.dev 明确不支持 Windows，一票否决）；`sing_box_flutter` 0.3.1（五端全支持但仅 14 天历史、20 commits、1 star、API 太薄，无 Clash API/测速/流量）；v2ray_box、singbox_ffi 淘汰。
- 状态管理二选一同步拍板：**flutter_riverpod 2.6.1**，全项目统一，不混用 bloc。

## 核心版本实测确认：sing-box 1.14.4

`flutter_sing_box` 3.1.0 实际内置的核心版本，阶段 0 已实测确认是 **1.14.4**（与上游最新稳定版一致，消除了 `docs/plugin-choice.md` 里“3.1.0 未记录核心升级”的疑点）：

| 端 | 证据 |
| --- | --- |
| Android | 插件 `android/build.gradle.kts` 引用 `com.github.singbox-android:libbox:1.14.4` |
| Windows | 插件包内 `assets/windows/amd64/sing-box.exe` 的 strings 含 `mod github.com/sagernet/sing-box v1.14.4` |
| 官方二进制 | 本机下载官方 `sing-box-1.14.4-linux-amd64`，`sing-box version 1.14.4`，带 `with_clash_api` 标签 |

## 最小验证结果（本机 Linux 能做的部分，2026-11-22）

按 `docs/plugin-choice.md` §4 的分级，只做了 4.1（本地验证）；4.2（Android）与 4.3（Windows）须真机，未做。证据文件在 `docs/validation/stage0/`。

| 验证项 | 结果 |
| --- | --- |
| 纯 Dart 单测 | 通过：`flutter test` **11/11**（品牌配置 4、userinfo 解析 5、widget 冒烟 2） |
| `flutter analyze` | **零问题** |
| 官方 sing-box 1.14.4 `check`（新格式 DNS 配置） | 通过 |
| 官方 sing-box 1.14.4 `check`（legacy DNS 配置） | 按预期拒绝，报错 `legacy DNS server formats ... removed in sing-box 1.14.0`——证实面板 legacy DNS 不能原样透传 |
| `sing-box run` 本地回环 | 通过：mixed 入站 127.0.0.1:1080 转发到本地 HTTP 服务器，curl 返回页面，exit 0 |
| Clash API `/version` | 通过：`{"meta":true,"premium":true,"version":"sing-box 1.14.4"}` |
| Clash API `/proxies` | 通过：`GLOBAL / direct / block` 三个组 |
| Clash API `/traffic` | 通过：一帧采样 `{"up":0,"down":0}` |
| Dart 写的 Clash API 客户端 | 通过：`clash_client.dart` 断言全过（版本 + 出站 + 流量采样），exit 0 |

验证中踩到的两个坑（已写进代码注释与验证脚本，阶段 1 别再踩）：

1. **新格式 DNS 必须用 `type`**：`{"address": "https://..."}` 对象仍是 legacy 格式，会被 1.14 拒绝；新格式是 `{"type": "https", "server": "223.5.5.5", "server_port": 443, ...}`；`address_resolver` 不是新格式 DNS 服务器的字段；Clash API 字段叫 `external_controller` 不是 `listen`；`route.default_domain_resolver` 必填。
2. **`/traffic` 是流式接口**：每秒推一帧永不关闭，不能用 `.join()` 等流结束，只能读第一行就关连接。

## 插件 API（阶段 0 已核对源码，供阶段 1 调用）

主入口 `FlutterSingBox`（`package:flutter_sing_box/flutter_sing_box.dart`）：

- 生命周期：`init()`、`startVpn()`、`stopVpn()`、`serviceReload()`。
- 选节点/测速：`setClashMode(String)`、`selectOutbound({groupTag, outboundTag})`、`setGroupExpand({groupTag, isExpand})`、`urlTest({groupTag})`。
- 状态流：`proxyStateStream`（sealed class `ProxyState`：`ProxyStopped(errMessage?)` / `ProxyStarting` / `ProxyStarted` / `ProxyStopping`）、`connectedStatusStream`、`groupStream`、`clashModeStream`、`logStream`。
- 版本：`getSingBoxVersion()`。
- Windows 服务：`installService({serviceName, displayName, description})`、`uninstallService()`、`startService()`、`stopService()`、`queryServiceStatus()`、`hasPendingHelperUpdate()`、`restartService()`（仅 Windows 实现，其他平台抛 `UnimplementedError`，调用前先判平台）。
- 阶段 0 的封装：`lib/core/singbox_core.dart` 的 `CoreService`（只包启动/停止/读状态/读日志/读版本号；配置生成归阶段 1）。

## 待用户拍板

1. **GPL-3.0 合规**：三个候选插件全是 GPL-3.0。客户端源码公开范围未定——公开源码即合规，不公开则须另想办法（换插件/买授权/自研封装）。**拍板前不要对外发布源码。**
2. **包名已定**：`com.zhexuexi.client`（阶段 0 拍板，不再改）。
3. **插件 fork 只读镜像**：`docs/plugin-choice.md` 建议 fork 一份只读镜像防插件删仓/改 API，是否做、放哪个组织，等用户拍板。

## 未核实项

- Android VpnService 全链路（安装→授权→连接→断网重连→后台保活→卸载）：须 Android 真机。
- Windows 服务安装/UAC/崩溃恢复/卸载全链路：须 Windows 真机。
- 插件在 Android 上的真实 libbox 行为（只核对了版本号，未跑真机）。
- CI 真跑（GitHub Actions）：Flutter 工程刚建，构建命令须先在 CI 上实跑一次，阶段 0 只做到 YAML 解析通过。
