#Requires -Version 5.1
<#
.SYNOPSIS
    哲学系客户端打包工具（图形界面版）
    双击同目录下的“启动打包工具.bat”打开，填好信息，点“开始打包”，
    在本机打出 release APK（分架构：arm64 / armv7 / x86_64）。

.DESCRIPTION
    功能：
      1. 一键安装打包环境：自动下载 Flutter 3.50.1、Java 17、Android 命令行工具，
         用 sdkmanager 装 platform-tools / platforms / build-tools，
         NDK 28.2.13676358 直接下载压缩包（不走 sdkmanager 的慢路），
         装完写入用户环境变量（ANDROID_HOME、JAVA_HOME、PATH），不用手动配。
      2. 图形界面填信息：应用名、Logo（选文件或填网址）、远程配置域名、
         keystore 文件、keystore 密码、源码位置。
      3. 点“开始打包”自动完成品牌注入、生成 key.properties、
         跑 flutter build apk --release --split-per-abi，
         界面上实时显示进度和日志，打完显示三个分包的路径、大小、SHA-256。

    要求：Windows 10/11，系统自带的 Windows PowerShell 5.1 就够，不用装 PowerShell 7。
    首次安装环境要下载约 2.9 GB（Flutter 1.87 GB + NDK 748 MB + JDK 约 180 MB +
    命令行工具 143 MB），请保持网络畅通。

    keystore 文件和密码只存在你本机，不会发给任何人。
    使用方法见同目录的 package-apk-README.md。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# ---------------- 常量 ----------------
$script:DefaultAppName = '哲学系'
$script:DefaultRemoteDomain = 'cc.jiankong.cf'
$script:RepoUrl = 'https://github.com/nbbk/zhexuexi-client'
$script:RequiredFlutter = '3.50.1'
$script:RequiredNdk = '28.2.13676358'
$script:RequiredCompileSdk = '37'
$script:FlutterZipUrl = 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.50.1-stable.zip'
$script:CmdlineToolsUrl = 'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip'
$script:NdkZipUrl = 'https://dl.google.com/android/repository/android-ndk-r28c-windows.zip'
$script:JdkZipUrl = 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse'
$script:EnvRoot = Join-Path $env:USERPROFILE 'zhexuexi-tools'
$script:DownloadDir = Join-Path $script:EnvRoot 'downloads'

# ---------------- 日志 ----------------
function Add-Log {
    param([string]$Text, [string]$Kind = 'info')
    $color = switch ($Kind) {
        'ok'    { [System.Drawing.Color]::Green }
        'warn'  { [System.Drawing.Color]::DarkOrange }
        'error' { [System.Drawing.Color]::Red }
        'step'  { [System.Drawing.Color]::Blue }
        default { [System.Drawing.Color]::Black }
    }
    $box = $script:logBox
    if (-not $box) { return }
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = $color
    $box.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $Text))
    $box.SelectionColor = $box.ForeColor
    $box.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Status {
    param([string]$Text)
    if ($script:statusLabel) { $script:statusLabel.Text = $Text }
    [System.Windows.Forms.Application]::DoEvents()
}

function Format-MB {
    param([long]$Bytes)
    return ('{0:N1} MB' -f ($Bytes / 1MB))
}

function Test-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# ---------------- 下载（BITS 优先，失败回退到 Invoke-WebRequest） ----------------
function Download-File {
    param([string]$Url, [string]$Dest, [string]$Name)
    $dir = Split-Path $Dest -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path $Dest) { Remove-Item $Dest -Force }
    Add-Log "下载 $Name …（$Url）" 'info'
    $bitsOk = $false
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) { $bitsOk = $true }
    }
    catch { $bitsOk = $false }
    if ($bitsOk) {
        try {
            $job = Start-BitsTransfer -Source $Url -Destination $Dest -Asynchronous -DisplayName $Name -Description $Name -ErrorAction Stop
            while ($job.JobState -in @('Connecting', 'Transferring', 'Queued', 'TransientError')) {
                Start-Sleep -Milliseconds 500
                [System.Windows.Forms.Application]::DoEvents()
                $job = Get-BitsTransfer -JobId $job.JobId -ErrorAction SilentlyContinue
                if (-not $job) { break }
                if ($job.BytesTotal -gt 0) {
                    $pct = [Math]::Round($job.BytesTransferred * 100 / $job.BytesTotal, 1)
                    Set-Status "下载 $Name：$pct%（已下 $(Format-MB -Bytes $job.BytesTransferred) / 共 $(Format-MB -Bytes $job.BytesTotal)）"
                }
            }
            if ($job -and $job.JobState -eq 'Transferred') {
                Complete-BitsTransfer -BitsJob $job -ErrorAction Stop
                Add-Log "$Name 下载完成" 'ok'
                return $true
            }
            if ($job) { Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue }
            Add-Log 'BITS 下载没完成，改用普通下载重试…' 'warn'
        }
        catch {
            Add-Log "BITS 下载失败（$($_.Exception.Message)），改用普通下载重试…" 'warn'
        }
    }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop
        Add-Log "$Name 下载完成" 'ok'
        return $true
    }
    catch {
        throw "下载 $Name 失败：$($_.Exception.Message)。请检查网络后点“重试”，或手动下载后放到 $Dest 再重新安装。"
    }
}

