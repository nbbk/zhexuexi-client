# GitHub 手动打包教程：在 GitHub 上点几下，自动打出 APK 和 Windows exe

不用本地装 Flutter、不用等助手打包。代码更新好以后，你自己在 GitHub
网页上填几个信息、点一下运行，十几分钟后就能下载到新版 APK 或 Windows exe。

先说一句：这个流程已经多次跑绿，正常填都能跑通。跑不通别慌，照第 4 节查，
多数是 Secrets 没填对。

---

## 0. 先准备好三样东西

| 东西 | 在哪 | 备注 |
|---|---|---|
| keystore 文件 | 之前发到你邮箱/聊天里的 `zhexuexi-release.keystore`（解压 keystore zip 得到） | 以后每次升级都用同一把签，别换、别丢 |
| keystore 密码 | 和 keystore 一起给你的那串密码 | 不要发给别人、不要贴到任何公开地方 |
| Logo 图片地址（可选） | 你要用的 Logo 放到一个能直接下载的地址 | 必须是直接指向 PNG 文件的链接，不是网页预览页 |

---

## 1. 填 Secrets（只做一次，以后不用再填）

Secrets 是存在仓库里的密码，构建时才用，不会写进代码、不会打进日志。

### 1.1 先把 keystore 转成 base64

在 Windows 电脑上，打开 PowerShell，进到 keystore 文件所在的文件夹，
复制下面这行、回车。它会把 base64 结果直接复制到剪贴板，不在电脑上留文件：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("zhexuexi-release.keystore")) | Set-Clipboard
```

看到光标回到下一行、没报错，就是转好了（剪贴板里现在是一大串字母数字）。

> 也可以用 `certutil -encode zhexuexi-release.keystore out.txt`，但它输出
> 的文件头尾带 `-----BEGIN CERTIFICATE-----` / `-----END CERTIFICATE-----`
> 两行，粘贴前必须手动删掉这两行，漏删构建会报错。**不要用在线 base64
> 工具转 keystore**：keystore 就是你的签名身份，传到陌生网站上等于
> 把钥匙交给别人。PowerShell 本地转最稳。

### 1.2 去仓库里新建 Secrets

1. 打开浏览器，进仓库 `nbbk/zhexuexi-client`。
2. 点顶部菜单的 **Settings**（仓库设置，不是你账号的设置）。
3. 左边栏点 **Secrets and variables** → **Actions**。
4. 点右边的 **New repository secret**，一个一个建。下面 4 个是 Android
   正式版必须的，名字要一字不差：

| Secret 名字 | 填什么 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | 第 1.1 步转好的那串 base64（从剪贴板粘贴） |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 的 storePassword（建 keystore 时设的密码） |
| `ANDROID_KEY_PASSWORD` | key 的 keyPassword（和 storePassword 是同一串） |
| `ANDROID_KEY_ALIAS` | keyAlias，填 `zhexuexi` |

每个建完点 **Add secret**。建完列表里只显示名字，看不到值，这是正常的。

> Windows 签名用的 `WINDOWS_CERT_BASE64` / `WINDOWS_CERT_PASSWORD`
> 是给 Windows 版 exe 的，只打 APK 不用填。

### 1.3 怎么确认填对了

Secrets 页面能看到 4 个名字都在，就行。值看不到、改不了，填错了只能
点名字进去 **Update** 重新填。如果后面构建报密码错，先来这里重填
这 3 个密码类的（见第 4 节）。

---

## 2. 手动触发构建

1. 在仓库页面点顶部菜单的 **Actions**。
2. 左边的工作流列表里点 **build**。
3. 右边点 **Run workflow**（如果看不到这个按钮，说明你没登录或不是
   仓库成员，先登录 GitHub）。
4. 弹出的表单里填 5 个输入：

| 输入 | 填什么 | 留空会怎样 |
|---|---|---|
| 应用名 `brand_name` | 想显示的应用名，一般就用默认的 `哲学系` | 用默认的 `哲学系` |
| 版本号 `version` | 比如 `0.1.1` | 不填也行，产物名用分支名代替；**注意：这个版本号只用来给产物起名，不会改应用里显示的版本号** |
| Logo 图片地址 `logo_url` | Logo 图片直链（PNG/JPG/WebP/BMP/GIF 等） | 用仓里自带的 Logo（哲人侧脸 v1） |
| 远程配置域名 `remote_config_domain` | 比如 `cc.jiankong.cf`，只填域名 | 用仓里默认值 |
| 打包平台 `platform` | 下拉选一个：`all`（Windows＋安卓一起打）、`windows`（只打 Windows 版，zip，解压即用）、`android`（只打安卓 APK） | 默认 `all`，两个一起打 |

   只打一个平台时，另一个任务会显示“已跳过”（Skipped），这是正常的，
   不是失败：你没选它，它就不跑，Artifacts 里也只有你选的那个平台的包。

   填 Logo 时注意：必须是直接返回图片的地址（PNG/JPG/WebP/BMP/GIF 等，
   下载后统一转成 PNG）。在浏览器里打开那个地址，应该直接显示一张图；
   如果打开是个网页、要再点下载，那个地址不能用。
   Logo 是整个换的：底色也是 Logo 的一部分，传什么底色、启动器图标就
   是什么底色，不再贴到墨蓝底上；最好传方形图（含底色），比如 1024×1024。
   填域名时注意：只填域名，不要带 `https://`，也不要带后面的路径；
   填了完整地址也能用（只取 host 部分），但最好只填域名。

