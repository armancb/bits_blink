package com.fullstackattack.bits_blink

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import androidx.camera.core.ImageProxy
import java.io.ByteArrayOutputStream

/**
 * ModemAnalyzer — Stateful DSP pipeline for the BITSBlink optical modem.
 *
 * Responsibilities:
 *   1. Stateful ROI tracking (Global Scan → Lock → Local Tracking)
 *   2. 1D waveform extraction via row-averaged luma
 *   3. Adaptive thresholding → binary waveform
 *   4. JPEG visualization with red bounding box
 *
 * All tunable constants are grouped at the top for easy hackathon tweaking.
 */
class ModemAnalyzer {

    // ═══════════════════════════════════════════════════════════════
    // ██  TUNABLE CONSTANTS — tweak these during the hackathon!  ██
    // ═══════════════════════════════════════════════════════════════

    /** Pixels to skip during global scan (larger = faster, less precise). */
    private val GLOBAL_SCAN_STEP = 16

    /** Half-width of the local tracking search box (pixels). */
    private val LOCAL_TRACK_RADIUS = 50

    /** If the brightest pixel in the local box falls below this, lose lock. */
    private val LOCK_LOSS_THRESHOLD = 40

    /** Width of the 1D waveform extraction box (pixels). Narrow = focused signal. */
    private val EXTRACT_WIDTH = 60

    /** Height of the 1D waveform extraction box.
     *  Set to 0 = use FULL sensor height (captures max rolling-shutter time). */
    private val EXTRACT_HEIGHT = 0  // 0 = full height

    /** Thickness of the drawn bounding box (pixels). */
    private val BOX_THICKNESS = 2

    /** JPEG compression quality (0–100). Lower = smaller, faster. */
    private val JPEG_QUALITY = 70

    // ═══════════════════════════════════════════════════════════════
    // ██  STATE VARIABLES — persist across frames                ██
    // ═══════════════════════════════════════════════════════════════

    /** X coordinate of the tracked ROI center. */
    var lastRoiCenterX: Int = 0
        private set

    /** Y coordinate of the tracked ROI center. */
    var lastRoiCenterY: Int = 0
        private set

    /** Whether we have a stable lock on the light source. */
    var isLocked: Boolean = false
        private set

    // ═══════════════════════════════════════════════════════════════
    // ██  MAIN ENTRY POINT                                       ██
    // ═══════════════════════════════════════════════════════════════