function Expand-Zip {
    param([string]$Zip, [string]$Dest)
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Force -Path $Dest | Out-Null }
    Add-Log "解压 $(Split-Path $Zip -Leaf) …" 'info'
    Expand-Archive -Path $Zip -DestinationPath $Dest -Force
}

# ---------------- 环境定位 ----------------
function Get-FlutterPath {
    $p = Join-Path $script:EnvRoot 'flutter\bin\flutter.bat'
    if (Test-Path $p) { return $p }
    if (Test-Command 'flutter') { return 'flutter' }
    return $null
}

function Get-AndroidSdkDir {
    $p = Join-Path $script:EnvRoot 'android-sdk'
    if (Test-Path (Join-Path $p 'cmdline-tools\latest\bin\sdkmanager.bat')) { return $p }
    if ($env:ANDROID_HOME -and (Test-Path $env:ANDROID_HOME)) { return $env:ANDROID_HOME }
    if ($env:ANDROID_SDK_ROOT -and (Test-Path $env:ANDROID_SDK_ROOT)) { return $env:ANDROID_SDK_ROOT }
    $def = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path $def) { return $def }
    return $null
}

function Get-JavaHome {
    $p = Join-Path $script:EnvRoot 'jdk-17'
    if (Test-Path (Join-Path $p 'bin\java.exe')) { return $p }
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) { return $env:JAVA_HOME }
    return $null
}

