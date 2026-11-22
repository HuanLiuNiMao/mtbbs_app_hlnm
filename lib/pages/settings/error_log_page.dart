import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mtbbs/config/build_config.dart';
import 'package:mtbbs/core/app/site_store.dart';
import 'package:mtbbs/core/utils/clipboard_helper.dart';
import 'package:mtbbs/core/utils/formatters.dart';
import 'package:mtbbs/services/error_log/error_log_entry.dart';
import 'package:mtbbs/services/error_log/error_log_store.dart';
import 'package:mtbbs/widgets/common/toast_utils.dart';
import 'package:mtbbs/widgets/dialog/confirm_dialog.dart';

/// 错误日志页 —— 把 [ErrorLogStore] 累积的未捕获错误按「卡片流」展示。
///
/// **形式与交互完全借鉴 bggRGjQaUbCoE/PiliPlus 的「日志」页**
/// （https://github.com/bggRGjQaUbCoE/PiliPlus，`lib/pages/setting/pages/logs.dart`）。
/// 页面最上方的小字即为出处标注。
///
/// 与上游的差异仅有两处，都是本仓库环境决定的：
/// - 上游放在「设置 → 日志」，本仓库按需求挂在**关于页 → 数据管理**；
/// - 上游用 `catcher_2` 采集，本仓库自己装钩子（见 `ErrorLogStore.install`）。
///
/// 页面结构（与上游一一对应）：
/// 1. 顶部「相关信息」卡：设备 / 应用 / 编译三节，可展开、可整段复制；
/// 2. 错误卡片：标题（错误首行）+ 时间 + 复制 + 展开；
/// 3. 展开后：「错误详情」与「堆栈跟踪」，等宽字体、可选中、包内帧加粗；
/// 4. 右上角菜单：复制全部 / 清空 / 错误反馈（调试包额外有「引发错误」）。
class ErrorLogPage extends StatefulWidget {
  const ErrorLogPage({super.key});

  @override
  State<ErrorLogPage> createState() => _ErrorLogPageState();
}

