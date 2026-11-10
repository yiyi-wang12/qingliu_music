import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../cache_service.dart';
import '../models.dart';
import '../widgets/liquid_glass.dart';
import '../widgets/song_tile.dart';

class CachePage extends StatelessWidget {
  const CachePage({super.key});

  Future<void> _clearAll(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: kBarrierDim,
      builder: (dialogContext) => GlassAlertDialog(
        title: '清空缓存',
        content: const Text('将删除全部已缓存的音频、歌词和封面，确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await context.read<CacheService>().clear();
    if (context.mounted) showSnack(context, '缓存已清空');
  }

  Future<void> _removeOne(BuildContext context, CacheEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: kBarrierDim,
      builder: (dialogContext) => GlassAlertDialog(
        title: '删除缓存',
        content: Text('删除「${entry.name}」的本地缓存？歌曲文件本身不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await context.read<CacheService>().remove(entry.songId);
    if (context.mounted) showSnack(context, '已删除「${entry.name}」的缓存');
  }

  String _timeText(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final cache = context.watch<CacheService>();
    final app = context.watch<AppState>();
    final entries = cache.all;
    final downloads = cache.downloads;
    final theme = Theme.of(context);
    final glass = app.glassEffect;

    final body = (entries.isEmpty && downloads.isEmpty)
        ? _emptyView(theme)
        : _listView(context, entries, downloads, cache, theme);

    return GlassPage(
      enabled: glass,
      child: Scaffold(
        backgroundColor: glass ? Colors.transparent : null,
        extendBodyBehindAppBar: glass,
        appBar: GlassAppBar(
          enabled: glass,
          title: const Text('缓存管理'),
          actions: [
            if (entries.isNotEmpty || downloads.isNotEmpty)
              TextButton(
                onPressed: () => _clearAll(context),
                child: const Text('清空'),
              ),
          ],
        ),
        body: Padding(
          padding: EdgeInsets.only(
            top: glass ? glassAppBarInset(context) : 0,
          ),
          child: body,
        ),
      ),
    );
  }

  Widget _emptyView(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_off_outlined,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant.withAlpha(153),
            ),
            const SizedBox(height: 12),
            Text('还没有缓存', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 6),
            Text(
              '在设置里打开「播放时自动缓存」，开播就会顺手把整首存到本机；'
              '歌曲菜单里的「添加缓存」可以手动下载，断了也能接着下。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listView(
    BuildContext context,
    List<CacheEntry> entries,
    List<CacheDownload> downloads,
    CacheService cache,
    ThemeData theme,
  ) {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withAlpha(22),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(Icons.sd_storage_outlined,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${entries.length} 首 · 共 ${formatBytes(cache.totalBytes)}'
                  '${downloads.isEmpty ? '' : ' · 下载中 ${downloads.length} 首'}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 6),
            itemCount: downloads.length + entries.length,
            itemBuilder: (context, index) {
              if (index < downloads.length) {
                return _downloadTile(
                    context, downloads[index], cache, theme);
              }
              final entry = entries[index - downloads.length];
              return _entryTile(context, entry, theme);
            },
          ),
        ),
      ],
    );
  }

  /// 正在下载的一行：歌名、进度、已下/总大小，右边可以直接取消。
  Widget _downloadTile(
    BuildContext context,
    CacheDownload item,
    CacheService cache,
    ThemeData theme,
  ) {
    final percent = (item.progress * 100).round();
    final detail = item.waiting
        ? '${item.artist} · 等待下载'
        : '${item.artist} · ${formatBytes(item.received)} / '
            '${formatBytes(item.total)} · $percent%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withAlpha(22),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.downloading,
                size: 20, color: theme.colorScheme.primary),
          ),
          title: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: IconButton(
            tooltip: '取消下载',
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => cache.cancelDownload(item.songId),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 72, 10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: item.waiting
                  ? 0
                  : (item.total > 0 ? item.progress : null),
              minHeight: 4,
              backgroundColor: theme.colorScheme.primary.withAlpha(26),
            ),
          ),
        ),
      ],
    );
  }

  Widget _entryTile(BuildContext context, CacheEntry entry, ThemeData theme) {
    final parts = <String>['音频'];
    if (entry.lrcBytes > 0) parts.add('歌词');
    if (entry.coverBytes > 0) parts.add('封面');
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withAlpha(22),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(Icons.audiotrack,
            size: 20, color: theme.colorScheme.primary),
      ),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${entry.artist} · ${parts.join(' / ')} · '
        '${formatBytes(entry.totalBytes)} · ${_timeText(entry.cachedTime)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: IconButton(
        tooltip: '删除缓存',
        icon: const Icon(Icons.delete_outline, size: 20),
        onPressed: () => _removeOne(context, entry),
      ),
    );
  }
}
