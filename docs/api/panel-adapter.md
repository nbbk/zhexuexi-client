# 面板适配接口确认（relay-node 面板 1.3.29）

- 核对依据：本地只读副本 `relay-node-kit-160/panel/`，`VERSION` 文件内容为 `1.3.29`。
- 通读文件：`handlers.go`（路由注册与会话/白名单中间件）、`subscription.go`（订阅端点、格式识别、`subscription-userinfo`、订阅路径/对外域名/文件名）、`user_traffic.go`（按人限流的 userinfo 拼法）、`subtoken.go`（令牌格式与限流）、`subgroup.go`（分组生效逻辑）、`central.go` / `central_user.go`（集中管理通道）、`config.go`（`subPath()` 默认值与配置字段）。
- 本文档只写代码里确认的事实。凡写“没有”的，都是在路由表与全仓 grep 中查无此物；凡写“须实测”的，见末尾“未核实项”。
- 脱敏：本文所有示例一律用 `example.com` / `203.0.113.1` / `/sub-path/` / `sub_` + 64 位十六进制占位，不含任何真实域名、IP、订阅路径与令牌。

---

## 1. 用户自查接口：没有

**结论：面板 1.3.29 没有给客户端用的“用户自查”接口。没有用订阅令牌查自己的流量 / 到期 / 分组（或用量、停用状态）的公开接口。MVP 只能靠订阅 + `subscription-userinfo` 响应头。**

核对过程（`handlers.go` 路由注册表，全量核对）：

- 无须认证的 GET 路由只有 5 条：
  - `GET /`——面板前端（`handleRoot`，静态页面分发）；
  - `POST /api/v1/login`——管理员登录；
  - `GET /<订阅路径>/{token}`——订阅端点（`handleSub`，见 §2）；
  - `GET /logo`——面板 Logo；
  - `GET /api/v1/public-info`——公开读登录页信息，只返回两个字段：`login_notice`（登录页公告，纯文本，最多 500 字）与 `login_signature`（登录页签名）。**不含流量、到期、分组、订阅、版本号中的任何一项**，不能当作自查接口或配置中心用。
- 其余全部 `/api/v1/*` 路由都包着 `requireAuth`（管理员登录会话）或 `requireCentralToken`（集中管理 `rpt_` 令牌，面板与面板之间用，见下），客户端拿订阅令牌调它们会返回 401。
- 与订阅令牌沾边的管理接口（`GET /api/v1/subscriptions/link`、`GET /api/v1/subscriptions/users`、`GET /api/v1/subscriptions/groups` 等）全部是会话认证，返回的是管理员视角的全量列表，不是“查自己”。客户端绝不能拿管理员会话去调。
- 集中管理接口（`/api/v1/central/*`，如 `GET /api/v1/central/user-traffic`）认的是 `rpt_` 令牌（面板间配对令牌），不是订阅令牌（`sub_`），且返回的是被管面板汇总给主面板的管理数据。客户端用订阅令牌调它不通过；把 `rpt_` 令牌发给客户端等于把管理权限交给用户，**禁止这样做**。
- 全仓 grep `client-config` / `client_config` / `ClientConfig` 零命中（见 §3）；除订阅端点外，面板没有任何以订阅令牌为鉴权的读接口。

对 MVP 的直接后果：

1. 首页“已用 / 总量 / 到期日”三格只能从每次订阅请求的 `subscription-userinfo` 响应头解析（字段口径见 §2）。没有该头时显示“—”，不编数据。
2. 分组名、停用原因、重置日期、限流百分比等信息，订阅响应里都没有（分组只影响订阅里包含哪些落地，见 §6；停用只表现为节点连不上 + userinfo 里用量已满）。客户端不要假装能显示这些。
3. “用户自查”若以后要做，须面板新增接口（与 §3 的配置中心接口同属“待拍板 D10”清单），建议的最小形态：`GET /<订阅路径>/{token}/info`（或等价路径），用订阅令牌鉴权，只返回该令牌自己的用量、总量、到期、分组名。**现阶段不存在，不要在代码里预留调用。**

---

## 2. 订阅端点与 `subscription-userinfo` 头

### 2.1 订阅 URL 与令牌

```
GET https://<订阅对外域名或面板地址>/<订阅路径>/<订阅令牌>?format=<格式>&mode=<模式>
```

