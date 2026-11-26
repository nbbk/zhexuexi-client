package com.clashsing.flutter_sing_box

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.clashsing.flutter_sing_box.cs.PluginManager
import com.clashsing.flutter_sing_box.cs.SingBoxConnector
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.sfa.bg.BoxService
import java.util.concurrent.atomic.AtomicReference

class FlutterSingBoxPlugin : FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.ActivityResultListener {
    companion object {
        private const val TAG = "FlutterSingBoxPlugin"
        private const val METHOD_CHANNEL_NAME = "flutter_sing_box_method"
        private const val VPN_REQUEST_CODE = 1001

        // PATCH(zhexuexi): 无 Activity 时挂起的启动请求最多等多久（毫秒），
        // 超时后按 NO_ACTIVITY 失败收尾，不让 Dart 侧的 startVpn() 一直挂着。
        private const val PENDING_START_TIMEOUT_MS = 20_000L
    }

    private lateinit var channel: MethodChannel
    private var singBoxConnector: SingBoxConnector? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val pendingStartVpnResult = AtomicReference<Result?>(null)

    // PATCH(zhexuexi): 见 packages/flutter_sing_box/PATCH_NOTES.md。
    // 上游 init/startVpn 硬要求 activityBinding?.activity 非空，小米真机上
    // ActivityAware 回调链没把 Activity 交过来时直接报 NO_ACTIVITY、代理起不来。
    // 这里多留两条路：init 改走 Application Context（bindService 本来就
    // 不需要 Activity）；startVpn 拿不到 Activity 时先看是否已授权，
    // 已授权直接起服务，未授权则挂起等 Activity 挂上再弹授权框。
    private var applicationContext: Context? = null

    // PATCH(zhexuexi): MainActivity 在 configureFlutterEngine 里直接推过来的
    // Activity（ActivityAware 回调失灵时的兜底），见 MainActivity.kt。
    private var fallbackActivity: Activity? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingTimeoutRunnable: Runnable? = null

    // PATCH(zhexuexi): 供 MainActivity 调用。ActivityAware 正常时它和
    // activityBinding 指向同一个 Activity，互为冗余，无害。
    fun setFallbackActivity(activity: Activity) {
        fallbackActivity = activity
    }

    // PATCH(zhexuexi): 只清掉属于本实例的引用。Activity 重建时新实例先
    // set、旧实例后 onDestroy，identity 比对避免旧实例误清新实例的。
    fun clearFallbackActivity(activity: Activity) {
        if (fallbackActivity === activity) {
            fallbackActivity = null
        }
    }

    // PATCH(zhexuexi): 当前可用的 Activity，优先 ActivityAware 的绑定，
    // 没有时用 MainActivity 直接推过来的兜底。
    private fun currentActivity(): Activity? =
        activityBinding?.activity ?: fallbackActivity

    // PATCH(zhexuexi): 有 Activity 时的启动流程（从原 startVpn 分支抽出，
    // 逻辑不变）：需授权则弹系统 VPN 授权框，结果回 onActivityResult；
    // 已授权直接起服务。
    // 2026-11-25 闪退修复：这里之前全程没有任何 try/catch，prepare /
    // startActivityForResult 一抛就从主线程直达进程死亡；且 pending
    // 是先 set 再拉框，拉框抛了 Result 会永远泄漏（这条路没配超时），
    // 下次点开关直接 VPN_BUSY。现全部包住，拉框失败清掉刚设的 pending。
    private fun requestVpnWithActivity(activity: Activity, result: Result) {
        if (activity.isFinishing || activity.isDestroyed) {
            // 兜底 fallback 可能是 MIUI 配置变更后留下的旧实例，
            // 对它调 startActivityForResult 会抛异常。
            result.error("NO_ACTIVITY", "Activity 已销毁，请重试", null)
            return
        }
        val intent: Intent?
        try {
            intent = VpnService.prepare(activity)
        } catch (t: Throwable) {
            Log.e(TAG, "VpnService.prepare 失败", t)
            result.error("VPN_ERROR", "启动 VPN 失败：${t.message}", null)
            return
        }
        if (intent == null) {
            startVpnService(result)
            return
        }
        pendingStartVpnResult.set(result)
        try {
            activity.startActivityForResult(intent, VPN_REQUEST_CODE)
        } catch (t: Throwable) {
            Log.e(TAG, "拉起 VPN 授权框失败", t)
            pendingStartVpnResult.compareAndSet(result, null)
            result.error("VPN_ERROR", "拉起 VPN 授权框失败：${t.message}", null)
        }
    }

