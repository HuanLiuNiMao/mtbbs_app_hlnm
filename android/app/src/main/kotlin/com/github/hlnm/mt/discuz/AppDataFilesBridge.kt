package com.github.hlnm.mt.discuz

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 「注入文件提供器」的开关桥（Dart ⇄ 原生）。
 *
 * 为什么需要运行时开关，而不是像 MT 那样装上就常驻：
 *
 * 1. 我们的私有目录里有登录 Cookie（`cookies/{host}/{account}`）与账号设置，
 *    provider 一旦常驻，任何能拉起系统文件选择器的应用都能诱导用户点一下授权；
 *    默认关闭 = 默认没有这个面。
 * 2. 组件默认 `android:enabled="false"`，运行时才 setComponentEnabledSetting 打开。
 *    这同时避免了「装了但没开」时被系统 DocumentsUI 列出，也避免了
 *    [AppDataFilesWakeUpActivity] 被任意应用凭空拉起进程。
 * 3. `DONT_KILL_APP` 保证切换时**不杀进程**——杀掉进程会连带清掉前台服务、
 *    MCP 状态通知与 Flutter 引擎，用户会觉得「点了下开关 App 就重启了」。
 *
 * 通道名 `mtbbs/app_data_files`，方法：
 * - `isEnabled` → bool（读组件当前启用状态）
 * - `setEnabled` → bool（写入并回读，返回最终状态）
 */
object AppDataFilesBridge {
    const val CHANNEL = "mtbbs/app_data_files"

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> result.success(isEnabled(context))
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    result.success(setEnabled(context, enabled))
                }
                else -> result.notImplemented()
            }
        }
    }

    /** provider 与唤醒 Activity 是**一对**：只开 provider 则进程被回收后查不到。 */
    private fun components(context: Context) = listOf(
        ComponentName(context, AppDataFilesProvider::class.java),
        ComponentName(context, AppDataFilesWakeUpActivity::class.java),
    )

    /**
     * 读启用状态。
     *
     * `COMPONENT_ENABLED_STATE_DEFAULT` 视为关闭：manifest 里写的是
     * `android:enabled="false"`，DEFAULT 表示「沿用 manifest」，也就是关。
     * 只用 provider 一个组件判断即可（两者由 [setEnabled] 同步写入）。
     */
    fun isEnabled(context: Context): Boolean =
        context.packageManager.getComponentEnabledSetting(components(context).first()) ==
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED

    /** 写入启用状态，返回写入后回读到的实际值（不轻信写入结果）。 */
    fun setEnabled(context: Context, enabled: Boolean): Boolean {
        val pm = context.packageManager
        val state = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        for (component in components(context)) {
            pm.setComponentEnabledSetting(component, state, PackageManager.DONT_KILL_APP)
        }
        return isEnabled(context)
    }
}