5. 点绿色的 **Run workflow** 按钮。页面会跳到这次运行（run）的详情页。

### 看进度

详情页上方的流程图里有两个方块：**Windows** 和 **Android**。方块变绿
勾就是跑完了，变红叉就是失败了，变灰“已跳过”就是你这次没选它
（platform 只选了一个平台时另一个就是跳过，不用管它）。点一个方块能看到每一步花了多长时间。
Android 那边从拉代码到出包一般 10–20 分钟，第一次跑要下载 Flutter
和 Gradle 依赖，会更慢，耐心等。页面不用一直开着，跑完了 GitHub
会给你发邮件通知。

---

## 3. 下载 APK 和 Windows 压缩包

### 下载 APK

1. 等你选的那个方块变绿勾（只打一个平台时另一个是“已跳过”，不用等它），拉到详情页最底部，找到 **Artifacts**。
2. 里面有一个压缩包，名字是 `android-` 开头：
   - 版本号填了 `0.1.1` → `android-0.1.1`
   - 版本号没填 → `android-main`
3. 点它下载，得到一个 zip，解压，里面有 6 个文件：

| 文件 | 说明 |
|---|---|
| `app-arm64-v8a-release.apk` | **小米手机装这个**（arm64，约 102MB） |
| `app-armeabi-v7a-release.apk` | 老手机用的 armv7 版 |
| `app-x86_64-release.apk` | 模拟器用的 x86_64 版 |
| 每个 APK 对应的 `.sha256` 文件 | 校验用的哈希值 |

### 校验（确认下载的文件没坏）

在 Windows PowerShell 里，进到解压出来的文件夹，跑：

```powershell
Get-FileHash .\app-arm64-v8a-release.apk -Algorithm SHA256
```

输出一串哈希值。再打开同名的 `.sha256` 文件（记事本就能开），
里面也是一串哈希值。两串**完全一样**，文件就是好的；不一样就重新下载。

> 如果 Artifacts 里只有一个 `app-debug.apk`、没有上面三个 release 包，
> 说明 keystore 的 Secrets 没填（流程自动降级编了 debug 包）。回去
> 看第 1 节，4 个 Android Secrets 有没有都建好，建好再跑一次。

### 下载 Windows 压缩包

1. 等 **Windows** 方块变绿勾，拉到详情页最底部，找到 **Artifacts**。
2. 里面有一个压缩包，名字是 `windows-` 开头：
   - 版本号填了 `0.1.1` → `windows-0.1.1`
   - 版本号没填 → `windows-main`
3. 点它下载，得到一个 zip，解压，里面就是可以直接运行的文件夹：

| 文件 | 说明 |
|---|---|
| `哲学系.exe` | **双击这个就能跑** |
| `flutter_windows.dll` | 程序要用的库，和 exe 放同一个文件夹，别删 |
| `data/` 文件夹 | 程序要用的资源文件，和 exe 放同一个文件夹，别删 |
| `哲学系.exe.sha256` | 校验用的哈希值（校验方法见下面） |

解压后别把 exe 单独拷走：exe、dll、`data/` 必须在同一个文件夹里才能跑，
拷走一个就跑不起来。

### 校验 Windows 的 exe（确认下载的文件没坏）

在 Windows PowerShell 里，进到解压出来的文件夹，跑：

```powershell
Get-FileHash .\哲学系.exe -Algorithm SHA256
```

输出一串哈希值。再打开同名的 `.sha256` 文件（记事本就能开），里面也是一串
哈希值。两串**完全一样**，文件就是好的；不一样就重新下载。

