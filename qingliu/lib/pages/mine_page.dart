import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../player_controller.dart';
import '../widgets/liquid_glass.dart';
import '../widgets/song_tile.dart';
import 'listening_page.dart';
import 'song_list_page.dart';

class MinePage extends StatelessWidget {
  const MinePage({super.key});

  Future<void> _createPlaylist(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      barrierColor: kBarrierDim,
      builder: (dialogContext) {
        return GlassAlertDialog(
          title: '新建歌单',
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 30,
            decoration: const InputDecoration(
              hintText: '歌单名称',
              counterText: '',
            ),
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || !context.mounted) return;
    final ok = await context.read<AppState>().createPlaylist(trimmed);
    if (context.mounted) {
      showSnack(context, ok ? '已创建「$trimmed」' : '创建失败');
    }
  }

  Future<void> _deletePlaylist(BuildContext context, Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: kBarrierDim,
      builder: (dialogContext) => GlassAlertDialog(
        title: '删除歌单',
        content: Text('确定删除「${playlist.name}」？歌曲本身不会被删除。'),
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
    final ok = await context.read<AppState>().deletePlaylist(playlist.id);
    if (context.mounted) {
      showSnack(context, ok ? '已删除' : '删除失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = context.watch<PlayerController>();
    final theme = Theme.of(context);
    final glass = app.glassEffect;
    final bottomInset = glassBottomInset(
      context,
      enabled: glass,
      playing: player.current != null,
    );

    return Scaffold(
      backgroundColor: glass ? Colors.transparent : null,
      extendBodyBehindAppBar: glass,
      appBar: GlassAppBar(
        enabled: glass,
        title: const Text('我的', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          glass ? glassAppBarInset(context) + 6 : 4,
          16,
          24 + bottomInset,
        ),
        children: [
          _profileCard(context, app, theme, glass),
          GlassCard(
            radius: 20,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.headphones,
                      color: theme.colorScheme.primary),
                  title: const Text('听歌时长'),
                  subtitle: const Text('排行榜'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ListeningPage(),
                      ),
                    );
                  },
                ),
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: theme.dividerColor.withAlpha(60),
                ),
                ListTile(
                  leading: Icon(Icons.favorite,
                      color: theme.colorScheme.primary),
                  title: const Text('我的收藏'),
                  subtitle: Text('${app.favoriteSongs.length} 首'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SongListPage(title: '我的收藏'),
                      ),
                    );
                  },
                ),
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: theme.dividerColor.withAlpha(60),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                  child: Row(
                    children: [
                      const Text(
                        '我的歌单',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => _createPlaylist(context),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新建歌单'),
                      ),
                    ],
                  ),
                ),
                if (app.playlists.isEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: Text(
                      '还没有歌单，点右上角新建。',
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  ...app.playlists.map((playlist) {
                    final songs = app.songsOfPlaylist(playlist);
                    return ListTile(
                      leading: Icon(Icons.queue_music,
                          color: theme.colorScheme.onSurfaceVariant),
                      title: Text(playlist.name),
                      subtitle: Text('${songs.length} 首'),
                      trailing: Builder(
                        builder: (buttonContext) => IconButton(
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
                              entries: const [
                                GlassMenuEntry(
                                  value: 'delete',
                                  label: '删除歌单',
                                  icon: Icons.delete_outline,
                                  danger: true,
                                ),
                              ],
                            );
                            if (value == 'delete' && context.mounted) {
                              _deletePlaylist(context, playlist);
                            }
                          },
                        ),
                      ),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SongListPage(
                              title: playlist.name,
                              playlistId: playlist.id,
                            ),
                          ),
                        );
                      },
                    );
                  }),
                const SizedBox(height: 6),
              ],
            ),
          ),
          if (player.current != null) const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _profileCard(
    BuildContext context,
    AppState app,
    ThemeData theme,
    bool glass,
  ) {
    final content = Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: glass
                ? theme.colorScheme.primary.withAlpha(36)
                : Colors.white.withAlpha(51),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.person,
            color: glass ? theme.colorScheme.primary : Colors.white,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                app.username,
                style: TextStyle(
                  color: glass ? theme.colorScheme.onSurface : Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                app.serverUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: glass
                      ? theme.colorScheme.onSurfaceVariant
                      : Colors.white.withAlpha(217),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${app.songs.length}',
              style: TextStyle(
                color: glass ? theme.colorScheme.primary : Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '首歌曲',
              style: TextStyle(
                color: glass
                    ? theme.colorScheme.onSurfaceVariant
                    : Colors.white.withAlpha(217),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ],
    );

    if (!glass) {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          borderRadius: BorderRadius.circular(16),
        ),
        child: content,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LiquidGlass(
        radius: 20,
        blur: 2,
        tint: theme.colorScheme.primary,
        padding: const EdgeInsets.all(16),
        child: content,
      ),
    );
  }
}
