# x86_64 debug APK 构建记录（2026-11-26，构建员）

目的：给哲学系客户端编一个能在 x86_64 安卓模拟器上跑的 debug APK（验证通路）。
客户端代码零改动，只加目标架构。

## 1. 补丁版 libbox android/amd64

- 构建命令（照 `tools/build-patched-libbox.sh` 的路子，只改目标）：
  `go run ./cmd/internal/build_libbox -target android -platform android/amd64`
  （源码树 `~/workspace/libbox-patch/sing-box-1.14.4/`，补丁与 `v1.14.4-patched` tag
  已是打好状态，未重打；环境变量与原脚本一致：Go 1.26.10、NDK 28.2.13676358、
  JDK 17、GOTMPDIR/GOCACHE/TMPDIR 走 workspace）
- 构建脚本：`~/.tmp/go-build/build-amd64.sh`，日志：
  `~/workspace/libbox-patch/work/build-libbox-amd64.log`
- 耗时：成功那次 16:51:58 → 17:13:54，约 22 分钟（主变体 API 24＋legacy 变体 API 21）
- 产物：
  - `~/workspace/libbox-patch/work/libbox-amd64.aar`（30,397,395 字节）
    SHA-256：`d18d27991e65e7214941202423cd9fe008f428d877a268caefbad389ace6b18c`
  - `~/workspace/libbox-patch/work/libbox-legacy-amd64.aar`（25,309,757 字节）
    SHA-256：`2e9c35210d3f5971bd28afd49515f40796967866a2e1dc0b3eed9c01b58fd3cc`
  - 内含 `jni/x86_64/libbox.so`：ELF 64-bit x86-64，85,662,144 字节，
    SHA-256 `6df0606c9552c7509725f8ff3cd412f9dacc1068b7ac1555fbd148774523c86a`，
    含版本戳字符串 `1.14.4-patched`
- 合并：arm64 AAR 未被覆盖——原 arm64 AAR 备份在
  `~/workspace/libbox-patch/work/libbox-arm64.aar`
  （SHA-256 `d688e52490a7117670f7843bd385dbb5084a89e1a6a7e6639ad3d55ccbece96b`，
  与 Maven 仓旧文件一致）。双架构 fat AAR：
  `~/workspace/libbox-patch/work/libbox-fat.aar`
  SHA-256：`5fed532471ca14a490f8430780bc66d95e685f34197ed7ce32df5cd017894107`
  （内含 arm64-v8a/libbox.so 与 x86_64/libbox.so，逐字节与各自原版一致）
- 发布：fat AAR 已写入本地 Maven 仓，坐标不变
  `io.nekohasekai:libbox:1.14.4-patched`
  （`packages/flutter_sing_box/android/libs/maven-repo/.../libbox-1.14.4-patched.aar`，
  SHA-256 同上；`maven-metadata-local.xml` 的 lastUpdated 已刷新）
- 构建插曲：
  - 第 1 次（16:47:58 起）被虚拟机重启打断（约 16:48，systemd/PID 1 重起；
    0.1.8 的 Gradle 守护进程 PID 8958 也随之消失，非我所杀）。
  - 第 2 次（16:49:36 起）49 秒即失败：`gomobile: open .../build/amd64/libbox/
    go_libboxmain.go: file exists`——第 1 次被杀时残留了 `build/amd64/` 中间目录；
    删掉 `sing-box-1.14.4/build/amd64/`（及空的 `build/arm64/`）后重跑通过。

## 2. Flutter x86_64 debug APK

- 构建命令：`flutter build apk --debug --target-platform android-x64`
  （构建脚本 `~/.tmp-flutter/build-x86_64-debug.sh`，日志
  `apps/flutter_client/build-x86_64-debug.log`；环境变量与正式版一致：
  GRADLE_USER_HOME=`~/workspace/.gradle-fresh`、JAVA_HOME=JDK 17、
  TMPDIR=`~/workspace/.tmp-flutter`、GRADLE_OPTS/JAVA_OPTS 均为
  `-Djava.net.preferIPv4Stack=true`）
- 耗时：17:14:45 → 17:41:57，约 27 分钟（Gradle `assembleDebug` 1624.5 秒；
  比正式 release 构建慢，主因是 Kotlin 编译 daemon 反复连不上、每分钟起死一次，
  见下）
