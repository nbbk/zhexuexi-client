# flutter_sing_box 本地补丁版（基于上游 3.1.0）

> 本目录是 `flutter_sing_box` 3.1.0 的本地 fork，只改 Android 侧取 Activity
> 的方式；Dart API、iOS、Windows 与其它方法一律不动。
> 上游仓库 `github.com/clash-sing/flutter_sing_box` 的 master（2026-11-25 核对）
> 与 pub.dev 最新版（3.1.0，2026-11-01 发布）仍是旧写法，没有修这个问题，
> 所以先本地 fork；上游以后修了，再评估切回官方版。

## 触发的 bug

小米真机（新版 APK，main 65473362）上：App 能打开、首页/节点/流量都显示，
点大开关启动时底部报错：

```
启动失败：PlatformException(NO_ACTIVITY, 无法获取Activity实例, null, null)
```

报错来自插件原生侧 `FlutterSingBoxPlugin.kt`：`init`（第 56 行）与
`startVpn`（第 63 行）在 `activityBinding?.activity` 为 null 时直接报
`NO_ACTIVITY`。`activityBinding` 只在 `onAttachedToActivity` 里赋值，
在 `onDetachedFromActivity` /
`onDetachedFromActivityForConfigChanges` 里置 null。

## 根因（已核实到 Flutter 3.50.1 嵌入层字节码）

- 不是启动竞态：反编译本地 Flutter 3.50.1 的 `flutter.jar` 核实，
  `FlutterActivityAndFragmentDelegate.onAttach`（即 `onCreate`）里先
  `attachToActivity`、再 `configureFlutterEngine`（注册插件），
  `FlutterEngineConnectionRegistry.add()` 对已挂上 Activity 的引擎会立即
  补调 `onAttachedToActivity`；Dart 入口在 `onStart` 才跑。所以正常流程下
  Dart 调 `init` 时 Activity 一定已挂好。
- 真机上是设备侧的 detach：小米（MIUI）在首次启动时做显示/字体/深色等
  配置调整，Activity 走了一次 detach，插件的绑定被置 null 后没在点启动前
  恢复；插件本身没有任何重试或兜底，于是 `init` 与 `startVpn` 双双报
  `NO_ACTIVITY`。App 侧 `main.dart` 的 `_initCore()` 还把 `init` 的错吞了，
  问题直到点启动才暴露。
- 旧版里这个错被 MMKV 错盖住了：`start()` 先调 `_usingConfigPath()`
  （ProfileStorage）抛 `StateError("forget initialize MMKV first?")`，
  还没走到 `startVpn()`；MMKV 修好后 NO_ACTIVITY 才露出来。

## 补丁内容（见 `PATCH(zhexuexi)` 标记；2026-11-25 闪退修复后不再是
“只改一个 Kotlin 文件”，见下文“真机闪退”一节）

`android/src/main/kotlin/com/clashsing/flutter_sing_box/FlutterSingBoxPlugin.kt`：

1. **`init` 不再要 Activity**：`SingBoxConnector.connect()` 只拿 Context
   去 `bindService`，本来就不需要 Activity。改走 `onAttachedToEngine`
   里存下的 Application Context，`init` 永远不再报 NO_ACTIVITY。
2. **`startVpn` 三档回落**：有 Activity 走原流程（需授权弹系统 VPN
   授权框，已授权直接起服务）；无 Activity 时先调
   `VpnService.prepare(applicationContext)`，返回 null 说明已授权，
   直接 `BoxService.start()`；未授权则把请求挂起，等
   `onAttachedToActivity` / `onReattachedToActivityForConfigChanges`
   时 `drainPendingStart()` 再弹授权框；20 秒等不到就按 NO_ACTIVITY
   失败收尾（Dart 侧不一直挂着）。
3. **MainActivity 直接推 Activity 兜底**：插件新增
   `setFallbackActivity` / `clearFallbackActivity`，
   `MainActivity.configureFlutterEngine` 里把当前 Activity 推给插件；
   `currentActivity()` 优先 ActivityAware 绑定，没有时用这个兜底。
   Activity 重建时新实例先 set、旧实例后 onDestroy，identity 比对避免
   旧实例误清新实例的。正常设备上它与 ActivityAware 指向同一个
   Activity，互为冗余，无害。
