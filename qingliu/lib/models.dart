class Song {
  final String id;
  final String name;
  final String artist;
  final String album;
  final String ext;
  final int size;
  final double duration;
  final bool hasLrc;
  final bool hasCover;
  final String version;
  final String lrcVersion;
  final String coverVersion;
  final String folder;

  const Song({
    required this.id,
    required this.name,
    required this.artist,
    required this.album,
    required this.ext,
    required this.size,
    required this.duration,
    required this.hasLrc,
    required this.hasCover,
    required this.version,
    required this.lrcVersion,
    required this.coverVersion,
    required this.folder,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '未知歌曲',
      artist: json['artist']?.toString() ?? '未知艺术家',
      album: json['album']?.toString() ?? '',
      ext: json['ext']?.toString() ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      duration: (json['duration'] as num?)?.toDouble() ?? 0,
      hasLrc: json['has_lrc'] == true,
      hasCover: json['has_cover'] == true,
      version: json['version']?.toString() ?? '',
      lrcVersion: json['lrc_version']?.toString() ?? '',
      coverVersion: json['cover_version']?.toString() ?? '',
      folder: json['folder']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'artist': artist,
        'album': album,
        'ext': ext,
        'size': size,
        'duration': duration,
        'has_lrc': hasLrc,
        'has_cover': hasCover,
        'version': version,
        'lrc_version': lrcVersion,
        'cover_version': coverVersion,
        'folder': folder,
      };

  String get subtitle => album.isEmpty ? artist : '$artist · $album';

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        artist.toLowerCase().contains(q) ||
        album.toLowerCase().contains(q) ||
        folder.toLowerCase().contains(q);
  }
}

class Playlist {
  final String id;
  final String name;
  final List<String> songIds;

  const Playlist({required this.id, required this.name, required this.songIds});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'songs': songIds,
      };

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '未命名歌单',
      songIds: (json['songs'] as List?)?.map((e) => e.toString()).toList() ?? <String>[],
    );
  }
}

/// 听歌时长榜上的一首歌。
///
/// 服务端只存整数单位（默认 1 单位 = 6 秒）和歌名，次数不落库：
/// 打开榜单时用当前曲库的歌曲时长现算，见 [plays]。
class ListeningSong {
  final String id;
  final String name;
  final String artist;
  final int units;
  final int unitSeconds;
  final double duration;

  const ListeningSong({
    required this.id,
    required this.name,
    required this.artist,
    required this.units,
    this.unitSeconds = 6,
    this.duration = 0,
  });

  factory ListeningSong.fromJson(Map<String, dynamic> json, int unitSeconds) {
    return ListeningSong(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '未知歌曲',
      artist: json['artist']?.toString() ?? '未知艺术家',
      units: (json['units'] as num?)?.toInt() ?? 0,
      unitSeconds: unitSeconds,
      duration: (json['duration'] as num?)?.toDouble() ?? 0,
    );
  }

  /// 听歌秒数：单位数 × 单位长度。
  double get seconds => units * unitSeconds.toDouble();

  /// 客户端显示单位是分钟。
  double get minutes => seconds / 60;

  /// 次数 = 听歌时长 / 歌曲时长。
  ///
  /// [songDuration] 由页面打开那一刻从当前曲库取，不跟着服务端记录存。
  /// 不取整：听半首就是 0.5 次。
  double plays(double songDuration) {
    if (songDuration <= 0) return 0;
    return seconds / songDuration;
  }
}

/// 一个用户的听歌时长总账。
class ListeningStats {
  final int unitSeconds;
  final int totalUnits;
  final List<ListeningSong> songs;

  const ListeningStats({
    required this.unitSeconds,
    required this.totalUnits,
    required this.songs,
  });

  factory ListeningStats.fromJson(Map<String, dynamic> json) {
    final unitSeconds = (json['unit_seconds'] as num?)?.toInt() ?? 6;
    final list = (json['songs'] as List?) ?? const [];
    return ListeningStats(
      unitSeconds: unitSeconds <= 0 ? 6 : unitSeconds,
      totalUnits: (json['total_units'] as num?)?.toInt() ?? 0,
      songs: list
          .whereType<Map>()
          .map((e) => ListeningSong.fromJson(
                Map<String, dynamic>.from(e),
                unitSeconds <= 0 ? 6 : unitSeconds,
              ))
          .toList(),
    );
  }

  double get totalMinutes => totalUnits * unitSeconds / 60;
}

/// 分钟数按 1 位小数显示，整数就不带小数点：1.1 / 12 / 66。
String formatMinutes(double minutes) => formatOneDecimal(minutes);

/// 次数按 1 位小数显示：0.3 / 1.1 / 4。
/// 不到 0.1 次显示 `<0.1`，不然刚听十几秒又变成 "0 次"，和白听一样。
String formatTimes(double value) {
  if (value <= 0) return '0';
  if (value < 0.05) return '<0.1';
  return formatOneDecimal(value);
}

String formatOneDecimal(double value) {
  if (value <= 0) return '0';
  final rounded = (value * 10).round() / 10;
  if (rounded == rounded.roundToDouble()) {
    return rounded.toStringAsFixed(0);
  }
  return rounded.toStringAsFixed(1);
}

class LyricLine {
  final Duration time;
  final String text;

  const LyricLine(this.time, this.text);
}

/// 解析 LRC 文本，支持一行多个时间标签、[offset:xxx] 与毫秒/百分秒。
List<LyricLine> parseLrc(String raw) {
  final lines = <LyricLine>[];
  var offsetMs = 0;
  final offsetReg = RegExp(r'\[offset:\s*(-?\d+)\s*\]', caseSensitive: false);
  final offsetMatch = offsetReg.firstMatch(raw);
  if (offsetMatch != null) {
    offsetMs = int.tryParse(offsetMatch.group(1)!) ?? 0;
  }

  final tagReg = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final matches = tagReg.allMatches(line);
    if (matches.isEmpty) continue;
    final text = line.replaceAll(tagReg, '').trim();
    for (final m in matches) {
      final min = int.tryParse(m.group(1)!) ?? 0;
      final sec = int.tryParse(m.group(2)!) ?? 0;
      final fracRaw = m.group(3) ?? '0';
      int ms;
      if (fracRaw.length == 1) {
        ms = int.parse(fracRaw) * 100;
      } else if (fracRaw.length == 2) {
        ms = int.parse(fracRaw) * 10;
      } else {
        ms = int.parse(fracRaw);
      }
      final total = Duration(
        milliseconds: min * 60 * 1000 + sec * 1000 + ms - offsetMs,
      );
      lines.add(LyricLine(total, text));
    }
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

String formatDuration(Duration? d) {
  if (d == null || d.inMilliseconds <= 0) return '--:--';
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
