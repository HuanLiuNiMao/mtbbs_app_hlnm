package com.github.hlnm.mt.discuz

import android.annotation.SuppressLint
import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.content.Context
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Point
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * MCP 悬浮球：通过 WindowManager 常驻在屏幕上的可拖动圆球。
 *
 * **本功能的实现来自 Bin佬**（MT 论坛 `FloatingWindowButton`，https://bbs.binmt.cc/）。
 * 拖动跟手、松手后的二维惯性抛射贴边、闲置自动收起、位置按比例记忆，都是他原作的
 * 设计与手感参数，这里只做了三处移植性改动：
 *
 * 1. **不再继承 `com.google.android.material.floatingactionbutton.FloatingActionButton`**。
 *    本项目 `android/app/build.gradle.kts` 里没有（也不需要）Material 组件库依赖，
 *    为了一个悬浮球引入整套 `com.google.android.material` 不划算——它还会强制
 *    AppCompat/Material 主题、把 minSdk 往上抬。这里改用 `FrameLayout` + 圆形
 *    `GradientDrawable` + `ImageView`，视觉与触摸行为对齐原作。
 * 2. **颜色可配**（用户要求）：[setBallColor] 改背景色，图标自动按亮度取黑白对比色。
 * 3. **闲置收起时长可配**（用户要求）：原作里 `IDLE_DELAY_MILLIS = 3000` 是编译期
 *    常量，这里改成实例字段 [idleDelayMillis]，由设置项驱动；`0` 表示**不自动收起**。
 *
 * 位置仍然保存为「可移动范围的比例」（0–1）而不是绝对像素，这样换分辨率、转屏、
 * 分屏都不会把球甩到屏幕外——这是原作最值得保留的一处设计。
 */