function Set-UserEnv {
    param([string]$Name, [string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item "env:$Name" $Value
}

function Add-UserPath {
    param([string]$Dir)
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($cur -notlike "*$Dir*") {
        [Environment]::SetEnvironmentVariable('Path', "$cur;$Dir", 'User')
    }
    if ($env:Path -notlike "*$Dir*") { $env:Path = "$env:Path;$Dir" }
}

# ================= 一键安装打包环境 =================
function Install-Environment {
    Add-Log '开始安装打包环境（首次约下载 2.9 GB，请保持网络畅通）' 'step'
    Set-Status '正在安装打包环境…'
    if (-not (Test-Path $script:DownloadDir)) { New-Item -ItemType Directory -Force -Path $script:DownloadDir | Out-Null }

    # ---- 1. Flutter 3.50.1 ----
    $flutterBat = Join-Path $script:EnvRoot 'flutter\bin\flutter.bat'
    $flutterOk = $false
    if (Test-Path $flutterBat) {
        $v = (& $flutterBat --version 2>&1 | Out-String)
        if ($v -match 'Flutter\s+(\d+\.\d+\.\d+)' -and $Matches[1] -eq $script:RequiredFlutter) {
            $flutterOk = $true
            Add-Log "Flutter $($Matches[1]) 已安装，跳过" 'ok'
        }
        else {
            Add-Log '已装的 Flutter 版本不对，重新下载安装…' 'warn'
        }
    }
    if (-not $flutterOk) {
        $zip = Join-Path $script:DownloadDir 'flutter_windows_3.50.1-stable.zip'
        [void](Download-File -Url $script:FlutterZipUrl -Dest $zip -Name 'Flutter 3.50.1')
        Expand-Zip -Zip $zip -Dest $script:EnvRoot
        if (-not (Test-Path $flutterBat)) { throw 'Flutter 解压后没找到 flutter\bin\flutter.bat，安装失败。' }
        $v = (& $flutterBat --version 2>&1 | Out-String)
        if ($v -notmatch 'Flutter\s+3\.50\.1') { throw "Flutter 装完版本号不对：$v" }
        Add-Log 'Flutter 3.50.1 安装完成' 'ok'
    }

    # ---- 2. Java 17（Temurin） ----
    $javaHome = Join-Path $script:EnvRoot 'jdk-17'
    if (-not (Test-Path (Join-Path $javaHome 'bin\java.exe'))) {
        $zip = Join-Path $script:DownloadDir 'temurin-17-jdk.zip'
        [void](Download-File -Url $script:JdkZipUrl -Dest $zip -Name 'Java 17（Temurin）')
        $tmp = Join-Path $script:DownloadDir 'jdk-tmp'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Zip -Zip $zip -Dest $tmp
        $found = Get-ChildItem $tmp -Recurse -Filter 'java.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'bin\\java\.exe$' } | Select-Object -First 1
        if (-not $found) { throw 'JDK 解压后没找到 bin\java.exe，安装失败。' }
        $jdkDir = Split-Path (Split-Path $found.FullName -Parent) -Parent
        if (Test-Path $javaHome) { Remove-Item $javaHome -Recurse -Force }
        Move-Item $jdkDir $javaHome
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Add-Log 'Java 17 安装完成' 'ok'
    }
    else {
        Add-Log 'Java 17 已安装，跳过' 'ok'
    }

    # ---- 3. Android 命令行工具 ----
    $sdkDir = Join-Path $script:EnvRoot 'android-sdk'
    $sdkManager = Join-Path $sdkDir 'cmdline-tools\latest\bin\sdkmanager.bat'
    if (-not (Test-Path $sdkManager)) {
        $zip = Join-Path $script:DownloadDir 'commandlinetools-win-13114758_latest.zip'
        [void](Download-File -Url $script:CmdlineToolsUrl -Dest $zip -Name 'Android 命令行工具')
        $tmp = Join-Path $script:DownloadDir 'cmdline-tmp'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Zip -Zip $zip -Dest $tmp
        $latestDir = Join-Path $sdkDir 'cmdline-tools\latest'
        if (-not (Test-Path $latestDir)) { New-Item -ItemType Directory -Force -Path $latestDir | Out-Null }
        Copy-Item (Join-Path $tmp 'cmdline-tools\*') $latestDir -Recurse -Force
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $sdkManager)) { throw '命令行工具解压后没找到 sdkmanager.bat，安装失败。' }
        Add-Log 'Android 命令行工具安装完成' 'ok'
    }
    else {
        Add-Log 'Android 命令行工具已安装，跳过' 'ok'
    }

    # ---- 4. sdkmanager 装 platform-tools / platforms / build-tools ----
    Add-Log '用 sdkmanager 安装 platform-tools、platforms、build-tools…' 'info'
    $env:JAVA_HOME = $javaHome
    $env:ANDROID_HOME = $sdkDir
    $env:ANDROID_SDK_ROOT = $sdkDir
    & $sdkManager --sdk_root=$sdkDir 'platform-tools' "platforms;android-$($script:RequiredCompileSdk)" 'build-tools;36.0.0' 2>&1 |
        ForEach-Object { Add-Log $_.ToString() }
    if ($LASTEXITCODE -ne 0) { throw 'sdkmanager 安装失败（见上面日志）。请检查网络后重试。' }
    Add-Log 'platform-tools、platforms、build-tools 安装完成' 'ok'

    # ---- 5. 接受 Android 许可证 ----
    Add-Log '接受 Android 许可证…' 'info'
    1..50 | ForEach-Object { 'y' } | & $sdkManager --sdk_root=$sdkDir --licenses 2>&1 |
        ForEach-Object { Add-Log $_.ToString() }

    # ---- 6. NDK 直接下载压缩包（不走 sdkmanager，之前教训：sdkmanager 下 NDK 只有约 167KB/s） ----
    $ndkDir = Join-Path $sdkDir "ndk\$($script:RequiredNdk)"
    if (-not (Test-Path $ndkDir)) {
        $zip = Join-Path $script:DownloadDir 'android-ndk-r28c-windows.zip'
        [void](Download-File -Url $script:NdkZipUrl -Dest $zip -Name 'NDK r28c')
        $tmp = Join-Path $script:DownloadDir 'ndk-tmp'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Zip -Zip $zip -Dest $tmp
        $ndkSrc = Join-Path $tmp 'android-ndk-r28c'
        if (-not (Test-Path $ndkSrc)) { throw 'NDK 解压后没找到 android-ndk-r28c 文件夹，安装失败。' }
        $ndkParent = Join-Path $sdkDir 'ndk'
        if (-not (Test-Path $ndkParent)) { New-Item -ItemType Directory -Force -Path $ndkParent | Out-Null }
        Move-Item $ndkSrc $ndkDir
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Add-Log "NDK $($script:RequiredNdk) 安装完成" 'ok'
    }
    else {
        Add-Log "NDK $($script:RequiredNdk) 已安装，跳过" 'ok'
    }

    # ---- 7. 写用户环境变量（不用管理员权限） ----
    Set-UserEnv -Name 'ANDROID_HOME' -Value $sdkDir
    Set-UserEnv -Name 'JAVA_HOME' -Value $javaHome
    Add-UserPath -Dir (Join-Path $script:EnvRoot 'flutter\bin')
    Add-UserPath -Dir (Join-Path $sdkDir 'platform-tools')
    Add-UserPath -Dir (Join-Path $javaHome 'bin')
    Add-Log '环境变量已写入（ANDROID_HOME、JAVA_HOME、PATH），新开的窗口直接可用' 'ok'

    # ---- 8. 验收 ----
    $fv = (& $flutterBat --version 2>&1 | Out-String)
    if ($fv -notmatch 'Flutter\s+3\.50\.1') { throw '验收失败：flutter --version 不是 3.50.1。' }
    if (-not (Test-Path (Join-Path $sdkDir "platforms\android-$($script:RequiredCompileSdk)"))) { throw '验收失败：SDK Platform 37 没装上。' }
    if (-not (Test-Path $ndkDir)) { throw '验收失败：NDK 没装上。' }
    Add-Log '打包环境安装完成，可以开始打包了' 'ok'
    Set-Status '打包环境已就绪'
}

