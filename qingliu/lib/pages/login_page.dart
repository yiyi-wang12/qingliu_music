import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _server;
  late final TextEditingController _user;
  late final TextEditingController _pwd;

  bool _loading = false;
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

  Future<void> _submit() async {
    if (_loading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await context.read<AppState>().login(
            _server.text,
            _user.text.trim(),
            _pwd.text,
          );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(Icons.graphic_eq,
                        color: Colors.white, size: 34),
                  ),
                  const SizedBox(height: 20),
                  Text('清流音乐', style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
                  const SizedBox(height: 6),
                  Text(
                    '连接你的音乐服务器',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _server,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    decoration:
                        _decoration('服务器地址', null, Icons.dns_outlined),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _user,
                    textInputAction: TextInputAction.next,
                    decoration: _decoration('用户名', '用户名', Icons.person_outline),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _pwd,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: _decoration('密码', '密码', Icons.lock_outline)
                        .copyWith(
                      suffixIcon: IconButton(
                        icon: Icon(_obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              size: 18, color: theme.colorScheme.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 50,
                    child: FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.2, color: Colors.white),
                            )
                          : const Text('登录'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Divider(
                    height: 1,
                    thickness: 0.6,
                    color: theme.dividerColor.withAlpha(64),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '本软件仅提供本地音乐文件的播放功能，不提供、不内置、不分发任何音乐及歌词内容。\n'
                    '曲库由用户自行导入，请确保其来源合法并拥有相应使用权。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      height: 1.7,
                      color: theme.colorScheme.onSurfaceVariant.withAlpha(150),
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

  InputDecoration _decoration(String label, String? hint, IconData icon) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, size: 20),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
    );
  }
}
