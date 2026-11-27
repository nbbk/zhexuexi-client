package io.nekohasekai.sfa.bg

import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.clashsing.flutter_sing_box.utils.SettingsManager
import com.clashsing.flutter_sing_box.cs.PluginManager
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.TunOptions
//import io.nekohasekai.sfa.database.Settings
import io.nekohasekai.sfa.ktx.toIpPrefix
import io.nekohasekai.sfa.ktx.toList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

@SuppressLint("VpnServicePolicy")
class VPNService :
    VpnService(),
    PlatformInterfaceWrapper {
    companion object {
        private const val TAG = "VPNService"

        // protect() 诊断计数（2026-11-26 二轮修复；0.1.9 纠正）：
        // 上游 1.14.4 common/dialer/default.go 只在
        // networkManager.AutoDetectInterface() 为真时才给拨号挂
        // ProtectFunc()。0.1.9 起配置写 auto_detect_interface: true，
        // Android 上 C.IsLinux 为真、guard 不触发，拨号会走到这里——
        // 计数非 0 是修法生效的证据，失败数说明这台机子 protect
        // 是否生效；0.1.8 及之前配置没开，计数恒为 0 是正常的
        // （不是“没记到”）。
        var protectCalls = 0
            private set
        var protectFailures = 0
            private set
    }

    private lateinit var service: BoxService

    override fun onCreate() {
        super.onCreate()
        PluginManager.init(this)
        service = BoxService(this, this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = service.onStartCommand()

    override fun onBind(intent: Intent): IBinder {
        val binder = super.onBind(intent)
        if (binder != null) {
            return binder
        }
        return service.onBind()
    }

    override fun onDestroy() {
        service.onDestroy()
    }

    override fun onRevoke() {
        runBlocking {
            withContext(Dispatchers.Main) {
                service.onRevoke()
            }
        }
    }

    // 2026-11-26 二轮修复：记下 protect() 的返回值（之前直接丢掉，
    // 真机上生效与否无从查证）。失败必记 WARN（小米等机型有
    // EPERM 兜底的前科）；成功记 DEBUG（拨号频繁，别刷屏）。
    // 注意：0.1.9 起配置写 auto_detect_interface: true，核心拨号
    // 会走这条路（Android 上 guard 不触发，见 singbox_config.dart
    // 的 route 注释）；环路隔离是这里的 protect(fd) 与下面 openTun
    // 里的 addDisallowedApplication(自家包名) 两道并存。
    override fun autoDetectInterfaceControl(fd: Int) {
        protectCalls++
        val ok = protect(fd)
        if (ok) {
            Log.d(TAG, "autoDetectInterfaceControl(fd=$fd): protect=true")
        } else {
            protectFailures++
            Log.w(
                TAG,
                "autoDetectInterfaceControl(fd=$fd): protect=false " +
                    "(calls=$protectCalls failures=$protectFailures)",
            )
        }
    }

    var systemProxyAvailable = false
    var systemProxyEnabled = false

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")

        val builder =
            Builder()
                .setSession("Clash Sing")
                .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

//        if (Settings.allowBypass) {
//            builder.allowBypass()
//        }

        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val address = inet4Address.next()
            builder.addAddress(address.address(), address.prefix())
        }

        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val address = inet6Address.next()
            builder.addAddress(address.address(), address.prefix())
        }

        if (options.autoRoute) {
            // libbox 1.14：dnsServerAddress 改为迭代器，并新增 dnsMode 判断（对齐上游 SFA 提交 3cb49ff "Use new DNS mode"）
            if (options.dnsMode.value != Libbox.DNSModeDisabled) {
                val dnsServerAddress = options.dnsServerAddress
                while (dnsServerAddress.hasNext()) {
                    builder.addDnsServer(dnsServerAddress.next())
                }
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val inet4RouteAddress = options.inet4RouteAddress
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        builder.addRoute(inet4RouteAddress.next().toIpPrefix())
                    }
                } else if (options.inet4Address.hasNext()) {
                    builder.addRoute("0.0.0.0", 0)
                }

                val inet6RouteAddress = options.inet6RouteAddress
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        builder.addRoute(inet6RouteAddress.next().toIpPrefix())
                    }
                } else if (options.inet6Address.hasNext()) {
                    builder.addRoute("::", 0)
                }

                val inet4RouteExcludeAddress = options.inet4RouteExcludeAddress
                while (inet4RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet4RouteExcludeAddress.next().toIpPrefix())
                }

                val inet6RouteExcludeAddress = options.inet6RouteExcludeAddress
                while (inet6RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet6RouteExcludeAddress.next().toIpPrefix())
                }
            } else {
                val inet4RouteAddress = options.inet4RouteRange
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        val address = inet4RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }

                val inet6RouteAddress = options.inet6RouteRange
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        val address = inet6RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }
            }

            if (SettingsManager.perAppProxyMode == SettingsManager.Keys.PER_APP_PROXY_INCLUDE) {
                val appList = SettingsManager.perAppProxyIncludeList
                if (appList.isNotEmpty()) {
                    appList.forEach {
                        try {
                            builder.addAllowedApplication(it)
                        } catch (_: NameNotFoundException) {
                        }
                    }
                    builder.addAllowedApplication(PluginManager.appContext.packageName)
                }
            } else if (SettingsManager.perAppProxyMode == SettingsManager.Keys.PER_APP_PROXY_EXCLUDE) {
                val appList = SettingsManager.perAppProxyExcludeList
                appList.forEach {
                    try {
                        builder.addDisallowedApplication(it)
                    } catch (_: NameNotFoundException) {
                    }
                }
            }

            // 2026-11-26 二轮修复（TUN 环路硬隔离；0.1.9 补充）：
            // 核心自己的 socket 必须绕过 TUN，否则出站向节点拨号
            // 的 SYN 进 TUN 后又被当作新连接路由给出站，永不到达节点
            // （拨测超时、YouTube 打不开、上行高企下行零）。0.1.9
            // 起配置另开一条路：route.auto_detect_interface 让拨号
            // 挂 ProtectFunc() 走 protect(fd)（见 companion 注释）；
            // 这行 addDisallowedApplication 仍保留作插件层隔离，
            // 两道隔离并存，不互相替代。
            // - 只在 perAppProxyMode 不是 INCLUDE 时加：INCLUDE 模式
            //   下方已把自家包写进 allowed 列表，两边同时写同一个包
            //   会冲突；INCLUDE 本来就是“只有这些应用走 VPN”，自家包
            //   在 allowed 里是该模式的原有语义，不动它。
            // - EXCLUDE / DISABLED 模式下都加：默认是 DISABLED（见
            //   SettingsManager 注释），默认不排除任何应用，不加这
            //   行核心 socket 就没有任何隔离。
            // - try/catch：万一某机型拒绝排除自家包，只记一行 WARN、
            //   继续建 TUN（退回今天的行为），不要让一次加排除把整
            //   个 VPN 启动炸掉；logcat 里这行就是真机定罪的证据。
            if (SettingsManager.perAppProxyMode != SettingsManager.Keys.PER_APP_PROXY_INCLUDE) {
                val ownPackage = PluginManager.appContext.packageName
                try {
                    builder.addDisallowedApplication(ownPackage)
                    Log.i(TAG, "addDisallowedApplication($ownPackage): ok, core sockets bypass TUN")
                } catch (e: Exception) {
                    Log.w(TAG, "addDisallowedApplication($ownPackage) failed, core sockets may loop through TUN", e)
                }
            }

