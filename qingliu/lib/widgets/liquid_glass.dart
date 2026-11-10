import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';

/// 玻璃栏里导航行的高度。
const double kGlassNavHeight = 62;

/// 悬浮玻璃栏距屏幕底部的留白。
const double kGlassBarGap = 10;

/// 迷你播放器在玻璃栏里的高度。
const double kGlassMiniHeight = 60;

/// 弹窗、底部弹层背后那层遮罩。
///
/// 系统默认是 `Colors.black54`，一点下去整屏"唰"地暗一大截，
/// 玻璃主题里显得又重又生硬。这里只留很淡的一层，弹窗靠自身
/// 的玻璃白雾和投影浮起来就够，背后内容还能看清。
const Color kBarrierDim = Color(0x24000000);

/// 列表需要额外留出的底部空间，免得最后一项被悬浮玻璃栏盖住。
double glassBottomInset(
  BuildContext context, {
  required bool enabled,
  required bool playing,
}) {
  if (!enabled) return 0;
  final safe = MediaQuery.of(context).padding.bottom;
  return kGlassNavHeight +
      kGlassBarGap +
      safe +
      (playing ? kGlassMiniHeight : 0) +
      8;
}

/// Liquid Glass。
///
/// 整块玻璃**只有一次背景采样**，这是硬约束：
///
/// 1. **背景** —— 一个 `BackdropFilter` 盖住整块矩形，模糊量全域相同。
///    中间和边缘取的是同一张图、同一个 sigma，物理上不存在"两块的
///    交界"，所以不会再出现撕裂、错位、重影。
/// 2. **白雾** —— 极淡的一层白，只负责让玻璃有体积，不遮背后颜色。
/// 3. **边缘** —— 玻璃的"厚度"全部改成**叠加绘制**：厚度渐变环、内侧
///    亮环、1.2px 高光轮廓。这些层不碰 backdrop，只往画布上叠颜色，
///    形状起点和终点都是渐隐的，因此不会把背后的内容挤歪。
///
/// 以前的写法是边缘切出一圈、单独做一次放大采样的 backdrop，再和中间
/// 那块拼接。两块取样点不同，交界线两侧内容对不上，就是那道撕裂感。
/// 以后不要再往这个组件里加第二个 BackdropFilter。
///
/// 另一条铁律：backdrop 外面不能套会开离屏图层的组件
/// （`ColorFiltered` / `Opacity` / `FadeTransition` / `ShaderMask`），
/// 否则采样到的是空离屏图，中间直接透出一个洞。
class LiquidGlass extends StatefulWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.radius = 22,
    this.blur = 8,
    this.tint,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
    this.shadow = true,
    this.interactive = false,
    this.frost = 1,
    this.refract = true,
  });

  final Widget child;
  final double radius;
  final double blur;
  final Color? tint;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final bool shadow;

  /// 白雾强度。压在深色内容上时调高一点，保证文字看得清。
  final double frost;

  /// 是否做完整的边缘处理。大面板（导航栏、菜单、弹层）用默认的 true；
  /// 卡片传 false，边缘只留淡淡一圈，免得一屏里每块玻璃都顶着一道亮边。
  final bool refract;

  /// 按下时整体轻微收缩，模拟液态玻璃被压。
  final bool interactive;

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final radius = widget.radius;
    final borderRadius = BorderRadius.circular(radius);

    // 背景采样的外扩量。模糊是在 BackdropFilter 自己的 bounds 里算的，
    // 贴着边界那一圈取不到外侧像素、模糊会衰减，边缘就比中间"清楚"。
    // 往外多取一圈，玻璃边界内的模糊才是完整的。
    final bleed = math.max(20.0, widget.blur * 4);

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: widget.shadow
            ? [
                BoxShadow(
                  color: Colors.black.withAlpha(dark ? 104 : 38),
                  blurRadius: 26,
                  spreadRadius: -6,
                  offset: const Offset(0, 12),
                ),
              ]
            : null,
      ),
      // 外层 Stack 只干一件事：把绘制分成"要裁的"和"不裁的"两块。
      //
      // 边缘层必须画在 ClipRRect **外面**。放在里面时，backdrop / 白雾 /
      // 内容 / 边缘这四层各自被裁一次，每层在边界都留一圈抗锯齿的
      // 半透明像素，四层叠在同一像素上 —— 玻璃边缘那 1px 就是这么变脏、
      // 变毛的。挪出来之后，边缘层可以完整覆盖住裁剪的过渡带。
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.passthrough,
        children: [
          ClipRRect(
            borderRadius: borderRadius,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // ---------- 背景：整块只有这一次采样 ----------
                //
                // 中间和边缘取的是同一张 backdrop、同一个 sigma，全域连续，
                // 不存在能撕裂的交界。边缘的厚度/亮边在下面用叠加绘制补，
                // 那些层不碰 backdrop，所以不会把内容挤歪。
                //
                // 采样域比玻璃大一圈（bleed），扩出去的部分由 ClipRRect
                // 裁掉，所以看不出来，但玻璃边界内的模糊是完整的。
                //
                // 这里只能放"裸的" BackdropFilter。外面一旦套上
                // ColorFiltered / Opacity / FadeTransition 这类会开离屏图层
                // 的组件，backdrop 采样到的就是那张空离屏图，模糊出来是
                // 全透明 —— 玻璃中间变成洞。
                Positioned(
                  left: -bleed,
                  top: -bleed,
                  right: -bleed,
                  bottom: -bleed,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: widget.blur,
                      sigmaY: widget.blur,
                      tileMode: TileMode.clamp,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                // ---------- 白雾 ----------
                Positioned.fill(
                  child: CustomPaint(
                    painter: _WashPainter(
                      dark: dark,
                      frost: widget.frost,
                      tint: widget.tint,
                    ),
                  ),
                ),
                // ---------- 内容 ----------
                Padding(
                  padding: widget.padding,
                  child: RepaintBoundary(child: widget.child),
                ),
              ],
            ),
          ),
          // ---------- 边缘：在裁剪层外面 ----------
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _EdgePainter(
                    radius: radius,
                    dark: dark,
                    strength: _pressed ? 1.25 : 1,
                    heavy: widget.refract,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (widget.interactive) {
      surface = Listener(
        behavior: HitTestBehavior.deferToChild,
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.985 : 1,
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeOut,
          child: surface,
        ),
      );
    }

    return Padding(padding: widget.margin, child: surface);
  }
}