> Windows 版没填签名证书时出的是未签名包，第一次双击 exe 会弹
> SmartScreen（“Windows 已保护你的电脑”），点 **更多信息** →
> **仍要运行** 就能跑。这是没买证书的正常现象，不是文件有问题。

---

## 4. 失败了怎么办

去那次运行的详情页，点变红的方块，点失败的那一步，看最后几行红字。
下面是最常见的几种：

### 4.1 产物只有 debug 包，没有 release 包

- **长什么样**：构建显示成功（绿勾），但 Artifacts 里只有 `app-debug.apk`。
- **原因**：`ANDROID_KEYSTORE_BASE64` 没填，流程自动改编 debug 包。
- **怎么修**：按第 1 节把 4 个 Android Secrets 建好，重新跑一次。

### 4.2 keystore 密码错

- **长什么样**：**Android** 方块变红，失败在“编 Android APK”这一步，
  日志里有 `keystore password was incorrect` 或 `Cannot recover key`，
  或者中文提示“缺密码 Secrets”。
- **原因**：三个密码类的 Secret 有一个填错了，或者只填了 keystore
  没填密码。
- **怎么修**：去 Secrets 页面，把 `ANDROID_KEYSTORE_PASSWORD`、
  `ANDROID_KEY_PASSWORD`、`ANDROID_KEY_ALIAS` 重新填一遍（Update），
  再跑一次。密码就是和 keystore 一起给你的那串。

### 4.3 Logo 地址下不到

- **长什么样**：失败在“Logo 与远程配置域名注入”这一步，日志里有
  `logo 转换失败` 或下载报错。
- **原因**：地址打不开，或者打开的不是图片（是个网页、或者要登录）。
- **怎么修**：浏览器里直接打开那个地址，能直接看到图才行；不行就换
  一个直链，或者这次先不填 Logo（留空用仓里自带的），跑通了再说。

### 4.4 远程配置域名不合法

- **长什么样**：失败在“Logo 与远程配置域名注入”这一步，日志里有
  `remote_config_domain 不合法` 或 `远程配置默认地址替换失败`。
- **原因**：域名填错了格式（比如带了空格、带了中文、带了路径）。
- **怎么修**：只填域名本身，如 `cc.jiankong.cf`，不要带 `https://`、
  不要带 `/` 后面的东西。

### 4.5 构建超时 / 第一次跑特别慢

- **长什么样**：跑了很久没动静，或者超时失败。
- **原因**：第一次跑要下载 Flutter、Gradle 和一堆依赖，GitHub
  那边慢是正常的。
- **怎么修**：直接点 **Re-run jobs** 再跑一次；第二次有缓存，会快很多。

---

## 5. 装到小米手机上

1. 把 `app-arm64-v8a-release.apk` 传到小米手机上（微信发给自己、
   数据线拷、或从电脑上用浏览器下载都行）。
2. 在手机上点这个 APK 文件安装。
3. 如果弹出“出于安全考虑，已禁止安装未知来源应用”（或类似的话）：
   点弹框里的 **设置** → 打开 **允许安装未知应用**（允许这一次安装的
   来源，比如微信或文件管理）→ 返回，再点 APK 安装。
   这是小米自带的安全提示，不是文件有问题。
4. 装好后点 **打开**。

### 怎么确认装的是新版

应用里 **设置** 页显示的版本号就是装的这一版（0.1.14 起改读安装包的
真实版本，不再写死），**可以直接拿它当新版的证据**。下面几处也可以对照：

- 顶栏是墨蓝色的（不是浅灰蓝）；
- 节点列表里每行左侧圆圈里是协议简称（`VL`、`HY2` 这种），不是国旗、
  也不是 `Hysteria2` 这种长文字；
- 节点页能看到“扫码”按钮，订阅管理里能看到订阅列表；
- 首次启动那条“需要联网拉取配置”的提示右上角有个 ×，能点掉。

---

## 附：一次完整操作清单（照着打勾）

- [ ] 第 1.1 步：keystore 转 base64，复制到剪贴板
- [ ] 第 1.2 步：4 个 Android Secrets 建好
- [ ] 第 2 步：Actions → build → Run workflow，填好 5 个输入，点运行
- [ ] 等你选的方块变绿勾（只打一个平台时另一个是“已跳过”，不用等它）
- [ ] 第 3 步：Artifacts 下载 `android-*`（和/或 `windows-*`），解压，校验 SHA-256
- [ ] 第 5 步：传到小米手机上安装，确认是新版
