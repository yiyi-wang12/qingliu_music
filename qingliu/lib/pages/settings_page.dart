import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../cache_service.dart';
import '../models.dart';
import '../player_controller.dart';
import '../widgets/liquid_glass.dart';
import '../widgets/song_tile.dart';
import 'cache_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _server;
  late final TextEditingController _user;
  late final TextEditingController _pwd;

  bool _saving = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _server = TextEditingController(text: app.serverUrl);
    _user = TextEditingController(text: app.username);
    _pwd = TextEditingController(text: app.password);
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pwd.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<AppState>().updateAccount(
            _server.text,
            _user.text.trim(),
            _pwd.text,
          );
      if (mounted) showSnack(context, '已保存，重新登录成功');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: kBarrierDim,
      builder: (dialogContext) => GlassAlertDialog(
        title: '退出登录',
        content: const Text('退出后需要重新输入服务器、用户名和密码。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<AppState>().logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final cache = context.watch<CacheService>();
    final theme = Theme.of(context);
    final glass = app.glassEffect;
    final bottomInset = glassBottomInset(
      context,
      enabled: glass,
      playing: context.watch<PlayerController>().current != null,
    );

    return Scaffold(
      backgroundColor: glass ? Colors.transparent : null,
      extendBodyBehindAppBar: glass,
      appBar: GlassAppBar(
        enabled: glass,
        title: const Text('设置', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          glass ? glassAppBarInset(context) + 6 : 4,
          16,
          32 + bottomInset,
        ),
        children: [
          _card(
            context,
            title: '服务器与账号',
            child: Column(
              children: [
                TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: '192.168.1.10:8080',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _user,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pwd,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: '密码',
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('保存并重新登录'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            title: '主题颜色',
            child: Column(
              children: [
                for (final entry in AppState.themeGroups.entries)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: entry.key == AppState.themeGroups.keys.last
                          ? 0
                          : 12,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 18,
                          child: Text(
                            entry.key,
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              for (final seed in entry.value) _swatch(app, seed),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            title: '外观',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('玻璃效果', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                '底部导航、搜索栏、歌词与二级页面使用 Liquid Glass 半透明模糊',
                style: TextStyle(fontSize: 12),
              ),
              value: app.glassEffect,
              onChanged: (value) => app.setGlassEffect(value),
            ),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            title: '歌词',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('字号', style: TextStyle(fontSize: 13)),
                    const Spacer(),
                    Text(
                      app.lyricFontSize.round().toString(),
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: app.lyricFontSize.clamp(14.0, 36.0).toDouble(),
                  min: 14,
                  max: 36,
                  divisions: 11,
                  onChanged: (value) => app.setLyricFontSize(value),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withAlpha(15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '歌词预览',
                    style: TextStyle(
                      fontSize: app.lyricFontSize,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            title: '播放设置',
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动连播', style: TextStyle(fontSize: 14)),
                  subtitle: const Text('一首结束后自动播放下一首',
                      style: TextStyle(fontSize: 12)),
                  value: app.autoNext,
                  onChanged: (value) => app.setAutoNext(value),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '播放模式',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                        child: _modeChip(app, 'list', '列表循环', Icons.repeat)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: _modeChip(app, 'one', '单曲循环', Icons.repeat_one)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: _modeChip(app, 'shuffle', '随机播放', Icons.shuffle)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            title: '缓存',
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title:
                      const Text('播放时自动缓存', style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                    '一开播就顺手把整首存到本机，播放缓冲吃紧时下载自动让路',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: app.autoCache,
                  onChanged: (value) => app.setAutoCache(value),
                ),
                const SizedBox(height: 4),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.folder_outlined,
                      color: theme.colorScheme.primary),
                  title: const Text('缓存管理', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '已缓存 ${cache.count} 首 · ${formatBytes(cache.totalBytes)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CachePage()),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            title: '关于',
            child: Column(
              children: [
                _infoRow('服务器名称', app.serverName),
                _infoRow('已登录账号', app.username),
                _infoRow('曲库数量', '${app.songs.length} 首'),
                _infoRow('作者', 'yiyi-wang12'),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 46,
            child: OutlinedButton(
              onPressed: _logout,
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error.withAlpha(102)),
              ),
              child: const Text('退出登录'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _swatch(AppState app, int seed) {
    final theme = Theme.of(context);
    final selected = app.themeSeed == seed;
    final color = Color(seed);
    // 浅色块上用深色对勾，否则看不清
    final checkColor =
        color.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;
    return GestureDetector(
      onTap: () => app.setThemeSeed(seed),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? theme.colorScheme.onSurface : Colors.transparent,
            width: 2.4,
          ),
        ),
        child: selected
            ? Icon(Icons.check, size: 19, color: checkColor)
            : null,
      ),
    );
  }

  Widget _modeChip(
    AppState app,
    String value,
    String label,
    IconData icon,
  ) {
    final theme = Theme.of(context);
    final selected = app.playMode == value;
    final base = app.glassEffect
        ? theme.colorScheme.surface.withAlpha(140)
        : theme.colorScheme.surface;
    return InkWell(
      onTap: () => app.setPlayMode(value),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withAlpha(26)
              : base,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.dividerColor.withAlpha(89),
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? theme.colorScheme.primary : null,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? theme.colorScheme.primary : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context,
      {required String title, required Widget child}) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
