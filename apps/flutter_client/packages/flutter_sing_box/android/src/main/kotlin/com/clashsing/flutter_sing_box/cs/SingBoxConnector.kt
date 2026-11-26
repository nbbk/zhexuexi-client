package com.clashsing.flutter_sing_box.cs

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import io.nekohasekai.sfa.aidl.IService
import io.nekohasekai.sfa.aidl.IServiceCallback
import io.nekohasekai.sfa.constant.Action
import io.nekohasekai.sfa.constant.Status
import io.nekohasekai.sfa.utils.CommandClient

import com.clashsing.flutter_sing_box.cs.models.ClientClashMode
import com.clashsing.flutter_sing_box.cs.models.ClientGroup
import com.clashsing.flutter_sing_box.cs.models.ClientLog
import com.clashsing.flutter_sing_box.cs.models.ClientStatus
import com.clashsing.flutter_sing_box.utils.SettingsManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.nekohasekai.libbox.LogEntry
import io.nekohasekai.libbox.OutboundGroup
import io.nekohasekai.libbox.StatusMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.lang.ref.WeakReference

class SingBoxConnector(binaryMessenger: BinaryMessenger) {

    companion object {
        private const val TAG = "SingBoxConnector"
        private const val EVENT_CHANNEL_CONNECTED_STATUS = "connected_status_event"
        private const val EVENT_CHANNEL_GROUP = "group_event"
        private const val EVENT_CHANNEL_CLASH_MODE = "clash_mode_event"
        private const val EVENT_CHANNEL_LOG = "log_event"
        private const val EVENT_CHANNEL_PROXY_STATE = "proxy_state_event"
    }

    private var statusClient: CommandClient? = null
    internal var groupClient: CommandClient? = null
    internal var clashModeClient: CommandClient? = null
    private var logClient: CommandClient? = null
    private var coroutineScope: CoroutineScope? = null

    @Volatile
    private var statusSink: EventChannel.EventSink? = null
    @Volatile
    private var groupSink: EventChannel.EventSink? = null
    @Volatile
    private var clashModeSink: EventChannel.EventSink? = null
    @Volatile
    private var logSink: EventChannel.EventSink? = null
    @Volatile
    private var proxyStateSink: EventChannel.EventSink? = null

    @Volatile
    internal var clientClashMode: ClientClashMode? = null

    private var serviceConnection: ServiceConnection? = null

    private var proxyStatus: Status? = null

    private var clientGroups: List<ClientGroup>? = null