    /**
     * Process a single camera frame. Returns a [FrameResult] containing
     * the JPEG visualization, binary waveform, and tracking metadata.
     */
    fun analyze(image: ImageProxy): FrameResult {
        val yPlane = image.planes[0]
        val yBuffer = yPlane.buffer.duplicate()
        val width = image.width
        val height = image.height
        val rowStride = yPlane.rowStride
        val pixelStride = yPlane.pixelStride

        // ── 1. Copy Y-plane to contiguous array ──
        val yBytes = ByteArray(width * height)
        yBuffer.rewind()

        if (rowStride == width && pixelStride == 1) {
            // Fast path: buffer is tightly packed
            yBuffer.get(yBytes, 0, width * height)
        } else {
            // Slow path: handle row stride padding
            val rowBuffer = ByteArray(rowStride)
            for (row in 0 until height) {
                val remaining = yBuffer.remaining()
                if (remaining <= 0) break
                if (row == height - 1 && remaining < rowStride) {
                    val toRead = minOf(remaining, width)
                    yBuffer.get(rowBuffer, 0, toRead)
                    System.arraycopy(rowBuffer, 0, yBytes, row * width, minOf(toRead, width))
                } else {
                    yBuffer.get(rowBuffer, 0, minOf(remaining, rowStride))
                    System.arraycopy(rowBuffer, 0, yBytes, row * width, width)
                }
            }
        }

        // ── 2. ROI Tracking ──
        val maxBrightness: Int
        if (!isLocked) {
            // ── GLOBAL SCAN: find the brightest cluster across the whole frame ──
            val result = globalScan(yBytes, width, height)
            lastRoiCenterX = result.first
            lastRoiCenterY = result.second
            maxBrightness = result.third
            // Lock on if we found something bright enough
            isLocked = maxBrightness >= LOCK_LOSS_THRESHOLD
        } else {
            // ── LOCAL TRACKING: search only near the last known position ──
            val result = localTrack(yBytes, width, height, lastRoiCenterX, lastRoiCenterY)
            lastRoiCenterX = result.first
            lastRoiCenterY = result.second
            maxBrightness = result.third
            // ── LOCK LOSS: if brightness drops, unlock for a full re-scan ──
            if (maxBrightness < LOCK_LOSS_THRESHOLD) {
                isLocked = false
            }
        }

        // ── 3. 1D Waveform Extraction (row averaging) ──
        val actualExtractH = if (EXTRACT_HEIGHT <= 0) height else EXTRACT_HEIGHT
        val waveform = extractWaveform(yBytes, width, height, lastRoiCenterX, lastRoiCenterY, actualExtractH)

        // ── 4. Adaptive Thresholding ──
        val threshold = adaptiveThreshold(waveform)
        val binaryWaveform = BooleanArray(waveform.size) { waveform[it] > threshold }

        // ── 4b. Frame-level ROI average brightness ──
        // Single number: average of ALL rows in the extraction region.
        // This is the key value for frame-level OOK when chips > frame time.
        val roiAvgBrightness = if (waveform.isNotEmpty()) waveform.sum() / waveform.size else 0

        // ── 5. Build JPEG visualization ──
        val extractX = (lastRoiCenterX - EXTRACT_WIDTH / 2).coerceIn(0, (width - EXTRACT_WIDTH).coerceAtLeast(0))
        val extractY = if (actualExtractH >= height) 0
                        else (lastRoiCenterY - actualExtractH / 2).coerceIn(0, (height - actualExtractH).coerceAtLeast(0))

        // Build NV21 for JPEG encoding
        val nv21 = ByteArray(width * height * 3 / 2)
        System.arraycopy(yBytes, 0, nv21, 0, width * height)
        java.util.Arrays.fill(nv21, width * height, nv21.size, 128.toByte())

        // Draw red bounding box
        drawRect(nv21, width, height, extractX, extractY,
                 EXTRACT_WIDTH, actualExtractH, BOX_THICKNESS, 82.toByte())
        colorizeRectUV(nv21, width, height, extractX, extractY,
                       EXTRACT_WIDTH, actualExtractH, BOX_THICKNESS)

        val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        val out = ByteArrayOutputStream()
        yuvImage.compressToJpeg(Rect(0, 0, width, height), JPEG_QUALITY, out)
        val jpegBytes = out.toByteArray()

        return FrameResult(
            jpegBytes = jpegBytes,
            binaryWaveform = binaryWaveform,
            waveform = waveform,
            roiCenterX = lastRoiCenterX,
            roiCenterY = lastRoiCenterY,
            isLocked = isLocked,
            threshold = threshold,
            maxBrightness = maxBrightness,
            roiAvgBrightness = roiAvgBrightness
        )
    }

    // ═══════════════════════════════════════════════════════════════
    // ██  ROI TRACKING                                           ██
    // ═══════════════════════════════════════════════════════════════

