/// 阅读器统一控件覆盖层 — 对齐 uihtml/阅读控件改2.html 设计
///
/// 点击正文 → 顶部弹出不透明控件栏（覆盖状态栏）+ 底部弹出不透明控件栏
/// （覆盖导航栏）+ 中间悬浮 4 个圆形按钮。中间区域保持透明可看到正文。
///
/// 适配暗色/亮色模式，控件栏使用 colorScheme.surface，状态栏图标自动反色。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/providers.dart';

class ReaderControlOverlay extends StatelessWidget {
  final ReaderSettings settings;

  final String bookName;
  final String currentChapterTitle;
  final String sourceName;
  final String sourceUrl;
  final String chapterUrl;
  final bool hasBookmark;

  final int chapterCount;
  final int currentIndex;
  final double? sliderValue;
  final bool hasPrev;
  final bool hasNext;
  final bool isAutoScrolling;
  final bool isNightMode;

  final bool isVisible;

  final VoidCallback onBack;
  final VoidCallback onChangeSource;
  final VoidCallback onRefreshChapter;
  final VoidCallback onStartDownload;
  final VoidCallback onToggleBookmark;
  final VoidCallback onClose;

  final ValueChanged<double> onSliderChanged;
  final ValueChanged<int> onSliderChangeEnd;
  final VoidCallback onPrevChapter;
  final VoidCallback onNextChapter;
  final VoidCallback onStartSearch;
  final VoidCallback onToggleAutoScroll;
  final VoidCallback onToggleNightMode;
  final VoidCallback onOpenReplaceRules;
  final VoidCallback onShowDirectory;
  final VoidCallback onStartTts;
  final VoidCallback onShowReaderSettings;

