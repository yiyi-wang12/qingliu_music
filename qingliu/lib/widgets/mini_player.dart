import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../pages/player_page.dart';
import '../player_controller.dart';
import 'cover_art.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, this.glass = false});

  /// 嵌在底部玻璃栏里时不再自带底色与描边。
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final song = player.current;
    if (song == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final surface = Container(
      decoration: glass
          ? null
          : BoxDecoration(
              border: Border(
                top: BorderSide(color: theme.dividerColor.withAlpha(89)),
              ),
            ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StreamBuilder<Duration>(
            stream: player.positionStream,
            builder: (context, snapshot) {
              final position = snapshot.data ?? Duration.zero;
              final total = player.audio.duration ?? Duration.zero;
              final value = total.inMilliseconds > 0
                  ? (position.inMilliseconds / total.inMilliseconds)
                      .clamp(0.0, 1.0)
                      .toDouble()
                  : 0.0;
              return LinearProgressIndicator(
                value: value,
                minHeight: 2,
                backgroundColor: Colors.transparent,
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Row(
              children: [
                CoverArt(song: song, size: 40, radius: 10, iconSize: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        song.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                StreamBuilder<PlayerState>(
                  stream: player.playerStateStream,
                  builder: (context, snapshot) {
                    final state = snapshot.data;
                    final loading = state != null &&
                        (state.processingState == ProcessingState.loading ||
                            state.processingState == ProcessingState.buffering);
                    if (loading) {
                      return const SizedBox(
                        width: 40,
                        height: 40,
                        child: Padding(
                          padding: EdgeInsets.all(11),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    return IconButton(
                      icon: Icon(
                        (state?.playing ?? false)
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                      onPressed: () => player.toggle(),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: () => player.next(),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return Material(
      color: glass ? Colors.transparent : theme.colorScheme.surface,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PlayerPage()),
          );
        },
        child: surface,
      ),
    );
  }
}
