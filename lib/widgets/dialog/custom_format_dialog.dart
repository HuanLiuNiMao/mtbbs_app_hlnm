import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:mtbbs/config/toolbar_config.dart';
import 'package:mtbbs/models/managed_item.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/widgets/bbcode/bbcode_controller.dart';
import 'package:mtbbs/widgets/common/toast_utils.dart';

/// 「自定义格式」选择面板（工具栏项 `customFormat` 的动作）。
///
/// 列出 `settings.customFormats` 里可见的格式，点选后按模板语义套用到正文：
/// 有选中 → 包裹选中文字；无选中 → 插入标签、光标落在中间。
///
/// 面板右上角有设置入口，直达编辑器设置页的「自定义格式」管理。
Future<void> showCustomFormatPicker(
  BuildContext context,
  BBCodeController contentCtl,
  VoidCallback focus,
) async {
  final formats = context
      .read<SettingsProvider>()
      .customFormats
      .where((e) => e.visible)
      .toList();
  if (formats.isEmpty) {
    showToast('暂无自定义格式，可在设置中添加');
    return;
  }

  final picked = await showDialog<ManagedItem>(
    context: context,
    builder: (dctx) => AlertDialog(
      constraints: const BoxConstraints(maxWidth: 380, maxHeight: 480),
      title: Row(
        children: [
          const Expanded(child: Text('自定义格式')),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            tooltip: '格式设置',
            onPressed: () {
              Navigator.of(dctx).pop();
              context.push('/settings/editor');
            },
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: '关闭',
            onPressed: () => Navigator.of(dctx).pop(),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in formats)
              ListTile(
                dense: true,
                title: Text(f.name),
                subtitle: Text(
                  toolbarTemplateOf(f) ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
                trailing: toolbarLabelOf(f) == f.name
                    ? null
                    : Text(
                        toolbarLabelOf(f),
                        style: const TextStyle(fontSize: 12),
                      ),
                onTap: () => Navigator.of(dctx).pop(f),
              ),
          ],
        ),
      ),
    ),
  );

  if (picked == null) return;
  final template = toolbarTemplateOf(picked);
  if (template == null) return;

  if (toolbarIsBlockOf(picked) && !template.contains(kSelectTextToken)) {
    contentCtl.insertBlockTag(template);
  } else {
    contentCtl.applyTemplate(template);
  }
  focus();
}
