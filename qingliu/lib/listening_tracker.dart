import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'api.dart';
import 'models.dart';
import 'player_controller.dart';

/// 听歌时长统计。
///
/// 服务端按 6 秒一个单位存整数，这里跟着播放位置累计：位置每前进 6 秒
/// 记 1 个单位，攒够 [flushUnits] 个单位上报一次，暂停 / 切歌 / 停止时
/// 立刻把攒下的补齐。进排行榜页前也会主动冲一次，数字不会落后半分钟。
///
/// 用位置流而不是定时器：暂停、后台播放、拖动进度都能分辨出来，
/// 拖进度造成的跳变（位置突然前跳）不计入时长。
class ListeningTracker {
  ListeningTracker({required this.player, required this.apiOf});

  /// 服务端一个单位对应的秒数。
  static const int unitSeconds = 6;

  /// 攒够几个单位上报一次（5 单位 = 30 秒），避免每 6 秒打一次请求。
  static const int flushUnits = 5;

  /// 上报失败时最多往回攒多少单位（600 单位 = 1 小时）。
  /// 离线一整天的数据不该全塞在内存里。
  static const int maxPendingUnits = 600;

  /// 位置一次前进超过这个值就当成拖动进度，不计时长。
  static const int _maxStepMs = 5000;

  final PlayerController player;
  final MusicApi? Function() apiOf;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;

  String? _songId;
  Song? _song;
  Duration? _lastPos;
  int _accMs = 0;
  int _pending = 0;

  /// 上报串成一条链，保证先后顺序，也不会同一批报两次。
  Future<void> _chain = Future<void>.value();

  bool get started => _posSub != null;

  void start() {
    if (started) return;
    _posSub = player.positionStream.listen(_onPosition);
    _stateSub = player.playerStateStream.listen(_onState);
  }

  /// 把当前攒下的单位发出去，返回的 Future 在那批请求结束后完成。
  Future<void> flush() {
    _enqueue();
    return _chain;
  }

  /// 清空计时状态（退出登录用）。
  void reset() {
    _pending = 0;
    _accMs = 0;
    _songId = null;
    _song = null;
    _lastPos = null;
  }

  void dispose() {
    _posSub?.cancel();
    _posSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    reset();
  }

  void _onPosition(Duration pos) {
    final song = player.current;
    if (song == null) {
      // 队列被清空（停止播放）：上一首的零头先报掉
      _enqueue();
      _songId = null;
      _song = null;
      _lastPos = null;
      _accMs = 0;
      return;
    }
    if (song.id != _songId) {
      // 换歌：上一首攒下的先报掉，再从这首歌的当前位置重新起算
      _enqueue();
      _songId = song.id;
      _song = song;
      _lastPos = pos;
      _accMs = 0;
      return;
    }
    _song = song;
    final last = _lastPos;
    _lastPos = pos;
    if (last == null) return;
    if (!player.isPlaying) return;
    final delta = pos - last;
    if (delta <= Duration.zero) return;
    if (delta.inMilliseconds > _maxStepMs) return;
    _accMs += delta.inMilliseconds;
    while (_accMs >= unitSeconds * 1000) {
      _accMs -= unitSeconds * 1000;
      _pending++;
    }
    if (_pending >= flushUnits) _enqueue();
  }

  void _onState(PlayerState state) {
    if (state.playing) return;
    // 暂停 / 播完 / 停止：先把不足一批的单位送出去，界面数字才跟得上
    _enqueue();
    if (player.current == null) {
      _songId = null;
      _song = null;
      _lastPos = null;
      _accMs = 0;
    }
  }

  void _enqueue() {
    final units = _pending;
    final song = _song;
    final client = apiOf();
    // 没有服务端可写（离线 / 未登录）就把这批丢掉：留着会在切歌时
    // 被记到下一首头上，串账比少记更难查。
    if (units <= 0 || song == null || client == null) {
      _pending = 0;
      return;
    }
    _pending = 0;
    _chain = _chain.then((_) async {
      try {
        await client.reportListening(
          song.id,
          units: units,
          name: song.name,
          artist: song.artist,
        );
      } catch (_) {
        // 网络抖一下就补回去，下次连同新单位一起报；攒太多就丢掉一部分。
        // 已经切歌的话不能再补——这批单位会记到下一首头上。
        if (_songId == song.id) {
          _pending += units;
          if (_pending > maxPendingUnits) _pending = maxPendingUnits;
        }
      }
    });
  }
}
