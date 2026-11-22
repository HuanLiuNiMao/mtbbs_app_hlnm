import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/pages/settings/error_log_page.dart';

/// 错误日志页的**渲染契约**。
///
/// 两件容易被顺手改坏、但用户会立刻感知的事：
/// 1. 页面最上方必须有「借鉴于 bggRGjQaUbCoE/PiliPlus」小字（这是需求的一部分）；
/// 2. 没有日志时不能白屏，要给出可读的空状态。
///
/// 落盘读不出数据在这里是预期行为：测试环境没有 `path_provider` 插件实现，
/// 而 `ErrorLogStore.all()` 对这种情况返回空列表（不是抛异常）——
/// 正好顺带守住「日志组件自身不崩」这条。
void main() {
  /// 挂载页面并等它读完日志。
  ///
  /// `testWidgets` 跑在 FakeAsync 里，真实文件 IO 的回调不会被调度到，
  /// 光靠 `pump()` 会永远停在 loading（页面上的转圈动画也永远停不下来，
  /// 所以这里也不用 `pumpAndSettle`）。必须用 `runAsync` 让出一次真实事件循环。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: ErrorLogPage()));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  testWidgets('页面顶部常驻借鉴出处小字', (tester) async {
    await pumpPage(tester);

    expect(find.text('错误日志'), findsOneWidget);
    expect(
      find.textContaining('bggRGjQaUbCoE/PiliPlus'),
      findsOneWidget,
      reason: '借鉴出处是需求的一部分，不能删',
    );
  });

  testWidgets('无日志时显示空状态而不是白屏', (tester) async {
    await pumpPage(tester);

    expect(find.text('相关信息'), findsOneWidget);
    expect(find.text('暂无错误日志'), findsOneWidget);
  });

  testWidgets('站点未初始化时页面仍能渲染（站点显示占位符）', (tester) async {
    // 这条守的是一个真实崩溃：`SiteStore.instance.host` 直接取
    // `_sites[_currentIndex]`，未初始化就 `RangeError`。而错误日志页恰恰是
    // 「启动早期的错误」最需要能打开的地方，它自己不能挂。
    // 测试环境本来就没有初始化 SiteStore，正好是这个场景。
    await pumpPage(tester);

    await tester.tap(find.byTooltip('展开'));
    await tester.pump();

    expect(find.textContaining('未初始化'), findsOneWidget);
  });

  testWidgets('相关信息卡默认收起，展开后显示三节', (tester) async {
    await pumpPage(tester);

    // 收起态下三节标题都不在
    expect(find.text('设备信息'), findsNothing);

    await tester.tap(find.byTooltip('展开'));
    await tester.pump();

    expect(find.text('设备信息'), findsOneWidget);
    expect(find.text('应用信息'), findsOneWidget);
    expect(find.text('编译信息'), findsOneWidget);
  });
}
