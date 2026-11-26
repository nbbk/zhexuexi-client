# 哲学系客户端打包工具使用说明（Windows 本地版）

> 不依赖 GitHub。在你自己的 Windows 电脑上，双击打开、填好信息、点“开始打包”，
> 直接在本机打出 release APK（分架构：arm64 / armv7 / x86_64）。
> 以后助手更新好客户端代码，你自己这样打就行，不用等助手发包。

---

## 一、双击哪个文件打开

把 `tools/` 目录里的这两个文件拷到 Windows 电脑上，放同一个文件夹里：

| 文件 | 作用 |
|---|---|
| `启动打包工具.bat` | **双击这个打开**（它会调用下面的脚本） |
| `package-apk.ps1` | 打包工具本体（图形界面） |

> 也可以右键 `package-apk.ps1` →“使用 PowerShell 运行”，但双击 `.bat` 最省事。
> 系统自带的 Windows PowerShell 5.1 就够，**不用装 PowerShell 7**。
> 第一次打开如果弹“是否允许运行”，点“是”即可。

---

## 二、第一次用：先点“一键安装打包环境”

打开界面后，先点左下角 **“一键安装打包环境”**。它会自动做这些事：

1. 下载 Flutter 3.50.1（约 1.87 GB），解压到 `C:\Users\你的用户名\zhexuexi-tools\flutter`
2. 下载 Java 17（Temurin，约 180 MB），解压到 `zhexuexi-tools\jdk-17`
3. 下载 Android 命令行工具（约 143 MB），用 sdkmanager 装 platform-tools、SDK Platform 37、build-tools
4. **NDK 28.2.13676358 直接下载压缩包**（约 748 MB，不走 sdkmanager——sdkmanager 下 NDK 特别慢）
5. 把路径写进你的用户环境变量（ANDROID_HOME、JAVA_HOME、PATH），新开的窗口直接可用
6. 装完自动验收一遍（Flutter 版本、Platform 37、NDK 都在才算过）

首次安装一共下载约 2.9 GB，看网速，可能要十几分钟到半小时，日志框里会实时显示进度。
装好之后以后都不用再装，打开直接打包。

> 环境目录在 `C:\Users\你的用户名\zhexuexi-tools`，不用管理员权限。
> 已经装过的部分会自动跳过，不会重复下载。

---

## 三、每项填什么

| 项 | 填什么 |
|---|---|
| 应用名 | 打包出来的 App 在手机上显示的名字。默认“哲学系”，回车就是默认 |
| Logo | 两种方式：点“选择文件…”选本地图片，或直接在框里填图片网址。空着用仓库自带的 Logo。Logo 会被缩放到 1600×1600，启动器图标按新 Logo 重新生成 |
| 远程配置域名 | 客户端拉品牌/订阅配置的地址里的域名。默认 `cc.jiankong.cf`，只填域名本身，不要带 `https://` |
| keystore 文件 | 点“选择文件…”选你的 keystore 文件。默认找当前目录下的 `zhexuexi-release.keystore`，找到了会自动填上 |
| keystore 密码 | 密码框，输入时不回显。**以后每次升级都要用同一把 keystore 和同一个密码签名，换了签名，已装的用户就升不了级，只能卸载重装** |
| 源码位置 | 空着：自动克隆仓库到当前目录下的 `zhexuexi-client`（已有目录就 `git pull` 更新）。也可以点“选择目录…”选你本地已有的源码目录 |

填完点 **“开始打包”**，它会自动做：品牌注入（应用名写进 brand.json、换 Logo、换远程配置域名）→ 生成 key.properties → `flutter build apk --release --split-per-abi`。

---

## 四、keystore 放哪

- 把 `zhexuexi-release.keystore` 文件放到和 `启动打包工具.bat` 同一个文件夹里，打开工具时会自动填上。
- 或者点“选择文件…”选它在别处的位置。
- **keystore 文件和密码只存在你本机，不要发给别人。** 打包工具不会把它们发到任何地方。