/// 白雾：极淡的一层白，只在顶部稍亮一点。浓度高了就退回毛玻璃。
class _WashPainter extends CustomPainter {
  const _WashPainter({
    required this.dark,
    required this.frost,
    required this.tint,
  });

  final bool dark;
  final double frost;
  final Color? tint;

  int _a(num value) => (value * frost).round().clamp(0, 255).toInt();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0.0, 0.38, 1.0],
          colors: dark
              ? [
                  Colors.white.withAlpha(_a(20)),
                  Colors.white.withAlpha(_a(7)),
                  Colors.white.withAlpha(_a(13)),
                ]
              : [
                  Colors.white.withAlpha(_a(9)),
                  Colors.white.withAlpha(_a(2)),
                  Colors.white.withAlpha(_a(5)),
                ],
        ).createShader(rect),
    );

    final t = tint;
    if (t != null) {
      canvas.drawRect(rect, Paint()..color = t.withAlpha(dark ? 16 : 22));
    }
  }

  @override
  bool shouldRepaint(_WashPainter oldDelegate) =>
      oldDelegate.dark != dark ||
      oldDelegate.frost != frost ||
      oldDelegate.tint != tint;
}

/// 边缘的特殊处理。
///
/// 这一层只往画布上叠颜色，**不采样背景** —— 背景已经在
/// [_LiquidGlassState] 里被一次性模糊好了。所以这里画多少层都不可能
/// 把背后的内容挤歪，也就不存在撕裂。
///
/// 结构只有两层，边缘越简单越平滑：
///
/// 1. **内收边** —— 从边界向内几级**同心环**，逐级变淡、环环紧邻无缝，
///    模拟玻璃的厚度。最内一级的 alpha 已经接近 0，环到主体的过渡是
///    连续的，不会出现"旁边一圈和中间是两种颜色"。
/// 2. **外轮廓高光** —— 一圈 1px，上亮下暗，沿圆角连续。
///
/// 三条硬约束，破了就回到锯齿 / 硬边：
///
/// - **不用 `Path.combine`**。Impeller 的路径布尔运算是先把曲线展平成
///   多边形再求交的，差集结果的圆弧部分是折线。2~3px 宽的细环在圆角处
///   就是肉眼可见的台阶 —— 这是"边缘过度不平滑"最直接的原因。
///   同心环用 `PathFillType.evenOdd` + 两次 `addRRect`，曲线全程精确。
/// - **不做 `canvas.clipPath`，也不把描边压在边界上**。描边中心离边界
///   只剩半个笔宽时，外侧那半像素会被裁剪的 anti-alias 再乘一次，
///   线宽剩下不到一半、边缘发毛。现在整条线落在裁剪区内部。
/// - **不用 `MaskFilter.blur`**。高斯模糊会向内外各扩散 1~2px，在低
///   alpha 下就是一圈说不清是亮还是脏的影，反而更毛。
class _EdgePainter extends CustomPainter {
  const _EdgePainter({
    required this.radius,
    required this.dark,
    required this.strength,
    required this.heavy,
  });