- **订阅路径**：路径段来自配置项 `SubPath`，默认 `sub`（`config.go` 的 `subPath()`：配置为空时返回 `"sub"`）。示例写 `/sub-path/`，真实路径以面板设置页为准，客户端绝不硬编码。
- **令牌位置与格式**：令牌在 URL 路径的最后一段，不在查询串、不在请求头。格式为 `sub_` + 64 位小写十六进制字符（32 字节随机数，`subscription.go` 的 `generateSubToken()`）。面板只存令牌的 SHA-256 哈希（鉴权用常数时间比较）与 AES-GCM 密文（重新拼链接用），明文只在生成时显示一次。
- **三种令牌共用同一端点**：通用订阅令牌、按人订阅令牌（`SubUser`）、合并订阅令牌（`MergedSub`），都是 `sub_` 开头、同一条路由、同一套校验。客户端不须区分是哪一种，按 URL 原样拉取即可。
- **令牌校验与状态码**（`handleSub` / `subtoken.go`）：
  - 令牌格式不对（不是 `sub_` + 64 位十六进制）→ 直接 404，不查库；
  - 令牌对但查无此令牌 → 404（故意不用 401，避免暴露端点存在）；
  - 令牌对但已过期 → **410**（不是 404，让客户端分得清“令牌错了”还是“订阅到期了”）；
  - 令牌对但格式参数非法 → 400（见 §2.2）；
  - 同一 IP 连续 10 次失败 → 锁 10 分钟，返回 **429**（响应头带 `Retry-After: 600`）。**正确的令牌永远放行，不受锁影响**，正常客户端不会被锁；
  - 成功 → 200，响应体为订阅内容，响应头带 `subscription-userinfo`（可能没有，见 §2.3）与 `Content-Disposition`（下载文件名，见 §5）。

### 2.2 订阅格式：`?format=` 参数与默认格式

参数名是 `format`，取值（不区分大小写，前后空格会被去掉）：

| `?format=` 取值 | 返回内容 | `Content-Type` |
|---|---|---|
| `clash` 或 `yaml` | Clash YAML（见 §6.2） | `text/yaml; charset=utf-8` |
| `singbox` 或 `sing-box` | sing-box JSON（见 §6.1） | `application/json; charset=utf-8` |
| `base64` | base64 编码的节点链接列表（每行一条 `vless://` / `vmess://` / `trojan://` / `ss://`，末尾带换行后整体 base64） | `text/plain; charset=utf-8` |
| `plain` | 明文节点链接列表（每行一条，同上，不编码） | `text/plain; charset=utf-8` |
| 不传 | 按 User-Agent 自动识别（见下） | 按识别结果 |
| 其他非法值 | 400，错误信息为 `format 只支持 clash/base64/plain/singbox` | — |

**默认格式（不传 `?format=` 时，`resolveSubFormat` 的 UA 嗅探逻辑，全部小写匹配）：**

1. UA 含 `sing-box` / `sfa` / `sfi` / `sfm` → sing-box JSON；
2. 否则 UA 含 `clash` / `stash` / `mihomo` → Clash YAML；
3. 否则 → **base64**（默认格式是 base64，不是 sing-box JSON，也不是 Clash YAML）。

**对客户端的硬性要求：每次拉订阅必须显式带 `?format=singbox`，绝不依赖 UA 嗅探。** 原因见 §4。

补充：

- `?mode=` 参数只影响 Clash YAML：`split`（分流，默认）或 `global`（全局，`MATCH` 走手动选择组）；非法值返回 400。**sing-box JSON 不认 `mode`，始终按分流出**（`route.final` 为 `direct`，见 §6.1）。
- 订阅内容实时生成：面板增删节点、改组、改限流后，下次拉取即生效，不用重新发链接。
- 订阅内容按令牌上的内容范围过滤：`both`（中转 + 直连）、`relay`（仅中转）、`direct`（仅直连），老记录空值按 `both` 处理。客户端解析时不要假设两种后缀一定同时出现。
- 节点名去重：重名节点在 sing-box JSON 与 Clash YAML 里会被改写为 `名字 (2)`、`名字 (3)`……客户端按 `tag` / `name` 精确匹配，不要按原名去重。
- **协议覆盖差异**：sing-box JSON 与 Clash YAML 只含 VLESS / Trojan / VMess / Shadowsocks 四种协议；**Hysteria2 与 TUIC 在这两种格式里会被跳过**（`singboxOutboundFromLink` 与 `clashProxyFromLink` 遇到不支持的协议返回失败、直接丢弃），只在 base64 / plain 订阅里保留。落地若有 HY2 / TUIC 节点，客户端用 `?format=singbox` 会看不到它们——须在界面或文档里写明，或等落地侧方案定夺，不要静默以为节点丢了是面板 bug。

### 2.3 `subscription-userinfo` 头：准确字段、格式与单位

响应头名：`subscription-userinfo`。格式为分号 + 空格分隔的 `key=value` 串，例如：

```
subscription-userinfo: upload=123456789; download=987654321; total=107374182400; expire=1798765432
```

