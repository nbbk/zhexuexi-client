# 远程配置中心：`client-config.json` 接口文档

> 切片 7 落地。面板侧接口 `GET /client-config.json` 尚不存在（待拍板 D10），
> MVP 先走 Worker 直出 / GitHub Raw / R2 + 本地缓存兜底。
> 本文档是客户端与配置发布方的契约：改格式先改本文档，再改代码、再改测试。

## 1. 信封格式

顶层 JSON（字段表见 DEV-PLAN 附录 B / 客户端方案 §6.2）：

```json
{
  "config_version": 3,
  "updated_at": "2026-11-21T15:00:00+08:00",
  "min_app_version": "1.0.0",
  "force_update": false,
  "force_update_message": "当前版本无法解析新订阅格式，请升级到最新版。",
  "download_url": "https://example.com/download",
  "brand": {
    "app_name": "哲学系",
    "logo_url": "https://config.example.com/zhexuexi/logo.png",
    "primary_color": "#16324F",
    "accent_color": "#E8A317",
    "support_url": "https://example.com/support"
  },
  "panel": {
    "panel_domain": "panel.example.com",
    "panel_api_base": "https://panel.example.com",
    "min_panel_version": "1.3.29",
    "subscription_url": "https://sub.example.com/x9f2/sub_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "subscription_backup_urls": ["https://sub2.example.com/x9f2/sub_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
    "subscription_format": "singbox"
  },
  "announcement": {
    "id": "20261121-domain-change",
    "title": "域名已更换，客户端不用重装",
    "body": "订阅地址已更新，下次启动自动生效。",
    "url": "https://example.com/notice/20261121"
  },
  "features": {
    "auto_select": true,
    "tun_default": true,
    "show_traffic": true
  },
  "signature": "BASE64_ED25519_SIGNATURE_OVER_CANONICAL_JSON"
}
```

| 字段 | 含义 | 改了之后 |
|---|---|---|
| `config_version` | 配置版本号，单调递增 | 客户端只接受比本地缓存新的版本，不回退 |
| `min_app_version` / `force_update` | 最低可用客户端版本 / 是否强制更新 | 低于最低版本时首页弹升级提示；`force_update` 为真时大开关拦住、弹全屏升级说明，不让继续用旧版连 |
| `download_url` | 强制更新时给用户看的下载地址（官网下载页） | 升级弹窗里显示成可复制的文本；配置里没给时弹窗只说明原因、不写地址 |
| `brand.*` | 应用名、Logo 地址、主色、强调色、客服链接 | 重启客户端即生效，不用重新打包（Logo 是远程图，首次加载后缓存；离线用包内默认 Logo） |
| `panel.subscription_url` / `subscription_backup_urls` | 当前订阅地址 + 备用订阅地址 | 下次订阅更新即用新地址；旧地址 404 时自动试备用地址（令牌不变、只换地址） |
| `panel.panel_domain` / `panel_api_base` | 面板域名与接口地址 | 面板换域名后改这里，客户端不用重装 |
| `announcement.*` | 公告（带唯一 id，去重用） | 远程配置公告优先于面板 public-info 的公告 |
| `features.*` | 功能开关（自动选节点、TUN 默认开、流量显示） | 可远程关掉出问题的功能，不用发版 |
| `signature` | Ed25519 签名 | 验签失败的配置一律不用 |

注意：

- `panel.subscription_url` 与备用地址里不要放真实用户令牌——示例里的
  `sub_AAA…` 只是占位。客户端取备用地址时只取 base（去掉 `sub_` 开头
  的最后一段），再拼用户自己的令牌；令牌只存在用户本机安全存储里。
- `panel_api_base` 为空时由 `panel_domain` 派生 `https://<域名>`。
- `brand.logo_url` 为空时用包内默认 Logo（`assets/logo/logo.png`）。

## 2. 拉取地址链

客户端按顺序试，第一个验签通过且版本比缓存新的就用（超时 10 秒/个）：

1. **面板**：`https://<panel_domain>/client-config.json`（方案 A）。
   面板域名取自本地缓存的最后一份好配置（没有时用包内默认值，
   `example.com` 占位地址跳过不拉）。须面板新增公开只读接口
   （待拍板 D10）；Worker 须同步加一条路由反代（现有 Worker 模板
   只放行订阅路径，其他路径一律 404，见 panel-adapter.md §3）。
