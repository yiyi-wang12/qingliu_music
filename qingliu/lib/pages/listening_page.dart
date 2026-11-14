import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_glass.dart';

/// 听歌时长排行榜。
///
/// 顶部是总时长，下面是单曲榜：歌名、听歌时长（分钟）、次数（时长 / 歌曲时长）。
/// 数据全部来自服务端，进页面先把自己攒着的上报单位冲上去再拉一次。
class ListeningPage extends StatefulWidget {
  const ListeningPage({super.key});

  @override
  State<ListeningPage> createState() => _ListeningPageState();
}

class _ListeningPageState extends State<ListeningPage> {
  ListeningStats? _stats;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // initState 里直接 await 会碰到还没建好的 context 树，等第一帧过去再拉
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _stats == null;
      _error = null;
    });
    try {
      final stats = await context.read<AppState>().fetchListening();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final glass = app.glassEffect;
    final stats = _stats;

    return GlassPage(
      enabled: glass,
      child: Scaffold(
        backgroundColor: glass ? Colors.transparent : null,
        extendBodyBehindAppBar: glass,
        appBar: GlassAppBar(
          enabled: glass,
          title: const Text('听歌时长'),
          actions: [
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: _load,
            ),
          ],
        ),
        body: Padding(
          padding: EdgeInsets.only(top: glass ? glassAppBarInset(context) : 0),
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _totalCard(stats, theme),
                const SizedBox(height: 14),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.only(top: 60),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                    ),
                  )
                else if (stats == null || stats.songs.isEmpty)
                  _emptyView(theme)
                else
                  ..._rankList(stats, theme, app),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 总时长卡片，放在榜单最上面。
  Widget _totalCard(ListeningStats? stats, ThemeData theme) {
    final minutes = stats?.totalMinutes ?? 0;
    return GlassCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '听歌总时长',
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                formatMinutes(minutes),
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                  height: 1.1,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '分钟',
                style: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _rankList(ListeningStats stats, ThemeData theme, AppState app) {
    final rows = <Widget>[];
    for (var i = 0; i < stats.songs.length; i++) {
      if (i > 0) rows.add(const SizedBox(height: 8));
      rows.add(_rankRow(i + 1, stats.songs[i], theme, app));
    }
    return rows;
  }

  Widget _rankRow(int rank, ListeningSong song, ThemeData theme, AppState app) {
    final top = rank <= 3;
    // 次数打开页面时现算：时长优先用服务端这次返回的（它按当前曲库现算），
    // 拿不到再退回本地曲库缓存
    final duration = _durationOf(song, app);
    return GlassCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$rank',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: top ? 16 : 14,
                fontWeight: top ? FontWeight.w700 : FontWeight.w500,
                color: top
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
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
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${formatMinutes(song.minutes)} 分钟',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                // 曲库里查不到时长（歌被删了 / 文件头解析不出）就算不了次数
                duration > 0 ? '${formatTimes(song.plays(duration))} 次' : '--',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 这首歌的时长，取不到就返回 0（界面上显示 --）。
  ///
  /// 依次尝试：服务端这次返回的时长 → 本地曲库同 id 的歌 → 同名歌（文件被
  /// 改名或挪目录后 id 会变，老记录就靠这一步还能算出次数）。
  double _durationOf(ListeningSong song, AppState app) {
    if (song.duration > 0) return song.duration;
    final local = app.songById(song.id);
    if (local != null && local.duration > 0) return local.duration;
    for (final s in app.songs) {
      if (s.duration > 0 && s.name == song.name) return s.duration;
    }
    return 0;
  }

  Widget _emptyView(ThemeData theme) {
    final message = _error ?? '还没有听歌记录，去放一首吧。';
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        children: [
          Icon(
            _error == null ? Icons.headphones_outlined : Icons.cloud_off,
            size: 42,
            color: theme.colorScheme.onSurfaceVariant.withAlpha(153),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}
