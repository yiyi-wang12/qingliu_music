import 'package:flutter/material.dart';

import 'liquid_glass.dart';

/// 离线模式下点了没有本地缓存的歌：提示未连接服务器。
///
/// 只有一个「知道了」，不给重试按钮——重连是全局状态，不是这一首歌的事。
Future<void> showOfflineNotice(BuildContext context, {String? songName}) {
  final name = songName?.trim() ?? '';
  return showDialog<void>(
    context: context,
    barrierColor: kBarrierDim,
    builder: (dialogContext) => GlassAlertDialog(
      title: '未连接服务器',
      content: Text(
        name.isEmpty
            ? '当前处于离线模式，只能播放已经缓存到本地的歌曲。'
            : '「$name」没有本地缓存，连上服务器后再播放。',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