# ================= 开始打包 =================
function Start-Package {
    Add-Log '开始打包' 'step'
    Set-Status '正在打包…'

    $appName = $script:txtAppName.Text.Trim()
    $logoInput = $script:txtLogo.Text.Trim()
    $remoteDomain = $script:txtDomain.Text.Trim()
    $keystorePath = $script:txtKeystore.Text.Trim()
    $keystorePassword = $script:txtPassword.Text
    $sourceInput = $script:txtSource.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($appName)) { throw '应用名不能为空。' }
    if ([string]::IsNullOrWhiteSpace($remoteDomain)) { throw '远程配置域名不能为空。' }
    if ($remoteDomain -match '^https?://') { throw '远程配置域名只填域名本身，不要带 https://，比如 cc.jiankong.cf。' }
    if ([string]::IsNullOrWhiteSpace($keystorePath)) { throw '请选 keystore 文件。' }
    if (-not (Test-Path $keystorePath)) { throw "找不到 keystore 文件：$keystorePath" }
    if ([string]::IsNullOrWhiteSpace($keystorePassword)) { throw '请填 keystore 密码。' }

    # ---- 环境定位 ----
    $flutterExe = Get-FlutterPath
    if (-not $flutterExe) { throw '没找到 Flutter。请先点“一键安装打包环境”，或把 Flutter 的 bin 目录加到 PATH。' }
    $sdkDir = Get-AndroidSdkDir
    if (-not $sdkDir) { throw '没找到 Android SDK。请先点“一键安装打包环境”。' }
    $javaHome = Get-JavaHome
    if (-not $javaHome) { throw '没找到 Java 17。请先点“一键安装打包环境”。' }
    if (-not (Test-Path (Join-Path $sdkDir "ndk\$($script:RequiredNdk)"))) {
        throw "没找到 NDK $($script:RequiredNdk)。请点“一键安装打包环境”装好再打包。"
    }
    $env:ANDROID_HOME = $sdkDir
    $env:ANDROID_SDK_ROOT = $sdkDir
    $env:JAVA_HOME = $javaHome
    $env:GRADLE_OPTS = '-Djava.net.preferIPv4Stack=true'
    $env:JAVA_OPTS = '-Djava.net.preferIPv4Stack=true'
    Add-Log "Flutter：$flutterExe" 'ok'
    Add-Log "Android SDK：$sdkDir" 'ok'

    # ---- 源码 ----
    $workDir = Get-Location
    if ([string]::IsNullOrWhiteSpace($sourceInput)) {
        $sourceDir = Join-Path $workDir 'zhexuexi-client'
        if ((Test-Path (Join-Path $sourceDir '.git')) -and (Test-Path (Join-Path $sourceDir 'apps\flutter_client'))) {
            Add-Log "源码目录已存在，从仓库更新：$sourceDir" 'info'
            Push-Location $sourceDir
            try {
                & git pull 2>&1 | ForEach-Object { Add-Log $_.ToString() }
                if ($LASTEXITCODE -ne 0) { throw 'git pull 失败：请检查网络，或手动进目录跑 git pull。' }
            }
            finally { Pop-Location }
        }
        else {
            Add-Log "克隆仓库到：$sourceDir" 'info'
            & git clone $script:RepoUrl $sourceDir 2>&1 | ForEach-Object { Add-Log $_.ToString() }
            if ($LASTEXITCODE -ne 0) { throw 'git clone 失败：请检查网络，或确认仓库地址能打开。' }
        }
    }
    else {
        $sourceDir = $sourceInput
        if (-not (Test-Path (Join-Path $sourceDir 'apps\flutter_client'))) {
            throw "这个目录下没有 apps\flutter_client，不是客户端源码目录：$sourceDir"
        }
        Add-Log "用已有的源码目录：$sourceDir" 'info'
    }
    $appDir = Join-Path $sourceDir 'apps\flutter_client'
    $brandFile = Join-Path $appDir 'assets\brand.json'
    $logoFile = Join-Path $appDir 'assets\logo\logo.png'
    $remoteConfigFile = Join-Path $appDir 'lib\services\remote_config_service.dart'
    foreach ($f in @($brandFile, $logoFile, $remoteConfigFile)) {
        if (-not (Test-Path $f)) { throw "源码不完整，缺文件：$f" }
    }
    Add-Log "源码就绪：$sourceDir" 'ok'

    # ---- 品牌注入：应用名 ----
    $brandText = [IO.File]::ReadAllText($brandFile, [Text.Encoding]::UTF8)
    $escapedName = $appName.Replace('\', '\\').Replace('"', '\"')
    $newBrandText = [regex]::Replace(
        $brandText,
        '"app_name"\s*:\s*"[^"]*"',
        "`"app_name`":`"$escapedName`"",
        [System.Text.RegularExpressions.RegexOptions]::None,
        [TimeSpan]::FromSeconds(5)
    )
    if ($newBrandText -eq $brandText) { throw 'brand.json 里没找到 app_name，没法写入应用名。' }
    [IO.File]::WriteAllText($brandFile, $newBrandText, (New-Object System.Text.UTF8Encoding($false)))
    Add-Log "应用名已写入 brand.json：$appName" 'ok'

    # ---- 品牌注入：Logo ----
    if ($logoInput) {
        $tmpLogo = Join-Path $env:TEMP ('zhexuexi-logo-' + [Guid]::NewGuid().ToString('N') + '.png')
        if ($logoInput -match '^https?://') {
            Add-Log "下载 Logo：$logoInput" 'info'
            try {
                Invoke-WebRequest -Uri $logoInput -OutFile $tmpLogo -UseBasicParsing -ErrorAction Stop
            }
            catch {
                throw "Logo 下载失败：$($_.Exception.Message)"
            }
        }
        else {
            if (-not (Test-Path $logoInput)) { throw "找不到这个 Logo 文件：$logoInput" }
            Copy-Item $logoInput $tmpLogo -Force
        }
        $iconRegenerated = $false
        $hasPython = Test-Command 'python'
        if ($hasPython) {
            $resizePy = Join-Path $env:TEMP ('zhexuexi-resize-' + [Guid]::NewGuid().ToString('N') + '.py')
            @'
import sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGB")
im = im.resize((1600, 1600), Image.LANCZOS)
im.save(dst, "PNG")
print("resized to 1600x1600")
'@ | Set-Content -Path $resizePy -Encoding ascii
            try {
                & python $resizePy $tmpLogo $logoFile 2>&1 | ForEach-Object { Add-Log $_.ToString() }
                if ($LASTEXITCODE -eq 0) {
                    Add-Log 'Logo 已替换并缩放到 1600x1600' 'ok'
                    Push-Location $appDir
                    try {
                        & python tool/generate_launcher_icons.py 2>&1 | ForEach-Object { Add-Log $_.ToString() }
                        if ($LASTEXITCODE -eq 0) { $iconRegenerated = $true }
                    }
                    finally { Pop-Location }
                }
                else {
                    Add-Log 'Logo 缩放失败，改用原图直接替换（启动器图标不重新生成）。' 'warn'
                    Copy-Item $tmpLogo $logoFile -Force
                }
            }
            catch {
                Add-Log "Logo 处理出错（$($_.Exception.Message)），改用原图直接替换（启动器图标不重新生成）。" 'warn'
                Copy-Item $tmpLogo $logoFile -Force
            }
            finally {
                Remove-Item $resizePy -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Copy-Item $tmpLogo $logoFile -Force
            Add-Log '没装 Python，Logo 已替换，但启动器图标没有重新生成（仍用旧图标）。' 'warn'
        }
        Remove-Item $tmpLogo -Force -ErrorAction SilentlyContinue
        if ($iconRegenerated) { Add-Log '启动器图标已按新 Logo 重新生成（5 个密度）' 'ok' }
    }
    else {
        Add-Log 'Logo 用仓库自带的，不动' 'ok'
    }

    # ---- 品牌注入：远程配置域名（只换 workerConfigUrl 这一行） ----
    if ($remoteDomain -ne $script:DefaultRemoteDomain) {
        $rcText = [IO.File]::ReadAllText($remoteConfigFile, [Text.Encoding]::UTF8)
        $newRcText = [regex]::Replace(
            $rcText,
            "(workerConfigUrl\s*=\s*'https://)[^']+(/client-config\.json')",
            "`${1}$remoteDomain`$2"
        )
        if ($newRcText -eq $rcText) { throw 'remote_config_service.dart 里没找到 workerConfigUrl，没法写入远程配置域名。' }
        [IO.File]::WriteAllText($remoteConfigFile, $newRcText, (New-Object System.Text.UTF8Encoding($false)))
        Add-Log "远程配置域名已写入：https://$remoteDomain/client-config.json" 'ok'
    }
    else {
        Add-Log "远程配置域名用默认：https://$($script:DefaultRemoteDomain)/client-config.json" 'ok'
    }

    # ---- 签名配置 ----
    $keystoreFull = (Resolve-Path $keystorePath).Path
    $keyPropsFile = Join-Path $appDir 'android\key.properties'
    $storeFileValue = $keystoreFull.Replace('\', '/')
    $keyPropsContent = @"
storePassword=$keystorePassword
keyPassword=$keystorePassword
keyAlias=zhexuexi
storeFile=$storeFileValue
"@
    [IO.File]::WriteAllText($keyPropsFile, $keyPropsContent, (New-Object System.Text.UTF8Encoding($false)))
    Add-Log 'key.properties 已生成（在 android 目录下，不进仓库）' 'ok'

    # ---- 打包 ----
    Add-Log '跑 flutter build apk --release --split-per-abi（可能要几分钟）…' 'info'
    Set-Status '正在打包 APK…'
    Push-Location $appDir
    try {
        & $flutterExe pub get 2>&1 | ForEach-Object { Add-Log $_.ToString() }
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败：请检查网络，或看上面输出的报错。' }
        & $flutterExe build apk --release --split-per-abi 2>&1 | ForEach-Object { Add-Log $_.ToString() }
        if ($LASTEXITCODE -ne 0) {
            throw @'
flutter build apk 失败。
  常见原因：
  - NDK 没装对：确认 Android SDK 里有 ndk/28.2.13676358；
  - 依赖下不下来：检查网络，或等一会儿再跑一次；
  - 签名报错：确认 keystore 密码输对了、key.properties 里 alias 是 zhexuexi。
  上面输出的最后几行就是具体报错，按它修。
'@
        }
    }
    finally { Pop-Location }
    Add-Log '打包完成' 'ok'

    # ---- 结果 ----
    $apkDir = Join-Path $appDir 'build\app\outputs\flutter-apk'
    $apks = @(
        @{ File = 'app-arm64-v8a-release.apk'; Label = 'arm64（小米等绝大多数安卓手机用这个）' }
        @{ File = 'app-armeabi-v7a-release.apk'; Label = 'armv7（老手机）' }
        @{ File = 'app-x86_64-release.apk'; Label = 'x86_64（模拟器）' }
    )
    $resultLines = @()
    $foundAny = $false
    foreach ($a in $apks) {
        $p = Join-Path $apkDir $a.File
        if (Test-Path $p) {
            $foundAny = $true
            $size = Format-MB -Bytes (Get-Item $p).Length
            $sha = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
            if ($a.File -like '*arm64*') {
                $resultLines += "★ arm64：$p"
                $resultLines += "  大小：$size，SHA-256：$sha"
                Add-Log "★ arm64：$p（$size）" 'ok'
            }
            else {
                $resultLines += "$($a.Label)：$p"
                $resultLines += "  大小：$size，SHA-256：$sha"
                Add-Log "$($a.Label)：$p（$size）" 'info'
            }
        }
        else {
            Add-Log "没找到 $($a.File)（$($a.Label)）" 'warn'
        }
    }
    if (-not $foundAny) { throw "打包输出目录里一个 APK 都没有：$apkDir" }
    $script:resultBox.Text = ($resultLines -join "`r`n")
    Add-Log '全部完成。把 arm64 那个 APK 传到手机上安装即可。' 'ok'
    Set-Status '打包完成'
}

# ================= 界面 =================
$form = New-Object System.Windows.Forms.Form
$form.Text = '哲学系客户端打包工具'
$form.ClientSize = New-Object System.Drawing.Size(680, 830)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = '哲学系客户端打包工具'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei', 14, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20, 12)
$title.Size = New-Object System.Drawing.Size(640, 30)
$form.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = '填好信息 → 点“开始打包”，在本机打出 release APK。第一次用请先点“一键安装打包环境”。'
$sub.Location = New-Object System.Drawing.Point(20, 44)
$sub.Size = New-Object System.Drawing.Size(640, 20)
$sub.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($sub)

function New-RowLabel {
    param([string]$Text, [int]$Y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point(20, $Y)
    $l.Size = New-Object System.Drawing.Size(105, 22)
    $l.TextAlign = 'MiddleRight'
    $form.Controls.Add($l)
    return $l
}

function New-TextBox {
    param([int]$Y, [int]$Width = 330, [string]$Text = '')
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(135, $Y)
    $t.Size = New-Object System.Drawing.Size($Width, 24)
    $t.Text = $Text
    $form.Controls.Add($t)
    return $t
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 100, [int]$Height = 26)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($Width, $Height)
    $form.Controls.Add($b)
    return $b
}

# 应用名
[void](New-RowLabel -Text '应用名：' -Y 76)
$script:txtAppName = New-TextBox -Y 74 -Text $script:DefaultAppName

# Logo
[void](New-RowLabel -Text 'Logo：' -Y 110)
$script:txtLogo = New-TextBox -Y 108
$btnLogo = New-Button -Text '选择文件…' -X 475 -Y 107 -Width 90
$btnLogo.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = '选择 Logo 图片'
    $d.Filter = '图片文件 (*.png;*.jpg;*.jpeg;*.webp)|*.png;*.jpg;*.jpeg;*.webp|所有文件 (*.*)|*.*'
    if ($d.ShowDialog() -eq 'OK') { $script:txtLogo.Text = $d.FileName }
})
$hintLogo = New-Object System.Windows.Forms.Label
$hintLogo.Text = '填本地图片路径或图片网址，空着用仓库自带的 Logo。'
$hintLogo.Location = New-Object System.Drawing.Point(135, 134)
$hintLogo.Size = New-Object System.Drawing.Size(430, 18)
$hintLogo.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($hintLogo)

