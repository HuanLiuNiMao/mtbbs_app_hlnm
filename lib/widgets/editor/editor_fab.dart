import 'dart:async';

import 'package:flutter/material.dart';

/// 编辑器悬浮窗的尺寸与手感参数。
///
/// 集中放一处是因为设置页的滑杆上下限、`EditorSettings.editorFabSizeValue`
/// 的钳位区间、组件自身的布局三者必须一致，散开写必有一处写错。
class EditorFabConfig {
  EditorFabConfig._();

  /// 边长可调区间（逻辑像素）
  static const double minSize = 36;
  static const double maxSize = 72;

  /// 默认边长 —— 「中等大小」：比 MCP 悬浮球（48）略大，一眼能认出是编辑器。
  static const double defaultSize = 52;

  /// 贴边后缩到原尺寸的这个比例 —— 「贴边后要小一点」。
  ///
  /// 0.78 是目测调出来的：再小就难点中，再大又看不出「收起来了」。
  static const double snappedScale = 0.78;

  /// 贴边后贴着屏幕边缘时，保留的边距
  static const double edgeMargin = 8;

  /// 拖动结束后自动贴边的默认秒数
  static const int defaultSnapSeconds = 3;

  /// 自动贴边的秒数上限（0 表示不贴边）
  static const int maxSnapSeconds = 30;

  /// 位置记忆的边距上限比例：不让球被拖到完全出屏后找不回来
  static const double maxOffsetRatio = 0.9;
}

/// 应用内编辑器悬浮窗。
///
/// 与 MCP 悬浮球（`McpFloatingBall`，原生 `TYPE_APPLICATION_OVERLAY`，
/// 能飘到别的应用上面）**刻意不同**：本组件是 Flutter 层的，天生只在本应用
/// 的 widget 树里存在，不会跨应用。用户的要求正是「这个悬浮窗不需要跨应用」。
///
/// 手感参数照抄 `McpFloatingBall.kt`：
/// - 拖动跟手（手指位移直接加到位置上，不做阻尼）；
/// - 松手后按松手速度做二维惯性抛射；
/// - 惯性结束 / 松手后闲置 N 秒 → 自动贴到最近的左右边缘；
/// - 贴边后整体缩小（[EditorFabConfig.snappedScale]）；
/// - 再次按下时立刻恢复原尺寸，避免"变小了拖不动"。
class EditorFab extends StatefulWidget {
  const EditorFab({
    super.key,
    required this.size,
    required this.snapSeconds,
    required this.onTap,
    this.child,
  });

  /// 边长（来自设置，已被 `EditorSettings.editorFabSizeValue` 钳过）
  final double size;

  /// 闲置多少秒后自动贴边；0 = 不自动贴边
  final int snapSeconds;

  /// 点击回调（进编辑器）
  final VoidCallback onTap;

  /// 球体内容（默认是编辑图标）
  final Widget? child;

  @override
  State<EditorFab> createState() => _EditorFabState();
}

