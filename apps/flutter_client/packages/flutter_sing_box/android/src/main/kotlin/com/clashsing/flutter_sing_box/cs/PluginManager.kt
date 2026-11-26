package com.clashsing.flutter_sing_box.cs

import android.app.NotificationManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.PowerManager
import androidx.core.content.getSystemService
import io.nekohasekai.sfa.constant.Bugs
import com.clashsing.flutter_sing_box.utils.ProfileManager
import com.clashsing.flutter_sing_box.utils.SettingsManager
import com.tencent.mmkv.MMKV
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File
import java.util.Locale

object PluginManager {
    @Volatile
    private var _appContext: Context? =  null
    val appContext: Context get() = _appContext ?: throw throwError()

    fun init(context: Context) {
        val checkedResult = _appContext
        if (checkedResult != null) {
            return
        }
        synchronized(this) {
            val doubleCheckedResult = _appContext
            if (doubleCheckedResult != null) {
                return
            }
            val appCtx = context.applicationContext
            this._appContext = appCtx
            // PATCH(zhexuexi 2026-11-26)：Java 侧 MMKV 必须在这里、在任何
            // mmkvWithID 之前先初始化（真机 2026-11-26 的 VPN_ERROR 根因）。
            // 已核实的事实（不要再按旧注释“ Dart 初始化能覆盖两边”理解）：
            // ① Dart 的 MMKV.initialize() 只调 FFI mmkvInitialize_v2，
            //    不置 Java 包装类的静态 rootDir；mmkv Dart 包全仓 grep
            //    不到任何一次对 Java initializeMMKV 的调用；
            //    MMKVPlugin.onAttachedToEngine 也只注册 channel，
            //    不调 MMKV.initialize。所以 Java 侧 rootDir 一直是 null，
            //    mmkvWithID 一律抛 IllegalStateException
            //    （"You should Call MMKV.initialize() first."，
            //    mmkv-2.4.3-runtime.jar 字节码已核）。
            // ② 根目录必须和 Dart 用同一个：Dart 默认 rootDir 是
            //    ${getApplicationDocumentsPath}/mmkv，而 path_provider
            //    在 Android 上返回 getDir("flutter")，即
            //    <filesDir>/app_flutter，所以 Dart 的根目录是
            //    <filesDir>/app_flutter/mmkv；Java 默认
            //    initialize(context) 用的是 <filesDir>/mmkv，
            //    目录不同会让原生侧读到空库、档案找不到。
            //    必须显式传同一目录。
            // ③ 每个进程都要走一遍：UI 进程在插件注册时（onAttachedToEngine），
            //    :remote 进程在 VPNService/ProxyService.onCreate 时，
            //    两处都调 PluginManager.init()，都在这里覆盖。
            // Java 初始化与 Dart FFI 初始化共存无问题：mmkv 官方示例
            // （example 的 MyApplication.kt + main.dart）就是两边都调。
            MMKV.initialize(
                appCtx,
                File(
                    appCtx.getDir("flutter", Context.MODE_PRIVATE),
                    "mmkv",
                ).absolutePath,
            )
            MMKV.mmkvWithID(ProfileManager.MMKV_ID, MMKV.MULTI_PROCESS_MODE)
            MMKV.mmkvWithID(SettingsManager.MMKV_ID, MMKV.MULTI_PROCESS_MODE)
            // PATCH(zhexuexi 2026-11-26)：using_config 目录缺省值，
            // 见 ProfileManager.seedUsingConfigDir 的注释——
            // 真机“连接失败”的根因，Dart 侧从未写过这个 key。
            ProfileManager.seedUsingConfigDir(
                appCtx.getDir("flutter", Context.MODE_PRIVATE).absolutePath,
            )
            initSingBox()
        }
    }

    private fun initSingBox() {
//        Seq.setContext(appContext)
        Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))
        val baseDir = appContext.filesDir
        baseDir.mkdirs()
        val workingDir = appContext.getExternalFilesDir(null) ?: return
        workingDir.mkdirs()
        val tempDir = appContext.cacheDir
        tempDir.mkdirs()
        Libbox.setup(SetupOptions().also {
            it.basePath = baseDir.path
            it.workingPath = workingDir.path
            it.tempPath = tempDir.path
            it.fixAndroidStack = Bugs.fixAndroidStack
            it.logMaxLines = 3000
            it.debug = false // TODO: 临时赋值 false
        })
        // libbox 1.14 移除了 Libbox.redirectStderr：Setup() 现在自动把 stderr
        // 重定向到 workingDir/CrashReport-<source>.log，无需手动调用
    }

    val connectivity by lazy { appContext.getSystemService<ConnectivityManager>() ?: throw throwError() }

    val packageManager by lazy { appContext.packageManager ?: throw throwError() }

    val wifiManager by lazy { appContext.getSystemService<WifiManager>() ?: throw throwError() }

    val notification by lazy { appContext.getSystemService<NotificationManager>() ?: throw throwError() }

    val launchIntent by lazy {
        packageManager.getLaunchIntentForPackage(appContext.packageName) ?: throw throwError()
    }

    val powerManager by lazy { appContext.getSystemService<PowerManager>() ?: throw throwError() }

    private fun throwError() : Throwable = IllegalStateException(
        "PluginManager not initialized. Call PluginManager.init() first."
    )

}