#!/usr/bin/env bash
# 打补丁的 libbox（sing-box 1.14.4 + REALITY X25519MLKEM768 补丁）构建脚本。
#
# 用途：给哲学系客户端编一个带 REALITY 补丁的 libbox Android AAR，
#      替换 flutter_sing_box 插件里原来从 JitPack 拉的
#      com.github.singbox-android:libbox:1.14.4。
#
# 源码来源：
#   - sing-box v1.14.4：GitHub release tarball 解压到
#     ~/workspace/libbox-patch/sing-box-1.14.4/（不是 git 仓）。
#   - metacubex/utls v1.8.7：GitHub tag tarball 解压到
#     ~/workspace/libbox-patch/work/utls/（补丁副本，勿改 module cache）。
# 补丁文件（Tunl 原样，见 ~/workspace/libbox-patch/PATCH_DESIGN.md）：
#   - ~/workspace/libbox-patch/patches/reality-xray.patch
#     （改 sing-box 本体：份额保留＋会话 ID 版本 26.3.27＋auth key 回退
#      ＋randomized hello 改 HelloRandomizedALPN）
#   - ~/workspace/libbox-patch/patches/utls-presets.patch
#     （改 utls v1.8.7：加 Firefox 148 / Safari 26.3 hello 预设）
#   补丁在 1.14.4 / utls v1.8.7 上实测可应用；升 sing-box 大版本后
#   要重跑 --check，贴不上就按 Tunl 的 Bump 流程 rebase。
# 工具链版本：
#   - Go 1.26.10（~/workspace/toolchains/go-1.26.10/bin/go；不是 go.mod
#     最低版 1.25.5，取自该 tag 的 .github/workflows/build.yml）。
#   - gomobile / gobind v0.1.13（sing-box Makefile lib_install 那两行）。
#   - Android SDK ~/workspace/toolchains/android-sdk，
#     NDK 28.2.13676358（r28c）；JDK 17。
# 产物：
#   - ~/workspace/libbox-patch/work/libbox.aar（主变体，API 24，全部 tag，
#     含 with_utls；只编 arm64——客户端只发 arm64 APK）
#   - ~/workspace/libbox-patch/work/libbox-legacy.aar（API 21、无 naive，
#     构建副产物，不接进插件）
#   - 插件接线位置：本地 Maven 仓
#     apps/flutter_client/packages/flutter_sing_box/android/libs/maven-repo/
#     io/nekohasekai/libbox/1.14.4-patched/（aar＋pom＋metadata，
#     坐标 io.nekohasekai:libbox:1.14.4-patched；不提交进任何 git 仓，
#     kit 本身不是 git 仓）
#     为什么不用 implementation(files("libs/libbox.aar"))：AGP 禁止
#     library 模块直接依赖本地 .aar（bundleReleaseAar 的
#     hasLocalAarDeps 检查，0.1.3 首版构建即因此失败）——本地 .aar
#     的类与资源不会被打进产出的 AAR；走 Maven 坐标按模块解析，正常打包。
#   - libbox-legacy.aar 不接进插件。
# 复现：只跑本脚本即可（补丁已打过时自动跳过，幂等）。
# 注意：/tmp 只有 512M，Go 构建临时目录与缓存一律走 workspace
#       （GOTMPDIR / GOCACHE），否则编到一半报 no space left on device。
set -euo pipefail

PATCH_ROOT="$HOME/workspace/libbox-patch"
SINGBOX_DIR="$PATCH_ROOT/sing-box-1.14.4"
UTLS_DIR="$PATCH_ROOT/work/utls"
WORK_DIR="$PATCH_ROOT/work"
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_LIBS="$KIT_ROOT/apps/flutter_client/packages/flutter_sing_box/android/libs"
MAVEN_REPO_DIR="$PLUGIN_LIBS/maven-repo/io/nekohasekai/libbox/1.14.4-patched"

GO="$HOME/workspace/toolchains/go-1.26.10/bin/go"
GOMOBILE_VERSION="v0.1.13"

