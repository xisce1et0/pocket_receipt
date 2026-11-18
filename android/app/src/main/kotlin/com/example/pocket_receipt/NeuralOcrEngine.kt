package com.example.pocket_receipt

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import io.flutter.FlutterInjector
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.io.File
import java.io.FileOutputStream
import java.nio.FloatBuffer
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

class NeuralOcrEngine(private val context: Context) {

    private var initialized = false
    private lateinit var env: OrtEnvironment
    private lateinit var detSession: OrtSession
    private lateinit var recSession: OrtSession
    private lateinit var dict: List<String>

    private data class TextBox(
        val corners: Array<Point>, // [tl, tr, br, bl]
        val centerX: Double,
        val centerY: Double,
        val cropW: Int,
        val cropH: Int,
        val angleRad: Double,
    )

    @Synchronized
    fun ensureInitialized() {
        if (initialized) return

        if (!OpenCVLoader.initLocal()) {
            throw IllegalStateException("Не удалось инициализировать OpenCV")
        }

        val ocrDir = File(context.filesDir, "neural_ocr")
        if (!ocrDir.exists()) ocrDir.mkdirs()

        val detFile = ensureAssetCopied("assets/ocr/det.onnx", File(ocrDir, "det.onnx"))
        val recFile = ensureAssetCopied("assets/ocr/rec.onnx", File(ocrDir, "rec.onnx"))
        val ymlFile = ensureAssetCopied(
            "assets/ocr/rec_inference.yml",
            File(ocrDir, "rec_inference.yml"),
        )

        dict = parseDictionaryFromYml(ymlFile)
        env = OrtEnvironment.getEnvironment()
        detSession = env.createSession(detFile.absolutePath, OrtSession.SessionOptions())
        recSession = env.createSession(recFile.absolutePath, OrtSession.SessionOptions())
        initialized = true
    }

    fun recognizeText(imagePath: String): String {
        ensureInitialized()

        val bitmap = loadOrientedBitmap(imagePath)
            ?: throw IllegalStateException("Не удалось открыть изображение")

        val rgbaMat = Mat()
        val bgrMat = Mat()
        try {
            Utils.bitmapToMat(bitmap, rgbaMat)
            Imgproc.cvtColor(rgbaMat, bgrMat, Imgproc.COLOR_RGBA2BGR)
        } finally {
            bitmap.recycle()
            rgbaMat.release()
        }

        try {
            val boxes = detectTextBoxes(bgrMat)
            if (boxes.isEmpty()) return ""

            val lines = groupBoxesIntoLines(boxes)
            val sb = StringBuilder()

            for (lineBoxes in lines) {
                val lineParts = mutableListOf<String>()
                for (box in lineBoxes) {
                    val crop = warpTextBox(bgrMat, box)
                    try {
                        val recognized = recognizeLine(crop).trim()
                        if (recognized.isNotEmpty()) {
                            lineParts.add(recognized)
                        }
                    } finally {
                        crop.release()
                    }
                }
                if (lineParts.isNotEmpty()) {
                    if (sb.isNotEmpty()) sb.append('\n')
                    sb.append(lineParts.joinToString(" "))
                }
            }
            return sb.toString()
        } finally {
            bgrMat.release()
        }
    }