# 远程配置域名
[void](New-RowLabel -Text '远程配置域名：' -Y 160)
$script:txtDomain = New-TextBox -Y 158 -Text $script:DefaultRemoteDomain

# keystore
[void](New-RowLabel -Text 'keystore 文件：' -Y 194)
$script:txtKeystore = New-TextBox -Y 192
$btnKeystore = New-Button -Text '选择文件…' -X 475 -Y 191 -Width 90
$btnKeystore.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = '选择 keystore 文件'
    $d.Filter = 'keystore 文件 (*.keystore)|*.keystore|所有文件 (*.*)|*.*'
    if ($d.ShowDialog() -eq 'OK') { $script:txtKeystore.Text = $d.FileName }
})
$defaultKs = Join-Path (Get-Location) 'zhexuexi-release.keystore'
if (Test-Path $defaultKs) { $script:txtKeystore.Text = $defaultKs }
elseif (Test-Path (Join-Path $PSScriptRoot 'zhexuexi-release.keystore')) {
    $script:txtKeystore.Text = Join-Path $PSScriptRoot 'zhexuexi-release.keystore'
}

# keystore 密码
[void](New-RowLabel -Text 'keystore 密码：' -Y 228)
$script:txtPassword = New-TextBox -Y 226
$script:txtPassword.UseSystemPasswordChar = $true