export ANDROID_HOME="$HOME/workspace/toolchains/android-sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
export JAVA_HOME="$HOME/workspace/toolchains/jdk17"
export GOTMPDIR="$HOME/workspace/.tmp/go-build"
export GOCACHE="$HOME/workspace/.cache/go-build"
# gomobile bind 最后一步要调 javac（$JAVA_HOME/bin 必须在 PATH 里，
# 否则编完 .so 才报 "javac: executable file not found in $PATH"），
# 它的临时工作目录走 $TMPDIR（默认 /tmp 只有 512M）。
export TMPDIR="$HOME/workspace/.tmp/go-build"
export GOTOOLCHAIN=local
export GOPROXY=https://goproxy.cn,direct
export GOSUMDB=off
export PATH="$HOME/workspace/toolchains/go-1.26.10/bin:$HOME/go/bin:$JAVA_HOME/bin:$PATH"

mkdir -p "$GOTMPDIR" "$GOCACHE" "$PLUGIN_LIBS"

# 已打过就跳过；正反都贴不上就报错停下（不要硬改）。
apply_patch_once() {
  local dir="$1" patch="$2"
  (
    cd "$dir"
    # 注意：patch 的位置参数是待打文件，补丁必须从 stdin 读（< "$patch"），
    # 写成 patch ... "$patch" 会把补丁文件当成待打文件、挂起等 stdin。
    if patch --dry-run -p1 -R < "$patch" >/dev/null 2>&1; then
      echo "already applied, skip: $patch"
    elif patch --dry-run -p1 < "$patch" >/dev/null 2>&1; then
      patch -p1 < "$patch"
    else
      echo "ERROR: patch does not apply (check offsets by hand): $patch" >&2
      exit 1
    fi
  )
}

echo "== 1. sing-box 本体补丁 =="
apply_patch_once "$SINGBOX_DIR" "$PATCH_ROOT/patches/reality-xray.patch"

echo "== 2. utls 副本补丁 =="
apply_patch_once "$UTLS_DIR" "$PATCH_ROOT/patches/utls-presets.patch"

echo "== 3. go.mod replace 指到打好补丁的 utls 副本 =="
if ! grep -q "github.com/metacubex/utls => ../work/utls" "$SINGBOX_DIR/go.mod"; then
  (cd "$SINGBOX_DIR" && "$GO" mod edit -replace github.com/metacubex/utls=../work/utls)
fi
grep "^replace" "$SINGBOX_DIR/go.mod"

echo "== 4. gomobile / gobind $GOMOBILE_VERSION =="
if [ ! -x "$HOME/go/bin/gomobile" ] || [ ! -x "$HOME/go/bin/gobind" ]; then
  "$GO" install "github.com/sagernet/gomobile/cmd/gomobile@$GOMOBILE_VERSION"
  "$GO" install "github.com/sagernet/gomobile/cmd/gobind@$GOMOBILE_VERSION"
fi
# gomobile bind 时要从 PATH 上找到 gobind（$HOME/go/bin 必须在 PATH 里，
# 否则报 "gobind was not found. Please run gomobile init"）。
# 注意不要调 `gomobile version`：它在模块外跑会报 no required module，
# 看着像失败，其实只是它自检的用法问题。
command -v gomobile gobind