    private fun detectTextBoxes(bgrMat: Mat): List<TextBox> {
        val srcW = bgrMat.cols()
        val srcH = bgrMat.rows()
        val maxSide = max(srcW, srcH)

        val scale = if (maxSide > 960) 960.0 / maxSide else 1.0
        var resizeW = ((srcW * scale) / 32.0).roundToInt() * 32
        var resizeH = ((srcH * scale) / 32.0).roundToInt() * 32
        resizeW = max(32, resizeW)
        resizeH = max(32, resizeH)

        val ratioW = resizeW.toDouble() / srcW
        val ratioH = resizeH.toDouble() / srcH

        val resized = Mat()
        Imgproc.resize(bgrMat, resized, Size(resizeW.toDouble(), resizeH.toDouble()))

        val probMap: FloatArray
        try {
            val pixelCount = resizeW * resizeH
            val bytes = ByteArray(pixelCount * 3)
            resized.get(0, 0, bytes)

            val inputFloats = FloatArray(3 * pixelCount)
            val mean = floatArrayOf(0.485f, 0.456f, 0.406f)
            val std = floatArrayOf(0.229f, 0.224f, 0.225f)

            for (i in 0 until pixelCount) {
                val b = (bytes[i * 3].toInt() and 0xFF) / 255.0f
                val g = (bytes[i * 3 + 1].toInt() and 0xFF) / 255.0f
                val r = (bytes[i * 3 + 2].toInt() and 0xFF) / 255.0f
                inputFloats[i] = (b - mean[0]) / std[0]
                inputFloats[pixelCount + i] = (g - mean[1]) / std[1]
                inputFloats[2 * pixelCount + i] = (r - mean[2]) / std[2]
            }

            val inputName = detSession.inputNames.iterator().next()
            val shape = longArrayOf(1L, 3L, resizeH.toLong(), resizeW.toLong())
            OnnxTensor.createTensor(env, FloatBuffer.wrap(inputFloats), shape).use { tensor ->
                detSession.run(mapOf(inputName to tensor)).use { results ->
                    val outTensor = results[0] as OnnxTensor
                    val buf = outTensor.floatBuffer
                    probMap = FloatArray(buf.remaining())
                    buf.get(probMap)
                }
            }
        } finally {
            resized.release()
        }

        val binMat = Mat(resizeH, resizeW, CvType.CV_8UC1)
        val binBytes = ByteArray(resizeH * resizeW)
        for (i in binBytes.indices) {
            binBytes[i] = if (probMap[i] > 0.3f) 255.toByte() else 0.toByte()
        }
        binMat.put(0, 0, binBytes)

        val contours = ArrayList<MatOfPoint>()
        val hierarchy = Mat()
        val boxes = mutableListOf<TextBox>()

        try {
            Imgproc.findContours(
                binMat,
                contours,
                hierarchy,
                Imgproc.RETR_LIST,
                Imgproc.CHAIN_APPROX_SIMPLE,
            )

            for (contour in contours) {
                val ptsArray = contour.toArray()
                if (ptsArray.size < 3) {
                    contour.release()
                    continue
                }

                val bound = Imgproc.boundingRect(contour)
                val score = computeBoxScore(probMap, resizeW, resizeH, bound.x, bound.y, bound.width, bound.height)
                if (score < 0.45f) {
                    contour.release()
                    continue
                }

                val pts2f = MatOfPoint2f(*ptsArray)
                val rect = Imgproc.minAreaRect(pts2f)
                pts2f.release()
                contour.release()

                val rw = rect.size.width
                val rh = rect.size.height
                if (min(rw, rh) < 3.0) continue

                // Расширяем бокс (DBNet unclip_ratio = 1.5)
                val area = rw * rh
                val perimeter = 2.0 * (rw + rh)
                val distance = (area * 1.5) / max(1.0, perimeter)
                rect.size = Size(rw + 2.0 * distance, rh + 2.0 * distance)

                val rawPts = Array(4) { Point() }
                rect.points(rawPts)

                // Переводим координаты обратно в исходный размер фото
                val scaledPts = Array(4) { idx ->
                    Point(
                        (rawPts[idx].x / ratioW).coerceIn(0.0, srcW.toDouble()),
                        (rawPts[idx].y / ratioH).coerceIn(0.0, srcH.toDouble()),
                    )
                }

                val ordered = orderBoxCorners(scaledPts)
                val cropW = hypot(ordered[1].x - ordered[0].x, ordered[1].y - ordered[0].y).roundToInt()
                val cropH = hypot(ordered[3].x - ordered[0].x, ordered[3].y - ordered[0].y).roundToInt()
                if (cropW < 8 || cropH < 6) continue

                val angleRad = atan2(ordered[1].y - ordered[0].y, ordered[1].x - ordered[0].x)
                val cx = ordered.sumOf { it.x } / 4.0
                val cy = ordered.sumOf { it.y } / 4.0

                boxes.add(
                    TextBox(
                        corners = ordered,
                        centerX = cx,
                        centerY = cy,
                        cropW = cropW,
                        cropH = cropH,
                        angleRad = angleRad,
                    ),
                )
            }
        } finally {
            binMat.release()
            hierarchy.release()
        }

        return boxes
    }

    private fun computeBoxScore(
        probMap: FloatArray,
        mapW: Int,
        mapH: Int,
        x: Int,
        y: Int,
        w: Int,
        h: Int,
    ): Float {
        val x1 = x.coerceIn(0, mapW - 1)
        val y1 = y.coerceIn(0, mapH - 1)
        val x2 = (x + w).coerceIn(0, mapW)
        val y2 = (y + h).coerceIn(0, mapH)
        if (x2 <= x1 || y2 <= y1) return 0f

        var sum = 0f
        var count = 0
        for (row in y1 until y2) {
            val rowOffset = row * mapW
            for (col in x1 until x2) {
                sum += probMap[rowOffset + col]
                count++
            }
        }
        return if (count > 0) sum / count else 0f
    }

