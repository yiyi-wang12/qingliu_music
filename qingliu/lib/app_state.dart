import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'cache_service.dart';
import 'library_store.dart';
import 'listening_tracker.dart';
import 'media_session.dart';
import 'models.dart';
import 'player_controller.dart';

class AppState extends ChangeNotifier {
  final PlayerController player = PlayerController();
  final CacheService cache = CacheService();
  final MediaSessionService media = MediaSessionService();
  final LibraryStore library = LibraryStore();

  /// 听歌时长统计：跟着播放进度按 6 秒一个单位累计，攒批上报服务端。
  late final ListeningTracker listening = ListeningTracker(
    player: player,
    apiOf: () => _onlineApi,
  );

  late SharedPreferences _prefs;
  MusicApi? api;
  bool bootstrapping = true;

  /// 离线模式：连不上服务器。界面用上次留下的曲库快照顶上，
  /// 播放只能走本地缓存。见 [PlayerController.offline]。
  bool offline = false;

  /// 启动时自动登录失败的原因，留给登录页显示。
  String? bootError;

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

  /// 离线时不碰写接口：收藏 / 歌单这些改动到不了服务器，做了也只会回滚。
  MusicApi? get _onlineApi => offline ? null : api;

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
    await library.init();
    // 先把上次的曲库铺上，联网成功后会被新数据覆盖
    final snapshot = await library.load();
    if (snapshot != null) _applySnapshot(snapshot);
    cache.setEnabled(autoCache);
    await _sweepLyricCache();
    await player.configure();
    listening.start();

    if (serverUrl.isNotEmpty && username.isNotEmpty && password.isNotEmpty) {
      try {
        // 启动时的自动登录别死等：连不上就早点切离线
        await _doLogin(serverUrl, username, password,
            persist: false, timeout: const Duration(seconds: 6));
      } catch (e) {
        bootError = e.toString();
        // 连不上但有上次的曲库：直接进离线模式，别停在登录页
        if (_isOfflineError(e) && songs.isNotEmpty) {
          bootError = null;
          _enterOffline(e.toString());
        }
      }
    }

    bootstrapping = false;
    notifyListeners();
  }

  /// 网络层错误（超时、连不上、证书错误）。凭证错误（401）不算，
  /// 那种情况该回登录页重新登录，而不是拿本地快照顶着。
  bool _isOfflineError(Object error) {
    if (error is ApiException) return error.status == 0;
    return false;
  }

  void _applySnapshot(LibraryCache snapshot) {
    // 快照只对同一台服务器有意义
    final saved = MusicApi.normalize(snapshot.serverUrl);
    final current = MusicApi.normalize(serverUrl);
    if (saved.isNotEmpty && current.isNotEmpty && saved != current) return;
    songs = snapshot.songs;
    _songIndex = {for (final song in songs) song.id: song};
    favoriteIds = List<String>.of(snapshot.favorites);
    playlists = List<Playlist>.of(snapshot.playlists);
    if (snapshot.serverName.isNotEmpty) serverName = snapshot.serverName;
  }

  /// 进离线模式。api 仍建一个（没有 token），只为让播放器有队列可用；
  /// 离线下的音源全部走本地缓存，不会真的请求它。
  void _enterOffline([String? reason]) {
    final base = MusicApi.normalize(serverUrl);
    if (base.isEmpty) return;
    final client = MusicApi(base);
    api = client;
    player.api = client;
    player.offline = true;
    offline = true;
    lastError = reason ?? '未连接服务器';
    notifyListeners();
  }

  void _setOnline() {
    if (!offline) return;
    offline = false;
    player.offline = false;
  }

  /// 快照写盘串成一条链，避免曲库与收藏两个请求同时回来时写坏同一个文件。
  Future<void> _snapshotChain = Future<void>.value();

  void _saveSnapshot() {
    final snapshot = LibraryCache(
      serverUrl: serverUrl,
      username: username,
      serverName: serverName,
      songs: List<Song>.of(songs),
      favorites: List<String>.of(favoriteIds),
      playlists: List<Playlist>.of(playlists),
      savedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _snapshotChain = _snapshotChain.then((_) => library.save(snapshot));
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
      {bool persist = true, Duration timeout = const Duration(seconds: 12)}) async {
    final base = MusicApi.normalize(url);
    if (base.isEmpty) throw ApiException('请填写服务器地址');
    final client = MusicApi(base);
    final result = await client.login(user, pass, timeout: timeout);
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
    offline = false;
    player.offline = false;
    bootError = null;

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
      _setOnline();
      _saveSnapshot();
    } catch (e) {
      lastError = e.toString();
      if (_isOfflineError(e)) _markOffline(e.toString());
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
      _setOnline();
      _saveSnapshot();
      notifyListeners();
    } catch (e) {
      lastError = e.toString();
      if (_isOfflineError(e)) _markOffline(e.toString());
      notifyListeners();
    }
  }

  /// 用着用着断网了：不弹窗，静默切离线，界面照旧显示已有列表。
  void _markOffline(String reason) {
    if (offline) return;
    offline = true;
    player.offline = true;
    lastError = reason;
    notifyListeners();
  }

  /// 听歌时长排行榜：先把本地攒的单位报上去，数字才是最新的。
  Future<ListeningStats> fetchListening() async {
    final client = _onlineApi;
    if (client == null) throw ApiException('当前离线，看不到听歌时长');
    await listening.flush();
    return client.fetchListening();
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
    final client = _onlineApi;
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
    final client = _onlineApi;
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
    final client = _onlineApi;
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
    final client = _onlineApi;
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
    final client = _onlineApi;
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
    final client = _onlineApi;
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
    final client = _onlineApi;
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
    final client = _onlineApi;
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
    final client = _onlineApi;
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
    final client = _onlineApi;
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
    final client = _onlineApi;
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
    // 退出前把攒着的听歌单位送出去，stop() 之后就没法上报了
    await listening.flush();
    await player.stop();
    listening.reset();
    // 停掉还没下完的缓存任务；半截文件和断点记录保留，下次登录接着下
    await cache.cancelAll();
    player.api = null;
    player.offline = false;
    api = null;
    offline = false;
    songs = [];
    favoriteIds = [];
    playlists = [];
    _songIndex = {};
    serverUrl = '';
    username = '';
    password = '';
    // 退出登录：曲库快照跟着作废，下次换账号不会看到上一台的列表
    await library.clear();
    await _prefs.remove('serverUrl');
    await _prefs.remove('username');
    await _prefs.remove('password');
    notifyListeners();
  }

  @override
  void dispose() {
    listening.dispose();
    player.dispose();
    cache.dispose();
    super.dispose();
  }
}
