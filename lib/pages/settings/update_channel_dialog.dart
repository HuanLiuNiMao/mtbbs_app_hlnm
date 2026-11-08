import 'package:flutter/material.dart';
import 'package:mtbbs/config/update_config.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/services/update_service.dart';

/// 更新渠道选择对话框
///
/// 只影响「检查哪一类发布」，**不改变本包的 applicationId**。
/// 两个渠道（稳定版 / 测试版）对应 GitHub Release 的 Latest / Pre-release 标记，
/// 产物是同一个应用，因此跨渠道也能覆盖安装；这里仍提示「可能需手动下载」，
/// 是为了覆盖签名被换过（例如从 MT 内置签名切到自有 keystore）的情况。
class UpdateChannelDialog {
  static void show(BuildContext context, SettingsProvider settings) {
    final service = UpdateService.instance;
    final buildChannel = service.buildChannel;
    if (buildChannel == null) return;

    showDialog(
      context: context,
      builder: (ctx) {
        String selected = settings.updateChannel;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('更新渠道'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '当前安装包是「${buildChannel.label}」。'
                    '切换渠道只改变检查哪个渠道的更新。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _option(
                    ctx: ctx,
                    value: '',
                    groupValue: selected,
                    title: '跟随安装包',
                    subtitle: '与当前安装包一致（${buildChannel.label}）',
                    onChanged: (v) => setDialogState(() => selected = v),
                  ),
                  ...UpdateChannel.values.map(
                    (c) => _option(
                      ctx: ctx,
                      value: c.name,
                      groupValue: selected,
                      title: c.label,
                      subtitle: c.description,
                      onChanged: (v) => setDialogState(() => selected = v),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 跨渠道升级装不上的前提说明：只在用户选了与安装包不同的
                  // 「非稳定版」渠道时才有意义，这里按需提示。
                  if (selected.isNotEmpty && selected != buildChannel.name)
                    _crossChannelHint(ctx, buildChannel),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    await settings.setUpdateChannel(selected);
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static Widget _option({
    required BuildContext ctx,
    required String value,
    required String groupValue,
    required String title,
    required String subtitle,
    required ValueChanged<String> onChanged,
  }) {
    return RadioListTile<String>(
      value: value,
      groupValue: groupValue,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
    );
  }

  /// 跨渠道升级提示：说明「检测得到，但可能装不上」。
  ///
  /// [build] 是当前安装包的渠道。两个渠道产物同源同签名，正常情况下能覆盖安装；
  /// 装不上只会发生在签名变过（例如换了 keystore）或包名不同（曾经用 `.beta`
  /// 独立包）这两种历史情况，所以提示要说的是「可能」，并给出应对方式。
  static Widget _crossChannelHint(BuildContext ctx, UpdateChannel build) {
    final cs = Theme.of(ctx).colorScheme;
    final reason = build == UpdateChannel.release
        ? '测试版渠道包含预发布（Pre-release）包，版本更新但可能不稳定。'
              '两者是同一个应用，一般可直接覆盖安装；若提示签名冲突，'
              '说明中途换过签名，需要卸载后重装。'
        : '稳定版渠道只收正式发布（Latest）。当前包若仍来自旧的 `.beta` '
              '独立包，检测到的新版本可能无法直接覆盖安装，需要手动下载安装。';
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: cs.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              reason,
              style: TextStyle(fontSize: 11, color: cs.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}