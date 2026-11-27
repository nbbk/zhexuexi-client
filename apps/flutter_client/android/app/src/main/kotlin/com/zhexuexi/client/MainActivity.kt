package com.zhexuexi.client

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import com.clashsing.flutter_sing_box.FlutterSingBoxPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {

    // sing-box 插件实例（configureFlutterEngine 里拿到，供 onDestroy 清兜底引用）。
    private var singBoxPlugin: FlutterSingBoxPlugin? = null

    // 分应用代理：已装应用列表通道（0.1.14）。
    private var installedAppsChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 兜底：把当前 Activity 直接交给 sing-box 插件
        // （见 apps/flutter_client/packages/flutter_sing_box/PATCH_NOTES.md）。
        // 正常情况下插件经 ActivityAware 回调就能拿到 Activity；小米真机上
        // 出现过回调链没把 Activity 交过来的情况（点启动报 NO_ACTIVITY），
        // 这里再推一次。正常设备上它与回调指向同一个 Activity，互为冗余，无害。
        singBoxPlugin =
            flutterEngine.plugins.get(FlutterSingBoxPlugin::class.java)
                as? FlutterSingBoxPlugin
        singBoxPlugin?.setFallbackActivity(this)

        installedAppsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.zhexuexi.client/installed_apps",
        )
        installedAppsChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getLaunchableApps" -> {
                    try {
                        result.success(getLaunchableApps())
                    } catch (e: Exception) {
                        result.error("LOAD_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // 列出全部可启动应用（包名＋名称＋图标）。
    // Android 11+ 应用可见性：ACTION_MAIN + CATEGORY_LAUNCHER 的
    // queryIntentActivities 不用 QUERY_ALL_PACKAGES 就能列出全部
    // 可启动应用（系统白名单意图），所以这里不声明新权限。
    // 图标压到 96x96 PNG 再过通道，一次全量约 1MB 上下，Dart 侧缓存。
    private fun getLaunchableApps(): List<Map<String, Any>> {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val infos = pm.queryIntentActivities(intent, 0)
        val seen = HashSet<String>()
        val apps = ArrayList<Map<String, Any>>()
        for (info in infos) {
            val pkg = info.activityInfo.packageName
            if (!seen.add(pkg)) continue
            val map = HashMap<String, Any>()
            map["packageName"] = pkg
            map["label"] = info.loadLabel(pm).toString()
            drawableToPng(info.loadIcon(pm))?.let { map["icon"] = it }
            apps.add(map)
        }
        apps.sortBy { (it["label"] as String).lowercase() }
        return apps
    }

    private fun drawableToPng(drawable: Drawable): ByteArray? {
        return try {
            val size = 96
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        } catch (_: Exception) {
            null
        }
    }

    override fun onDestroy() {
        installedAppsChannel?.setMethodCallHandler(null)
        installedAppsChannel = null
        // 只清掉属于本实例的兜底引用，别误清重建后新实例设好的
        // （clearFallbackActivity 内部有 identity 比对）。
        singBoxPlugin?.clearFallbackActivity(this)
        singBoxPlugin = null
        super.onDestroy()
    }
}
