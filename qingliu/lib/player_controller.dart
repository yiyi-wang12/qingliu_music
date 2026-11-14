import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'api.dart';
import 'cache_service.dart';
import 'chunk_stream.dart';
import 'media_session.dart';
import 'models.dart';

/// 离线模式下点到一首没有本地缓存的歌。
class OfflineNoCacheException implements Exception {
  const OfflineNoCacheException(this.song);

  final Song song;

  @override
  String toString() => '未连接服务器，${song.name} 没有本地缓存';
}

/// 播放队列与控制。
///
/// 一次只给播放器装**一首**歌的音源，播完由这里决定下一首。
/// 不能用 just_audio 的播放列表：它自己会顺着往下播，单曲循环、随机播放、
/// 关掉自动连播这几项全部会失效（只剩顺序播放）。
class PlayerController extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  MusicApi? api;
  CacheService? cache;
  MediaSessionService? media;

  /// 离线模式：只有本地缓存能放，网络音源不去碰。
  bool offline = false;

  /// 离线又没缓存时的提示出口，由界面层注入（全局弹窗）。
  void Function(Song song)? onOfflineMiss;

  List<Song> queue = [];
  int index = -1;
  bool autoNext = true;
  String playMode = 'list'; // list / one / shuffle
  String? error;

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerException>? _errorSub;

  /// 连点切歌时后一次加载作废前一次，旧请求回来不会再覆盖新歌。
  int _loadToken = 0;

  /// 播完只处理一次，避免 completed 重复触发。
  bool _advancing = false;

  AudioPlayer get audio => _player;
  Song? get current => (index >= 0 && index < queue.length) ? queue[index] : null;
  bool get isPlaying => _player.playing;

  /// 网络播放走的本机分块代理，第一次播网络歌时起。
  ChunkStreamServer? _stream;

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  Future<void> configure() async {
    // 单曲音源不该自己循环，循环逻辑全在 _handleCompleted 里
    try {
      await _player.setLoopMode(LoopMode.off);
    } catch (_) {}

    _stateSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        if (!_advancing) {
          _advancing = true;
          unawaited(
            _handleCompleted().whenComplete(() => _advancing = false),
          );
        }
      } else {
        notifyListeners();
      }
      syncMedia(position: _player.position, duration: _player.duration);
    });

    _positionSub = _player.positionStream.listen((position) {
      syncMedia(position: position, duration: _player.duration);
    });

    _errorSub = _player.errorStream.listen((e) {
      // 切歌打断上一次加载是正常现象，不当错误弹
      if (e is PlayerInterruptedException) return;
      error = '播放出错：${e.message}';
      notifyListeners();
    });
  }

  /// 把当前播放状态推给锁屏 / 通知栏 / 灵动岛。
  ///
  /// 位置每秒同步一次（内部限流），封面只在换歌时查一次盘。
  void syncMedia({Duration? position, Duration? duration}) {
    final service = media;
    final song = current;
    if (service == null) return;
    if (song == null) {
      service.clear();
      return;
    }
    if (_artSongId != song.id) {
      _artSongId = song.id;
      _artPath = cache?.coverFile(song.id)?.path;
      // 离线时别给通知栏一个抓不到的网络地址，没有本地封面就干脆不给
      _artUrl = (!offline && song.hasCover && api != null)
          ? api!.coverUrl(song.id)
          : null;
    }
    service.update(
      song: song,
      playing: _player.playing,
      position: position ?? _player.position,
      duration: duration ?? _player.duration,
      hasNext: queue.isNotEmpty,
      hasPrevious: queue.isNotEmpty,
      artPath: _artPath,
      artUrl: _artUrl,
    );
  }

  String? _artSongId;
  String? _artPath;
  String? _artUrl;

  /// 一首歌放完了。三种播放模式 + 自动连播开关都在这里生效。
  ///
  /// 缓存正常在开始播放时就已排队（见 [_cacheWhilePlaying]），这里再补一次
  /// 只是兜底：中途才打开缓存开关、或者上一轮没匹配上版本的情况。
  Future<void> _handleCompleted() async {
    _cacheWhilePlaying(current);
    if (!autoNext) {
      // 不连播：停在原地，进度归零，等用户自己点播放
      await _player.pause();
      await _player.seek(Duration.zero);
      notifyListeners();
      syncMedia(position: Duration.zero);
      return;
    }
    if (playMode == 'one') {
      // 同一首重放，音源已经加载好，不用重新请求
      await _player.seek(Duration.zero);
      await _player.play();
      notifyListeners();
      syncMedia(position: Duration.zero);
      return;
    }
    await next();
  }

  Future<void> setQueue(List<Song> songs, {int start = 0}) async {
    if (api == null || songs.isEmpty) return;
    queue = List<Song>.of(songs);
    final target = start.clamp(0, queue.length - 1).toInt();
    // 每首歌都从头放，不续上次的进度
    await _playIndex(target);
  }

  /// 列表里点歌。已经在放这首 → 什么都不做；否则换歌。
  Future<void> playFromList(List<Song> songs, int start) async {
    if (songs.isEmpty) return;
    final target = start.clamp(0, songs.length - 1).toInt();
    if (current?.id == songs[target].id) return;
    if (!_sameQueue(songs)) {
      queue = List<Song>.of(songs);
    }
    await _playIndex(target);
  }

  bool _sameQueue(List<Song> songs) {
    if (queue.length != songs.length) return false;
    for (var i = 0; i < songs.length; i++) {
      if (queue[i].id != songs[i].id) return false;
    }
    return true;
  }

  /// 缓存命中的歌直接播本地文件；没命中就交给本机分块代理。
  ///
  /// 代理按 setting.json 的 chunk_size 一块一块从服务器拉，播放器播当前块时
  /// 下一块已经在路上。代理起不来（极少见）就退回直连服务器，别因此播不了。
  Future<AudioSource> _sourceFor(Song song, MusicApi client) async {
    final local = cache?.audioFile(song.id);
    if (local != null) {
      return AudioSource.uri(Uri.file(local.path));
    }
    // 离线：服务器都连不上，分块代理和直连都是白等，直接报给界面
    if (offline) throw OfflineNoCacheException(song);
    final stream = _stream ??= ChunkStreamServer(() => api);
    if (await stream.ensureStarted()) {
      final url = stream.urlFor(song);
      if (url != null) return AudioSource.uri(Uri.parse(url));
    }
    return AudioSource.uri(Uri.parse(client.streamUrl(song.id)));
  }

  /// 加载第 i 首并播放。队列里其它歌不预装，避免整条列表一起加载。
  Future<void> _playIndex(
    int i, {
    Duration position = Duration.zero,
    bool autoplay = true,
  }) async {
    final client = api;
    if (client == null || i < 0 || i >= queue.length) return;

    final token = ++_loadToken;
    final previousIndex = index;
    index = i;
    error = null;
    notifyListeners();
    // 新歌的时长还没解析出来，别让通知栏继续显示上一首的
    syncMedia(position: Duration.zero, duration: Duration.zero);

    // 块大小以服务端 setting.json 为准，切歌顺手刷新一次（一分钟内只拉一次）
    if (!offline) unawaited(client.refreshConfig());

    try {
      final source = await _sourceFor(queue[i], client);
      if (token != _loadToken) return;
      await _player.setAudioSource(source, initialPosition: position);
      if (token != _loadToken) return;
      if (autoplay) await _player.play();
    } catch (e) {
      if (token != _loadToken) return;
      if (e is OfflineNoCacheException) {
        // 这首放不了：退回上一首，别让界面停在一首没放出来的歌上
        index = previousIndex;
        _artSongId = null;
        notifyListeners();
        syncMedia();
        onOfflineMiss?.call(e.song);
        return;
      }
      error = '播放失败：$e';
      notifyListeners();
    }
    if (token != _loadToken) return;
    syncMedia(position: position);
    // 一开播就顺手缓存整首，不必等放完
    _cacheWhilePlaying(queue[i]);
  }

  /// 手动「添加缓存」：不看自动缓存开关，排进下载队列。
  ///
  /// 和自动缓存共用一条队列，一次只下一首；播放缓冲时同样会让路。
  Future<bool> cacheSong(Song song) async {
    final client = api;
    final store = cache;
    if (client == null || store == null) return false;
    return store.addToCache(song, client, shouldPause: downloadShouldPause);
  }

  /// 开始播放一首歌时，顺手把整首拉进缓存（缓存开关打开才做）。
  ///
  /// 播放走的是本机分块代理，缓存是另一路整首下载，两条腿各跑各的：
  /// 缓冲不够时 [downloadShouldPause] 会让下载停下，缓冲攒够再继续，
  /// 所以下载抢不过播放。放完一首时通常已经存好，切歌也不会白下。
  void _cacheWhilePlaying(Song? song) {
    final client = api;
    final store = cache;
    if (client == null || song == null || store == null) return;
    // 离线时下载必然失败，别把队列塞满失败任务
    if (offline) return;
    if (!store.enabled || store.isCached(song.id)) return;
    unawaited(store.prefetch(
      song,
      client,
      shouldPause: downloadShouldPause,
    ));
  }

  /// 播放器一进入缓冲就停下载，缓冲攒够了再继续。
  /// 缓存下载和播放并行，这样下载永远抢不过播放。
  bool downloadShouldPause() {
    try {
      // 没在播放（暂停 / 停下）就不必让路，正好趁机下完
      if (!_player.playing) return false;
      final state = _player.processingState;
      if (state == ProcessingState.loading ||
          state == ProcessingState.buffering) {
        return true;
      }
      if (state != ProcessingState.ready) return false;
      final buffered = _player.bufferedPosition;
      final position = _player.position;
      // 拿不到缓冲信息就当作充足，别把下载永久停掉
      if (buffered <= position) return false;
      return (buffered - position) < const Duration(seconds: 3);
    } catch (_) {
      return false;
    }
  }

  Future<void> toggle() async {
    if (current == null) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
    notifyListeners();
    syncMedia(position: _player.position);
  }

  Future<void> playAt(int i) async {
    if (i < 0 || i >= queue.length) return;
    await _playIndex(i);
  }

  Future<void> next() async {
    if (queue.isEmpty) return;
    int target;
    if (playMode == 'shuffle' && queue.length > 1) {
      final random = Random();
      do {
        target = random.nextInt(queue.length);
      } while (target == index);
    } else {
      target = index + 1;
      if (target >= queue.length) target = 0;
    }
    await _playIndex(target);
  }

  Future<void> previous() async {
    if (queue.isEmpty) return;
    var target = index - 1;
    if (target < 0) target = queue.length - 1;
    await _playIndex(target);
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
    syncMedia(position: position);
  }

  /// 跳到指定位置并继续播放（点歌词用）。
  Future<void> seekAndPlay(Duration position) async {
    if (current == null) return;
    try {
      await _player.seek(position);
      if (!_player.playing) await _player.play();
      notifyListeners();
    } catch (e) {
      error = '播放失败：$e';
      notifyListeners();
    }
    syncMedia(position: position);
  }

  void setPlayMode(String mode) {
    playMode = mode;
    notifyListeners();
  }

  void setAutoNext(bool value) {
    autoNext = value;
    notifyListeners();
  }

  Future<void> stop() async {
    _loadToken++;
    cache?.cancelPrefetch();
    try {
      await _player.stop();
    } catch (_) {}
    queue = [];
    index = -1;
    media?.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    cache?.cancelPrefetch();
    _stream?.close();
    _stream = null;
    _stateSub?.cancel();
    _positionSub?.cancel();
    _errorSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
