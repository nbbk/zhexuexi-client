/// 编译进客户端的远程配置中心 Ed25519 公钥（base64，32 字节）。
///
/// 密钥对 2026-11-23 生成（openssl genpkey -algorithm ed25519）。
/// 2026-11-23 03:05 轮换：上一把私钥只放在 /tmp，被清空丢了，
/// 全盘搜不到；新私钥存 ~/workspace/user/remote-config-private-key.pem
///（持久目录，600 权限），绝不要再放 /tmp。
/// 私钥只在离线处保管，绝不进仓库、不进面板、不进 Worker 代码；
/// 换公钥才须重新打包（公钥几乎不换，见 docs/api/remote-config.md）。
/// 私钥的保管位置与备份办法见 tools/remote-config/README.md。
const String remoteConfigPublicKeyBase64 =
    'RR7Xm49vs+h18Ny8QLQZLjGkoqZHAoGr+oxbYQ087tE=';
