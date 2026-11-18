package com.example.pocket_receipt

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val ocrChannelName = "pocket_receipt/ocr"
    private val shareChannelName = "pocket_receipt/share"

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var ocrEngine: NeuralOcrEngine
    private var shareChannel: MethodChannel? = null
    private var initialIntentHandled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ocrEngine = NeuralOcrEngine(applicationContext)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ocrChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "recognizeText") {
                    val imagePath = call.argument<String>("imagePath")
                    if (imagePath.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "imagePath is missing", null)
                        return@setMethodCallHandler
                    }

                    executor.execute {
                        try {
                            val text = ocrEngine.recognizeText(imagePath)
                            mainHandler.post { result.success(text) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("OCR_ERROR", e.message ?: "OCR failed", null)
                            }
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }

        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannelName)
        shareChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getInitialSharedImages") {
                if (initialIntentHandled) {
                    result.success(emptyList<String>())
                    return@setMethodCallHandler
                }
                initialIntentHandled = true
                val startIntent = intent
                executor.execute {
                    val paths = extractSharedImagePaths(startIntent)
                    mainHandler.post { result.success(paths) }
                }
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        executor.execute {
            val paths = extractSharedImagePaths(intent)
            if (paths.isNotEmpty()) {
                mainHandler.post {
                    shareChannel?.invokeMethod("onSharedImages", paths)
                }
            }
        }
    }

    private fun extractSharedImagePaths(intent: Intent?): List<String> {
        if (intent == null) return emptyList()
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return emptyList()
        }

        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            getSingleUri(intent)?.let { uris.add(it) }
        } else {
            uris.addAll(getMultipleUris(intent))
        }

        if (uris.isEmpty()) {
            val clip = intent.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) {
                    clip.getItemAt(i).uri?.let { uris.add(it) }
                }
            }
        }

        val savedPaths = mutableListOf<String>()
        for (i in uris.indices) {
            copyUriToCache(uris[i], i)?.let { savedPaths.add(it) }
        }
        return savedPaths
    }

    private fun getSingleUri(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
    }

    private fun getMultipleUris(intent: Intent): List<Uri> {
        val list = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        }
        return list ?: emptyList()
    }

    private fun copyUriToCache(uri: Uri, index: Int): String? {
        return try {
            val ext = when (contentResolver.getType(uri)) {
                "image/png" -> ".png"
                "image/webp" -> ".webp"
                else -> ".jpg"
            }
            val outFile = File(cacheDir, "shared_${System.currentTimeMillis()}_$index$ext")
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output ->
                    input.copyTo(output)
                }
            } ?: return null
            outFile.absolutePath
        } catch (_: Exception) {
            null
        }
    }
}