import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'models.dart';

/// 一首歌的缓存记录。version 与服务器文件指纹一致才算命中。
class CacheEntry {
  const CacheEntry({
    required this.songId,
    required this.name,
    required this.artist,
    required this.version,
    required this.lrcVersion,
    required this.coverVersion,
    required this.audioExt,
    required this.coverExt,
    required this.audioBytes,
    required this.lrcBytes,
    required this.coverBytes,
    required this.cachedAt,
  });

  final String songId;
  final String name;
  final String artist;
  final String version;
  final String lrcVersion;
  final String coverVersion;
  final String audioExt;
  final String coverExt;
  final int audioBytes;
  final int lrcBytes;
  final int coverBytes;
  final int cachedAt;

  int get totalBytes => audioBytes + lrcBytes + coverBytes;

  DateTime get cachedTime => DateTime.fromMillisecondsSinceEpoch(cachedAt);

  Map<String, dynamic> toJson() => {
        'song_id': songId,
        'name': name,
        'artist': artist,
        'version': version,
        'lrc_version': lrcVersion,
        'cover_version': coverVersion,
        'audio_ext': audioExt,
        'cover_ext': coverExt,
        'audio_bytes': audioBytes,
        'lrc_bytes': lrcBytes,
        'cover_bytes': coverBytes,
        'cached_at': cachedAt,
      };

  factory CacheEntry.fromJson(Map<String, dynamic> json) {
    String asText(dynamic value) => value?.toString() ?? '';
    int asInt(dynamic value) => (value as num?)?.toInt() ?? 0;
    return CacheEntry(
      songId: asText(json['song_id']),
      name: asText(json['name']),
      artist: asText(json['artist']),
      version: asText(json['version']),
      lrcVersion: asText(json['lrc_version']),
      coverVersion: asText(json['cover_version']),
      audioExt: asText(json['audio_ext']),
      coverExt: asText(json['cover_ext']),
      audioBytes: asInt(json['audio_bytes']),
      lrcBytes: asInt(json['lrc_bytes']),
      coverBytes: asInt(json['cover_bytes']),
      cachedAt: asInt(json['cached_at']),
    );
  }
}

/// 缓存管理页里「正在下载」的一行。
class CacheDownload {
  const CacheDownload({
    required this.songId,
    required this.name,
    required this.artist,
    required this.received,
    required this.total,
    required this.manual,
    required this.waiting,
  });

  final String songId;
  final String name;
  final String artist;

  /// 已落盘的字节数
  final int received;

  /// 整首大小，0 表示还没探测到
  final int total;

  /// 手动点的（会持久化、重开应用自动续传）/ 播放时顺手下的
  final bool manual;

  /// 还在排队，等前一首下完
  final bool waiting;

  double get progress =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : 0.0;
}

/// 一条连接负责的字节区间。
///
/// [offset] 只是内存里的进度，真正的断点在段文件的长度上——
/// 进程被杀也丢不掉，重开时按文件大小接着写。
class _Lane {
  _Lane(this.start, this.end, this.offset);

  final int start;
  final int end;
  int offset;

  int get span => end - start + 1;

  int get done {
    final written = offset - start;
    if (written <= 0) return 0;
    return written > span ? span : written;
  }

  bool get finished => offset > end;
}

/// 一次整首下载的共享状态。进度就是所有 lane 的已写字节之和。
class _Task {
  _Task({
    required this.songId,
    required this.version,
    required this.ext,
    required this.total,
    required this.meta,
  });

  final String songId;
  final String version;
  final String ext;
  final File meta;

  int total;
  bool cancelled = false;

  /// 用户点了取消：收尾时把段文件和布局记录一起丢掉，不留断点
  bool discard = false;

  final List<_Lane> lanes = [];

  int get received => lanes.fold<int>(0, (sum, lane) => sum + lane.done);

  double get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : 0.0;
}

/// 排队中的一次缓存下载。手动「添加缓存」和播放时顺手缓存共用这条队列。
class _Job {
  _Job(this.song, this.api, this.shouldPause,
      {required this.manual, required this.lanes});

  final Song song;
  final MusicApi api;
  final bool Function()? shouldPause;

  /// 手动点的：排在队里就一直等，并写进持久队列。
  /// 自动缓存只跟当前这首，新的挤掉旧的。
  final bool manual;

  /// 初始分段数。手动给足带宽，播放时顺手下的收敛一点，别把缓冲抢空。
  final int lanes;
}

/// Range 探测结果：服务端是否支持分段，以及音频的真实总长度。
class _Probe {
  const _Probe(this.ranges, this.total);

  final bool ranges;
  final int total;
}