| 字段 | 含义 | 单位 / 格式 | 一定有吗 |
|---|---|---|---|
| `upload` | 已用上行字节数 | **字节**（整数，无单位后缀） | 不一定（见下） |
| `download` | 已用下行字节数 | **字节**（整数，无单位后缀） | 不一定（见下） |
| `total` | 流量上限（总量） | **字节**（整数，无单位后缀） | 不一定（见下） |
| `expire` | 到期时间 | **Unix 秒级时间戳**（整数，如 `1798765432`），不是 RFC3339、不是毫秒 | 不一定（见下） |

**关键口径（两条代码路径，`subscription.go` 的 `subUserinfoHeader` 与 `user_traffic.go` 的 `subUserinfoHeaderForUser`）：**

1. **开了限流的订阅**（`TrafficLimitBytes > 0` 的按人订阅或合并订阅）走 `subUserinfoHeaderForUser`：
   - `upload` / `download` = **该订阅自己的已用量**（不是全面板汇总）：`limitMode == "monthly"` 时取本期用量（`upPeriod` / `downPeriod`），否则取累计用量（`upTotal` / `downTotal`）。数据源优先用集中管理聚合缓存（远程面板每 60 秒汇总上来的用量），没有缓存时用本机用量记录。
   - `total` = 该订阅的流量上限（`TrafficLimitBytes`）。
   - `expire` = 令牌到期与各落地到期日中**更早的那个**（`earliestExpiry`）。
   - 本机没有该订阅的用量记录时（例如管理面板模式），头里仍会拼 `total` 与 `expire`，只是不含 `upload` / `download`——**不编用量数据**。
2. **没开限流的订阅**走 `subUserinfoHeader`：
   - `upload` / `download` = 各落地流量统计的累计值之和（有数据的落地才计入；都没数据就不含这两项）。
   - `total` = 各落地流量上限（`TrafficLimitBytes`）之和（都没设限就不含）。
   - `expire` = 令牌到期（`tokenExpiry`，RFC3339）与各落地到期日中最早的，两者取更早的（都没设就不含）。
   - 管理面板模式（本机无落地）时，头里可以只有 `expire` 一项（只靠令牌到期）。
3. **三项全都没有时不返回这个头**（`serveSubContent` 里 `h == ""` 就不设头）。**没有头 ≠ 用量为 0**，客户端必须显示“—”，不许把缺失当成 0。
4. `expire` 的取值是“令牌到期与落地到期取更早”，不是只取令牌到期；落地到期比令牌到期早时，头里显示的是落地到期。客户端不要拿它反推令牌本身的到期日。
5. **直连流量不在 userinfo 里**：按人限流（1.3.25 A 方案）的用量只统计中转侧；直连节点链接不经过中转机，面板看不到直连流量。开了限流的订阅，userinfo 里的已用量 = 仅中转口径。直连要计量须等节点侧按人计量（agent）上线，客户端在界面上须写明“仅中转”，不要在直连节点上画已用流量。

---

## 3. 远程配置中心：`GET /client-config.json` 不存在

**结论：面板 1.3.29 没有 `GET /client-config.json`，也没有任何等价的公开只读配置接口。须面板新增接口（待拍板 D10）。**

核对过程：

- 路由表（`handlers.go`）无此路由；全仓 grep `client-config` / `client_config` / `ClientConfig`（`.go` / `.md` / `.js` / `.html`）**零命中**。
- 面板现成的 Cloudflare Worker 模板（`subscription.go` 的 `renderWorkerCode`）只反代订阅路径：`if (!url.pathname.startsWith("/<订阅路径>/")) return 404`，其他路径一律 404，不把面板其他接口暴露出去。也就是说，即使以后面板加了配置接口，现有 Worker 代码也不会自动放行 `/client-config.json`——Worker 须同步加一条路由。
- 唯一公开读配置的口子是 `GET /api/v1/public-info`，只返回登录页公告与签名（见 §1），字段、签名、版本、订阅地址一概没有，**不能冒充配置中心**。

**备用方案顺序（按客户端方案 §6，面板接口未落地前的执行顺序）：**

1. **主地址（待新增，须拍板 D10）**：面板新增公开只读接口，例如 `GET /client-config.json`，无须登录，返回签过名的配置 JSON；Worker 加一条 `/config/`（或同路径）路由反代到面板。配置与订阅同源，换域名只改一处；面板整机迁移备份（`migration_enc`）可把配置一起带走。面板挂了配置也拉不到，靠本地缓存兜底。
2. **备用地址之一（Worker 直出）**：在现有 Cloudflare Worker 里加一个路由，直接返回配置 JSON（内容存在 Worker KV 或写在 Worker 代码里）。不用改面板代码；Worker 本身抗封性比单台面板好。代价是 Worker 代码要多维护一份配置。
3. **备用地址之二（GitHub Raw / R2 静态文件）**：配置 JSON 放私有仓 Raw 或 R2 公开桶，客户端按地址列表逐个试。完全不依赖面板与 Worker；Raw 有约 45–90 秒缓存延迟，公开桶地址本身也可能被封。
4. **本地缓存兜底**：全部地址失败时用本地缓存的最后一份好配置 + 上次的订阅继续工作，首页提示“配置中心暂时连不上，正在用上次的配置”；全新安装且首次拉取就失败时，用包内内置默认值并给手动粘贴订阅的兜底入口。
5. **不做**：另起一套独立的配置中心服务（新域名、新服务器、新后台）——多一套维护、域名多一个被封面、与面板两套事实来源会打架。