class _ErrorLogPageState extends State<ErrorLogPage> {
  List<_ExpandedItem<ErrorLogEntry>>? _logs;
  bool _loading = true;
  bool _infoExpanded = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await ErrorLogStore.instance.all();
    if (!mounted) return;
    setState(() {
      _logs = [for (final e in list) _ExpandedItem(e)];
      _loading = false;
    });
  }

  // ==================== 菜单动作 ====================

  Future<void> _copyAll() async {
    final logs = _logs ?? const [];
    if (logs.isEmpty) {
      showToast('暂无日志可复制', duration: const Duration(seconds: 1));
      return;
    }
    // 与上游一致：包一层代码块，贴到 issue / 论坛里不会被 Markdown 吃掉格式。
    // 正文统一由 exportText 生成，避免「页面复制的格式」与「导出格式」各写一套。
    final text = '```\n${await ErrorLogStore.instance.exportText()}\n```';
    final ok = await ClipboardHelper.write(text);
    if (!mounted) return;
    showToast(
      ok ? '已复制 ${logs.length} 条日志' : '复制失败，请检查剪切板权限',
      duration: const Duration(seconds: 1),
    );
  }

  Future<void> _clear() async {
    final ok = await showConfirmDialog(
      context,
      title: '清空错误日志',
      message: '将删除全部已记录的错误（共 ${_logs?.length ?? 0} 条），不影响其它数据。',
      confirmText: '清空',
      danger: true,
    );
    if (ok != true || !mounted) return;
    final done = await ErrorLogStore.instance.clear();
    if (!mounted) return;
    if (!done) {
      showToast('清空失败');
      return;
    }
    setState(() => _logs = []);
    showToast('已清空', duration: const Duration(seconds: 1));
  }

  Future<void> _openIssues() async {
    final uri = Uri.parse('${BuildConfig.repoUrl}/issues');
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) showToast('无法打开链接');
  }

  /// 调试包专用：立刻制造一条错误，用来验证采集链路通不通。
  void _raiseTestError() {
    ErrorLogStore.report(
      '这是一条用于验证错误日志链路的测试错误',
      stack: StackTrace.current,
      source: '手动上报',
      context: {'触发入口': '错误日志页 → 引发错误'},
    );
    showToast('已写入一条测试错误', duration: const Duration(seconds: 1));
    // 写入是异步串行的，稍等一下再读，否则刚写的那条还没落盘
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _reload();
    });
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('错误日志'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'copy':
                  _copyAll();
                case 'clear':
                  _clear();
                case 'issues':
                  _openIssues();
                case 'test':
                  _raiseTestError();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'copy', child: Text('复制日志')),
              const PopupMenuItem(value: 'issues', child: Text('错误反馈')),
              const PopupMenuItem(value: 'clear', child: Text('清空日志')),
              if (kDebugMode)
                const PopupMenuItem(value: 'test', child: Text('引发错误')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 需求要求：**界面最上方**用小字说明借鉴出处。
          // 固定在滚动区之外，保证不论滑到哪里、有没有日志都能看到。
          _creditLine(cs),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: _buildBody(cs),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _creditLine(ColorScheme cs) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        '本页形式与交互借鉴于 GitHub 仓库 bggRGjQaUbCoE/PiliPlus',
        style: TextStyle(fontSize: 11, height: 1.3, color: cs.outline),
      ),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    final logs = _logs ?? const [];
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: _InfoCard(
              device: _deviceInfo(),
              app: _appInfo(),
              buildInfo: _buildInfo(),
              expanded: _infoExpanded,
              onToggle: () => setState(() => _infoExpanded = !_infoExpanded),
            ),
          ),
        ),
        if (logs.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 80),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline, size: 44, color: cs.outline),
                    const SizedBox(height: 12),
                    Text(
                      '暂无错误日志',
                      style: TextStyle(color: cs.outline, fontSize: 14),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '应用运行中未被捕获的错误会记录在这里',
                      style: TextStyle(color: cs.outline, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
            sliver: SliverList.separated(
              itemCount: logs.length,
              itemBuilder: (_, i) => _ReportCard(item: logs[i]),
              separatorBuilder: (_, __) => const SizedBox(height: 12),
            ),
          ),
      ],
    );
  }

  // ==================== 信息卡数据 ====================

  Map<String, String> _deviceInfo() {
    final size = MediaQuery.maybeSizeOf(context);
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context);
    return {
      '系统': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'CPU 核心数': '${Platform.numberOfProcessors}',
      '区域 / 语言': Platform.localeName,
      if (size != null)
        '窗口逻辑尺寸': '${size.width.toStringAsFixed(0)} × '
            '${size.height.toStringAsFixed(0)}',
      if (ratio != null) '像素密度': ratio.toStringAsFixed(2),
    };
  }

  Map<String, String> _appInfo() {
    return {
      '应用版本': BuildConfig.versionName,
      '构建号': '${BuildConfig.versionCode}',
      if (kDebugMode) '构建形态': 'debug',
      if (!kDebugMode && BuildConfig.isBeta) '构建形态': 'beta',
      '当前站点': _currentHost(),
      '日志条数': '${_logs?.length ?? 0} / ${ErrorLogStore.maxEntries}',
    };
  }

  /// 当前站点域名；**站点表为空时不能抛**。
  ///
  /// `SiteStore.instance.host` 直接取 `_sites[_currentIndex]`，未初始化（单测、
  /// 极端早期的启动错误）会 `RangeError`。错误日志页是排障入口，它自己崩掉
  /// 就等于把唯一的诊断线索也弄丢了，所以这里降级成占位符。
  String _currentHost() {
    try {
      final store = SiteStore.instance;
      if (store.sites.isEmpty) return '（未初始化）';
      return store.host;
    } catch (_) {
      return '（未初始化）';
    }
  }

  Map<String, String> _buildInfo() {
    final t = BuildConfig.buildTime;
    return {
      '提交': BuildConfig.commitHash,
      '编译时间': t > 0
          ? formatDateTimeFull(
              DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true)
                  .toLocal(),
            )
          : 'N/A',
      'Dart': Platform.version.split(' ').first,
    };
  }
}

/// 展开状态包一层：和上游一样，状态放在数据里而不是另开一个 Set。
class _ExpandedItem<T> {
  _ExpandedItem(this.item);

  final T item;
  bool isExpanded = false;
}