    /// Упорядочивает 4 угла в [tl, tr, br, bl] по длинной оси текста (работает при любом наклоне)
    private fun orderBoxCorners(pts: Array<Point>): Array<Point> {
        val d01 = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
        val d12 = hypot(pts[2].x - pts[1].x, pts[2].y - pts[1].y)

        var edge1Start: Point
        var edge1End: Point
        var edge2Start: Point
        var edge2End: Point

        if (d01 >= d12) {
            edge1Start = pts[0]
            edge1End = pts[1]
            edge2Start = pts[3]
            edge2End = pts[2]
        } else {
            edge1Start = pts[1]
            edge1End = pts[2]
            edge2Start = pts[0]
            edge2End = pts[3]
        }

        if (edge1Start.x > edge1End.x) {
            val tmp = edge1Start
            edge1Start = edge1End
            edge1End = tmp
        }
        if (edge2Start.x > edge2End.x) {
            val tmp = edge2Start
            edge2Start = edge2End
            edge2End = tmp
        }

        val mid1Y = (edge1Start.y + edge1End.y) / 2.0
        val mid2Y = (edge2Start.y + edge2End.y) / 2.0

        return if (mid1Y <= mid2Y) {
            arrayOf(edge1Start, edge1End, edge2End, edge2Start)
        } else {
            arrayOf(edge2Start, edge2End, edge1End, edge1Start)
        }
    }

    private fun warpTextBox(bgrMat: Mat, box: TextBox): Mat {
        val srcPts = MatOfPoint2f(*box.corners)
        val dstPts = MatOfPoint2f(
            Point(0.0, 0.0),
            Point(box.cropW.toDouble(), 0.0),
            Point(box.cropW.toDouble(), box.cropH.toDouble()),
            Point(0.0, box.cropH.toDouble()),
        )
        val transform = Imgproc.getPerspectiveTransform(srcPts, dstPts)
        val cropped = Mat()
        try {
            Imgproc.warpPerspective(
                bgrMat,
                cropped,
                transform,
                Size(box.cropW.toDouble(), box.cropH.toDouble()),
            )
            return cropped
        } finally {
            srcPts.release()
            dstPts.release()
            transform.release()
        }
    }

    private fun groupBoxesIntoLines(boxes: List<TextBox>): List<List<TextBox>> {
        val wideAngles = boxes
            .filter { it.cropW > it.cropH * 2 && abs(it.angleRad) < Math.PI / 4 }
            .map { it.angleRad }
            .sorted()

        val medianAngle = if (wideAngles.isNotEmpty()) {
            wideAngles[wideAngles.size / 2]
        } else {
            0.0
        }

        val cosA = cos(medianAngle)
        val sinA = sin(medianAngle)

        data class RotatedBox(val box: TextBox, val rotX: Double, val rotY: Double)

        val rotated = boxes.map { box ->
            val rx = box.centerX * cosA + box.centerY * sinA
            val ry = -box.centerX * sinA + box.centerY * cosA
            RotatedBox(box, rx, ry)
        }.sortedBy { it.rotY }

        val rows = mutableListOf<MutableList<RotatedBox>>()
        for (item in rotated) {
            if (rows.isEmpty()) {
                rows.add(mutableListOf(item))
                continue
            }
            val currentRow = rows.last()
            val rowAvgY = currentRow.sumOf { it.rotY } / currentRow.size
            val rowAvgH = currentRow.sumOf { it.box.cropH.toDouble() } / currentRow.size
            val threshold = max(rowAvgH, item.box.cropH.toDouble()) * 0.55

            if (abs(item.rotY - rowAvgY) <= threshold) {
                currentRow.add(item)
            } else {
                rows.add(mutableListOf(item))
            }
        }

        return rows.map { row ->
            row.sortedBy { it.rotX }.map { it.box }
        }
    }