class _EditorFabState extends State<EditorFab>
    with SingleTickerProviderStateMixin {
  /// 当前左上角位置。null = 尚未定位（首帧按「右下角」初始化）
  Offset? _pos;

  /// 是否已贴边（贴边后缩小）
  bool _snapped = false;

  /// 是否正在拖动（拖动时不缩小，也不自动贴边）
  bool _dragging = false;

  /// 拖动速度（逻辑像素/秒），松手后用来算惯性
  Offset _velocity = Offset.zero;

  /// 上一帧的指针位置与时间戳，用于估算速度
  Offset? _lastPointer;
  Duration? _lastTime;

  /// 自动贴边的定时器
  ///
  /// 用 `Timer` 而不是 `Future.delayed`：拖动频繁开始/结束，需要能取消。
  /// 不取消的话会攒下一堆过期回调，用户会在拖动中途被"抢"过去贴边。
  Timer? _snapTimer;

  /// 惯性抛射的动画控制器
  late final AnimationController _flingController;

  /// 惯性动画的起止位置
  Offset _flingFrom = Offset.zero;
  Offset _flingTo = Offset.zero;

  /// 上一次布局拿到的可用区域（用于边缘吸附与越界修正）
  Size _viewport = Size.zero;

  @override
  void initState() {
    super.initState();
    _flingController = AnimationController(vsync: this)
      ..addListener(_onFlingTick)
      ..addStatusListener(_onFlingStatus);
  }

  @override
  void dispose() {
    _snapTimer?.cancel();
    _flingController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant EditorFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 秒数改成 0 时要把已经在跑的贴边取消掉，否则改完设置还会被贴一次
    if (widget.snapSeconds != oldWidget.snapSeconds) {
      _snapTimer?.cancel();
      if (widget.snapSeconds <= 0) _snapTimer = null;
    }
    if (widget.size != oldWidget.size) {
      // 尺寸变了要重新钳位置，否则球会有一部分跑到屏幕外
      _clampIntoViewport();
    }
  }

  /// 当前边长：贴边时缩到 [EditorFabConfig.snappedScale]
  double get _currentSize =>
      widget.size * (_snapped ? EditorFabConfig.snappedScale : 1);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (viewport != _viewport) {
          _viewport = viewport;
          // 首帧 / 旋转 / 分屏变化：确保球还在可见区域内
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _ensureInitialized();
            _clampIntoViewport();
          });
        }
        final pos = _pos;
        if (pos == null) return const SizedBox.expand();
        final size = _currentSize;
        return Stack(
          children: [
            Positioned(
              left: pos.dx,
              top: pos.dy,
              width: size,
              height: size,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                onPanCancel: _onPanCancel,
                onTap: widget.onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    // 「主题色的圆角方形框」：填充用主题色，圆角比正圆少一点，
                    // 让它在视觉上比 MCP 圆球更"方"，符合用户说的方形框。
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(size * 0.32),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.22),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Center(
                    child:
                        widget.child ??
                        Icon(
                          Icons.edit_outlined,
                          // 图标跟着边长缩放，缩小后不会显得挤
                          size: size * 0.46,
                          color: cs.onPrimary,
                        ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 首次布局时放到右下角（用户要求「默认放在界面右下角」）
  void _ensureInitialized() {
    if (_pos != null) return;
    if (_viewport == Size.zero) return;
    final margin = EditorFabConfig.edgeMargin;
    _pos = Offset(
      _viewport.width - widget.size - margin * 2,
      _viewport.height - widget.size - margin * 4,
    );
    _clampIntoViewport();
  }

  /// 把位置钳进可用区域，防止旋转/改尺寸后球跑到屏幕外
  void _clampIntoViewport() {
    final pos = _pos;
    if (pos == null) return;
    final size = _currentSize;
    final maxX = (_viewport.width - size).clamp(0.0, double.infinity);
    final maxY = (_viewport.height - size).clamp(0.0, double.infinity);
    final next = Offset(pos.dx.clamp(0.0, maxX), pos.dy.clamp(0.0, maxY));
    if (next != pos) setState(() => _pos = next);
  }

  void _onPanStart(DragStartDetails details) {
    _snapTimer?.cancel();
    _flingController.stop();
    // 按下立刻恢复原尺寸：缩小的球手指容易压到屏幕边缘之外
    setState(() {
      _dragging = true;
      _snapped = false;
    });
    _lastPointer = null;
    _lastTime = null;
    _velocity = Offset.zero;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final now = details.sourceTimeStamp;
    final local = details.localPosition;
    // localPosition 是相对球自身的，这里要的是全局位移，用 delta 累加更稳
    final delta = details.delta;
    if (delta == Offset.zero) return;

    if (now != null && _lastTime != null && _lastPointer != null) {
      final dt =
          (now - _lastTime!).inMicroseconds / Duration.microsecondsPerSecond;
      if (dt > 0.001) {
        // 简单的指数平滑：单帧速度抖动很大，直接用会让惯性方向乱跳
        _velocity = Offset.lerp(_velocity, delta / dt, 0.4)!;
      }
    }
    _lastTime = now;
    _lastPointer = local;

    final pos = _pos!;
    setState(() {
      _pos = Offset(pos.dx + delta.dx, pos.dy + delta.dy);
    });
    _clampIntoViewport();
  }

  void _onPanEnd(DragEndDetails details) {
    setState(() => _dragging = false);
    // 用松手速度（比手势累计速度更准确，也包含「甩出去」那一下）
    final v = details.velocity.pixelsPerSecond;
    final speed = v.distance;
    if (speed > 240) {
      _startFling(v);
    } else {
      _scheduleSnap();
    }
  }

  void _onPanCancel() {
    setState(() => _dragging = false);
    _scheduleSnap();
  }

  /// 惯性抛射：按速度方向滑一段距离后停住，再安排贴边。
  ///
  /// 距离取「速度 × 0.18 秒」并钳到半屏，纯经验值 —— 太长会飞得莫名其妙，
  /// 太短则「甩」这个动作没有反馈。
  void _startFling(Offset velocity) {
    final pos = _pos;
    if (pos == null) return;
    final distance = velocity * 0.18;
    _flingFrom = pos;
    _flingTo = Offset(
      (pos.dx + distance.dx).clamp(0.0, (_viewport.width - _currentSize)),
      (pos.dy + distance.dy).clamp(0.0, (_viewport.height - _currentSize)),
    );
    // 速度越快动画越短，避免慢速拖动滑很久
    final durationMs = (260 - velocity.distance / 26).clamp(90.0, 260.0);
    _flingController.duration = Duration(milliseconds: durationMs.round());
    _flingController.forward(from: 0);
  }

  void _onFlingTick() {
    final t = Curves.easeOutCubic.transform(_flingController.value);
    setState(() {
      _pos = Offset.lerp(_flingFrom, _flingTo, t);
    });
  }

  void _onFlingStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _scheduleSnap();
  }

  /// 安排「闲置 N 秒后自动贴边」
  void _scheduleSnap() {
    _snapTimer?.cancel();
    final seconds = widget.snapSeconds;
    if (seconds <= 0) return;
    _snapTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted || _dragging) return;
      _snapToEdge();
    });
  }

  /// 贴到最近的左右边缘，并缩小。
  ///
  /// 只吸附左右不吸附上下：上下边缘常被底栏/Tab 压住，贴上去就点不到了。
  void _snapToEdge() {
    final pos = _pos;
    if (pos == null) return;
    // 先按缩小后的尺寸算目标位置，避免「缩小时看着贴住了，动画结束又露出来」
    final shrunk = widget.size * EditorFabConfig.snappedScale;
    final margin = EditorFabConfig.edgeMargin;
    final centerX = pos.dx + _currentSize / 2;
    final toLeft = centerX < _viewport.width / 2;
    final targetX = toLeft
        ? margin
        : (_viewport.width - shrunk - margin).clamp(0.0, double.infinity);
    final targetY = pos.dy.clamp(
      0.0,
      (_viewport.height - shrunk).clamp(0.0, double.infinity),
    );
    setState(() {
      _snapped = true;
      _pos = Offset(targetX, targetY);
    });
  }
}