执行注意：三层地址（面板域名、Worker 域名、GitHub Raw / R2 域名）须是三个不同域名，一个被封试下一个；配置 JSON 必须验签（Ed25519，公钥编译进客户端），验签失败直接丢弃、用本地缓存。

---

## 4. 客户端固定 UA 的建议

**面板有 UA 相关逻辑，且 UA 直接决定默认订阅格式（见 §2.2）。核实结果如下：**

- 面板只在订阅端点用 UA 做一件事：`resolveSubFormat` 的嗅探（`wantsClashByUA` / `wantsSingboxByUA`，`subscription.go`）。
  - Clash 系判定：UA（转小写后）含 `clash` / `stash` / `mihomo` 任一子串；
  - sing-box 系判定：UA（转小写后）含 `sing-box` / `sfa` / `sfi` / `sfm` 任一子串；
  - 注意是**子串匹配**，不是相等、不是前缀：UA 里任何位置出现这些子串都会命中。例如 UA 里出现 `sfa` 三个连续字母就会被判为 sing-box 系。
- **方案建议的固定 UA（如 `Zhexuexi/1.0`）核实结果**：`Zhexuexi/1.0` 转小写后是 `zhexuexi/1.0`，不含 `clash` / `stash` / `mihomo` / `sing-box` / `sfa` / `sfi` / `sfm` 任一子串，**会落到默认分支，拿到 base64 格式**。所以只换 UA、不带 `?format=` 参数，客户端拿到的是 base64，不是 sing-box JSON。
- **正确做法**：固定 UA 照常用（例如 `Zhexuexi/1.0`，UA 里不带机场特征词），但**每次拉订阅必须同时显式带 `?format=singbox`**。`?format=` 手动指定优先于 UA 嗅探（`resolveSubFormat` 先查参数，参数为空才看 UA），这样 UA 换什么都不会改格式。
- **UA 取值禁区**：UA 里不要出现 `clash` / `stash` / `mihomo` / `sing-box` / `sfa` / `sfi` / `sfm` 这些子串（包括版本号、设备型号、备注里无意带上的，例如某型号名含 `sfa`）。一旦命中，`?format=` 没带时格式会被带偏；带了 `?format=` 则无影响，但仍建议保持 UA 干净，避免将来某处逻辑改动后踩坑。
- Worker 转发 UA：Worker 模板原样转发请求 UA（`headers: { "User-Agent": request.headers.get("User-Agent") || "" }`），面板看到的 UA 就是客户端发的 UA，经 Worker 不会变。客户端经 Worker 拉订阅时，UA 规则与直连面板完全一致。
- 除订阅格式嗅探外，面板没有别的 UA 相关逻辑：没有按 UA 限流、没有按 UA 屏蔽、没有 UA 白名单。UA 只影响格式，不影响鉴权与用量统计。

---

## 5. 订阅路径可自定义、订阅对外域名的现状

### 5.1 订阅路径可自定义（代码确认）

- 配置项 `SubPath`（`config.go`），默认 `sub`（配置为空时 `subPath()` 返回 `"sub"`）。路由注册时用 `"GET /" + s.subPath() + "/{token}"`，即路径段是路由的一部分。
- 改路径：`POST /api/v1/settings/sub-path`（**会话认证**，管理员在面板设置页操作；客户端无权调）。请求体 `{"path": "<新路径段>"}`。
- 校验（`validSubPath`）：单段、1–32 个字符、字母开头、只含字母数字与 `-` `_`；`api` 与 `logo` 是保留段，不能用；`sub` 是默认值，允许改回。
- **改路径的后果（代码注释明确写清）**：改了要**重启面板才生效**；重启后旧订阅链接**全部失效**（旧路径不再有路由）；会话失效须重新登录；客户端须重新导入新链接。客户端在订阅更新失败（404）时，应先拉远程配置（新地址）再报“订阅地址已变，正在用新地址重试”，而不是直接报“订阅失效”。
- 客户端绝不硬编码订阅路径：订阅地址全量来自远程配置中心（见 §3），本地只存“上次成功的那份”做缓存。

