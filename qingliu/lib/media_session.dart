import 'package:flutter/services.dart';

import 'models.dart';

/// 锁屏 / 通知栏 / 小米灵动岛的控制器。
///
/// 走 Android 原生 MediaSession + MediaStyle 通知（Kotlin 侧
/// `MediaPlayback.kt`），不依赖任何插件，也不参与启动流程 ——
/// 初始化只是注册一个 channel handler，不会阻塞 runApp。
class MediaSessionService {
  static const MethodChannel _channel = MethodChannel('qingliu/media');

  VoidCallback? onPrevious;
  VoidCallback? onNext;
  VoidCallback? onToggle;
  VoidCallback? onPlay;
  VoidCallback? onPause;
  VoidCallback? onStop;
  void Function(Duration position)? onSeek;

  DateTime _lastPositionSync = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastArtKey;
  String? _lastTrackKey;

  /// 注册回调。可以在任意时刻调用，多次调用只保留最后一次。
  void init({
    required VoidCallback onPrevious,
    required VoidCallback onNext,
    required VoidCallback onToggle,
    required VoidCallback onPlay,
    required VoidCallback onPause,
    required VoidCallback onStop,
    void Function(Duration position)? onSeek,
  }) {
    this.onPrevious = onPrevious;
    this.onNext = onNext;
    this.onToggle = onToggle;
    this.onPlay = onPlay;
    this.onPause = onPause;
    this.onStop = onStop;
    this.onSeek = onSeek;
    _channel.setMethodCallHandler(_handle);
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method != 'action') return null;
    final args = call.arguments is Map ? call.arguments as Map : const {};
    final action = args['action']?.toString() ?? '';
    switch (action) {
      case 'previous':
        onPrevious?.call();
        break;
      case 'next':
        onNext?.call();
        break;
      case 'toggle':
        onToggle?.call();
        break;
      case 'play':
        onPlay?.call();
        break;
      case 'pause':
        onPause?.call();
        break;
      case 'stop':
        onStop?.call();
        break;
      case 'seek':
        final ms = (args['positionMs'] as num?)?.toInt() ?? 0;
        onSeek?.call(Duration(milliseconds: ms < 0 ? 0 : ms));
        break;
    }
    return null;
  }

  /// 推送当前播放状态。position 每 ~1 秒同步一次即可，
  /// 系统会按 1x 速度自己推算进度。
  Future<void> update({
    required Song song,
    required bool playing,
    required Duration position,
    Duration? duration,
    required bool hasNext,
    required bool hasPrevious,
    String? artPath,
    String? artUrl,
  }) async {
    final now = DateTime.now();
    final key = artPath ?? artUrl ?? '';
    final artChanged = key != _lastArtKey;
    // 换歌 / 播放暂停必须立刻推，否则快速切歌时通知还停在上一次
    final trackKey = '${song.id}|$playing';
    final trackChanged = trackKey != _lastTrackKey;
    final positionDue =
        now.difference(_lastPositionSync).inMilliseconds > 900;
    if (!artChanged && !trackChanged && !positionDue) return;
    _lastArtKey = key;
    _lastTrackKey = trackKey;
    _lastPositionSync = now;

    try {
      await _channel.invokeMethod('update', {
        'id': song.id,
        'title': song.name,
        'artist': song.artist,
        'album': song.album,
        'playing': playing,
        'positionMs': position.inMilliseconds,
        'durationMs': duration?.inMilliseconds ?? 0,
        'hasNext': hasNext,
        'hasPrevious': hasPrevious,
        'artPath': artPath ?? '',
        'artUrl': artUrl ?? '',
      });
    } catch (_) {
      // 通知栏不可用不影响播放
    }
  }

  Future<void> clear() async {
    _lastArtKey = null;
    _lastTrackKey = null;
    try {
      await _channel.invokeMethod('clear');
    } catch (_) {}
  }
}