2. **Worker 直出**：`https://cc.jiankong.cf/client-config.json`（方案 B）。
   须在现有 Cloudflare Worker 里加一个路由，直接返回信封 JSON
   （内容存在 Worker KV 或写在 Worker 代码里）。
3. **GitHub Raw**：`https://raw.githubusercontent.com/nbbk/zhexuexi-client/main/client-config.json`
   （方案 C）。信封文件由运营方签名后推到客户端仓根目录；
   Raw 有约 45–90 秒缓存延迟。

三个地址须是三个不同域名，一个被封试下一个。运营方还可以在
shared_preferences 的 `remote_config_extra_urls` 里追加地址
（排在三地址之后；目前没有在界面里改它的入口）。

**今天的状态**：面板接口与 Worker 路由都还没接，三地址里只有 GitHub Raw
这条路是发布方现在就能走通的（签名后把文件推到仓根目录即可）。

## 3. 签名规则

- 算法：Ed25519。私钥只存在运营方手里（离线保管，不进仓库、不进面板、
  不进 Worker 代码）；公钥编译进客户端（`lib/brand/remote_config_keys.dart`，
  换公钥才须重新打包——公钥几乎不换）。
- 签什么：除 `signature` 字段外的全部内容做规范 JSON（key 按字典序递归
  排序、无空格、无换行）后签名。签名工具见 `tools/remote-config/sign.py`
  （`sign` / `verify` / `generate-key` / `pubkey`），只依赖 Python 标准库
  + openssl。
- 客户端收到后先验签，验签通过才解析应用；验签失败直接丢弃、用本地缓存
  的最后一份好配置，并继续试下一个地址。
- 传输层一律 HTTPS；HTTP 地址客户端直接拒绝（本机回环地址
  `127.0.0.1` / `::1` / `localhost` 除外，只给本地假服务器测试用，
  生产地址全是 HTTPS）。

规范 JSON 的细节（签名方与验签方必须逐字节一致，否则签名对不上）：

- key 排序按字典序（ASCII key 与 Python `sort_keys=True` 一致）；
- 紧凑格式，无空格、无换行（`separators=(',', ':')`）；
- 字符串用 UTF-8 原文（不转 `\uXXXX`），只转义 `"`、`\` 与控制字符；
- 数字不要用浮点写版本号（`config_version` 必须是整数）。

## 4. 版本规则与缓存

- 客户端只接受比本地缓存新的版本，不回退；同版/旧版继续试下一个地址
  （另一个地址可能有更新的版本），都没有新版时报“已是最新配置”。
- 拉到的新版验签通过后立即存本地缓存（shared_preferences
  `remote_config_cache`，整封信封原文）；读缓存时重新验签，签不过
  当作没有缓存并清掉。
- 全部地址失败时用本地缓存的最后一份好配置，首页提示
  “配置中心暂时连不上，正在用上次的配置”；全新安装且首次拉取就失败时，
  用包内内置默认值（订阅地址为空，首页提示“首次启动需要联网拉取配置”，
  并给一个“重试”按钮 + 我的页手动粘贴订阅的兜底入口）。

## 5. 订阅地址换了之后（客户端行为）

- 下次订阅更新即用新地址；旧地址 404 时先拉远程配置，再用新地址
  （主地址 → 备用地址）重试一次，令牌不变、只换地址；重试成功时
  节点页顶部显示一句“订阅地址已变，已自动切换到新地址”，用户可关掉；
  新地址也拉不到才报原来的“订阅已失效，请重新绑定”，本地绑定不动。
- 品牌（应用名、主色、Logo）拉到新版就换，界面跟着变，不用重启；
  订阅地址换了要下次订阅更新才生效（正在跑的节点不断线）。
- 强制更新只用于“旧版客户端解析不了新订阅格式”这种真断裂场景，
  不要拿来当日常推送手段。`force_update` 为真且当前版本低于
  `min_app_version` 时，首页大开关拦住、弹升级说明；下载地址是
  顶层 `download_url`（切片 8 接入），升级弹窗里显示成可复制的
  文本，配置里没给时只说明原因、不写地址。