# 源码位置
[void](New-RowLabel -Text '源码位置：' -Y 262)
$script:txtSource = New-TextBox -Y 260
$btnSource = New-Button -Text '选择目录…' -X 475 -Y 259 -Width 90
$btnSource.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = '选择已有的客户端源码目录（里面要有 apps\flutter_client）'
    if ($d.ShowDialog() -eq 'OK') { $script:txtSource.Text = $d.SelectedPath }
})
$hintSrc = New-Object System.Windows.Forms.Label
$hintSrc.Text = '空着：克隆到当前目录下的 zhexuexi-client；已有目录会被更新。'
$hintSrc.Location = New-Object System.Drawing.Point(135, 286)
$hintSrc.Size = New-Object System.Drawing.Size(430, 18)
$hintSrc.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($hintSrc)

# 按钮
$btnInstall = New-Button -Text '一键安装打包环境' -X 20 -Y 316 -Width 200 -Height 40
$btnInstall.BackColor = [System.Drawing.Color]::LightBlue
$btnBuild = New-Button -Text '开始打包' -X 240 -Y 316 -Width 180 -Height 40
$btnBuild.BackColor = [System.Drawing.Color]::LightGreen
$btnBuild.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)

# 日志
$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = '进度日志：'
$logLabel.Location = New-Object System.Drawing.Point(20, 370)
$logLabel.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($logLabel)

