import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../cache_service.dart';
import '../models.dart';
import '../pages/player_page.dart';
import '../player_controller.dart';
import 'offline_notice.dart';

/// 点歌：立即进入全屏播放页。
///
/// 正在放的就是这首 → 只开页面，不碰播放器；
/// 队列没变 → 只切曲目；换了一份列表才重建音源。
/// 离线又没有本地缓存 → 只弹提示，不推页面。
void playAndOpen(
  BuildContext context,
  PlayerController player,
  List<Song> songs,
  int index,
) {
  if (songs.isEmpty) return;
  final start = index.clamp(0, songs.length - 1).toInt();
  final app = context.read<AppState>();
  final cached = context.read<CacheService>().isCached(songs[start].id);
  if (app.offline && !cached) {
    showOfflineNotice(context, songName: songs[start].name);
    return;
  }

  final navigator = Navigator.of(context);
  // 不 await：音源加载在后台进行，页面先弹出来
  player.playFromList(songs, start);
  navigator.push(
    MaterialPageRoute(builder: (_) => const PlayerPage()),
  );
}
