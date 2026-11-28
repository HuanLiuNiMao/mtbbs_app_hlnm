package com.github.hlnm.mt.discuz

import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Point
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * MCP 运行状态「系统级悬浮球」。
 *
 * ## 为什么需要它
 * MCP 的 HTTP 服务跑在 Flutter 进程内，只要进程被系统回收（内存吃紧、厂商省电策略、
 * 用户从最近任务里划掉但服务还没停干净）MCP 就断了，外部 AI 客户端会连不上。
 * 常驻通知（[McpStatusNotification]）和前台服务（[McpForegroundService]）能让进程
 * 尽量活着，但都属于"用户看不见"的隐性手段；这里再给一个**用户随时可见、可点**的
 * 浮层入口：
 *
 * 1. **保活**：悬浮球由系统 `WindowManager` 持有（[android.view.WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY]），
 *    只要进程活着它就在；反过来，只要用户看到球还在，就说明进程和 MCP 都还在。
 *    它本身也是一个"正在运行"的强提示，比一条可被折叠的通知更难被忽略。
 * 2. **入口**：离开 App（切到别的应用/桌面）后仍能一键点开 MCP 快捷面板，
 *    不用先回到 App 再翻设置。
 *
 * ## 出处与改造
 * 交互机制（拖动 / 二维惯性贴边 / 闲置 3 秒半收起 / 位置按比例记忆 / 横竖屏重排）
 * 完整移植自上游作者 Bin 授权的 `FloatingWindowButton`
 * （`/sdcard/FloatingWindowButtonDemo.zip`，见 `docs/branch-management.md` 之外的
 * `docs/mcp-floating-ball.md` 说明）。原实现 `extends FloatingActionButton` 依赖
 * `com.google.android.material`，而本项目刻意**不引入 androidx/Material**
 * （见 `build.gradle.kts` 没有任何 `dependencies` 块），因此改为自绘 [View]：
 * 圆形背景 + 白色 "MCP" 文字，配色与通知图标一致。
 *
 * ## 线程约定
 * `attachToScreen()` / `removeFromScreen()` / 位置读写都必须在**主线程**调用。
 */
