import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'cache_service.dart';
import 'media_session.dart';
import 'models.dart';
import 'player_controller.dart';

class AppState extends ChangeNotifier {
  final PlayerController player = PlayerController();
  final CacheService cache = CacheService();
  final MediaSessionService media = MediaSessionService();

  late SharedPreferences _prefs;
  MusicApi? api;
  bool bootstrapping = true;

  String serverUrl = '';
  String username = '';
  String password = '';
  String serverName = '音乐服务器';

  double lyricFontSize = 22;
  bool autoNext = true;
  String playMode = 'list'; // list / one / shuffle
  bool autoCache = false;

  /// Liquid Glass 玻璃效果：底部导航、搜索栏、歌词与二级页面。
  bool glassEffect = true;

  /// 主题色（ARGB），设置页里可改。
  int themeSeed = defaultThemeSeed;

  /// 可选主题色：红橙黄绿蓝靛紫 七组，每组 6 档，从浅到深。
  static const Map<String, List<int>> themeGroups = <String, List<int>>{
    '红': <int>[
      0xFFEFBDBD, 0xFFE48B8B, 0xFFD85A5A, 0xFFC62F2F, 0xFF992424, 0xFF701A1A,
    ],
    '橙': <int>[
      0xFFEFD5BD, 0xFFE4B58B, 0xFFD8955A, 0xFFC6752F, 0xFF995A24, 0xFF70421A,
    ],
    '黄': <int>[
      0xFFEFE7BD, 0xFFE4D58B, 0xFFD8C35A, 0xFFC6AD2F, 0xFF998524, 0xFF70611A,
    ],
    '绿': <int>[
      0xFFBDEFCC, 0xFF8BE4A6, 0xFF5AD880, 0xFF2FC65C, 0xFF249947, 0xFF1A7034,
    ],
    '蓝': <int>[
      0xFFBDD5EF, 0xFF8BB5E4, 0xFF5A95D8, 0xFF2F75C6, 0xFF245A99, 0xFF1A4270,
    ],
    '靛': <int>[
      0xFFC7BDEF, 0xFF9D8BE4, 0xFF735AD8, 0xFF4D2FC6, 0xFF3B2499, 0xFF2B1A70,
    ],
    '紫': <int>[
      0xFFE5BDEF, 0xFFD28BE4, 0xFFBF5AD8, 0xFFA82FC6, 0xFF812499, 0xFF5E1A70,
    ],
  };

  /// 默认主题色：中性蓝
  static const int defaultThemeSeed = 0xFF2F75C6;

  static bool isKnownSeed(int value) {
    for (final group in themeGroups.values) {
      if (group.contains(value)) return true;
    }
    return false;
  }

  List<Song> songs = [];
  List<String> favoriteIds = [];
  List<Playlist> playlists = [];

  bool loadingSongs = false;
  String? lastError;

  Map<String, Song> _songIndex = {};

  bool get loggedIn => api != null;

  Future<void> bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
    serverUrl = _prefs.getString('serverUrl') ?? '';
    username = _prefs.getString('username') ?? '';
    password = _prefs.getString('password') ?? '';
    serverName = _prefs.getString('serverName') ?? '音乐服务器';
    lyricFontSize = _prefs.getDouble('lyricFontSize') ?? 22;
    autoNext = _prefs.getBool('autoNext') ?? true;
    playMode = _prefs.getString('playMode') ?? 'list';
    autoCache = _prefs.getBool('autoCache') ?? false;
    glassEffect = _prefs.getBool('glassEffect') ?? true;
    themeSeed = _prefs.getInt('themeSeed') ?? defaultThemeSeed;
    // 旧版本留下的色值不在新色板里，退回默认色
    if (!isKnownSeed(themeSeed)) themeSeed = defaultThemeSeed;

    player.autoNext = autoNext;
    player.playMode = playMode;
    player.media = media;
    player.cache = cache;
    // 缓存下载统一让着播放：恢复出来的任务没有单独的让路回调，
    // 靠这个注入的守卫一样能在缓冲吃紧时停下
    cache.playbackGuard = player.downloadShouldPause;
    // 锁屏 / 通知栏 / 灵动岛上的操作回灌到播放器
    media.init(
      onPrevious: () => player.previous(),
      onNext: () => player.next(),
      onToggle: () => player.toggle(),
      onPlay: () {
        if (!player.isPlaying) player.toggle();
      },
      onPause: () {
        if (player.isPlaying) player.toggle();
      },
      onStop: () => player.stop(),
      onSeek: (position) => player.seek(position),
    );
    await cache.init();
    cache.setEnabled(autoCache);
    await _sweepLyricCache();
    await player.configure();

