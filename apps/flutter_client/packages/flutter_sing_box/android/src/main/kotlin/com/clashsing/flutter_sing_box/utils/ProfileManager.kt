package com.clashsing.flutter_sing_box.utils

import com.clashsing.flutter_sing_box.cs.models.Profile
import com.tencent.mmkv.MMKV
import kotlinx.serialization.json.Json
import java.io.File

object ProfileManager {
    const val MMKV_ID = "cs_profile"
    private val mmkv by lazy {
        MMKV.mmkvWithID(MMKV_ID, MMKV.MULTI_PROCESS_MODE)
    }
    fun getAllKeys() : List<String>? {
        return  mmkv.allKeys()?.toList()
    }
    fun getSelectedProfile(): Profile? {
        val id = mmkv.decodeInt(Keys.SELECTED_PROFILE_ID, -1)
        val profileKey = getProfileKey(id)
        val content = mmkv.decodeString(profileKey)
        return if (content == null) null
        else Json.decodeFromString<Profile>(content)
    }
    private fun getProfileKey(id: Int): String {
        return "${Keys.PROFILE_PREFIX}$id"
    }

    fun getUsingConfig(): File {
        return File(
            mmkv.decodeString(Keys.USING_CONFIG, ""),
            Keys.USING_CONFIG_FILE_NAME
        )
    }

    /// PATCH(zhexuexi 2026-11-26)：补 `using_config` 目录的缺省值。
    ///
    /// 真机“连接失败”的根因（已核实到代码，不是猜测）：Dart 侧
    /// ProfileStorage.getUsingConfig() 在 key 不存在时回落到文档目录，
    /// 但 setUsingConfig() 全仓没有任何一处调用，MMKV 里一直没有这个
    /// key；Java 侧这里用 decodeString(..., "")，空串拼出来是相对路径
    /// "using_config.json"，:remote 进程里根本不存在，
    /// BoxService.startService() 每次都走 EmptyConfiguration。
    /// PluginManager.init()（UI 与 :remote 两进程都走）在 MMKV 初始化
    /// 后调这里，把缺省目录写进去，与 Dart 的回落值完全一致
    ///（<filesDir>/app_flutter，即 path_provider 的文档目录）。
    /// Dart 侧读到这个值与它自己的回落值相同，不受影响。
    fun seedUsingConfigDir(documentsDir: String) {
        if (mmkv.decodeString(Keys.USING_CONFIG).isNullOrBlank()) {
            mmkv.encode(Keys.USING_CONFIG, documentsDir)
        }
    }

    private object Keys {
        const val PROFILE_PREFIX: String = "profile_"
        const val SELECTED_PROFILE_ID: String = "selected_profile_id"
        const val USING_CONFIG: String = "using_config"
        const val USING_CONFIG_FILE_NAME: String = "using_config.json"
    }
}