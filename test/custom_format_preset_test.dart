import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/config/toolbar_config.dart';
import 'package:mtbbs/models/managed_item.dart';
import 'package:mtbbs/widgets/dialog/toolbar_template_dialog.dart';

/// 「新增自定义格式」的一键预设。
///
/// 背景：以前新增格式要在弹窗里一个字母一个字母敲
/// `[size=4][b]${selectText}[/b][/size]`，方括号/斜杠/占位符错一处就是废模板。
/// 现在弹窗顶部摆一排常用格式，点一下就把名称 / 按钮文字 / 模板全填好。

/// 挂一个最小宿主，返回可用于 showDialog 的 context。
Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext hostContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            hostContext = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return hostContext;
}

/// 固定帧推进：输入框光标闪烁会持续排帧，不能 pumpAndSettle。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 打开弹窗并等它稳定。
Future<void> _openDialog(
  WidgetTester tester,
  BuildContext context, {
  ManagedItem? initial,
  bool isCustomFormat = true,
}) async {
  showToolbarTemplateDialog(
    context,
    initial: initial,
    isCustomFormat: isCustomFormat,
  );
  await _settle(tester);
}

/// 取某个输入框的当前文本（按 label 定位，避免依赖排列顺序）。
String _textOf(WidgetTester tester, String label) {
  final field = tester.widget<TextField>(
    find.ancestor(
      of: find.text(label),
      matching: find.byType(TextField),
    ).first,
  );
  return field.controller!.text;
}

void main() {
  group('预设数据本身', () {
    test('每个预设都非空，且模板里带 ${kSelectTextToken} 占位符', () {
      expect(kBbcodePresets, isNotEmpty);
      for (final p in kBbcodePresets) {
        expect(p.name.trim(), isNotEmpty, reason: '${p.name} 名称为空');
        expect(p.label.trim(), isNotEmpty, reason: '${p.name} 按钮文字为空');
        expect(
          p.template.contains(kSelectTextToken),
          isTrue,
          reason: '${p.name} 的模板缺占位符，套用时无法包裹选中文字',
        );
      }
    });

    test('名称不重复（否则面板里两行长得一样，分不清）', () {
      final names = kBbcodePresets.map((p) => p.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('模板标签成对闭合：开标签数与闭标签数一致', () {
      // 只校验"每个 [x] 都有 [/x]"，不处理 [*] 这类自闭合标记。
      final tagRe = RegExp(r'\[(/?)([a-z]+)(?:=[^\]]*)?\]');
      for (final p in kBbcodePresets) {
        final opened = <String>[];
        var balanced = true;
        for (final m in tagRe.allMatches(p.template)) {
          final isClose = m.group(1) == '/';
          final tag = m.group(2)!;
          if (isClose) {
            if (opened.isEmpty || opened.removeLast() != tag) {
              balanced = false;
              break;
            }
          } else {
            opened.add(tag);
          }
        }
        expect(balanced && opened.isEmpty, isTrue,
            reason: '${p.name} 的模板标签未正确配对：${p.template}');
      }
    });
  });

  group('新增自定义格式：一键上屏', () {
    testWidgets('点预设后 名称 / 按钮文字 / 模板 三个框同时被填好', (tester) async {
      final context = await _pumpHost(tester);
      await _openDialog(tester, context);

      expect(find.text('常用格式（点一下自动填好，再改改就能用）'), findsOneWidget);

      final preset = kBbcodePresets.first;
      await tester.tap(find.widgetWithText(ActionChip, preset.name));
      await _settle(tester);

      expect(_textOf(tester, '名称'), preset.name);
      expect(_textOf(tester, '按钮文字'), preset.label);
      expect(_textOf(tester, '模板'), preset.template);
    });

    testWidgets('点另一个预设会整体替换，不是追加', (tester) async {
      final context = await _pumpHost(tester);
      await _openDialog(tester, context);

      await tester.tap(find.widgetWithText(ActionChip, kBbcodePresets[0].name));
      await _settle(tester);
      await tester.tap(find.widgetWithText(ActionChip, kBbcodePresets[1].name));
      await _settle(tester);

      expect(_textOf(tester, '模板'), kBbcodePresets[1].template);
      expect(_textOf(tester, '名称'), kBbcodePresets[1].name);
    });

    testWidgets('套用预设后直接保存，存下来的就是这套模板', (tester) async {
      final context = await _pumpHost(tester);
      ManagedItem? saved;
      showToolbarTemplateDialog(context, isCustomFormat: true).then((v) {
        saved = v;
      });
      await _settle(tester);

      final preset = kBbcodePresets[2];
      await tester.tap(find.widgetWithText(ActionChip, preset.name));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await _settle(tester);

      expect(saved, isNotNull);
      expect(saved!.name, preset.name);
      expect(toolbarTemplateOf(saved!), preset.template);
      expect(saved!.data?['label'], preset.label);
      // 新增项统一归入 custom 分组
      expect(saved!.data?['group'], 'custom');
      expect(saved!.id.startsWith('format_'), isTrue);
    });

    testWidgets('编辑已有格式时不显示预设（避免误覆盖用户已写好的模板）', (tester) async {
      final context = await _pumpHost(tester);
      final existing = ManagedItem(
        id: 'format_1',
        name: '我的格式',
        visible: true,
        data: const {
          'template': r'[color=#123456]${selectText}[/color]',
          'label': '我',
        },
      );
      await _openDialog(tester, context, initial: existing);

      expect(find.text('常用格式（点一下自动填好，再改改就能用）'), findsNothing);
      expect(find.byType(ActionChip), findsNothing);
      // 原有内容原封不动
      expect(_textOf(tester, '名称'), '我的格式');
      expect(_textOf(tester, '模板'), existing.data!['template']);
    });

    testWidgets('新增工具栏项（非自定义格式）不显示预设', (tester) async {
      final context = await _pumpHost(tester);
      await _openDialog(tester, context, isCustomFormat: false);

      expect(find.text('常用格式（点一下自动填好，再改改就能用）'), findsNothing);
    });

    testWidgets('点了预设又清空名称，仍然拦得住并提示', (tester) async {
      final context = await _pumpHost(tester);
      await _openDialog(tester, context);

      await tester.tap(find.widgetWithText(ActionChip, kBbcodePresets[0].name));
      await _settle(tester);

      await tester.enterText(
        find.ancestor(of: find.text('名称'), matching: find.byType(TextField)).first,
        '',
      );
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await _settle(tester);

      expect(find.text('请填写名称'), findsOneWidget);
    });
  });
}
