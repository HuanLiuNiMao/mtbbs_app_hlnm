import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/config/app_typography.dart';
import 'package:mtbbs/config/toolbar_config.dart';
import 'package:mtbbs/models/managed_item.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/widgets/dialog/confirm_dialog.dart';
import 'package:mtbbs/widgets/dialog/managed_list_dialog.dart';
import 'package:mtbbs/widgets/dialog/color_pick_dialog.dart';

/// 模板类条目的编辑弹窗（工具栏「模板项」与「自定义格式」共用）。
///
/// 模板 = 一段含 `${selectText}` 占位符的 BBCode 文本，用于包裹选中文字
/// （无选中时占位符为空，光标落在标签之间）。
///
/// 两个语境只差文案：工具栏模板进工具栏，自定义格式只在「自定义格式」面板里列出。
Future<ManagedItem?> showToolbarTemplateDialog(
  BuildContext context, {
  ManagedItem? initial,
  bool isCustomFormat = false,
}) {
  return showDialog<ManagedItem>(
    context: context,
    builder: (_) => _ToolbarTemplateDialog(
      initial: initial,
      isCustomFormat: isCustomFormat,
    ),
  );
}

class _ToolbarTemplateDialog extends StatefulWidget {
  final ManagedItem? initial;
  final bool isCustomFormat;

  const _ToolbarTemplateDialog({this.initial, this.isCustomFormat = false});

  @override
  State<_ToolbarTemplateDialog> createState() => _ToolbarTemplateDialogState();
}