class McpFloatingBall private constructor(
    context: Context,
    positionId: String,
    private val onClick: () -> Unit,
    private val onLongClick: () -> Unit,
    endpoint: String,
) : View(context) {

    private val windowManager: WindowManager =
        context.applicationContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private val preferences: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private val positionXKey = "x:$positionId"
    private val positionYKey = "y:$positionId"

    private val params: WindowManager.LayoutParams
    // 必须声明在所有自绘 Paint 之前：Kotlin 按声明顺序初始化属性，
    // 下面的 Paint 初始化器会读到 density，放到后面就会读到 0f。
    private val density: Float = context.applicationContext.resources.displayMetrics.density
    private val displaySize = Point()
    private val touchSlopSquare: Float
    private val maximumFlingVelocity: Int
    private val switchEdgeVelocity: Int
    private val shrinkAfterIdle = Runnable { shrinkToEdge() }

    // 自绘资源
    private val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = BALL_COLOR }
    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.parseColor("#4DFFFFFF")
        strokeWidth = density * 1.5f
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textSize = density * 12f
    }
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = STATUS_COLOR }
    private val ballRect = RectF()

    /**
     * 监听地址（如 `127.0.0.1:8080`）。只取「端口」部分画在球下方的标签里
     * —— 完整地址太长，44dp 的球放不下；完整 endpoint 由点击后的快捷面板展示。
     * 为空表示地址未知（旧版 Dart 或服务未启动），此时不画标签，球恢复成纯圆。
     */
    private var endpointLabel: String = formatEndpointLabel(endpoint)
    /** 标签文字尺寸随 density 缩放，和球体文字保持同一视觉比例 */
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textSize = density * 8f
    }
    private val labelBackgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#E61F1B3A")
    }
    private val labelRect = RectF()

    private var positionX = 1f
    private var positionY = Float.NaN
    private var positionChanged = false
    private var firstLayout = false
    private var shrunk = false
    private var shrinkAnimator: AnimatorSet? = null
    private var edgeAnimator: ValueAnimator? = null

    private var velocityTracker: VelocityTracker? = null
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var dragging = false
    private var expandOnlyTouch = false
    private var longClickFired = false

    init {
        val windowType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
        }
        params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            windowType,
            // 不抢焦点（不挡住输入法/其他 App 的键鼠事件），但可以接收触摸
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.RGBA_8888,
        ).apply {
            // 拖动按物理屏幕坐标计算，窗口原点固定在左上角
            gravity = Gravity.LEFT or Gravity.TOP
        }

        val configuration = ViewConfiguration.get(context)
        val touchSlop = configuration.scaledTouchSlop
        touchSlopSquare = touchSlop.toFloat() * touchSlop.toFloat()
        maximumFlingVelocity = configuration.scaledMaximumFlingVelocity
        switchEdgeVelocity = configuration.scaledMinimumFlingVelocity *
            SWITCH_EDGE_MIN_FLING_MULTIPLIER

        alpha = EXPANDED_ALPHA
        isClickable = true
        isFocusable = false
        contentDescription = "MCP 运行中，点击打开 MCP 快捷面板，长按关闭悬浮球"
    }

    // ==================== 尺寸与绘制 ====================

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        // FloatingActionButton 的 mini 尺寸（40dp）在悬浮场景下最好用，直接固定。
        // 有 endpoint 时下方要多留一条标签高度，否则文字会被窗口裁掉。
        val size = (BALL_SIZE_DP * density).roundToInt()
        val labelHeight = if (endpointLabel.isEmpty()) 0 else LABEL_HEIGHT_DP * density
        setMeasuredDimension(size, size + labelHeight.roundToInt())
    }

    override fun onDraw(canvas: Canvas) {
        // 有标签时，圆形只占上方 44dp 区域，标签贴在其下；无标签则沿用整块高度。
        val ballSize = (BALL_SIZE_DP * density)
        val cx = width / 2f
        val cy = if (endpointLabel.isEmpty()) height / 2f else ballSize / 2f
        val radius = ballSize / 2f - ringPaint.strokeWidth

        ballRect.set(cx - radius, cy - radius, cx + radius, cy + radius)
        canvas.drawCircle(cx, cy, radius, backgroundPaint)
        canvas.drawCircle(cx, cy, radius, ringPaint)

        // 居中的 "MCP" 文字
        val textBaseline = cy - (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText("MCP", cx, textBaseline, textPaint)

        // 右下角小绿点：运行状态指示（视觉上和"在线"呼应）
        val dotRadius = density * 3.5f
        canvas.drawCircle(
            cx + radius * 0.66f,
            cy + radius * 0.66f,
            dotRadius,
            dotPaint,
        )
        // 球下方端口标签：让用户一眼看到 MCP 监听在哪个端口，不必点开面板
        if (endpointLabel.isNotEmpty()) {
            drawEndpointLabel(canvas, ballSize)
        }
    }

    /** 在圆球正下方画一颗胶囊形端口标签（如 `:8080`）。 */
    private fun drawEndpointLabel(canvas: Canvas, ballSize: Float) {
        val textWidth = labelPaint.measureText(endpointLabel)
        val padH = density * 4f
        val padV = density * 1.5f
        val labelH = labelPaint.descent() - labelPaint.ascent() + padV * 2
        val centerX = width / 2f
        val top = ballSize + density * 1f
        labelRect.set(
            centerX - textWidth / 2f - padH,
            top,
            centerX + textWidth / 2f + padH,
            top + labelH,
        )
        val r = labelRect.height() / 2f
        canvas.drawRoundRect(labelRect, r, r, labelBackgroundPaint)
        val baseline = labelRect.centerY() - (labelPaint.descent() + labelPaint.ascent()) / 2f
        canvas.drawText(endpointLabel, centerX, baseline, labelPaint)
    }

    /**
     * 运行中更新监听地址（服务重启换了端口时调用）。主线程调用。
     * 传空串则收起标签，球恢复纯圆。
     */
    fun setEndpoint(endpoint: String) {
        val next = formatEndpointLabel(endpoint)
        if (next == endpointLabel) return
        // 尺寸可能从「有标签」变「无标签」，必须重新 measure 才不会被裁切
        val hadLabel = endpointLabel.isNotEmpty()
        endpointLabel = next
        if (hadLabel != next.isNotEmpty()) {
            requestLayout()
        } else {
            invalidate()
        }
    }

    // ==================== 对外 API ====================

    /** 在主线程添加悬浮球；调用前宿主必须已拿到悬浮窗授权。 */
    fun attachToScreen() {
        if (parent != null) return
        readDisplaySize()
        // 添加前先定位，避免首帧短暂闪现在左上角
        measure(
            MeasureSpec.makeMeasureSpec(displaySize.x, MeasureSpec.AT_MOST),
            MeasureSpec.makeMeasureSpec(displaySize.y, MeasureSpec.AT_MOST),
        )
        positionX = preferences.getFloat(positionXKey, 1f)
        positionY = preferences.getFloat(positionYKey, Float.NaN)
        restorePosition(measuredWidth, measuredHeight)
        windowManager.addView(this, params)
    }

    /** 在主线程移除悬浮球；宿主销毁时也必须调用，否则会泄漏窗口。 */
    fun removeFromScreen() {
        if (parent != null) {
            windowManager.removeViewImmediate(this)
        }
    }

    // ==================== 位置记忆 ====================

    /** Overlay 的可用显示区域沿用系统窗口的 Display 尺寸，兼容低版本。 */
    @Suppress("DEPRECATION")
    private fun readDisplaySize() {
        windowManager.defaultDisplay.getSize(displaySize)
    }

    private fun restorePosition(width: Int, height: Int) {
        val maxX = max(0, displaySize.x - width)
        val maxY = max(0, displaySize.y - height)
        params.x = clamp(positionX * maxX, maxX)
        params.y = clamp(
            if (positionY.isNaN()) displaySize.y / 3f else positionY * maxY,
            maxY,
        )
    }

    /** 按可移动范围的比例保存位置，收起时的视觉位移不写入偏好。 */
    private fun savePosition() {
        if (!positionChanged) return
        val maxX = max(0, displaySize.x - width)
        val maxY = max(0, displaySize.y - height)
        positionX = if (maxX == 0) 0f else clamp(params.x.toFloat(), maxX) / maxX.toFloat()
        positionY = if (maxY == 0) 0f else clamp(params.y.toFloat(), maxY) / maxY.toFloat()
        preferences.edit()
            .putFloat(positionXKey, positionX)
            .putFloat(positionYKey, positionY)
            .apply()
        positionChanged = false
    }

    // ==================== 闲置收起 ====================

    /** 收起仅移动绘制内容，窗口坐标仍保留在贴边位置。 */
    private fun shrinkToEdge() {
        if (isPressed || dragging || edgeAnimator != null || width == 0) return
        val distance = width * SHRINK_DISTANCE_RATIO * if (params.x == 0) -1 else 1
        val fade = ObjectAnimator.ofFloat(this, ALPHA, EXPANDED_ALPHA, SHRUNK_ALPHA)
        val slide = ObjectAnimator.ofFloat(this, TRANSLATION_X, 0f, distance)
        shrinkAnimator = AnimatorSet().apply {
            playTogether(fade, slide)
            duration = SHRINK_DURATION_MILLIS
        }
        shrunk = true
        shrinkAnimator?.start()
    }

    private fun expand() {
        shrinkAnimator?.let {
            it.cancel()
            shrinkAnimator = null
        }
        if (shrunk) {
            alpha = EXPANDED_ALPHA
            translationX = 0f
            shrunk = false
        }
    }

    private fun scheduleShrink() {
        removeCallbacks(shrinkAfterIdle)
        postDelayed(shrinkAfterIdle, IDLE_DELAY_MILLIS)
    }

    /** 停止仍在更新窗口坐标的动画，并保存中断位置。 */
    private fun cancelEdgeAnimation() {
        edgeAnimator?.let {
            it.cancel()
            edgeAnimator = null
        }
        savePosition()
    }

    // ==================== 生命周期 ====================

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        if (firstLayout) {
            firstLayout = false
            restorePosition(right - left, bottom - top)
            if (parent != null) windowManager.updateViewLayout(this, params)
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        firstLayout = true
        velocityTracker = VelocityTracker.obtain()
        scheduleShrink()
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(shrinkAfterIdle)
        expand()
        cancelEdgeAnimation()
        velocityTracker?.recycle()
        velocityTracker = null
        dragging = false
        isPressed = false
        super.onDetachedFromWindow()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        cancelEdgeAnimation()
        readDisplaySize()
        if (isAttachedToWindow) {
            expand()
            restorePosition(width, height)
            windowManager.updateViewLayout(this, params)
            scheduleShrink()
        }
    }

    // ==================== 触摸交互 ====================

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        val tracker = velocityTracker ?: return super.onTouchEvent(event)
        val action = event.actionMasked
        if (action == MotionEvent.ACTION_DOWN) {
            removeCallbacks(shrinkAfterIdle)
            cancelEdgeAnimation()
            tracker.clear()
        }
        addRawMovement(event)
        when (action) {
            MotionEvent.ACTION_DOWN -> {
                // 收起后第一下只展开，因此也跳过点击动作
                expandOnlyTouch = shrunk
                isPressed = !expandOnlyTouch
                longClickFired = false
                downX = event.rawX
                downY = event.rawY
                startX = params.x
                startY = params.y
                dragging = false
                // 长按 = 关闭悬浮球（给用户一个不依赖 App 界面的退出方式）
                postDelayed(longPress, ViewConfiguration.getLongPressTimeout().toLong())
            }

            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - downX
                val dy = event.rawY - downY
                if (!dragging && dx * dx + dy * dy > touchSlopSquare) {
                    dragging = true
                    isPressed = false
                    removeCallbacks(longPress)
                    expand()
                }
                if (dragging) {
                    params.x = clamp(startX + dx, displaySize.x - width)
                    params.y = clamp(startY + dy, displaySize.y - height)
                    positionChanged = true
                    windowManager.updateViewLayout(this, params)
                }
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                removeCallbacks(longPress)
                expand()
                isPressed = false
                if (dragging) {
                    dragging = false
                    if (action == MotionEvent.ACTION_UP) {
                        tracker.computeCurrentVelocity(1000, maximumFlingVelocity.toFloat())
                        adjustToEdge(tracker.xVelocity, tracker.yVelocity)
                    } else {
                        adjustToEdge(0f, 0f)
                    }
                } else {
                    scheduleShrink()
                    if (action == MotionEvent.ACTION_UP && !expandOnlyTouch && !longClickFired) {
                        onClick()
                    }
                }
            }
        }
        return true
    }

    private val longPress = Runnable {
        if (!dragging) {
            longClickFired = true
            isPressed = false
            expand()
            onLongClick()
        }
    }

    /** 在屏幕坐标系采样，避免窗口跟随手指移动时丢失速度。 */
    private fun addRawMovement(event: MotionEvent) {
        val offsetX = event.rawX - event.x
        val offsetY = event.rawY - event.y
        event.offsetLocation(offsetX, offsetY)
        try {
            velocityTracker?.addMovement(event)
        } finally {
            event.offsetLocation(-offsetX, -offsetY)
        }
    }

    /**
     * 按松手速度启动二维抛射；横向速度超过阈值时切换到另一侧重力，否则回到当前侧。
     */
    private fun adjustToEdge(vX: Float, vY: Float) {
        cancelEdgeAnimation()
        val maxX = max(0, displaySize.x - width)
        val maxY = max(0, displaySize.y - height)
        val motion = EdgeMotion(
            clamp(params.x.toFloat(), maxX).toFloat(),
            clamp(params.y.toFloat(), maxY).toFloat(),
            vX, vY, maxX, maxY, switchEdgeVelocity.toFloat(),
        )
        val lastPlayTime = longArrayOf(0)
        val animator = ValueAnimator.ofFloat(0f, 1f)
        animator.addUpdateListener { animation ->
            val playTime = animation.currentPlayTime
            var remainingSeconds = (playTime - lastPlayTime[0]) / 1000f
            lastPlayTime[0] = playTime
            if (remainingSeconds <= 0f) return@addUpdateListener
            var stopped = false
            // 长帧拆成稳定的小时间片，避免掉帧时越过重力分界或屏幕边界
            while (remainingSeconds > 0 && !stopped) {
                val seconds = min(remainingSeconds, MAX_FRAME_SECONDS)
                stopped = motion.advance(seconds, maxX, maxY)
                remainingSeconds -= seconds
            }
            if (playTime >= EDGE_MOTION_DURATION && !stopped) {
                motion.settleToGravityEdge(maxX)
                stopped = true
            }
            params.x = motion.x.roundToInt()
            params.y = motion.y.roundToInt()
            positionChanged = true
            if (isAttachedToWindow) {
                windowManager.updateViewLayout(this, params)
            }
            if (stopped) {
                edgeAnimator = null
                animation.cancel()
                savePosition()
                scheduleShrink()
            }
        }
        animator.duration = EDGE_MOTION_DURATION
        edgeAnimator = animator
        animator.start()
    }

    /**
     * 保存一次二维贴边运动的连续状态，使用逐帧积分保证水平和竖直速度共同参与轨迹。
     *
     * 逐字移植自 Bin 的 `FloatingWindowButton.EdgeMotion`，数值调过，不要随意改动。
     */
    private class EdgeMotion(
        var x: Float,
        var y: Float,
        var velocityX: Float,
        var velocityY: Float,
        maxX: Int,
        maxY: Int,
        switchEdgeVelocity: Float,
    ) {
        private val gravityDirection: Int
        private var stopped = false

        init {
            // 初始位置先夹在可视区域内，避免旋转/分屏后松手瞬间越界
            y = y.coerceIn(0f, maxY.toFloat())
            val currentEdge = if (x <= maxX / 2f) -1 else 1
            gravityDirection = when {
                currentEdge < 0 && velocityX > switchEdgeVelocity -> 1
                currentEdge > 0 && velocityX < -switchEdgeVelocity -> -1
                else -> currentEdge
            }
        }

        /** 推进一个受限时间片；接触任一侧边后立即停止全部运动，不保留切向滑动。 */
        fun advance(seconds: Float, maxX: Int, maxY: Int): Boolean {
            if (stopped) return true
            velocityX += gravityDirection * maxX * EDGE_GRAVITY_FACTOR * seconds
            val damping = exp(-AIR_DRAG * seconds)
            velocityX *= damping
            velocityY *= damping
            x += velocityX * seconds
            y += velocityY * seconds
            if (x <= 0 || x >= maxX) {
                x = if (x <= 0) 0f else maxX.toFloat()
                velocityX = 0f
                velocityY = 0f
                stopped = true
            }
            if (y <= 0) {
                y = 0f
                velocityY = 0f
            } else if (y >= maxY) {
                y = maxY.toFloat()
                velocityY = 0f
            }
            return stopped
        }

        /** 超过动画时限时吸附到松手瞬间选定的重力面，避免异常帧率下长期占用动画。 */
        fun settleToGravityEdge(maxX: Int) {
            x = if (gravityDirection < 0) 0f else maxX.toFloat()
            velocityX = 0f
            velocityY = 0f
            stopped = true
        }
    }

    companion object {
        /** 判断系统是否允许当前应用显示悬浮窗；API 21–22 由 Manifest 声明即视为允许。 */
        fun canShowOverlay(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)

        /** 打开系统「显示在其他应用上层」授权页；失败返回 false（部分 ROM 没有该页面）。 */
        fun openOverlaySettings(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
            return try {
                val intent = android.content.Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    android.net.Uri.fromParts("package", context.packageName, null),
                ).apply { addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK) }
                context.startActivity(intent)
                true
            } catch (e: Exception) {
                // 少数 ROM 忽略了包名限制，退化为打开应用列表页
                try {
                    context.startActivity(
                        android.content.Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    true
                } catch (_: Exception) {
                    false
                }
            }
        }

        fun make(
            context: Context,
            positionId: String = DEFAULT_POSITION_ID,
            endpoint: String = "",
            onClick: () -> Unit,
            onLongClick: () -> Unit,
        ): McpFloatingBall =
            McpFloatingBall(context, positionId, onClick, onLongClick, endpoint)

        /**
         * 把完整的监听地址压缩成球下标签用的短文本。
         *
         * - `http://127.0.0.1:8080/mcp` → `:8080`
         * - `127.0.0.1:8080`            → `:8080`
         * - 解析不出端口时退回原串（截断到 12 字符），保证不改行为、不抛异常。
         */
        internal fun formatEndpointLabel(endpoint: String): String {
            val raw = endpoint.trim()
            if (raw.isEmpty()) return ""
            // 去掉 scheme 与 path，只留 host:port
            val hostPort = raw
                .substringAfter("://", raw)
                .substringBefore('/')
            val port = hostPort.substringAfterLast(':', "")
            if (port.isNotEmpty() && port.all { it.isDigit() }) return ":$port"
            return if (raw.length > 12) raw.take(12) else raw
        }

        const val DEFAULT_POSITION_ID = "mcp"

        private const val PREFS_NAME = "mcp_floating_ball"

        private const val IDLE_DELAY_MILLIS = 3000L
        private const val SHRINK_DURATION_MILLIS = 300L
        private const val EXPANDED_ALPHA = 0.8f
        private const val SHRUNK_ALPHA = 0.35f
        private const val SHRINK_DISTANCE_RATIO = 0.8f
        private const val SWITCH_EDGE_MIN_FLING_MULTIPLIER = 8
        private const val EDGE_GRAVITY_FACTOR = 6f
        private const val AIR_DRAG = 3.5f
        private const val MAX_FRAME_SECONDS = 0.032f
        private const val EDGE_MOTION_DURATION = 1000L
        private const val BALL_SIZE_DP = 44f
        /** 标签区高度（含上下内边距），仅在 endpoint 非空时占用 */
        private const val LABEL_HEIGHT_DP = 15f

        /** 与通知图标 / 品牌色保持一致的深蓝紫 */
        private val BALL_COLOR = Color.parseColor("#FF5B4BC4")
        private val STATUS_COLOR = Color.parseColor("#FF3DDC84")

        private fun clamp(value: Float, maxValue: Int): Int =
            max(0, min(value.roundToInt(), maxValue))
    }
}