    if (serverUrl.isNotEmpty && username.isNotEmpty && password.isNotEmpty) {
      try {
        await _doLogin(serverUrl, username, password, persist: false);
      } catch (_) {
        // 自动登录失败：留在登录页，凭证保留
      }
    }

    bootstrapping = false;
    notifyListeners();
  }

  Future<void> login(String url, String user, String pass) async {
    await _doLogin(url, user, pass, persist: true);
  }

  /// 歌词解码版本。服务端改成按编码族判定之后，旧的本地歌词可能是按
  /// 错编码解出来的乱码；版本号一变就丢掉歌词缓存重新拉一次。
  static const int lyricCodecVersion = 2;

  Future<void> _sweepLyricCache() async {
    final stored = _prefs.getInt('lyricCodecVersion') ?? 1;
    if (stored >= lyricCodecVersion) return;
    await cache.clearLyrics();
    await _prefs.setInt('lyricCodecVersion', lyricCodecVersion);
  }

  Future<void> _doLogin(String url, String user, String pass,
      {bool persist = true}) async {
    final base = MusicApi.normalize(url);
    if (base.isEmpty) throw ApiException('请填写服务器地址');
    final client = MusicApi(base);
    final result = await client.login(user, pass);
    // 分块大小以服务端 setting.json 为准；老服务端没有这个接口就用默认值
    await client.loadConfig();

    // 换了服务器，旧缓存里的同名 id 可能对应别的文件，直接丢掉
    if (serverUrl.isNotEmpty && serverUrl != base) {
      await cache.clear();
    }

    api = client;
    serverUrl = base;
    username = user;
    password = pass;
    serverName = result.server;
    player.api = client;

    if (persist) {
      await _prefs.setString('serverUrl', base);
      await _prefs.setString('username', user);
      await _prefs.setString('password', pass);
      await _prefs.setString('serverName', result.server);
    }

    notifyListeners();
    await loadAll();
    // 上次没下完的手动缓存，登录拿到 api 后接着下
    unawaited(cache.resumeManual(client, songs));
  }

  Future<void> updateAccount(String url, String user, String pass) async {
    await _doLogin(url, user, pass, persist: true);
  }

  Future<void> loadAll() async {
    await Future.wait([refreshSongs(), refreshLibrary()]);
  }

  Future<void> refreshSongs() async {
    final client = api;
    if (client == null) return;
    loadingSongs = true;
    notifyListeners();
    try {
      songs = await client.fetchSongs();
      _songIndex = {for (final song in songs) song.id: song};
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      loadingSongs = false;
      notifyListeners();
    }
  }

  Future<void> refreshLibrary() async {
    final client = api;
    if (client == null) return;
    try {
      final snapshot = await client.fetchLibrary();
      favoriteIds = snapshot.favorites;
      playlists = snapshot.playlists;
      notifyListeners();
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
    }
  }

  Song? songById(String id) => _songIndex[id];

  List<Song> get favoriteSongs {
    final result = <Song>[];
    for (final id in favoriteIds) {
      final song = _songIndex[id];
      if (song != null) result.add(song);
    }
    return result;
  }

  List<Song> songsOfPlaylist(Playlist playlist) {
    final result = <Song>[];
    for (final id in playlist.songIds) {
      final song = _songIndex[id];
      if (song != null) result.add(song);
    }
    return result;
  }

  bool isFavorite(String songId) => favoriteIds.contains(songId);

  Future<void> toggleFavorite(String songId) async {
    final client = api;
    if (client == null) return;
    final previous = List<String>.of(favoriteIds);
    if (favoriteIds.contains(songId)) {
      favoriteIds.remove(songId);
    } else {
      favoriteIds.add(songId);
    }
    notifyListeners();
    try {
      favoriteIds = await client.toggleFavorite(songId);
    } catch (e) {
      favoriteIds = previous;
      lastError = e.toString();
    }
    notifyListeners();
  }

  /// 批量收藏。已经在收藏里的自动跳过，返回实际新增的首数。
  Future<int> addFavorites(Iterable<String> songIds) async {
    final client = api;
    if (client == null) return 0;
    final targets = <String>[];
    for (final id in songIds) {
      if (!favoriteIds.contains(id) && !targets.contains(id)) targets.add(id);
    }
    if (targets.isEmpty) return 0;
    final previous = List<String>.of(favoriteIds);
    try {
      final result = await client.setFavorites(targets, add: true);
      favoriteIds = result.value;
      notifyListeners();
      return result.changed;
    } catch (e) {
      favoriteIds = previous;
      lastError = e.toString();
      notifyListeners();
      return 0;
    }
  }

  /// 批量取消收藏。本来就不在收藏里的自动跳过，返回实际移除的首数。
  Future<int> removeFavorites(Iterable<String> songIds) async {
    final client = api;
    if (client == null) return 0;
    final targets = songIds.where((id) => favoriteIds.contains(id)).toList();
    if (targets.isEmpty) return 0;
    final previous = List<String>.of(favoriteIds);
    try {
      final result = await client.setFavorites(targets, add: false);
      favoriteIds = result.value;
      notifyListeners();
      return result.changed;
    } catch (e) {
      favoriteIds = previous;
      lastError = e.toString();
      notifyListeners();
      return 0;
    }
  }

  /// 批量加入歌单。已在歌单里的自动跳过，返回实际加入的首数。
  Future<int> addSongsToPlaylist(String playlistId, List<String> songIds) async {
    final client = api;
    if (client == null) return 0;
    Playlist? target;
    for (final item in playlists) {
      if (item.id == playlistId) {
        target = item;
        break;
      }
    }
    if (target == null) return 0;
    final existing = target.songIds.toSet();
    final wanted = <String>[];
    for (final id in songIds) {
      if (!existing.contains(id) && !wanted.contains(id)) wanted.add(id);
    }
    if (wanted.isEmpty) return 0;
    try {
      final result = await client.addSongsToPlaylist(playlistId, wanted);
      playlists = result.value;
      notifyListeners();
      return result.changed;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return 0;
    }
  }

  /// 批量从歌单移除。不在歌单里的自动跳过，返回实际移除的首数。
  Future<int> removeSongsFromPlaylist(
      String playlistId, List<String> songIds) async {
    final client = api;
    if (client == null) return 0;
    Playlist? target;
    for (final item in playlists) {
      if (item.id == playlistId) {
        target = item;
        break;
      }
    }
    if (target == null) return 0;
    final existing = target.songIds.toSet();
    final wanted = songIds.where(existing.contains).toList();
    if (wanted.isEmpty) return 0;
    try {
      final result = await client.removeSongsFromPlaylist(playlistId, wanted);
      playlists = result.value;
      notifyListeners();
      return result.changed;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return 0;
    }
  }

  Future<bool> reorderFavorites(List<String> songIds) async {
    final client = api;
    if (client == null) return false;
    try {
      favoriteIds = await client.reorderFavorites(songIds);
      notifyListeners();
      return true;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> createPlaylist(String name) async {
    final client = api;
    if (client == null) return false;
    try {
      playlists = await client.createPlaylist(name);
      notifyListeners();
      return true;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> addToPlaylist(String playlistId, String songId) async {
    final client = api;
    if (client == null) return false;
    try {
      playlists = await client.addToPlaylist(playlistId, songId);
      notifyListeners();
      return true;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> removeFromPlaylist(String playlistId, String songId) async {
    final client = api;
    if (client == null) return false;
    try {
      playlists = await client.removeFromPlaylist(playlistId, songId);
      notifyListeners();
      return true;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> reorderPlaylist(String playlistId, List<String> songIds) async {
    final client = api;
    if (client == null) return false;
    try {
      playlists = await client.reorderPlaylist(playlistId, songIds);
      notifyListeners();
      return true;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> deletePlaylist(String playlistId) async {
    final client = api;
    if (client == null) return false;
    try {
      playlists = await client.deletePlaylist(playlistId);
      notifyListeners();
      return true;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  void setLyricFontSize(double value) {
    lyricFontSize = value;
    _prefs.setDouble('lyricFontSize', value);
    notifyListeners();
  }

  void setAutoNext(bool value) {
    autoNext = value;
    player.setAutoNext(value);
    _prefs.setBool('autoNext', value);
    notifyListeners();
  }

  void setPlayMode(String value) {
    playMode = value;
    player.setPlayMode(value);
    _prefs.setString('playMode', value);
    notifyListeners();
  }

  void setAutoCache(bool value) {
    autoCache = value;
    cache.setEnabled(value);
    _prefs.setBool('autoCache', value);
    notifyListeners();
  }

  void setGlassEffect(bool value) {
    if (glassEffect == value) return;
    glassEffect = value;
    _prefs.setBool('glassEffect', value);
    notifyListeners();
  }

  void setThemeSeed(int value) {
    if (themeSeed == value) return;
    themeSeed = value;
    _prefs.setInt('themeSeed', value);
    notifyListeners();
  }

  Future<void> logout() async {
    await player.stop();
    // 停掉还没下完的缓存任务；半截文件和断点记录保留，下次登录接着下
    await cache.cancelAll();
    player.api = null;
    api = null;
    songs = [];
    favoriteIds = [];
    playlists = [];
    _songIndex = {};
    serverUrl = '';
    username = '';
    password = '';
    await _prefs.remove('serverUrl');
    await _prefs.remove('username');
    await _prefs.remove('password');
    notifyListeners();
  }

  @override
  void dispose() {
    player.dispose();
    cache.dispose();
    super.dispose();
  }
}
