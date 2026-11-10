import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../player_controller.dart';
import '../widgets/liquid_glass.dart';
import '../widgets/play_action.dart';
import '../widgets/selection.dart';
import '../widgets/song_tile.dart';

class SongListPage extends StatefulWidget {
  const SongListPage({super.key, required this.title, this.playlistId});

  final String title;
  final String? playlistId;

  @override
  State<SongListPage> createState() => _SongListPageState();
}

class _SongListPageState extends State<SongListPage> {
  bool _editing = false;
  bool _saving = false;
  List<Song>? _order;

  /// 多选状态。
  bool _selecting = false;
  bool _busy = false;
  final Set<String> _selected = <String>{};

  bool get _isFavorites => widget.playlistId == null;

  List<Song> _songsOf(AppState app) {
    if (_isFavorites) return app.favoriteSongs;
    for (final item in app.playlists) {
      if (item.id == widget.playlistId) return app.songsOfPlaylist(item);
    }
    return <Song>[];
  }

  void _startEdit(List<Song> songs) {
    setState(() {
      _editing = true;
      _order = List<Song>.of(songs);
    });
  }

  void _finishEdit() {
    setState(() {
      _editing = false;
      _order = null;
    });
  }

  void _enterSelection(String songId) {
    setState(() {
      _selecting = true;
      _selected
        ..clear()
        ..add(songId);
    });
  }