  final double radius;
  final bool dark;
  final double strength;

  /// 大面板（导航栏、菜单、弹层）做完整边缘；卡片只要很淡的一圈，
  /// 免得一屏里每张卡片都顶着一道亮边，看着吵。
  final bool heavy;

  int _a(num value) =>
      (value * strength * (heavy ? 1.0 : 0.55)).round().clamp(0, 255).toInt();

  static RRect _rr(Rect rect, double r) =>
      RRect.fromRectAndRadius(rect, Radius.circular(math.max(0, r)));

  /// 同心圆角环。evenOdd 直接做内外两个 RRect 的填充判定，
  /// 不经过任何布尔运算，圆弧保持精确。
  static Path _ring(Rect outer, double outerR, Rect inner, double innerR) => Path()
    ..fillType = PathFillType.evenOdd
    ..addRRect(_rr(outer, outerR))
    ..addRRect(_rr(inner, innerR));

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final r = math.min(radius, size.shortestSide / 2);
    if (size.width < 2 || size.height < 2) return;

    // ---- 1. 内收边 ----
    //
    // 宽度跟控件尺寸走：62px 高的导航栏得到 3.6px 收边，小卡片 2px 出头。
    // 分级而不是一层渐变，是因为环形填充的渐变只能沿矩形斜向走，
    // 环的内边界永远会停在某个非零 alpha 上，形成一道硬边。分级之后
    // 每一级都比上一级淡，最内一级几乎为 0，边界就被"化"掉了。
    //
    // 从 1px 处起算，把最外面那 1px 让给高光轮廓 —— 两者叠在一起会
    // 变成"白线上压了层灰"，棱就不亮了。
    const rim = 1.0;
    final depth = math.min(heavy ? 3.6 : 2.2, size.shortestSide * 0.07);
    final levels = dark ? const [20, 10, 4] : const [7, 3, 1];
    var prev = rect.deflate(rim);
    var prevR = r - rim;
    for (var i = 0; i < levels.length; i++) {
      final d = rim + depth * (i + 1) / levels.length;
      final inner = rect.deflate(d);
      final innerR = r - d;
      final alpha = _a(levels[i]);
      if (alpha > 0 && inner.width > 0.5 && inner.height > 0.5) {
        canvas.drawPath(
          _ring(prev, prevR, inner, innerR),
          Paint()
            ..isAntiAlias = true
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: const [0.0, 0.55, 1.0],
              colors: [
                Colors.black.withAlpha(0),
                Colors.black.withAlpha((alpha * 0.7).round()),
                Colors.black.withAlpha(alpha),
              ],
            ).createShader(rect),
        );
      }
      prev = inner;
      prevR = innerR;
    }

    // ---- 2. 外轮廓高光 ----
    //
    // 中心 0.5px、笔宽 1px → 可见范围 0.0~1.0，正好盖住裁剪层的抗锯齿
    // 过渡带。这一层在 ClipRRect 外面，不会被二次裁剪，笔宽是完整的。
    //
    // 用上下渐变而不是斜向渐变：斜向会让长边的高光在中段就淡掉，
    // 看上去像"线断了一半"。上下渐变能让顶边整条都亮、底边整条回光。
    // 也不单独画顶边/底边的直线段：直线在圆角处会突然断，就是"线段"。
    const lineCenter = 0.5;
    const lineWidth = 1.0;
    final lineRect = rect.deflate(lineCenter);
    if (lineRect.width > 0.5 && lineRect.height > 0.5) {
      canvas.drawRRect(
        _rr(lineRect, r - lineCenter),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lineWidth
          ..isAntiAlias = true
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0.0, 0.22, 0.62, 0.88, 1.0],
            colors: dark
                ? [
                    Colors.white.withAlpha(_a(158)),
                    Colors.white.withAlpha(_a(96)),
                    Colors.white.withAlpha(_a(26)),
                    Colors.white.withAlpha(_a(64)),
                    Colors.white.withAlpha(_a(96)),
                  ]
                : [
                    Colors.white.withAlpha(_a(255)),
                    Colors.white.withAlpha(_a(206)),
                    Colors.white.withAlpha(_a(104)),
                    Colors.white.withAlpha(_a(196)),
                    Colors.white.withAlpha(_a(226)),
                  ],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_EdgePainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.dark != dark ||
      oldDelegate.strength != strength ||
      oldDelegate.heavy != heavy;
}