4. **挂起请求永不丢**：二次 `startVpn` 在已有请求等待时报 `VPN_BUSY`
   （避免两个 Result 打架）；`onDetachedFromActivity`（Activity 彻底走）
   时把挂起的请求失败收尾；配置变更 detach 不动挂起的请求，等重挂上。
5. 其它方法（`stopVpn` / `serviceReload` / `setClashMode` /
   `selectOutbound` / `setGroupExpand` / `urlTest` /
   `getSingBoxVersion` / `onActivityResult`）与上游 3.1.0 逐字节一致。
   （2026-11-25 闪退修复是例外：见下文“真机闪退”一节，那次只加了
   防护与日志，没改启动语义。）

`MainActivity.kt`（App 侧）：`configureFlutterEngine` 里取插件实例并
`setFallbackActivity(this)`；`onDestroy` 里 identity 比对清掉。

`AndroidManifest.xml`（App 侧，加固）：`configChanges` 补上
`colorMode|mcc|mnc`，这类变更不再重建 Activity，减少 detach 窗口。

## 真机闪退（2026-11-25，带 NO_ACTIVITY 补丁的新包 a96e1003）

现象：点大开关第一次弹系统 VPN 授权框，点允许后 App 直接闪退；
再打开 App 点开关，直接闪退，连授权框都不弹。
沙箱无真机/模拟器，无法复现，以下按代码核实。

### 已核实的前提

- 两次点按的共同点是 `startVpnService → BoxService.start()`：第一次授权
  返回后走它（`onActivityResult → startVpnService`），第二次已授权
  （`VpnService.prepare` 返回 null）直接走它。
- 服务跑在独立进程（本次构建的合并清单已核对：
  `build/app/intermediates/merged_manifest/release/.../AndroidManifest.xml`
  里 `VPNService` 带 `android:process=":remote"`；`ProxyService` 未在任何
  清单里注册）。所以单是 `:remote` 崩掉不会直接杀 UI，
  UI 闪退一定另有 UI 进程内的未捕获异常/原生崩溃（或系统杀进程）。
- Dart 侧没有杀进程的路径（已逐项核对，不用改 Dart）：
  `CoreService.start()` 的错全被首页 `_onToggle` 接住弹 SnackBar；
  `proxyStateStream` 有 `handleError` 转 `ProxyStopped`；
  `ProxyState.fromName` 未知值兜底回 `stopped`；
  `CoreService.init` 的监听里 `switch` 穷尽、`dispose` 先取消订阅；
  Clash API 流的错误走 `onError` 回“—”。TUN 默认关，配置里无 tun
  入站，`VPNService.openTun` 本次不跑。
- MMKV 契约 Dart 与原生一致（键 `profile_` / `selected_profile_id` /
  `using_config`、Profile JSON 形状一致），`getSelectedProfile` 失败
  只会走 `stopAndAlert(EmptyConfiguration)`，不会杀进程。
- `drainPendingStart` 与 `onActivityResult` 不会双消费 Result：
  所有 pending 操作都在主线程，`getAndSet` 原子，超时任务在 drain
  时取消；`onAttachedToActivity` / `onReattached…` 都是先
  `addActivityResultListener` 再 drain。
- 二次启动本身不冲突：`BoxService.onStartCommand` 有
  `status != Stopped` 守卫；命令服务是 unix socket
  （`<basePath>/command.sock`），启动前 `os.Remove`，无残留端口冲突；
  若 `:remote` 还活着且已 Started，二次 `startForegroundService`
  只是 early return。

### 根因 1（最可能）：启动链上有未捕获异常直达主线程的缺口

`startVpnService` 只 `catch (e: Exception)`，不 catch `Error`
（`UnsatisfiedLinkError` / `NoClassDefFoundError` 等）；
`requestVpnWithActivity`（`VpnService.prepare` +
`activity.startActivityForResult`）和 `onActivityResult` 全程没有任何
try/catch；`BoxService.start()` 里还用 `runBlocking {
withContext(Dispatchers.IO) { Intent(...) } }` 在主线程上阻塞。
主线程上任何未捕获的异常/Error 都会从 Flutter 引擎的 Activity
结果分发一路穿透，直接杀进程——两次点按都经过这里。
补丁引入的放大器：`currentActivity()` 可能返回已销毁的 fallback
Activity（MIUI 配置变更 detach 后、重建前，`activityBinding` 为 null
而 `fallbackActivity` 还是旧实例；`onDetachedFromActivity` 也不清
fallback）；对已销毁 Activity 调 `startActivityForResult` 会抛异常且
没被 catch。且 `requestVpnWithActivity` 先
`pendingStartVpnResult.set(result)` 再调 `startActivityForResult`——
一旦后者抛了，pending 里的 Result 永远泄漏（这条路没配 20 秒超时），
下次点开关直接报 `VPN_BUSY`。

