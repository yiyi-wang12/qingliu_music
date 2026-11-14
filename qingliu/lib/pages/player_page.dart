import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../cache_service.dart';
import '../models.dart';
import '../player_controller.dart';
import '../screen_keep_on.dart';
import '../widgets/cover_art.dart';
import '../widgets/liquid_glass.dart';
import '../widgets/song_tile.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final ScrollController _scroll = ScrollController();

  List<LyricLine> _lyrics = [];
  String? _lyricSongId;
  bool _loadingLyric = false;
  int _currentLine = -1;
  double? _dragValue;
  double _scrollPad = 0;
  double _scrollFontSize = 0;

  /// 上一次是不是横屏：切换方向后要把当前歌词行重新摆到正中。
  bool? _landscape;

  @override
  void initState() {
    super.initState();
    // 盯着歌词看的时候别让屏幕自己灭
    ScreenKeepOn.acquire();
  }

  @override
  void dispose() {
    ScreenKeepOn.release();
    _scroll.dispose();
    super.dispose();
  }

  double get _lineHeight => context.read<AppState>().lyricFontSize * 2.8;

  void _loadLyric(PlayerController player) {
    final song = player.current;
    if (song == null) return;
    _lyricSongId = song.id;
    _lyrics = [];
    _currentLine = -1;
    _loadingLyric = song.hasLrc;
    if (!song.hasLrc) {
      setState(() {});
      return;
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
    final cached = context.read<CacheService>().lrcFile(song.id);
    if (cached != null) {
      // 按字节读再宽松解码：磁盘上的缓存万一有坏字节，readAsString 会直接
      // 抛异常，歌词就整块不显示了。
      cached.readAsBytes().then((bytes) {
        _applyLyric(song.id, utf8.decode(bytes, allowMalformed: true));
      }).catchError((_) {
        if (player.offline) {
          _applyLyric(song.id, null);
        } else {
          player.api?.fetchLyric(song.id).then((text) => _applyLyric(song.id, text));
        }
      });
      return;
    }
    // 离线又没有本地歌词：不发请求，也不转那个 10 秒的圈
    if (player.offline) {
      _applyLyric(song.id, null);
      return;
    }
    player.api?.fetchLyric(song.id).then((text) => _applyLyric(song.id, text));
  }

  void _applyLyric(String songId, String? text) {
    if (!mounted || _lyricSongId != songId) return;
    setState(() {
      _lyrics = text == null ? <LyricLine>[] : parseLrc(text);
      _loadingLyric = false;
    });
  }

  int _lineIndexAt(Duration position) {
    if (_lyrics.isEmpty) return -1;
    var index = -1;
    for (var i = 0; i < _lyrics.length; i++) {
      if (_lyrics[i].time <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  /// 当前行唱到的比例（0~1）。LRC 只有行时间，按到下一行的时长摊到每个字。
  double _lineProgress(int i, Duration position) {
    final start = _lyrics[i].time;
    final end = i + 1 < _lyrics.length
        ? _lyrics[i + 1].time
        : start + const Duration(seconds: 5);
    final total = end.inMilliseconds - start.inMilliseconds;
    if (total <= 0) return 1;
    final passed = position.inMilliseconds - start.inMilliseconds;
    if (passed <= 0) return 0;
    if (passed >= total) return 1;
    return passed / total;
  }

  /// 当前行。字是唱出来的：整行原地由暗转亮，不位移、不缩放。
  ///
  /// 这块压在玻璃面板上，所以不再叠 GlassText 那四层（落影 / 反光 /
  /// 描边）。玻璃字是给"直接浮在背景上"用的，放在玻璃面板里会糊成一片。
  /// 这里只留一层很淡的落影把字从面板上抬起来。
  Widget _activeLine(
    String text,
    double fontSize,
    double progress,
    ThemeData theme,
  ) {
    final dark = theme.brightness == Brightness.dark;
    final lit = dark ? Colors.white : theme.colorScheme.primary;
    final dim = lit.withAlpha(dark ? 100 : 88);
    final runes = text.runes.toList();
    final count = runes.length;
    final sung =
        count == 0 ? 0 : (progress * count).floor().clamp(0, count).toInt();
    final base = TextStyle(
      fontSize: fontSize,
      height: 1.24,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
      shadows: [
        Shadow(
          color: Colors.black.withAlpha(dark ? 110 : 30),
          blurRadius: 10,
          offset: const Offset(0, 1),
        ),
      ],
    );
    return Text.rich(
      TextSpan(
        children: [
          if (sung > 0)
            TextSpan(
              text: String.fromCharCodes(runes.sublist(0, sung)),
              style: base.copyWith(color: lit),
            ),
          if (sung < count)
            TextSpan(
              text: String.fromCharCodes(runes.sublist(sung)),
              style: base.copyWith(color: dim),
            ),
        ],
      ),
      style: base,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 点歌词：跳到这一句的时间点并继续播放。
  void _tapLine(int i, PlayerController player) {
    if (i < 0 || i >= _lyrics.length) return;
    final time = _lyrics[i].time;
    if (time < Duration.zero) return;
    player.seekAndPlay(time);
    setState(() => _currentLine = i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToLine(i, _scrollPad);
    });
  }

  void _scrollToLine(int index, double topPad) {    if (!_scroll.hasClients || index < 0) return;
    final lineHeight = _lineHeight;
    final viewport = _scroll.position.viewportDimension;
    var offset = topPad + index * lineHeight + lineHeight / 2 - viewport / 2;
    final maxOffset = _scroll.position.maxScrollExtent;
    if (offset < 0) offset = 0;
    if (offset > maxOffset) offset = maxOffset;
    _scroll.animateTo(
      offset,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = context.watch<PlayerController>();
    final song = player.current;

    if (song != null && song.id != _lyricSongId) {
      // 切歌这一帧就把上一首的歌词清掉，别等异步加载回来才换
      _lyricSongId = song.id;
      _lyrics = const <LyricLine>[];
      _currentLine = -1;
      _loadingLyric = song.hasLrc;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadLyric(player);
      });
    }

    if (song == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('当前没有播放的歌曲')),
      );
    }

    final favorite = context.select<AppState, bool>((a) => a.isFavorite(song.id));
    final glass = app.glassEffect;
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;

    // 横竖屏一换视口高度就变了，把当前行重新摆到正中
    if (_landscape != null && _landscape != landscape) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToLine(_currentLine, _scrollPad);
      });
    }
    _landscape = landscape;

    return GlassPage(
      enabled: glass,
      child: Scaffold(
        backgroundColor: glass ? Colors.transparent : null,
        // 横屏高度本来就紧，标题栏省掉，返回键挪进左栏
        appBar: landscape ? null : _appBar(context, app, song, favorite),
        body: SafeArea(
          child: landscape
              ? _buildLandscape(context, app, player, song, favorite)
              : _buildPortrait(context, app, player, song),
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar(
    BuildContext context,
    AppState app,
    Song song,
    bool favorite,
  ) {
    final theme = Theme.of(context);
    final glass = app.glassEffect;
    return AppBar(
      backgroundColor: glass ? Colors.transparent : null,
      scrolledUnderElevation: glass ? 0 : 0.5,
      leading: IconButton(
        icon: const Icon(Icons.keyboard_arrow_down),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: const Text('正在播放', style: TextStyle(fontSize: 15)),
      centerTitle: true,
      actions: [
        IconButton(
          icon: Icon(
            favorite ? Icons.favorite : Icons.favorite_border,
            color: favorite ? theme.colorScheme.primary : null,
          ),
          onPressed: () => app.toggleFavorite(song.id),
        ),
      ],
    );
  }

  /// 竖屏：封面在上，歌词在下。
  Widget _buildPortrait(
    BuildContext context,
    AppState app,
    PlayerController player,
    Song song,
  ) {
    final theme = Theme.of(context);
    return Column(
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: AspectRatio(
            aspectRatio: 1,
            child: CoverArt(song: song, radius: 20, iconSize: 88),
          ),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              Text(
                song.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                song.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _buildLyric(context, app, player),
        ),
        _buildProgress(context, player),
        _buildControls(context, app, player),
        const SizedBox(height: 12),
      ],
    );
  }

  /// 横屏：左半边封面与控制，右半边歌词。
  Widget _buildLandscape(
    BuildContext context,
    AppState app,
    PlayerController player,
    Song song,
    bool favorite,
  ) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 4, 6),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        favorite ? Icons.favorite : Icons.favorite_border,
                        color:
                            favorite ? theme.colorScheme.primary : null,
                      ),
                      onPressed: () => app.toggleFavorite(song.id),
                    ),
                  ],
                ),
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: CoverArt(song: song, radius: 18, iconSize: 64),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  song.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  song.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                _buildProgress(context, player, horizontal: 4, compact: true),
                _buildControls(context, app, player,
                    horizontal: 4, playSize: 54),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 10),
            child: _buildLyric(context, app, player),
          ),
        ),
      ],
    );
  }

  /// 歌词区：整块做成液态玻璃，和底部那个悬浮播放条同一种材质。
  Widget _buildLyric(
      BuildContext context, AppState app, PlayerController player) {
    final theme = Theme.of(context);
    final fontSize = app.lyricFontSize;
    final lineHeight = _lineHeight;

    Widget body;
    if (_loadingLyric) {
      body = const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (_lyrics.isEmpty) {
      body = Center(
        child: Text(
          '暂无歌词',
          style: TextStyle(
            fontSize: fontSize,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    } else {
      if (_scrollFontSize != fontSize) {
        _scrollFontSize = fontSize;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToLine(_currentLine, _scrollPad);
        });
      }
      body = LayoutBuilder(
        builder: (context, constraints) {
          final pad = ((constraints.maxHeight - lineHeight) / 2)
              .clamp(0.0, 100000.0)
              .toDouble();
          _scrollPad = pad;
          return StreamBuilder<Duration>(
            stream: player.positionStream,
            builder: (context, snapshot) {
              final position = snapshot.data ?? Duration.zero;
              final index = _lineIndexAt(position);
              if (index != _currentLine) {
                _currentLine = index;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _scrollToLine(index, pad);
                });
              }
              // 上下两端的歌词淡进淡出，别在面板边界上被硬切一刀。
              return ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00000000),
                    Color(0xFF000000),
                    Color(0xFF000000),
                    Color(0x00000000),
                  ],
                  stops: [0.0, 0.14, 0.84, 1.0],
                ).createShader(rect),
                child: ListView.builder(
                  controller: _scroll,
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.symmetric(vertical: pad),
                  itemExtent: lineHeight,
                  itemCount: _lyrics.length,
                  itemBuilder: (context, i) =>
                      _lyricLine(i, index, position, fontSize, theme, player),
                ),
              );
            },
          );
        },
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: _lyricPanel(context, app, body),
    );
  }

  /// 玻璃壳。参数与底部悬浮栏对齐（同样 26 圆角、同样的白雾强度），
  /// 一屏里的两块玻璃才是同一种材质。
  Widget _lyricPanel(BuildContext context, AppState app, Widget child) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    if (!app.glassEffect) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
        ),
        child: child,
      );
    }
    return LiquidGlass(
      radius: 26,
      blur: 3.5,
      frost: dark ? 0.95 : 1.12,
      tint: theme.colorScheme.primary,
      child: SizedBox.expand(child: child),
    );
  }

  /// 一行歌词。离当前行越远越淡，滚出中心区自然消失。
  Widget _lyricLine(
    int i,
    int index,
    Duration position,
    double fontSize,
    ThemeData theme,
    PlayerController player,
  ) {
    final line = _lyrics[i];
    final selected = i == index;
    final text = line.text.isEmpty ? '♪' : line.text;
    final dark = theme.brightness == Brightness.dark;
    final base = dark ? Colors.white : theme.colorScheme.onSurface;

    final distance = (i - index).abs();
    final int alpha;
    if (distance <= 1) {
      alpha = dark ? 216 : 214;
    } else if (distance == 2) {
      alpha = dark ? 166 : 158;
    } else if (distance == 3) {
      alpha = dark ? 122 : 114;
    } else {
      alpha = dark ? 82 : 74;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _tapLine(i, player),
      child: RepaintBoundary(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: selected
                ? _activeLine(
                    text,
                    fontSize + 2,
                    _lineProgress(i, position),
                    theme,
                  )
                : Text(
                    text,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: fontSize,
                      height: 1.24,
                      fontWeight: FontWeight.w500,
                      color: base.withAlpha(alpha),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgress(
    BuildContext context,
    PlayerController player, {
    double horizontal = 20,
    bool compact = false,
  }) {
    final theme = Theme.of(context);
    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        final maxMs = duration.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final value = _dragValue ??
                (maxMs > 0
                    ? position.inMilliseconds.toDouble().clamp(0.0, maxMs).toDouble()
                    : 0.0);
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontal),
              child: Column(
                children: [
                  SizedBox(
                    height: compact ? 26 : null,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2.5,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 16),
                      ),
                      child: Slider(
                        value: value,
                        max: maxMs > 0 ? maxMs : 1,
                        onChanged: maxMs > 0
                            ? (v) => setState(() => _dragValue = v)
                            : null,
                        onChangeEnd: maxMs > 0
                            ? (v) {
                                player.seek(
                                    Duration(milliseconds: v.round()));
                                setState(() => _dragValue = null);
                              }
                            : null,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          formatDuration(Duration(
                              milliseconds: value.round())),
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          formatDuration(duration),
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildControls(
    BuildContext context,
    AppState app,
    PlayerController player, {
    double horizontal = 24,
    double playSize = 64,
  }) {
    final theme = Theme.of(context);
    final iconSize = playSize * 0.53;
    final smallSize = playSize * 0.34;

    IconData modeIcon;
    String modeLabel;
    switch (app.playMode) {
      case 'one':
        modeIcon = Icons.repeat_one;
        modeLabel = '单曲循环';
        break;
      case 'shuffle':
        modeIcon = Icons.shuffle;
        modeLabel = '随机播放';
        break;
      default:
        modeIcon = Icons.repeat;
        modeLabel = '列表循环';
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontal),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            tooltip: modeLabel,
            icon: Icon(modeIcon, size: smallSize),
            color: theme.colorScheme.primary,
            onPressed: () {
              const order = ['list', 'one', 'shuffle'];
              final next = order[(order.indexOf(app.playMode) + 1) % order.length];
              app.setPlayMode(next);
            },
          ),
          IconButton(
            icon: Icon(Icons.skip_previous, size: iconSize),
            onPressed: () => player.previous(),
          ),
          StreamBuilder<PlayerState>(
            stream: player.playerStateStream,
            builder: (context, snapshot) {
              final state = snapshot.data;
              final loading = state != null &&
                  (state.processingState == ProcessingState.loading ||
                      state.processingState == ProcessingState.buffering);
              return SizedBox(
                width: playSize,
                height: playSize,
                child: Material(
                  color: theme.colorScheme.primary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => player.toggle(),
                    child: Center(
                      child: loading
                          ? SizedBox(
                              width: smallSize,
                              height: smallSize,
                              child: const CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              (state?.playing ?? false)
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              size: iconSize,
                              color: Colors.white,
                            ),
                    ),
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: Icon(Icons.skip_next, size: iconSize),
            onPressed: () => player.next(),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.queue_music, size: smallSize),
            tooltip: '播放列表',
            onSelected: (value) async {
              if (value == 'add') {
                await showAddToPlaylistSheet(context, player.current!);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'add', child: Text('加入歌单')),
              PopupMenuItem(
                value: 'info',
                enabled: false,
                child: Text(
                  '队列 ${player.queue.length} 首 · 第 ${player.index + 1} 首',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