/// 玻璃文字。
///
/// 四层叠出来：落影 → 主体 → 顶面反光 → 描边。
class GlassText extends StatelessWidget {
  const GlassText({
    super.key,
    required this.text,
    required this.style,
    this.parts,
    this.alpha = 255,
    this.strokeColor,
    this.textAlign = TextAlign.center,
    this.maxLines,
    this.strength = 1,
  });

  /// 纯文本，用来画落影和描边。
  final String text;
  final TextStyle style;

  /// 分段样式。各段只允许颜色（其实是 alpha）不同，
  /// 字号、字重、行高必须与 [style] 一致，否则各层会对不齐。
  final List<TextSpan>? parts;

  /// 没有 [parts] 时主体文字的浓度。
  final int alpha;

  /// 描边色，不传就按明暗主题自动选。
  final Color? strokeColor;

  final TextAlign textAlign;
  final int? maxLines;

  /// 玻璃浓度，0.4 以下会自动省掉顶面反光那层。
  final double strength;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final s = strength.clamp(0.0, 1.0);
    int a(int v) => (v * s).round().clamp(0, 255).toInt();

    // 深色底上是发光的白玻璃，浅色底上反过来做墨玻璃：
    // 字用深色保证可读，玻璃感交给上半段那道反光和落影。
    // 浅色模式的描边必须细而淡——白色粗描边在小字号上会把笔画整个吃掉。
    final fill = dark ? Colors.white : theme.colorScheme.onSurface;
    final stroke = strokeColor ??
        (dark
            ? Colors.white.withAlpha(a(124))
            : theme.colorScheme.onSurface.withAlpha(a(64)));
    final strokeWidth = dark ? 0.9 : 0.6;

    Widget layer(InlineSpan span, TextStyle st) => Text.rich(
          span,
          style: st,
          textAlign: textAlign,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
        );