class _ToolbarTemplateDialogState extends State<_ToolbarTemplateDialog> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _labelCtl;
  late final TextEditingController _templateCtl;
  String? _error;

  bool get _isCustomFormat => widget.isCustomFormat;
  bool get _isCustom =>
      widget.initial == null || isCustomToolbarItem(widget.initial!);
  bool get _isEditing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameCtl = TextEditingController(text: initial?.name ?? '');
    _labelCtl = TextEditingController(
      text: initial?.data?['label']?.toString() ?? '',
    );
    _templateCtl = TextEditingController(
      text: initial == null ? '' : (toolbarTemplateOf(initial) ?? ''),
    );
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _labelCtl.dispose();
    _templateCtl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtl.text.trim();
    final template = _templateCtl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写名称');
      return;
    }
    if (template.isEmpty) {
      setState(() => _error = '请填写模板内容');
      return;
    }

    final initial = widget.initial;
    final data = <String, dynamic>{
      ...?initial?.data,
      'template': template,
      'label': _labelCtl.text.trim(),
      // 新增项统一归入 custom 分组；编辑项沿用原分组
      if (initial == null) 'group': 'custom',
    };
    final prefix = widget.isCustomFormat ? 'format' : 'custom';
    final item = ManagedItem(
      id: initial?.id ?? '${prefix}_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      visible: initial?.visible ?? true,
      data: data,
    );
    Navigator.of(context).pop(item);
  }

  String get _title {
    if (_isCustomFormat) return _isEditing ? '编辑自定义格式' : '新增自定义格式';
    return _isEditing ? '编辑工具栏项' : '新增工具栏项';
  }

  /// 是否显示「常用格式」一键预设。
  ///
  /// 只在**新增自定义格式**时给：编辑时若也摆一排，手一滑就把用户已写好的
  /// 模板连名称一起覆盖掉，而他本来只是想改个颜色值。
  bool get _showPresets => _isCustomFormat && !_isEditing;

  /// 把预设的三个字段一起填进输入框。
  ///
  /// 光标一并推到模板末尾：`TextEditingController.text` 的 setter 会把
  /// selection 置成 `offset: -1`（相当于"无光标"），此时用户接着打字有概率
  /// 把内容插到开头，看起来像"点了预设又变成了乱码"。
  void _applyPreset(ManagedItem preset) {
    final template = toolbarTemplateOf(preset) ?? '';
    setState(() {
      _nameCtl.text = preset.name;
      _labelCtl.text = toolbarLabelOf(preset);
      _templateCtl.text = template;
      _templateCtl.selection = TextSelection.collapsed(
        offset: template.length,
      );
      _error = null;
    });
  }

  /// 选色并插入到模板光标处。
  ///
  /// 只插入 `#RRGGBB` 而不替用户补 `[color=]` 标签：同一个色值可能用于
  /// `[color]` 或 `[backcolor]`，甚至写进 `[table]` 背景，猜错了反而更麻烦。
  Future<void> _pickColor(BuildContext context) async {
    final picked = await showColorPickDialog(context);
    if (picked == null) return;
    final text = colorToHexRgb(picked);
    // 有选区就替换掉，无选区就插在光标处（没有光标则追加到末尾）
    final sel = _templateCtl.selection;
    final hasSel = sel.isValid;
    final start = hasSel ? sel.start : _templateCtl.text.length;
    final end = hasSel ? sel.end : _templateCtl.text.length;
    setState(() {
      _templateCtl.value = TextEditingValue(
        text: _templateCtl.text.replaceRange(start, end, text),
        selection: TextSelection.collapsed(offset: start + text.length),
      );
    });
  }

  /// 打开「管理常用格式」面板（增 / 删 / 改 / 排序 / 恢复默认）。
  ///
  /// 复用 [showManagedListDialog]：它已经处理了拖动排序、长按删除、
  /// 逐项显隐与「新增」按钮，没必要为预设再写一套。
  Future<void> _managePresets(BuildContext context) async {
    final settings = context.read<SettingsProvider>();
    await showManagedListDialog(
      context: context,
      title: '管理常用格式',
      items: settings.formatPresets,
      emptyHint: '暂无预设，点右上角 + 添加',
      allowToggleVisibility: false,
      onAdd: () async {
        final created = await showToolbarTemplateDialog(
          context,
          isCustomFormat: true,
        );
        if (created == null) return null;
        // 预设自带稳定 id 前缀，避免和 customFormats 的 format_ 混淆
        final item = ManagedItem(
          id: '${kFormatPresetIdPrefix}${DateTime.now().millisecondsSinceEpoch}',
          name: created.name,
          visible: true,
          data: created.data,
        );
        await settings.addFormatPreset(item);
        return item;
      },
      onEdit: (item) async {
        final edited = await showToolbarTemplateDialog(
          context,
          initial: item,
          isCustomFormat: true,
        );
        if (edited == null) return null;
        await settings.updateFormatPreset(item.id, edited);
        return edited;
      },
      onDelete: (id) async {
        await settings.deleteFormatPreset(id);
        return true;
      },
      onReorder: (from, to) => settings.moveFormatPreset(from, to),
      titleActions: [
        IconButton(
          tooltip: '恢复默认预设',
          icon: const Icon(Icons.restore, size: 20),
          onPressed: () async {
            final ok = await showConfirmDialog(
              context,
              title: '恢复默认预设',
              message: '会用内置的 ${kBbcodePresets.length} 个常用格式覆盖当前列表，'
                  '你自己加过的预设不会被保留。确定吗？',
              confirmText: '恢复',
            );
            if (ok == true) await settings.resetFormatPresets();
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 预设来自设置（用户可增删改），不再写死在代码里。
    // 用 `watch` 而非 `read`：用户在「管理」里改完返回，这排 chip 要立刻跟着变。
    final presets = context.watch<SettingsProvider>().formatPresets;
    return AlertDialog(
      title: Text(_title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_showPresets) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '常用格式（点一下自动填好，再改改就能用）',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _managePresets(context),
                      icon: const Icon(Icons.tune, size: 16),
                      label: const Text('管理', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final preset in presets)
                      ActionChip(
                        label: Text(preset.name),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _applyPreset(preset),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Divider(height: 1, color: cs.outlineVariant),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _nameCtl,
                enabled: _isCustom,
                decoration: InputDecoration(
                  labelText: '名称',
                  helperText: _isCustomFormat
                      ? '显示在「自定义格式」面板与按钮 tooltip'
                      : '显示在 tooltip 与设置列表',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _labelCtl,
                decoration: InputDecoration(
                  labelText: '按钮文字',
                  helperText: _isCustomFormat
                      ? '格式条目的紧凑标签，可留空（留空则用名称）'
                      : '工具栏按钮上显示的文字，如 H1；留空则用名称',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _templateCtl,
                maxLines: 4,
                minLines: 2,
                style: context.appTypography.mono.copyWith(fontSize: 13),
                decoration: const InputDecoration(
                  labelText: '模板',
                  helperText: r'用 ${selectText} 代表选中文字（无选中时为空）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 6),
              // 取色入口：手写 `[color=#1A2B3C]` 容易写错位，点选更省事。
              // 只插入 `#RRGGBB` 本身，不替用户补标签 —— 他要套 color 还是
              // backcolor 得自己决定，替错了反而更难改。
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => _pickColor(context),
                    icon: const Icon(Icons.palette_outlined, size: 16),
                    label: const Text('选颜色', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '插到光标处',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '示例：[size=4][b]\${selectText}[/b][/size]',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: cs.error, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
