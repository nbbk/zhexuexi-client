# 远程配置中心签名工具

给远程配置 JSON 签名、验签的工具（只依赖 Python 标准库 + openssl 命令行）。
签名规则见 `docs/api/remote-config.md`：除 `signature` 字段外的全部内容做
规范 JSON（key 排序、无空格）后 Ed25519 签名；客户端先验签，验签失败的
配置一律不用。

## 密钥

```sh
# 生成一对新密钥（私钥只存你指定的路径，绝不进仓库）：
python3 sign.py generate-key --private /tmp/remote-config-private.pem
# 输出 base64 公钥：把它编译进客户端 lib/brand/remote_config_keys.dart。
# 换公钥才须重新打包（公钥几乎不换）。

# 看一把私钥对应的公钥（换公钥时用）：
python3 sign.py pubkey --key /tmp/remote-config-private.pem
```

密钥保管（DEV-PLAN D14）：私钥由助手出、助手保管，各备两份离线备份，
密码分开保管；绝不进仓库、不进面板、不进 Worker 代码。
`.gitignore` 已把 `*.pem` / `*.key` / `ed25519-private.pem` /
`remote-config-private.key` 排除在外，误放也会被拦住。

## 签一份配置

```sh
# payload.json 是不含 signature 的配置内容（字段见 docs/api/remote-config.md）。
python3 sign.py sign --key /tmp/remote-config-private.pem \
    --config payload.json --out client-config.json

# --bump：沿用上一份信封的 config_version + 1（改配置必升版本，
# 客户端只接受比本地缓存新的版本，不回退）：
python3 sign.py sign --key /tmp/remote-config-private.pem \
    --config payload.json --out client-config.json --bump prev.json

# 验一份信封（公钥是编译进客户端的那把 base64）：
python3 sign.py verify --public <BASE64公钥> --envelope client-config.json
```

## 发布到三个地址（发完客户端下次拉取即生效，不用重装）

1. **面板（主地址，待面板新增接口 D10）**：面板加公开只读接口
   `GET /client-config.json` 后，把签好的信封由面板返回；
   Worker 加一条 `/client-config.json` 路由反代到面板。
2. **Worker 直出**：在现有 Cloudflare Worker 里加一个路由，直接返回
   信封 JSON（内容存在 Worker KV 或写在 Worker 代码里）。
3. **GitHub Raw / R2**：把签好的 `client-config.json` 推到客户端仓
   根目录（或 R2 公开桶）。Raw 有约 45–90 秒缓存延迟。

三个地址须是三个不同域名，一个被封试下一个。配置里只有公开信息
（品牌、订阅地址模板、面板域名），绝不放订阅令牌。

## 换域名操作清单

1. 新域名解析到面板 / Worker；
2. 面板设置里改订阅对外域名；
3. 改配置中心的 `panel_domain` / `subscription_url`，`config_version` +1，
   重新签名（`--bump` 上一份信封），按上面三条路发布；
4. 用一台已装客户端的手机验证：杀掉重开，订阅自动更新到新地址，
   旧令牌能用；
5. 发公告。整个过程用户不用重装、不用重新绑定。
