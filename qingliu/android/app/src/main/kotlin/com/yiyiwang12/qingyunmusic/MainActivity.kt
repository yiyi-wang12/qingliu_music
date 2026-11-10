package com.yiyiwang12.qingyunmusic

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
    }
}