### 根因 2（次因）：`:remote` 死亡经未加保护的连接器协程反噬 UI 进程

补丁之前这条启动链在真机上从未真正跑通过（先被 MMKV 错盖住，再被
NO_ACTIVITY 拦住），`:remote` 内任何未捕获的崩溃都是首次暴露：
libbox 1.14 的 Go 侧 `debug.SetPanicOnFault(true)`，panic 即进程死；
`VPNService.onCreate → PluginManager.init → Libbox.setup`、
`BoxService.onStartCommand → startCommandServer / startService →
startForeground` 任一步原生崩溃都会让绑定死亡。而 UI 进程
`SingBoxConnector` 里接死亡通知的代码全无防护：
`MyServiceConnection.onServiceConnected` 在 `SupervisorJob` 协程里裸调
AIDL `registerCallback` / `getStatus`，远端刚死就抛
`RemoteException` / `DeadObjectException`，协程未捕获异常走默认
handler 杀进程；`ServiceCallback.onServiceStatusChanged` 的协程里
`connectClient()` 的 Go 对象构造在 try/catch 之外，Go 侧一抛同样直达
协程未捕获处理；`onBindingDied → connect() → bindService` 无节流，
远端崩溃循环时会反复重建，加大撞上上面窗口的概率。

### 本次修复（只加防护与日志，不改启动语义）

`FlutterSingBoxPlugin.kt`：`startVpnService` 改 catch `Throwable` 并记
Log；`requestVpnWithActivity` 加 `isFinishing/isDestroyed` 守卫，
`prepare` 与 `startActivityForResult` 各包 try/catch，拉框失败时用
`compareAndSet` 清掉刚设的 pending；无 Activity 分支的
`VpnService.prepare(applicationContext)` 也包 try/catch。
`BoxService.kt`：`start()` 删掉多余的 `runBlocking +
withContext(Dispatchers.IO)`（构造 Intent 不需要 IO 线程），直接构造；
`stopService(isRestart)` 里的 `start()` 与 `commandServer.close()` 各包
住（它们跑在无保护的 `GlobalScope` 协程里）。
`SingBoxConnector.kt`：`onServiceConnected` 的 AIDL 调用、
`onServiceStatusChanged` / `onServiceAlert` 的协程体、四路
CommandClient 回调（status/group/clashMode/log）的协程体全部包
try/catch `Throwable` 并记 Log；`onBindingDied` 加节流——5 秒内连续死
3 次以上就停止重建绑定并向 Dart 侧报一次错。
`CommandClient.kt`（utils）：Go 对象构造移进 try/catch 并放宽到
`Throwable`。
`ProxyService.kt` + 插件 `AndroidManifest.xml`（潜在问题，非本次主因，
顺手修）：`ProxyService` 之前未在任何清单里注册，且 `onCreate` 没调
`PluginManager.init`（与 `VPNService` 不一致）；一旦 MMKV 里
`serviceMode` 被写成 `normal`，每次启动都会失败。现补注册（主进程，
与上游 SFA 一致）并在 `onCreate` 里调 `PluginManager.init(this)`。

### 待真机验证（沙箱复现不了）

下次发包后若还闪退，抓这两份日志再定位，不要只凭现象猜：
`adb logcat -d | grep -E "FlutterSingBoxPlugin|BoxService|SingBoxConnector|CommandClient|FATAL"`，
以及 libbox 的崩溃文件（`Libbox.setup` 把 stderr 重定向到
`getExternalFilesDir(null)/CrashReport-.log`）。

上游发布修了 NO_ACTIVITY 的版本（init 不硬要 Activity，或 startVpn
有挂起/重试）后，删掉本目录与 `pubspec.yaml` 里的
`dependency_overrides`，跑 `flutter pub get` + 全量测试 + 真机复测，
确认启动正常再切。