$btnClearLog = New-Button -Text '清空日志' -X 565 -Y 366 -Width 90 -Height 24
$btnClearLog.Add_Click({ $script:logBox.Clear() })

$script:logBox = New-Object System.Windows.Forms.RichTextBox
$script:logBox.Location = New-Object System.Drawing.Point(20, 394)
$script:logBox.Size = New-Object System.Drawing.Size(640, 250)
$script:logBox.Multiline = $true
$script:logBox.ReadOnly = $true
$script:logBox.ScrollBars = 'Vertical'
$script:logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:logBox.WordWrap = $false
$form.Controls.Add($script:logBox)

# 结果
$resLabel = New-Object System.Windows.Forms.Label
$resLabel.Text = '打包结果：'
$resLabel.Location = New-Object System.Drawing.Point(20, 654)
$resLabel.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($resLabel)

$script:resultBox = New-Object System.Windows.Forms.TextBox
$script:resultBox.Location = New-Object System.Drawing.Point(20, 678)
$script:resultBox.Size = New-Object System.Drawing.Size(640, 100)
$script:resultBox.Multiline = $true
$script:resultBox.ReadOnly = $true
$script:resultBox.ScrollBars = 'Vertical'
$script:resultBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:resultBox.WordWrap = $false
$form.Controls.Add($script:resultBox)

