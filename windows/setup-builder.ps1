# 哲学系客户端 — Windows 一键构建器
# 用法：右键 setup-builder.bat → 以管理员身份运行（它会调这个脚本）。
# 脚本会自动装 Git、Flutter、JDK 17、Android SDK（自动接受 license）、
# 设环境变量、跑 flutter doctor 校验、可选注册 GitHub 自托管 runner、
# 设开机自启。用户全程只看中文提示，失败即停并打印原因，不静默跳过。
# 注意：本脚本未在真机 Windows 上跑过（本机无 Windows、无 pwsh），
# 只做静态核对；阶段 0 须在干净 Win 11 真机上跑一遍再交付。
# 版本钉死（阶段 0 再核实一次最新稳定版）：Flutter 3.24.0，JDK 17，Android API 34。

$ErrorActionPreference = "Stop"

$FlutterVersion = "3.24.0"
$AndroidApiLevel = "34"
$InstallRoot = "C:\dev"
$FlutterDir = "$InstallRoot\flutter"
$AndroidSdkDir = "$InstallRoot\android-sdk"
$RunnerDir = "$InstallRoot\zhexuexi-runner"

function Say-Step([string]$Text) { Write-Host ""; Write-Host "$Text" -ForegroundColor Cyan}
function Say-Ok([string]$Text) { Write-Host "$Text" -ForegroundColor Green}
function Say-Fail([string]$Step, [string]$Reason, [string]$Fix) {
Write-Host ""; Write-Host "第 $Step 步失败了。" -ForegroundColor Red
Write-Host "原因是：$Reason" -ForegroundColor Red
Write-Host "怎么办：$Fix" -ForegroundColor Yellow
Write-Host "把上面这段话发给助手，就能定位，不用自己猜。" -ForegroundColor Yellow
exit 1
}

Write-Host "=============================================="
Write-Host "哲学系客户端 — Windows 一键构建器"
Write-Host "会自动装 Git、Flutter、Java、Android SDK，"
Write-Host "装完就能编 Win 和 Android，还能开机自启。"
Write-Host "全程中文提示，失败了会告诉你原因和办法。"
Write-Host "=============================================="

# 第 1 步：检查
Say-Step "第 1 步：正在检查你的电脑（Windows 版本、管理员权限）…"
try {
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "没有管理员权限。请右键 setup-builder.bat，选“以管理员身份运行”。"}
$os = (Get-CimInstance Win32_OperatingSystem).Caption
Write-Host "你的系统是：$os"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
Say-Fail "1" "找不到 winget（装软件用的工具）。" "先去微软商店装 App Installer，再重新跑一次脚本。"
}
} catch { Say-Fail "1" $_.Exception.Message "按上面的提示做，再重新跑一次脚本。"}
Say-Ok "检查通过。"

