import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  final String message;
  final int status;

  ApiException(this.message, [this.status = 0]);

  @override
  String toString() => message;
}

class LoginResult {
  final String token;
  final String username;
  final String server;

  LoginResult({required this.token, required this.username, required this.server});
}

class LibrarySnapshot {
  final List<String> favorites;
  final List<Playlist> playlists;

  LibrarySnapshot({required this.favorites, required this.playlists});
}

/// 批量操作的回执：改了几首、跳过几首，以及操作后的完整状态。
class BatchResult<T> {
  final T value;
  final int changed;
  final int skipped;

  const BatchResult({
    required this.value,
    this.changed = 0,
    this.skipped = 0,
  });
}

class MusicApi {
  String baseUrl;
  String? token;

  /// 分块下载的块大小，登录后从服务端 setting.json 的 chunk_size 拉取。
  int chunkSize = 262144;

  MusicApi(this.baseUrl, {this.token});

  static String normalize(String input) {
    var value = input.trim();
    if (value.isEmpty) return value;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Uri _uri(String path, [Map<String, String>? query]) {
    final url = Uri.parse('$baseUrl$path');
    if (query == null || query.isEmpty) return url;
    return url.replace(queryParameters: {...url.queryParameters, ...query});
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final uri = _uri(path);
    http.Response response;
    try {
      switch (method) {
        case 'POST':
          response = await http
              .post(uri, headers: _headers, body: jsonEncode(body ?? const {}))
              .timeout(timeout);
          break;
        case 'DELETE':
          response = await http.delete(uri, headers: _headers).timeout(timeout);
          break;
        default:
          response = await http.get(uri, headers: _headers).timeout(timeout);
      }
    } on TimeoutException {
      throw ApiException('连接超时，请检查服务器地址');
    } on SocketException {
      throw ApiException('无法连接服务器，请检查地址与网络');
    } on http.ClientException {
      throw ApiException('网络请求失败，请检查服务器地址');
    } on HandshakeException {
      throw ApiException('证书错误，请确认服务器地址是否正确');
    }
    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    Map<String, dynamic> data = <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) data = decoded;
    } catch (_) {
      // 忽略非 JSON 响应
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return data;
    }
    final message = data['error']?.toString() ?? _statusText(response.statusCode);
    throw ApiException(message, response.statusCode);
  }

  String _statusText(int code) {
    switch (code) {
      case 401:
        return '登录已失效，请重新登录';
      case 403:
        return '没有权限';
      case 404:
        return '资源不存在';
      case 500:
        return '服务器内部错误';
      default:
        return '请求失败（$code）';
    }
  }

  Future<LoginResult> login(
    String username,
    String password, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final data = await _send('POST', '/api/login',
        timeout: timeout,
        body: {
          'username': username,
          'password': password,
        });
    final newToken = data['token']?.toString();
    if (newToken == null || newToken.isEmpty) {
      throw ApiException('服务器返回的登录凭证无效');
    }
    token = newToken;
    return LoginResult(
      token: newToken,
      username: data['username']?.toString() ?? username,
      server: data['server']?.toString() ?? '音乐服务器',
    );
  }

  /// 拉取服务端配置。老版本服务端没有 /api/config，失败就沿用默认块大小。
  Future<void> loadConfig() async {
    _configAt = DateTime.now().millisecondsSinceEpoch;
    try {
      final data = await _send('GET', '/api/config',
          timeout: const Duration(seconds: 8));
      final value = (data['chunk_size'] as num?)?.toInt() ?? 0;
      if (value >= 16384) chunkSize = value.clamp(16384, 8 * 1024 * 1024);
    } catch (_) {
      // 忽略：默认 256KB
    }
  }

  int _configAt = 0;

  /// 后台刷新一次块大小。服务端每次读 setting.json，所以改完文件不用重启；
  /// 这里一分钟内只拉一次，避免每切一首歌都多打一个请求。
  Future<void> refreshConfig() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _configAt < 60000) return;
    await loadConfig();
  }

  Future<List<Song>> fetchSongs() async {
    final data = await _send('GET', '/api/songs');
    final list = (data['songs'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => Song.fromJson(Map<String, dynamic>.from(e)))
        .where((s) => s.id.isNotEmpty)
        .toList();
  }

  Future<LibrarySnapshot> fetchLibrary() async {
    final data = await _send('GET', '/api/library');
    final favorites = (data['favorites'] as List?)?.map((e) => e.toString()).toList() ??
        <String>[];
    final playlists = (data['playlists'] as List?)
            ?.whereType<Map>()
            .map((e) => Playlist.fromJson(Map<String, dynamic>.from(e)))
            .toList() ??
        <Playlist>[];
    return LibrarySnapshot(favorites: favorites, playlists: playlists);
  }

  Future<List<String>> toggleFavorite(String songId) async {
    final data = await _send('POST', '/api/favorites/toggle', body: {'song_id': songId});
    return (data['favorites'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
  }

  /// 上报听歌时长。服务端按 6 秒一个单位累计，遇到没记录的 song_id 自动建条目。
  ///
  /// 调用方已经攒好批量的单位数，这里一次发一批，不逐单位打请求。
  /// 歌曲时长和次数都不上报——次数由榜单页用曲库时长现算。
  Future<void> reportListening(
    String songId, {
    required int units,
    String name = '',
    String artist = '',
  }) async {
    if (units <= 0 || songId.isEmpty) return;
    await _send(
      'POST',
      '/api/listening/report',
      body: {
        'song_id': songId,
        'units': units,
        'name': name,
        'artist': artist,
      },
      timeout: const Duration(seconds: 8),
    );
  }

  Future<ListeningStats> fetchListening() async {
    final data = await _send('GET', '/api/listening');
    return ListeningStats.fromJson(data);
  }

  /// 批量收藏 / 取消收藏。
  ///
  /// 服务端会跳过已经在（或不在）收藏里的歌。老服务端没有这个接口时
  /// 返回 404，这里退回逐首 toggle，结果一样，只是请求多几个。
  Future<BatchResult<List<String>>> setFavorites(
    List<String> songIds, {
    required bool add,
  }) async {
    if (songIds.isEmpty) {
      return BatchResult<List<String>>(value: <String>[]);
    }
    try {
      final data = await _send(
        'POST',
        '/api/favorites/batch',
        body: {'song_ids': songIds, 'action': add ? 'add' : 'remove'},
        timeout: const Duration(seconds: 30),
      );
      return BatchResult<List<String>>(
        value: _parseIds(data['favorites']),
        changed: (data['changed'] as num?)?.toInt() ?? songIds.length,
        skipped: (data['skipped'] as num?)?.toInt() ?? 0,
      );
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
      var favorites = <String>[];
      for (final id in songIds) {
        favorites = await toggleFavorite(id);
      }
      return BatchResult<List<String>>(
        value: favorites,
        changed: songIds.length,
      );
    }
  }

  /// 批量加入歌单，已在歌单里的自动跳过。
  Future<BatchResult<List<Playlist>>> addSongsToPlaylist(
    String playlistId,
    List<String> songIds,
  ) async {
    if (songIds.isEmpty) {
      return const BatchResult<List<Playlist>>(value: <Playlist>[]);
    }
    try {
      final data = await _send(
        'POST',
        '/api/playlists/$playlistId/songs/batch',
        body: {'song_ids': songIds},
        timeout: const Duration(seconds: 30),
      );
      return BatchResult<List<Playlist>>(
        value: _parsePlaylists(data['playlists']),
        changed: (data['changed'] as num?)?.toInt() ?? songIds.length,
        skipped: (data['skipped'] as num?)?.toInt() ?? 0,
      );
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
      var playlists = <Playlist>[];
      for (final id in songIds) {
        playlists = await addToPlaylist(playlistId, id);
      }
      return BatchResult<List<Playlist>>(
        value: playlists,
        changed: songIds.length,
      );
    }
  }

  /// 批量从歌单移除，不在歌单里的自动跳过。
  Future<BatchResult<List<Playlist>>> removeSongsFromPlaylist(
    String playlistId,
    List<String> songIds,
  ) async {
    if (songIds.isEmpty) {
      return const BatchResult<List<Playlist>>(value: <Playlist>[]);
    }
    try {
      final data = await _send(
        'POST',
        '/api/playlists/$playlistId/songs/remove',
        body: {'song_ids': songIds},
        timeout: const Duration(seconds: 30),
      );
      return BatchResult<List<Playlist>>(
        value: _parsePlaylists(data['playlists']),
        changed: (data['changed'] as num?)?.toInt() ?? songIds.length,
        skipped: (data['skipped'] as num?)?.toInt() ?? 0,
      );
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
      var playlists = <Playlist>[];
      for (final id in songIds) {
        playlists = await removeFromPlaylist(playlistId, id);
      }
      return BatchResult<List<Playlist>>(
        value: playlists,
        changed: songIds.length,
      );
    }
  }

  List<String> _parseIds(dynamic raw) =>
      (raw as List?)?.map((e) => e.toString()).toList() ?? <String>[];

  Future<List<String>> reorderFavorites(List<String> songIds) async {
    final data = await _send('POST', '/api/favorites/order', body: {'songs': songIds});
    return (data['favorites'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
  }

  Future<List<Playlist>> reorderPlaylist(
      String playlistId, List<String> songIds) async {
    final data = await _send('POST', '/api/playlists/$playlistId/order',
        body: {'songs': songIds});
    return _parsePlaylists(data['playlists']);
  }

  Future<List<Playlist>> createPlaylist(String name) async {
    final data = await _send('POST', '/api/playlists', body: {'name': name});
    return _parsePlaylists(data['playlists']);
  }

  Future<List<Playlist>> deletePlaylist(String playlistId) async {
    final data = await _send('DELETE', '/api/playlists/$playlistId');
    return _parsePlaylists(data['playlists']);
  }

  Future<List<Playlist>> addToPlaylist(String playlistId, String songId) async {
    final data = await _send('POST', '/api/playlists/$playlistId/songs', body: {'song_id': songId});
    return _parsePlaylists(data['playlists']);
  }

  Future<List<Playlist>> removeFromPlaylist(String playlistId, String songId) async {
    final data = await _send('DELETE', '/api/playlists/$playlistId/songs/$songId');
    return _parsePlaylists(data['playlists']);
  }

  List<Playlist> _parsePlaylists(dynamic raw) {
    final list = (raw as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => Playlist.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<String?> fetchLyric(String songId) async {
    try {
      final response = await http
          .get(_uri('/api/lrc/$songId${_tokenQuery()}'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return utf8.decode(response.bodyBytes, allowMalformed: true);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String _tokenQuery() {
    if (token == null) return '';
    return '?token=${Uri.encodeQueryComponent(token!)}';
  }

  String streamUrl(String songId) => '$baseUrl/api/stream/$songId${_tokenQuery()}';

  String coverUrl(String songId) => '$baseUrl/api/cover/$songId${_tokenQuery()}';
}
