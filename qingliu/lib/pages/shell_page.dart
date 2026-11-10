import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../player_controller.dart';
import '../widgets/liquid_glass.dart';
import '../widgets/mini_player.dart';
import 'home_page.dart';
import 'mine_page.dart';
import 'settings_page.dart';

class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int _index = 0;

  static const List<Widget> _pages = [
    HomePage(),
    MinePage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = context.watch<PlayerController>();
    final glass = app.glassEffect;
    final theme = Theme.of(context);

    final body = IndexedStack(index: _index, children: _pages);

    if (!glass) {
      return Scaffold(
        body: body,
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (index) => setState(() => _index = index),
              height: 62,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '首页',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: '我的',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '设置',
                ),
              ],
            ),
          ],
        ),
      );
    }

    return GlassPage(
      enabled: true,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // 让列表从悬浮玻璃栏底下滚过去，模糊才有内容可糊
        extendBody: true,
        body: body,
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, kGlassBarGap),
            child: LiquidGlass(
              radius: 26,
              blur: 2.5,
              interactive: true,
              frost: 1.05,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (player.current != null) ...[
                    const MiniPlayer(glass: true),
                    Divider(
                      height: 0.5,
                      thickness: 0.5,
                      indent: 16,
                      endIndent: 16,
                      color: theme.dividerColor.withAlpha(70),
                    ),
                  ],
                  SizedBox(
                    height: kGlassNavHeight,
                    child: Row(
                      children: [
                        _navItem(0, Icons.home_outlined, Icons.home, '首页'),
                        _navItem(1, Icons.person_outline, Icons.person, '我的'),
                        _navItem(2, Icons.settings_outlined, Icons.settings, '设置'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _navItem(
    int index,
    IconData icon,
    IconData activeIcon,
    String label,
  ) {
    final theme = Theme.of(context);
    final selected = index == _index;
    final color =
        selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;

    return Expanded(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => _index = index),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(selected ? activeIcon : icon, size: 23, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  height: 1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
