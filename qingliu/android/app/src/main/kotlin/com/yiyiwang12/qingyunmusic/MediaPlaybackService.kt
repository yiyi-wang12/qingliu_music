package com.yiyiwang12.qingyunmusic

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 只为「播放中不被系统杀掉」而存在的前台服务。
 * 通知内容由 MediaPlayback 维护，这里只负责进入/退出前台。
 */
class MediaPlaybackService : Service() {
    companion object {
        private const val ACTION_DETACH = "com.yiyiwang12.qingyunmusic.action.DETACH"
        private const val ACTION_STOP = "com.yiyiwang12.qingyunmusic.action.STOP_SERVICE"

        fun start(ctx: Context) {
            try {
                val intent = Intent(ctx, MediaPlaybackService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(intent)
                } else {
                    ctx.startService(intent)
                }
            } catch (e: Exception) {
                // 后台启动受限时忽略，播放照常
            }
        }

        fun detach(ctx: Context) {
            try {
                ctx.startService(
                    Intent(ctx, MediaPlaybackService::class.java).setAction(ACTION_DETACH)
                )
            } catch (e: Exception) {
            }
        }

        fun stop(ctx: Context) {
            try {
                ctx.startService(
                    Intent(ctx, MediaPlaybackService::class.java).setAction(ACTION_STOP)
                )
            } catch (e: Exception) {
                try {
                    ctx.stopService(Intent(ctx, MediaPlaybackService::class.java))
                } catch (ignored: Exception) {
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DETACH -> {
                // 暂停：通知留在锁屏，但不再占前台
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_DETACH)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(false)
                }
                try {
                    val manager = getSystemService(Context.NOTIFICATION_SERVICE)
                        as android.app.NotificationManager
                    manager.notify(
                        MediaPlayback.NOTIFICATION_ID,
                        MediaPlayback.buildNotification(this)
                    )
                } catch (e: Exception) {
                }
            }
            ACTION_STOP -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
            }
            else -> {
                try {
                    startForeground(
                        MediaPlayback.NOTIFICATION_ID,
                        MediaPlayback.buildNotification(this)
                    )
                } catch (e: Exception) {
                    stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }
}
