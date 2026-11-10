import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../cache_service.dart';
import '../models.dart';
import '../player_controller.dart';
import 'cover_art.dart';
import 'liquid_glass.dart';

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
}

Future<void> showAddToPlaylistSheet(BuildContext context, Song song) async {
  final app = context.read<AppState>();
  final glass = app.glassEffect;
  await showModalBottomSheet<void>(
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
                      song.name,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
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
                      return ListTile(
                        leading: const Icon(Icons.queue_music),
                        title: Text(playlist.name),
                        subtitle: Text('${playlist.songIds.length} 首'),
                        onTap: () async {
                          Navigator.of(sheetContext).pop();
                          final ok = await app.addToPlaylist(playlist.id, song.id);
                          if (context.mounted) {
                            showSnack(context,
                                ok ? '已加入「${playlist.name}」' : '加入失败');
                          }
                        },
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

class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    this.onTap,
    this.onLongPress,
    this.isPlaying = false,
    this.playlistId,
    this.showFavoriteButton = true,
    this.trailing,
    this.selectionMode = false,
    this.selected = false,
  });

  final Song song;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool isPlaying;
  final String? playlistId;
  final bool showFavoriteButton;
  final Widget? trailing;

  /// 多选态：左侧换成勾选圈，右侧的操作按钮全部让位。
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.read<AppState>();
    final favorite = context.select<AppState, bool>((a) => a.isFavorite(song.id));
    final highlight = selectionMode && selected;

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      selected: highlight || (!selectionMode && isPlaying),
      selectedTileColor: highlight
          ? theme.colorScheme.primary.withAlpha(26)
          : theme.colorScheme.primary.withAlpha(15),
      leading: selectionMode
          ? SizedBox(
              width: 72,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 22,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  CoverArt(song: song, size: 40, radius: 9, iconSize: 20),
                ],
              ),
            )
          : CoverArt(song: song, size: 44, radius: 10, iconSize: 22),
      title: Text(
        song.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 15,
          fontWeight: (highlight || isPlaying) ? FontWeight.w600 : FontWeight.w500,
          color: highlight || (!selectionMode && isPlaying)
              ? theme.colorScheme.primary
              : null,
        ),
      ),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              song.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (song.hasLrc) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withAlpha(26),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '词',
                style: TextStyle(
                  fontSize: 9,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ],
      ),
      trailing: selectionMode
          ? null
          : trailing ??
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showFavoriteButton)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    favorite ? Icons.favorite : Icons.favorite_border,
                    size: 20,
                    color: favorite ? theme.colorScheme.primary : null,
                  ),
                  onPressed: () async {
                    await app.toggleFavorite(song.id);
                    if (context.mounted) {
                      showSnack(context, favorite ? '已取消收藏' : '已收藏');
                    }
                  },
                ),
              Builder(
                builder: (buttonContext) => IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.more_vert, size: 20),
                  onPressed: () async {
                    final box = buttonContext.findRenderObject();
                    var origin = Offset.zero;
                    var height = 0.0;
                    if (box is RenderBox) {
                      origin = box.localToGlobal(Offset.zero);
                      height = box.size.height;
                    }
                    final value = await showGlassMenu<String>(
                      context: buttonContext,
                      globalPosition: origin + Offset(0, height),
                      entries: [
                        GlassMenuEntry(
                          value: 'favorite',
                          label: favorite ? '取消收藏' : '收藏',
                          icon: favorite
                              ? Icons.favorite_border
                              : Icons.favorite,
                        ),
                        const GlassMenuEntry(
                          value: 'cache',
                          label: '添加缓存',
                          icon: Icons.download_for_offline_outlined,
                        ),
                        const GlassMenuEntry(
                          value: 'playlist',
                          label: '加入歌单',
                          icon: Icons.playlist_add,
                        ),
                        if (playlistId != null)
                          const GlassMenuEntry(
                            value: 'remove',
                            label: '从歌单移除',
                            icon: Icons.playlist_remove,
                          ),
                      ],
                    );
                    if (!context.mounted) return;
                    if (value == 'favorite') {
                      await app.toggleFavorite(song.id);
                    } else if (value == 'cache') {
                      final cache = context.read<CacheService>();
                      if (cache.isCached(song.id)) {
                        showSnack(context, '这首已经在缓存里');
                      } else if (cache.isPending(song.id)) {
                        showSnack(context, '已经在下载队列里');
                      } else {
                        final player = context.read<PlayerController>();
                        final ok = await player.cacheSong(song);
                        if (context.mounted) {
                          showSnack(context, ok ? '已加入缓存' : '缓存不可用');
                        }
                      }
                    } else if (value == 'playlist') {
                      await showAddToPlaylistSheet(context, song);
                    } else if (value == 'remove' && playlistId != null) {
                      final ok =
                          await app.removeFromPlaylist(playlistId!, song.id);
                      if (context.mounted) {
                        showSnack(context, ok ? '已从歌单移除' : '移除失败');
                      }
                    }
                  },
                ),
              ),
            ],
          ),
    );
  }
}
