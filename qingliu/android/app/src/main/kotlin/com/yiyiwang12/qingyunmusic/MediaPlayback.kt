package com.yiyiwang12.qingyunmusic

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import kotlin.math.max

/**
 * 锁屏 / 通知栏 / 小米灵动岛的原生媒体会话。
 *
 * 纯 framework API，没有第三方依赖，也不参与应用启动：attach 只注册一个
 * method channel，任何异常都不会拖垮主流程。
 */
object MediaPlayback {
    private const val CHANNEL_ID = "qingliu_playback"
    const val NOTIFICATION_ID = 1101

    private const val EXTRA_PREVIOUS = "com.yiyiwang12.qingyunmusic.action.PREVIOUS"
    private const val EXTRA_TOGGLE = "com.yiyiwang12.qingyunmusic.action.TOGGLE"
    private const val EXTRA_NEXT = "com.yiyiwang12.qingyunmusic.action.NEXT"

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    private var appContext: Context? = null
    private var channel: MethodChannel? = null
    private var session: MediaSession? = null
    private var receiver: BroadcastReceiver? = null

    private var songId: String = ""
    private var title: String = ""
    private var artist: String = ""
    private var album: String = ""
    private var playing: Boolean = false
    private var positionMs: Long = 0L
    private var durationMs: Long = 0L
    private var hasNext: Boolean = false
    private var hasPrevious: Boolean = false

    private var art: Bitmap? = null
    private var artKey: String = ""
    private var metadataKey: String = ""
    private var notificationKey: String = ""

    // ---------------------------------------------------------------- 生命周期

    fun attach(context: Context, methodChannel: MethodChannel) {
        try {
            appContext = context.applicationContext
            channel = methodChannel
            ensureSession()
            methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        update(call.arguments as? Map<*, *>)
                        result.success(null)
                    }
                    "clear" -> {
                        clear()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        } catch (e: Exception) {
            // 媒体会话不可用不影响播放
        }
    }