---

## 五、打完的 APK 在哪

打完后，下面“打包结果”里会列出三个分包的路径、大小、SHA-256，arm64 那个重点标出：

| 分包 | 给谁用 |
|---|---|
| `app-arm64-v8a-release.apk`（约 102 MB） | **小米等绝大多数安卓手机用这个** |
| `app-armeabi-v7a-release.apk`（约 91 MB） | 老手机 |
| `app-x86_64-release.apk`（约 108 MB） | 模拟器 |

文件在源码目录下：`zhexuexi-client\apps\flutter_client\build\app\outputs\flutter-apk\`。
把 arm64 那个传到手机上安装即可。

> SHA-256 是用来核对文件没传坏的：传到手机前后对一下，值一样就是完整的。

---

## 六、常见报错怎么办

| 报错 / 现象 | 怎么办 |
|---|---|
| 双击 `.bat` 一闪而过 | 右键 `.bat` →“以管理员身份运行”试一次；或打开 PowerShell，`cd` 到工具目录，跑 `powershell -ExecutionPolicy Bypass -File .\package-apk.ps1` 看报错 |
| 提示“无法加载文件，因为在此系统上禁止运行脚本” | 用 `.bat` 启动（它自带 `-ExecutionPolicy Bypass`）；或以管理员身份跑一次 `Set-ExecutionPolicy RemoteSigned` |
| “没找到 Flutter / Java / Android SDK” | 先点“一键安装打包环境”；装完关掉重开工具再打包 |
| Flutter 版本不对（要求 3.50.1） | 工具里点“一键安装打包环境”会装 3.50.1；如果本机 PATH 里还有旧版 Flutter，把旧版的 bin 从 PATH 里去掉 |
| NDK 没装对 | 点“一键安装打包环境”重装；或确认 `zhexuexi-tools\android-sdk\ndk\28.2.13676358` 目录存在 |
| 下载失败 / 下载中断 | 检查网络，点“一键安装打包环境”重新跑一次，已下好的部分会跳过、断掉的会重下 |
| `git clone` 失败 | 检查网络，或确认能打开 https://github.com/nbbk/zhexuexi-client；也可以手动把源码拷下来，在“源码位置”里选它 |
| `flutter build apk` 失败，提示签名错误 | 确认 keystore 密码输对了（密码框不回显，输错一位就失败）；确认 keystore 的 alias 是 `zhexuexi` |
| `flutter build apk` 失败，提示依赖下不下来 | 检查网络，等一会儿再点“开始打包”重试；第一次构建要下载 Gradle 和依赖，比较慢 |
| Logo 不是方的，启动器图标没换 | 工具会先把 Logo 缩放到 1600×1600 再生成图标；如果提示没装 Python，装 Python 3 后再打包（或接受只换应用内 Logo、启动器图标仍用旧的） |
| 打完的 APK 装到手机上提示“与已安装应用签名不一致” | 说明这把 keystore 和手机上已装的那版不是同一把。必须用当初打第一版的那把 keystore 和密码重新打，不能换 |

---

## 七、这个工具和 GitHub CI 的区别

| | 本地工具（本说明） | GitHub Actions CI |
|---|---|---|
| 在哪打包 | 你的 Windows 电脑 | GitHub 的服务器 |
| 怎么触发 | 双击打开填信息点按钮 | 仓库 → Actions → build → Run workflow 填信息 |
| 要装什么 | 第一次点“一键安装打包环境”自动装 | 不用装，服务器上有 |
| 产物 | 直接落在你本机 | 在 Actions 的 Artifacts 里下载，保留 90 天 |
| 适合 | 经常打、想立刻拿到包 | 电脑不在身边、或本地环境实在装不上时 |

两个都能出正式版 release 包（同一把 keystore 签名就能互相升级）。
