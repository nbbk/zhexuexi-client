# sing-box REALITY 补丁（Windows 版 sing-box.exe 构建输入）

> 来源：Tunl 的两份补丁，原样复用（见 `~/workspace/libbox-patch/PATCH_DESIGN.md`）。
> Android 的 libbox（`tools/build-patched-libbox.sh`）打的是同一份补丁，
> Windows 的 sing-box.exe 必须打同一份，否则 Windows 上 REALITY 握不过
> Xray v26.11.9（0.1.20：未打补丁的上游 1.14.4 在 Windows 上三个 REALITY
> 节点测速全报“握手失败”，同 NekoBox 1.4.2 的失败模式）。

## 文件

| 文件 | 内容 | SHA-256 |
|---|---|---|
| `reality-xray.patch` | 改 sing-box 本体：份额保留＋会话 ID 版本 26.3.27＋auth key 回退＋randomized hello 改 HelloRandomizedALPN | `031896207171c6e8c1892f3ad666177f6361c7265318ba9cd40498225c398c42` |
| `utls-presets.patch` | 改 metacubex/utls v1.8.7：加 Firefox 148 / Safari 26.3 hello 预设 | `b346c5f4d76afe61ba26629b53a8b69cd4e318f5f4117b33feb525e6898b0e4a` |

## 同步规则（重要）

- 这两份文件必须与 `~/workspace/libbox-patch/patches/` 里的同名文件
  **逐字节一致**（Android libbox 是同一份补丁的源头）。
  改了一边必须同步另一边；升 sing-box 大版本后两边一起重跑 `--check`，
  贴不上就按 Tunl 的 Bump 流程 rebase。
- 升版检查：`git apply --check`（或 `patch --dry-run -p1`）在对应源码上跑，
  不通过就不要硬推。

## CI 里的用法（见 `.github/workflows/build.yml` 的 Windows job）

1. 下 sing-box 1.14.4 源码（tag tarball），`git apply` 打 `reality-xray.patch`；
2. 下 metacubex/utls v1.8.7 源码，`git apply` 打 `utls-presets.patch`；
3. `go mod edit -replace github.com/metacubex/utls=../utls-1.8.7`；
4. Go 1.26.10（sing-box 1.14.4 的 tag 构建用的版本，不用 go.mod 的最低版
   1.25.5），`CGO_ENABLED=0`，tags
   `with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api`
   （与 libbox 构建一致），交叉编译 windows/amd64 与 windows/arm64，
   版本戳 `1.14.4-patched`（`-X constant.Version=...`，与 libbox 同款）；
5. 产物放进 `packages/flutter_sing_box/assets/windows/<arch>/sing-box.exe`；
   构建后核对 `sing-box.exe version`（版本戳＋with_utls）与
   `go version -m`（utls replace 生效）。

## 为什么是源码编译、不是下载官方 Release

- sing-box.exe 太大（amd64 79MB），Git Data API 拒收（422），不进仓；
- 官方 Release 是未打补丁的，握不过 Xray v26.11.9 的 REALITY。
  源码编译一次解决两个问题：不要下载、且自带补丁。