$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.Text = '就绪'
$script:statusLabel.Location = New-Object System.Drawing.Point(20, 792)
$script:statusLabel.Size = New-Object System.Drawing.Size(640, 20)
$script:statusLabel.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($script:statusLabel)

# ---- 按钮事件 ----
$btnInstall.Add_Click({
    $btnInstall.Enabled = $false
    $btnBuild.Enabled = $false
    try {
        Install-Environment
        [System.Windows.Forms.MessageBox]::Show('打包环境安装完成，可以开始打包了。', '完成', 'OK', 'Information') | Out-Null
    }
    catch {
        Add-Log "安装失败：$($_.Exception.Message)" 'error'
        Set-Status '安装失败'
        [System.Windows.Forms.MessageBox]::Show("安装失败：$($_.Exception.Message)", '失败', 'OK', 'Error') | Out-Null
    }
    finally {
        $btnInstall.Enabled = $true
        $btnBuild.Enabled = $true
    }
})

$btnBuild.Add_Click({
    $btnInstall.Enabled = $false
    $btnBuild.Enabled = $false
    $script:resultBox.Clear()
    try {
        Start-Package
        [System.Windows.Forms.MessageBox]::Show('打包完成，三个分包的信息在下面“打包结果”里，arm64 那个传到手机上安装即可。', '完成', 'OK', 'Information') | Out-Null
    }
    catch {
        Add-Log "打包失败：$($_.Exception.Message)" 'error'
        Set-Status '打包失败'
        [System.Windows.Forms.MessageBox]::Show("打包失败：$($_.Exception.Message)", '失败', 'OK', 'Error') | Out-Null
    }
    finally {
        $btnInstall.Enabled = $true
        $btnBuild.Enabled = $true
    }
})

Add-Log '哲学系客户端打包工具已打开。第一次用请先点“一键安装打包环境”。' 'info'
Add-Log "打包环境目录：$($script:EnvRoot)" 'info'
[void]$form.ShowDialog()