  const ReaderControlOverlay({
    super.key,
    required this.settings,
    required this.bookName,
    required this.currentChapterTitle,
    required this.sourceName,
    required this.sourceUrl,
    required this.chapterUrl,
    required this.hasBookmark,
    required this.chapterCount,
    required this.currentIndex,
    required this.sliderValue,
    required this.hasPrev,
    required this.hasNext,
    required this.isAutoScrolling,
    required this.isNightMode,
    required this.isVisible,
    required this.onBack,
    required this.onChangeSource,
    required this.onRefreshChapter,
    required this.onStartDownload,
    required this.onToggleBookmark,
    required this.onClose,
    required this.onSliderChanged,
    required this.onSliderChangeEnd,
    required this.onPrevChapter,
    required this.onNextChapter,
    required this.onStartSearch,
    required this.onToggleAutoScroll,
    required this.onToggleNightMode,
    required this.onOpenReplaceRules,
    required this.onShowDirectory,
    required this.onStartTts,
    required this.onShowReaderSettings,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = cs.brightness == Brightness.dark;
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;

    return Positioned(
      left: 0,
      top: 0,
      right: 0,
      bottom: 0,
      child: LayoutBuilder(
        builder: (context, constraints) {
          debugPrint(
            '[ReaderOverlay] visible=$isVisible '
            'screen=(${screenW.toStringAsFixed(0)},${screenH.toStringAsFixed(0)}) '
            'box=(${constraints.maxWidth.toStringAsFixed(0)},${constraints.maxHeight.toStringAsFixed(0)}) '
            'topPad=$topPad botPad=$botPad',
          );

          return IgnorePointer(
            ignoring: !isVisible,
            child: Column(
              children: [
                // ---- Top bar ----
                AnimatedOpacity(
                  opacity: isVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: AnnotatedRegion<SystemUiOverlayStyle>(
                    value: SystemUiOverlayStyle(
                      statusBarColor: cs.surface,
                      statusBarIconBrightness:
                          isDark ? Brightness.light : Brightness.dark,
                    ),
                    child: Material(
                      color: cs.surface,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(8, topPad, 4, 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _headerRow1(context, cs),
                            const SizedBox(height: 4),
                            _headerRow2(cs),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // ---- Middle ----
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onClose,
                        ),
                      ),
                      AnimatedOpacity(
                        opacity: isVisible ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 250),
                        child: Align(
                          alignment: const Alignment(0, 0.85),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                                _fab(Icons.search, cs, onTap: onStartSearch),
                                _fab(
                                  isAutoScrolling
                                      ? Icons.pause
                                      : Icons.autorenew,
                                  cs,
                                  onTap: onToggleAutoScroll,
                                ),
                                _fab(
                                  isNightMode
                                      ? Icons.wb_sunny
                                      : Icons.nightlight_round,
                                  cs,
                                  onTap: onToggleNightMode,
                                ),
                                _fab(
                                  Icons.settings,
                                  cs,
                                  onTap: onShowReaderSettings,
                                ),
                              ],
                            ),
                          ),
                      ),
                    ],
                  ),
                ),

                // ---- Bottom bar ----
                AnimatedOpacity(
                  opacity: isVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: Material(
                    color: cs.surface,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(12, 4, 12, botPad),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _progressBar(context, cs),
                          const SizedBox(height: 8),
                          _bottomNav(context, cs),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _headerRow1(BuildContext context, ColorScheme cs) {
    final title = bookName.isNotEmpty
        ? bookName
        : currentChapterTitle.isNotEmpty
            ? currentChapterTitle
            : '阅读';
    return Row(
      children: [
        _iconBtn(Icons.arrow_back, cs, tooltip: '返回', onTap: onBack),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: cs.onSurface,
            ),
          ),
        ),
        _iconBtn(Icons.swap_horiz, cs, tooltip: '换源', onTap: onChangeSource),
        _iconBtn(Icons.refresh, cs, tooltip: '刷新', onTap: onRefreshChapter),
        _iconBtn(Icons.download, cs, tooltip: '缓存', onTap: onStartDownload),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant, size: 24),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onSelected: (v) {
            if (v == 'bookmark') onToggleBookmark();
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'bookmark',
              child: Row(
                children: [
                  Icon(
                    hasBookmark ? Icons.bookmark : Icons.bookmark_border,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  const Text('书签'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'more',
              enabled: false,
              child: Text('更多设置…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _headerRow2(ColorScheme cs) {
    final label = sourceName.isNotEmpty ? sourceName : '书源';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (currentChapterTitle.isNotEmpty)
                  Text(
                    currentChapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                if (sourceUrl.isNotEmpty || chapterUrl.isNotEmpty)
                  Text(
                    sourceUrl.isNotEmpty ? sourceUrl : chapterUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurfaceVariant.withAlpha(0x99),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressBar(BuildContext context, ColorScheme cs) {
    final maxCh = (chapterCount - 1).toDouble();
    final maxChClamped = maxCh < 0 ? 0.0 : maxCh;
    final cur = (sliderValue ?? currentIndex.toDouble())
        .clamp(0, maxChClamped) as double;
    return Row(
      children: [
        _labelBtn('上一章', cs, hasPrev ? onPrevChapter : null),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 7),
              activeTrackColor: cs.primary,
              inactiveTrackColor: cs.surfaceContainerHighest,
              thumbColor: cs.primary,
            ),
            child: Slider(
              value: cur,
              min: 0,
              max: maxChClamped,
              divisions: chapterCount > 1 ? chapterCount - 1 : 1,
              onChanged: onSliderChanged,
              onChangeEnd: (v) {
                final idx = v.round().clamp(0, chapterCount - 1);
                onSliderChangeEnd(idx);
              },
            ),
          ),
        ),
        _labelBtn('下一章', cs, hasNext ? onNextChapter : null),
      ],
    );
  }

  Widget _bottomNav(BuildContext context, ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _navBtn(Icons.list, '目录', cs, onShowDirectory),
        _navBtn(Icons.headphones, '朗读', cs, onStartTts),
        _navBtn(Icons.format_size, '界面', cs, onToggleNightMode),
        _navBtn(Icons.settings, '设置', cs, onShowReaderSettings),
      ],
    );
  }

  Widget _iconBtn(IconData icon, ColorScheme cs,
      {String? tooltip, required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Tooltip(
        message: tooltip ?? '',
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration:
              BoxDecoration(borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: cs.onSurfaceVariant, size: 24),
        ),
      ),
    );
  }

  Widget _labelBtn(String label, ColorScheme cs, VoidCallback? onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            color: onTap != null
                ? cs.onSurfaceVariant
                : cs.onSurfaceVariant.withAlpha(0x40),
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _navBtn(
      IconData icon, String label, ColorScheme cs, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: cs.onSurfaceVariant, size: 24),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fab(IconData icon, ColorScheme cs,
      {required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cs.surface,
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withAlpha(0x14),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, color: cs.onSurfaceVariant, size: 24),
      ),
    );
  }
}
