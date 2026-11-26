package com.zhexuexi.client

import com.clashsing.flutter_sing_box.FlutterSingBoxPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    // sing-box 插件实例（configureFlutterEngine 里拿到，供 onDestroy 清兜底引用）。
    private var singBoxPlugin: FlutterSingBoxPlugin? = null

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
    }

    override fun onDestroy() {
        // 只清掉属于本实例的兜底引用，别误清重建后新实例设好的
        // （clearFallbackActivity 内部有 identity 比对）。
        singBoxPlugin?.clearFallbackActivity(this)
        singBoxPlugin = null
        super.onDestroy()
    }
}
