package io.nekohasekai.sfa.bg

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import com.clashsing.flutter_sing_box.R
import com.clashsing.flutter_sing_box.cs.PluginManager
import com.clashsing.flutter_sing_box.utils.ProfileManager
import com.clashsing.flutter_sing_box.utils.SettingsManager
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SystemProxyStatus
//import io.nekohasekai.sfa.Application
//import io.nekohasekai.sfa.R
//import io.nekohasekai.sfa.compose.MainActivity
import io.nekohasekai.sfa.constant.Action
import io.nekohasekai.sfa.constant.Alert
import io.nekohasekai.sfa.constant.Status
//import io.nekohasekai.sfa.database.ProfileManager
//import io.nekohasekai.sfa.database.Settings
import io.nekohasekai.sfa.ktx.hasPermission
//import io.nekohasekai.sfa.vendor.Vendor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class BoxService(private val service: Service, private val platformInterface: PlatformInterface) : CommandServerHandler {
    companion object {
        fun start() {
            // 2026-11-25 闪退修复：构造 Intent 不需要 IO 线程，之前这里
            // 用 runBlocking + withContext(Dispatchers.IO) 包着，在主线程
            // 上阻塞等 IO 线程是多余的 ANR/死锁隐患，直接构造。
            val intent = Intent(PluginManager.appContext, SettingsManager.serviceClass())
            ContextCompat.startForegroundService(PluginManager.appContext, intent)
        }

        fun stop() {
            PluginManager.appContext.sendBroadcast(
                Intent(Action.SERVICE_CLOSE).setPackage(
                    PluginManager.appContext.packageName,
                ),
            )
        }
        // 修复 ‘serviceReload’
        fun restart() {
            PluginManager.appContext.sendBroadcast(
                Intent(Action.SERVICE_RESTART).setPackage(
                    PluginManager.appContext.packageName,
                ),
            )
        }
    }

    var fileDescriptor: ParcelFileDescriptor? = null

    private val status = MutableLiveData(Status.Stopped)
    private val binder = ServiceBinder(status)
    private val notification = ServiceNotification(status, service)
    private lateinit var commandServer: CommandServer

    private var receiverRegistered = false
    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Action.SERVICE_CLOSE -> {
                        stopService()
                    }
                    // 修复 ‘serviceReload’
                    Action.SERVICE_RESTART -> {
                        stopService(isRestart = true)
                    }

                    PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            serviceUpdateIdleMode()
                        }
                    }
                }
            }
        }

    private fun startCommandServer() {
        val commandServer = CommandServer(this, platformInterface)
        commandServer.start()
        this.commandServer = commandServer
    }

    private var lastProfileName = ""

    private suspend fun startService() {
        try {
            withContext(Dispatchers.Main) {
                notification.show(lastProfileName, R.string.status_starting)
            }

//            val selectedProfileId = Settings.selectedProfile
//            if (selectedProfileId == -1L) {
//                stopAndAlert(Alert.EmptyConfiguration)
//                return
//            }
//
//            val profile = ProfileManager.get(selectedProfileId)
//            if (profile == null) {
//                stopAndAlert(Alert.EmptyConfiguration)
//                return
//            }
//
//            val content = File(profile.typed.path).readText()
            val configFile = ProfileManager.getUsingConfig()
            val profile = ProfileManager.getSelectedProfile()
            if (profile == null || !configFile.exists()) {
                // 2026-11-26 连接失败：之前这里不带 message，Dart 侧只能
                // 拼出 "PlatformException(Stopped, null, null, null)"，
                // 首页只能显示干巴巴的“连接失败”。带上人话原因。
                stopAndAlert(
                    Alert.EmptyConfiguration,
                    "没有可用配置：请先拉取订阅生成配置再启动",
                )
                return
            }
            val content = configFile.readText()
            if (content.isBlank()) {
                stopAndAlert(
                    Alert.EmptyConfiguration,
                    "配置文件是空的：请重新拉取订阅生成配置",
                )
                return
            }

            lastProfileName = profile.name
            withContext(Dispatchers.Main) {
                notification.show(lastProfileName, R.string.status_starting)
            }

            DefaultNetworkMonitor.start()

            try {
                commandServer.startOrReloadService(
                    content,
                    OverrideOptions().apply {
                        autoRedirect = SettingsManager.autoRedirect
//                        if (Vendor.isPerAppProxyAvailable() && Settings.perAppProxyEnabled) {
//                            val appList = Settings.getEffectivePerAppProxyList()
//                            if (Settings.getEffectivePerAppProxyMode() == Settings.PER_APP_PROXY_INCLUDE) {
//                                includePackage =
//                                    PlatformInterfaceWrapper.StringArray((appList + Application.application.packageName).iterator())
//                            } else {
//                                excludePackage =
//                                    PlatformInterfaceWrapper.StringArray((appList - Application.application.packageName).iterator())
//                            }
//                        }
                    },
                )
            } catch (e: Exception) {
                stopAndAlert(Alert.CreateService, e.message)
                return
            }

            if (commandServer.needWIFIState()) {
                val wifiPermission =
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                        android.Manifest.permission.ACCESS_FINE_LOCATION
                    } else {
                        android.Manifest.permission.ACCESS_BACKGROUND_LOCATION
                    }
                if (!service.hasPermission(wifiPermission)) {
                    // 2026-11-26：同上，无 message 的告警到 Dart 侧只剩
                    // 一句没用的 PlatformException.toString()。
                    stopAndAlert(
                        Alert.RequestLocationPermission,
                        "需要位置权限才能检测 Wi-Fi 状态，请在系统设置里授予位置权限后重试",
                    )
                    return
                }
            }

            status.postValue(Status.Started)
            withContext(Dispatchers.Main) {
                notification.show(lastProfileName, R.string.status_started)
            }
            notification.start()
        } catch (t: Throwable) {
            // 2026-11-26 连接失败排查：之前只 catch Exception，Error
            //（如 NoClassDefFoundError）会直接杀掉 :remote 协程、
            // 状态卡在“正在连接…”、没有任何上报；现全接住并上报。
            // CancellationException 必须重抛，不能吞协程取消。
            if (t is CancellationException) throw t
            Log.e("BoxService", "startService 失败", t)
            stopAndAlert(Alert.StartService, t.message ?: t.toString())
            return
        }
    }

    override fun serviceStop() {
        notification.close()
        status.postValue(Status.Starting)
        val pfd = fileDescriptor
        if (pfd != null) {
            pfd.close()
            fileDescriptor = null
        }
        closeService()
    }

    override fun serviceReload() {
        // 修复 ‘serviceReload’
        restart()
//        runBlocking {
//            serviceReload0()
//        }
    }

    suspend fun serviceReload0() {
//        val selectedProfileId = Settings.selectedProfile
//        if (selectedProfileId == -1L) {
//            stopAndAlert(Alert.EmptyConfiguration)
//            return
//        }
//
//        val profile = ProfileManager.get(selectedProfileId)
//        if (profile == null) {
//            stopAndAlert(Alert.EmptyConfiguration)
//            return
//        }
//
//        val content = File(profile.typed.path).readText()

        val configFile = ProfileManager.getUsingConfig()
        val profile = ProfileManager.getSelectedProfile()
        if (profile == null || !configFile.exists()) {
            stopAndAlert(Alert.EmptyConfiguration)
            return
        }
        val content = configFile.readText()
        if (content.isBlank()) {
            stopAndAlert(Alert.EmptyConfiguration)
            return
        }
        lastProfileName = profile.name
        // Bug fix：切换配置文件时，通知栏显示的配置文件名可能不是最新的
        withContext(Dispatchers.Main) {
            notification.show(lastProfileName, R.string.status_starting)
        }
        try {
            commandServer.startOrReloadService(
                content,
                OverrideOptions().apply {
                    autoRedirect = SettingsManager.autoRedirect
//                    if (Vendor.isPerAppProxyAvailable() && Settings.perAppProxyEnabled) {
//                        val appList = Settings.getEffectivePerAppProxyList()
//                        if (Settings.getEffectivePerAppProxyMode() == Settings.PER_APP_PROXY_INCLUDE) {
//                            includePackage = PlatformInterfaceWrapper.StringArray((appList + Application.application.packageName).iterator())
//                        } else {
//                            excludePackage = PlatformInterfaceWrapper.StringArray((appList - Application.application.packageName).iterator())
//                        }
//                    }
                },
            )
        } catch (e: Exception) {
            stopAndAlert(Alert.CreateService, e.message)
            return
        }

        if (commandServer.needWIFIState()) {
            val wifiPermission =
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    android.Manifest.permission.ACCESS_FINE_LOCATION
                } else {
                    android.Manifest.permission.ACCESS_BACKGROUND_LOCATION
                }
            if (!service.hasPermission(wifiPermission)) {
                stopAndAlert(Alert.RequestLocationPermission)
                return
            }
        }
    }

    override fun getSystemProxyStatus(): SystemProxyStatus? {
        val status = SystemProxyStatus()
        if (service is VPNService) {
            status.available = service.systemProxyAvailable
            status.enabled = service.systemProxyEnabled
        }
        return status
    }

    override fun setSystemProxyEnabled(isEnabled: Boolean) {
        serviceReload()
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun serviceUpdateIdleMode() {
        if (PluginManager.powerManager.isDeviceIdleMode) {
            commandServer.pause()
        } else {
            commandServer.wake()
        }
    }

    /**
     * 修复 ‘serviceReload’，添加参数 isRestart
     *
     */
    @OptIn(DelicateCoroutinesApi::class)
    private fun stopService(isRestart: Boolean = false) {
        if (status.value != Status.Started) return
        status.value = Status.Stopping
        if (receiverRegistered) {
            service.unregisterReceiver(receiver)
            receiverRegistered = false
        }
        notification.close()
        GlobalScope.launch(Dispatchers.IO) {
            val pfd = fileDescriptor
            if (pfd != null) {
                pfd.close()
                fileDescriptor = null
            }
            DefaultNetworkMonitor.stop()
            closeService()
            // 2026-11-25 闪退修复：这里跑在无保护的 GlobalScope 协程里，
            // close()（Go 侧调用）抛出来会直接杀掉服务进程。
            runCatching { commandServer.close() }.onFailure {
                Log.e("BoxService", "close command server failed", it)
            }
            SettingsManager.startedByUser = false
            withContext(Dispatchers.Main) {
                status.value = Status.Stopped
                service.stopSelf()
//                修复 ‘serviceReload’
                if (isRestart) {
                    // 2026-11-25 闪退修复：同上，start() 抛出来会直接
                    // 杀掉服务进程，包住只记日志。
                    try {
                        start()
                    } catch (t: Throwable) {
                        Log.e("BoxService", "restart failed", t)
                    }
                }
            }
        }
    }

    private fun closeService() {
        runCatching {
            commandServer.closeService()
        }.onFailure {
            commandServer.setError("android: close service: ${it.message}")
        }
    }

    private suspend fun stopAndAlert(type: Alert, message: String? = null) {
        SettingsManager.startedByUser = false
        val pfd = fileDescriptor
        if (pfd != null) {
            pfd.close()
            fileDescriptor = null
        }
        DefaultNetworkMonitor.stop()
        if (::commandServer.isInitialized) {
            closeService()
            commandServer.close()
        }
        withContext(Dispatchers.Main) {
            if (receiverRegistered) {
                service.unregisterReceiver(receiver)
                receiverRegistered = false
            }
            notification.close()
            binder.broadcast { callback ->
                callback.onServiceAlert(type.ordinal, message)
            }
            status.value = Status.Stopped
            service.stopSelf()
        }
    }

    @OptIn(DelicateCoroutinesApi::class)
    @Suppress("SameReturnValue")
    internal fun onStartCommand(): Int {
        if (status.value != Status.Stopped) return Service.START_NOT_STICKY
        status.value = Status.Starting

        if (!receiverRegistered) {
            ContextCompat.registerReceiver(
                service,
                receiver,
                IntentFilter().apply {
                    addAction(Action.SERVICE_CLOSE)
                    addAction(Action.SERVICE_RESTART)     // 修复 ‘serviceReload’
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                    }
                },
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            receiverRegistered = true
        }

        GlobalScope.launch(Dispatchers.IO) {
            SettingsManager.startedByUser = true
            try {
                startCommandServer()
            } catch (t: Throwable) {
                // 2026-11-26：同 startService，Error 也要上报，
                // 不能让协程静默死掉、状态卡在“正在连接…”。
                if (t is CancellationException) throw t
                Log.e("BoxService", "startCommandServer 失败", t)
                stopAndAlert(Alert.StartCommandServer, t.message ?: t.toString())
                return@launch
            }
            startService()
        }
        return Service.START_NOT_STICKY
    }

    internal fun onBind(): IBinder = binder

    internal fun onDestroy() {
        binder.close()
    }

    internal fun onRevoke() {
        stopService()
    }

    internal fun sendNotification(notification: Notification) {
        // libbox 1.14：identifier 语义变为通知 tag，频道 ID 改由 typeID 派生（对齐上游 SFA）
        val channel = "notification-${notification.typeID}"
        val builder =
            NotificationCompat.Builder(service, channel).setShowWhen(false)
                .setContentTitle(notification.title).setContentText(notification.body)
                .setOnlyAlertOnce(true).setSmallIcon(R.drawable.ic_menu)
                .setCategory(NotificationCompat.CATEGORY_EVENT)
                .setPriority(NotificationCompat.PRIORITY_HIGH).setAutoCancel(true)
        if (!notification.subtitle.isNullOrBlank()) {
            builder.setContentInfo(notification.subtitle)
        }
        if (!notification.openURL.isNullOrBlank()) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    service,
                    0,
                    PluginManager.launchIntent.apply {
                        setAction(Action.OPEN_URL).setData(Uri.parse(notification.openURL))
                        setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    },
                    ServiceNotification.flags,
                ),
            )
        }
        GlobalScope.launch(Dispatchers.Main) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PluginManager.notification.createNotificationChannel(
                    NotificationChannel(
                        channel,
                        notification.typeName,
                        NotificationManager.IMPORTANCE_HIGH,
                    ),
                )
            }
            PluginManager.notification.notify(notification.identifier, notification.typeID, builder.build())
        }
    }

    internal fun cancelNotification(identifier: String, typeID: Int) {
        GlobalScope.launch(Dispatchers.Main) {
            PluginManager.notification.cancel(identifier, typeID)
        }
    }

    override fun triggerNativeCrash() {
        Thread {
            Thread.sleep(200)
            throw RuntimeException("debug native crash")
        }.start()
    }

    override fun writeDebugMessage(message: String?) {
        Log.d("sing-box", message!!)
    }

    override fun connectSSHAgent(): Int = -1
}
