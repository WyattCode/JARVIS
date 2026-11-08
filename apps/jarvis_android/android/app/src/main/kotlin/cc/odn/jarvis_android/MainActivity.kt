package cc.odn.jarvis_android

import android.app.Activity
import android.content.*
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Rect
import android.media.*
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.ByteArrayInputStream
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 31) {
            // The Flutter first frame matches the native reactor artwork.
            // Remove atomically instead of cross-fading/scaling two reactors.
            splashScreen.setOnExitAnimationListener { view -> view.remove() }
        }
    }

    private val io = Executors.newSingleThreadExecutor()
    private val outputIo = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var audioEvents: EventChannel.EventSink? = null
    private lateinit var player: PcmPlayer
    private var audioManager: AudioManager? = null
    private var focus: AudioFocusRequest? = null
    private var oldMode = AudioManager.MODE_NORMAL
    private var pendingExport: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null
    private var receiverRegistered = false
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) { endAudio(); audioEvents?.success(mapOf("type" to "stop_requested")) }
    }
    private fun emit(value: Map<String, Any>) { main.post { audioEvents?.success(value) } }
    private fun focus() {
        val manager = getSystemService(AudioManager::class.java)
        if (audioManager == null) { audioManager = manager; oldMode = manager.mode }
        if (Build.VERSION.SDK_INT >= 26 && focus == null) {
            focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener({ change ->
                    if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                        player.stop(); emit(mapOf("type" to "focus_lost"))
                    }
                }, main).build()
            require(manager.requestAudioFocus(focus!!) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) { "Audio focus denied" }
        }
        volumeControlStream = AudioManager.STREAM_VOICE_CALL
    }
    private fun endAudio() {
        player.stop()
        stopService(Intent(this, JarvisCallService::class.java))
        if (Build.VERSION.SDK_INT >= 26) focus?.let { audioManager?.abandonAudioFocusRequest(it) }
        focus = null; audioManager?.mode = oldMode; audioManager = null
        volumeControlStream = AudioManager.USE_DEFAULT_STREAM_TYPE
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == "cc.odn.jarvis.OPEN_CALL") emit(mapOf("type" to "open_requested"))
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val binary = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(binary, "cc.odn.jarvis/layout").setMethodCallHandler { call, result ->
            if (call.method == "foldable") {
                // A folding phone has a hinge sensor; a straight phone does not.
                result.success(packageManager.hasSystemFeature("android.hardware.sensor.hinge_angle"))
                return@setMethodCallHandler
            }
            if (call.method != "gripExclusion") { result.notImplemented(); return@setMethodCallHandler }
            if (Build.VERSION.SDK_INT >= 29) {
                val bounds = call.arguments as? List<*>
                window.decorView.systemGestureExclusionRects = if (bounds?.size == 4) {
                    val values = bounds.map { (it as Number).toInt() }
                    listOf(Rect(values[0], values[1], values[2], values[3]))
                } else emptyList()
            }
            result.success(null)
        }
        player = PcmPlayer(::emit)
        val vault = PrivateVault(this)
        EventChannel(binary, "cc.odn.jarvis/audio-events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { audioEvents = events }
            override fun onCancel(arguments: Any?) { audioEvents = null }
        })
        val filter = IntentFilter("cc.odn.jarvis.END_CALL")
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(stopReceiver, filter, Context.RECEIVER_NOT_EXPORTED) else registerReceiver(stopReceiver, filter)
        receiverRegistered = true
        MethodChannel(binary, "cc.odn.jarvis/vault").setMethodCallHandler { call, result ->
            if (call.method !in listOf("read", "write", "readBlob", "writeBlob")) { result.notImplemented(); return@setMethodCallHandler }
            io.execute {
                try {
                    val value: Any? = when (call.method) {
                        "read" -> vault.read(vault.state())?.toString(Charsets.UTF_8)
                        "write" -> { vault.write(vault.state(), (call.arguments as String).toByteArray(Charsets.UTF_8)); null }
                        "readBlob" -> vault.read(vault.blob(call.arguments as String))
                        else -> { val id = call.argument<String>("id")!!; val bytes = call.argument<ByteArray>("bytes")!!; vault.write(vault.blob(id), bytes); null }
                    }
                    main.post { result.success(value) }
                } catch (_: Exception) { main.post { result.error("vault_failed", "无法访问本机加密资料，原资料已保留", null) } }
            }
        }
        MethodChannel(binary, "cc.odn.jarvis/audio").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        focus(); player.configure(call.argument<Int>("rate")!!, call.argument<Int>("epoch")!!)
                        val intent = Intent(this, JarvisCallService::class.java)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        result.success(null)
                    }
                    "configureOutput" -> { focus(); player.configure(call.argument<Int>("rate")!!, call.argument<Int>("epoch")!!); result.success(null) }
                    "feed" -> {
                        val bytes = call.argument<ByteArray>("bytes")!!; val epoch = call.argument<Int>("epoch")!!
                        outputIo.execute { try { player.feed(epoch, bytes); main.post { result.success(null) } } catch (_: Exception) { main.post { result.error("audio_failed", "音频输出失败", null) } } }
                    }
                    "clear" -> { player.clear(call.argument<Int>("epoch")!!); result.success(null) }
                    "setPaused" -> { player.setPaused(call.argument<Boolean>("paused") == true); result.success(null) }
                    "inputError" -> { emit(mapOf("type" to "input_error")); result.success(null) }
                    "stop" -> { endAudio(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("audio_failed", "音频设备未能启动或已被占用", null) }
        }
        MethodChannel(binary, "cc.odn.jarvis/files").setMethodCallHandler { call, result ->
            when (call.method) {
                "normalizeImage" -> io.execute {
                    try { val bytes = normalizeImage(call.arguments as ByteArray); main.post { result.success(bytes) } }
                    catch (_: Exception) { main.post { result.error("image_invalid", "图片无法读取、尺寸过大或压缩后超过3MB", null) } }
                }
                "save" -> {
                    if (pendingExport != null) { result.error("busy", "请先完成当前保存操作", null); return@setMethodCallHandler }
                    pendingExport = result; pendingBytes = call.argument<ByteArray>("bytes")!!
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE); type = call.argument<String>("mime") ?: "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "jarvis-file")
                    }, 741)
                }
                "share" -> io.execute {
                    try {
                        val name = File(call.argument<String>("name") ?: "jarvis-file").name
                        val file = File(File(cacheDir, "exports").apply { mkdirs() }, "${System.currentTimeMillis()}-$name")
                        file.writeBytes(call.argument<ByteArray>("bytes")!!)
                        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
                        val intent = Intent(Intent.ACTION_SEND).apply { type = call.argument<String>("mime") ?: "application/octet-stream"; putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                        main.post { startActivity(Intent.createChooser(intent, "分享")); result.success(true) }
                    } catch (_: Exception) { main.post { result.error("share_failed", "无法打开分享，请重试", null) } }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun normalizeImage(bytes: ByteArray): ByteArray {
        require(bytes.size <= 20 * 1024 * 1024)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0 && bounds.outWidth.toLong() * bounds.outHeight <= 60_000_000L)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 3072) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: error("Bad image")
        val owned = mutableSetOf(decoded)
        try {
            // JPEG pixels can be sideways/mirrored; compression discards EXIF.
            val orientation = try {
                ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            } catch (_: Exception) { ExifInterface.ORIENTATION_NORMAL }
            val transform = Matrix().apply {
                when (orientation) {
                    2 -> setScale(-1f, 1f)
                    3 -> setRotate(180f)
                    4 -> setScale(1f, -1f)
                    5 -> setValues(floatArrayOf(0f, 1f, 0f, 1f, 0f, 0f, 0f, 0f, 1f))
                    6 -> setRotate(90f)
                    7 -> setValues(floatArrayOf(0f, -1f, 0f, -1f, 0f, 0f, 0f, 0f, 1f))
                    8 -> setRotate(270f)
                }
            }
            val oriented = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, transform, true).also { owned.add(it) }
            val factor = minOf(1.0, 3072.0 / maxOf(oriented.width, oriented.height))
            val scaled = Bitmap.createScaledBitmap(oriented, maxOf(1, (oriented.width * factor).toInt()), maxOf(1, (oriented.height * factor).toInt()), true).also { owned.add(it) }
            val flat = Bitmap.createBitmap(scaled.width, scaled.height, Bitmap.Config.ARGB_8888).also { owned.add(it) }
            Canvas(flat).apply { drawColor(Color.WHITE); drawBitmap(scaled, 0f, 0f, null) }
            val output = ByteArrayOutputStream(); require(flat.compress(Bitmap.CompressFormat.JPEG, 88, output))
            return output.toByteArray().also { require(it.size <= 3 * 1024 * 1024) }
        } finally {
            owned.forEach { if (!it.isRecycled) it.recycle() }
        }
    }
    @Deprecated("Legacy document picker result bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 741) return
        val result = pendingExport ?: return; val bytes = pendingBytes
        pendingExport = null; pendingBytes = null
        if (resultCode != Activity.RESULT_OK || data?.data == null || bytes == null) { result.success(false); return }
        val uri = data.data!!
        io.execute { try { contentResolver.openOutputStream(uri)?.use { it.write(bytes) } ?: error("No stream"); main.post { result.success(true) } }
            catch (_: Exception) { main.post { result.error("save_failed", "文件保存失败", null) } } }
    }
    override fun onDestroy() {
        if (::player.isInitialized) { endAudio(); player.close() }
        if (receiverRegistered) unregisterReceiver(stopReceiver)
        pendingExport?.error("cancelled", "操作已结束", null); pendingExport = null; pendingBytes = null
        io.shutdown(); outputIo.shutdownNow(); super.onDestroy()
    }
}
