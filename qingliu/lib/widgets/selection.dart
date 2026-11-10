import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../cache_service.dart';
import '../models.dart';
import '../player_controller.dart';
import 'liquid_glass.dart';

/// 多选底栏上的一个动作。
class SelectionAction {
  const SelectionAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;

  /// 为 null 表示暂时不可点（例如正在处理上一批）。
  final VoidCallback? onTap;
  final bool danger;
}

/// 多选时浮在列表底部的操作栏。
///
/// 玻璃效果跟着「设置 → 外观 → 玻璃效果」走：开着就是一块玻璃，
/// 关着退化成带阴影的纯色卡片。
class SelectionActionBar extends StatelessWidget {
  const SelectionActionBar({
    super.key,
    required this.actions,
    this.glass = true,
  });

  final List<SelectionAction> actions;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          for (final action in actions)
            Expanded(child: _item(context, theme, action)),
        ],
      ),
    );

    if (!glass) {
      return Material(
        elevation: 6,
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: content,
      );
    }
    return LiquidGlass(radius: 22, blur: 3, child: content);
  }

  Widget _item(BuildContext context, ThemeData theme, SelectionAction action) {
    final enabled = action.onTap != null;
    final color = !enabled
        ? theme.colorScheme.onSurfaceVariant.withAlpha(110)
        : (action.danger ? theme.colorScheme.error : theme.colorScheme.onSurface);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: action.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(action.icon, size: 21, color: color),
            const SizedBox(height: 4),
            Text(
              action.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, height: 1.1, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// 多选结果的统一说法：改了几首、跳过几首。
String batchSummary(String verb, int done, int skipped) {
  if (done == 0 && skipped > 0) return '没有可$verb的，跳过 $skipped 首';
  if (skipped > 0) return '已$verb $done 首，跳过 $skipped 首';
  return '已$verb $done 首';
}

/// 批量收藏，已在收藏里的自动跳过。返回实际新增的首数。
Future<int> addFavoritesBatch(BuildContext context, List<Song> songs) {
  final app = context.read<AppState>();
  final pending = songs.where((song) => !app.isFavorite(song.id));
  return app.addFavorites(pending.map((song) => song.id));
}

/// 批量加入缓存：已缓存的和已在下载队列里的都跳过。返回成功排队的首数。
Future<int> queueCacheBatch(BuildContext context, List<Song> songs) async {
  final cache = context.read<CacheService>();
  final player = context.read<PlayerController>();
  var done = 0;
  for (final song in songs) {
    if (cache.isCached(song.id) || cache.isPending(song.id)) continue;
    if (await player.cacheSong(song)) done++;
  }
  return done;
}

/// 批量删除缓存：没缓存的跳过。返回实际删掉的首数。
Future<int> dropCacheBatch(BuildContext context, List<Song> songs) async {
  final cache = context.read<CacheService>();
  var done = 0;
  for (final song in songs) {
    if (!cache.isCached(song.id)) continue;
    await cache.remove(song.id);
    done++;
  }
  return done;
}

/// 多选时选择目标歌单。返回 null 表示没选。
Future<Playlist?> showPlaylistPicker(
  BuildContext context, {
  required List<Song> songs,
}) async {
  final app = context.read<AppState>();
  final glass = app.glassEffect;
  return showModalBottomSheet<Playlist>(
    context: context,
    backgroundColor: glass ? Colors.transparent : null,
    elevation: glass ? 0 : null,
    barrierColor: kBarrierDim,
    builder: (sheetContext) {
      final Widget sheet = SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  children: [
                    const Text('加入歌单',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text(
                      '已选 ${songs.length} 首',
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (app.playlists.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                  child: Text('还没有歌单，先到「我的」里新建一个。'),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: app.playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = app.playlists[index];
                      final already = songs
                          .where((song) => playlist.songIds.contains(song.id))
                          .length;
                      return ListTile(
                        leading: const Icon(Icons.queue_music),
                        title: Text(playlist.name),
                        subtitle: Text(already > 0
                            ? '${playlist.songIds.length} 首 · 已含 $already 首'
                            : '${playlist.songIds.length} 首'),
                        onTap: () => Navigator.of(sheetContext).pop(playlist),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      );
      if (!glass) return sheet;
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: LiquidGlass(radius: 24, blur: 5, child: sheet),
      );
    },
  );
}
