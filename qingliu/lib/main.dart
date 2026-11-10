import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'cache_service.dart';
import 'pages/login_page.dart';
import 'pages/shell_page.dart';
import 'player_controller.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  app.bootstrap();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<PlayerController>.value(value: app.player),
        ChangeNotifierProvider<CacheService>.value(value: app.cache),
      ],
      child: const MusicApp(),
    ),
  );
}

class MusicApp extends StatelessWidget {
  const MusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final seed = Color(app.themeSeed);
    return MaterialApp(
      title: '清流音乐',
      debugShowCheckedModeBanner: false,
      theme: _theme(seed, Brightness.light, app.glassEffect),
      darkTheme: _theme(seed, Brightness.dark, app.glassEffect),
      themeMode: ThemeMode.system,
      // 边缘继续拖拽时不做整块拉伸。页面底是透明的玻璃渐变，滚动视图
      // 一被拉伸，玻璃卡片背后的采样区域跟着变形，整片看上去就"暗一下"。
      scrollBehavior: const _NoStretchScrollBehavior(),
      home: app.bootstrapping
          ? const _SplashPage()
          : (app.loggedIn ? const ShellPage() : const LoginPage()),
    );
  }

  ThemeData _theme(Color seed, Brightness brightness, bool glass) {
    final light = brightness == Brightness.light;
    final base = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    // ColorScheme.fromSeed 会把种子色统一映射到固定色调（浅色 tone 40、
    // 深色 tone 80），色板里 6 档深浅就会被抹成同一个亮度，点哪一档看着都一样。
    // 这里把主色直接钉在选中的色值上，深浅档才真的反映到界面上。
    final hsl = HSLColor.fromColor(seed);
    final primary = seed;
    final container = hsl
        .withLightness((hsl.lightness + (light ? 0.34 : -0.16)).clamp(0.0, 1.0))
        .toColor();
    final secondary = hsl
        .withSaturation((hsl.saturation * 0.6).clamp(0.0, 1.0))
        .withLightness(light
            ? (hsl.lightness + 0.06).clamp(0.0, 0.68)
            : (hsl.lightness + 0.2).clamp(0.0, 1.0))
        .toColor();
    final scheme = base.copyWith(
      primary: primary,
      onPrimary: _inkOn(primary),
      primaryContainer: container,
      onPrimaryContainer: _inkOn(container),
      secondary: secondary,
      onSecondary: _inkOn(secondary),
      secondaryContainer: container,
      onSecondaryContainer: _inkOn(container),
      tertiary: secondary,
      onTertiary: _inkOn(secondary),
    );

    // 整页底色也跟种子色走：色相随色系，明度随深浅档。
    // 玻璃关掉时就是这一层，开着时它是玻璃下面的渐变底。
    final palette = GlassPalette.fromSeed(seed, brightness);

    return ThemeData(
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[palette],
      scaffoldBackgroundColor: palette.background.first,
      // 系统默认的 Android 转场会把旧页面整体压暗再缩小，进播放页、
      // 进歌单页时看着就是"画面突然一黑"。换成不压暗的淡入位移，
      // 旧页面一直亮着，玻璃底不会被撕开。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      // 三点菜单 / 弹出菜单统一大圆角，玻璃模式下略微透一点
      popupMenuTheme: PopupMenuThemeData(
        color: glass ? scheme.surfaceContainerHigh.withAlpha(238) : scheme.surfaceContainerHigh,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: glass
              ? BorderSide(
                  color: brightness == Brightness.dark
                      ? Colors.white.withAlpha(30)
                      : Colors.white.withAlpha(150),
                )
              : BorderSide.none,
        ),
      ),
    );
  }

  /// 底色浅就用深字，底色深就用白字——浅色档的色块上白字会糊掉。
  Color _inkOn(Color color) =>
      color.computeLuminance() > 0.5 ? const Color(0xFF1B1B1B) : Colors.white;
}

/// 关掉 Android 边缘的拉伸（stretch）回弹指示器。
///
/// 这套界面底下是透明的玻璃渐变，滚动视图被拉伸时，`BackdropFilter`
/// 的采样区域跟着变形、边界被裁掉一圈，整片玻璃就"暗一下"。
/// 下拉刷新用的是 overscroll 通知，不吃这个指示器，所以不受影响。
class _NoStretchScrollBehavior extends MaterialScrollBehavior {
  const _NoStretchScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _SplashPage extends StatelessWidget {
  const _SplashPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, size: 56),
            SizedBox(height: 20),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
          ],
        ),
      ),
    );
  }
}