/// 顶部「相关信息」卡（对应上游的 `_InfoCard`）
class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.device,
    required this.app,
    required this.buildInfo,
    required this.expanded,
    required this.onToggle,
  });

  final Map<String, String> device;
  final Map<String, String> app;
  final Map<String, String> buildInfo;
  final bool expanded;
  final VoidCallback onToggle;

  String _asText() {
    final b = StringBuffer();
    void section(String title, Map<String, String> map) {
      if (map.isEmpty) return;
      b.writeln('[$title]');
      map.forEach((k, v) => b.writeln('$k: $v'));
      b.writeln();
    }

    section('设备信息', device);
    section('应用信息', app);
    section('编译信息', buildInfo);
    return b.toString().trimRight();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, size: 22, color: cs.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '相关信息',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  tooltip: '复制',
                  icon: const Icon(Icons.copy_outlined),
                  onPressed: () async {
                    final ok = await ClipboardHelper.write(_asText());
                    if (context.mounted) {
                      showToast(
                        ok ? '相关信息已复制' : '复制失败',
                        duration: const Duration(seconds: 1),
                      );
                    }
                  },
                ),
                IconButton(
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  tooltip: expanded ? '收起' : '展开',
                  icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: onToggle,
                ),
              ],
            ),
            if (expanded) ...[
              _section(cs, '设备信息', device),
              _section(cs, '应用信息', app),
              _section(cs, '编译信息', buildInfo),
            ],
          ],
        ),
      ),
    );
  }

  Widget _section(ColorScheme cs, String title, Map<String, String> map) {
    if (map.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: cs.primary,
          ),
        ),
        const SizedBox(height: 4),
        for (final e in map.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '• ${e.key}: ',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  TextSpan(text: e.value),
                ],
              ),
              style: const TextStyle(fontSize: 13, height: 1.35),
            ),
          ),
      ],
    );
  }
}

/// 单条错误卡片（对应上游的 `_ReportCard`）
class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.item});

  final _ExpandedItem<ErrorLogEntry> item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entry = item.item;
    final stack = _formatStack(entry.stackTrace);
    final time = ErrorLogEntry.formatDateTime(entry.at);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            time,
                            style: TextStyle(fontSize: 13, color: cs.outline),
                          ),
                          if (entry.source.isNotEmpty) ...[
                            Text(
                              ' · ',
                              style: TextStyle(fontSize: 13, color: cs.outline),
                            ),
                            Text(
                              entry.source,
                              style: TextStyle(fontSize: 13, color: cs.outline),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  tooltip: '复制',
                  icon: const Icon(Icons.copy_outlined),
                  onPressed: () async {
                    final ok = await ClipboardHelper.write(
                      '```\n${entry.format()}\n```',
                    );
                    if (context.mounted) {
                      showToast(
                        ok ? '已将 $time 复制至剪切板' : '复制失败',
                        duration: const Duration(seconds: 1),
                      );
                    }
                  },
                ),
                IconButton(
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  tooltip: item.isExpanded ? '收起' : '展开',
                  icon: Icon(
                    item.isExpanded ? Icons.expand_less : Icons.expand_more,
                  ),
                  onPressed: () {
                    item.isExpanded = !item.isExpanded;
                    // 与上游同样的做法：卡片自身无状态，改完标记重建
                    (context as Element).markNeedsBuild();
                  },
                ),
              ],
            ),
            if (item.isExpanded) ...[
              const SizedBox(height: 12),
              _label(cs, '错误详情'),
              const SizedBox(height: 8),
              _codeBox(
                cs,
                child: SelectableText(
                  entry.error,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.4,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
              if (stack.isNotEmpty) ...[
                const SizedBox(height: 12),
                _label(cs, '堆栈跟踪'),
                const SizedBox(height: 8),
                _codeBox(
                  cs,
                  child: SelectableText.rich(
                    TextSpan(
                      children: [
                        for (final line in stack)
                          TextSpan(
                            text: '$line\n',
                            style: line.contains('package:mtbbs')
                                ? TextStyle(
                                    color: cs.onSurface,
                                    fontWeight: FontWeight.w600,
                                  )
                                : TextStyle(color: cs.onSurfaceVariant),
                          ),
                      ],
                    ),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ],
              if (entry.context.isNotEmpty) ...[
                const SizedBox(height: 12),
                _label(cs, '附加信息'),
                const SizedBox(height: 8),
                for (final e in entry.context.entries)
                  Text(
                    '• ${e.key}: ${e.value}',
                    style: const TextStyle(fontSize: 12, height: 1.4),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _label(ColorScheme cs, String text) => Text(
    text,
    style: TextStyle(
      fontWeight: FontWeight.bold,
      fontSize: 14,
      color: cs.error,
    ),
  );

  Widget _codeBox(ColorScheme cs, {required Widget child}) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: cs.surface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: cs.outline.withValues(alpha: 0.5)),
    ),
    child: child,
  );

  /// 与上游一致：过滤空行与 "null"，避免展开后一大片空白
  static List<String> _formatStack(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty || text == 'null') return const [];
    return [
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty) line.trimRight(),
    ];
  }
}
