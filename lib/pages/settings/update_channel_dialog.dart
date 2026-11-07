import 'package:flutter/material.dart';
import 'package:mtbbs/config/update_config.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/services/update_service.dart';

/// 更新渠道选择对话框
///
/// 只影响「检查哪个渠道的发布」，**不改变本包的 applicationId**。
/// beta 是独立包（`.beta` 后缀），所以从正式版切到测试版渠道后，
/// 检测到的 beta 版本无法覆盖安装——这里必须把这件事说清楚，
/// 否则用户会以为点了下载就能升级。
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

  /// 跨渠道升级提示：说明「检测得到 ≠ 装得上」。
  ///
  /// [build] 是当前安装包的渠道，用来把「为什么装不上」说具体：
  /// 从稳定版切到测试版时，beta 包是独立 applicationId（`.beta` 后缀），
  /// 不是同一个应用，系统根本不会走「覆盖安装」这条路。
  static Widget _crossChannelHint(BuildContext ctx, UpdateChannel build) {
    final cs = Theme.of(ctx).colorScheme;
    final reason = build == UpdateChannel.release
        ? '测试版是独立安装包（包名带 .beta），与当前应用不是同一个，'
              '检测到的新版本需要手动下载安装，不会覆盖当前应用。'
        : '不同渠道的安装包签名/包名可能不同，检测到的新版本可能无法直接'
              '覆盖安装，需要手动下载安装。';
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