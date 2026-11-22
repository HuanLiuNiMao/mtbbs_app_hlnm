package com.github.hlnm.mt.discuz

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * MCP 悬浮球的 Dart ⇄ 原生桥。
 *
 * 通道名 `mtbbs/mcp_floating_ball`，方法：
 * - `isSupported`       → bool  是否支持悬浮窗（平板/手机/鸿蒙外的桌面平台返回 false）
 * - `hasPermission`     → bool  系统是否已授予「显示在其他应用上层」
 * - `requestPermission` → bool  跳系统授权页（返回时状态未变，需回来重新查）
 * - `show`              → bool  显示悬浮球（线程安全，内部切主线程）
 * - `hide`              → bool  移除悬浮球
 * - `isShowing`         → bool  当前是否已显示
 * - `setColor`          → bool  设置球体颜色（`color` 为 0xAARRGGBB int）
 * - `setIdleSeconds`    → bool  设置闲置收起秒数（`seconds`；0 = 不自动收起）
 * - `onClick`           → 原生 → Dart 回调（点球）
 *
 * **实现来自 Bin佬**（MT 论坛 `FloatingWindowButton`），见 [McpFloatingBall] 注释。
 *
 * 为什么悬浮球是「独立开关」而不是跟着 MCP 服务自动显示：
 * MCP 服务常在后台跑一整天，若服务一开就强行在屏幕上顶一个球，等于替用户决定
 * 「我要一直看到它」。做成独立开关后，用户想让它出现才出现。
 */
object McpFloatingBallBridge {
    const val CHANNEL = "mtbbs/mcp_floating_ball"

    private const val TAG = "MTBBS_FLOATING"
    private const val POSITION_ID = "mcp"

    /** 悬浮窗授权请求码（与通知权限 8765 区分开） */
    const val OVERLAY_PERMISSION_REQUEST_CODE = 8766

    private val mainHandler = Handler(Looper.getMainLooper())

    private var ball: McpFloatingBall? = null
    private var channel: MethodChannel? = null
    private var lastColor: Int = McpFloatingBall.DEFAULT_COLOR
    private var lastIdleMillis: Long = McpFloatingBall.DEFAULT_IDLE_SECONDS * 1000L

    fun register(messenger: BinaryMessenger, context: Context) {
        val appContext = context.applicationContext
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(true)
                "hasPermission" -> result.success(McpFloatingBall.canShowOverlay(appContext))
                "requestPermission" -> {
                    result.success(requestPermission(context, appContext))
                }
                "show" -> {
                    // 先记住配置：show 与 setColor 的调用顺序不确定（Dart 侧并行发），
                    // 这里在创建时就用最近一次的值，避免先短暂显示成默认色
                    call.argument<Int>("color")?.let { lastColor = it }
                    call.argument<Int>("idleSeconds")?.let {
                        lastIdleMillis = maxOf(0, it) * 1000L
                    }
                    runOnMain {
                        result.success(showBall(appContext))
                    }
                }
                "hide" -> runOnMain { result.success(hideBall()) }
                "isShowing" -> result.success(ball != null)
                "setColor" -> {
                    val color = call.argument<Int>("color") ?: McpFloatingBall.DEFAULT_COLOR
                    lastColor = color
                    runOnMain {
                        ball?.setBallColor(color)
                        result.success(ball != null)
                    }
                }
                "setIdleSeconds" -> {
                    val seconds = call.argument<Int>("seconds")
                        ?: McpFloatingBall.DEFAULT_IDLE_SECONDS
                    lastIdleMillis = maxOf(0, seconds) * 1000L
                    runOnMain {
                        ball?.idleDelayMillis = lastIdleMillis
                        result.success(ball != null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 进程退出/引擎销毁时清理，避免 Activity 没了球还挂在屏幕上。 */
    fun dispose() {
        mainHandler.post { hideBall() }
        channel = null
    }

    private fun showBall(context: Context): Boolean {
        if (!McpFloatingBall.canShowOverlay(context)) {
            Log.w(TAG, "没有悬浮窗权限，忽略 show")
            return false
        }
        val existing = ball
        if (existing != null) {
            // 已显示：只同步配置，不重建
            existing.setBallColor(lastColor)
            existing.idleDelayMillis = lastIdleMillis
            return true
        }
        return try {
            val created = McpFloatingBall.make(context, POSITION_ID).apply {
                setBallColor(lastColor)
                idleDelayMillis = lastIdleMillis
                onBallClick = { channel?.invokeMethod("onClick", null) }
            }
            created.attachToScreen()
            ball = created
            true
        } catch (e: Exception) {
            // 权限刚被撤销、或系统拒绝 addView 时不要崩：球是可选装饰，不该拖垮 App
            Log.w(TAG, "显示悬浮球失败: $e")
            false
        }
    }

    private fun hideBall(): Boolean {
        val existing = ball ?: return true
        ball = null
        return try {
            existing.removeFromScreen()
            true
        } catch (e: Exception) {
            Log.w(TAG, "移除悬浮球失败: $e")
            false
        }
    }

    /** 跳系统「显示在其他应用上层」授权页。 */
    private fun requestPermission(context: Context, appContext: Context): Boolean {
        if (McpFloatingBall.canShowOverlay(appContext)) return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${appContext.packageName}"),
            ).apply {
                // 从非 Activity 上下文启动必须带 NEW_TASK
                if (context !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            false
        } catch (e: Exception) {
            Log.w(TAG, "打开悬浮窗授权页失败: $e")
            false
        }
    }

    private inline fun runOnMain(crossinline block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post { block() }
    }
}