    private fun ensureSession() {
        val ctx = appContext ?: return
        if (session != null) return

        val s = MediaSession(ctx, "qingliu-music")
        s.setFlags(
            MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
        )
        s.setPlaybackToLocal(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .setLegacyStreamType(AudioManager.STREAM_MUSIC)
                .build()
        )
        s.setSessionActivity(contentIntent(ctx))
        s.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = sendAction("play")
            override fun onPause() = sendAction("pause")
            override fun onSkipToNext() = sendAction("next")
            override fun onSkipToPrevious() = sendAction("previous")
            override fun onStop() = sendAction("stop")
            override fun onSeekTo(pos: Long) {
                positionMs = pos
                pushState()
                sendAction("seek", pos)
            }
        })
        s.isActive = false
        session = s

        val filter = IntentFilter().apply {
            addAction(EXTRA_PREVIOUS)
            addAction(EXTRA_TOGGLE)
            addAction(EXTRA_NEXT)
        }
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    EXTRA_PREVIOUS -> sendAction("previous")
                    EXTRA_TOGGLE -> sendAction("toggle")
                    EXTRA_NEXT -> sendAction("next")
                }
            }
        }
        receiver = r
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            ctx.registerReceiver(r, filter)
        }
    }

    // ---------------------------------------------------------------- 状态更新

    private fun update(args: Map<*, *>?) {
        if (args == null) return
        ensureSession()
        val s = session ?: return
        s.isActive = true

        songId = args["id"]?.toString().orEmpty()
        title = args["title"]?.toString().orEmpty()
        artist = args["artist"]?.toString().orEmpty()
        album = args["album"]?.toString().orEmpty()
        playing = args["playing"] == true
        positionMs = (args["positionMs"] as? Number)?.toLong() ?: 0L
        durationMs = (args["durationMs"] as? Number)?.toLong() ?: 0L
        hasNext = args["hasNext"] == true
        hasPrevious = args["hasPrevious"] == true

        val path = args["artPath"]?.toString().orEmpty()
        val url = args["artUrl"]?.toString().orEmpty()
        loadArtwork(if (path.isNotEmpty()) path else url)

        val mKey = "$songId|$title|$artist|$album|$durationMs|${if (art != null) 'a' else '-'}"
        if (mKey != metadataKey) {
            metadataKey = mKey
            pushMetadata()
        }
        pushState()
        pushNotification()
    }

    private fun pushMetadata() {
        val s = session ?: return
        val builder = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, album)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, max(durationMs, 0L))
        art?.let { builder.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) }
        s.setMetadata(builder.build())
    }

    private fun pushState() {
        val s = session ?: return
        // 上一首 / 下一首常驻：锁屏媒体卡片、通知栏和 HyperOS 灵动岛
        // 都是按这个位掩码决定露出哪几个按钮的，不能等队列变化才加。
        val actions = PlaybackState.ACTION_PLAY or
            PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SKIP_TO_PREVIOUS or
            PlaybackState.ACTION_SKIP_TO_NEXT or
            PlaybackState.ACTION_SEEK_TO or
            PlaybackState.ACTION_STOP
        val state =
            if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(state, positionMs, if (playing) 1f else 0f)
                .build()
        )
    }

    // ---------------------------------------------------------------- 通知

    private fun pushNotification() {
        val ctx = appContext ?: return
        val key = "$songId|$title|$artist|$playing|$hasNext|$hasPrevious|" +
            "${if (art != null) 'a' else '-'}"
        if (key == notificationKey) return
        notificationKey = key

        if (playing) {
            MediaPlaybackService.start(ctx)
        }
        notify(ctx)
        if (!playing) {
            MediaPlaybackService.detach(ctx)
        }
    }

    private fun notify(ctx: Context) {
        try {
            val manager =
                ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, buildNotification(ctx))
        } catch (e: Exception) {
            // 通知被系统拒绝时忽略
        }
    }

    /** 供前台服务调用：把通知贴到服务上。 */
    fun buildNotification(ctx: Context): Notification {
        ensureChannel(ctx)
        val builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(ctx, CHANNEL_ID)
            else
                @Suppress("DEPRECATION") Notification.Builder(ctx)

        builder.setSmallIcon(R.drawable.ic_stat_music)
            .setContentTitle(if (title.isEmpty()) "清流音乐" else title)
            .setContentText(if (album.isEmpty()) artist else "$artist · $album")
            .setContentIntent(contentIntent(ctx))
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setOngoing(playing)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        art?.let { builder.setLargeIcon(it) }

        builder.addAction(
            action(ctx, android.R.drawable.ic_media_previous, "上一首", EXTRA_PREVIOUS, 1)
        )
        builder.addAction(
            action(
                ctx,
                if (playing) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play,
                if (playing) "暂停" else "播放",
                EXTRA_TOGGLE,
                2
            )
        )
        builder.addAction(
            action(ctx, android.R.drawable.ic_media_next, "下一首", EXTRA_NEXT, 3)
        )

        val style = Notification.MediaStyle()
            .setShowActionsInCompactView(0, 1, 2)
        session?.let { style.setMediaSession(it.sessionToken) }
        builder.setStyle(style)
        return builder.build()
    }

    private fun action(
        ctx: Context,
        iconRes: Int,
        label: String,
        actionName: String,
        code: Int
    ): Notification.Action {
        val intent = Intent(actionName).setPackage(ctx.packageName)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pending = PendingIntent.getBroadcast(ctx, code, intent, flags)
        return Notification.Action.Builder(
            Icon.createWithResource(ctx, iconRes), label, pending
        ).build()
    }

    private fun contentIntent(ctx: Context): PendingIntent {
        val intent = Intent(ctx, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(ctx, 0, intent, flags)
    }

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID, "播放控制", NotificationManager.IMPORTANCE_LOW
        )
        channel.description = "锁屏和通知栏的播放控制"
        channel.setShowBadge(false)
        channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        manager.createNotificationChannel(channel)
    }

    // ---------------------------------------------------------------- 封面

    private fun loadArtwork(key: String) {
        if (key == artKey) return
        artKey = key
        if (key.isEmpty()) {
            art = null
            return
        }
        worker.execute {
            val bitmap =
                if (key.startsWith("http")) download(key) else decodeFile(key)
            main.post {
                if (artKey != key) return@post
                art = bitmap
                metadataKey = ""
                pushMetadata()
                notificationKey = ""
                pushNotification()
            }
        }
    }

    private fun decodeFile(path: String): Bitmap? = try {
        if (File(path).exists()) BitmapFactory.decodeFile(path) else null
    } catch (e: Exception) {
        null
    }

    private fun download(url: String): Bitmap? {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 5000
                readTimeout = 5000
            }
            conn.inputStream.use { BitmapFactory.decodeStream(it) }
        } catch (e: Exception) {
            null
        } finally {
            try {
                conn?.disconnect()
            } catch (e: Exception) {
            }
        }
    }

    // ---------------------------------------------------------------- 其他

    private fun sendAction(action: String, position: Long = 0L) {
        main.post {
            try {
                channel?.invokeMethod(
                    "action",
                    mapOf("action" to action, "positionMs" to position)
                )
            } catch (e: Exception) {
            }
        }
    }

    fun clear() {
        val ctx = appContext ?: return
        playing = false
        songId = ""
        title = ""
        artist = ""
        album = ""
        positionMs = 0L
        durationMs = 0L
        art = null
        artKey = ""
        notificationKey = ""
        try {
            session?.isActive = false
            val manager =
                ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.cancel(NOTIFICATION_ID)
        } catch (e: Exception) {
        }
        MediaPlaybackService.stop(ctx)
    }
}