## 真机启动 VPN_ERROR（2026-11-26，小米，6cc867ca 版）

现象：不闪退了，开关关着点测速能出延迟（直连 TCP 探测已生效），
但点大开关底部报：

```
启动失败：PlatformException(VPN_ERROR, 启动VPN服务失败:
com.clashsing.flutter_sing_box.utils.SettingsManager, null, null)
```

这次没弹 VPN 授权框（上版已允许过），开关仍是“静候连接”。

### 根因（已核实到字节码与第三方源码，不是猜测）

Java 侧 MMKV 从未被初始化过，`SettingsManager` 类在首次访问时
初始化失败被永久毒化，之后每次访问只剩 `NoClassDefFoundError`，
其 message 恰好就是类名——与截图逐字相符。证据链：

1. `startVpnService()` 当时只传 `t.message`
   （`FlutterSingBoxPlugin.kt`），截图第二行就是 `t.message` 原值。
   一个异常的 message 恰好等于一个类的全限定名，最吻合
   `NoClassDefFoundError`。
2. 两段式行为已用 JDK 实测验证：类静态初始化首次失败抛
   `ExceptionInInitializerError`（message 为 null，cause 是原异常），
   此后每次访问都抛 `NoClassDefFoundError`。HotSpot 的 message 是
   `Could not initialize class X`，而 Android ART 的 message 就是
   类名本身，与截图一致。所以截图这次一定是第二次及以后的访问；
   第一次访问（同进程内第一次点开关）抛的是
   `ExceptionInInitializerError` 并把类毒化了。
3. 首次失败的原异常已定位：`SettingsManager` 有两个急切 val
   （`dynamicNotification`、`disableMemoryLimit`），对象初始化时就读
   `mmkv`；`mmkv` 是 lazy，调 `MMKV.mmkvWithID`；反编译
   mmkv-2.4.3-runtime.jar 核实，`mmkvWithID` 先查 Java 包装类的
   静态 `rootDir`，为 null 即抛
   `IllegalStateException("You should Call MMKV.initialize() first.")`。
4. Java 侧 `rootDir` 为 null 是必然的：全仓 grep，App 与插件代码里
   没有任何一处调 Java 的 `MMKV.initialize()`（只有 fork 的 example
   应用调过，不发货）；`PluginManager.init()` 只调了两次
   `mmkvWithID`，没调 initialize；Dart 的 `MMKV.initialize()` 只调
   FFI `mmkvInitialize_v2`（mmkv_android-2.4.3 源码已核），
   不置 Java 静态字段；Dart 包全仓 grep 不到任何一次对 Java
   `initializeMMKV` 方法通道的调用；`MMKVPlugin.onAttachedToEngine`
   也只注册 channel、不初始化。main.dart 旧注释称“Dart 初始化能
   覆盖两边”是错的，已更正。
5. 完整的启动时序（已核 GeneratedPluginRegistrant 与 Flutter 3.50.1
   的 flutter.jar）：插件注册顺序是 MMKVPlugin 在前、
   FlutterSingBoxPlugin 在后；`FlutterSingBoxPlugin.onAttachedToEngine`
   里先设 channel、再调 `PluginManager.init()`，后者抛出的
   `IllegalStateException` 被 `FlutterEngineConnectionRegistry.add`
   的 `catch (Throwable)` 接住记日志、App 继续跑，但
   `onAttachedToEngine` 里 `PluginManager.init()` 之后的两行
   （`applicationContext` 赋值、`singBoxConnector` 创建）没跑到，
   连接器一直是 null，Dart 的 `init()` 调 `connect()` 是空操作、
   静默成功——所以首页/节点/测速（全走 Dart 侧 FFI MMKV）都正常，
   服务从未真正绑上，直到点开关走 `BoxService.start()` 才撞上
   已毒化的 `SettingsManager`。`:remote` 进程同理：
   `VPNService.onCreate → PluginManager.init` 一样会抛。
6. 还有一个坑：即使补调 `MMKV.initialize(context)` 也不够——
   Java 默认根目录是 `<filesDir>/mmkv`，而 Dart 默认根目录是
   `${getApplicationDocumentsPath}/mmkv`，path_provider 在 Android
   上返回 `getDir("flutter")`（即 `<filesDir>/app_flutter`），
   所以 Dart 的根目录是 `<filesDir>/app_flutter/mmkv`。
   两边目录不同，原生侧会读到空库、档案找不到。必须显式传同一目录。

