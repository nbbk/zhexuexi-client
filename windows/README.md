# Windows 一键构建器 — 小白用法

> 一句话：**下载 → 右键以管理员身份运行 → 等它装完 → 看到“构建器已就绪”。**
> 全程中文提示，Android SDK、Flutter、Java、Git 全部脚本自动装，你一个都不用手动弄。

## 你要做的事（只有 3 步）

1. **下载**：把这个仓库下下来（Code → Download ZIP），解压到任意位置（比如桌面），打开 `windows` 文件夹。
2. **运行**：右键 `setup-builder.bat` → **以管理员身份运行**（双击也行，它会自己弹管理员窗口，点“是”）。
3. **等它装完**：屏幕上一步一步打中文提示，Android SDK 那一步最久（约 10–20 分钟），别关窗口。最后出现 **“构建器已就绪”** 就是装好了。

## 装的过程中会问你的事（只有 1 个，可跳过）

- **要不要注册 GitHub 自托管 runner？** 想让这台电脑接发布任务（面板点发布后在这台电脑上编）就要注册；只想装环境、以后再说，就**直接回车跳过**。
- 要注册时，粘贴 runner token：去 GitHub 仓库页面 → Settings → Actions → Runners → New self-hosted runner，复制那里的 token，粘贴进来。token 只能用一次，过期了重新复制一个。
- 仓库地址有默认值 `nbbk/zhexuexi-client`，直接回车就行；换仓时改成自己的 `账号/仓库名`。

## 装好了怎么验证（逐项打勾，全打勾才算装好）

- [ ] 屏幕上出现“构建器已就绪”。
- [ ] 新开一个 PowerShell，跑 `flutter doctor`，显示 `No issues found`，或只剩 Chrome / Visual Studio 的提示（那两个不影响编 Win 和 Android）。
- [ ] 跑 `git --version`、`java -version`、`flutter --version`，都有输出，没有“找不到命令”。
- [ ] 跑 `echo $env:ANDROID_HOME`，指向 `C:\dev\android-sdk`。
- [ ] 任务计划程序里能看到 `ZhexuexiBuilder`（只在注册了 runner 时有）。
- [ ] 重启电脑一次，登录后构建器自动起来（GitHub 仓库 Actions → Runners 里显示 Online）。

有一项不过：把屏幕上的报错原样发给助手，不用自己猜、不用从头重装。

## 怎么卸载 / 重装

- **卸载**：任务计划程序里删 `ZhexuexiBuilder`；删掉 `C:\dev\flutter`、`C:\dev\android-sdk`、`C:\dev\zhexuexi-runner` 三个文件夹；就卸干净了。
- **重装**：再跑一次 `setup-builder.bat` 就行；已编好的包在仓库的 `build/` 里，不在脚本目录，重装不会删掉。

## 出问题怎么办

| 看到的提示 | 怎么办 |
|---|---|
| 第 1 步失败：没有管理员权限 | 右键 `setup-builder.bat`，选“以管理员身份运行”，别直接双击 |
| 第 2 / 3 / 4 / 5 步失败：下载不了 | 检查网络能不能上 github.com / storage.googleapis.com / dl.google.com，再跑一次 |
| 第 7 步失败：token 无效 | token 只能用一次，去 GitHub 重新复制一个再跑 |
| 装到一半关了窗口 | 再跑一次脚本，已装好的步骤会自动跳过，不用从头装 |

> 提醒：本脚本未在真机 Windows 上跑过（本机无 Windows），只做静态核对；阶段 0 会在干净 Win 11 真机上跑一遍再交付。
