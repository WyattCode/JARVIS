package ai.jarvis.app.android

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class JarvisCallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("jarvis-call", "贾维斯语音通话", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") {
            sendBroadcast(Intent("ai.jarvis.app.END_CALL").setPackage(packageName))
            stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); return START_NOT_STICKY
        }
        val open = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java).setAction("ai.jarvis.app.OPEN_CALL").addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 2, Intent(this, JarvisCallService::class.java).setAction("stop"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "jarvis-call") else Notification.Builder(this)
        val notification = builder
            .setSmallIcon(R.drawable.ic_call_notification).setContentTitle("贾维斯语音通话中")
            .setContentText("点击返回通话").setContentIntent(open).setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL).addAction(Notification.Action.Builder(null, "结束通话", stop).build()).build()
        if (Build.VERSION.SDK_INT >= 30) startForeground(3401, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else if (Build.VERSION.SDK_INT >= 29) startForeground(3401, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else startForeground(3401, notification)
        return START_NOT_STICKY
    }
}
