import 'package:flutter/material.dart';
import 'package:mtbbs/widgets/bbcode/bbcode_toolbar.dart';

/// 通用取色弹窗：一排常用色，点一下返回该颜色，取消返回 null。
///
/// 抽成公共函数的原因：自定义格式的模板输入、「MCP 悬浮球颜色」都要用同一套
/// 配色与同一段 `#RRGGBB` 换算，各写一份必然越改越不像。
///
/// 只用 [bbcodeCommonColors] 这 16 个色，不做自由取色：
/// - 论坛 BBCode 的颜色在暗色主题下仍有可读性要求，随手挑的高饱和色容易糊；
/// - 一个网格能选完，比开 HSV 取色盘少三次点击。
/// 真需要精确色值时，用户仍可以直接在模板里手输 `#RRGGBB`。
Future<Color?> showColorPickDialog(
  BuildContext context, {
  Color? current,
  String title = '选颜色',
}) {
  return showDialog<Color>(
    context: context,
    builder: (dctx) {
      final cs = Theme.of(dctx).colorScheme;
      return AlertDialog(
        constraints: const BoxConstraints(maxWidth: 340),
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in bbcodeCommonColors)
              InkWell(
                onTap: () => Navigator.of(dctx).pop(c),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      // 当前值画一个明显边框，避免「点了取消还以为选上了」
                      color: c.toARGB32() == current?.toARGB32()
                          ? cs.primary
                          : cs.outlineVariant,
                      width: c.toARGB32() == current?.toARGB32() ? 2 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('取消'),
          ),
        ],
      );
    },
  );
}

/// `Color` → `#RRGGBB`（大写、无 alpha）。
///
/// 单独抽出来是为了能被测试直接覆盖：这个换算写错过一次（少 `padLeft` 导致
/// `#00000A` 变成 `#A`），而它在 UI 里很难肉眼发现。
String colorToHexRgb(Color color) {
  final argb = color.toARGB32();
  return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