    return Stack(
      alignment: Alignment.center,
      children: [
        // 落影：把字从背景上抬起来
        Transform.translate(
          offset: const Offset(0, 2),
          child: layer(
            TextSpan(text: text),
            style.copyWith(
              color: Colors.black.withAlpha(dark ? a(120) : a(34)),
            ),
          ),
        ),
        // 主体
        parts != null
            ? layer(TextSpan(children: parts), style)
            : layer(
                TextSpan(text: text),
                style.copyWith(color: fill.withAlpha(alpha)),
              ),
        // 顶面反光：裁上半段，贴一层亮色，玻璃的"面"就在这一层
        if (s >= 0.6 && parts == null)
          ClipRect(
            clipper: const _BandClipperRect(0.0, 0.46),
            child: layer(
              TextSpan(text: text),
              style.copyWith(
                color: Colors.white.withAlpha(dark ? a(74) : a(46)),
              ),
            ),
          ),
        // 描边：勾勒字形轮廓
        layer(
          TextSpan(text: text),
          style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..color = stroke,
          ),
        ),
      ],
    );
  }
}

/// 只保留文字上半段或某一段的裁剪框。
class _BandClipperRect extends CustomClipper<Rect> {
  const _BandClipperRect(this.from, this.to);

  final double from;
  final double to;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
        0,
        size.height * from,
        size.width,
        size.height * to,
      );

  @override
  bool shouldReclip(_BandClipperRect oldClipper) =>
      oldClipper.from != from || oldClipper.to != to;
}

/// 玻璃底：一层柔和渐变 + 几团主题色光斑，玻璃才有东西可以折射。
///
/// 渐变和光斑都来自 [GlassPalette]（由主题种子色派生），换色系连底子一起换，
/// 同一色系里选浅档整页提亮、选深档整页压沉——不这么走，六档深浅看着全一样。
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final palette = theme.extension<GlassPalette>() ??
        GlassPalette.fromSeed(theme.colorScheme.primary, theme.brightness);

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: palette.background,
            ),
          ),
        ),
        Positioned(
          top: -120,
          right: -70,
          child: _Blob(
            size: 420,
            color: palette.glowPrimary.withAlpha(dark ? 150 : 210),
          ),
        ),
        Positioned(
          top: 180,
          left: -120,
          child: _Blob(
            size: 380,
            color: palette.glowSecondary.withAlpha(dark ? 118 : 188),
          ),
        ),
        Positioned(
          bottom: -70,
          right: -20,
          child: _Blob(
            size: 400,
            color: palette.glowTertiary.withAlpha(dark ? 104 : 172),
          ),
        ),
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withAlpha(0)],
          ),
        ),
      ),
    );
  }
}

/// 页面外壳：玻璃开启时在背后铺一层渐变底，页面本身用透明背景浮上去。
class GlassPage extends StatelessWidget {
  const GlassPage({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Stack(
      fit: StackFit.expand,
      children: [const GlassBackground(), child],
    );
  }
}

/// 玻璃标题栏。内容从它底下滚过去，模糊的是真实内容而不是纯色。
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({
    super.key,
    required this.enabled,
    required this.title,
    this.actions,
    this.leading,
    this.bottom,
  });

  final bool enabled;
  final Widget title;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize => Size.fromHeight(
        kToolbarHeight + (bottom?.preferredSize.height ?? 0),
      );

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return AppBar(
        title: title,
        actions: actions,
        leading: leading,
        bottom: bottom,
      );
    }

    final glass = LiquidGlass(
      radius: 0,
      blur: 3,
      shadow: false,
      frost: 0.8,
      child: const SizedBox.expand(),
    );

    return AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      title: title,
      actions: actions,
      leading: leading,
      bottom: bottom,
      flexibleSpace: glass,
    );
  }
}

/// 内容从玻璃标题栏底下滚过去时需要的顶部留白。
double glassAppBarInset(BuildContext context) =>
    kToolbarHeight + MediaQuery.paddingOf(context).top;

