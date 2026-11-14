package com.yiyiwang12.qingyunmusic

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MediaPlayback.attach(
            applicationContext,
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qingliu/media")
        )
        // 播放页（歌词界面）保持屏幕常亮。
        // 只加窗口标志：窗口不可见或进程退出时自动失效，不用额外权限。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qingliu/screen")
            .setMethodCallHandler { call, result ->
                if (call.method != "keepOn") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val on = call.argument<Boolean>("on") ?: false
                if (on) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
    }
}