### 本次修复（只修启动链，不改启动语义/测速/UI）

`PluginManager.kt`：`init()` 里在任何 `mmkvWithID` 之前先调
`MMKV.initialize(appCtx, <filesDir>/app_flutter/mmkv)`（与 Dart
同一根目录，见上面第 6 点）。UI 进程在插件注册时、`:remote`
进程在 `VPNService`/`ProxyService.onCreate` 时都走这里，
两边一次覆盖。Java 初始化与 Dart FFI 初始化共存无问题：
mmkv 官方示例（example 的 `MyApplication.kt` + `main.dart`）
就是两边都调。`BootReceiver` 未在任何清单里注册，是死代码，
不用补。

`SettingsManager.kt`：`dynamicNotification` 与
`disableMemoryLimit` 两个急切 val 改成 getter，对象初始化不再碰
MMKV；以后即使某次访问时 MMKV 没就绪，也只是当次抛错，不再毒化类。

`FlutterSingBoxPlugin.kt`：`startVpnService` 的错误上报改成带
异常类名 + cause 链（message），完整堆栈放 details；再出怪错
不用只凭一个类名猜。

`lib/main.dart`：只改注释，更正“Dart 初始化能覆盖两边”的错误说法。

### 待真机验证（沙箱复现不了）

点开关应直接起服务（已授权过，不再弹授权框），变“运行中”；
若还报错，底部提示现在会带异常类名 + cause 链，把那段文字
和 `adb logcat` 里 `FlutterSingBoxPlugin` / `BoxService` /
`FATAL` 的行一起发回。

## 真机点开关“连接失败”（2026-11-26，小米，f34561c9 版）

现象：不闪退、不报 VPN_ERROR，关着测速正常；点大开关后首页显示
“连接失败 / 轻触重试”，没有底部报错。

### 根因（已核实到代码，不是猜测）

“连接失败”只能来自原生 `proxy_state_event` 的 error 事件：
`CoreService` 收到带 `errMessage` 的 `ProxyStopped` 才置
`CoreStatus.error`（见 `singbox_core.dart` 与
`flutter_sing_box_method_channel.dart` 的 `handleError`）。
`startVpn()` 本身是同步成功的，失败发生在 `:remote` 进程里异步的
`BoxService.startService()`——第一步就查
`ProfileManager.getUsingConfig()` 拿配置文件，文件不存在就走
`stopAndAlert(Alert.EmptyConfiguration)`（message 为 null），Dart 侧
只能拼出 `PlatformException(Stopped, null, null, null)`。

为什么文件一定不存在：Dart 侧 `ProfileStorage.getUsingConfig()` 在 key
不存在时回落到文档目录，但 `setUsingConfig()` 全仓没有任何一处调用，
MMKV 里一直没有 `using_config` 这个 key；Java 侧
`decodeString("using_config", "")` 拿到空串，拼出来是相对路径
`using_config.json`。JDK 实测：`new File("", "using_config.json")`
解析成 `/using_config.json`，`exists() == false`。所以每次点开关，
`:remote` 进程都必然走 `EmptyConfiguration`——之前几版都没暴露，
是因为启动链走到这一步是第一次。

已排除的候选（代码核实）：`VPNService.onCreate` 调了
`PluginManager.init()`；Dart 与 Java 的 MMKV 根目录都是
`<filesDir>/app_flutter/mmkv`（mmkv.dart 源码与 PluginManager 注释
双向对上）；配置里没有任何 wifi 规则，`needWIFIState()` 的位置权限
分支走不到；通知的 `startForeground` 在 `startService` 开头就调了。

### 本次修复

`ProfileManager.kt`：新增 `seedUsingConfigDir()`，`PluginManager.init()`
在两进程初始化 MMKV 后调它，把缺省目录 `<filesDir>/app_flutter`
写进 MMKV（与 Dart 的回落值完全一致），`:remote` 就能读到 Dart
写的那份 `using_config.json`。

`BoxService.kt`：`EmptyConfiguration` 与 `RequestLocationPermission`
告警带上人话原因（之前无 message 的告警到 Dart 侧只剩一句没用的
`PlatformException.toString()`）；`startService` 与
`startCommandServer` 的 `catch (e: Exception)` 扩成
`catch (t: Throwable)`（`CancellationException` 重抛）并记 Log，
Error 不再静默杀掉 `:remote` 协程。

