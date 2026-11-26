package io.nekohasekai.sfa.bg

import android.app.Service
import android.content.Intent
import com.clashsing.flutter_sing_box.cs.PluginManager
import io.nekohasekai.libbox.Notification

class ProxyService :
    Service(),
    PlatformInterfaceWrapper {
    private val service = BoxService(this, this)

    // 2026-11-25 闪退修复：之前没调 PluginManager.init（VPNService
    // 的 onCreate 里有），一旦 serviceMode 走到 Proxy，首次触
    // PluginManager.appContext 即抛 IllegalStateException。
    override fun onCreate() {
        super.onCreate()
        PluginManager.init(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = service.onStartCommand()

    override fun onBind(intent: Intent) = service.onBind()

    override fun onDestroy() = service.onDestroy()

    override fun sendNotification(notification: Notification) = service.sendNotification(notification)

    override fun cancelNotification(identifier: String, typeID: Int) = service.cancelNotification(identifier, typeID)
}