# 第 2 步：装 Git
Say-Step "第 2 步：正在安装 Git（下载代码用的）…"
try {
if (Get-Command git -ErrorAction SilentlyContinue) { Write-Host "Git 已经装过了，跳过。"}
else { winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements; $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")}
git --version
} catch { Say-Fail "2" $_.Exception.Message "检查网络能不能上 github.com，再重新跑一次脚本。"}
Say-Ok "Git 装好了。"

# 第 3 步：装 Flutter
Say-Step "第 3 步：正在安装 Flutter $FlutterVersion（编客户端用的，约 1GB，耐心等）…"
try {
if (Test-Path "$FlutterDir\bin\flutter.bat") { Write-Host "Flutter 已经装过了，跳过。"}
else {
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
$zip = "$env:TEMP\flutter_windows_$FlutterVersion-stable.zip"
Invoke-WebRequest -Uri "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_$FlutterVersion-stable.zip" -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $InstallRoot -Force
Remove-Item $zip -Force
}
$flutterBin = "$FlutterDir\bin"
if ($env:Path -notlike "*$flutterBin*") { [System.Environment]::SetEnvironmentVariable("Path", "$env:Path;$flutterBin", "Machine"); $env:Path += ";$flutterBin"}
flutter --version
} catch { Say-Fail "3" $_.Exception.Message "检查网络能不能上 storage.googleapis.com，再重新跑一次脚本。"}
Say-Ok "Flutter 装好了。"

# 第 4 步：装 JDK 17
Say-Step "第 4 步：正在安装 Java 17（编 Android 用的）…"
try {
if (Get-Command java -ErrorAction SilentlyContinue) { Write-Host "Java 已经装过了，跳过。"}
else { winget install --id EclipseAdoptium.Temurin.17.JDK -e --accept-source-agreements --accept-package-agreements}
java -version
} catch { Say-Fail "4" $_.Exception.Message "检查网络，再重新跑一次脚本。"}
Say-Ok "Java 装好了。"

# 第 5 步：装 Android SDK（最久，约 10–20 分钟，别关窗口）
Say-Step "第 5 步：正在安装 Android SDK（这一步最久，约 10–20 分钟，别关窗口）…"
try {
$cmdlineZip = "$env:TEMP\commandlinetools-win.zip"
if (-not (Test-Path "$AndroidSdkDir\cmdline-tools\latest\bin\sdkmanager.bat")) {
Invoke-WebRequest -Uri "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip" -OutFile $cmdlineZip
New-Item -ItemType Directory -Force -Path "$AndroidSdkDir\cmdline-tools" | Out-Null
Expand-Archive -Path $cmdlineZip -DestinationPath "$env:TEMP\cmdline-tools-tmp" -Force
Move-Item "$env:TEMP\cmdline-tools-tmp\cmdline-tools" "$AndroidSdkDir\cmdline-tools\latest" -Force
Remove-Item $cmdlineZip -Force
} else { Write-Host "Android SDK 已经装过了，跳过下载，只补装缺少的组件。"}
[System.Environment]::SetEnvironmentVariable("ANDROID_HOME", $AndroidSdkDir, "Machine")
[System.Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", $AndroidSdkDir, "Machine")
$env:ANDROID_HOME = $AndroidSdkDir; $env:ANDROID_SDK_ROOT = $AndroidSdkDir
$env:Path += ";$AndroidSdkDir\cmdline-tools\latest\bin;$AndroidSdkDir\platform-tools"
# 自动接受全部 license，用户不用一个个点同意
cmd /c "echo y | `"$AndroidSdkDir\cmdline-tools\latest\bin\sdkmanager.bat`" --licenses" | Out-Null
& "$AndroidSdkDir\cmdline-tools\latest\bin\sdkmanager.bat" "platform-tools" "platforms;android-$AndroidApiLevel" "build-tools;34.0.0"
} catch { Say-Fail "5" $_.Exception.Message "检查网络能不能上 dl.google.com，再重新跑一次脚本。"}
Say-Ok "Android SDK 装好了。"

# 第 6 步：校验
Say-Step "第 6 步：正在检查安装结果（flutter doctor）…"
try {
flutter doctor
Write-Host "如果上面只剩 Chrome / Visual Studio 的提示，不用管，不影响编 Win 和 Android。"
} catch { Say-Fail "6" $_.Exception.Message "把上面 flutter doctor 的输出发给助手。"}
Say-Ok "校验通过。"

# 第 7 步：注册 GitHub 自托管 runner（可选，直接回车跳过）
Say-Step "第 7 步：要不要注册 GitHub 自托管 runner？（想在这台电脑上接发布任务就要，"
Write-Host "不要就直接回车跳过，只装环境。以后想注册，再跑一次脚本就行。）"
$token = Read-Host "粘贴 runner token（GitHub 仓库 Settings → Actions → Runners → New self-hosted runner 里复制），不要直接回车"
if ($token -ne "") {
try {
$repo = Read-Host "仓库地址（默认 nbbk/zhexuexi-client，直接回车就是默认值）"
if ($repo -eq "") { $repo = "nbbk/zhexuexi-client"}
New-Item -ItemType Directory -Force -Path $RunnerDir | Out-Null
$runnerZip = "$env:TEMP\actions-runner-win.zip"
Invoke-WebRequest -Uri "https://github.com/actions/runner/releases/download/v2.317.0/actions-runner-win-x64-2.317.0.zip" -OutFile $runnerZip
Expand-Archive -Path $runnerZip -DestinationPath $RunnerDir -Force
Set-Location $RunnerDir
.\config.cmd --url "https://github.com/$repo" --token $token --unattended --replace
Write-Host "runner 注册好了。"
} catch { Say-Fail "7" $_.Exception.Message "检查 token 是不是刚复制的（token 只能用一次，过期了去 GitHub 重新复制一个），再重新跑一次脚本。"}
Say-Ok "runner 注册好了。"
} else {
Write-Host "跳过注册，只装了环境。以后想注册，再跑一次脚本，粘贴 token 就行。"
}

# 第 8 步：开机自启（只在注册了 runner 时做）
if ($token -ne "") {
Say-Step "第 8 步：正在设置开机自启（登录后构建器自动启动）…"
try {
$action = New-ScheduledTaskAction -Execute "$RunnerDir\run.cmd" -WorkingDirectory $RunnerDir
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName "ZhexuexiBuilder" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
} catch { Say-Fail "8" $_.Exception.Message "把报错发给助手。"}
Say-Ok "开机自启设好了。"
}

# 第 9 步：就绪清单
Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "构建器已就绪" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host "装了什么："
flutter --version
git --version
java -version
Write-Host "Android SDK 在：$AndroidSdkDir"
if ($token -ne "") { Write-Host "runner 在：$RunnerDir，开机自启任务：ZhexuexiBuilder"}
Write-Host ""
Write-Host "怎么验证（逐项打勾）："
Write-Host "1. 新开一个 PowerShell，跑 flutter doctor，显示 No issues found 或只剩 Chrome / Visual Studio 提示。"
Write-Host "2. 跑 git --version、java -version、flutter --version 都有输出。"
Write-Host "3. 跑 echo `$env:ANDROID_HOME，应指向 $AndroidSdkDir。"
Write-Host "4. 任务计划程序里能看到 ZhexuexiBuilder（只在注册了 runner 时有）。"
Write-Host "5. 重启电脑一次，登录后构建器自动起来（GitHub 仓库 Actions → Runners 里显示 Online）。"
Write-Host ""
Write-Host "怎么卸载：见 windows/README.md（删任务计划 + 删 C:\dev 下的文件夹，再跑一次脚本就是重装）。"