    init {
        EventChannel(binaryMessenger, EVENT_CHANNEL_CONNECTED_STATUS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { statusSink = events }
            override fun onCancel(arguments: Any?) { statusSink = null }
        })
        EventChannel(binaryMessenger, EVENT_CHANNEL_GROUP).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                groupSink = events
                clientGroups?.let { events?.success(Json.encodeToString(it)) }
            }
            override fun onCancel(arguments: Any?) { groupSink = null }
        })
        EventChannel(binaryMessenger, EVENT_CHANNEL_CLASH_MODE).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                clashModeSink = events
                clientClashMode?.let { events?.success(Json.encodeToString(it)) }
            }
            override fun onCancel(arguments: Any?) { clashModeSink = null }
        })
        EventChannel(binaryMessenger, EVENT_CHANNEL_LOG).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { logSink = events }
            override fun onCancel(arguments: Any?) { logSink = null }
        })
        EventChannel(binaryMessenger, EVENT_CHANNEL_PROXY_STATE).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                proxyStateSink = events
                proxyStatus?.let { events?.success(it.name) }
            }
            override fun onCancel(arguments: Any?) { proxyStateSink = null }
        })
    }

    private var context: WeakReference<Context>? = null
    internal fun connect(ctx: Context) {
        Log.d(TAG, "connect begin----------------------------")
        disconnect()
        context = WeakReference(ctx)
        coroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        serviceConnection = MyServiceConnection()
        val intent = Intent(ctx, SettingsManager.serviceClass())
        intent.action = Action.SERVICE
        ctx.bindService(intent, serviceConnection!!, Context.BIND_AUTO_CREATE)

        statusClient = CommandClient(coroutineScope!!, CommandClient.ConnectionType.Status, StatusClient())
        groupClient = CommandClient(coroutineScope!!, CommandClient.ConnectionType.Groups, GroupClient())
        clashModeClient = CommandClient(coroutineScope!!, CommandClient.ConnectionType.ClashMode, ClashModeClient())
        logClient = CommandClient(coroutineScope!!, CommandClient.ConnectionType.Log, LogClient())
        Log.d(TAG, "connect ended ----------------------------")
    }

    internal fun disconnect() {
        Log.d(TAG, "disconnect ----------------------------")
        try {
            disconnectClient()
            coroutineScope?.cancel()
            coroutineScope = null
            if (serviceConnection != null) {
                context?.get()?.unbindService(serviceConnection!!)
                serviceConnection = null
            }
        } catch (e: Exception) {
            Log.e(TAG, "disconnect: 解绑失败: ${e.message}")
        }
    }

    private fun connectClient() {
        statusClient?.connect()
        groupClient?.connect()
        clashModeClient?.connect()
        logClient?.connect()
    }

    private fun disconnectClient() {
        statusClient?.disconnect()
        groupClient?.disconnect()
        clashModeClient?.disconnect()
        logClient?.disconnect()
    }

    inner class ServiceCallback : IServiceCallback.Stub() {
        override fun onServiceStatusChanged(status: Int) {
            val tempStatus = when (status) {
                Status.Stopped.ordinal -> Status.Stopped
                Status.Starting.ordinal -> Status.Starting
                Status.Started.ordinal -> Status.Started
                Status.Stopping.ordinal -> Status.Stopping
                else -> throw IllegalArgumentException("Unknown status: $status")
            }
            if (proxyStatus != tempStatus) {
                proxyStatus = tempStatus
                coroutineScope?.launch(Dispatchers.Main.immediate) {
                    // 2026-11-25 闪退修复：这里跑在 SupervisorJob 协程里，
                    // 未捕获异常（connectClient 的 Go 调用、已失效的
                    // EventSink）会走默认 handler 直接杀掉 UI 进程。
                    try {
                        proxyStateSink?.success(proxyStatus?.name)
                        withContext(Dispatchers.Default) {
                            if (proxyStatus == Status.Started) {
                                connectClient()
                            } else if (proxyStatus == Status.Stopped) {
                                disconnectClient()
                            }
                        }
                    } catch (t: Throwable) {
                        Log.e(TAG, "onServiceStatusChanged 处理失败", t)
                    }
                }
            }
        }

        override fun onServiceAlert(type: Int, message: String?) {
            Log.e(TAG, "onServiceAlert: $type $message")
            proxyStatus = Status.Stopped
            coroutineScope?.launch(Dispatchers.Main.immediate) {
                // 2026-11-25 闪退修复：同上，EventSink 已失效时 error()
                // 也可能抛，包住。
                try {
                    proxyStateSink?.error(Status.Stopped.name, message, null)
                } catch (t: Throwable) {
                    Log.e(TAG, "上报服务告警失败", t)
                }
            }
            disconnectClient()
        }
    }

    inner class MyServiceConnection : ServiceConnection {
        private var service: IService? = null
        private val callback = ServiceCallback()

        // 2026-11-25 闪退修复：onBindingDied 节流用（见下）。
        private var lastBindDiedAtMs = 0L
        private var consecutiveBindDeaths = 0

        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            Log.d(TAG, "onServiceConnected: ${name?.toString()}")
            service = IService.Stub.asInterface(binder)
            coroutineScope?.launch {
                // 2026-11-25 闪退修复：远端服务在绑定完成前就死了
                //（启动即崩）时，这两个 AIDL 调用抛 RemoteException /
                // DeadObjectException；之前没有任何防护，协程未捕获异常
                // 直接杀掉 UI 进程——这是 `:remote` 崩溃反噬 UI 的主通道。
                try {
                    service?.apply {
                        registerCallback(callback)
                        callback.onServiceStatusChanged(status)
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "onServiceConnected: 服务已死亡，跳过回调注册", t)
                }
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            try {
                Log.d(TAG, "onServiceDisconnected: ${name?.toString()}")
                service?.unregisterCallback(callback)
            } catch (e: Exception) {
                Log.e(TAG, "onServiceDisconnected: 不需要取消注册。 $e")
            }
        }

        override fun onBindingDied(name: ComponentName?) {
            Log.e(TAG, "ServiceConnection.onBindingDied: ${name?.toString()}")
            // 2026-11-25 闪退修复：远端反复崩溃时别无限重建绑定——
            // 5 秒内连续死 3 次以上就停手并向 Dart 侧报一次错，否则
            // 重建-崩溃循环会反复撞上 onServiceConnected 的 AIDL 窗口、
            // 把 UI 进程也拖死。零星一次死亡仍正常重建。
            val now = SystemClock.elapsedRealtime()
            consecutiveBindDeaths =
                if (now - lastBindDiedAtMs < 5_000L) consecutiveBindDeaths + 1 else 1
            lastBindDiedAtMs = now
            if (consecutiveBindDeaths > 3) {
                Log.e(TAG, "服务反复死亡，停止重建绑定")
                coroutineScope?.launch(Dispatchers.Main.immediate) {
                    try {
                        proxyStateSink?.error(
                            Status.Stopped.name,
                            "代理服务反复崩溃，请重启应用再试",
                            null,
                        )
                    } catch (t: Throwable) {
                        Log.e(TAG, "上报服务崩溃失败", t)
                    }
                }
                return
            }
            context?.get()?.let {
                connect(it)
            }
        }
    }

    inner class StatusClient : CommandClient.Handler {
        override fun onConnected() {
        }
        override fun onDisconnected() {
        }

        override fun updateStatus(status: StatusMessage) {
            coroutineScope?.launch {
                // 2026-11-25 闪退修复：协程体无防护，序列化/推事件一抛
                // 就杀进程；包住只记日志。
                try {
                    val clientStatus = ClientStatus(
                        memory = status.memory,
                        goroutines = status.goroutines,
                        connectionsIn = status.connectionsIn,
                        connectionsOut = status.connectionsOut,
                        trafficAvailable = status.trafficAvailable,
                        uplink = status.uplink,
                        downlink = status.downlink,
                        uplinkTotal = status.uplinkTotal,
                        downlinkTotal = status.downlinkTotal
                    )
                    val event = Json.encodeToString(clientStatus)
                    withContext(Dispatchers.Main.immediate) {
                        statusSink?.success(event)
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "updateStatus 处理失败", t)
                }
            }
        }
    }

    inner class GroupClient : CommandClient.Handler {
        override fun updateGroups(newGroups: MutableList<OutboundGroup>) {
            coroutineScope?.launch {
                // 2026-11-25 闪退修复：同上；ClientGroup 构造里调 Go
                // 迭代器，可能抛，包住。
                try {
                    clientGroups = newGroups.map(::ClientGroup)
                    val event = Json.encodeToString(clientGroups)
                    withContext(Dispatchers.Main.immediate) {
                        groupSink?.success(event)
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "updateGroups 处理失败", t)
                }
            }
        }
    }

    inner class ClashModeClient : CommandClient.Handler {
        override fun initializeClashMode(modeList: List<String>, currentMode: String) {
            coroutineScope?.launch {
                // 2026-11-25 闪退修复：同上，包住。
                try {
                    clientClashMode = ClientClashMode(
                        modes = modeList,
                        currentMode = currentMode
                    )
                    val event = Json.encodeToString(clientClashMode)
                    withContext(Dispatchers.Main.immediate) {
                        clashModeSink?.success(event)
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "initializeClashMode 处理失败", t)
                }
            }
        }
        override fun updateClashMode(newMode: String) {
            coroutineScope?.launch {
                // 2026-11-25 闪退修复：同上，包住。
                try {
                    clientClashMode?.let { clashMode ->
                        clashMode.currentMode = newMode
                        val event = Json.encodeToString(clashMode)
                        withContext(Dispatchers.Main.immediate) {
                            clashModeSink?.success(event)
                        }
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "updateClashMode 处理失败", t)
                }
            }
        }
    }

    inner class LogClient : CommandClient.Handler {
        override fun clearLogs() {
            Log.d(TAG, "clearLogs: -------------------------")
        }
        override fun appendLogs(message: List<LogEntry>) {
            if (logSink == null) return
            coroutineScope?.launch {
                // 2026-11-25 闪退修复：同上，包住。
                try {
                    val clientLogs = message.map { ClientLog(it.level, it.message) }
                    val event = Json.encodeToString(clientLogs)
                    Log.d(TAG, "appendLogs: $event")
                    withContext(Dispatchers.Main.immediate) {
                        logSink?.success(event)
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "appendLogs 处理失败", t)
                }
            }
        }
    }

}