### 5.2 订阅对外域名（代码确认）

- 配置项 `SubPublicDomain`（`config.go`），默认空。
- 拼链接规则（`subURL`）：填了对外域名时，面板里所有订阅链接（通用链接、每人链接、合并订阅、二维码）都改成 `https://<对外域名>/<订阅路径>/<令牌>`；没填时按当前请求的协议与 Host 拼（面板怎么打开，订阅就用什么地址；面板是明文 HTTP 时拼出来就是 `http://`，带面板端口）。
- 改域名：`POST /api/v1/settings/subscription-domain`（**会话认证**）。请求体 `{"domain": "<域名>"}`；空字符串 = 清除，恢复成面板自己的地址。
- 校验（`validPublicDomain`）：只允许域名（字母数字、点、横杠，标签不以横杠开头或结尾），可选 `:端口`；**不许带 scheme、路径、斜杠、查询串**。即只填 `example.com` 或 `example.com:8443` 这类，不填 `https://example.com/...`。
- 注意：对外域名只改面板**显示**的订阅链接，Worker 代码里的源站地址（ORIGIN）不受影响，仍是面板真实地址。换对外域名后，客户端须用新地址拉订阅；旧地址是否还能用，取决于旧域名解析与 Worker 配置是否还在，不由面板保证。

### 5.3 订阅下载文件名（附带，客户端导入命名用）

- 配置项 `SubFileName`（`config.go`），默认空。`Content-Disposition` 文件名 = 基本名 + 后缀：Clash 是 `.yaml`，sing-box 是 `.json`，base64 / plain 是 `.txt`。
- 基本名：填了 `SubFileName` 就用它，留空回落面板名。非 ASCII 文件名按 RFC 5987 编码（同时保留 ASCII 的 `filename=` 兜底，老客户端不认 `filename*` 时用通用名 `subscription.<后缀>`）。
- 改文件名：`POST /api/v1/settings/subscription-filename`（会话认证），1–64 字。客户端按文件名给导入的配置起名即可，不要解析文件名取令牌或路径。

---

## 6. 客户端自己生成 DNS 配置时须对照的事实

### 6.1 面板出的 sing-box JSON：逐字段清单

`renderSingboxJSON`（`subscription.go`）输出的完整配置结构如下（`log` / `dns` / `inbounds` / `outbounds` / `route` 五段）：

```json
{
  "log": { "level": "info" },
  "dns": { "...": "见 §6.1.1" },
  "inbounds": [
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080 }
  ],
  "outbounds": [ "节点出站...", { "type": "selector", "tag": "Proxy", "outbounds": ["<节点名...>"], "default": "<默认节点>" }, { "type": "urltest", "tag": "自动选择", "outbounds": ["<节点名...>"], "url": "http://www.gstatic.com/generate_204", "interval": "5m" }, { "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" } ],
  "route": { "rules": [ "...": "见下" ], "final": "direct" }
}
```

- **节点出站**（`singboxOutboundFromLink`）：VLESS 出站字段为 `type: "vless"`、`server`、`server_port`、`uuid`、`tag`（节点名）；Trojan 为 `type: "trojan"`、`server`、`server_port`、`password`；VMess 为 `type: "vmess"`、`server`、`server_port`、`uuid`、`alter_id: 0`、`security: "auto"`；Shadowsocks 为 `type: "shadowsocks"`、`server`、`server_port`、`method`、`password`。TLS 开启时加 `tls: {"enabled": true, "server_name": "<SNI>"}`（SNI 取链接的 `sni` 参数，空时取 `host` 参数）；传输为 WS 时加 `transport: {"type": "ws", "path": "<WS 路径>", "headers": {"Host": "<WS Host>"}}`（`path` / `headers` 为空时不写该字段）。HY2 / TUIC 不出（见 §2.2）。
- **selector `Proxy`**：成员为全部节点名；`default` 为第一个 `-直连` 后缀节点，没有直连节点时取第一个节点。
- **urltest `自动选择`**：成员为全部节点名；`url` 固定 `http://www.gstatic.com/generate_204`；`interval` 固定 `5m`。
- **route 规则**（按顺序，先命中先走）：TikTok 后缀组 → `Proxy`；社交后缀组 → `Proxy`；流媒体后缀组 → `Proxy`；测 IP 后缀组（15 个域名，见 §6.1.2）→ `Proxy`；`.cn` → `direct`；`final: "direct"`。`?mode=` 不影响 sing-box，始终是这套分流。
- **节点为空时**：只出合法的空配置（`dns` + `mixed` 入站 + `direct` / `block` 出站，`route` 里只有 `.cn → direct` 一条规则，不引用不存在的 `Proxy` 组），客户端能正常导入、节点数为 0。
- **入站**：只放 `mixed`（`127.0.0.1:2080`）。面板注释明确写：官方客户端自己会按需加 TUN，订阅里不强加 TUN，避免与客户端的 TUN 设置冲突。客户端不要指望订阅里带 TUN。