    private fun recognizeLine(cropBgr: Mat): String {
        val imgH = 48
        val srcW = cropBgr.cols()
        val srcH = cropBgr.rows()
        if (srcW <= 0 || srcH <= 0) return ""

        val ratio = srcW.toDouble() / srcH.toDouble()
        val resizedW = max(8, min(1280, ceil(imgH * ratio).toInt()))
        val targetW = max(320, ((resizedW + 31) / 32) * 32)

        val resized = Mat()
        Imgproc.resize(cropBgr, resized, Size(resizedW.toDouble(), imgH.toDouble()))

        val logits: FloatArray
        val timeSteps: Int
        val numClasses: Int

        try {
            val bytes = ByteArray(imgH * resizedW * 3)
            resized.get(0, 0, bytes)

            val planeSize = imgH * targetW
            val inputFloats = FloatArray(3 * planeSize) // По умолчанию 0.0f для padding справа

            for (y in 0 until imgH) {
                val srcRowOffset = y * resizedW * 3
                val dstRowOffset = y * targetW
                for (x in 0 until resizedW) {
                    val b = ((bytes[srcRowOffset + x * 3].toInt() and 0xFF) / 255.0f - 0.5f) / 0.5f
                    val g = ((bytes[srcRowOffset + x * 3 + 1].toInt() and 0xFF) / 255.0f - 0.5f) / 0.5f
                    val r = ((bytes[srcRowOffset + x * 3 + 2].toInt() and 0xFF) / 255.0f - 0.5f) / 0.5f

                    val dstIdx = dstRowOffset + x
                    inputFloats[dstIdx] = b
                    inputFloats[planeSize + dstIdx] = g
                    inputFloats[2 * planeSize + dstIdx] = r
                }
            }

            val inputName = recSession.inputNames.iterator().next()
            val shape = longArrayOf(1L, 3L, imgH.toLong(), targetW.toLong())
            OnnxTensor.createTensor(env, FloatBuffer.wrap(inputFloats), shape).use { tensor ->
                recSession.run(mapOf(inputName to tensor)).use { results ->
                    val outTensor = results[0] as OnnxTensor
                    val outShape = outTensor.info.shape
                    timeSteps = outShape[1].toInt()
                    numClasses = outShape[2].toInt()
                    val buf = outTensor.floatBuffer
                    logits = FloatArray(buf.remaining())
                    buf.get(logits)
                }
            }
        } finally {
            resized.release()
        }

        // CTC Greedy Decode
        val sb = StringBuilder()
        var prevIdx = -1
        for (t in 0 until timeSteps) {
            val rowOffset = t * numClasses
            var bestIdx = 0
            var bestVal = logits[rowOffset]
            for (c in 1 until numClasses) {
                val v = logits[rowOffset + c]
                if (v > bestVal) {
                    bestVal = v
                    bestIdx = c
                }
            }

            if (bestIdx != 0 && bestIdx != prevIdx) {
                val dictIdx = bestIdx - 1
                if (dictIdx in dict.indices) {
                    sb.append(dict[dictIdx])
                } else if (numClasses == dict.size + 2 && bestIdx == dict.size + 1) {
                    sb.append(' ')
                }
            }
            prevIdx = bestIdx
        }
        return sb.toString()
    }

    private fun parseDictionaryFromYml(ymlFile: File): List<String> {
        val result = mutableListOf<String>()
        var inDict = false

        ymlFile.readLines(Charsets.UTF_8).forEach { rawLine ->
            if (!inDict) {
                if (rawLine.trimStart().startsWith("character_dict:")) {
                    inDict = true
                }
                return@forEach
            }

            val trimmed = rawLine.trim()
            if (trimmed.isEmpty()) return@forEach
            if (!trimmed.startsWith("- ")) {
                inDict = false
                return@forEach
            }

            var token = trimmed.substring(2).trim()
            if (token.length >= 2 && token.startsWith("'") && token.endsWith("'")) {
                token = token.substring(1, token.length - 1).replace("''", "'")
            } else if (token.length >= 2 && token.startsWith("\"") && token.endsWith("\"")) {
                token = token.substring(1, token.length - 1)
                    .replace("\\\"", "\"")
                    .replace("\\\\", "\\")
            }
            result.add(token)
        }
        return result
    }

    private fun ensureAssetCopied(assetPath: String, destFile: File): File {
        if (!destFile.exists() || destFile.length() == 0L) {
            val assetKey = FlutterInjector.instance()
                .flutterLoader()
                .getLookupKeyForAsset(assetPath)
            context.assets.open(assetKey).use { input ->
                FileOutputStream(destFile).use { output ->
                    input.copyTo(output)
                }
            }
        }
        return destFile
    }

    private fun loadOrientedBitmap(imagePath: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(imagePath, bounds)

        val maxSide = max(bounds.outWidth, bounds.outHeight)
        var sampleSize = 1
        while (maxSide / sampleSize > 2048) {
            sampleSize *= 2
        }

        val decodeOpts = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        var bitmap = BitmapFactory.decodeFile(imagePath, decodeOpts) ?: return null

        if (bitmap.config != Bitmap.Config.ARGB_8888) {
            val converted = bitmap.copy(Bitmap.Config.ARGB_8888, false)
            bitmap.recycle()
            bitmap = converted
        }

        val rotationDegrees = try {
            val exif = ExifInterface(imagePath)
            when (exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (_: Exception) {
            0f
        }

        if (rotationDegrees == 0f) return bitmap

        val matrix = Matrix().apply { postRotate(rotationDegrees) }
        val rotated = Bitmap.createBitmap(
            bitmap,
            0,
            0,
            bitmap.width,
            bitmap.height,
            matrix,
            true,
        )
        bitmap.recycle()
        return rotated
    }
}