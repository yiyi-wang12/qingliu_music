import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../player_controller.dart';
import '../widgets/liquid_glass.dart';
import '../widgets/play_action.dart';
import '../widgets/selection.dart';
import '../widgets/song_tile.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  /// 多选状态。长按任意一首进入，点 AppBar 的叉退出。
  bool _selecting = false;
  bool _busy = false;
  final Set<String> _selected = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = context.watch<PlayerController>();
    final theme = Theme.of(context);
    final glass = app.glassEffect;

    final songs = _query.isEmpty
        ? app.songs
        : app.songs.where((song) => song.matches(_query)).toList();

    final bottomInset = glassBottomInset(
      context,
      enabled: glass,
      playing: player.current != null,
    );
    final allSelected =
        songs.isNotEmpty && songs.every((song) => _selected.contains(song.id));

    return Scaffold(
      backgroundColor: glass ? Colors.transparent : null,
      appBar: AppBar(
        backgroundColor: glass ? Colors.transparent : null,
        scrolledUnderElevation: glass ? 0 : 0.5,
        leading: _selecting
            ? IconButton(
                tooltip: '退出多选',
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              )
            : null,
        title: _selecting
            ? Text('已选 ${_selected.length} 首',
                style: const TextStyle(fontWeight: FontWeight.w600))
            : const Text('清流音乐',
                style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (_selecting)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => allSelected ? _exitSelection() : _selectAll(songs),
              child: Text(allSelected ? '取消全选' : '全选'),
            )
          else
            IconButton(
              tooltip: '刷新曲库',
              icon: const Icon(Icons.refresh),
              onPressed: () => app.refreshSongs(),
            ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: glass
                    ? LiquidGlass(
                        radius: 18,
                        blur: 1.5,
                        child: _searchField(theme, glass: true),
                      )
                    : _searchField(theme, glass: false),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Row(
                  children: [
                    Text(
                      _selecting
                          ? '共选中 ${_selected.length} 首'
                          : (_query.isEmpty
                              ? '共 ${app.songs.length} 首'
                              : '找到 ${songs.length} 首'),
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    if (app.loadingSongs)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: _buildList(context, app, player, songs, bottomInset),
              ),
            ],
          ),
          if (_selecting)
            Positioned(
              left: 12,
              right: 12,
              bottom: glass ? bottomInset : 12,
              child: SelectionActionBar(
                glass: glass,
                actions: [
                  SelectionAction(
                    icon: Icons.favorite_border,
                    label: '收藏',
                    onTap: _busy || _selected.isEmpty
                        ? null
                        : () => _addFavorites(_selectedSongs(songs)),
                  ),
                  SelectionAction(
                    icon: Icons.heart_broken_outlined,
                    label: '取消收藏',
                    onTap: _busy || _selected.isEmpty
                        ? null
                        : () => _removeFavorites(_selectedSongs(songs)),
                  ),
                  SelectionAction(
                    icon: Icons.playlist_add,
                    label: '加入歌单',
                    onTap: _busy || _selected.isEmpty
                        ? null
                        : () => _addToPlaylist(_selectedSongs(songs)),
                  ),
                  SelectionAction(
                    icon: Icons.download_for_offline_outlined,
                    label: '缓存',
                    onTap: _busy || _selected.isEmpty
                        ? null
                        : () => _addCache(_selectedSongs(songs)),
                  ),
                  SelectionAction(
                    icon: Icons.delete_outline,
                    label: '删缓存',
                    danger: true,
                    onTap: _busy || _selected.isEmpty
                        ? null
                        : () => _removeCache(_selectedSongs(songs)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _searchField(ThemeData theme, {required bool glass}) {
    return TextField(
      controller: _search,
      onChanged: (value) => setState(() => _query = value),
      decoration: InputDecoration(
        hintText: '搜索歌曲、歌手、专辑',
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _search.clear();
                  setState(() => _query = '');
                },
              ),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        filled: !glass,
        fillColor: glass ? Colors.transparent : theme.colorScheme.surface,
        border: glass
            ? InputBorder.none
            : OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
        enabledBorder: glass ? InputBorder.none : null,
        focusedBorder: glass ? InputBorder.none : null,
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    AppState app,
    PlayerController player,
    List<Song> songs,
    double bottomInset,
  ) {
    final theme = Theme.of(context);
    final extra = _selecting ? 84.0 : 0.0;

    if (songs.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => app.refreshSongs(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(bottom: bottomInset),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.18),
            Icon(
              _query.isEmpty ? Icons.library_music_outlined : Icons.search_off,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withAlpha(153),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                _query.isEmpty ? '曲库还是空的' : '没有匹配的歌曲',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (_query.isEmpty) ...[
              const SizedBox(height: 8),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    app.lastError ??
                        '把音乐文件放进服务端 music 目录，歌词放进 lrc 目录，然后下拉刷新。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => app.refreshSongs(),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: 12 + bottomInset + extra),
        itemCount: songs.length,
        itemBuilder: (context, index) {
          final song = songs[index];
          final selected = _selected.contains(song.id);
          return SongTile(
            song: song,
            isPlaying: player.current?.id == song.id,
            selectionMode: _selecting,
            selected: selected,
            onTap: _selecting
                ? () => _toggleSelected(song.id)
                : () => playAndOpen(context, player, songs, index),
            onLongPress:
                _selecting ? null : () => _enterSelection(song.id),
          );
        },
      ),
    );
  }
}
