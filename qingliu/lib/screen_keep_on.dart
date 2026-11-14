import 'package:flutter/services.dart';

/// 播放页（歌词界面）保持屏幕常亮。
///
/// 走原生窗口标志 `FLAG_KEEP_SCREEN_ON`（Kotlin 侧 `MainActivity.kt`），
/// 不加依赖、不要权限：只影响当前窗口，切到后台或退出应用自动失效。
///
/// 页面可能叠着开（列表里点一首、再从通知栏点进来），用计数让叠加的页面
/// 只算一次；最后一个页面关掉时才恢复系统息屏。
class ScreenKeepOn {
  static const MethodChannel _channel = MethodChannel('qingliu/screen');

  static int _holders = 0;

  static Future<void> acquire() async {
    _holders++;
    if (_holders != 1) return;
    try {
      await _channel.invokeMethod('keepOn', {'on': true});
    } catch (_) {
      // 通道不可用（非 Android / 引擎未就绪）就别常亮了，不影响播放
    }
  }

  static Future<void> release() async {
    if (_holders == 0) return;
    _holders--;
    if (_holders > 0) return;
    try {
      await _channel.invokeMethod('keepOn', {'on': false});
    } catch (_) {}
  }
}
