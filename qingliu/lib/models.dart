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

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '未命名歌单',
      songIds: (json['songs'] as List?)?.map((e) => e.toString()).toList() ?? <String>[],
    );
  }
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
