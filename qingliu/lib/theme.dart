import 'package:flutter/material.dart';

/// 主题种子色派生出来的「玻璃底」配色。
///
/// 单独拉一套的原因：`ColorScheme.fromSeed` 会把 surface 系列统一映射到
/// 中性色，换种子色基本只影响 primary —— 导航选中的图标、几个小字。
/// 页面 90% 的面积（渐变底、光斑、卡片）纹丝不动，色板里六档深浅
/// 点来点去看着就一模一样。
///
/// 这里让底色和光斑直接从种子色派生：**色相跟着色系走，明度跟着档位走**。
/// 选浅档整页提亮，选深档整页压沉，换色系则连底子一起换。
@immutable
class GlassPalette extends ThemeExtension<GlassPalette> {
  const GlassPalette({
    required this.background,
    required this.glowPrimary,
    required this.glowSecondary,
    required this.glowTertiary,
  });

  /// 页面渐变底的三段颜色。
  final List<Color> background;

  /// 三团主题色光斑，玻璃有东西可折射。
  final Color glowPrimary;
  final Color glowSecondary;
  final Color glowTertiary;

  factory GlassPalette.fromSeed(Color seed, Brightness brightness) {
    final hsl = HSLColor.fromColor(seed);
    final dark = brightness == Brightness.dark;

    // 色板从 0xFFEFBDBD（HSL 明度≈0.84）排到 0xFF701A1A（≈0.27）。
    // 把这段归一到 0（最浅档）→ 1（最深档）。
    final depth = ((0.84 - hsl.lightness) / 0.57).clamp(0.0, 1.0);

    Color tone(double lightness,
        {double hueShift = 0, double satScale = 1}) {
      final h = (hsl.hue + hueShift) % 360;
      final s = (hsl.saturation * satScale).clamp(0.0, 1.0);
      return HSLColor.fromAHSL(1, h, s, lightness.clamp(0.0, 1.0)).toColor();
    }

    if (dark) {
      // 深色模式：档位差要拉开，否则近黑底上完全分辨不出来
      final base = 0.034 + depth * 0.125;
      return GlassPalette(
        background: [
          tone(base, satScale: 0.75),
          tone(base + 0.058, hueShift: 3, satScale: 0.95),
          tone(base - 0.008, hueShift: -4, satScale: 0.7),
        ],
        glowPrimary: tone(0.44 + depth * 0.12, satScale: 1.15),
        glowSecondary: tone(0.34 + depth * 0.10, hueShift: 32, satScale: 1.0),
        glowTertiary: tone(0.30 + depth * 0.08, hueShift: -28, satScale: 0.95),
      );
    }

    // 浅色模式：浅档几乎留白，深档压成带色相的浅灰。
    // 0.968 → 0.851 的跨度肉眼能直接看出来，又不至于把正文压糊。
    final base = 0.968 - depth * 0.117;
    return GlassPalette(
      background: [
        tone(base, satScale: 0.55),
        tone(base - 0.030, hueShift: 3, satScale: 0.72),
        tone(base + 0.006, hueShift: -4, satScale: 0.5),
      ],
      glowPrimary: tone(0.70 - depth * 0.16, satScale: 0.95),
      glowSecondary: tone(0.76 - depth * 0.14, hueShift: 30, satScale: 0.9),
      glowTertiary: tone(0.72 - depth * 0.15, hueShift: -26, satScale: 0.85),
    );
  }

  @override
  GlassPalette copyWith({
    List<Color>? background,
    Color? glowPrimary,
    Color? glowSecondary,
    Color? glowTertiary,
  }) {
    return GlassPalette(
      background: background ?? this.background,
      glowPrimary: glowPrimary ?? this.glowPrimary,
      glowSecondary: glowSecondary ?? this.glowSecondary,
      glowTertiary: glowTertiary ?? this.glowTertiary,
    );
  }

  @override
  GlassPalette lerp(GlassPalette? other, double t) {
    if (other == null) return this;
    return GlassPalette(
      background: [
        for (var i = 0; i < background.length; i++)
          Color.lerp(background[i], other.background[i], t) ?? background[i],
      ],
      glowPrimary: Color.lerp(glowPrimary, other.glowPrimary, t) ?? glowPrimary,
      glowSecondary:
          Color.lerp(glowSecondary, other.glowSecondary, t) ?? glowSecondary,
      glowTertiary:
          Color.lerp(glowTertiary, other.glowTertiary, t) ?? glowTertiary,
    );
  }
}
