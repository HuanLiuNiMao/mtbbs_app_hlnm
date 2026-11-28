# MCP 系统级悬浮球与进程保活
> 适用：修改 MCP 悬浮球原生实现、排查「球不显示 / 球在 App 内而非系统层 / 切后台球消失」前必读；也适用于给其他常驻能力接系统级 overlay。

## 解决的问题

MCP 服务端需要 App 进程长期存活，但 Android 上多数厂商 ROM 会在 App 切到后台后几十秒内冻结或杀进程，结果是端口断开、外部客户端静默失败。用户侧看不到任何反馈，只会觉得「MCP 坏了」。

悬浮球是把这个隐形的状态变成可见信号：**球还在 = 进程还活着、MCP 可用**。它同时承担快捷入口（点球开面板，不用反复切 App）。

## 必须真系统级，不能用 Flutter Dialog

Flutter 的 Overlay / Dialog 只能画在 Flutter 自己的 View 树里，App 切到后台就跟着消失，完全无法表达「进程还活着」。所以这里走原生 WindowManager：

| 项 | 取值 | 为什么 |
| --- | --- | --- |
| 窗口类型 | TYPE_APPLICATION_OVERLAY | API 26+ 唯一能浮在其他应用之上的类型 |
| 标志位 | FLAG_NOT_FOCUSABLE | 不抢焦点，不阻断下层 App 输入与输入法 |
| 权限 | SYSTEM_ALERT_WINDOW | 普通权限，无运行时弹框，但需用户到设置页手动授予 |
| 显隐入口 | 与 MCP 开关严格同步 | 避免「以为在跑其实早被杀」 |

## 文件与职责

| 文件 | 职责 |
| --- | --- |
| android/app/src/main/kotlin/.../McpFloatingBall.kt | 球视图本体：addView、拖拽、松手吸边 |
| android/app/src/main/kotlin/.../McpFloatingBallController.kt | 状态机：显示、隐藏、权限检查、引导授权 |
| lib/mcp/mcp_server_controller.dart | 通过 MethodChannel 联动原生显隐 |
| lib/mcp/mcp_status_notice.dart | 状态提示文案 |
| lib/main.dart | resumed 时自动补球，从设置页授权返回后无需二次点击 |
| android/app/src/main/AndroidManifest.xml | 声明 SYSTEM_ALERT_WINDOW |

## 踩坑

- **授权返回不补球**：用户去设置页开完权限回来，MCP 开关是开的但球不出现。main.dart 里用 resumed 回调重新同步一次，否则用户会以为功能坏而反复点开关。
- **拿 onBallDismissed 当开关**：原生侧回调目前只记日志，没有回写 Dart 状态；若后续要「拖出屏幕即关闭」，必须补一条状态同步，否则开关与实际不一致。
- **悬浮球不等于保活**：部分 ROM 对「带悬浮窗的后台应用」有更激进的清理策略。要真正长期存活仍需前台服务加常驻通知、引导关闭电池优化、部分机型加自启动白名单。不要把「球还在」当成「一定不会被杀」的保证。
- **endpoint 未透传**：showBall 的 endpoint 参数没有传到原生，所以球上暂时显示不了监听地址；若需要显示，要补 Native 侧参数接收。

## 验证方式

- dart analyze 三个改动文件应为 No issues found，全项目 lib 的 error 数为 0；
- 真机验证要跨 App：开出球后切到其他应用，球应仍在且可拖拽；
- debug 包可通过 .github/workflows/debug-apk.yml 手动构建（见 docs/32 与 docs/15）。