#### 6.1.1 DNS 段：legacy 格式，逐字段列出

面板 sing-box JSON 里的 `dns` 段原文（字段名与取值逐字照录）：

```json
"dns": {
  "servers": [
    { "tag": "dns-direct", "address": "https://doh.pub/dns-query", "detour": "direct" },
    { "tag": "dns-proxy", "address": "https://dns.google/dns-query", "detour": "proxy" }
  ],
  "rules": [
    { "domain_suffix": [".cn"], "server": "dns-direct" },
    { "domain_suffix": ["<TikTok 后缀组，共 8 个>"], "server": "dns-proxy" },
    { "domain_suffix": ["<测 IP 后缀组，共 15 个>"], "server": "dns-proxy" }
  ],
  "final": "dns-direct"
}
```

逐字段说明：

| 字段 | 取值 | 说明 |
|---|---|---|
| `dns.servers[0].tag` | `dns-direct` | 直连 DNS 服务器的 tag |
| `dns.servers[0].address` | `https://doh.pub/dns-query` | DoH 地址，**以字符串形式写在 `address` 字段里** |
| `dns.servers[0].detour` | `direct` | 该 DNS 查询走 `direct` 出站（直连解析） |
| `dns.servers[1].tag` | `dns-proxy` | 代理 DNS 服务器的 tag |
| `dns.servers[1].address` | `https://dns.google/dns-query` | DoH 地址，同样是 `address` 字符串形式 |
| `dns.servers[1].detour` | `proxy` | 该 DNS 查询走 `proxy`（即 selector `Proxy` 组，走代理） |
| `dns.rules[0]` | `domain_suffix: [".cn"]` → `server: "dns-direct"` | `.cn` 后缀走直连 DNS |
| `dns.rules[1]` | `domain_suffix: <TikTok 后缀组>` → `server: "dns-proxy"` | TikTok 相关域名走代理 DNS |
| `dns.rules[2]` | `domain_suffix: <测 IP 后缀组>` → `server: "dns-proxy"` | 测 IP 域名走代理 DNS |
| `dns.final` | `dns-direct` | 以上规则都不命中时走直连 DNS |

**格式判定：legacy（旧格式），sing-box 1.14 下会直接报错。**

- 判定依据：`dns.servers[]` 的每项用的是 **`address` 字段（字符串形式的 DoH 地址）**，没有 `type` / `server` / `server_port` / `path` 字段。sing-box 官方在 1.12.0 起废弃 legacy DNS 服务器格式（`dns.servers` 的 `address` 写法），**1.14.0 起彻底移除**，旧格式配置在启动时直接报 `decode config ... dns.servers[0]: legacy DNS server formats are deprecated ... removed in sing-box 1.14.0`，须按官方迁移文档改成新格式。
- 新格式（客户端自己生成 DNS 时须用的写法，字段名以 sing-box 1.14 官方文档为准）：每个 DNS 服务器须带 `type`，DoH 写成 `{"type": "https", "tag": "dns-direct", "server": "doh.pub", "server_port": 443, "path": "/dns-query", "detour": "direct"}` 这类分拆字段形式，不再用 `address` 字符串。
- **结论：客户端绝不能原样透传面板 sing-box JSON 里的 `dns` 段。** 客户端须按自己的 DNS 方案（DoH `https://dns.cloudflare.com/dns-query` 与 `https://dns.google/dns-query` 双路、DoT 兜底、只解析 IPv4、节点域名走代理解析、不回落明文 UDP 53）自己生成 DNS 配置；解析订阅时只取节点出站（`outbounds` 里除 `Proxy` / `自动选择` / `direct` / `block` 之外的节点项），`dns` / `route` / `inbounds` 一律不要照搬。
- 另注意：面板 DNS 段没有 `strategy`（IPv4/IPv6 策略）、没有 `independent_cache`、没有 `disable_cache` 等字段；客户端自己生成时按客户端方案补齐，不要以为面板段里缺失的字段是“面板故意留空让你填”——面板段是完整输出，只是格式老了。

#### 6.1.2 分流域名清单（计数已核对）