    /**
     * GLOBAL SCAN — Scans the entire Y-plane skipping [GLOBAL_SCAN_STEP]
     * pixels to find the brightest cluster. Samples a small cross pattern
     * at each candidate point for noise robustness.
     *
     * Returns: Triple(centerX, centerY, maxBrightness)
     */
    private fun globalScan(yBytes: ByteArray, w: Int, h: Int): Triple<Int, Int, Int> {
        var bestX = w / 2
        var bestY = h / 2
        var bestVal = 0

        val step = GLOBAL_SCAN_STEP
        // Scan with a cross-shaped kernel (5 samples per point)
        for (y in step until h - step step step) {
            for (x in step until w - step step step) {
                // Sum a small cross: center + 4 neighbors
                val center = yBytes[y * w + x].toInt() and 0xFF
                val up = yBytes[(y - 1) * w + x].toInt() and 0xFF
                val down = yBytes[(y + 1) * w + x].toInt() and 0xFF
                val left = yBytes[y * w + (x - 1)].toInt() and 0xFF
                val right = yBytes[y * w + (x + 1)].toInt() and 0xFF
                val sum = center + up + down + left + right

                if (sum > bestVal) {
                    bestVal = sum
                    bestX = x
                    bestY = y
                }
            }
        }
        // Return per-pixel brightness (divide cluster sum by 5)
        return Triple(bestX, bestY, bestVal / 5)
    }

    /**
     * LOCAL TRACKING — Searches only within ±[LOCAL_TRACK_RADIUS] pixels
     * around the last known ROI center. Uses step=4 for a balance of
     * speed and precision.
     *
     * Returns: Triple(newCenterX, newCenterY, maxBrightness)
     */
    private fun localTrack(
        yBytes: ByteArray, w: Int, h: Int, cx: Int, cy: Int
    ): Triple<Int, Int, Int> {
        val r = LOCAL_TRACK_RADIUS
        val x0 = (cx - r).coerceAtLeast(1)
        val y0 = (cy - r).coerceAtLeast(1)
        val x1 = (cx + r).coerceAtMost(w - 2)
        val y1 = (cy + r).coerceAtMost(h - 2)

        var bestX = cx
        var bestY = cy
        var bestVal = 0

        val step = 4  // Fine-grained local scan
        for (y in y0 until y1 step step) {
            for (x in x0 until x1 step step) {
                val center = yBytes[y * w + x].toInt() and 0xFF
                val up = yBytes[(y - 1) * w + x].toInt() and 0xFF
                val down = yBytes[(y + 1) * w + x].toInt() and 0xFF
                val sum = center + up + down
                if (sum > bestVal) {
                    bestVal = sum
                    bestX = x
                    bestY = y
                }
            }
        }
        return Triple(bestX, bestY, bestVal / 3)
    }

    // ═══════════════════════════════════════════════════════════════
    // ██  1D WAVEFORM EXTRACTION                                 ██
    // ═══════════════════════════════════════════════════════════════

    /**
     * Collapse the 2D ROI into a 1D waveform by averaging each row's
     * luma values. The resulting array has one entry per row of the
     * extraction box (length = [EXTRACT_HEIGHT]).
     *
     * Peaks in this array correspond to flash ON bands in the rolling
     * shutter capture.
     */
    private fun extractWaveform(
        yBytes: ByteArray, w: Int, h: Int, cx: Int, cy: Int, extractH: Int
    ): IntArray {
        val halfW = EXTRACT_WIDTH / 2
        val x0 = (cx - halfW).coerceIn(0, (w - EXTRACT_WIDTH).coerceAtLeast(0))
        val y0 = if (extractH >= h) 0
                 else (cy - extractH / 2).coerceIn(0, (h - extractH).coerceAtLeast(0))
        val actualW = minOf(EXTRACT_WIDTH, w - x0)
        val actualH = minOf(extractH, h - y0)

        val waveform = IntArray(actualH)

        for (row in 0 until actualH) {
            var sum = 0
            val rowStart = (y0 + row) * w + x0
            for (col in 0 until actualW) {
                sum += yBytes[rowStart + col].toInt() and 0xFF
            }
            waveform[row] = if (actualW > 0) sum / actualW else 0
        }

        return waveform
    }

    // ═══════════════════════════════════════════════════════════════
    // ██  ADAPTIVE THRESHOLDING                                  ██
    // ═══════════════════════════════════════════════════════════════

    /**
     * Computes a dynamic threshold for this frame using the midpoint
     * of the waveform's min and max values.
     *
     * threshold = (min + max) / 2
     *
     * This adapts to varying ambient light conditions, LED brightness,
     * and distance from the transmitter.
     */
    private fun adaptiveThreshold(waveform: IntArray): Int {
        if (waveform.isEmpty()) return 128

        var min = 255
        var max = 0
        for (v in waveform) {
            if (v < min) min = v
            if (v > max) max = v
        }
        return (min + max) / 2
    }

