package com.fullstackattack.bits_blink

import android.Manifest
import android.content.pm.PackageManager
import android.util.Size
import android.view.Surface
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.content.Context
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.CaptureRequestOptions
import android.os.Handler
import android.os.Looper
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.bitsblink/hardware"
    private val STREAM_CHANNEL = "com.bitsblink/stream"
    private val CAMERA_PERMISSION_CODE = 1001
    private var pendingResult: MethodChannel.Result? = null
    private var cameraProvider: ProcessCameraProvider? = null

    // Existing modem channel
    private val modemChannelName = "bitsblink/modem"

    // Stream state
    private var eventSink: EventChannel.EventSink? = null
    private val uiHandler = Handler(Looper.getMainLooper())

    // Throttle: min interval between processed frames (~18 FPS)
    private val minFrameIntervalMs = 55L
    private var lastFrameTimestamp = 0L

    // ROI smoothing: exponential moving average on bestX
    private var smoothedBestX: Double = -1.0
    private val roiSmoothingAlpha = 0.3  // 30% new, 70% old

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Existing modem / transmit channel ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, modemChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "transmit") {
                    val signal = call.argument<List<Boolean>>("signal")
                    if (signal == null) {
                        result.error("BAD_ARGS", "Missing 'signal' argument", null)
                        return@setMethodCallHandler
                    }

                    Thread {
                        val cameraManager =
                            getSystemService(Context.CAMERA_SERVICE) as CameraManager
                        val cameraId = cameraManager.cameraIdList[0]

                        try {
                            // Chip duration configurable from Dart (default 5ms)
                            val chipDurationMs = call.argument<Int>("chipDurationMs") ?: 15
                            val chipDurationNs = chipDurationMs * 1_000_000L

                            for (state in signal) {
                                cameraManager.setTorchMode(cameraId, state)
                                // Precise busy-wait (System.nanoTime) instead of Thread.sleep
                                val start = System.nanoTime()
                                while (System.nanoTime() - start < chipDurationNs) {
                                    // spin — much more precise than Thread.sleep for <10ms
                                }
                            }
                        } catch (e: Exception) {
                            android.util.Log.e("BITSBlink", "Transmit error: ${e.message}")
                        } finally {
                            try {
                                cameraManager.setTorchMode(cameraId, false)
                            } catch (_: Exception) {}
                        }
                    }.start()

                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        // ── Debug capture channel (single frame) ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "captureDebugFrame") {
                    pendingResult = result
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
                        == PackageManager.PERMISSION_GRANTED
                    ) {
                        captureFrame()
                    } else {
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.CAMERA),
                            CAMERA_PERMISSION_CODE
                        )
                    }
                } else {
                    result.notImplemented()
                }
            }

        // ── Continuous stream EventChannel ──
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STREAM_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    if (ContextCompat.checkSelfPermission(
                            this@MainActivity, Manifest.permission.CAMERA
                        ) == PackageManager.PERMISSION_GRANTED
                    ) {
                        startStreaming()
                    } else {
                        ActivityCompat.requestPermissions(
                            this@MainActivity,
                            arrayOf(Manifest.permission.CAMERA),
                            CAMERA_PERMISSION_CODE
                        )
                    }
                }

                override fun onCancel(arguments: Any?) {
                    stopStreaming()
                    eventSink = null
                }
            })
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                if (pendingResult != null) captureFrame()
                if (eventSink != null) startStreaming()
            } else {
                pendingResult?.error("PERMISSION_DENIED", "Camera permission denied", null)
                pendingResult = null
                eventSink?.error("PERMISSION_DENIED", "Camera permission denied", null)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Continuous streaming via CameraX ImageAnalysis
    // ═══════════════════════════════════════════════════════════════════

    private fun startStreaming() {
        smoothedBestX = -1.0  // Reset ROI smoothing for fresh stream
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            try {
                val provider = cameraProviderFuture.get()
                this.cameraProvider = provider
                val executor = Executors.newSingleThreadExecutor()

                val analysisBuilder = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setTargetRotation(Surface.ROTATION_0)
                    .setTargetResolution(Size(640, 480))

                // Phase 2: Lock camera exposure via Camera2 interop
                @androidx.camera.camera2.interop.ExperimentalCamera2Interop
                fun applyCamera2Settings() {
                    val extender = Camera2Interop.Extender(analysisBuilder)
                    extender.setCaptureRequestOption(
                        CaptureRequest.CONTROL_AE_MODE,
                        CaptureRequest.CONTROL_AE_MODE_OFF
                    )
                    extender.setCaptureRequestOption(
                        CaptureRequest.SENSOR_EXPOSURE_TIME,
                        1_000_000L  // 1ms — ultra-short for sharp stripes
                    )
                    extender.setCaptureRequestOption(
                        CaptureRequest.SENSOR_SENSITIVITY,
                        100  // ISO 100 — minimal noise
                    )
                }
                applyCamera2Settings()

                val imageAnalysis = analysisBuilder.build()

                imageAnalysis.setAnalyzer(executor) { imageProxy ->
                    val now = System.currentTimeMillis()

                    // ── Throttle: skip frame if too soon ──
                    if (now - lastFrameTimestamp < minFrameIntervalMs) {
                        imageProxy.close()
                        return@setAnalyzer
                    }
                    lastFrameTimestamp = now

                    var payload: HashMap<String, Any>? = null
                    try {
                        payload = processFrameWithDemod(imageProxy)
                    } catch (e: Exception) {
                        android.util.Log.e("BITSBlink", "Stream frame error: ${e.message}")
                    } finally {
                        imageProxy.close()
                    }

                    // Push payload to Flutter on the UI thread
                    if (payload != null) {
                        val p = payload
                        uiHandler.post {
                            eventSink?.success(p)
                        }
                    }
                }

                provider.unbindAll()
                val camera = provider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    imageAnalysis
                )

                // ── Force exposure settings AFTER bind (more reliable) ──
                @Suppress("UnsafeOptInUsageError")
                try {
                    val cam2Control = Camera2CameraControl.from(camera.cameraControl)
                    val options = CaptureRequestOptions.Builder()
                        .setCaptureRequestOption(
                            CaptureRequest.CONTROL_AE_MODE,
                            CaptureRequest.CONTROL_AE_MODE_OFF
                        )
                        .setCaptureRequestOption(
                            CaptureRequest.SENSOR_EXPOSURE_TIME,
                            1_000_000L  // 1ms
                        )
                        .setCaptureRequestOption(
                            CaptureRequest.SENSOR_SENSITIVITY,
                            100  // ISO 100
                        )
                        .build()
                    cam2Control.captureRequestOptions = options
                    android.util.Log.i("BITSBlink", "Camera2 exposure locked: 1ms, ISO 100")
                } catch (e: Exception) {
                    android.util.Log.w("BITSBlink", "Camera2Control fallback failed: ${e.message}")
                }
            } catch (e: Exception) {
                android.util.Log.e("BITSBlink", "Stream start error: ${e.message}")
                uiHandler.post {
                    eventSink?.error("CAMERA_ERROR", e.message, null)
                }
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun stopStreaming() {
        try {
            cameraProvider?.unbindAll()
        } catch (e: Exception) {
            android.util.Log.e("BITSBlink", "Stream stop error: ${e.message}")
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Single-frame capture (existing — still returns raw JPEG bytes)
    // ═══════════════════════════════════════════════════════════════════

    private fun captureFrame() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            try {
                val provider = cameraProviderFuture.get()
                this.cameraProvider = provider
                val executor = Executors.newSingleThreadExecutor()

                val imageAnalysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()

                imageAnalysis.setAnalyzer(executor) { imageProxy ->
                    var result: HashMap<String, Any>? = null
                    var errorMsg: String? = null

                    try {
                        result = processFrameWithDemod(imageProxy)
                    } catch (e: Exception) {
                        errorMsg = e.message ?: "Unknown processing error"
                        e.printStackTrace()
                    } finally {
                        imageProxy.close()
                    }

                    runOnUiThread {
                        try {
                            provider.unbindAll()
                        } catch (_: Exception) {}

                        if (result != null) {
                            pendingResult?.success(result["frame"])
                        } else {
                            pendingResult?.error("CAPTURE_ERROR", errorMsg, null)
                        }
                        pendingResult = null
                    }
                }

                provider.unbindAll()
                provider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    imageAnalysis
                )
            } catch (e: Exception) {
                pendingResult?.error("CAMERA_ERROR", e.message, null)
                pendingResult = null
            }
        }, ContextCompat.getMainExecutor(this))
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Frame processing: ROI → Demod → Red Box Bitmap → JPEG + bits
    // ═══════════════════════════════════════════════════════════════════

    /**
     * Returns a HashMap containing:
     *   "frame" → JPEG ByteArray with a RED bounding box drawn via Canvas
     *   "bits"  → List<Int> of 1s and 0s from rolling-shutter demodulation
     */
    // Track actual camera resolution
    private var loggedResolution = false

    private fun processFrameWithDemod(image: ImageProxy): HashMap<String, Any> {
        val yPlane = image.planes[0]
        val yBuffer = yPlane.buffer.duplicate()
        val width = image.width
        val height = image.height
        val rowStride = yPlane.rowStride
        val pixelStride = yPlane.pixelStride

        // ── Step 1: Extract Y-plane bytes ──
        val yBytes = ByteArray(width * height)
        yBuffer.rewind()

        if (!loggedResolution) {
            android.util.Log.i("BITSBlink", "Camera resolution: ${width}x${height}")
            loggedResolution = true
        }

        if (rowStride == width && pixelStride == 1) {
            yBuffer.get(yBytes, 0, width * height)
        } else {
            val rowBuffer = ByteArray(rowStride)
            for (row in 0 until height) {
                val remaining = yBuffer.remaining()
                val toRead = if (row == height - 1) {
                    minOf(remaining, width)
                } else {
                    minOf(remaining, rowStride)
                }

                if (toRead <= 0) break

                if (row == height - 1 && remaining < rowStride) {
                    yBuffer.get(rowBuffer, 0, toRead)
                    System.arraycopy(rowBuffer, 0, yBytes, row * width, minOf(toRead, width))
                } else {
                    yBuffer.get(rowBuffer, 0, rowStride)
                    System.arraycopy(rowBuffer, 0, yBytes, row * width, width)
                }
            }
        }

        // ── Step 2: Find brightest ROI (existing algorithm) ──
        val blockSize = 8
        val roiBlocks = 4
        var bestSum = 0L
        var bestX = 0
        var bestY = 0

        val gridW = width / blockSize
        val gridH = height / blockSize

        if (gridW > roiBlocks && gridH > roiBlocks) {
            for (gy in 0 until gridH - roiBlocks) {
                for (gx in 0 until gridW - roiBlocks) {
                    var sum = 0L
                    for (by in 0 until roiBlocks) {
                        for (bx in 0 until roiBlocks) {
                            val px = (gx + bx) * blockSize + blockSize / 2
                            val py = (gy + by) * blockSize + blockSize / 2
                            if (py < height && px < width) {
                                sum += (yBytes[py * width + px].toInt() and 0xFF)
                            }
                        }
                    }
                    if (sum > bestSum) {
                        bestSum = sum
                        bestX = gx * blockSize
                        bestY = gy * blockSize
                    }
                }
            }
        }

        val roiSize = roiBlocks * blockSize

        // ── ROI Stabilization: EMA smoothing on X position ──
        val rawX = bestX.coerceIn(0, (width - roiSize).coerceAtLeast(0))
        if (smoothedBestX < 0) {
            smoothedBestX = rawX.toDouble()  // First frame: snap to position
        } else {
            smoothedBestX = roiSmoothingAlpha * rawX + (1.0 - roiSmoothingAlpha) * smoothedBestX
        }
        val roiX = smoothedBestX.toInt().coerceIn(0, (width - roiSize).coerceAtLeast(0))

        // CRITICAL: Force the ROI to span the ENTIRE image height
        // so we capture the full rolling-shutter time-domain waveform.
        val roiY = 0
        val roiEndY = height

        // ── Step 3: Rolling shutter demodulation inside the ROI ──
        val bits = mutableListOf<Int>()
        val roiEndX = minOf(roiX + roiSize, width)
        val roiW = roiEndX - roiX

        if (roiW > 0 && roiEndY > roiY) {
            // Calculate average brightness per row inside the ROI
            val rowAverages = mutableListOf<Double>()
            for (y in roiY until roiEndY) {
                var rowSum = 0L
                for (x in roiX until roiEndX) {
                    rowSum += (yBytes[y * width + x].toInt() and 0xFF)
                }
                rowAverages.add(rowSum.toDouble() / roiW)
            }

            // ── Squelch: Minimum brightness gate ──
            val maxBrightness = rowAverages.maxOrNull() ?: 0.0
            val squelchThreshold = 30.0

            if (maxBrightness < squelchThreshold) {
                for (i in rowAverages.indices) bits.add(0)
            } else {
                // Sliding window adaptive threshold
                val windowSize = 60
                val minRowBrightness = 10.0  // Per-row noise gate
                for (i in rowAverages.indices) {
                    // Per-row gate: if this row is too dark, it's noise → force 0
                    if (rowAverages[i] < minRowBrightness) {
                        bits.add(0)
                        continue
                    }
                    val wStart = maxOf(0, i - windowSize / 2)
                    val wEnd   = minOf(rowAverages.size, i + windowSize / 2)
                    var localSum = 0.0
                    for (j in wStart until wEnd) localSum += rowAverages[j]
                    val localThreshold = localSum / (wEnd - wStart)
                    bits.add(if (rowAverages[i] >= localThreshold * 0.95) 1 else 0)
                }
            }

            // ── Low-Pass Filter: Majority-vote sliding window ──
            // Each bit becomes the majority of its neighbors.
            // A 151-row window means a noise spike < 75 rows gets outvoted.
            val lpfWindow = 151
            if (bits.size > lpfWindow) {
                val filtered = IntArray(bits.size)
                val half = lpfWindow / 2

                // Compute initial window sum for position 0
                var windowSum = 0
                for (j in 0 until minOf(lpfWindow, bits.size)) {
                    windowSum += bits[j]
                }
                // Initial window covers [0, min(lpfWindow, size))
                var wLeft = 0
                var wRight = minOf(lpfWindow, bits.size)
                var wSize = wRight - wLeft
                filtered[0] = if (windowSum * 2 >= wSize) 1 else 0

                for (i in 1 until bits.size) {
                    // Slide window: ideally centered at i
                    val newLeft = maxOf(0, i - half)
                    val newRight = minOf(bits.size, i + half + 1)

                    // Remove elements that left the window
                    while (wLeft < newLeft) {
                        windowSum -= bits[wLeft]
                        wLeft++
                    }
                    // Add elements that entered the window
                    while (wRight < newRight) {
                        windowSum += bits[wRight]
                        wRight++
                    }
                    wSize = wRight - wLeft
                    filtered[i] = if (windowSum * 2 >= wSize) 1 else 0
                }
                bits.clear()
                for (v in filtered) bits.add(v)
            }

            // ── Headless: Return raw data only (no Bitmap/JPEG) ──
            return hashMapOf(
                "intensities" to rowAverages,
                "bits" to bits
            )
        }

        // Fallback: empty data
        return hashMapOf(
            "intensities" to listOf<Double>(),
            "bits" to listOf<Int>()
        )
    }
}