| 组 | 域名后缀（`domain_suffix`） | 数量 |
|---|---|---|
| TikTok（`tiktokSuffixes`） | `tiktok.com`、`tiktokv.com`、`tiktokcdn.com`、`tiktokcdn-us.com`、`musical.ly`、`byteoversea.com`、`ibytedtos.com`、`isnssdk.com` | 8 |
| 社交（`socialSuffixes`，仅 route 规则用，不进 DNS 规则） | `facebook.com`、`fb.com`、`fbcdn.net`、`instagram.com`、`cdninstagram.com`、`x.com`、`twitter.com`、`twimg.com`、`whatsapp.com`、`whatsapp.net`、`telegram.org`、`t.me`、`snapchat.com`、`scdn.co`、`reddit.com`、`redditmedia.com`、`redditstatic.com`、`pinterest.com`、`pinimg.com`、`linkedin.com`、`licdn.com`、`discord.com`、`discordapp.com`、`discord.gg`、`threads.net`、`line.me` | 26 |
| 流媒体（`streamSuffixes`，仅 route 规则用，不进 DNS 规则） | `youtube.com`、`googlevideo.com`、`ytimg.com`、`youtu.be`、`netflix.com`、`nflxvideo.net`、`nflxext.com`、`nflxso.net`、`disneyplus.com`、`dssott.com`、`hulu.com`、`huluim.com`、`max.com`、`hbomax.com`、`hbo.com`、`primevideo.com`、`amazonvideo.com`、`aiv-cdn.net`、`tv.apple.com`、`spotify.com`、`scdn.co`、`spotifycdn.com`、`twitch.tv`、`twitchcdn.net`、`jtvnw.net` | 25 |
| 测 IP（`ipCheckSuffixes`，route 与 DNS 规则都用） | `www.cloudflare.com`、`api.ip.sb`、`ipinfo.io`、`ipwho.is`、`get.geojs.io`、`api.country.is`、`api.ipquery.io`、`ident.me`、`ipapi.co`、`api.ipapi.is`、`ip.api.skk.moe`、`api.internetdata.io`、`ifconfig.co`、`api.myip.com`、`ip-api.com` | 15 |

客户端内置规则须与这份清单对齐（DNS 规则只含 `.cn`、TikTok、测 IP 三组；社交与流媒体只在 route 规则里，不进 DNS 规则）。

### 6.2 Clash YAML 的 dns 段（对照用，客户端解析时只取节点）

`renderClashHeader` 输出的 Clash `dns` 段（有节点时才出；节点为空的空配置不写 dns 段）：

```yaml
dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: true
  default-nameserver:
    - 223.5.5.5
    - 114.114.114.114
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  proxy-server-nameserver:
    - https://doh.pub/dns-query
  fallback:
    - https://dns.google/dns-query
    - https://1.1.1.1/dns-query
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4
      - 0.0.0.0/32
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.localhost"
    - "time.windows.com"
    - "time.apple.com"
    - "time.asia.apple.com"
    - "ntp.*.com"
    - "<订阅里实际节点域名，去重排序后逐个加 *.域名 与 域名两条>"
ipv6: false
mode: rule
sniffer:
  enable: true
  sniff:
    TLS:
      ports: [443, 8443]
    HTTP:
      ports: [80, 8080]
  skip-domain:
    - "<订阅里实际节点域名，逐个加 *.域名>"
```

- Clash 策略组固定 7 个（按顺序）：`自动选择`（url-test，`url: http://www.gstatic.com/generate_204`，`interval: 300`）、`GLOBAL`（select）、`手动选择`（select）、`中转节点`（select，仅有中转节点时出）、`直连节点`（select，仅有直连节点时出）、`社交`（select）、`流媒体`（select）。规则顺序：TikTok → `自动选择`（另有一条 `DOMAIN-KEYWORD,tiktok`）、社交 → `自动选择`、流媒体 → `自动选择`、测 IP → `自动选择`、`MATCH`（split 时 `DIRECT`，global 时 `手动选择`）。
- **客户端解析 Clash YAML 时的取舍**：只取 `proxies` 数组里的节点（每条都带 `udp: true`），不要取 `proxy-groups` 与 `rules`（规则由客户端按 §6.1.2 的清单自己生成）；`dns` 段不要透传给 sing-box 核心（那是 Clash/mihomo 的 fake-ip 体系，与 sing-box DNS 不通用）。
- **面板分组不在订阅内容里**：分组（1.3.26）只决定订阅包含哪些落地（`effectiveSelectionForSubUser`：进了组的用组的落地集合，否则用自己的勾选），**组名不出现在订阅正文里**。Clash 的“中转节点 / 直连节点”组与 sing-box 的 `Proxy` / `自动选择`组是按节点名后缀（`-中转` / `-直连`）分的，不是按面板分组分的。客户端要按面板分组展示，只能按节点名后缀分中转/直连两组，或等“用户自查”接口（见 §1）落地后才有真分组名。通用订阅不进分组。

---

## 7. 客户端接面板的最小实现清单（按本文结论）