- 产物（注意文件名）：
  - `flutter build apk --debug` 不带 `--split-per-abi` 时产物叫 `app-debug.apk`，
    不是 `app-x86_64-debug.apk`（后者只在 `--split-per-abi` 时出现）：
    `~/workspace/zhexuexi-client-kit/apps/flutter_client/build/app/outputs/flutter-apk/app-debug.apk`
    275,629,373 字节，
    SHA-256：`ae6ed5aeda59af6e7e63fa5f6959a052ed4e4185a9114a914704823e9918f81f`
  - 同值命名副本（防下次 debug 构建覆盖）：
    `.../flutter-apk/app-x86_64-debug.apk`（同一 SHA-256）
- 版本：aapt2 显示 `versionName='0.1.8'`、`versionCode='9'`、包名
  `com.zhexuexi.client`（当前 kit 树就是 0.1.8 进行中状态，未改版本）

## 3. aapt2 验证

- `aapt2 dump badging`：`package: name='com.zhexuexi.client' versionCode='9'
  versionName='0.1.8'`，`sdkVersion:'26'`，`targetSdkVersion:'36'`
- APK 内 `lib/x86_64/libbox.so` 存在：ELF 64-bit x86-64，85,662,136 字节，
  含 `1.14.4-patched` 字符串；`lib/x86_64/libflutter.so` 也存在（38,893,888 字节）
- 与构建产物 .so 的 8 字节差：APK 里的 .so 比 AAR 里的少 8 字节
  （85,662,136 vs 85,662,144；arm64 那份同样少 8 字节），`cmp` 显示差异只在
  ELF 头的 `e_shoff` 字段与文件尾的 `.shstrtab`（AGP 打包时 strip 段元数据），
  代码段无差异——是同一份补丁构建，非不同版本
- 注意：APK 是 fat 包——除 x86_64 外还含 `lib/arm64-v8a/`（含 arm64 libbox.so，
  与原版逐字节一致）与 `lib/armeabi-v7a/`（无 libbox）。`--target-platform
  android-x64` 只限定了 Flutter 引擎（`libflutter.so` 只有 x86_64 一份），
  不限制 Gradle 打包 AAR 里的 jniLibs。模拟器（x86_64）安装时会取 x86_64 目录，
  能跑；多余的 arm64 库只是占体积（debug 包 275MB）。如需纯 x86_64 包，
  须另加 abiFilters（本次按任务只加目标架构，未动）

## 4. flutter analyze

- `flutter analyze`：`No issues found! (ran in 15.5s)`——零问题
  （日志 `apps/flutter_client/analyze-x86_64.log`）

## 5. 内存等待

- Flutter 构建开始前 available 3.4GB（≥2.5GB 阈值），**等待 0 分钟**：
  16:48 虚拟机重启后 0.1.8 的 Gradle 守护进程（3.3GB）已不在，内存自然空出。
  未杀任何进程、未动 0.1.8 的工作。
- 构建中 available 一度掉到约 390MB（Gradle 守护进程 RSS 约 2.3GB＋Kotlin
  daemon），但构建未 OOM、成功完成；Gradle 守护进程（PID 20419，我的构建新建的）
  仍在运行，未特意停掉。

## 6. 遗留/注意

- Kotlin daemon 连不上（日志里多次 `e: Failed connecting to the daemon in 4
  retries`，`/tmp/kotlin-daemon.*.log` 显示新 daemon 每分钟起一个、连 registry
  超时 60 秒后自停）：构建靠回退路径继续推进，未失败，但拖慢了构建（27 分钟）。
  下次构建若还慢，可考虑查 Kotlin daemon 注册表（`/root/.kotlin/daemon/`）
  或改 in-process 编译——本次未改，免得动构建配置。
- 未推客户端仓、未动面板/服务端、未动上游 PR、未动 0.1.8 的任何文件。
- 0.1.8 的 Gradle 守护进程死于 16:48 虚拟机重启（与本次任务无关的系统事件），
  其构建是否受影响须由 0.1.8 协调员自行确认；其 16:22 的 release 产物
  （`app-arm64-v8a-release.apk`、`app-x86_64-release.apk` 等）原样未动。
