import 'package:flutter/material.dart';

import '../models.dart';
import '../pages/player_page.dart';
import '../player_controller.dart';

/// 点歌：立即进入全屏播放页。
///
/// 正在放的就是这首 → 只开页面，不碰播放器；
/// 队列没变 → 只切曲目；换了一份列表才重建音源。
void playAndOpen(
  BuildContext context,
  PlayerController player,
  List<Song> songs,
  int index,
) {
  if (songs.isEmpty) return;
  final navigator = Navigator.of(context);
  final start = index.clamp(0, songs.length - 1).toInt();
  // 不 await：音源加载在后台进行，页面先弹出来
  player.playFromList(songs, start);
  navigator.push(
    MaterialPageRoute(builder: (_) => const PlayerPage()),
  );
}