/// 多连接下载的共享状态。任一条连接失败就整体叫停，别让其它连接白跑。
class _Run {
  bool aborted = false;
}

/// 本地缓存：音频 / 歌词 / 封面。
///
/// 播放本身走网络流（服务端按 setting.json 的 chunk_size 分块发送，边下边播）。
/// 「自动缓存」打开时，一首歌**一开播就顺手把整首拉到本地**，下载在播放缓冲
/// 不足时自动让路，放完基本已经存好。
///
/// 写盘结构（断点续传靠它）：
///   * 每条连接写自己的段文件 `audio/{id}.{ext}.p0 / .p1 / …`，用追加方式打开，
///     段文件有多长就代表那段下到哪，进程被杀也不会丢进度；
///   * 布局（每段负责的字节区间）和版本指纹写在 `{id}.{ext}.p.json`；
///   * 全部段齐了才拼成 `{id}.{ext}.merging`，校验长度后改名落盘，
///     缺字节的残缺文件绝不会被当成缓存；
///   * 手动「添加缓存」的队列写进 `queue.json`，重开应用自动接着下。
class CacheService extends ChangeNotifier {
  /// 手动下载的并发连接数。
  ///
  /// 服务端单条连接只有 0.5MB/s 左右（Linux 上是 ThreadingHTTPServer，
  /// Range 请求天然并发），实测 4 条能到 1.2MB/s 上下；再加收益递减，
  /// 还容易把同时播放的缓冲抢空，所以固定 4。
  static const int parallelConnections = 4;

  /// 播放时顺手缓存用的连接数：留足带宽给正在播的那一路。
  static const int playingConnections = 2;

  bool enabled = false;
  bool ready = false;

  /// 由播放器注入：正在播放且缓冲吃紧时返回 true，下载让路。
  ///
  /// 用回调解耦，恢复出来的下载任务也能自动让路，不必逐个传参。
  bool Function()? playbackGuard;

  Directory? _root;
  final Map<String, CacheEntry> entries = {};
  _Task? _task;
  _Job? _current;
  final List<_Job> _queue = [];
  bool _draining = false;

  /// 手动点的、还没下完的歌。写进 queue.json，重开应用按这个恢复。
  final List<String> _manualPending = [];

  DateTime _progressAt = DateTime.fromMillisecondsSinceEpoch(0);

  int get count => entries.length;

  int get totalBytes =>
      entries.values.fold<int>(0, (sum, entry) => sum + entry.totalBytes);

  List<CacheEntry> get all {
    final list = entries.values.toList()
      ..sort((a, b) => b.cachedAt.compareTo(a.cachedAt));
    return list;
  }

  /// 缓存管理页要显示的下载中条目：正在下的在前，排队中的在后。
  List<CacheDownload> get downloads {
    final result = <CacheDownload>[];
    final job = _current;
    final task = _task;
    if (job != null) {
      final total = task?.total ?? 0;
      result.add(CacheDownload(
        songId: job.song.id,
        name: job.song.name,
        artist: job.song.artist,
        received: task?.received ?? 0,
        total: total > 0 ? total : job.song.size,
        manual: job.manual,
        waiting: false,
      ));
    }
    for (final item in _queue) {
      result.add(CacheDownload(
        songId: item.song.id,
        name: item.song.name,
        artist: item.song.artist,
        received: 0,
        total: item.song.size,
        manual: item.manual,
        waiting: true,
      ));
    }
    return result;
  }

