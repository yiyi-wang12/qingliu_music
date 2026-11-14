import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// 曲库快照：曲库、收藏、歌单。
///
/// 断网时没有服务器可问，主界面全靠这一份。能连上服务器时每次拉到新数据
/// 就写盘一次；启动时先读出来把列表顶上，再尝试联网刷新。只在同一台
/// 服务器之间复用——换了地址就作废，别把上一台的歌单套到新服务器上。
class LibraryCache {
  const LibraryCache({
    required this.serverUrl,
    required this.username,
    required this.serverName,
    required this.songs,
    required this.favorites,
    required this.playlists,
    required this.savedAt,
  });

  final String serverUrl;
  final String username;
  final String serverName;
  final List<Song> songs;
  final List<String> favorites;
  final List<Playlist> playlists;
  final int savedAt;

  Map<String, dynamic> toJson() => {
        'server_url': serverUrl,
        'username': username,
        'server_name': serverName,
        'saved_at': savedAt,
        'songs': songs.map((song) => song.toJson()).toList(),
        'favorites': favorites,
        'playlists': playlists.map((item) => item.toJson()).toList(),
      };

  factory LibraryCache.fromJson(Map<String, dynamic> json) {
    String asText(dynamic value) => value?.toString() ?? '';
    final songs = <Song>[];
    final rawSongs = json['songs'];
    if (rawSongs is List) {
      for (final item in rawSongs) {
        if (item is Map) {
          final song = Song.fromJson(Map<String, dynamic>.from(item));
          if (song.id.isNotEmpty) songs.add(song);
        }
      }
    }
    final favorites = <String>[];
    final rawFavorites = json['favorites'];
    if (rawFavorites is List) {
      for (final item in rawFavorites) {
        final id = item?.toString() ?? '';
        if (id.isNotEmpty) favorites.add(id);
      }
    }
    final playlists = <Playlist>[];
    final rawPlaylists = json['playlists'];
    if (rawPlaylists is List) {
      for (final item in rawPlaylists) {
        if (item is Map) {
          playlists.add(Playlist.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return LibraryCache(
      serverUrl: asText(json['server_url']),
      username: asText(json['username']),
      serverName: asText(json['server_name']),
      songs: songs,
      favorites: favorites,
      playlists: playlists,
      savedAt: (json['saved_at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 快照读写。文件放在 `music_cache/library.json`，和音频缓存同一个目录。
class LibraryStore {
  File? _file;
  bool ready = false;

  Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/music_cache');
      await dir.create(recursive: true);
      _file = File('${dir.path}/library.json');
      ready = true;
    } catch (_) {
      _file = null;
      ready = false;
    }
  }

  Future<LibraryCache?> load() async {
    final file = _file;
    if (file == null || !file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final snapshot =
          LibraryCache.fromJson(Map<String, dynamic>.from(decoded));
      return snapshot.songs.isEmpty ? null : snapshot;
    } catch (_) {
      // 文件损坏就当没有快照，走登录页
      return null;
    }
  }

  Future<void> save(LibraryCache snapshot) async {
    final file = _file;
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
    } catch (_) {
      // 写失败不影响联网使用
    }
  }

  Future<void> clear() async {
    final file = _file;
    if (file == null || !file.existsSync()) return;
    try {
      await file.delete();
    } catch (_) {}
  }
}