echo "== 5. 给源码树打版本 tag（0.1.4 A 路 P0-1：ReadTag 读不到 tag 就钉 unknown） =="
# build_libbox 靠 `git describe --tags` 读版本（ReadTag：tag 正好在
# HEAD 上就返回去 v 前缀的 tag 名，读不到就 currentTag = "unknown"，
# 再经 LinkerFlags 钉进 constant.Version）；源码树是 release
# tarball 解压的、根本不是 git 仓，所以 0.1.3 编出的
# Libbox.version() 恒为 "unknown"，诊断包分不清补丁版与官方版。
# 做法：在源码树里就地建一个只用于读 tag 的本地 git 仓，打上
# v1.14.4-patched 再编。幂等：tag 已存在就跳过（补丁已打过也跳过，
# 两者互不干扰）；只打本地 tag，不推任何远端（本脚本从不推仓）；
# 构建产物（libbox*.aar）不进提交。
VERSION_STAMP="1.14.4-patched"
(
  cd "$SINGBOX_DIR"
  if git rev-parse --verify -q "refs/tags/v$VERSION_STAMP" >/dev/null 2>&1; then
    echo "version tag v$VERSION_STAMP already present, skip"
  else
    if [ ! -d .git ]; then git init -q; fi
    # 注意：不要写 `git add -A -- ':!libbox.aar'`——树自带的
    # .gitignore 已有 `/*.aar`，带 `:!` 排除的 pathspec 会把被
    # 忽略文件当显式指定而报错退出（exit 1）；直接 `git add -A`
    # 就会按 .gitignore 跳过两个 .aar。
    git add -A
    git -c user.email=libbox-builder@local -c user.name=libbox-builder \
      commit -qm "sing-box $VERSION_STAMP (local build tree)" || true
    git tag "v$VERSION_STAMP"
    echo "tagged v$VERSION_STAMP"
  fi
)

echo "== 5b. 编 patched sing-box 二进制（Linux，用于 sing-box check 验证） =="
(cd "$SINGBOX_DIR" && "$GO" build -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=$VERSION_STAMP" \
  -tags "with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api" \
  -o "$WORK_DIR/sing-box-patched" ./cmd/sing-box)
"$GO" version -m "$WORK_DIR/sing-box-patched" | grep "metacubex/utls"

echo "== 6. 编 libbox AAR（android/arm64，官方 build_libbox） =="
(cd "$SINGBOX_DIR" && "$GO" run ./cmd/internal/build_libbox \
  -target android -platform android/arm64)

echo "== 7. 产物归档（发布进插件内的本地 Maven 仓） =="
cp "$SINGBOX_DIR/libbox.aar" "$WORK_DIR/libbox.aar"
cp "$SINGBOX_DIR/libbox-legacy.aar" "$WORK_DIR/libbox-legacy.aar"
# 为什么不用 implementation(files("libs/libbox.aar"))：
# AGP 禁止 library 模块直接依赖本地 .aar（bundleReleaseAar 的
# hasLocalAarDeps 检查，0.1.3 首版构建即因此失败）——本地 .aar 的
# 类与资源不会被打进产出的 AAR。改走本地 Maven 仓坐标
# io.nekohasekai:libbox:1.14.4-patched，Gradle 按模块解析，正常打包。
mkdir -p "$MAVEN_REPO_DIR"
cp "$WORK_DIR/libbox.aar" "$MAVEN_REPO_DIR/libbox-1.14.4-patched.aar"
cat > "$MAVEN_REPO_DIR/libbox-1.14.4-patched.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.nekohasekai</groupId>
  <artifactId>libbox</artifactId>
  <version>1.14.4-patched</version>
  <packaging>aar</packaging>
  <name>libbox (patched)</name>
  <description>sing-box 1.14.4 libbox with REALITY X25519MLKEM768 patch. Built by tools/build-patched-libbox.sh; do not edit by hand.</description>
</project>
POM
cat > "$MAVEN_REPO_DIR/maven-metadata-local.xml" <<METADATA
<?xml version="1.0" encoding="UTF-8"?>
<metadata>
  <groupId>io.nekohasekai</groupId>
  <artifactId>libbox</artifactId>
  <versioning>
    <latest>1.14.4-patched</latest>
    <release>1.14.4-patched</release>
    <versions>
      <version>1.14.4-patched</version>
    </versions>
    <lastUpdated>$(date +%Y%m%d%H%M%S)</lastUpdated>
  </versioning>
</metadata>
METADATA
# 旧接线残留：libs/libbox.aar 已不再被引用，删掉防混淆。
rm -f "$PLUGIN_LIBS/libbox.aar"
sha256sum "$WORK_DIR/libbox.aar" "$MAVEN_REPO_DIR/libbox-1.14.4-patched.aar"
echo "libbox-1.14.4-patched.aar -> $MAVEN_REPO_DIR"
