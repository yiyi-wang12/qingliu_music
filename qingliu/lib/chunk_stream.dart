import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'models.dart';

/// 本机回环分块代理。
///
/// 播放器不再直连服务器，而是连 127.0.0.1 上的这个小服务。每路请求里按
/// [MusicApi.chunkSize]（服务端 setting.json 的 chunk_size，登录后经
/// /api/config 拉到）一块一块地拉：
///
///   拉第 0 块 → 交给播放器 → 拉第 1 块 → 交给播放器 → …
///
/// 下一块的请求在「把当前块交给播放器」之前就已经发出，所以播放器播当前块
/// 的时候下一块在路上，块与块之间没有请求往返的空档。
///
/// 节奏靠 `response.flush()` 控：播放器不取数据，socket 就堵着，flush 不返回，
/// 也就不会去拉下一块 —— 内存里最多压两块，不会把整首歌读进 RAM。
class ChunkStreamServer {
  ChunkStreamServer(this._api);

  final MusicApi? Function() _api;

  HttpServer? _server;
  Future<void>? _starting;
  final Map<String, Song> _songs = {};

  /// 起服务，幂等。起不来（端口/权限问题）返回 false，调用方退回直连服务器。
  Future<bool> ensureStarted() async {
    if (_server != null) return true;
    final pending = _starting ??= _start();
    try {
      await pending;
    } catch (_) {}
    if (identical(_starting, pending)) _starting = null;
    return _server != null;
  }

  Future<void> _start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_handle, onError: (Object _) {});
      _server = server;
    } catch (_) {
      _server = null;
    }
  }

  /// 给一首歌拿本机播放地址；拿不到（服务没起 / 大小未知）返回 null。
  String? urlFor(Song song) {
    final server = _server;
    if (server == null || song.id.isEmpty || song.size <= 0) return null;
    // 只留最近几首的元数据，切歌多了不留垃圾
    if (_songs.length > 8) _songs.clear();
    _songs[song.id] = song;
    return 'http://127.0.0.1:${server.port}/s/${song.id}';
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } catch (_) {}
  }

  // ---------------- 内部实现 ----------------

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final api = _api();
      final id = request.uri.pathSegments.length >= 2
          ? request.uri.pathSegments[1]
          : '';
      final song = _songs[id];
      if (api == null || api.token == null || song == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final total = song.size;
      var from = 0;
      var toEx = total; // 结束位置，不含
      var ranged = false;
      final header = request.headers.value(HttpHeaders.rangeHeader);
      final match = header == null
          ? null
          : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(header);
      if (match != null) {
        final g1 = match.group(1) ?? '';
        final g2 = match.group(2) ?? '';
        if (g1.isEmpty && g2.isNotEmpty) {
          // bytes=-N：最后 N 个字节
          from = max(0, total - (int.tryParse(g2) ?? 0));
        } else if (g1.isNotEmpty) {
          from = int.tryParse(g1) ?? 0;
          if (g2.isNotEmpty) toEx = min((int.tryParse(g2) ?? total - 1) + 1, total);
        }
        from = from.clamp(0, total - 1);
        toEx = toEx.clamp(from + 1, total);
        ranged = true;
      }

      response.headers.contentType = ContentType.parse(_mime(song.ext));
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.statusCode = ranged ? HttpStatus.partialContent : HttpStatus.ok;
      if (ranged) {
        response.headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $from-${toEx - 1}/$total');
      }
      response.contentLength = toEx - from;

      final client = http.Client();
      var offset = from;
      Future<Uint8List>? pending;
      try {
        while (offset < toEx) {
          pending ??= _fetch(client, api, song, offset, toEx);
          final data = await pending;
          pending = null;
          if (data.isEmpty) break;
          final next = offset + data.length;
          // 关键一步：先把下一块请求发出去，再把当前块交给播放器
          if (next < toEx) pending = _fetch(client, api, song, next, toEx);
          response.add(data);
          // 等 socket 真正收下。播放器不读，这里就停着，不会继续拉
          await response.flush();
          offset = next;
        }
      } catch (_) {
        // 播放器断开 / 上游失败：收尾，让播放器自己处理短响应
      } finally {
        pending?.ignore();
        client.close();
      }
    } catch (_) {
      // 响应头阶段出错
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  /// 拉一块：从 [from] 起最多 [MusicApi.chunkSize] 字节，最多重试 3 次。
  Future<Uint8List> _fetch(
    http.Client client,
    MusicApi api,
    Song song,
    int from,
    int toEx,
  ) async {
    final step = api.chunkSize <= 0 ? 262144 : api.chunkSize;
    final want = min(step, toEx - from);
    final to = from + want - 1;
    Object error = const HttpException('分块请求失败');
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final request = http.Request('GET', Uri.parse(api.streamUrl(song.id)))
          ..headers['Range'] = 'bytes=$from-$to';
        final response =
            await client.send(request).timeout(const Duration(seconds: 20));
        if (response.statusCode == 200 && from > 0) {
          throw const HttpException('服务端不支持 Range');
        }
        if (response.statusCode != 206 && response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode}');
        }
        final bytes =
            await response.stream.toBytes().timeout(const Duration(seconds: 30));
        if (bytes.isEmpty) throw const HttpException('空块');
        return bytes.length > want
            ? Uint8List.sublistView(bytes, 0, want)
            : bytes;
      } catch (e) {
        error = e;
        if (attempt >= 2) break;
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
    throw error;
  }

  String _mime(String ext) {
    switch (ext.toLowerCase()) {
      case 'mp3':
        return 'audio/mpeg';
      case 'flac':
        return 'audio/flac';
      case 'm4a':
      case 'm4b':
      case 'alac':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'wav':
        return 'audio/wav';
      case 'wma':
        return 'audio/x-ms-wma';
      case 'ape':
        return 'audio/x-ape';
      case 'aiff':
      case 'aif':
        return 'audio/aiff';
      default:
        return 'application/octet-stream';
    }
  }
}