1. 拉订阅：`GET https://<配置中心给的订阅地址>?format=singbox`，固定带自己的 UA（如 `Zhexuexi/1.0`），超时 15 秒、重试 2 次；解析失败时回退 `?format=base64`，再失败回退 `?format=clash`。
2. 解析订阅只取节点模型（协议、地址、端口、UUID/密码、传输、TLS、SNI、WS 路径、名称、分组、来源）；`dns` / `route` / `proxy-groups` / `rules` 一律不透传，DNS 与路由由客户端自己生成。
3. 每次订阅更新后解析 `subscription-userinfo` 头：`upload` / `download` / `total` 按字节算剩余（`total - upload - download`），`expire` 按 Unix 秒转日期；缺字段显示“—”，不编数据；注意口径是“仅中转”。
4. 状态码处理：404 → “订阅已失效，请重新绑定”；410 → “订阅已到期”；429 → 退避重试（带 `Retry-After: 600`，不要立即狂刷）；400 → “订阅请求参数不对”（须报给开发侧，不是用户问题）。
5. 远程配置：主地址 `GET /client-config.json` 目前不存在，MVP 先走 Worker 直出 / GitHub Raw / R2（见 §3），并把“面板新增接口”列进待拍板 D10；配置 JSON 验签失败一律丢弃、用本地缓存。
6. 版本门：客户端 `min_panel_version = 1.3.29`；面板低于此版本时启动检查提示升级，不静默降级（面板版本号本身不在订阅里，须由配置中心或面板设置页确认，见未核实项）。

---

## 8. 未核实项（代码里看不出来的、须真机 / 真面板实测）

1. **sing-box JSON 在 sing-box 1.14 真机上是否确实导入失败**：代码层面已确认是 legacy `address` 格式、官方文档确认 1.14 已移除，但面板实际下发的 JSON 在目标客户端（Flutter 插件内置的 sing-box 1.14.x）上是报 `decode config dns.servers[0]` 错、还是被插件的转换层悄悄修掉了，须真机实测。另须实测新格式 DNS（`type`/`server`/`server_port`/`path`）在同一插件上的写法是否一次通过。
2. **订阅经 Worker 后的响应头是否完整保留**：Worker 模板写的是原样返回状态码、响应头与响应体，但 Cloudflare 是否会改写 / 剥离 `subscription-userinfo` 与 `Content-Disposition`，须真机经 Worker 拉一次订阅、抓头核对。
3. **小火箭 / FlClash / Hiddify 对 userinfo 头的实际显示**：面板代码只保证头按规范拼，三个客户端在“仅 `expire` 一项”“仅 `total` + `expire` 两项”“四项全有”三种情况下分别显示什么（是否显示到期、是否显示剩余），须真机逐个核对。
4. **限流订阅的 userinfo 在集中管理（多面板）下的实际值**：代码走聚合缓存（远程面板每 60 秒汇总），但远程面板离线、汇总延迟、空壳全 0 记录等边界下头里实际是什么，须真面板联调。
5. **`?format=singbox` 下 HY2 / TUIC 节点丢失的用户体验**：代码确认这两种协议在 sing-box JSON 与 Clash YAML 里被跳过，但落地实际有 HY2 / TUIC 节点时，客户端节点列表少了节点、用户是否会误以为节点被删，须真机 + 真落地核对，并定夺是否在界面提示。
6. **订阅 410 / 429 在各客户端的实际表现**：代码返回 410（过期）与 429（`Retry-After: 600`），但客户端是把 410 当“订阅失效”还是当“网络错误”、429 后是否自动退避，须真机核对；自家客户端须按 §7 第 4 条实现，不要照抄第三方客户端的行为。
7. **订阅路径改动后的客户端恢复流程**：代码确认改路径要重启面板、旧链接全部 404，但客户端“先拉远程配置、再用新地址重试”的流程在真机上是否跑得通（配置中心本身若也走旧域名会不会一起断），须按换域名操作清单实测一次。
8. **面板版本号的客户端侧获取方式**：订阅响应里不带面板版本号；`GET /api/v1/public-info` 也不带。客户端启动检查 `min_panel_version = 1.3.29` 时，版本号从哪里来（配置中心字段、还是面板设置页人工确认），须定夺，未在代码里找到现成接口。
9. **Clash YAML 空配置（无节点）与 sing-box 空配置在自家客户端解析器上的表现**：代码保证两者都是合法空配置（节点数为 0），但自家解析器是否把“空”正确处理为“节点数为 0”而不是“解析失败”，须回归测试覆盖。
10. **流量统计口径差**：userinfo 的 `upload` / `download` 是面板流量统计的累计字节；与客户端本机统计（Clash API 查核心流量）对不上时以面板为准，但两者差几个百分点是否在预期内（采样、L3/L7 口径差），须真机拉一段流量后两边对数。