/// 玻璃卡片：设置页、我的页里的分组容器。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 16),
    this.radius = 18,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final glass = context.watch<AppState>().glassEffect;
    final theme = Theme.of(context);
    if (!glass) {
      return Container(
        padding: padding,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      );
    }
    // 卡片也吃一点主题色：全白雾的话，色板里换深浅只有页底那点缝隙变了，
    // 卡片铺满一屏时几乎看不出来。
    return LiquidGlass(
      radius: radius,
      blur: 1.5,
      refract: false,
      tint: theme.colorScheme.primary,
      padding: padding,
      child: child,
    );
  }
}

/// 玻璃菜单的一项。
class GlassMenuEntry<T> {
  const GlassMenuEntry({
    required this.value,
    required this.label,
    this.icon,
    this.danger = false,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool danger;
}

/// 玻璃弹出菜单。
///
/// 系统的 [PopupMenuButton] 是纯色 Material，做不了模糊。这里用
/// [showGeneralDialog] + 透明遮罩自己摆位置：遮罩透明，菜单背后的
/// 页面内容才会被 `BackdropFilter` 采到，才真的是玻璃。
Future<T?> showGlassMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<GlassMenuEntry<T>> entries,
}) {
  final glass = context.read<AppState>().glassEffect;
  final box = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final screen = box?.size ?? MediaQuery.sizeOf(context);

  const itemHeight = 46.0;
  const padV = 6.0;
  const menuWidth = 184.0;
  final menuHeight = entries.length * itemHeight + padV * 2;

  var left = globalPosition.dx - 12;
  var top = globalPosition.dy;
  if (left + menuWidth > screen.width - 10) {
    left = screen.width - menuWidth - 10;
  }
  if (left < 10) left = 10;
  if (top + menuHeight > screen.height - 24) {
    top = globalPosition.dy - menuHeight - 52;
  }
  if (top < MediaQuery.paddingOf(context).top + 8) {
    top = MediaQuery.paddingOf(context).top + 8;
  }

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '菜单',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    transitionBuilder: (dialogContext, animation, _, __) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final theme = Theme.of(dialogContext);

      Widget menu = Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in entries)
              InkWell(
                onTap: () => Navigator.of(dialogContext).pop(entry.value),
                child: SizedBox(
                  height: itemHeight,
                  child: Row(
                    children: [
                      const SizedBox(width: 16),
                      if (entry.icon != null) ...[
                        Icon(
                          entry.icon,
                          size: 19,
                          color: entry.danger
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                      ],
                      Text(
                        entry.label,
                        style: TextStyle(
                          fontSize: 14,
                          color: entry.danger
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );

      if (glass) {
        menu = LiquidGlass(
          radius: 18,
          blur: 3,
          frost: 1.1,
          padding: const EdgeInsets.symmetric(vertical: padV),
          child: menu,
        );
      } else {
        menu = Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18),
          ),
          padding: const EdgeInsets.symmetric(vertical: padV),
          child: menu,
        );
      }

      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: menuWidth,
            child: FadeTransition(
              opacity: curve,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.9, end: 1).animate(curve),
                alignment: Alignment.topLeft,
                child: menu,
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// 玻璃确认框。玻璃关闭时退回系统默认的 AlertDialog。
class GlassAlertDialog extends StatelessWidget {
  const GlassAlertDialog({
    super.key,
    required this.title,
    this.content,
    required this.actions,
  });

  final String title;
  final Widget? content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final glass = context.watch<AppState>().glassEffect;
    if (!glass) {
      return AlertDialog(
        title: Text(title),
        content: content,
        actions: actions,
      );
    }

    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: LiquidGlass(
        radius: 28,
        blur: 3,
        frost: 1.2,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              if (content != null) ...[
                const SizedBox(height: 12),
                DefaultTextStyle.merge(
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  child: content!,
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final action in actions)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: action,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