  bool isCached(String songId) => entries.containsKey(songId);

  Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      _root = Directory('${base.path}/music_cache');
      for (final name in ['audio', 'lrc', 'cover']) {
        await Directory('${_root!.path}/$name').create(recursive: true);
      }
      // 老版本会把整首静默下到 temp 目录，现在播放走网络流，清掉遗留
      await _dropLegacyTemp();
      await _load();
      await _loadQueue();
      ready = true;
    } catch (_) {
      _root = null;
      ready = false;
    }
    notifyListeners();
  }

  void setEnabled(bool value) {
    if (enabled == value) return;
    enabled = value;
    notifyListeners();
  }

  // ---------------- 本地文件定位 ----------------

  File? audioFile(String songId) {
    final entry = entries[songId];
    if (!ready || entry == null || entry.audioExt.isEmpty) return null;
    final file = File('${_root!.path}/audio/$songId.${entry.audioExt}');
    return file.existsSync() ? file : null;
  }

  File? lrcFile(String songId) {
    final entry = entries[songId];
    if (!ready || entry == null || entry.lrcBytes <= 0) return null;
    final file = File('${_root!.path}/lrc/$songId.lrc');
    return file.existsSync() ? file : null;
  }

  File? coverFile(String songId) {
    final entry = entries[songId];
    if (!ready || entry == null || entry.coverExt.isEmpty) return null;
    final file = File('${_root!.path}/cover/$songId.${entry.coverExt}');
    return file.existsSync() ? file : null;
  }

  // ---------------- 下载队列 ----------------

  /// 播放时顺手缓存：只在缓存开关打开、且这首还没缓存时排队。
  ///
  /// 播放器这时正在放这首，[shouldPause] 返回 true 时会在下一个分块前
  /// 暂停，给播放让路。
  Future<void> prefetch(
    Song song,
    MusicApi api, {
    bool Function()? shouldPause,
  }) async {
    await _submit(song, api, force: false, shouldPause: shouldPause);
  }

  /// 手动「添加缓存」：不看自动缓存开关，直接排进队列并持久化。
  ///
  /// 一次只下一首，点几首就排几首，互不打断。返回 false 表示缓存目录没准备好
  /// （初始化失败），true 表示已排队或本来就有缓存。
  Future<bool> addToCache(
    Song song,
    MusicApi api, {
    bool Function()? shouldPause,
  }) {
    return _submit(song, api, force: true, shouldPause: shouldPause);
  }

  /// 登录成功后调用：把手动队列里没下完的接着下。
  ///
  /// 只按 id 记，曲库里找不到的（服务器换过文件、换了曲库）直接丢掉。
  Future<void> resumeManual(MusicApi api, List<Song> songs) async {
    if (!ready || _manualPending.isEmpty) return;
    final byId = {for (final song in songs) song.id: song};
    final ids = List<String>.of(_manualPending);
    var changed = false;
    for (final id in ids) {
      final song = byId[id];
      if (song == null) {
        _manualPending.remove(id);
        changed = true;
        continue;
      }
      if (entries.containsKey(id) || isPending(id)) continue;
      await _submit(song, api, force: true, shouldPause: null);
    }
    if (changed) await _saveQueue();
    notifyListeners();
  }

  /// 这一首是在下还是排在队里。
  bool isPending(String songId) =>
      _task?.songId == songId || _queue.any((job) => job.song.id == songId);

  /// 用户主动取消：停掉下载、删掉半截段文件和断点记录。
  Future<void> cancelDownload(String songId) async {
    final task = _task;
    if (task != null && task.songId == songId) {
      task.discard = true;
      task.cancelled = true;
      _task = null;
    }
    _queue.removeWhere((job) => job.song.id == songId);
    if (_manualPending.remove(songId)) await _saveQueue();
    await _dropParts(songId);
    notifyListeners();
  }

  Future<bool> _submit(
    Song song,
    MusicApi api, {
    required bool force,
    bool Function()? shouldPause,
  }) async {
    final root = _root;
    if (!ready || root == null) return false;
    if (!force && !enabled) return false;
    if (api.token == null || song.id.isEmpty) return false;

    // 已经有缓存：音频不用重下，只在版本变了时补歌词/封面
    final cached = audioFile(song.id);
    if (cached != null && entries[song.id]?.version == song.version) {
      final old = entries[song.id];
      if (old != null &&
          (old.lrcVersion != song.lrcVersion ||
              old.coverVersion != song.coverVersion)) {
        await _finalize(song, api, cached);
      }
      if (force && _manualPending.remove(song.id)) await _saveQueue();
      return true;
    }

    // 同一首只跑一个下载，避免两条连接写同一个文件
    if (isPending(song.id)) return true;

    // 自动缓存只跟当前这首：正在下的这首已经过半就让它收尾，否则让位
    if (!force) {
      _queue.removeWhere((job) => !job.manual);
      final current = _current;
      if (current != null && !current.manual) {
        if ((_task?.fraction ?? 0) >= 0.6) return true;
        cancelPrefetch();
      }
    }

    if (force && !_manualPending.contains(song.id)) {
      _manualPending.add(song.id);
      await _saveQueue();
    }

    _queue.add(_Job(
      song,
      api,
      shouldPause,
      manual: force,
      lanes: force ? parallelConnections : playingConnections,
    ));
    unawaited(_drain());
    notifyListeners();
    return true;
  }

  /// 队列一次只处理一首，下完一首再下一首。
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeAt(0);
        try {
          await _runJob(job);
        } catch (_) {
          // 单首失败（网络断了、文件被删）不影响后面排队的
        }
      }
    } finally {
      _draining = false;
      notifyListeners();
    }
  }

  Future<void> _runJob(_Job job) async {
    final root = _root;
    if (root == null) return;
    final song = job.song;
    final api = job.api;
    final ext = song.ext.isEmpty ? 'bin' : song.ext;
    final meta = File('${root.path}/audio/${song.id}.$ext.p.json');
    final merging = File('${root.path}/audio/${song.id}.$ext.merging');
    final task = _Task(
      songId: song.id,
      version: song.version,
      ext: ext,
      total: song.size,
      meta: meta,
    );

    _current = job;
    _task = task;
    var done = false;

    try {
      await merging.parent.create(recursive: true);
      // 上次没拼完的半截文件先清掉
      await _deleteQuiet(merging);
      // 扩展名变了，旧的段文件就是垃圾；同名同扩展名的留着续传
      await _dropParts(song.id, keepExt: ext);
      done = await _download(song, api, task, merging, job);
      if (done && task.cancelled) done = false;
      if (done) {
        _task = null;
        await _deleteQuiet(meta);
        await _cleanSegments(song.id, ext);
        await _finish(song, api, merging);
        if (job.manual && _manualPending.remove(song.id)) {
          await _saveQueue();
        }
      }
    } catch (_) {
      done = false;
    } finally {
      if (!done) {
        // 没下完（断网 / 取消 / 退出）：布局留着，段文件本身就是断点
        if (!task.discard) await _writeMeta(task);
        await _deleteQuiet(merging);
      }
      if (identical(_task, task)) _task = null;
      if (identical(_current, job)) _current = null;
      notifyListeners();
    }
  }

  /// 取消正在进行的下载（停止播放时调用）。队列里排着的保持不变，
  /// 清空缓存前要连队列一起清。
  void cancelPrefetch([String? songId]) {
    final task = _task;
    final job = _current;
    if (task == null) return;
    if (songId != null && task.songId != songId) return;
    // 不带参数是「停止播放」：手动的下载不该因此中断
    if (songId == null && job != null && job.manual) return;
    task.cancelled = true;
    _task = null;
  }

  /// 退出登录 / 换账号：停掉所有下载，段文件留给下次续传。
  Future<void> cancelAll() async {
    final task = _task;
    if (task != null) {
      task.cancelled = true;
      _task = null;
    }
    _queue.clear();
    notifyListeners();
  }

  // ---------------- 缓存写入 ----------------

  /// 拼好的整首改名落进缓存，随后补歌词、封面。
  Future<void> _finish(Song song, MusicApi api, File merging) async {
    final root = _root;
    if (root == null) return;
    final ext = song.ext.isEmpty ? 'bin' : song.ext;
    final target = File('${root.path}/audio/${song.id}.$ext');
    await target.parent.create(recursive: true);
    await _deleteQuiet(target);
    final audio = await _moveTo(merging, target);
    await _finalize(song, api, audio);
  }

  /// 补歌词 / 封面，写缓存记录。
  Future<void> _finalize(Song song, MusicApi api, File audio) async {
    final root = _root;
    if (root == null) return;
    final old = entries[song.id];

    // 扩展名变了，旧音频文件是垃圾
    if (old != null && old.audioExt.isNotEmpty && old.audioExt != song.ext) {
      await _deleteQuiet(File('${root.path}/audio/${song.id}.${old.audioExt}'));
    }

    // 歌词
    final lrc = File('${root.path}/lrc/${song.id}.lrc');
    if (song.hasLrc) {
      final lrcOk = old != null &&
          old.lrcVersion == song.lrcVersion &&
          old.lrcBytes > 0 &&
          lrc.existsSync();
      if (!lrcOk) {
        final text = await api.fetchLyric(song.id);
        if (text != null && text.isNotEmpty) {
          await lrc.parent.create(recursive: true);
          await lrc.writeAsString(text, flush: true);
        }
      }
    } else {
      await _deleteQuiet(lrc);
    }

    // 封面
    var coverExt = '';
    if (song.hasCover) {
      final cachedCover = old != null &&
          old.coverVersion == song.coverVersion &&
          old.coverExt.isNotEmpty &&
          File('${root.path}/cover/${song.id}.${old.coverExt}').existsSync();
      if (cachedCover) {
        coverExt = old.coverExt;
      } else {
        if (old != null && old.coverExt.isNotEmpty) {
          await _deleteQuiet(
              File('${root.path}/cover/${song.id}.${old.coverExt}'));
        }
        coverExt = await _downloadCover(api.coverUrl(song.id), song.id);
      }
    } else if (old != null && old.coverExt.isNotEmpty) {
      await _deleteQuiet(File('${root.path}/cover/${song.id}.${old.coverExt}'));
    }

    final cover = coverExt.isEmpty
        ? null
        : File('${root.path}/cover/${song.id}.$coverExt');

    entries[song.id] = CacheEntry(
      songId: song.id,
      name: song.name,
      artist: song.artist,
      version: song.version,
      lrcVersion: song.lrcVersion,
      coverVersion: song.coverVersion,
      audioExt: song.ext,
      coverExt: coverExt,
      audioBytes: audio.existsSync() ? audio.lengthSync() : 0,
      lrcBytes: lrc.existsSync() ? lrc.lengthSync() : 0,
      coverBytes: (cover != null && cover.existsSync()) ? cover.lengthSync() : 0,
      cachedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _save();
    notifyListeners();
  }

  Future<void> remove(String songId) async {
    await cancelDownload(songId);
    final entry = entries.remove(songId);
    if (entry == null) return;
    if (_root != null) {
      await _deleteQuiet(File('${_root!.path}/audio/$songId.${entry.audioExt}'));
      await _deleteQuiet(File('${_root!.path}/lrc/$songId.lrc'));
      if (entry.coverExt.isNotEmpty) {
        await _deleteQuiet(
            File('${_root!.path}/cover/$songId.${entry.coverExt}'));
      }
    }
    await _save();
    notifyListeners();
  }

  /// 只清歌词缓存，音频和封面保留。
  ///
  /// 服务端歌词解码规则改过之后，旧缓存里可能存着按错编码解出来的乱码，
  /// 而缓存是否命中的判据是文件指纹——服务器上的 .lrc 没变，那些乱码
  /// 就会一直躺在本地。升级时清一次歌词，强制重新拉取。
  Future<void> clearLyrics() async {
    final root = _root;
    if (root != null) {
      final dir = Directory('${root.path}/lrc');
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
      await dir.create(recursive: true);
    }
    final patched = <String, CacheEntry>{};
    for (final entry in entries.values) {
      patched[entry.songId] = CacheEntry(
        songId: entry.songId,
        name: entry.name,
        artist: entry.artist,
        version: entry.version,
        lrcVersion: '',
        coverVersion: entry.coverVersion,
        audioExt: entry.audioExt,
        coverExt: entry.coverExt,
        audioBytes: entry.audioBytes,
        lrcBytes: 0,
        coverBytes: entry.coverBytes,
        cachedAt: entry.cachedAt,
      );
    }
    entries
      ..clear()
      ..addAll(patched);
    await _save();
    notifyListeners();
  }

  Future<void> clear() async {
    cancelPrefetch();
    _queue.clear();
    _manualPending.clear();
    entries.clear();
    final root = _root;
    if (root != null) {
      for (final name in ['audio', 'lrc', 'cover']) {
        final dir = Directory('${root.path}/$name');
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
        await dir.create(recursive: true);
      }
      await _deleteQuiet(File('${root.path}/queue.json'));
    }
    await _save();
    await _saveQueue();
    notifyListeners();
  }

  // ---------------- 内部实现 ----------------

  Future<void> _load() async {
    entries.clear();
    final file = File('${_root!.path}/manifest.json');
    if (!file.existsSync()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      final list = (decoded is Map ? decoded['entries'] : null) as List?;
      if (list == null) return;
      for (final item in list) {
        if (item is Map) {
          final entry = CacheEntry.fromJson(Map<String, dynamic>.from(item));
          if (entry.songId.isNotEmpty) entries[entry.songId] = entry;
        }
      }
    } catch (_) {
      // 记录损坏就当作空缓存
    }
  }

  Future<void> _save() async {
    final root = _root;
    if (root == null) return;
    try {
      final data = {
        'entries': entries.values.map((entry) => entry.toJson()).toList(),
      };
      await File('${root.path}/manifest.json')
          .writeAsString(jsonEncode(data), flush: true);
    } catch (_) {
      // 写失败不影响播放
    }
  }

  Future<void> _loadQueue() async {
    _manualPending.clear();
    final root = _root;
    if (root == null) return;
    final file = File('${root.path}/queue.json');
    if (!file.existsSync()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      final list = (decoded is Map ? decoded['manual'] : null) as List?;
      if (list == null) return;
      for (final item in list) {
        final id = item?.toString() ?? '';
        if (id.isNotEmpty && !_manualPending.contains(id)) _manualPending.add(id);
      }
    } catch (_) {
      // 队列损坏就当没有
    }
  }

  Future<void> _saveQueue() async {
    final root = _root;
    if (root == null) return;
    try {
      await File('${root.path}/queue.json')
          .writeAsString(jsonEncode({'manual': _manualPending}), flush: true);
    } catch (_) {}
  }

  /// 整首下载的调度入口。
  ///
  /// 先探一次服务端是否支持 Range：支持就按 [job.lanes] 分段并发拉，
  /// 不支持（或文件太小不值得切）就单连接顺序拉。有断点就接着下。
  Future<bool> _download(
    Song song,
    MusicApi api,
    _Task task,
    File merging,
    _Job job,
  ) async {
    final uri = Uri.parse(api.streamUrl(song.id));
    final step = api.chunkSize <= 0 ? 262144 : api.chunkSize;

    final probe = await _probe(uri);
    if (task.cancelled) return false;

    final total = probe.total > 0 ? probe.total : song.size;
    if (total <= 0) return false;
    task.total = total;

    final layout = probe.ranges
        ? _loadLayout(task.meta, song.version, total)
        : null;

    if (layout == null) {
      // 布局对不上（新下载 / 服务端换了文件 / 不支持 Range）：
      // 段文件全部作废，按新分区从头来
      await _cleanSegments(song.id, task.ext);
      await _deleteQuiet(task.meta);
      task.lanes.addAll(_initialLanes(
          total, step, probe.ranges ? job.lanes : 1));
      await _writeMeta(task);
    } else {
      task.lanes.addAll(layout);
    }

    // 段文件有多长，就代表那条连接下到哪了
    for (var i = 0; i < task.lanes.length; i++) {
      final lane = task.lanes[i];
      final segment = _segmentFile(task.songId, task.ext, i);
      var exist = segment.existsSync() ? await segment.length() : 0;
      if (exist > lane.span) {
        // 多出来的数据说不清是哪次的，这条从头重下
        await _deleteQuiet(segment);
        exist = 0;
      }
      lane.offset = lane.start + exist;
    }

    if (!task.lanes.every((lane) => lane.finished)) {
      final run = _Run();
      final futures = <Future<bool>>[];
      for (var i = 0; i < task.lanes.length; i++) {
        final lane = task.lanes[i];
        if (lane.finished) continue;
        futures.add(_lane(
          run,
          uri,
          _segmentFile(task.songId, task.ext, i),
          lane,
          step,
          task,
          job.shouldPause,
        ));
      }
      final results = await Future.wait(futures);
      if (task.cancelled) return false;
      if (results.any((ok) => !ok)) return false;
    }

    // 每段都得是满的，少一个字节都不拼
    for (var i = 0; i < task.lanes.length; i++) {
      final lane = task.lanes[i];
      final segment = _segmentFile(task.songId, task.ext, i);
      if (!segment.existsSync()) return false;
      if (await segment.length() != lane.span) return false;
    }

    if (!await _merge(task, merging)) return false;
    return await merging.length() == total;
  }

  /// 用 1 字节的 Range 请求探一下：支持就顺手拿到真实总长度。
  ///
  /// 服务端每条连接的速度是瓶颈，值不值得并发全看这里。老版本服务端
  /// 或者没实现 Range 的反向代理会返回 200，那就老实用单连接。
  Future<_Probe> _probe(Uri uri) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      request.headers['Range'] = 'bytes=0-0';
      final response =
          await client.send(request).timeout(const Duration(seconds: 12));
      if (response.statusCode == 206) {
        await response.stream.drain<void>();
        final match = RegExp(r'bytes\s+\d+-\d+/(\d+)')
            .firstMatch(response.headers['content-range'] ?? '');
        final total = match == null ? 0 : (int.tryParse(match.group(1)!) ?? 0);
        return _Probe(true, total);
      }
      if (response.statusCode == 200) {
        return _Probe(false, response.contentLength ?? 0);
      }
      return const _Probe(false, 0);
    } catch (_) {
      return const _Probe(false, 0);
    } finally {
      // 200 时 body 是整个文件，别读，直接关连接
      client.close();
    }
  }

  /// 从布局记录恢复上次的分段。版本或大小对不上（服务端换了文件）就作废。
  List<_Lane>? _loadLayout(File meta, String version, int total) {
    try {
      if (!meta.existsSync()) return null;
      final decoded = jsonDecode(meta.readAsStringSync());
      if (decoded is! Map) return null;
      if (decoded['version']?.toString() != version) return null;
      final savedTotal = (decoded['total'] as num?)?.toInt() ?? 0;
      if (savedTotal != total) return null;
      final raw = decoded['lanes'];
      if (raw is! List || raw.isEmpty) return null;
      final lanes = <_Lane>[];
      for (final item in raw) {
        if (item is! List || item.length < 2) return null;
        final start = (item[0] as num?)?.toInt();
        final end = (item[1] as num?)?.toInt();
        if (start == null || end == null) return null;
        if (start < 0 || end < start || end >= total) return null;
        lanes.add(_Lane(start, end, start));
      }
      return lanes;
    } catch (_) {
      return null;
    }
  }

  /// 首次下载的分段：按 [maxLanes] 把整首劈成等长区间。
  List<_Lane> _initialLanes(int total, int step, int maxLanes) {
    final lanes = min(maxLanes, max(1, (total + step - 1) ~/ step));
    if (lanes <= 1) return [_Lane(0, total - 1, 0)];
    final per = (total + lanes - 1) ~/ lanes;
    final result = <_Lane>[];
    for (var i = 0; i < lanes; i++) {
      final start = i * per;
      if (start >= total) break;
      result.add(_Lane(start, min(start + per, total) - 1, start));
    }
    return result;
  }

  /// 一条连接：接着段文件的末尾，按 step 分块往后写。
  ///
  /// 分块是为了让播放要缓冲时能中途让路，取消也能及时停。
  Future<bool> _lane(
    _Run run,
    Uri uri,
    File segment,
    _Lane lane,
    int step,
    _Task task,
    bool Function()? shouldPause,
  ) async {
    if (lane.finished) return true;
    final client = http.Client();
    RandomAccessFile? raf;
    try {
      // 追加模式：文件里已有多少，下一次写就接在它后面。
      // 断点靠文件长度，不依赖内存里的 offset，进程被杀也不怕。
      raf = await segment.open(mode: FileMode.append);
      while (!lane.finished) {
        if (task.cancelled || run.aborted) return false;
        await _waitForPlayback(task, shouldPause);
        if (task.cancelled || run.aborted) return false;

        final stop = min(lane.offset + step - 1, lane.end);
        var written = 0;
        for (var attempt = 0; attempt < 3; attempt++) {
          if (task.cancelled || run.aborted) return false;
          try {
            written = await _readRange(client, uri, lane.offset, stop, task, raf);
            break;
          } catch (_) {
            written = 0;
            if (attempt >= 2) break;
            await Future<void>.delayed(
                Duration(milliseconds: 300 * (attempt + 1)));
          }
        }
        if (written <= 0) {
          // 一条断了整体就没意义了，叫停其它连接
          run.aborted = true;
          return false;
        }
        lane.offset += written;
        _touchProgress(task);
      }
      return true;
    } catch (_) {
      run.aborted = true;
      return false;
    } finally {
      try {
        await raf?.flush();
      } catch (_) {}
      try {
        await raf?.close();
      } catch (_) {}
      client.close();
    }
  }

  /// 拉一段区间，边收边追加写到段文件，返回实际写入的字节数。
  ///
  /// 区间没拉满就抛异常——半截数据写进缓存比失败更糟。服务端不认 Range、
  /// 直接甩回 200 整文件时，这里把整首都收下（只在单连接模式下出现）。
  Future<int> _readRange(
    http.Client client,
    Uri uri,
    int start,
    int end,
    _Task task,
    RandomAccessFile raf,
  ) async {
    final request = http.Request('GET', uri);
    request.headers['Range'] = 'bytes=$start-$end';
    final response =
        await client.send(request).timeout(const Duration(seconds: 20));
    if (response.statusCode == 200 && start > 0) {
      throw const HttpException('服务端不支持 Range');
    }
    if (response.statusCode != 206 && response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }

    final ranged = response.statusCode == 206;
    final want = end - start + 1;
    var got = 0;
    await for (final block
        in response.stream.timeout(const Duration(seconds: 25))) {
      if (task.cancelled) throw const HttpException('已取消');
      if (!ranged) {
        // 200：body 是整首，照单全收
        await raf.writeFrom(block);
        got += block.length;
        continue;
      }
      final room = want - got;
      if (room <= 0) break;
      final data = block.length > room ? block.sublist(0, room) : block;
      await raf.writeFrom(data);
      got += data.length;
    }
    if (ranged && got != want) {
      throw HttpException('区间不完整 $got/$want');
    }
    return got;
  }

  /// 把各段按顺序拼成一整首。先写 .merging，校验长度后才改名落盘。
  Future<bool> _merge(_Task task, File merging) async {
    IOSink? sink;
    var written = 0;
    try {
      await _deleteQuiet(merging);
      sink = merging.openWrite(mode: FileMode.write);
      for (var i = 0; i < task.lanes.length; i++) {
        final segment = _segmentFile(task.songId, task.ext, i);
        if (!segment.existsSync()) return false;
        await for (final block in segment.openRead()) {
          sink.add(block);
          written += block.length;
        }
      }
      await sink.flush();
    } catch (_) {
      return false;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
    }
    return written == task.total;
  }

  /// 播放器正在缓冲就让路。用户暂停时（不播了）放行，正好趁机下完。
  Future<void> _waitForPlayback(
    _Task task,
    bool Function()? shouldPause,
  ) async {
    var waited = 0;
    while (!task.cancelled && _shouldPause(shouldPause)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      waited += 400;
      // 长时间不 ready（暂停中 / 出错）别把下载僵死在这里
      if (waited >= 30000) return;
    }
  }

  bool _shouldPause(bool Function()? shouldPause) {
    if (shouldPause != null && shouldPause()) return true;
    final guard = playbackGuard;
    return guard != null && guard();
  }

  /// 进度上报：界面 400ms 最多刷一次。
  void _touchProgress(_Task task) {
    final now = DateTime.now();
    if (now.difference(_progressAt).inMilliseconds >= 400) {
      _progressAt = now;
      notifyListeners();
    }
  }

  Future<void> _writeMeta(_Task task) async {
    if (task.discard || task.lanes.isEmpty) return;
    try {
      await task.meta.parent.create(recursive: true);
      final data = {
        'version': task.version,
        'total': task.total,
        'lanes': task.lanes
            .map((lane) => [lane.start, lane.end])
            .toList(),
      };
      await task.meta.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {}
  }

  /// 跨目录移动；rename 失败（分区不同等）就退回复制。
  Future<File> _moveTo(File source, File target) async {
    try {
      return await source.rename(target.path);
    } catch (_) {
      try {
        await target.writeAsBytes(await source.readAsBytes(), flush: true);
        await _deleteQuiet(source);
      } catch (_) {}
      return target;
    }
  }

  Future<String> _downloadCover(String url, String songId) async {
    final client = http.Client();
    try {
      final response = await client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return '';
      final ext = _extFromContentType(response.headers['content-type']);
      final target = File('${_root!.path}/cover/$songId.$ext');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(response.bodyBytes, flush: true);
      return ext;
    } catch (_) {
      return '';
    } finally {
      client.close();
    }
  }

  String _extFromContentType(String? contentType) {
    final type = (contentType ?? '').toLowerCase();
    if (type.contains('png')) return 'png';
    if (type.contains('webp')) return 'webp';
    if (type.contains('gif')) return 'gif';
    if (type.contains('bmp')) return 'bmp';
    return 'jpg';
  }

  /// 老版本的 temp 目录（整首静默下载的中间产物）直接删掉。
  Future<void> _dropLegacyTemp() async {
    final root = _root;
    if (root == null) return;
    final dir = Directory('${root.path}/temp');
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 某首歌的一条连接对应的段文件。
  File _segmentFile(String songId, String ext, int index) =>
      File('${_root!.path}/audio/$songId.$ext.p$index');

  /// 删掉某首歌的所有段文件（可保留一个扩展名的），连同布局记录。
  Future<void> _dropParts(String songId, {String? keepExt}) async {
    final root = _root;
    if (root == null) return;
    try {
      final dir = Directory('${root.path}/audio');
      if (!dir.existsSync()) return;
      final keepPrefix = keepExt == null ? null : '$songId.$keepExt.p';
      final names = <String>[];
      await for (final item in dir.list(followLinks: false)) {
        if (item is File) names.add(item.uri.pathSegments.last);
      }
      for (final name in names) {
        if (!name.startsWith('$songId.')) continue;
        if (name.endsWith('.merging')) continue; // 由调用方单独收
        final isSegment = _segmentName.hasMatch(name);
        // 老版本的 .part / .part.json 结构不同，续不上，直接作废
        final isLegacy = name.contains('.part');
        if (!isSegment && !isLegacy) continue;
        if (isSegment && keepPrefix != null && name.startsWith(keepPrefix)) {
          continue;
        }
        await _deleteQuiet(File('${root.path}/audio/$name'));
      }
    } catch (_) {}
  }

  /// 删掉某首歌的全部段文件。
  Future<void> _cleanSegments(String songId, String ext) async {
    final root = _root;
    if (root == null) return;
    try {
      final dir = Directory('${root.path}/audio');
      if (!dir.existsSync()) return;
      final names = <String>[];
      await for (final item in dir.list(followLinks: false)) {
        if (item is File) names.add(item.uri.pathSegments.last);
      }
      for (final name in names) {
        if (!name.startsWith('$songId.$ext.p')) continue;
        if (_segmentName.hasMatch(name)) {
          await _deleteQuiet(File('${root.path}/audio/$name'));
        }
      }
    } catch (_) {}
  }

  static final RegExp _segmentName = RegExp(r'\.p\d+$');

  Future<void> _deleteQuiet(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }
}