    // ═══════════════════════════════════════════════════════════════
    // ██  DRAWING HELPERS                                        ██
    // ═══════════════════════════════════════════════════════════════

    /** Draw a rectangle on the Y-plane of an NV21 buffer. */
    private fun drawRect(
        nv21: ByteArray, w: Int, h: Int,
        rx: Int, ry: Int, rw: Int, rh: Int, thickness: Int, lumaValue: Byte
    ) {
        for (t in 0 until thickness) {
            for (x in rx until minOf(rx + rw, w)) {
                val topY = ry + t
                val botY = ry + rh - 1 - t
                if (topY in 0 until h) nv21[topY * w + x] = lumaValue
                if (botY in 0 until h) nv21[botY * w + x] = lumaValue
            }
            for (y in ry until minOf(ry + rh, h)) {
                val leftX = rx + t
                val rightX = rx + rw - 1 - t
                if (leftX in 0 until w) nv21[y * w + leftX] = lumaValue
                if (rightX in 0 until w) nv21[y * w + rightX] = lumaValue
            }
        }
    }

    /** Set UV values to red (V=240, U=90) for bounding-box pixels. */
    private fun colorizeRectUV(
        nv21: ByteArray, w: Int, h: Int,
        rx: Int, ry: Int, rw: Int, rh: Int, thickness: Int
    ) {
        val vRed: Byte = 240.toByte()   // Cr for red
        val uRed: Byte = 90.toByte()    // Cb for red
        val uvOffset = w * h

        fun setUV(px: Int, py: Int) {
            if (px in 0 until w && py in 0 until h) {
                val uvIdx = uvOffset + (py / 2) * w + (px and 0xFFFFFE.toInt())
                if (uvIdx + 1 < nv21.size) {
                    nv21[uvIdx] = vRed
                    nv21[uvIdx + 1] = uRed
                }
            }
        }

        for (t in 0 until thickness) {
            for (x in rx until minOf(rx + rw, w)) {
                setUV(x, ry + t)
                setUV(x, ry + rh - 1 - t)
            }
            for (y in ry until minOf(ry + rh, h)) {
                setUV(rx + t, y)
                setUV(rx + rw - 1 - t, y)
            }
        }
    }
}

/**
 * Result of analyzing a single frame.
 *
 * Sent over EventChannel to Flutter as a HashMap.
 */
data class FrameResult(
    /** JPEG image with red bounding box drawn. */
    val jpegBytes: ByteArray,
    /** Binarized waveform: true=bright (flash ON), false=dark. */
    val binaryWaveform: BooleanArray,
    /** Raw row-averaged luma waveform (0–255 per row). */
    val waveform: IntArray,
    /** X coordinate of tracked ROI center. */
    val roiCenterX: Int,
    /** Y coordinate of tracked ROI center. */
    val roiCenterY: Int,
    /** Whether the tracker has a stable lock. */
    val isLocked: Boolean,
    /** Adaptive threshold value used for this frame. */
    val threshold: Int,
    /** Brightest pixel value found in the tracking scan. */
    val maxBrightness: Int,
    /** Average brightness of entire ROI region (for frame-level OOK). */
    val roiAvgBrightness: Int
) {
    /** Convert to a HashMap for EventChannel transmission. */
    fun toMap(): HashMap<String, Any> {
        return hashMapOf(
            "jpeg" to jpegBytes,
            "waveform" to binaryWaveform.map { if (it) 1 else 0 }.toIntArray(),
            "rawWaveform" to waveform,
            "roiX" to roiCenterX,
            "roiY" to roiCenterY,
            "locked" to isLocked,
            "threshold" to threshold,
            "brightness" to maxBrightness,
            "roiAvg" to roiAvgBrightness
        )
    }
}