`lib/features/home/home_page.dart`：失败态下常驻显示
`CoreService.lastError` 的原因文字；转入失败态时同时弹底部提示；
旧版那种无 message 的 `PlatformException(Stopped, null…)` 显示成
“服务启动失败（没有返回原因），请重试或重新拉取订阅”。

### 待真机验证（沙箱复现不了）

点开关应直接变“运行中”（已授权过，不弹框）。若还是“连接失败”，
首页会直接显示原因文字，把那段文字和 `adb logcat` 里
`FlutterSingBoxPlugin` / `BoxService` / `FATAL` 的行一起发回。
能定论的日志特征：`SingBoxConnector: onServiceAlert: 3 ...` 即
`EmptyConfiguration`（`Alert` 枚举第 3 位）；`onServiceAlert: 5 ...`
是 `CreateService`（sing-box 运行时拒绝配置，message 里有具体原因）。

## 节点列表重构＋详情编辑（2026-11-26，用户 06:34 与 06:49 两条要求）

不在本补丁目录（改的是 App 侧 Dart 代码），记在这里备查。

`nodes_page.dart` 的 `_NodeRow`：删地址行、“使用中”徽章、明文徽章；
只留 44px 协议圆圈＋名称单行（`maxLines: 1`＋ellipsis）＋延迟芯片
＋尾部铅笔按钮（OpenContainer 进详情页，点它不选中）。卡片横向内边距
12→8、圆圈与名称间距 12→8；选中态保留边框 primary 1.5＋背景
primary 0.08；行高 64 不变。文字被裁的根因：行尾徽章＋芯片＋箭头
挤占了 Expanded 列宽度，地址行 Text 没写 `maxLines`，太长折到第二行、
超出 64 固定行高被裁掉。

新增 `lib/services/node_override_store.dart`（`flutter_secure_storage`，
key `node_overrides`，因为改动里含 UUID/密码、不写明文文件）：
覆盖键 `{subscriptionId}|{原始 dedupKey}`，存整套 18 个可编辑字段；
`Node` 加可选字段 `originDedupKey`（不参与 `dedupKey` 计算），
改地址/端口后靠它找回原始记录；`NodesNotifier` 在每次 `refresh`
拼装完列表后应用覆盖（订阅＋单节点），`updateNodeOverride` /
`clearNodeOverride` 写盘后 refresh；删改过的单节点按
`originDedupKey ?? dedupKey` 删。

`node_detail_page.dart`：同一页内切换编辑态；编辑字段有名称、地址、
端口、协议下拉（8 种）、UUID/密码、加密方式（仅 SS，空时默认
`aes-256-gcm`）、SNI、传输方式、WS 路径/Host（仅 ws）、TLS 开关、
flow（仅 VLESS）、REALITY 公钥/short id（仅 VLESS）、指纹、ALPN；
校验不合法就地提示、不保存；有覆盖时显示“已修改（非订阅原始值）”
＋“恢复默认”。

测试里修了一个真问题：`single_node_test` 的“机场订阅链接”一项因
`_applyOverrides` 读默认 `NodeOverrideStore`（真密钥库）在 testWidgets
里永久挂起（纯 Dart 测试里同样调用抛 `MissingPluginException` 被
catch 后继续跑）。修了两处：测试侧 container 补内存 fake；代码侧
`NodeOverrideStore` 每次密钥库调用加 5 秒超时（读超时按无覆盖算，
写超时抛给调用方报“保存失败，请重试”）。

遗留边界：改名后核心配置里落盘的默认选择仍是旧名对应的 tag——
但每次启动都会重新生成配置（`applyNodes` 按当前选中名取 tag），
所以下次启动默认选择应跟新名走，未在真机上验证；同内容节点
（名字不同）共用一条覆盖（`dedupKey` 本身的口径）；切离某协议后
不显示的栏位沿用原值不丢。

## 0.1.3：libbox 换成本地补丁版 AAR（2026-11-26）

### 为什么换

