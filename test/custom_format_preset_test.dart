import 'dart:ui' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/config/toolbar_config.dart';
import 'package:mtbbs/models/managed_item.dart';
import 'package:mtbbs/models/settings/app_settings.dart';
import 'package:mtbbs/widgets/dialog/color_pick_dialog.dart';

/// 「新增自定义格式」的一键预设。
///
/// 背景：以前新增格式要在弹窗里一个字母一个字母敲
/// `[size=4][b]${selectText}[/b][/size]`，方括号/斜杠/占位符错一处就是废模板。
/// 现在弹窗顶部摆一排预设，点一下就把名称 / 按钮文字 / 模板全填好。
///
/// 预设本身已经**从代码常量搬进设置**（`EditorSettings.formatPresets`），
/// 用户能增删改，所以这里顺带守卫默认值与「删空不复活」的行为。
///
/// 弹窗本身需要 `SettingsProvider`（预设从那里读），其增删改依赖数据库，
/// 故弹窗交互不做 widget 测试 —— 本轮只测纯数据层与模板工具函数。

/// 取模板文本（`ManagedItem` 的 `data['template']`）。
String? _tpl(ManagedItem item) => toolbarTemplateOf(item);

void main() {
  group('内置预设数据（defaultFormatPresets）', () {
    test('每个预设都非空，且模板里带 ${kSelectTextToken} 占位符', () {
      final defaults = defaultFormatPresets();
      expect(defaults, isNotEmpty);
      for (final item in defaults) {
        expect(item.name.trim(), isNotEmpty, reason: '名称不能为空');
        final tpl = _tpl(item);
        expect(tpl, isNotNull, reason: '${item.name} 没有 template');
        expect(
          tpl!.contains(kSelectTextToken),
          isTrue,
          reason: '${item.name} 的模板缺占位符，套用时无法包裹选中文字',
        );
      }
    });

    test('id 唯一且带 preset_ 前缀（与 customFormats 的 format_ 区分）', () {
      final ids = defaultFormatPresets().map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'id 必须唯一');
      for (final id in ids) {
        expect(id.startsWith(kFormatPresetIdPrefix), isTrue, reason: id);
      }
    });

    test('名称不重复（否则面板里两行长得一样，分不清）', () {
      final names = defaultFormatPresets().map((e) => e.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('模板标签成对闭合：开标签数与闭标签数一致', () {
      // 只校验"每个 [x] 都有 [/x]"，不处理 [*] 这类自闭合标记。
      final tagRe = RegExp(r'\[(/?)([a-z]+)(?:=[^\]]*)?\]');
      for (final item in defaultFormatPresets()) {
        final template = _tpl(item)!;
        final opened = <String>[];
        var balanced = true;
        for (final m in tagRe.allMatches(template)) {
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
        expect(
          balanced && opened.isEmpty,
          isTrue,
          reason: '${item.name} 的模板标签未正确配对：$template',
        );
      }
    });

    test('每个预设都有按钮文字 label', () {
      for (final item in defaultFormatPresets()) {
        final label = item.data?['label']?.toString() ?? '';
        expect(label.trim(), isNotEmpty, reason: '${item.name} 的 label 为空');
      }
    });

    test('两座「默认值」不漂移：kBbcodePresets 与 defaultFormatPresets 一一对应', () {
      final defaults = defaultFormatPresets();
      expect(defaults.length, kBbcodePresets.length);
      for (var i = 0; i < kBbcodePresets.length; i++) {
        expect(defaults[i].name, kBbcodePresets[i].name);
        expect(_tpl(defaults[i]), kBbcodePresets[i].template);
        expect(defaults[i].data?['label'], kBbcodePresets[i].label);
      }
    });
  });

  group('预设持久化语义（EditorSettings 序列化）', () {
    test('老设置文件没有 formatPresets 键 → 回落内置预设', () {
      // 模拟升级前的老文件：只有 customFormats，没有 formatPresets
      final restored = EditorSettings.fromMap(const {
        'customFormats': <dynamic>[],
        'quickReplies': <dynamic>[],
        'toolbarItems': <dynamic>[],
      });
      expect(restored.formatPresets.length, kBbcodePresets.length);
    });

    test('用户把预设删空（存了 []）→ 不会复活内置列表', () {
      // 关键区别：键存在但为空数组，必须尊重「我就是要空」
      final restored = EditorSettings.fromMap(const {
        'customFormats': <dynamic>[],
        'formatPresets': <dynamic>[],
        'quickReplies': <dynamic>[],
        'toolbarItems': <dynamic>[],
      });
      expect(restored.formatPresets, isEmpty);
    });

    test('往返：存下来的预设能原样读回', () {
      final original = defaultFormatPresets().take(3).toList();
      final map = EditorSettings.defaults().toMap();
      map['formatPresets'] = original.map((e) => e.toJson()).toList();
      final restored = EditorSettings.fromMap(map);
      expect(restored.formatPresets.length, 3);
      for (var i = 0; i < 3; i++) {
        expect(restored.formatPresets[i].id, original[i].id);
        expect(restored.formatPresets[i].name, original[i].name);
        expect(_tpl(restored.formatPresets[i]), _tpl(original[i]));
      }
    });

    test('toMap 永远写出 formatPresets 键（哪怕空列表）', () {
      final map = EditorSettings.defaults().toMap();
      expect(map.containsKey('formatPresets'), isTrue);
    });
  });

  group('选色换算（公共 colorToHexRgb）', () {
    test('颜色转 #RRGGBB 格式：补零、大写、去掉 alpha', () {
      // 纯红
      expect(colorToHexRgb(const Color(0xFFFF0000)), '#FF0000');
      // 深色也要补零：0x0000000A 不可丢前导 0
      expect(colorToHexRgb(const Color(0xFF00000A)), '#00000A');
      // 常见灰
      expect(colorToHexRgb(const Color(0xFF808080)), '#808080');
      // 小写输入也要变成大写
      expect(colorToHexRgb(const Color(0xFFe53935)), '#E53935');
    });

    test('半透明色只取 RGB，alpha 不进 BBCode', () {
      // 悬浮球缩起时是半透明的，但写进模板的颜色不该带 alpha
      expect(colorToHexRgb(const Color(0x80FF0000)), '#FF0000');
    });
  });
}