/*
            val includePackage = options.includePackage
            if (includePackage.hasNext()) {
                while (includePackage.hasNext()) {
                    try {
                        val nextPackage = includePackage.next()
                        builder.addAllowedApplication(nextPackage)
                        Log.d("VPNService", "addAllowedApplication: $nextPackage")
                    } catch (e: NameNotFoundException) {
                        Log.e("VPNService", "addAllowedApplication failed", e)
                    }
                }
            }

            val excludePackage = options.excludePackage
            if (excludePackage.hasNext()) {
                while (excludePackage.hasNext()) {
                    try {
                        val nextPackage = excludePackage.next()
                        builder.addDisallowedApplication(nextPackage)
                        Log.d("VPNService", "addDisallowedApplication: $nextPackage")
                    } catch (e: NameNotFoundException) {
                        Log.e("VPNService", "addDisallowedApplication failed", e)
                    }
                }
            }
*/
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            systemProxyAvailable = true
            systemProxyEnabled = SettingsManager.systemProxyEnabled
            if (systemProxyEnabled) {
                builder.setHttpProxy(
                    ProxyInfo.buildDirectProxy(
                        options.httpProxyServer,
                        options.httpProxyServerPort,
                        options.httpProxyBypassDomain.toList(),
                    ),
                )
            }
        } else {
            systemProxyAvailable = false
            systemProxyEnabled = false
        }

        val pfd =
            builder.establish() ?: error("android: the application is not prepared or is revoked")
        service.fileDescriptor = pfd
        return pfd.fd
    }

    override fun sendNotification(notification: Notification) = service.sendNotification(notification)

    override fun cancelNotification(identifier: String, typeID: Int) = service.cancelNotification(identifier, typeID)
}