    // PATCH(zhexuexi): Activity 刚挂上时，把挂起的启动请求跑掉。
    // 超时任务一并取消，结果由 requestVpnWithActivity / onActivityResult 收尾。
    private fun drainPendingStart() {
        val activity = currentActivity() ?: return
        val pending = pendingStartVpnResult.getAndSet(null) ?: return
        pendingTimeoutRunnable?.let {
            mainHandler.removeCallbacks(it)
            pendingTimeoutRunnable = null
        }
        requestVpnWithActivity(activity, pending)
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "onAttachedToEngine ---------------------------------")
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, METHOD_CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        PluginManager.init(flutterPluginBinding.applicationContext)
        applicationContext = flutterPluginBinding.applicationContext
        singBoxConnector = SingBoxConnector(flutterPluginBinding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "onDetachedFromEngine ---------------------------------")
        channel.setMethodCallHandler(null)
        singBoxConnector = null
        applicationContext = null
        fallbackActivity = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "init" -> {
                Log.d(TAG, "onMethodCall init ---------------------------------")
                // PATCH(zhexuexi): SingBoxConnector.connect() 只拿 Context 去
                // bindService，本来就不需要 Activity；上游这里硬要 Activity，
                // Activity 回调没到时 init 直接失败（App 侧还把这个错吞了，
                // 直到点启动才暴露）。改走 Application Context，init 不再
                // 依赖 Activity。
                val context = applicationContext ?: currentActivity()
                if (context != null) {
                    singBoxConnector?.connect(context)
                    result.success(null)
                    return
                } else {
                    result.error("NO_ACTIVITY", "无法获取Activity实例", null)
                    return
                }
            }
            "startVpn" -> {
                // PATCH(zhexuexi): 已有一次启动在等结果（授权框弹着 / 挂起等
                // Activity），直接拒绝，避免两个 Result 打架。
                if (pendingStartVpnResult.get() != null) {
                    result.error("VPN_BUSY", "已有一次启动正在进行", null)
                    return
                }
                val activity = currentActivity()
                if (activity != null) {
                    requestVpnWithActivity(activity, result)
                    return
                }
                // PATCH(zhexuexi): 无 Activity 时先看是否已授权：
                // VpnService.prepare() 返回 null 说明已授权，直接起服务。
                val appContext = applicationContext
                if (appContext != null) {
                    // 2026-11-25 闪退修复：prepare 是系统 IPC 调用，
                    // 抛出来（异常或 Error）之前没有任何防护，直接杀进程。
                    val prepared = try {
                        VpnService.prepare(appContext)
                    } catch (t: Throwable) {
                        Log.e(TAG, "VpnService.prepare 失败", t)
                        result.error("VPN_ERROR", "启动 VPN 失败：${t.message}", null)
                        return
                    }
                    if (prepared == null) {
                        startVpnService(result)
                        return
                    }
                }
                // PATCH(zhexuexi): 未授权且无 Activity：挂起，等 Activity
                // 挂上（onAttachedToActivity / onReattachedToActivityForConfigChanges
                // 里 drainPendingStart）再弹授权框；20 秒等不到就失败收尾。
                pendingStartVpnResult.set(result)
                val timeout = Runnable {
                    pendingStartVpnResult.getAndSet(null)?.error(
                        "NO_ACTIVITY",
                        "无法获取Activity实例，请重新打开应用再试",
                        null,
                    )
                    pendingTimeoutRunnable = null
                }
                pendingTimeoutRunnable = timeout
                mainHandler.postDelayed(timeout, PENDING_START_TIMEOUT_MS)
            }
            "stopVpn" -> {
                BoxService.stop()
                result.success(null)
            }
            "serviceReload" -> {
                try {
                    Libbox.newStandaloneCommandClient().serviceReload()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("SERVICE_RELOAD_FAILED", "服务重载失败", e)
                }
            }
            "setClashMode" -> {
                val clashMode = call.arguments as String
                if (singBoxConnector?.clientClashMode?.modes?.contains(clashMode) == true) {
                    Libbox.newStandaloneCommandClient().setClashMode(clashMode)
                    singBoxConnector?.clashModeClient?.connect()
                    result.success(null)
                } else {
                    result.error("INVALID_CLASH_MODE", "无效的Clash模式", null)
                }
            }
            "selectOutbound" -> {
                val groupArgName = "groupTag"
                val outboundArgName = "outboundTag"
                if (call.arguments !is Map<*, *>) {
                    result.error("INVALID_ARGUMENTS", "无效的参数", null)
                    return
                }
                val argsMap = call.arguments as Map<*, *>
                val groupTag = argsMap[groupArgName] as String?
                val outboundTag = argsMap[outboundArgName] as String?
                if (groupTag.isNullOrBlank() || outboundTag.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENTS", "无效的参数", null)
                    return
                }
                try {
                    Libbox.newStandaloneCommandClient().selectOutbound(groupTag, outboundTag)
                    singBoxConnector?.groupClient?.connect()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("INVALID_ARGUMENTS", "无效的参数", e)
                    return
                }
            }
            "setGroupExpand" -> {
                val groupArgName = "groupTag"
                val expandArgName = "isExpand"
                if (call.arguments !is Map<*, *>) {
                    result.error("INVALID_ARGUMENTS", "无效的参数", null)
                    return
                }
                val argsMap = call.arguments as Map<*, *>
                val groupTag = argsMap[groupArgName] as String?
                val isExpand = argsMap[expandArgName] as Boolean?
                if (groupTag.isNullOrBlank() || isExpand == null) {
                    result.error("INVALID_ARGUMENTS", "无效的参数", null)
                    return
                }
                try {
                    Libbox.newStandaloneCommandClient().setGroupExpand(groupTag, isExpand)
                    singBoxConnector?.groupClient?.connect()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("INVALID_ARGUMENTS", "无效的参数", e)
                    return
                }
            }
            "urlTest" -> {
                val groupTag = call.arguments as String?
                if (groupTag.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENTS", "无效的参数", null)
                    return
                }
                try {
                    Libbox.newStandaloneCommandClient().urlTest(groupTag)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("INVALID_ARGUMENTS", "无效的参数", e)
                    return
                }
            }
            "getSingBoxVersion" -> {
                val version = Libbox.version()
                result.success(version)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun startVpnService(result: Result) {
        try {
            BoxService.start()
            result.success(null)
        } catch (t: Throwable) {
            // 2026-11-25 闪退修复：之前只 catch Exception，Error
            //（如 UnsatisfiedLinkError / NoClassDefFoundError）会直接
            // 穿透主线程杀进程；两次点按都经过这里，必须全接住。
            Log.e(TAG, "启动 VPN 服务失败", t)
            // PATCH(zhexuexi 2026-11-26)：之前只传 t.message，
            // NoClassDefFoundError 这类错的 message 就是类名，
            // 丢了异常类型与 cause，下次再出怪错没法定位
            // （2026-11-26 真机截图只剩一个类名就是这么来的）。
            // 现在把异常类名 + cause 链写进 message，完整堆栈放 details。
            val detail = buildString {
                append(t::class.java.name)
                t.message?.let { append(": ").append(it) }
                var cause = t.cause
                while (cause != null) {
                    append("\nCaused by: ").append(cause::class.java.name)
                    cause.message?.let { append(": ").append(it) }
                    cause = cause.cause
                }
            }
            result.error(
                "VPN_ERROR",
                "启动VPN服务失败:\n$detail",
                Log.getStackTraceString(t),
            )
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        Log.d(TAG, "onAttachedToActivity --------------------")
        activityBinding = binding
        binding.addActivityResultListener(this)
        // PATCH(zhexuexi): Activity 到了，把挂起的启动跑掉。
        drainPendingStart()
//        singBoxConnector?.connect()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        Log.d(TAG, "onDetachedFromActivityForConfigChanges --------------------")
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        // PATCH(zhexuexi): 配置变更只是短暂 detach，不断挂起的启动；
        // 重挂上时 drainPendingStart 会跑掉，20 秒超时也会收尾。
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        Log.d(TAG, "onReattachedToActivityForConfigChanges --------------------")
        activityBinding = binding
        binding.addActivityResultListener(this)
        // PATCH(zhexuexi): Activity 到了，把挂起的启动跑掉。
        drainPendingStart()
    }

    override fun onDetachedFromActivity() {
        Log.d(TAG, "onDetachedFromActivity --------------------")
        singBoxConnector?.disconnect()
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        // PATCH(zhexuexi): Activity 彻底走了，挂起的启动等不到授权框了，
        // 直接失败收尾，别让 Dart 侧一直挂着（下次点启动会重新走流程）。
        pendingTimeoutRunnable?.let {
            mainHandler.removeCallbacks(it)
            pendingTimeoutRunnable = null
        }
        pendingStartVpnResult.getAndSet(null)?.error(
            "NO_ACTIVITY",
            "无法获取Activity实例，请重新打开应用再试",
            null,
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == VPN_REQUEST_CODE) {
            val result = pendingStartVpnResult.getAndSet(null)
            if (result != null) {
                if (resultCode == android.app.Activity.RESULT_OK) {
                    startVpnService(result)
                } else {
                    result.error("VPN_PERMISSION_DENIED", "用户拒绝了VPN权限", null)
                }
            }
            return true
        }
        return false
    }
}