Xray ≥26.9.8 的 REALITY 服务端要求 ClientHello 带 X25519MLKEM768 份额，
sing-box 1.14.4 客户端发包前无条件删掉该份额，且无配置项可改；
JitPack 上 libbox 最新只有 1.14.4，没有带补丁的版本可拉。
上游 issue SagerNet/sing-box#4520 仍开着（截至 2026-11-01，1.15.0 alpha
同样删份额），等上游不是办法。改法见
`~/workspace/libbox-patch/PATCH_DESIGN.md`（A 路方案）。

### 改了哪几处

- `android/build.gradle.kts`：`implementation("com.github.singbox-android:libbox:1.14.4")`
  改为 `implementation("io.nekohasekai:libbox:1.14.4-patched")`；仓库
  声明在根 `android/build.gradle.kts` 的 `allprojects` 里
  （`maven { url = uri("../packages/flutter_sing_box/android/libs/maven-repo") }`，
  插件模块自己的 `allprojects` 声明不会进 `:app` 的解析，实测 0.1.3
  连败两次都是在这里没声明）；JitPack 仓库一并移除。其余依赖
  （mmkv、kotlinx-serialization、desugar）不动。不要改回
  `implementation(files("libs/*.aar"))`：AGP 禁止 library 模块直接
  依赖本地 .aar（`bundleReleaseAar` 的 `hasLocalAarDeps` 检查，0.1.3
  首版构建即因此失败）；走 Maven 坐标按模块解析，产出的 AAR 才完整。
- `android/libs/maven-repo/io/nekohasekai/libbox/1.14.4-patched/`：
  新增，打好补丁的 libbox 主变体（API 24，tag 含 `with_utls`，只含
  arm64——客户端只发 arm64 APK），aar＋pom＋maven-metadata-local.xml
  三件套。由 `~/workspace/zhexuexi-client-kit/tools/build-patched-libbox.sh`
  第 7 步生成，只跑它就能复现；不要把 AAR 提交进任何 git 仓。
  （第一版曾放 `android/libs/libbox.aar` 直接引用，构建失败后改成
  现在这样，旧文件已删。）
- Kotlin/Dart 代码一处不动：AAR 的 javapkg 仍是 `io.nekohasekai`，
  `io.nekohasekai.libbox.*` 的 import 全部沿用。

### AAR 里是什么（对照的上游与出处）

- sing-box v1.14.4 本体＋Tunl `reality-xray.patch` 原样（94 行）：
  握手按指纹原样发、X25519MLKEM768 份额留着不删；会话 ID 客户端版本
  写 26.3.27；无 plain X25519 份额时 auth key 回退到混合份额的
  X25519 一半；randomized hello 改 `HelloRandomizedALPN` 并强制每次
  带份额与 ALPN。来源：dbelokursky/tunl `packaging/sing-box/`。
- metacubex/utls v1.8.7 副本＋Tunl `utls-presets.patch` 原样（579 行）：
  加 Firefox 148 / Safari 26.3 hello 预设（上游 refraction-networking/utls
  的三提交 cherry-pick），`go mod edit -replace` 指过去，不改 module cache。
- 没采用 MarbleNG 的 `support_x25519mlkem768` 开关路线：上游 1.14.4 的
  `OutboundRealityOptions` 没有这个字段（见 PATCH_DESIGN §2.3），
  无条件补丁更简单，且无需改 option schema 与解析层。
- 构建：Go 1.26.10、gomobile/gobind v0.1.13、官方 `cmd/internal/build_libbox`
 （`-target android -platform android/arm64`）。补丁应用结果：
  reality 补丁 3 处 hunk 各偏移 1 行、utls 补丁无偏移；utls 自带测试通过；
  `go version -m` 核对产物显示 `metacubex/utls v1.8.7 => ../work/utls`。
- 许可证与署名：补丁内 Tunl 的注释原样保留；reality-xray.patch 是
  sing-box 代码（GPL-3.0），utls-presets.patch 是 uTLS 代码（BSD 3-Clause）。
  若以后把 fork 公开，GPL 要求提供对应源码——那是发布时的事。

### 长期

libbox fork 当正式组件养（CI 定期跟进上游发版、rebase 补丁）。
上游 #4520 修好之日 `reality-xray.patch` 即可丢弃；metacubex/utls 自带
Firefox 148 / Safari 26.3 hello 之日 `utls-presets.patch` 即可丢弃。
每次升 sing-box 大版本都要重跑 `--check`，补丁贴不上就 rebase。