class McpFloatingBall private constructor(
    context: Context,
    private val positionId: String,
) : FrameLayout(context) {

    companion object {
        /** 闲置多少秒后自动收起（默认值，可被设置覆盖） */
        const val DEFAULT_IDLE_SECONDS = 3

        /** 球体直径。原作沿用 Material FAB 的 `SIZE_MINI`（40dp） */
        private const val BALL_SIZE_DP = 48f

        private const val SHRINK_DURATION_MILLIS = 300L
        private const val EXPANDED_ALPHA = 0.8f
        private const val SHRUNK_ALPHA = 0.35f
        private const val SHRINK_DISTANCE_RATIO = 0.8f
        private const val SWITCH_EDGE_MIN_FLING_MULTIPLIER = 8
        private const val EDGE_GRAVITY_FACTOR = 6f
        private const val AIR_DRAG = 3.5f
        private const val MAX_FRAME_SECONDS = 0.032f
        private const val EDGE_MOTION_DURATION = 1000L

        /** 位置偏好文件名：故意与 Bin佬 原作保持一致，便于用户沿用原来的位置。 */
        const val PREF_NAME = "floating_window_button"

        /** 默认配色：取 Material 蓝。`const val` 不能用 `.toInt()`（编译期常量限制），
         * 故声明为普通 `val`；颜色值本身仍是常量，外部只读。 */
        val DEFAULT_COLOR: Int = 0xFF1E88E5L.toInt()

        /** 使用带主题的 Context 创建控件，`positionId` 用于独立保存位置。 */
        fun make(context: Context, positionId: String): McpFloatingBall =
            McpFloatingBall(context, positionId)

        /** 系统是否允许本应用显示悬浮窗（API 23 起需要用户在系统设置里授权）。 */
        fun canShowOverlay(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)
    }

    private val displaySize = Point()
    private val windowManager: WindowManager =
        context.applicationContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val preferences: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
    private val positionXKey = "x:$positionId"
    private val positionYKey = "y:$positionId"

    private val params: WindowManager.LayoutParams
    private val touchSlopSquare: Float
    private val maximumFlingVelocity: Int
    private val switchEdgeVelocity: Float
    private val shrinkAfterIdle = Runnable { shrinkToEdge() }

    private val ballBackground = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(DEFAULT_COLOR)
    }
    private val iconView = ImageView(context).apply {
        setImageResource(R.drawable.ic_stat_mcp)
        scaleType = ImageView.ScaleType.CENTER_INSIDE
    }

    /** 闲置多久后收起；`0` 表示不收起（用户可关掉这个行为）。 */
    var idleDelayMillis: Long = DEFAULT_IDLE_SECONDS * 1000L
        set(value) {
            field = max(0L, value)
            if (isAttachedToWindow) scheduleShrink()
        }

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

    init {
        val density = resources.displayMetrics.density
        val size = (BALL_SIZE_DP * density).roundToInt()

        // API 26 起不允许用 TYPE_SYSTEM_ALERT（已废弃并被系统拒绝），按版本选类型。
        val windowType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
        }
        params = WindowManager.LayoutParams(
            size, size, windowType,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.RGBA_8888,
        ).apply {
            // 拖动按物理屏幕坐标计算，窗口原点固定在左上角。
            gravity = Gravity.LEFT or Gravity.TOP
        }

        val configuration = ViewConfiguration.get(context)
        val touchSlop = configuration.scaledTouchSlop.toFloat()
        touchSlopSquare = touchSlop * touchSlop
        maximumFlingVelocity = configuration.scaledMaximumFlingVelocity
        switchEdgeVelocity = configuration.scaledMinimumFlingVelocity *
            SWITCH_EDGE_MIN_FLING_MULTIPLIER

        // 球体本身画在 FrameLayout 的背景上，图标用内边距缩放，避免贴边
        elevation = 0f
        alpha = EXPANDED_ALPHA
        background = ballBackground
        val inset = (size * 0.22f).roundToInt()
        iconView.setPadding(inset, inset, inset, inset)
        addView(
            iconView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        setBallColor(DEFAULT_COLOR)
    }

    // ==================== 外观 ====================

    /**
     * 设置球体配色，并按背景亮度自动选黑白图标。
     *
     * 不给用户单独配图标色：两色自由组合极易撞出「浅底浅图标」看不见的情况，
     * 自动取对比色既省一个设置项，也保证任何配色下图标都可辨认。
     */
    fun setBallColor(color: Int) {
        ballBackground.setColor(color)
        val luminance = (
            0.299 * Color.red(color) +
                0.587 * Color.green(color) +
                0.114 * Color.blue(color)
            ) / 255.0
        iconView.setColorFilter(if (luminance > 0.6) Color.BLACK else Color.WHITE)
        // 浅色球在浅色壁纸上会「糊」掉，加一圈极淡描边兜底
        val strokeColor = if (luminance > 0.6) 0x22000000 else 0x33FFFFFF.toInt()
        ballBackground.setStroke(
            (1.5f * resources.displayMetrics.density).roundToInt(),
            strokeColor,
        )
    }

    // ==================== 显示 / 移除 ====================

    /** 在主线程添加悬浮球，调用前由宿主完成悬浮窗授权。 */
    fun attachToScreen() {
        if (parent != null) return
        readDisplaySize()
        // 添加前就定位，避免首帧短暂显示在左上角。
        measure(
            View.MeasureSpec.makeMeasureSpec(displaySize.x, View.MeasureSpec.AT_MOST),
            View.MeasureSpec.makeMeasureSpec(displaySize.y, View.MeasureSpec.AT_MOST),
        )
        positionX = preferences.getFloat(positionXKey, 1f)
        positionY = preferences.getFloat(positionYKey, Float.NaN)
        restorePosition(measuredWidth, measuredHeight)
        windowManager.addView(this, params)
    }

    /** 在主线程移除悬浮球，关闭开关或宿主退出时调用。 */
    fun removeFromScreen() {
        if (parent != null) windowManager.removeViewImmediate(this)
    }

    /** 当前球体左上角坐标（供 Dart 侧展示与排障，不影响保存逻辑）。 */
    fun positionSnapshot(): IntArray = intArrayOf(params.x, params.y)

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

    // ==================== 收起 / 展开 ====================

    /** 收起仅移动绘制内容，窗口坐标仍保留在贴边位置。 */
    private fun shrinkToEdge() {
        if (isPressed || dragging || edgeAnimator != null || width == 0) return
        val distance = width * SHRINK_DISTANCE_RATIO * if (params.x == 0) -1 else 1
        val fade = ObjectAnimator.ofFloat(this, View.ALPHA, EXPANDED_ALPHA, SHRUNK_ALPHA)
        val slide = ObjectAnimator.ofFloat(this, View.TRANSLATION_X, 0f, distance)
        shrinkAnimator = AnimatorSet().apply {
            playTogether(fade, slide)
            duration = SHRINK_DURATION_MILLIS
            start()
        }
        shrunk = true
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
        // 0 = 用户关掉了自动收起，只保留「贴边」不淡出
        if (idleDelayMillis <= 0) return
        postDelayed(shrinkAfterIdle, idleDelayMillis)
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
            windowManager.updateViewLayout(this, params)
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
        // 转屏 / 分屏 / 折叠屏展开：屏幕可用区域变了，按比例重新落位
        cancelEdgeAnimation()
        readDisplaySize()
        if (isAttachedToWindow) {
            expand()
            restorePosition(width, height)
            windowManager.updateViewLayout(this, params)
            scheduleShrink()
        }
    }

    // ==================== 触摸 ====================

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        val tracker = velocityTracker ?: return super.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            removeCallbacks(shrinkAfterIdle)
            cancelEdgeAnimation()
            tracker.clear()
        }
        addRawMovement(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // 收起后第一下只展开，因此也跳过点击
                expandOnlyTouch = shrunk
                isPressed = !expandOnlyTouch
                downX = event.rawX
                downY = event.rawY
                startX = params.x
                startY = params.y
                dragging = false
            }

            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - downX
                val dy = event.rawY - downY
                if (!dragging && dx * dx + dy * dy > touchSlopSquare) {
                    dragging = true
                    isPressed = false
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
                expand()
                isPressed = false
                if (dragging) {
                    dragging = false
                    if (event.actionMasked == MotionEvent.ACTION_UP) {
                        tracker.computeCurrentVelocity(1000, maximumFlingVelocity.toFloat())
                        adjustToEdge(tracker.xVelocity, tracker.yVelocity)
                    } else {
                        adjustToEdge(0f, 0f)
                    }
                } else {
                    scheduleShrink()
                    if (event.actionMasked == MotionEvent.ACTION_UP && !expandOnlyTouch) {
                        performClick()
                    }
                }
            }
        }
        return true
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

    /** 点击回调由 [McpFloatingBallBridge] 注入（点球 = 打开 MCP 快捷面板）。 */
    var onBallClick: (() -> Unit)? = null

    override fun performClick(): Boolean {
        super.performClick()
        onBallClick?.invoke()
        return true
    }

    // ==================== 惯性贴边 ====================

    /**
     * 按松手速度启动二维抛射；横向速度超过阈值时切换到另一侧重力，否则回到当前侧。
     *
     * 这套「重力 + 指数空气阻力 + 长帧切片」的积分模型是 Bin佬 原作的核心手感，
     * 换成简单的 ObjectAnimator 位移会丢掉「甩得越快飞得越远」的体感。
     */
    private fun adjustToEdge(vX: Float, vY: Float) {
        cancelEdgeAnimation()
        val maxX = max(0, displaySize.x - width)
        val maxY = max(0, displaySize.y - height)
        val motion = EdgeMotion(
            clamp(params.x.toFloat(), maxX),
            clamp(params.y.toFloat(), maxY),
            vX, vY, maxX, switchEdgeVelocity,
        )
        val lastPlayTime = longArrayOf(0)
        val animator = ValueAnimator.ofFloat(0f, 1f).apply {
            addUpdateListener { animation ->
                val playTime = animation.currentPlayTime
                var remainingSeconds = (playTime - lastPlayTime[0]) / 1000f
                lastPlayTime[0] = playTime
                if (remainingSeconds <= 0f) return@addUpdateListener
                var stopped = false
                // 长帧拆成稳定的小时间片，避免掉帧时越过重力分界或屏幕边界。
                while (remainingSeconds > 0f && !stopped) {
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
                if (isAttachedToWindow) windowManager.updateViewLayout(this, params)
                if (stopped) {
                    edgeAnimator = null
                    animation.cancel()
                    savePosition()
                    scheduleShrink()
                }
            }
            duration = EDGE_MOTION_DURATION
        }
        edgeAnimator = animator
        animator.start()
    }

    /**
     * 保存一次二维贴边运动的连续状态，使用逐帧积分保证水平和竖直速度共同参与轨迹。
     */
    private class EdgeMotion(
        x: Float,
        y: Float,
        velocityX: Float,
        velocityY: Float,
        maxX: Int,
        switchEdgeVelocity: Float,
    ) {
        var x: Float = x
        var y: Float = y
        private var velocityX: Float = velocityX
        private var velocityY: Float = velocityY
        private val gravityDirection: Int
        private var stopped = false

        init {
            // 从松手位置和横向速度一次性选择重力面，运动过程中不再因跨越中线而切换
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
            val damping = exp(-AIR_DRAG * seconds.toDouble()).toFloat()
            velocityX *= damping
            velocityY *= damping
            x += velocityX * seconds
            y += velocityY * seconds
            if (x <= 0f || x >= maxX) {
                x = if (x <= 0f) 0f else maxX.toFloat()
                velocityX = 0f
                velocityY = 0f
                stopped = true
            }
            if (y <= 0f) {
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

    private fun clamp(value: Float, limit: Int): Int =
        max(0f, min(value, limit.toFloat())).toInt()
}

