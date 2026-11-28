package com.github.hlnm.mt.discuz

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * MCP 悬浮球的**单实例**控制器：把 [McpFloatingBall] 的生命周期、权限判断，
 * 以及与 Dart 的回调串起来，并保证所有窗口操作都在主线程。
 *
 * ## 为什么要单独一层
 * 1. `WindowManager.addView` 的 View 属于**整个进程**而不是某个 Activity，
 *    悬浮球必须在 Activity 销毁/重建之间存活 —— 所以它不能挂在 `MainActivity` 的
 *    字段上随 Activity 一起销毁，这里用进程级单例持有。
 * 2. 悬浮球的生命周期由 **MCP 服务**决定（Dart 在 `start()` 成功后调 `showBall`，
 *    `stop()` 时调 `hideBall`），而不是由「用户是否正看着 App」决定。这样离开
 *    App、切到别的前台应用后球依然在，才符合"保活 + 可见入口"的目的。
 * 3. 权限、线程、异常兜底集中在一处，Dart 侧只需要一次 `showBall` 调用。
 *
 * ## 与前台服务的关系
 * 悬浮球**不替代** [McpForegroundService]：前台服务负责让进程活下来（dataSync 类型的
 * 常驻通知），悬浮球只是让用户"看得见"并"点得到"。两者同时存在才完整：
 * 服务保进程，球给可见性和快捷入口。任一环节失败都不影响另一环节。
 *
 * ## 已知边界
 * - 从最近任务划掉 App 时，`McpForegroundService`（`stopWithTask=true`）与 Flutter
 *   引擎一起结束，本控制器会随之被回收，球自然消失 —— 这是**预期行为**：
 *   球存在 <=> 进程活着 <=> MCP 还连着。
 * - 部分国产 ROM 会额外杀掉"带悬浮窗的后台应用"，因此球不是万能保活，只是让
 *   状态可见化，便于用户发现 MCP 掉线并即时拉起。
 */
object McpFloatingBallController {

    private const val TAG = "MTBBS"

    private val mainHandler = Handler(Looper.getMainLooper())

    private var ball: McpFloatingBall? = null

    /** Dart 侧注册的回调（点击悬浮球 -> 打开 MCP 快捷面板） */
    private var tapCallback: MethodChannel? = null

    /** 冷启动 / 通道尚未就绪时暂存的点击事件，等 Dart 注册后补发 */
    private var pendingTap = false

    /** Dart 是否希望悬浮球可见（用户可能在设置里关掉 MCP，此时不再自动显示） */
    private var wanted = false

    /** 绑定 Dart 通道；`init` 时调用一次即可。 */
    fun bind(channel: MethodChannel) {
        tapCallback = channel
        if (pendingTap) {
            pendingTap = false
            channel.invokeMethod("onBallTap", null)
        }
    }

    fun unbind() {
        tapCallback = null
    }

    /** 是否有悬浮窗权限（Android 6.0+ 需要用户在系统设置里手动授予）。 */
    fun hasOverlayPermission(context: Context): Boolean =
        McpFloatingBall.canShowOverlay(context)

    /** 跳系统「显示在其他应用上层」授权页；返回是否成功打开系统页面。 */
    fun requestOverlayPermission(context: Context): Boolean =
        McpFloatingBall.openOverlaySettings(context)

    /**
     * 显示悬浮球。已存在则直接返回（幂等）。
     *
     * 无权限时**不弹任何东西**、只返回 false —— 由 Dart 决定怎么提示用户
     * （引导授权的话术属于 UI 层，原生不该替它决定）。
     */
    fun show(context: Context): Boolean {
        wanted = true
        val appContext = context.applicationContext

        // 所有窗口操作统一切到主线程，避免 Dart 从后台 isolate 的调用踩到
        // "Only the original thread that created a view hierarchy can touch its views"
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { showOnMain(appContext) }
            return true
        }
        return showOnMain(appContext)
    }

    private fun showOnMain(appContext: Context): Boolean {
        if (ball != null) return true
        if (!McpFloatingBall.canShowOverlay(appContext)) {
            Log.i(TAG, "悬浮球未显示：缺少「显示在其他应用上层」权限")
            return false
        }
        return try {
            val created = McpFloatingBall.make(
                context = appContext,
                onClick = { dispatchTap() },
                onLongClick = {
                    // 长按 = 用户主动关球。同步告知 Dart，避免它在下次 start 前误以为还开着；
                    // 注意这只隐藏悬浮球，**不停止 MCP 服务**。
                    hide(appContext)
                    wanted = false
                    tapCallback?.invokeMethod("onBallDismissed", null)
                },
            )
            created.attachToScreen()
            ball = created
            true
        } catch (e: Exception) {
            // 典型：SecurityException（权限刚被回收）或 BadTokenException（窗口已失效）
            Log.w(TAG, "悬浮球添加失败: $e")
            ball = null
            false
        }
    }

    /** 移除悬浮球。幂等，可在任意线程调用。 */
    fun hide(context: Context) {
        wanted = false
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { hideOnMain() }
            return
        }
        hideOnMain()
    }

    private fun hideOnMain() {
        val current = ball ?: return
        ball = null
        try {
            current.removeFromScreen()
        } catch (e: Exception) {
            Log.w(TAG, "悬浮球移除失败: $e")
        }
    }

    /**
     * Activity 销毁 / 引擎回收时清理。
     *
     * 注意：这里**只解绑回调**，不强制移除球 —— 是否保留球取决于 [wanted]，
     * 而 `wanted` 由 Dart 的 MCP 开关决定。若这里无条件 removeView，
     * 用户旋转屏幕/系统重建 Activity 时会看到球闪一下消失。
     */
    fun onEngineDetached() {
        unbind()
        if (!wanted) hideOnMain()
    }

    /** 进程级彻底清理（App 真退出时）。 */
    fun dispose() {
        wanted = false
        hideOnMain()
        unbind()
    }

    private fun dispatchTap() {
        val target = tapCallback
        if (target == null) {
            pendingTap = true
        } else {
            mainHandler.post { target.invokeMethod("onBallTap", null) }
        }
    }
}