  void _exitSelection() {
    if (!_selecting) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelected(String songId) {
    setState(() {
      if (!_selected.remove(songId)) _selected.add(songId);
    });
  }

  void _selectAll(List<Song> songs) {
    setState(() {
      _selected
        ..clear()
        ..addAll(songs.map((song) => song.id));
    });
  }

  List<Song> _selectedSongs(List<Song> songs) =>
      songs.where((song) => _selected.contains(song.id)).toList();

  // ---------------- 批量操作 ----------------

  Future<void> _addFavorites(List<Song> songs) async {
    setState(() => _busy = true);
    final done = await addFavoritesBatch(context, songs);
    if (!mounted) return;
    setState(() => _busy = false);
    _exitSelection();
    showSnack(context, batchSummary('收藏', done, songs.length - done));
  }

  Future<void> _removeFavorites(List<Song> songs) async {
    final app = context.read<AppState>();
    setState(() => _busy = true);
    final done = await app.removeFavorites(songs.map((song) => song.id));
    if (!mounted) return;
    setState(() => _busy = false);
    _exitSelection();
    showSnack(context, batchSummary('取消收藏', done, songs.length - done));
  }

  Future<void> _addToPlaylist(List<Song> songs) async {
    final app = context.read<AppState>();
    final playlist = await showPlaylistPicker(context, songs: songs);
    if (playlist == null || !mounted) return;
    setState(() => _busy = true);
    final done = await app.addSongsToPlaylist(
      playlist.id,
      songs.map((song) => song.id).toList(),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _exitSelection();
    final skipped = songs.length - done;
    showSnack(
      context,
      skipped > 0
          ? '已加入「${playlist.name}」$done 首，跳过 $skipped 首'
          : '已加入「${playlist.name}」$done 首',
    );
  }

  Future<void> _removeFromPlaylist(List<Song> songs) async {
    final app = context.read<AppState>();
    final pid = widget.playlistId;
    if (pid == null) return;
    setState(() => _busy = true);
    final done =
        await app.removeSongsFromPlaylist(pid, songs.map((song) => song.id).toList());
    if (!mounted) return;
    setState(() => _busy = false);
    _exitSelection();
    showSnack(context, batchSummary('移出歌单', done, songs.length - done));
  }

  Future<void> _addCache(List<Song> songs) async {
    setState(() => _busy = true);
    final done = await queueCacheBatch(context, songs);
    if (!mounted) return;
    setState(() => _busy = false);
    _exitSelection();
    showSnack(context, batchSummary('加入缓存', done, songs.length - done));
  }

  Future<void> _removeCache(List<Song> songs) async {
    setState(() => _busy = true);
    final done = await dropCacheBatch(context, songs);
    if (!mounted) return;
    setState(() => _busy = false);
    _exitSelection();
    showSnack(context, batchSummary('删除缓存', done, songs.length - done));
  }

  // ---------------- 排序 ----------------

  void _onReorder(int oldIndex, int newIndex) {
    final current = _order;
    if (current == null) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    final list = List<Song>.of(current);
    list.insert(target, list.removeAt(oldIndex));
    _saveOrder(list);
  }

  Future<void> _saveOrder(List<Song> list) async {
    setState(() {
      _order = list;
      _saving = true;
    });
    final app = context.read<AppState>();
    final ids = list.map((song) => song.id).toList();
    final ok = _isFavorites
        ? await app.reorderFavorites(ids)
        : await app.reorderPlaylist(widget.playlistId!, ids);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      showSnack(context, '保存顺序失败，已还原');
      setState(() {
        _editing = false;
        _order = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = context.watch<PlayerController>();
    final theme = Theme.of(context);

    final source = _songsOf(app);
    final songs = (_editing && _order != null) ? _order! : source;
    final glass = app.glassEffect;
    final allSelected =
        songs.isNotEmpty && songs.every((song) => _selected.contains(song.id));

    return GlassPage(
      enabled: glass,
      child: Scaffold(
        backgroundColor: glass ? Colors.transparent : null,
        extendBodyBehindAppBar: glass,
        appBar: GlassAppBar(
          enabled: glass,
          leading: _selecting
              ? IconButton(
                  tooltip: '退出多选',
                  icon: const Icon(Icons.close),
                  onPressed: _exitSelection,
                )
              : null,
          title: Text(_selecting ? '已选 ${_selected.length} 首' : widget.title),
          actions: [
            if (_selecting)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => allSelected ? _exitSelection() : _selectAll(songs),
                child: Text(allSelected ? '取消全选' : '全选'),
              )
            else ...[
              if (songs.isNotEmpty)
                IconButton(
                  tooltip: '播放全部',
                  icon: const Icon(Icons.play_circle_outline),
                  onPressed: () => player.setQueue(songs, start: 0),
                ),
              if (songs.isNotEmpty && !_editing)
                IconButton(
                  tooltip: '多选',
                  icon: const Icon(Icons.checklist),
                  onPressed: () => setState(() {
                    _selecting = true;
                    _selected.clear();
                  }),
                ),
              if (songs.isNotEmpty)
                _editing
                    ? TextButton(
                        onPressed: _saving ? null : _finishEdit,
                        child: const Text('完成'),
                      )
                    : IconButton(
                        tooltip: '调整顺序',
                        icon: const Icon(Icons.swap_vert),
                        onPressed: () => _startEdit(source),
                      ),
            ],
          ],
        ),
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(
                top: glass ? glassAppBarInset(context) : 0,
              ),
              child: songs.isEmpty
                  ? _emptyView(theme)
                  : (_editing
                      ? _reorderList(songs, player, theme)
                      : _plainList(songs, player, extraBottom: _selecting)),
            ),
            if (_selecting)
              Positioned(
                left: 12,
                right: 12,
                bottom: MediaQuery.of(context).padding.bottom + 12,
                child: SelectionActionBar(
                  glass: glass,
                  actions: _selectionActions(songs),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<SelectionAction> _selectionActions(List<Song> songs) {
    final disabled = _busy || _selected.isEmpty;
    final actions = <SelectionAction>[
      _isFavorites
          ? SelectionAction(
              icon: Icons.favorite_border,
              label: '取消收藏',
              onTap: disabled ? null : () => _removeFavorites(_selectedSongs(songs)),
            )
          : SelectionAction(
              icon: Icons.favorite_border,
              label: '收藏',
              onTap: disabled ? null : () => _addFavorites(_selectedSongs(songs)),
            ),
      SelectionAction(
        icon: Icons.playlist_add,
        label: '加入歌单',
        onTap: disabled ? null : () => _addToPlaylist(_selectedSongs(songs)),
      ),
      if (!_isFavorites)
        SelectionAction(
          icon: Icons.playlist_remove,
          label: '移出歌单',
          danger: true,
          onTap:
              disabled ? null : () => _removeFromPlaylist(_selectedSongs(songs)),
        ),
      SelectionAction(
        icon: Icons.download_for_offline_outlined,
        label: '缓存',
        onTap: disabled ? null : () => _addCache(_selectedSongs(songs)),
      ),
      SelectionAction(
        icon: Icons.delete_outline,
        label: '删缓存',
        danger: true,
        onTap: disabled ? null : () => _removeCache(_selectedSongs(songs)),
      ),
    ];
    return actions;
  }

  Widget _plainList(
    List<Song> songs,
    PlayerController player, {
    bool extraBottom = false,
  }) {
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(4, 8, 4, extraBottom ? 96 : 12),
      itemCount: songs.length,
      itemBuilder: (context, index) {
        final song = songs[index];
        final selected = _selected.contains(song.id);
        return SongTile(
          song: song,
          isPlaying: player.current?.id == song.id,
          playlistId: widget.playlistId,
          selectionMode: _selecting,
          selected: selected,
          onTap: _selecting
              ? () => _toggleSelected(song.id)
              : () => playAndOpen(context, player, songs, index),
          onLongPress:
              _selecting ? null : () => _enterSelection(song.id),
        );
      },
    );
  }

  Widget _reorderList(
      List<Song> songs, PlayerController player, ThemeData theme) {
    final glass = context.read<AppState>().glassEffect;
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: songs.length,
      buildDefaultDragHandles: false,
      onReorder: _onReorder,
      header: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Text(
          '长按右侧把手拖动排序，松手即保存',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      itemBuilder: (context, index) {
        final song = songs[index];
        return ReorderableDelayedDragStartListener(
          key: ValueKey(song.id),
          index: index,
          child: Material(
            color: glass
                ? theme.colorScheme.surface
                : theme.scaffoldBackgroundColor,
            child: SongTile(
              song: song,
              isPlaying: player.current?.id == song.id,
              playlistId: widget.playlistId,
              trailing: Icon(
                Icons.drag_handle,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _emptyView(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.music_off_outlined,
            size: 44,
            color: theme.colorScheme.onSurfaceVariant.withAlpha(153),
          ),
          const SizedBox(height: 12),
          Text(
            _isFavorites ? '还没有收藏歌曲' : '歌单里还没有歌曲',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 6),
          Text(
            _isFavorites ? '在歌曲右侧点小心心即可收藏' : '在歌曲菜单里选择「加入歌单」',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
