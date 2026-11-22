# 发布检查清单（切片 8：打包验收）

> MVP v0.1.0（Win exe + Android APK）发版前逐项打勾。没做过的照实写
> “未测”，不要在本机冒充已验。版本号与流程见 DEV-PLAN §2.4 / §6。

## 1. 打包前检查（本地，必做）

- [ ] `flutter test` 全量通过（写清数字，如 208/208）
- [ ] `flutter analyze` 零问题
- [ ] 改了 sing-box 配置生成逻辑时：真 sing-box 1.14.4 `check` + `run`
      冒烟（有节点 / 空配置各一次；只验 `check` 不算数，见 1.3.37 教训）
- [ ] 版本号一致：`pubspec.yaml` 的 `version` 与
      `lib/brand/remote_config.dart` 的 `appVersion` 同步
      （当前都是 0.1.0；`+1` 是 build 号）
- [ ] `CHANGELOG.md` 有本版条目；`docs/mvp-slices.md` 进度已更新
- [ ] 远程配置公钥一致：`lib/brand/remote_config_keys.dart` 里的公钥
      必须对应 `~/workspace/user/remote-config-private-key.pem`
      那把私钥（`sign.py pubkey` 对得上才算）；换公钥必须重新打包
- [ ] 仓库里没有私钥 / keystore / `.pfx` / 令牌（`.gitignore` 已拦
      `*.pem` / `*.key`；推前 grep 一遍）

## 2. 打 tag，走 CI 出包

CI 在 `.github/workflows/build.yml`（阶段 0 已接线）：

- 打 tag `v0.1.0`（或 `workflow_dispatch` 手动触发）→ GitHub Actions
  自动编 Windows exe 与 Android APK，产物 + SHA256 一起上传
  （artifact 保留 90 天）。
- Windows job：`flutter build windows --release`；Android job：
  `flutter build apk --release`（有 keystore Secrets 时签名）。
- **CI 真跑尚未验过**：本机沙箱的 MITM 代理与 Java TLS 不兼容，
  Gradle 在本机下不到依赖（见 `docs/versions.md`）；第一次打 tag
  后须去 Actions 里看两 job 是否都绿、产物能不能下载安装。
  没绿之前不要对外宣布“已发布”。

## 3. 签名（正式发布前必须填好，否则按下表降级）

| 平台 | 正式发布要求 | 没填 Secrets 时 CI 的行为 |
|---|---|---|
| Windows | OV 代码签名证书（Secrets `WINDOWS_CERT_BASE64` / `WINDOWS_CERT_PASSWORD`） | 只出未签名包供测试；SmartScreen 会弹“未知发布者” |
| Android | 自签名 keystore（Secrets `ANDROID_KEYSTORE_BASE64` 等） | 只编 debug 包供测试，不出正式包 |

- 证书由助手办（DEV-PLAN §10.1 已定）；keystore（`.jks` + 密码）
  由用户保管，**丢了就不能再以同一签名升级，必须备份**。
- Secrets 只填在仓库 Settings → Secrets and variables → Actions，
  绝不写进代码、不打日志；fork 不会带走 Secrets。

## 4. 下载页与远程配置

- 官网下载页放最新版两个安装包 + SHA256；**保留最近 3 个版本可回滚**
  （DEV-PLAN §11.5）。
- 发版后更新远程配置的 `download_url`（指向下载页），
  `config_version` +1 重新签名发布（见 `tools/remote-config/README.md`）；
  强制更新弹窗里显示的就是这个地址。
- 远程配置的 `announcement` 写清本版内容与已知未测项。

## 5. 回滚（DEV-PLAN §6.4）

发错了能退回去：

1. 官网下载页换回上一个版本的安装包；
2. 远程配置 `force_update` 关掉（不要强制用户升到错版）；
3. 公告说明回滚原因与重新下载地址；
4. 远程配置本身要回滚时：`config_version` +1 发一份回滚配置
   （订阅地址与面板域名改回旧值），重新签名，客户端下次拉取即回滚。

## 6. 发布记录

每次发布在 `docs/releases/vX.Y.Z.md` 写一份（DEV-PLAN §6.3）：
版本号 / commit SHA / 核实到哪一级（代码已推 / 本地构建过 / 真机跑过，
三级分开写）/ 测试结果 / 未测项 / 回滚方案 / 公告。
首份记录见 `docs/releases/v0.1.0-mvp.md`。

## 7. 本版已知未测（v0.1.0 MVP，照实写）

- 真面板联调（须用户给测试订阅）、真机、APK 与 Win 包的真机安装；
- CI 首次跑（两 job 是否都绿、产物是否可用）；
- 远程配置中心真端（面板接口 D10 未拍板、Worker 路由未加，
  GitHub Raw 的 `client-config.json` 尚未发布）、品牌替换真机效果；
- TUN 在真机上是否起得来（只做了 `check`）；Wi-Fi 检测真机未验；
  公告经 Worker 域名未验；delay 接口成功路径真机未验。
- 直连流量不在 userinfo 里：**直连不限流**，发布说明里写明
  （DEV-PLAN §4.3 1-10；A 线 Phase 1 通过前界面写明“仅中转”）。
